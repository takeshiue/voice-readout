#!/bin/bash
# Codex Stop hook. Summary mode intentionally does not launch `codex exec` or
# require Claude CLI; it speaks a bounded excerpt. Full mode uses the existing
# TTS queue, engines, recovery, and emergency stop switch.
set -u

if [ "${1:-}" = "__worker" ]; then
  source "$(dirname "$0")/tts-lib.sh"
  source "$(dirname "$0")/response-text.sh"
  INPUT_FILE="${2:-}"
  trap 'rm -f "$INPUT_FILE"' EXIT

  is_enabled STOP_READOUT || exit 0
  LAST_MSG="$(cat "$INPUT_FILE" 2>/dev/null)"
  [ -n "$LAST_MSG" ] || exit 0
  CLEANED="$(clean_response_for_speech "$LAST_MSG")"
  if [ -z "$CLEANED" ]; then
    play_notice_clip "$CODE_ONLY_CLIP" nowait || speak "$READOUT_CODE_ONLY_NOTICE" 60 summary
    exit 0
  fi

  trap readout_speaking_end EXIT
  readout_speaking_begin || exit 0
  if [ "$(get_readout_mode)" = "full" ]; then
    speak "$CLEANED" 600 full
  else
    speak "$(excerpt_for_speech "$CLEANED" 160)" 120 summary
  fi
  exit 0
fi

# Stop hooks require JSON output. Hand a 0600 file to the detached worker so
# long responses and embedded newlines are not passed via environment variables.
source "$(dirname "$0")/tts-lib.sh"
INPUT_JSON="$(cat)"
LAST_MSG="$(printf '%s' "$INPUT_JSON" | jq -r '.last_assistant_message // empty' 2>/dev/null)"
[ -n "$LAST_MSG" ] || { printf '{}\n'; exit 0; }

umask 077
INPUT_FILE="$(mktemp "${PLUGIN_DATA_DIR}/vr-codex-stop.XXXXXX" 2>/dev/null)" || { printf '{}\n'; exit 0; }
printf '%s' "$LAST_MSG" > "$INPUT_FILE"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
VOICE_READOUT_GUARD=1 setsid "$SELF" __worker "$INPUT_FILE" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true
printf '{}\n'
