#!/bin/bash
# Antigravity CLI (agy) SessionEnd coordinator.
# Speaks farewell and clears the Android stop notification.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "__worker" ]; then
  INPUT_FILE="${2:-}"
  if [ -n "$INPUT_FILE" ] && [ -f "$INPUT_FILE" ]; then
    INPUT_JSON="$(cat "$INPUT_FILE")"
    rm -f "$INPUT_FILE" 2>/dev/null
  else
    INPUT_JSON="{}"
  fi

  source "$HERE/tts-lib.sh"
  touch "${PLUGIN_DATA_DIR}/voice-readout-session-ended" 2>/dev/null

  "$HERE/cancel.sh" >/dev/null 2>&1 || true
  printf '%s' "$INPUT_JSON" | "$HERE/session-farewell.sh" >/dev/null 2>&1
  exit 0
fi

INPUT_JSON="$(cat)"

umask 077
DATA_DIR="${PLUGIN_DATA_DIR:-/tmp}"
[ -d "$DATA_DIR" ] || DATA_DIR="/tmp"
INPUT_FILE="$(mktemp "${DATA_DIR}/vr-agy-session-end.XXXXXX" 2>/dev/null)" || { printf '{}\n'; exit 0; }
printf '%s' "$INPUT_JSON" > "$INPUT_FILE"

SELF="$HERE/$(basename "$0")"
setsid "$SELF" __worker "$INPUT_FILE" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

printf '{}\n'
