#!/bin/bash
# SessionStart hook: speak a short greeting when a Claude Code session begins,
# so the user hears right away whether the readout path is working. This is the
# first engine call after a possibly-long idle — exactly when the on-device TTS
# is most likely to be wedged. Doing it here (a) gives an audible "it works"
# cue and (b) if it fails, runs the same notify_failure + recovery-watcher
# pipeline a real readout would, so recovery starts at launch instead of only
# on the first response. Registered with "async": true; always exit 0.

set -u

if [ "${VOICE_READOUT_GUARD:-}" = "1" ]; then
  exit 0
fi
export VOICE_READOUT_GUARD=1

source "$(dirname "$0")/tts-lib.sh"

if ! is_enabled STARTUP_GREETING; then
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
    exit 0
    ;;
esac

GREETING="$(get_tuning STARTUP_GREETING_TEXT 'voice-readout、準備できたよ')"

log greeting "session ${SOURCE}: ${GREETING}"

# Goes through speak() like any readout: it honours the stop switch first, uses
# the default backend, and — crucially — if the on-device engine is wedged, its
# failure path fires notify_failure + start_recovery_watcher, so a silent
# launch is not silent about *why*.
speak "$GREETING" 60

exit 0
