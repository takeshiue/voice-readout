#!/bin/bash
# Codex SessionStart wrapper. Claude Code continues to load hooks/hooks.json.
# The shared coordinator posts the Android stop-button notification first, then
# releases the greeting worker after that Termux:API call completes or times
# out. This avoids the start-up request race on both hosts.
exec "$(cd "$(dirname "$0")" && pwd)/session-start.sh"
