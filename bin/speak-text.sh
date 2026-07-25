#!/bin/bash
# Ad-hoc readout: speaks arbitrary text supplied directly by the user (a file
# or stdin), bypassing the Stop hook's summarization/cleanup entirely. Unlike
# summarize-and-speak.sh, this is not a hook — it's invoked directly (e.g. by
# Claude when the user hands over a file to read aloud) and uses whichever
# TTS_BACKEND is currently configured (see toggle.sh backend).
#
# Usage: speak-text.sh <file>
#        cat file | speak-text.sh -

set -u

source "$(dirname "$0")/tts-lib.sh"

usage() {
  echo "Usage: $0 <file>" >&2
  echo "       $0 -        (read text from stdin)" >&2
  exit 1
}

[ $# -eq 1 ] || usage
SRC="$1"

if [ "$SRC" = "-" ]; then
  TEXT="$(cat)"
else
  [ -f "$SRC" ] || { echo "file not found: $SRC" >&2; exit 1; }
  TEXT="$(cat "$SRC")"
fi

[ -n "$TEXT" ] || { echo "nothing to read: input is empty" >&2; exit 1; }

# Scale the cap with length so long files aren't cut off mid-sentence — mirrors
# full-mode's cap in summarize-and-speak.sh.
bytes="$(printf '%s' "$TEXT" | wc -c)"
cap=$(( 30 + bytes / 3 ))
[ "$cap" -gt 900 ] && cap=900

log manual "speak-text.sh (${#TEXT} chars) from ${SRC}"
# Same handling as the Stop hook: queue behind any readout already speaking,
# and hold the marker so an idle notice cannot cut this one off either.
trap readout_speaking_end EXIT
if ! readout_speaking_begin; then
  log skip "読み上げ停止中 (stop switch pressed while queued)"
  exit 0
fi
speak "$TEXT" "$cap" file
rc=$?

# 3 = ondevice declined the text as too long (see the ceiling in speak()). The
# on-device backend was chosen deliberately — a registered cloud key does not
# override that — so rather than refusing (or switching to a cloud voice the
# user didn't ask for), summarize the file and read the summary on-device,
# announced as a summary so the listener knows the text was shortened. To have
# the whole file read verbatim, switch this function to a cloud backend:
#   bin/toggle.sh backend-file elevenlabs   （または inworld / gemini）
if [ "$rc" -eq 3 ]; then
  log fallback "file readout too long for ondevice (${#TEXT} chars), degrading to summary"
  export VOICE_READOUT_GUARD=1
  SUMMARY="$(printf '%s' "$TEXT" | claude --safe-mode -p --model haiku '以下の文章の内容を、短く日本語で要約してください。要約文だけを出力し、前置きや説明は付けないでください。' 2>/dev/null)"
  [ -n "$SUMMARY" ] || SUMMARY="${TEXT:0:120}"
  MAX="$(ondevice_max_chars)"
  # Announce via the pre-rendered notice clip if present, else prepend the
  # spoken notice text to the summary.
  if play_notice_clip "$NOTICE_CLIP"; then
    [ "${#SUMMARY}" -gt "$MAX" ] && SUMMARY="${SUMMARY:0:$MAX}"
    speak "$SUMMARY" 90 file
  else
    COMBINED="${READOUT_OVERFLOW_NOTICE}${SUMMARY}"
    [ "${#COMBINED}" -gt "$MAX" ] && COMBINED="${COMBINED:0:$MAX}"
    speak "$COMBINED" 90 file
  fi
fi
exit 0
