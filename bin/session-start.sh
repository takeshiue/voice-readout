#!/bin/bash
# Coordinate the start notification and greeting without making two Termux:API
# requests race each other. Claude Code runs matching hook handlers in parallel,
# and Termux:API can take seconds to service either request. Starting TTS while
# the persistent stop-button notification was still being posted made the
# notification appear only after the greeting (or much later).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INPUT_JSON="$(cat)"

# Start this first, but never make Claude/Codex wait for Android. The greeting
# worker gets this pid and waits only a short, bounded time before speaking.
# setsid keeps the command alive after this hook returns.
setsid "$HERE/readout-switch.sh" notify >/dev/null 2>&1 </dev/null &
NOTIFY_PID=$!
disown 2>/dev/null || true

printf '%s' "$INPUT_JSON" | \
  VOICE_READOUT_START_NOTIFY_PID="$NOTIFY_PID" \
  "$HERE/session-greet.sh"
