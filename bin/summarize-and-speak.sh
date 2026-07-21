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

# Rule-based cleanup: strip fenced code blocks, inline code, markdown links
# (keep the link text), raw URLs, then markup syntax that reads badly aloud
# (bold/italic markers, headings, list bullets, blockquotes — mainly matters
# for full mode, which speaks this text verbatim instead of via Haiku),
# then collapse whitespace.
CLEANED="$(printf '%s' "$LAST_MSG" \
  | sed -E '/^```/,/^```/d' \
  | sed -E 's/`[^`]*`//g' \
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
  log skip "nothing left to read after stripping code/URLs"
  exit 0
fi

READOUT_MODE="$(get_readout_mode)"

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
fi

# First-person framing matters: summarizing "the assistant's response" from
# the outside produced narrator-style readouts (「〜ということですね」) that
# felt like a third party reporting on the conversation. That part is a
# permanent baseline. The playful tone on top of it (see personas/) is
# optional and lives outside this script — read PERSONA_FILE via tts-lib.sh.
# Tone note: pushing a persona's framing too far (e.g. 恋人に囁く…) can make
# Haiku refuse, and the refusal text itself would get read aloud — see the
# fallback check below.
BASE_PROMPT_PREFIX='以下はあなた自身がたった今チャットで送った応答です。その内容を、送った本人として相手に直接話しかける一文に要約してください。短く、自然な話し言葉にしてください。「〜とのことです」「〜ということですね」のような伝聞・第三者的な言い回しや、堅い敬語は使わないでください。'
BASE_PROMPT_SUFFIX='コード・記号・URL・ファイルパスは含めないでください。要約文だけを出力し、前置きや説明は付けないでください。'
PERSONA_STYLE="$(get_persona_style)"
SUMMARY_PROMPT="${BASE_PROMPT_PREFIX} ${PERSONA_STYLE} ${BASE_PROMPT_SUFFIX}"

SUMMARY="$(printf '%s' "$CLEANED_TRIMMED" | claude --safe-mode -p --model haiku "$SUMMARY_PROMPT" 2>/dev/null)"

# If the summarizer refused the style instruction, reading the refusal aloud
# is worse than a plain readout — fall back to the cleaned text instead.
# Match only refusal-specific phrasing: the sweet tone itself legitimately
# produces 「申し訳ないのよ」 in apology summaries, so plain 申し訳/できません
# would throw those away too.
case "$SUMMARY" in
  *申し訳ありませんが*|*ロールプレイ*|*応答はできません*|*お応えできません*|*"I can't"*|*"I cannot"*)
    log fallback "summarizer refused style, using cleaned text"
    SUMMARY=""
    ;;
esac

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
# When we degraded here from an over-length full readout, announce it: play the
# pre-rendered notice clip if it's available, otherwise prepend the spoken
# notice text (before the trim, so the notice can't be the part that gets cut).
if [ -n "${OVERFLOW:-}" ] && ! play_notice_clip "$NOTICE_CLIP"; then
  SUMMARY="${READOUT_OVERFLOW_NOTICE}${SUMMARY}"
fi

SUMMARY_MAX="$(ondevice_max_chars)"
if [ "$(get_tts_backend summary)" = "ondevice" ] && [ "${#SUMMARY}" -gt "$SUMMARY_MAX" ]; then
  log fallback "summary ${#SUMMARY} chars exceeds ondevice ceiling, trimming to ${SUMMARY_MAX}"
  SUMMARY="${SUMMARY:0:$SUMMARY_MAX}"
fi

speak "$SUMMARY" 90 summary

exit 0
