#!/bin/bash
# Antigravity CLI (agy) SessionStart / PreInvocation startup coordinator.
# Posts the stop button notification on Android, then greets the user.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INPUT_JSON="$(cat)"

# Start persistent stop-button notification in background
setsid "$HERE/readout-switch.sh" notify >/dev/null 2>&1 </dev/null &
NOTIFY_PID=$!
disown 2>/dev/null || true

# Session greeting
printf '%s' "$INPUT_JSON" | \
  VOICE_READOUT_START_NOTIFY_PID="$NOTIFY_PID" \
  "$HERE/session-greet.sh" >/dev/null 2>&1 &
disown 2>/dev/null || true

# Return empty JSON object for hook protocol
printf '{}\n'
