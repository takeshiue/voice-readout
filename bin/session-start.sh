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

# The same button, on the platform that has no notification shade. These two are
# mutually exclusive by platform and each no-ops where the other applies:
# readout-switch.sh needs termux-notification, stop-button.sh exits early when
# termux-media-player is present. So both are started unconditionally rather than
# sniffing the OS here.
#
# nohup, not setsid: setsid does not exist in Git Bash (checked 2026-08-18 —
# which is also why the line above silently does nothing on Windows, harmless
# since it is Android-only work). stop-button.sh detaches the PowerShell process
# itself, so this only has to survive long enough to reach that; nohup covers the
# SessionStart hook's own teardown.
nohup "$HERE/stop-button.sh" start >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

printf '%s' "$INPUT_JSON" | \
  VOICE_READOUT_START_NOTIFY_PID="$NOTIFY_PID" \
  "$HERE/session-greet.sh"
