#!/bin/bash
# Stop hook: summarize the assistant's last message in one sentence and speak it.
# Registered with "async": true, so this runs in the background and must never
# block the interactive session. Every exit path below is exit 0.

set -u

# Defense in depth: `claude --safe-mode -p` below should already skip hooks,
# CLAUDE.md, and plugins, but guard against recursion in case that ever changes.
if [ "${VOICE_READOUT_GUARD:-}" = "1" ]; then
  exit 0
fi
export VOICE_READOUT_GUARD=1

source "$(dirname "$0")/tts-lib.sh"

if ! is_enabled STOP_READOUT; then
  log skip "stop readout disabled via toggle"
  exit 0
fi

INPUT_JSON="$(cat)"
LAST_MSG="$(printf '%s' "$INPUT_JSON" | jq -r '.last_assistant_message // empty' 2>/dev/null)"

if [ -z "$LAST_MSG" ]; then
  log skip "no last_assistant_message in hook input"
  exit 0
fi

# From here on this hook is committed to speaking, so claim the marker that
# stops the Notification hook from cutting the readout off with its idle notice
# (see SPEAKING_MARKER_FILE in tts-lib.sh). Claimed before the summarizer call
# rather than immediately before speak(): the marker covers a few seconds of
# silence that way, but every path below — full, summary, the overflow pipeline
# — is covered by construction, and one trap releases it however we exit.
readout_speaking_begin
trap readout_speaking_end EXIT

# Rule-based cleanup: strip fenced code blocks, inline code, markdown links
# (keep the link text), raw URLs, then markup syntax that reads badly aloud
# (bold/italic markers, headings, list bullets, blockquotes — mainly matters
# for full mode, which speaks this text verbatim instead of via Haiku),
# then collapse whitespace.
# The fence pattern allows leading whitespace: a code block nested in a list
# item is indented, and an anchored /^```/ left its contents in the text to be
# read aloud as prose.
CLEANED="$(printf '%s' "$LAST_MSG" \
  | sed -E '/^[[:space:]]*```/,/^[[:space:]]*```/d' \
  | sed -E 's/`([^`]*)`/\1/g' \
  | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' \
  | sed -E 's#https?://[^ ]+##g' \
  | sed -E 's/\*\*([^*]*)\*\*/\1/g; s/__([^_]*)__/\1/g' \
  | sed -E 's/\*([^*]*)\*/\1/g; s/_([^_]*)_/\1/g' \
  | sed -E 's/^#+[[:space:]]*//g' \
  | sed -E 's/^[[:space:]]*[-*+][[:space:]]+//g' \
  | sed -E 's/^>[[:space:]]*//g' \
  | tr -s '[:space:]' ' ')"

CLEANED_TRIMMED="$(printf '%s' "$CLEANED" | sed -E 's/^ +| +$//g')"
if [ -z "$CLEANED_TRIMMED" ]; then
  # A response that is only code/URLs. Say so rather than going silent: a
  # listener can't tell silence from a hook that died. Fixed phrase, so the
  # pre-rendered clip serves it; live TTS only if the clip is unavailable.
  log skip "nothing left to read after stripping code/URLs, announcing instead"
  play_notice_clip "$CODE_ONLY_CLIP" nowait || speak "$READOUT_CODE_ONLY_NOTICE" 60 summary
  exit 0
fi

READOUT_MODE="$(get_readout_mode)"

# The summarizer is a chat model, and handing it a fragment gives it nothing to
# summarize — so it stops summarizing and answers the user instead
# (「要約する応答がまだ送られていません…」), which then gets read aloud as if it
# were the summary. Observed after a response whose prose was one short line
# around a code block. Reproduced directly: 「はい。」 and 「こうです：」 both
# produce that reply. Below this length a summary can't beat the text itself
# anyway, so skip the model — which also drops the ~10-16s summarizer wait from
# every short reply.
SUMMARY_MIN_CHARS="$(get_tuning SUMMARY_MIN_CHARS 40)"

# Every phrasing meaning "you gave me nothing to summarize" that has been seen
# in the log or reproduced, plus the style refusals. One function rather than
# two copies of a case: the copies drifted, and the variant the user actually
# heard (「私の前の応答がありません。要約する内容がないんです」) matched neither.
# Substrings are kept short and specific for that reason — the wording changes
# from run to run. This is only a backstop; SUMMARY_MIN_CHARS above is what
# stops the model being asked in the first place.
summarizer_refused() {
  case "$1" in
    *申し訳ありませんが*|*ロールプレイ*|*応答はできません*|*お応えできません*|*"I can't"*|*"I cannot"*) return 0 ;;
    *要約の対象*|*要約する内容*|*要約する応答*|*要約できる*) return 0 ;;
    *前のメッセージ*|*前の応答*|*送られていません*|*提供されていない*) return 0 ;;
  esac
  return 1
}

# The summarizer prompt. Defined here (above the full-mode block) because the
# experimental overflow pipeline inside that block summarizes too.
#
# First-person framing matters: summarizing "the assistant's response" from the
# outside produced narrator-style readouts (「〜ということですね」) that felt like
# a third party reporting on the conversation.
#
# But it must not be framed as "this is the response YOU just sent", which is
# what it used to say. Haiku is a chat model with no such response in its
# context, so it would sometimes disagree with the premise and answer the user
# instead —「このセッションではまだ応答を送っていないので…」— and that reply got
# read aloud as the summary. Point at delimited text and ask for a summary of
# it: a claim about the text can't be contradicted by an empty history. The
# last sentence closes the same door explicitly.
SUMMARY_PROMPT='次の <text> と </text> に挟まれたテキストを、一文の日本語に要約してください。そのテキストを書いた本人が相手に直接話しかける口調で、短く自然な話し言葉にしてください。「〜とのことです」「〜ということですね」のような伝聞・第三者的な言い回しや、堅い敬語は使わないでください。コード・記号・URL・ファイルパスは含めないでください。要約文だけを出力し、前置きや説明は付けないでください。テキストが短くても断片でも、その内容を要約することだけを行い、質問や説明を返さないでください。'

# Feed the text to the summarizer, delimited to match the prompt above. A body
# carrying its own </text> would end the block early and leave the rest sitting
# outside it, where it reads as instructions rather than as material — this
# script summarizes whatever Claude last said, including text about these very
# tags. A probe with a closing tag and a follow-on instruction was in fact
# summarized rather than obeyed, but that is one sample of a model whose wording
# has varied run to run all day, so drop the bare tags instead of relying on it.
# They carry nothing audible anyway.
run_summarizer() {
  local body
  body="$(printf '%s' "$1" | sed -E 's#</?text>##g')"
  printf '<text>\n%s\n</text>' "$body" | claude --safe-mode -p --model haiku "$SUMMARY_PROMPT" 2>/dev/null
}

if [ "$READOUT_MODE" = "full" ]; then
  # Full mode: read the cleaned text verbatim, no summarization. Requested
  # because one-sentence summaries lose too much for the listener to follow.
  log full "(${#CLEANED_TRIMMED} chars) ${CLEANED_TRIMMED:0:60}..."
  speak "$CLEANED_TRIMMED" 600 full
  rc=$?
  if [ "$rc" -ne 3 ]; then
    exit 0
  fi
  # 3 = the on-device engine declined this as too long (see the ceiling in
  # speak()). The on-device backend was chosen deliberately, so we stay on it
  # rather than switching to a cloud voice — fall through to the one-sentence
  # summary below, which is always short enough for the engine to speak safely.
  # Saying nothing at all is the worst outcome for someone who is listening
  # rather than looking at the screen. OVERFLOW makes the summary announce
  # itself as a summary so the listener knows the full text was shortened.
  log fallback "full readout too long for ondevice, degrading to summary"
  OVERFLOW=1

  # ---- Experimental overflow pipeline (toggle OVERFLOW_PIPELINE, default off) --
  # Hide the summarizer latency behind the opening. Read the first ~N characters
  # verbatim immediately (no LLM, so it starts speaking at once), summarize the
  # WHOLE response with Haiku in the BACKGROUND meanwhile, bridge with a short
  # spoken notice, then read the finished summary. The three TTS calls run one
  # after another (no engine collision); only the non-engine `claude` summarizer
  # runs in parallel, and speaking the opening warms the engine so the bridge and
  # summary skip the preflight probe. Self-contained + toggle-guarded so the
  # whole feature is trivially revertible: delete this block, the toggle verb,
  # the two config defaults, and the bridge string.
  if [ "$(get_tuning OVERFLOW_PIPELINE off)" = "on" ]; then
    log fallback "overflow pipeline: opening now, summarizing whole response in background"
    PIPE_TMP="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/vr-pipe-$$")"
    PIPE_DONE_TMP="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/vr-pipe-done-$$")"
    PIPE_T0="$(date +%s)"
    # `wait` below only runs after the opening+bridge audio finishes, so
    # `date +%s` right after `wait` returns is NOT when claude actually exited
    # if it finished earlier — wait() on an already-exited child returns
    # instantly. Have the subshell stamp its own real completion time instead.
    ( run_summarizer "$CLEANED_TRIMMED" > "$PIPE_TMP"; date +%s > "$PIPE_DONE_TMP" ) &
    PIPE_PID=$!

    # Opening: first N chars, backed off to the last sentence/clause boundary
    # (。！？、) inside the window so it never stops mid-word. Character-safe
    # because tts-lib.sh exports a UTF-8 locale. N is configurable — it has to be
    # long enough to cover the background summarizer (measured ~30s for the
    # `claude -p` cold start), because the bridge is now a ~3s clip rather than a
    # ~12s TTS phrase and so hides much less of that wait on its own.
    PIPE_OPEN_MAX="$(get_tuning OVERFLOW_OPENING_CHARS 150)"
    PIPE_OPENING="${CLEANED_TRIMMED:0:$PIPE_OPEN_MAX}"
    PIPE_CUT="$(printf '%s' "$PIPE_OPENING" | sed -E 's/(.*[。！？、]).*/\1/')"
    [ -n "$PIPE_CUT" ] && PIPE_OPENING="$PIPE_CUT"
    log full "pipeline opening (${#PIPE_OPENING} chars): ${PIPE_OPENING:0:40}..."
    speak "$PIPE_OPENING" 120 full

    # Bridge so the listener knows an overall summary follows the opening. Play
    # the pre-rendered clip (instant, engine-independent, blocks until it stops
    # so it can't talk over the summary); fall back to live TTS only if the clip
    # is unavailable.
    if ! play_notice_clip "$BRIDGE_CLIP"; then
      speak "$OVERFLOW_PIPELINE_BRIDGE" 90 summary
    fi

    # Join the background summary (usually already done during the opening read).
    # Measure the seam: how long the summarizer took overall, how much the
    # opening+bridge covered, and the residual gap where `wait` actually blocked
    # (the silence the listener hears before the summary — 0 = seamless; if it's
    # consistently >0, raise OVERFLOW_OPENING_CHARS).
    PIPE_PRE_WAIT="$(date +%s)"
    wait "$PIPE_PID" 2>/dev/null
    PIPE_POST_WAIT="$(date +%s)"
    PIPE_TRUE_DONE="$(cat "$PIPE_DONE_TMP" 2>/dev/null)"
    PIPE_TRUE_DONE="${PIPE_TRUE_DONE:-$PIPE_POST_WAIT}"
    log info "pipeline timing: summarizer $(( PIPE_TRUE_DONE - PIPE_T0 ))s (true completion), opening+bridge $(( PIPE_PRE_WAIT - PIPE_T0 ))s, gap before summary $(( PIPE_POST_WAIT - PIPE_PRE_WAIT ))s"
    SUMMARY="$(cat "$PIPE_TMP" 2>/dev/null)"
    rm -f "$PIPE_TMP" "$PIPE_DONE_TMP" 2>/dev/null

    # Same empty fallback + on-device ceiling trim as the normal summarizer path
    # below. The refusal guard is now one shared function, so it can't drift.
    if summarizer_refused "$SUMMARY"; then
      log fallback "summarizer refused or had nothing to summarize, using cleaned text"
      SUMMARY=""
    fi
    [ -z "$SUMMARY" ] && SUMMARY="${CLEANED_TRIMMED:0:120}"
    PIPE_SMAX="$(ondevice_max_chars)"
    if [ "$(get_tts_backend summary)" = "ondevice" ] && [ "${#SUMMARY}" -gt "$PIPE_SMAX" ]; then
      log fallback "summary ${#SUMMARY} chars exceeds ondevice ceiling, trimming to ${PIPE_SMAX}"
      SUMMARY="${SUMMARY:0:$PIPE_SMAX}"
    fi
    log summary "$SUMMARY"
    speak "$SUMMARY" 90 summary
    exit 0
  fi
  # ---- end experimental overflow pipeline -------------------------------------

  # Announce the shortening NOW, before the ~10s+ summarizer call below — the
  # length check that got us here is instant, so there is no reason to make the
  # listener sit in silence during summarization wondering if it died. The
  # notice is a pre-rendered clip played through the media player (independent
  # of the TTS engine), so it fires immediately and cannot collide with the
  # summary readout that follows. If the clip is unavailable we fall back to
  # prepending the spoken notice text to the summary further down.
  if play_notice_clip "$NOTICE_CLIP"; then
    OVERFLOW_ANNOUNCED=1
  fi
fi

if [ "${#CLEANED_TRIMMED}" -lt "$SUMMARY_MIN_CHARS" ]; then
  # Too short to summarize (see SUMMARY_MIN_CHARS above) — read it as it is.
  log skip "only ${#CLEANED_TRIMMED} chars left, reading as-is instead of summarizing"
  SUMMARY="$CLEANED_TRIMMED"
else
  SUMMARY="$(run_summarizer "$CLEANED_TRIMMED")"

  # If the summarizer refused, reading the refusal aloud is worse than a plain
  # readout — fall back to the cleaned text instead. Match only refusal-specific
  # phrasing: a summary of an apology legitimately contains 申し訳/できません, so
  # matching those bare would throw away good summaries too.
  if summarizer_refused "$SUMMARY"; then
    log fallback "summarizer refused or had nothing to summarize, using cleaned text"
    SUMMARY=""
  fi
fi

if [ -z "$SUMMARY" ]; then
  # Fallback: no LLM summary available, just read the cleaned text head.
  SUMMARY="${CLEANED_TRIMMED:0:120}"
  log fallback "$SUMMARY"
else
  log summary "$SUMMARY"
fi

# The summary is *meant* to be one sentence, but nothing enforces that — a
# confused or verbose summarizer can hand back something over the on-device
# ceiling, and then speak() declines it too. This is the last stop before
# audio: if it gets refused here the listener hears nothing at all, which
# defeats the whole point of degrading to a summary in the first place
# (observed: a 450-char full readout degraded to a 244-char "summary" that
# was itself refused, so the hook spoke nothing). Trim to fit rather than
# lose the readout entirely. Character-safe: tts-lib.sh exports a UTF-8
# locale, so this slices by character, not byte.
# We already announced the overflow up front by playing the notice clip (see
# the OVERFLOW block above). Only if that clip was unavailable do we fall back
# to prepending the spoken notice text here — before the trim, so the notice
# can't be the part that gets cut.
if [ -n "${OVERFLOW:-}" ] && [ -z "${OVERFLOW_ANNOUNCED:-}" ]; then
  SUMMARY="${READOUT_OVERFLOW_NOTICE}${SUMMARY}"
fi

SUMMARY_MAX="$(ondevice_max_chars)"
if [ "$(get_tts_backend summary)" = "ondevice" ] && [ "${#SUMMARY}" -gt "$SUMMARY_MAX" ]; then
  log fallback "summary ${#SUMMARY} chars exceeds ondevice ceiling, trimming to ${SUMMARY_MAX}"
  SUMMARY="${SUMMARY:0:$SUMMARY_MAX}"
fi

speak "$SUMMARY" 90 summary

exit 0
