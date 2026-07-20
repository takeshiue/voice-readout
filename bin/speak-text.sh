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
speak "$TEXT" "$cap"
rc=$?

# 3 = ondevice declined the text as too long (see the ceiling in speak()).
# Surface it here rather than exiting silently: this is run interactively, so
# the caller needs to know nothing was spoken and why.
if [ "$rc" -eq 3 ]; then
  cat >&2 <<MSG
オンデバイス読み上げは長文に対応していません（${#TEXT}文字）。
Termux:API が長い読み上げの途中で停止し、アプリを手動で強制停止するまで復旧しないため、
安全な長さを超えるテキストは実行せずに中止しています。
長文を読み上げるには、クラウド系のバックエンドに切り替えてください:
  bin/toggle.sh backend inworld     （または elevenlabs / gemini）
MSG
  exit 3
fi
exit 0
