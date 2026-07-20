#!/bin/bash
# Auto-recovery watcher: started in the background when a readout fails.
# Probes the TTS engine with a silent call (termux-tts-engines binds the
# engine without making sound) until it responds again, then announces the
# recovery aloud — speak()'s success path also clears the ⚠️ notifications.
# Bounded by MAX_TRIES so it never runs forever.

set -u

source "$(dirname "$0")/tts-lib.sh"

LOCK_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-watcher.pid"

# Single instance: a live PID in the lock file means a watcher is already on it.
if [ -f "$LOCK_FILE" ]; then
  oldpid="$(cat "$LOCK_FILE" 2>/dev/null)"
  case "$oldpid" in
    ""|*[!0-9]*) ;;
    *) kill -0 "$oldpid" 2>/dev/null && exit 0 ;;
  esac
fi
printf '%s' "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

INTERVAL="${VOICE_READOUT_WATCH_INTERVAL:-60}"
MAX_TRIES="${VOICE_READOUT_WATCH_TRIES:-30}"

log watcher "started (interval ${INTERVAL}s, max ${MAX_TRIES} tries)"

tries=0
while [ "$tries" -lt "$MAX_TRIES" ]; do
  sleep "$INTERVAL"
  tries=$(( tries + 1 ))
  precleanup_stuck_tts
  if timeout 15 termux-tts-engines >/dev/null 2>&1; then
    log watcher "engine responding again after ${tries} probe(s)"
    speak "読み上げ、直ったみたいよ。お待たせしちゃってごめんね"
    exit 0
  fi
done

log watcher "gave up after ${MAX_TRIES} probes"
exit 0
