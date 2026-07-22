#!/bin/bash
# SessionEnd hook: play a short farewell clip when a Claude Code session
# genuinely ends. Unlike the readouts this is a fixed bundled clip
# (assets/session-end.wav) played via termux-media-player, NOT live TTS: a
# fixed clip needs no engine (so a wedged TTS can't swallow the goodbye),
# starts instantly, and — verified 2026-07-23 — Android's media service keeps
# playing it even after this process is torn down at exit, so the clip finishes
# regardless. Registered WITHOUT async so Claude Code runs it before exiting.

set -u

if [ "${VOICE_READOUT_GUARD:-}" = "1" ]; then
  exit 0
fi
export VOICE_READOUT_GUARD=1

source "$(dirname "$0")/tts-lib.sh"

if ! is_enabled SESSION_END_GREETING; then
  log skip "session-end farewell disabled via toggle"
  exit 0
fi

INPUT_JSON="$(cat)"
REASON="$(printf '%s' "$INPUT_JSON" | jq -r '.reason // empty' 2>/dev/null)"

# "clear" restarts the same session (the SessionStart greeting fires again on
# the way back in), so a goodbye there is just noise. Every other reason —
# exit, logout, prompt_input_exit — is a genuine end of use.
case "$REASON" in
  clear)
    log skip "session-end farewell: reason 'clear' skipped"
    exit 0
    ;;
esac

log farewell "session end (${REASON:-unknown})"

# Fixed clip via termux-media-player. play_notice_clip honours the stop switch,
# copies the asset into the Termux-accessible tmp dir, plays, and waits for it
# to finish. Playback is owned by Android's media service, so it survives this
# process exiting (tested). A farewell is cosmetic — if the clip is missing,
# just skip; it is never worth a live TTS round-trip at exit.
play_notice_clip "$PLUGIN_ROOT_DIR/assets/session-end.wav" || log skip "session-end: clip unavailable"

exit 0
