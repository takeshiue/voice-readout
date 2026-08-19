#!/bin/bash
# Antigravity CLI (agy) SessionStart / PreInvocation startup coordinator.
# Posts the stop button notification on Android, then greets the user.
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

  # Session greeting - ensure source: startup for agy
  if [ -z "$INPUT_JSON" ]; then
    INPUT_JSON='{"source":"startup"}'
  elif ! echo "$INPUT_JSON" | grep -q '"source"'; then
    INPUT_JSON=$(echo "$INPUT_JSON" | jq -c '. + {source: "startup"}')
  fi
  printf '%s' "$INPUT_JSON" | "$HERE/session-greet.sh" >/dev/null 2>&1
  exit 0
fi

INPUT_JSON="$(cat)"

umask 077
DATA_DIR="${PLUGIN_DATA_DIR:-/tmp}"
[ -d "$DATA_DIR" ] || DATA_DIR="/tmp"
INPUT_FILE="$(mktemp "${DATA_DIR}/vr-agy-session-start.XXXXXX" 2>/dev/null)" || { printf '{}\n'; exit 0; }
printf '%s' "$INPUT_JSON" > "$INPUT_FILE"

SELF="$HERE/$(basename "$0")"
setsid "$SELF" __worker "$INPUT_FILE" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

# Return empty JSON object for hook protocol
printf '{}\n'
