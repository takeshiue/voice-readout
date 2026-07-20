#!/bin/bash
# Auto-recovery watcher: started in the background when a readout fails.
# Probes the TTS engine with a silent call (termux-tts-engines binds the
# engine without making sound) until it responds again, then announces the
# recovery aloud — speak()'s success path also clears the ⚠️ notifications.
# Bounded by MAX_TRIES so it never runs forever.

set -u

source "$(dirname "$0")/tts-lib.sh"

LOCK_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-watcher.lock"

# Single instance, race-free: two speak() failures in quick succession each
# call start_recovery_watcher(), and a check-then-write PID file (the old
# approach here) has a gap between reading "no watcher yet" and writing your
# own PID — both can slip through and read "not locked" before either writes,
# leaving two watchers alive at once (observed 2026-07-20: two concurrent
# recovery-watcher.sh processes, each probing and eventually both trying to
# announce recovery). flock's lock+check happens as one atomic kernel op, so
# only one instance can ever hold it.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

# Probing costs an engine binding each time (engine_is_responsive reaps the
# child it leaks, but the attempt itself still lands on a wedged engine), so
# probe sparingly — a tight interval turns "watch for recovery" into "keep the
# engine too busy to recover". 2026-07-20.
INTERVAL="${VOICE_READOUT_WATCH_INTERVAL:-120}"
MAX_TRIES="${VOICE_READOUT_WATCH_TRIES:-30}"

log watcher "started (interval ${INTERVAL}s, max ${MAX_TRIES} tries)"

tries=0
while [ "$tries" -lt "$MAX_TRIES" ]; do
  sleep "$INTERVAL"

  # A legitimate long readout can easily still be speaking 60s later — don't
  # probe over it (see ondevice_call_in_progress's comment for why binding
  # the engine here could interrupt it), and don't count the skip as a try.
  if ondevice_call_in_progress; then
    log watcher "skipping probe: ondevice readout in progress"
    continue
  fi

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
