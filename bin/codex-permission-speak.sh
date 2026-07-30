#!/bin/bash
# Codex PermissionRequest hook. Codex has a dedicated permission event.
set -u

if [ "${1:-}" = "__worker" ]; then
  source "$(dirname "$0")/tts-lib.sh"
  is_enabled NOTIFICATION_READOUT || exit 0
  if [ "$(get_tts_backend notification)" = "ondevice" ] \
     && play_notice_clip "$PLUGIN_ROOT_DIR/assets/notify-permission-request.wav" nowait; then
    exit 0
  fi
  speak '実行許可を求めています' 90 notification
  exit 0
fi

source "$(dirname "$0")/json-lib.sh"
INPUT_JSON="$(cat)"
TOOL_NAME="$(json_get_field "$INPUT_JSON" tool_name)"
[ -n "$TOOL_NAME" ] || exit 0

# PermissionRequest is useful only when Codex will actually stop for the
# person at the keyboard. `dontAsk` and `bypassPermissions` proceed without a
# confirmation UI, so announcing a request there is misleading and noisy.
# Keep the notification for modes that can still show an approval prompt:
# default, acceptEdits (Bash/MCP can still need approval), and plan.
#
# Recent Codex versions normally do not emit PermissionRequest at all for the
# two automatic modes. Check defensively nevertheless: it also makes the hook
# correct if an event is delivered while a mode change is in flight.
PERMISSION_MODE="$(json_get_field "$INPUT_JSON" permission_mode)"
case "$PERMISSION_MODE" in
  dontAsk|bypassPermissions)
    exit 0
    ;;
esac

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
VOICE_READOUT_GUARD=1 setsid "$SELF" __worker >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true
