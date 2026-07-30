#!/bin/bash
# Codex SessionEnd wrapper, with the shared farewell and stop-switch cleanup.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INPUT_JSON="$(cat)"
printf '%s' "$INPUT_JSON" | "$HERE/session-farewell.sh"
printf '%s' "$INPUT_JSON" | "$HERE/readout-switch.sh" session-end >/dev/null 2>&1 || true
