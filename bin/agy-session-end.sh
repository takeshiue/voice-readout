#!/bin/bash
# Antigravity CLI (agy) SessionEnd coordinator.
# Speaks farewell and clears the Android stop notification.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INPUT_JSON="$(cat)"

"$HERE/session-farewell.sh" >/dev/null 2>&1 &
"$HERE/readout-switch.sh" session-end >/dev/null 2>&1 &

printf '{}\n'
