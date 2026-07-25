#!/bin/bash
# Notification hook: speak a short Japanese phrase when Claude Code is blocked
# waiting on the user (tool permission Yes/No, idle input prompt). The Stop
# hook never fires mid-turn, so without this the session goes silent exactly
# when it needs attention. Registered with "async": true; always exit 0.

set -u

if [ "${VOICE_READOUT_GUARD:-}" = "1" ]; then
  exit 0
fi
export VOICE_READOUT_GUARD=1

source "$(dirname "$0")/tts-lib.sh"

if ! is_enabled NOTIFICATION_READOUT; then
  log skip "notification readout disabled via toggle"
  exit 0
fi

INPUT_JSON="$(cat)"
MESSAGE="$(printf '%s' "$INPUT_JSON" | jq -r '.message // empty' 2>/dev/null)"

log notification "$MESSAGE"

if [ -z "$MESSAGE" ]; then
  log skip "no message in Notification hook input"
  exit 0
fi

# Fixed phrases, one pre-rendered clip each (played below when the notification
# backend is on-device). No LLM call: a permission prompt wants an instant cue.
# Tone belongs to the recording, not to this script — to change how these sound,
# re-record the clips in assets/. There used to be a second, sweeter set of
# phrases here selected by a persona file; it had no clips, so choosing it
# silently downgraded every notification to live TTS.
CLIP=""
case "$MESSAGE" in
  *"permission to use "*)
    # Tool name intentionally dropped: a single pre-rendered clip can't voice
    # a variable name, and "実行許可を求めています" is enough of a prompt.
    PHRASE="実行許可を求めています"
    CLIP="$PLUGIN_ROOT_DIR/assets/notify-permission-request.wav"
    ;;
  *permission*)
    PHRASE="実行許可の確認が待っています"
    CLIP="$PLUGIN_ROOT_DIR/assets/notify-permission.wav"
    ;;
  *"waiting for your input"*|*idle*)
    PHRASE="入力を待っています"
    CLIP="$PLUGIN_ROOT_DIR/assets/notify-idle.wav"
    ;;
  *)
    PHRASE="確認が必要です"
    CLIP="$PLUGIN_ROOT_DIR/assets/notify-generic.wav"
    ;;
esac

# Backend comes from TTS_BACKEND_NOTIFICATION, defaulting to ondevice. It used
# to be hardcoded to ondevice on the reasoning that a permission prompt wants
# an instant cue and a cloud round trip (~5-7s before any sound, measured
# 2026-07-20) defeats that. That reasoning is sound enough to be the default,
# but not to be the only option: it is the user's call, and someone who
# prefers a better voice for their prompts and doesn't mind the delay is
# entitled to choose it.
# Fixed notification phrases ship as pre-rendered clips (nicer voice, no engine
# time, no API call). Play the clip when the notification backend is on-device
# (the default). If the user has picked a cloud backend, honour that choice and
# synthesize live instead.
if [ -n "$CLIP" ] && [ "$(get_tts_backend notification)" = "ondevice" ] && play_notice_clip "$CLIP" nowait; then
  exit 0
fi

speak "$PHRASE" 90 notification

exit 0
