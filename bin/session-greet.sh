#!/bin/bash
# SessionStart hook: speak a short greeting when a Claude Code session begins,
# so the user hears right away whether the readout path is working. This is the
# first engine call after a possibly-long idle — exactly when the on-device TTS
# is most likely to be wedged. Doing it here (a) gives an audible "it works"
# cue and (b) if it fails, runs the same notify_failure + recovery-watcher
# pipeline a real readout would, so recovery starts at launch instead of only
# on the first response. Registered with "async": true; always exit 0.
#
# The greeting is ALSO shown as text in the transcript (announce_user), so the
# session start is visible even when the readout is muted or the audio is off.
# systemMessage only surfaces while Claude Code is still watching the hook, and
# only when that process exits — so the hook itself emits the text and returns
# immediately, handing the actual TTS (which may take seconds) to a detached
# worker. Mirrors session-farewell.sh's setsid worker split.

set -u

# --- Worker branch: the actual TTS (+ recovery pipeline), detached from the hook.
if [ "${1:-}" = "__worker" ]; then
  source "$(dirname "$0")/tts-lib.sh"
  # Goes through speak() like any readout: it honours the stop switch first, uses
  # the default backend, and — crucially — if the on-device engine is wedged, its
  # failure path fires notify_failure + start_recovery_watcher, so a silent
  # launch is not silent about *why*.
  speak "${VOICE_READOUT_GREETING_TEXT:-}" 60
  exit 0
fi

# --- Hook branch: decide, show the text, spawn the detached speaker, return fast.
if [ "${VOICE_READOUT_GUARD:-}" = "1" ]; then
  exit 0
fi

source "$(dirname "$0")/tts-lib.sh"

# A notice left by something that could not show it itself — announce_user only
# renders from a hook process whose stdout is still open, and a detached readout
# worker's is not. Read and cleared here, then folded into this hook's single
# announce_user call: two JSON objects on one hook's stdout would not be valid
# hook output. It is shown but never spoken; the spoken text is passed to the
# worker separately.
PENDING_NOTICE=""
if [ -s "$PENDING_NOTICE_FILE" ]; then
  PENDING_NOTICE="$(cat "$PENDING_NOTICE_FILE" 2>/dev/null)"
  rm -f "$PENDING_NOTICE_FILE" 2>/dev/null
fi

if ! is_enabled STARTUP_GREETING; then
  announce_user "$PENDING_NOTICE"
  log skip "startup greeting disabled via toggle"
  exit 0
fi

INPUT_JSON="$(cat)"
SOURCE="$(printf '%s' "$INPUT_JSON" | jq -r '.source // empty' 2>/dev/null)"

# Greet only when a session is actually beginning to be used — a fresh launch
# (startup) or a resumed one (resume). /clear and post-compact restarts happen
# mid-work, where the engine was just exercised and a greeting is only noise.
case "$SOURCE" in
  startup|resume) ;;
  *)
    log skip "startup greeting: source '${SOURCE:-unknown}' is not startup/resume"
    announce_user "$PENDING_NOTICE"
    exit 0
    ;;
esac

GREETING="$(get_tuning STARTUP_GREETING_TEXT 'ボイスリードアウト、準備できたよ')"

log greeting "session ${SOURCE}: ${GREETING}"

# Show the greeting in the transcript, from this fast-returning hook process so
# it appears immediately (the TTS runs in the detached worker below).
if [ -n "$PENDING_NOTICE" ]; then
  announce_user "${GREETING}
${PENDING_NOTICE}"
else
  announce_user "$GREETING"
fi

# setsid → own session, so nothing tears the speaker down when this hook exits;
# fds to /dev/null so its stdout can't leak into Claude's context.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
VOICE_READOUT_GUARD=1 VOICE_READOUT_GREETING_TEXT="$GREETING" \
  setsid "$SELF" __worker >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0
