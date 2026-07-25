#!/bin/bash
# SessionEnd hook: play a short farewell clip when a Claude Code session
# genuinely ends. Unlike the readouts this is a fixed bundled clip
# (assets/session-end.wav) played via termux-media-player, NOT live TTS: a
# fixed clip needs no engine (so a wedged TTS can't swallow the goodbye),
# starts instantly, and — verified 2026-07-23 — Android's media service keeps
# playing it even after this process is torn down at exit, so the clip finishes
# regardless.
#
# The catch (found 2026-07-24): Claude Code aborts synchronous SessionEnd hooks
# a moment into shutdown ("Hook cancelled"), and dispatching the clip takes ~2s
# (source the lib, cp the asset, one termux-media-player round trip) — longer
# than that window, so the play never reached Android and nothing was heard.
# Fix: do the real work in a DETACHED worker (setsid → its own session, so the
# hook's process group being killed can't take it down) and let the hook itself
# return in milliseconds. The hook "completes" instantly; the worker outlives it
# and finishes the dispatch.

set -u

# --- Worker branch: the actual playback, running detached from the hook. ---
if [ "${1:-}" = "__worker" ]; then
  source "$(dirname "$0")/tts-lib.sh"

  if ! is_enabled SESSION_END_GREETING; then
    log skip "session-end farewell disabled via toggle"
    exit 0
  fi

  # "clear" restarts the same session (the SessionStart greeting fires again on
  # the way back in), so a goodbye there is just noise. Every other reason —
  # exit, logout, prompt_input_exit — is a genuine end of use.
  case "${VOICE_READOUT_FAREWELL_REASON:-}" in
    clear)
      log skip "session-end farewell: reason 'clear' skipped"
      exit 0
      ;;
  esac

  log farewell "session end (${VOICE_READOUT_FAREWELL_REASON:-unknown})"

  # Fixed clip via termux-media-player. play_notice_clip honours the stop switch,
  # copies the asset into the Termux-accessible tmp dir, and plays it. nowait:
  # nothing follows the farewell, and playback is owned by Android's media service
  # so it finishes on its own even after this worker exits.
  play_notice_clip "$PLUGIN_ROOT_DIR/assets/session-end.wav" nowait || log skip "session-end: clip unavailable"
  exit 0
fi

# --- Hook branch: parse the reason, spawn the detached worker, return fast. ---
if [ "${VOICE_READOUT_GUARD:-}" = "1" ]; then
  exit 0
fi

source "$(dirname "$0")/tts-lib.sh"

INPUT_JSON="$(cat)"
REASON="$(printf '%s' "$INPUT_JSON" | jq -r '.reason // empty' 2>/dev/null)"

# Show a farewell line in the transcript (the audio is the fixed clip played by
# the worker). Same enable + skip-on-'clear' rules as the clip, but evaluated
# here in the fast hook process: systemMessage only surfaces from a hook Claude
# Code is still watching, and the detached worker's stdout is closed. Sourcing
# the lib is cheap (function defs only) and safe within the millisecond return
# budget the worker split exists to protect.
if is_enabled SESSION_END_GREETING && [ "$REASON" != "clear" ]; then
  announce_user "$(get_tuning SESSION_END_GREETING_TEXT 'ボイスリードアウト、またね')"
fi

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# setsid → new session/process-group so Claude Code killing the hook's group at
# shutdown can't take the worker with it. All fds to /dev/null so Claude Code's
# hook runner sees the pipe close and this process exit immediately, and does not
# wait on (or abort) the still-running worker.
VOICE_READOUT_GUARD=1 VOICE_READOUT_FAREWELL_REASON="$REASON" \
  setsid "$SELF" __worker >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0
