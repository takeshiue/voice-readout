# Shared TTS helpers for voice-readout hooks. Sourced, not executed.
# Callers must be registered with "async": true and must always exit 0.

# split_into_speech_chunks (below) uses bash's ${#s} and ${s:a:b}, which only
# count/slice by Unicode character under a UTF-8-aware locale — otherwise
# they operate byte-wise, and slicing a multi-byte Japanese character in half
# produces invalid UTF-8. That silently corrupted every chunk boundary
# whenever the invoking shell had no locale set (confirmed 2026-07-20: same
# chunk index failing identically across unrelated runs, traced to the
# resulting garbage bytes hanging termux-tts-speak). Force a UTF-8 locale
# here regardless of the caller's environment; C.utf8 needs no
# language-specific locale installed.
export LC_ALL=C.utf8

# The plugin's bundled files (e.g. pre-rendered audio under assets/) sit
# relative to this library, not under CLAUDE_PLUGIN_DATA (the writable per-user
# data dir). Resolved from BASH_SOURCE so it works however the caller was run.
PLUGIN_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
NOTICE_CLIP="${PLUGIN_ROOT_DIR}/assets/overflow-notice.wav"
# Bridge clip for the experimental overflow pipeline (summarize-and-speak.sh):
# spoken between the verbatim opening and the summary. Pre-rendered (Gemini 3.1
# Flash TTS Preview, Aoede) so it's instant and consistent instead of live TTS.
BRIDGE_CLIP="${PLUGIN_ROOT_DIR}/assets/summary-bridge.wav"
# Diagnostic cue played at each cloud chunk boundary when CHUNK_MARKER is on, so
# the split points are audible (speak_cloud_chunked). Default off: it is a
# listening aid for checking chunking/handoff, not part of normal readout.
CHUNK_MARKER_CLIP="${PLUGIN_ROOT_DIR}/assets/chunk-marker.wav"
# Played when a response is nothing but code/URLs, so stripping those leaves no
# prose to read (summarize-and-speak.sh). Silence is indistinguishable from a
# crashed hook for someone who is listening rather than looking.
CODE_ONLY_CLIP="${PLUGIN_ROOT_DIR}/assets/code-only.wav"

# Where this plugin's own state lives: config, API keys, log, locks, the queue.
#
# Claude Code sets CLAUDE_PLUGIN_DATA when it runs a hook, but NOT for anything
# invoked by hand — bin/toggle.sh from a terminal, bin/speak-text.sh, the
# recovery watcher. Every path here used to fall back to /tmp in that case,
# which was wrong twice over. The documented key-setup step (docs/design.md:
# 「ターミナルで bin/toggle.sh gemini-key <キー>」) therefore wrote all three
# cloud API keys into /tmp — a world-writable directory on any shared host —
# and the hooks, which DO have the variable, then read a different file, so the
# key silently never took effect. Both symptoms, one cause.
#
# So: fall back to the plugin's real data directory (the same path
# bin/statusline.sh resolves, for the same reason) and never to /tmp. The
# directory is created 0700 when it doesn't exist yet, because API keys live in
# it.
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  PLUGIN_DATA_DIR="$CLAUDE_PLUGIN_DATA"
elif [ -n "${HOME:-}" ]; then
  # CLAUDE_CONFIG_DIR relocates Claude Code's whole config directory, so the
  # plugin data under it moves too. Honouring it matters for agreement as much
  # as for correctness: statusline.sh resolves the same path independently, and
  # if the two disagree the status line reports settings nothing is reading.
  PLUGIN_DATA_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/voice-readout-voice-readout"
else
  # Neither variable set — a stripped environment no normal run reaches. A
  # shared /tmp is still not somewhere an API key may go, so use a per-uid
  # directory that only its owner can open.
  PLUGIN_DATA_DIR="${TMPDIR:-/tmp}/voice-readout-$(id -u 2>/dev/null || echo 0)"
fi
[ -d "$PLUGIN_DATA_DIR" ] || {
  mkdir -p "$PLUGIN_DATA_DIR" 2>/dev/null && chmod 700 "$PLUGIN_DATA_DIR" 2>/dev/null
}

# Persisted settings live here (written by bin/toggle.sh, seeded by
# `toggle.sh init`). Defined up front because the tuning values below read from
# it. A missing file or missing key falls through to a built-in default, so a
# fresh install works with zero setup.
CONFIG_FILE="${PLUGIN_DATA_DIR}/voice-readout-config"

# Resolve a tuning knob: an explicit env override (VOICE_READOUT_<KEY>) wins for
# throwaway one-off runs, then the value stored in CONFIG_FILE (<KEY>=...), then
# the built-in default. Keeps every tunable visible in one config file while
# still honouring a one-off `VOICE_READOUT_X=… cmd` override.
get_tuning() {
  local key="$1" default="$2" env_name val
  env_name="VOICE_READOUT_${key}"
  val="${!env_name:-}"
  if [ -n "$val" ]; then printf '%s' "$val"; return; fi
  if [ -f "$CONFIG_FILE" ]; then
    val="$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
    [ -n "$val" ] && { printf '%s' "$val"; return; }
  fi
  printf '%s' "$default"
}

# Integer knobs, validated. get_tuning above returns whatever the config file
# says, and several of those values land in a bash arithmetic context — either
# $(( ... )) directly or a ${text:0:$n} slice, which is arithmetic too. Bash
# evaluates an array subscript inside such an expression, and a subscript may
# contain a command substitution, so a config value of
#   TTS_RETRY_WAIT_BASE=w[$(id > /tmp/pwned)]
# executes that command when the retry backoff is computed (verified
# 2026-07-25). That turns "can write the config file" into "runs commands as
# the plugin", which is a much bigger step than it looks. Any value that is not
# a plain non-negative integer falls back to the built-in default — a typo in a
# hand-edited config should give the shipped behaviour, not a broken readout.
get_tuning_num() {
  local key="$1" default="$2" val
  val="$(get_tuning "$key" "$default")"
  case "$val" in
    ''|*[!0-9]*) printf '%s' "$default" ;;
    *)           printf '%s' "$val" ;;
  esac
}

# Decimal knobs. Every timing figure in the playback path is fractions of a
# second, and get_tuning_num is integer-only. Validated with a full-string regex
# rather than a `case` glob because a glob accepts "1.2.3", which reaches awk as
# a syntax error and comes back as an empty `sleep` argument.
get_tuning_dec() {
  local key="$1" default="$2" val out
  val="$(get_tuning "$key" "$default")"
  out="$(awk -v v="$val" 'BEGIN{ if (v ~ /^[0-9]+(\.[0-9]+)?$/) print v }')"
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$default"; fi
}

LOG_FILE="${PLUGIN_DATA_DIR}/voice-readout.log"
# This file is appended to indefinitely across sessions with nothing else
# trimming it, so self-rotate once it grows past a threshold instead of
# growing forever. Two generations are kept (voice-readout.log and .log.1), so
# the threshold is the size of ONE of them and the pair can reach twice it.
LOG_MAX_BYTES="$(get_tuning_num LOG_MAX_BYTES 1048576)"
_log_write() {
  local size=0
  # Guarded on existence rather than relying on `2>/dev/null`: that silences
  # wc's stderr, but a failed `<` redirection is reported by the shell itself
  # and would still print on the very first call of a fresh install.
  if [ -f "$LOG_FILE" ]; then
    size="$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
  else
    # Create the log here at 0600 rather than letting the append below create it
    # at the default umask. What accumulates in this file is a line per response
    # summary and per notification — a running record of the conversation, in
    # plain text, kept indefinitely. The containing directory is 0700, but a
    # directory's mode is the wrong place to rest the whole defence: it is set
    # once at creation and a reinstall or a manual mkdir puts it back to 0755.
    : > "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null
  fi
  case "$size" in *[!0-9]*|"") size=0 ;; esac
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    # Two generations, rotated: the full log becomes .1 and a fresh one starts.
    #
    # This used to keep `tail -n 500` and throw the rest away, which at the
    # observed rate (~500-600 lines a day) meant crossing the 1MB threshold
    # discarded some 9,000 lines to keep about half a day — and the half day
    # you keep is the one you already remember. Anything worth investigating,
    # like a wedge that started three days ago, was gone. Rotating instead puts
    # the floor at one full threshold's worth of history rather than 500 lines.
    #
    # The cost is disk: up to 2 x LOG_MAX_BYTES instead of one. That is the
    # trade being made deliberately, so LOG_MAX_BYTES now budgets a generation,
    # not the total.
    #
    # mv carries the 0600 mode over with the file, and the replacement is
    # created here rather than by the append below, which would use the default
    # umask. Both matter: what is in here is conversation text in the clear.
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
    : > "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null
  fi
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null
}

# Collapsing runs of one repeated line.
#
# With the stop switch held down, every arriving readout logs the same refusal.
# A real day produced 120 consecutive copies of "読み上げ停止中 (stop switch
# pressed while queued)" — around 60% of the file, saying one thing: the switch
# is on. That is not free. It is the history behind it that gets pushed out of
# the rotation window.
#
# So log_repeat() writes the first occurrence and counts the rest, and the run
# is closed by a single summary line the next time anything different is
# logged. Which is why the counter lives in a file: each readout is a separate
# process, so there is nothing in memory for the next one to find.
#
# Deliberately opt-in per call site rather than a blanket rule inside log().
# Identical text does not mean a repeated event: five "[spoke] elevenlabs-tts
# (pipelined, 3 chunks)" lines are five responses actually read aloud, and
# collapsing those would delete real history. Only lines that mean "nothing
# happened, same reason as last time" are passed through here.
#
# Two consequences worth knowing. A pending run stays uncounted in the file
# until something else is logged, so the tail can sit still while the switch is
# held (the first line is already there saying why, and a session start or end
# flushes it). And two readouts logging at the same instant can each bump the
# counter over the other, so the count is a close lower bound, not an exact
# tally — the alternative was locking every write for a diagnostic count.
LOG_REPEAT_STATE="${PLUGIN_DATA_DIR}/voice-readout-log-repeat"

_log_flush_repeat() {
  [ -f "$LOG_REPEAT_STATE" ] || return 0
  local count first last tag msg
  { read -r count; read -r first; read -r last; read -r tag; read -r msg; } \
    < "$LOG_REPEAT_STATE" 2>/dev/null
  rm -f "$LOG_REPEAT_STATE" 2>/dev/null
  case "${count:-0}" in ''|*[!0-9]*|0) return 0 ;; esac
  _log_write "${tag:-info}" "同じ行を ${count} 回省略 (${first} 〜 ${last}): ${msg}"
}

log() {
  _log_flush_repeat
  _log_write "$1" "$2"
}

log_repeat() {
  local now count first last tag msg
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  if [ -f "$LOG_REPEAT_STATE" ]; then
    { read -r count; read -r first; read -r last; read -r tag; read -r msg; } \
      < "$LOG_REPEAT_STATE" 2>/dev/null
    if [ "${tag:-}" = "$1" ] && [ "${msg:-}" = "$2" ]; then
      case "${count:-0}" in ''|*[!0-9]*) count=0 ;; esac
      printf '%s\n%s\n%s\n%s\n%s\n' "$(( count + 1 ))" "${first:-$now}" "$now" "$1" "$2" \
        > "$LOG_REPEAT_STATE" 2>/dev/null
      chmod 600 "$LOG_REPEAT_STATE" 2>/dev/null
      return 0
    fi
    _log_flush_repeat
  fi
  _log_write "$1" "$2"
  printf '%s\n%s\n%s\n%s\n%s\n' 0 "$now" "$now" "$1" "$2" > "$LOG_REPEAT_STATE" 2>/dev/null
  chmod 600 "$LOG_REPEAT_STATE" 2>/dev/null
}

# On/off toggles, controlled via bin/toggle.sh (invoked by asking Claude in
# chat, e.g. "音声読み上げをオフにして"). Missing file or missing key means
# enabled — the feature must work with zero setup on a fresh install.
# (CONFIG_FILE itself is defined near the top, before the tuning helpers.)
is_enabled() {
  local key="$1"
  [ -f "$CONFIG_FILE" ] || return 0
  local val
  val="$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
  [ "$val" != "off" ]
}

# READOUT_SPEED is the ONE speed the user sets: a reading-pace index where 1.0
# means about 300 characters a minute — roughly a news announcer's pace, and
# (by measurement, not design) almost exactly the on-device engine's own default.
# It exists because the four engines do not talk at the same speed: measured
# 2026-07-25 on one 147-character passage with every engine left unadjusted,
#   gemini 361 / elevenlabs 327 / ondevice 305 / inworld 271 characters a minute.
# So "1.3" set per-engine would produce four different speeds. Each engine's own
# knob is therefore derived from the index, scaled by 300/(its own native pace):
#
#   engine      knob                    factor   1.2    1.3
#   ondevice    TTS_RATE                1.01     1.21   1.31
#   inworld     INWORLD_SPEAKING_RATE   1.11     1.33   1.44
#   elevenlabs  ELEVENLABS_ATEMPO       0.92     1.10   1.19
#   gemini      GEMINI_SPEED            0.83     1.00   1.08
#
# It is a guide, not an exact multiplier: the same index varies a few percent
# with the passage and the voice, and gemini's knob is a prompt instruction
# rather than a signal-level control, so it tracks least precisely.
#
# resolve_speed KEY FACTOR — that engine's knob. "auto" (the shipped value)
# derives it from the index; any number set there is an explicit override and
# wins, so a single engine can still be tuned by ear.
resolve_speed() {
  local key="$1" factor="$2" val
  val="$(get_tuning "$key" auto)"
  case "$val" in
    ''|auto) awk -v s="$(get_tuning READOUT_SPEED 1.2)" -v f="$factor" 'BEGIN{printf "%.2f", s*f}' ;;
    *)       printf '%s' "$val" ;;
  esac
}

# Surface a one-line notice to the USER in the Claude Code transcript. The hook
# JSON protocol shows a `systemMessage` field to the user; plain SessionStart
# stdout, by contrast, is fed to Claude's context and never displayed. This also
# renders from an "async": true hook, but only once that hook process exits — so
# callers emit it from the fast-returning hook process, never from a detached
# worker whose stdout is already closed. No-op on empty text or if jq is missing
# (rather than emit broken JSON that would leak into Claude's context instead).
announce_user() {
  local text="$1"
  [ -n "$text" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -cn --arg m "$text" '{systemMessage: $m}'
}

# "summary" (default, one sentence via Haiku) or "full" (verbatim, no LLM).
get_readout_mode() {
  [ -f "$CONFIG_FILE" ] || { echo summary; return; }
  local val
  val="$(grep -E '^READOUT_MODE=' "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
  case "$val" in full) echo full ;; *) echo summary ;; esac
}

# Which engine speak() uses: "ondevice" (Android's on-device TTS, reached via
# Termux:API — this is the delivery pipe's name, not the voice itself; the
# voice is whichever Android TTS engine is set as default, currently Google's),
# "gemini" (Gemini API's TTS models, requires network + API key, set via
# `toggle.sh gemini-key`), "inworld" (Inworld's Realtime TTS-1.5 Mini, requires
# network + API key, set via `toggle.sh inworld-key`), or "elevenlabs"
# (ElevenLabs' eleven_flash_v2_5 model, requires network + API key, set via
# `toggle.sh elevenlabs-key`). Any stored value other than these three
# (including the old "termux" name from before the rename) falls back to
# "ondevice", so old config files stay compatible. Env var override takes
# priority for one-off testing without touching the config.
#
# Chosen per function, not once for the whole plugin. The four things this
# plugin speaks — a notification, a summary of a response, a response in
# full, an external file — are separate choices that belong to the user; the
# plugin does not get to decide that, say, notifications "should" be
# on-device because they are short. Anyone who wants a nicer cloud voice for
# their permission prompts is entitled to it.
#
# Resolution order, most specific first:
#   VOICE_READOUT_TTS_BACKEND      env, overrides everything (one-off tests)
#   TTS_BACKEND_<FUNCTION>=        config, this function's choice
#   TTS_BACKEND=                   config, the older single setting
#   ondevice                       default
#
# Defaults are all "ondevice" deliberately: it needs no API key, no network,
# and starts speaking immediately, so a fresh install is useful with zero
# setup. Users don't know an application's internals — the out-of-the-box
# configuration has to be the convenient one, with customisation available
# to whoever wants it.
FUNCTION_KEYS="notification summary full file"
get_tts_backend() {
  local fn="${1:-}"
  if [ -n "${VOICE_READOUT_TTS_BACKEND:-}" ]; then
    echo "$VOICE_READOUT_TTS_BACKEND"
    return
  fi
  local val=""
  if [ -f "$CONFIG_FILE" ]; then
    if [ -n "$fn" ]; then
      local key
      key="TTS_BACKEND_$(printf '%s' "$fn" | tr '[:lower:]' '[:upper:]')"
      val="$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
    fi
    # Falling back to the global TTS_BACKEND keeps config files written
    # before per-function keys existed working exactly as they did.
    if [ -z "$val" ]; then
      val="$(grep -E '^TTS_BACKEND=' "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
    fi
  fi
  case "$val" in
    gemini) echo gemini ;;
    inworld) echo inworld ;;
    elevenlabs) echo elevenlabs ;;
    *) echo ondevice ;;
  esac
}

# All cloud-backend API keys live together in one env file (KEY=VALUE per
# line), written/cleared via bin/toggle.sh's *-key subcommands. Read with
# `cut -d= -f2-` (not -f2): base64 keys end in "=" padding, so splitting on
# every "=" instead of just the first would truncate the value.
ENV_FILE="${PLUGIN_DATA_DIR}/voice-readout.env"
get_env_value() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Legacy per-key file from before keys were consolidated into voice-readout.env
# (kept so installs that already ran `toggle.sh gemini-key` don't lose it).
GEMINI_KEY_FILE_LEGACY="${PLUGIN_DATA_DIR}/voice-readout-gemini-key"
get_gemini_api_key() {
  if [ -n "${VOICE_READOUT_GEMINI_API_KEY:-}" ]; then
    printf '%s' "$VOICE_READOUT_GEMINI_API_KEY"
    return
  fi
  local val
  val="$(get_env_value GEMINI_API_KEY)"
  if [ -n "$val" ]; then
    printf '%s' "$val"
  elif [ -s "$GEMINI_KEY_FILE_LEGACY" ]; then
    cat "$GEMINI_KEY_FILE_LEGACY"
  fi
}

get_inworld_api_key() {
  if [ -n "${VOICE_READOUT_INWORLD_API_KEY:-}" ]; then
    printf '%s' "$VOICE_READOUT_INWORLD_API_KEY"
    return
  fi
  get_env_value INWORLD_API_KEY
}

get_elevenlabs_api_key() {
  if [ -n "${VOICE_READOUT_ELEVENLABS_API_KEY:-}" ]; then
    printf '%s' "$VOICE_READOUT_ELEVENLABS_API_KEY"
    return
  fi
  get_env_value ELEVENLABS_API_KEY
}

# Opens the Android app-info screen where the 強制停止 button lives. Actually
# force-stopping another app needs root, so one tap into that screen is the
# best we can do. Two candidates: the hang is usually in Google's TTS engine,
# but a wedged binding can also survive inside the Termux:API app itself —
# force-stopping only the Google side then fixes nothing (seen 2026-07-20).
GOOGLE_TTS_INTENT="am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:com.google.android.tts"
TERMUX_API_INTENT="am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:com.termux.api"

notify_failure() {
  command -v termux-notification >/dev/null 2>&1 || return 0

  # A stuck engine fails on every response, which used to fire one
  # notification per response. Suppress repeats within the cooldown window.
  local stamp_file="${PLUGIN_DATA_DIR}/voice-readout-last-notify"
  local cooldown="$(get_tuning_num NOTIFY_COOLDOWN 1800)"
  local now last
  now="$(date +%s)"
  last="$(cat "$stamp_file" 2>/dev/null || echo 0)"
  case "$last" in *[!0-9]*|"") last=0 ;; esac
  if [ $(( now - last )) -lt "$cooldown" ]; then
    log skip "failure notification suppressed (cooldown ${cooldown}s)"
    return 0
  fi
  printf '%s' "$now" > "$stamp_file" 2>/dev/null

  # One notification, two buttons — not two separate notifications. Two
  # separate notifications (an earlier design) actively conflicted on-device:
  # tapping either one's action dismissed the other before it could be used
  # too. Merging them into one fixed that, but exposed a second issue: Android
  # auto-cancels a notification once one of its buttons is pressed, so trying
  # button1 first still took the whole notification (and button2) away before
  # button2 could be tried (seen 2026-07-20). --ongoing marks it persistent,
  # which keeps it (and both buttons) around across a button press — cleared
  # only by clear_failure_notifications() once a readout actually succeeds.
  termux-notification \
    --id voice-readout-fix \
    --title "⚠️ 読み上げ停止 まず①、直らなければ②も" \
    --content "①Termux:APIを強制停止（これで直ることが多いです）。直らなければ②Google音声も同様に" \
    --priority high \
    --ongoing \
    --action "$TERMUX_API_INTENT" \
    --button1 "①Termux:API" \
    --button1-action "$TERMUX_API_INTENT" \
    --button2 "②Google音声" \
    --button2-action "$GOOGLE_TTS_INTENT" \
    2>/dev/null
}

# Launch the auto-recovery watcher in the background (single-instance guard
# lives inside the watcher itself). Detached so the async hook can exit.
start_recovery_watcher() {
  local watcher
  watcher="$(dirname "${BASH_SOURCE[0]}")/recovery-watcher.sh"
  [ -f "$watcher" ] || return 0
  nohup bash "$watcher" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# Once a readout succeeds again, recovery instructions are stale — clear them
# and reset the cooldown so the next hang episode notifies promptly.
clear_failure_notifications() {
  local stamp_file="${PLUGIN_DATA_DIR}/voice-readout-last-notify"
  [ -f "$stamp_file" ] || return 0
  rm -f "$stamp_file" 2>/dev/null
  if command -v termux-notification-remove >/dev/null 2>&1; then
    termux-notification-remove voice-readout-fix 2>/dev/null
    log info "cleared recovery notifications after successful readout"
  fi
}

# Tracks the ondevice call currently in flight, as "pid:deadline_epoch",
# written by speak()'s ondevice branch right before it invokes
# termux-tts-speak. Lets a later invocation tell a legitimately-still-speaking
# process from a truly stuck one (see precleanup_stuck_tts below) instead of
# guessing from process liveness alone.
ONDEVICE_LOCK_FILE="${PLUGIN_DATA_DIR}/voice-readout-ondevice.lock"

# Epoch seconds of the last fully-successful on-device readout. Used to skip the
# ~2s preflight probe when the engine was confirmed working very recently (it is
# still warm, so re-probing it only adds latency to every follow-up readout in
# an active conversation). Written on success below; read at the preflight gate.
ONDEVICE_LASTSPOKE_FILE="${PLUGIN_DATA_DIR}/voice-readout-ondevice-lastspoke"

# Termux wake lock for on-device readouts (why it is taken at all: see the call
# site in speak()). Normally the same speak() call takes and releases it, but
# every termux-* invocation is a ~1.9s Termux:API round trip, and speak_hybrid
# makes several speak() calls in a row and then hands the readout to a cloud
# voice. Paying the release per unit put that round trip squarely in the seam
# between the two voices, where it is silence the listener hears (measured
# 2026-07-27: ~2s of the ~7s handover gap). A caller that owns the whole
# readout sets VOICE_READOUT_KEEP_WAKELOCK=1 to hold the lock across its calls
# and release it once, after the last sound, where nobody is waiting on it.
_ONDEVICE_WAKELOCK_HELD=""

ondevice_wake_lock() {
  [ "${_ONDEVICE_WAKELOCK_HELD:-}" = "1" ] && return 0
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
  # Only remembered as held when someone is keeping it: otherwise the matching
  # unlock below runs and the flag would be a lie by the next call.
  [ "${VOICE_READOUT_KEEP_WAKELOCK:-}" = "1" ] && _ONDEVICE_WAKELOCK_HELD=1
  return 0
}

ondevice_wake_unlock() {
  [ "${VOICE_READOUT_KEEP_WAKELOCK:-}" = "1" ] && return 0
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null
  _ONDEVICE_WAKELOCK_HELD=""
  return 0
}

# Release a lock that was held across several speak() calls, whatever exit path
# the holder took. A no-op when nothing is held, so it is safe to call blindly.
ondevice_wake_unlock_held() {
  [ "${_ONDEVICE_WAKELOCK_HELD:-}" = "1" ] || return 0
  _ONDEVICE_WAKELOCK_HELD=""
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null
  return 0
}

# Marks a response readout as in flight, as "pid:deadline_epoch" (same shape as
# ONDEVICE_LOCK_FILE above). Exists because termux-media-player is a single
# global player: starting a notice clip stops whatever is already playing.
# Claude Code raises its idle Notification 60s after it begins waiting for
# input, and that timer knows nothing about the readout — so a readout longer
# than a minute could be cut off mid-sentence by its own idle notice, with the
# remaining chunks lost and the readout still logging success (observed
# 2026-07-25: a 431-char response cut at 60s, ~half of the last chunk never
# heard). The Notification hook checks this marker and drops the idle notice
# while a readout is speaking; the audio ending is itself the cue that it is
# the user's turn.
SPEAKING_MARKER_FILE="${PLUGIN_DATA_DIR}/voice-readout-speaking"
# Identifies this readout in the names of its chunk audio files, so two
# readouts can never write to each other's (see _cloud_audio_path). The pid is
# stable across the background generator subshells, which is what makes it
# usable as the shared key: $$ is the parent's pid inside a subshell.
VOICE_READOUT_RUN_ID="${VOICE_READOUT_RUN_ID:-$$}"
# Hard ceiling on how long the marker may silence idle notices. Belt and
# braces with the liveness check below: a marker that outlives its process
# must never mute notifications permanently.
SPEAKING_MARKER_MAX=900

# Readouts queue; they do not interrupt each other. Only one can be audible
# anyway — termux-media-player is a single global player — so when a response
# arrives while an earlier one is still being read, something has to give.
# This waits: the earlier readout finishes, then the later one starts.
#
# The alternative, dropping the earlier readout in favour of the newer one, was
# implemented first and was wrong. It assumed that interrupting means the user
# is done listening, which is a guess about intent. This is a readout, not a
# conversation: reading things in the order they were produced is the behaviour
# a listener can actually follow, and one that reads in order is self-evidently
# still working through the backlog. Nothing has to be inferred.
#
# The queue is a directory of one file per waiting readout, named
# "<nanoseconds>.<pid>" so a plain sort is arrival order and no lock is needed
# to join. A readout speaks once it is at the head and nobody holds the
# speaking marker.
READOUT_QUEUE_DIR="${PLUGIN_DATA_DIR}/voice-readout-queue"
# Longest a queued readout waits for its turn before going ahead regardless.
# Only reachable if a predecessor wedges in a way the liveness checks miss;
# speaking late beats never speaking.
READOUT_QUEUE_MAX_WAIT=900
READOUT_QUEUE_TICKET=""

# Drops tickets whose process is gone, so one crashed readout cannot stall
# every readout behind it.
_readout_queue_prune() {
  local t pid
  for t in "$READOUT_QUEUE_DIR"/*.*; do
    [ -e "$t" ] || continue
    pid="${t##*.}"
    case "$pid" in ''|*[!0-9]*) rm -f "$t" 2>/dev/null; continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -f "$t" 2>/dev/null
  done
}

_readout_queue_head() {
  _readout_queue_prune
  local t
  for t in "$READOUT_QUEUE_DIR"/*.*; do
    [ -e "$t" ] || continue
    printf '%s' "$t"
    return 0
  done
  return 1
}

# Take a ticket, wait for our turn, then claim the speaking marker.
readout_speaking_begin() {
  mkdir -p "$READOUT_QUEUE_DIR" 2>/dev/null
  # Nanosecond precision plus the pid: two readouts cannot collide, and the
  # name sorts by arrival, which is the whole ordering mechanism.
  READOUT_QUEUE_TICKET="$READOUT_QUEUE_DIR/$(date +%s%N).$$"
  : > "$READOUT_QUEUE_TICKET" 2>/dev/null

  local waited=0 announced=""
  while [ "$waited" -lt "$READOUT_QUEUE_MAX_WAIT" ]; do
    # A queued readout is as droppable as a speaking one: someone reaching for
    # 停止 wants silence, not silence followed by the backlog.
    if [ -e "$STOP_SWITCH_FILE" ]; then
      readout_queue_leave
      return 1
    fi
    if [ "$(_readout_queue_head)" = "$READOUT_QUEUE_TICKET" ] && ! readout_is_speaking; then
      break
    fi
    [ -z "$announced" ] && { log info "queued behind an in-progress readout"; announced=1; }
    sleep 1
    waited=$(( waited + 1 ))
  done
  [ "$waited" -ge "$READOUT_QUEUE_MAX_WAIT" ] && log fallback "queue wait exceeded ${READOUT_QUEUE_MAX_WAIT}s, speaking anyway"
  [ -n "$announced" ] && log info "queue: our turn after ${waited}s"

  printf '%s:%s' "$$" "$(( $(date +%s) + SPEAKING_MARKER_MAX ))" \
    > "$SPEAKING_MARKER_FILE" 2>/dev/null || true
  return 0
}

readout_queue_leave() {
  [ -n "$READOUT_QUEUE_TICKET" ] && rm -f "$READOUT_QUEUE_TICKET" 2>/dev/null
  READOUT_QUEUE_TICKET=""
  return 0
}

# Clears only our own marker. A readout that overran its deadline may already
# have been replaced, and removing the newer readout's marker would re-open the
# very gap this is here to close. Always give up our queue ticket too, so the
# readout behind us starts immediately.
readout_speaking_end() {
  local rec
  rec="$(cat "$SPEAKING_MARKER_FILE" 2>/dev/null || true)"
  [ "${rec%%:*}" = "$$" ] && rm -f "$SPEAKING_MARKER_FILE" 2>/dev/null
  readout_queue_leave
  return 0
}

readout_is_speaking() {
  local rec pid deadline now
  rec="$(cat "$SPEAKING_MARKER_FILE" 2>/dev/null || true)"
  [ -n "$rec" ] || return 1
  pid="${rec%%:*}"
  deadline="${rec##*:}"
  # Stale in three ways: unparseable, the readout process is gone, or it has
  # run past any plausible readout length. Clear it in every case rather than
  # letting a leftover file mute the notification hook for good.
  case "${pid}${deadline}" in ''|*[!0-9]*) rm -f "$SPEAKING_MARKER_FILE" 2>/dev/null; return 1 ;; esac
  now="$(date +%s)"
  if ! kill -0 "$pid" 2>/dev/null || [ "$now" -ge "$deadline" ]; then
    rm -f "$SPEAKING_MARKER_FILE" 2>/dev/null
    return 1
  fi
  return 0
}

# Longest text the on-device engine reliably finishes — see the ceiling check
# in speak() for how this number was arrived at. Exposed as a function so
# callers that would rather shorten their text than be refused (the Stop
# hook's summary path) can ask instead of hardcoding it.
ondevice_max_chars() {
  printf '%s' "$(get_tuning_num ONDEVICE_MAX_CHARS 240)"
}

# Spoken as a short preface when an over-length readout is degraded to a summary
# (see the on-device ceiling in speak()). Lets a listener who asked for the full
# text or a file know they are hearing a summary instead of the whole thing.
# Deliberately a fixed Japanese system message (no per-language
# variants): Japanese is the most compact — the same wording in English runs
# nearly twice the character count against the on-device ceiling — and the
# summary that follows is always Japanese too, so the two stay consistent.
READOUT_OVERFLOW_NOTICE="${VOICE_READOUT_OVERFLOW_NOTICE:-長文のため要約にします。}"

# Bridge phrase spoken between the verbatim opening and the summary in the
# experimental overflow pipeline (summarize-and-speak.sh, toggle OVERFLOW_PIPELINE).
OVERFLOW_PIPELINE_BRIDGE="${VOICE_READOUT_OVERFLOW_PIPELINE_BRIDGE:-残りは要約します。}"

# Spoken when the response was all code and nothing readable survived cleaning.
# Says only that there is nothing to read aloud — it must not claim what the
# code did, which this script has no way of knowing.
READOUT_CODE_ONLY_NOTICE="${VOICE_READOUT_CODE_ONLY_NOTICE:-コードだけだから、読み上げるところはないよ。}"

# Play a pre-rendered fixed-phrase clip (a bundled .wav) through the phone
# speaker, returning 0 if it played and 1 if the clip is unavailable so the
# caller can fall back to live TTS of the phrase. These "決まり文句" are
# rendered once with a good cloud voice and shipped in assets/, so they cost no
# API call and no engine time at readout.
#
# Two constraints mirror speak_gemini(): termux-media-player is the only path to
# the real speaker (no /dev/snd in this proot), and Termux:API can only open
# files under $TERMUX_HOME/storage — the bundled asset lives on the proot side,
# so copy it into the Termux scratch dir first. The stop switch is honoured up
# front so a fixed cue can't slip through after the user has silenced readout.
# The optional 2nd arg picks how the clip is timed:
#   wait   (default) — block until the clip finishes, then stop the player, so a
#          readout that FOLLOWS the clip (the overflow summary, the pipeline
#          summary) can't talk over it. Costs extra termux-media-player round
#          trips (info poll + stop), ~2s each.
#   nowait — the clip is terminal: nothing is spoken after it (a notification
#          cue, the recovery announce, the session-end farewell). Don't poll and
#          don't stop — every termux-media-player sub-command is a ~2s Termux:API
#          round trip, and here they buy nothing. `play` hands the clip to
#          Android's media service, which finishes it on its own even after this
#          process exits (verified with the session-end clip). This is what makes
#          a fixed notification cue sound promptly instead of ~8s later.
play_notice_clip() {
  local clip="$1"
  local mode="${2:-wait}"
  [ -e "$STOP_SWITCH_FILE" ] && return 0
  [ -f "$clip" ] || return 1
  command -v termux-media-player >/dev/null 2>&1 || return 1
  local termux_home="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}"
  local scratch_dir="$termux_home/.voice-readout-tmp"
  [ -d "$scratch_dir" ] || { mkdir -p "$scratch_dir" 2>/dev/null && chmod 700 "$scratch_dir" 2>/dev/null; } || return 1
  local dest="$scratch_dir/$(basename "$clip")"
  # Same guard as gen_cloud: a fixed name in a shared directory, so clear
  # whatever is at it before copying rather than following a link.
  rm -f "$dest" 2>/dev/null
  cp "$clip" "$dest" 2>/dev/null || return 1
  if ! termux-media-player play "$dest" >/dev/null 2>&1; then
    rm -f "$dest"
    return 1
  fi
  if [ "$mode" = "nowait" ]; then
    # Leave $dest in place: the media service is still reading it, and the next
    # clip of the same basename just overwrites it. Don't rm mid-playback.
    log spoke "notice clip ($(basename "$clip"), nowait)"
    return 0
  fi
  # Poll until it stops so the readout that follows doesn't talk over the clip.
  # Bounded so a stuck player can't hang the hook.
  local waited=0
  while [ "$waited" -lt 15 ]; do
    sleep 1
    waited=$(( waited + 1 ))
    termux-media-player info 2>/dev/null | grep -q 'Status: Playing' || break
  done
  termux-media-player stop >/dev/null 2>&1
  rm -f "$dest"
  log spoke "notice clip ($(basename "$clip"), ${waited}s)"
  return 0
}

# A libexec/termux-api TextToSpeech process still running past its own
# recorded deadline is stuck (a healthy call always finishes within the
# timeout speak() wrapped it in) and safe to SIGKILL. But one still inside its
# deadline is presumably mid-utterance — killing it here used to be exactly
# how a *new* invocation clobbered a working readout (multiple invocations —
# the Stop-hook's per-response readout, a manual speak-text.sh test, the
# recovery watcher's own probe — all called this on every attempt, 2026-07-20
# session). Worse, SIGKILL lands mid-Binder-transaction with Android's TTS
# service, which is itself a plausible cause of the "Termux:API holds a wedged
# connection" state the README describes — i.e. the blind-kill design here
# risked being the thing that kept re-breaking the engine it was meant to
# unstick. Returns 0 = caller may proceed (nothing running, or a stale one was
# just cleared), 1 = a live in-progress call holds the slot; caller must skip.
# True while a legitimate ondevice call is still inside its recorded
# deadline. Shared by precleanup_stuck_tts (don't kill it) and
# recovery-watcher.sh (don't probe over it either — termux-tts-engines binds
# the engine to check it, and doing that mid-utterance risks stealing the
# engine binding out from under the call that's actually speaking, which
# would look identical to "the engine hung" from the outside).
# The lock file — not the momentary presence of a TextToSpeech process — is
# the authority on "a readout is underway". Deriving it from a live process
# (the previous design) had a hole exactly where it mattered: between two
# chunks of a multi-chunk readout no TextToSpeech process exists for a
# moment, so this reported "idle", and whoever asked during that window
# (recovery-watcher.sh's periodic probe, or another invocation's precleanup)
# felt free to bind or kill the engine — landing right on top of the next
# chunk. That is what made a long readout fail reproducibly at whichever
# chunk happened to line up with the watcher's 60s probe interval
# (chunk 3, repeatedly, 2026-07-20), which read as "the engine hangs" but
# was self-inflicted. speak() holds this lock across the whole batch,
# refreshing the deadline around every attempt and every recovery wait, so
# it stays true through the inter-chunk gaps too.
ondevice_call_in_progress() {
  local owner deadline
  [ -f "$ONDEVICE_LOCK_FILE" ] || return 1
  owner="$(cut -d: -f1 "$ONDEVICE_LOCK_FILE" 2>/dev/null)"
  deadline="$(cut -d: -f2 "$ONDEVICE_LOCK_FILE" 2>/dev/null)"
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  case "$deadline" in ''|*[!0-9]*) return 1 ;; esac
  # A crashed owner must not keep the slot reserved forever, and a deadline
  # that has passed means the batch is over (or wedged) either way.
  kill -0 "$owner" 2>/dev/null || return 1
  [ "$(date +%s)" -lt "$deadline" ]
}

precleanup_stuck_tts() {
  # Asked before touching anything, and independently of whether a
  # TextToSpeech process happens to exist right now — see above.
  if ondevice_call_in_progress; then
    return 1
  fi

  local pids
  pids="$(ps aux 2>/dev/null | awk '$0 ~ /libexec\/termux-api TextToSpeech/ && $0 !~ /awk|grep/ {print $2}')"
  [ -z "$pids" ] && { rm -f "$ONDEVICE_LOCK_FILE" 2>/dev/null; return 0; }

  kill -9 $pids 2>/dev/null
  rm -f "$ONDEVICE_LOCK_FILE" 2>/dev/null
  return 0
}

# Cheap liveness probe reused from recovery-watcher.sh's technique: binds the
# TTS engine without producing sound, so a wedged engine is detected in
# seconds instead of only after a full-length termux-tts-speak call times out
# (which, for a long full-mode readout, could mean minutes before anyone —
# user or notify_failure — learns something is wrong).
engine_is_responsive() {
  # </dev/null: termux-* wrappers drain any stdin they inherit, which would
  # eat a caller's loop input (see the chunk-array comment in speak()).
  if timeout "$(get_tuning_num PREFLIGHT_TIMEOUT 10)" termux-tts-engines >/dev/null 2>&1 </dev/null; then
    return 0
  fi
  # timeout signals the sh wrapper; the libexec/termux-api grandchild it
  # spawned survives and keeps holding the engine binding it was waiting on.
  # Left alone these accumulate one per probe and smother the very engine the
  # probe is trying to find alive again (2026-07-20). Reap ours before
  # reporting failure — matched narrowly on LIST_AVAILABLE so this can never
  # touch a TextToSpeech process that is actually speaking.
  local probe_pids
  probe_pids="$(ps aux 2>/dev/null | awk '$0 ~ /libexec\/termux-api TextToSpeech/ && $0 ~ /LIST_AVAILABLE/ && $0 !~ /awk|grep/ {print $2}')"
  [ -n "$probe_pids" ] && kill -9 $probe_pids 2>/dev/null
  return 1
}

# Splits text into sentence-bounded chunks (each capped at roughly $max
# characters, but never cut mid-sentence) so a full-mode readout is many
# short termux-tts-speak calls instead of one long one. A single ~80s call
# consistently produced a "Termux:API Error: Error in ResultReturner" toast
# right around completion — confirmed via screenshot, 2026-07-20 — even
# though the call itself still reported success; short calls (a one-sentence
# summary, a "テスト" probe) never showed it. That points to Termux:API's
# result-return channel not surviving a call that runs this long, which
# per-call wake-locking (tried first) didn't fix, since the wake lock covers
# this shell's process, not the separate com.termux.api app. Chunking keeps
# every individual call short regardless of how long the whole text is.
# Printed NUL-separated so a chunk's own whitespace/newlines survive the
# caller's `read -r -d ''` loop.
split_into_speech_chunks() {
  local text="$1" max="$2"
  # Optional 3rd arg: a smaller cap for the FIRST emitted chunk only, so a cloud
  # readout can start speaking sooner (short first chunk = quick first audio)
  # while later chunks stay large (fewer termux-media-player play round-trips —
  # the dominant inter-chunk gap). Defaults to $max, i.e. uniform chunks.
  local first_max="${3:-$max}"
  local flat
  flat="$(printf '%s' "$text" | tr '\n' ' ')"

  # Pass 1 (awk): cut after every 。！？ into raw sentences. mawk's length()
  # is byte-, not character-, based, so it can't be trusted to enforce $max
  # on Japanese text — this pass only splits, it doesn't size-check.
  local sentences=()
  local s
  while IFS= read -r -d '' s; do
    [ -n "$s" ] && sentences+=("$s")
  done < <(printf '%s' "$flat" | awk '
    { buf = buf $0 }
    END {
      gsub(/。/, "。\x02", buf); gsub(/！/, "！\x02", buf); gsub(/？/, "？\x02", buf)
      n = split(buf, a, "\x02")
      for (i = 1; i <= n; i++) if (a[i] != "") printf "%s%c", a[i], 0
    }')

  # Pass 2 (bash, character-aware via ${#s}): a sentence with no internal 。
  # (e.g. one containing a quoted clause) can still be far longer than $max
  # on its own — that's what let a 195-character chunk through and fail
  # twice in a row despite the $max=100 target (2026-07-20). Break those
  # further on 、, and hard-slice anything still too long as a last resort.
  local pieces=()
  for s in "${sentences[@]}"; do
    s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -n "$s" ] || continue
    if [ "${#s}" -le "$max" ]; then
      pieces+=("$s")
      continue
    fi
    local commaparts=() part idx=0 last
    IFS='、' read -ra commaparts <<< "$s"
    last=$(( ${#commaparts[@]} - 1 ))
    for part in "${commaparts[@]}"; do
      [ "$idx" -lt "$last" ] && part="${part}、"
      idx=$(( idx + 1 ))
      while [ "${#part}" -gt "$max" ]; do
        pieces+=("${part:0:$max}")
        part="${part:$max}"
      done
      [ -n "$part" ] && pieces+=("$part")
    done
  done

  # Pass 3: greedily re-merge consecutive short pieces back up toward $max,
  # so unrelated clauses that are individually tiny don't each get their own
  # termux-tts-speak call.
  local chunk="" p emitted=0 lim
  for p in "${pieces[@]}"; do
    # First chunk fills only to first_max; every later chunk to max.
    [ "$emitted" -eq 0 ] && lim="$first_max" || lim="$max"
    if [ -n "$chunk" ] && [ $(( ${#chunk} + ${#p} )) -gt "$lim" ]; then
      printf '%s\0' "$chunk"
      emitted=1
      chunk="$p"
    else
      chunk="${chunk}${p}"
    fi
  done
  [ -n "$chunk" ] && printf '%s\0' "$chunk"
}

# POST JSON to a cloud TTS API without putting the API key — or the text being
# read aloud — on the command line.
#
# A process's arguments are world-readable through /proc/<pid>/cmdline (mode
# 444), so `curl -H "xi-api-key: $key"` published the key to every process on
# the device for the length of the request, and `-d "$payload"` did the same
# for the response text about to be spoken (both verified 2026-07-25 by
# snapshotting ps mid-request). File permissions cannot help with this: the
# exposure is in the process table, not on disk.
#
# curl reads options from stdin with `--config -`, and nothing read there ever
# reaches argv. The request body goes through a 0600 temp file for the same
# reason. Gemini's key moves from the URL query string into a header at the
# same time — a URL is additionally logged by proxies and servers, which is
# why Google documents the header form.
#
# Values in a curl config file are quoted, and inside those quotes curl treats
# \ and " as escapes — so both are escaped here. Without that, a key
# containing either arrives truncated (verified against a local server: a test
# key was cut at its first quote).
#
# cloud_post URL AUTH_HEADER PAYLOAD OUTFILE
#   Response body to OUTFILE, HTTP status code to stdout, curl's exit status
#   as the return value.
cloud_post() {
  local url="$1" auth="$2" payload="$3" out="$4" body esc rc
  # Prefer the plugin's own 0700 data dir over a shared /tmp; fall back only if
  # that is somehow unusable, since failing here would silence the readout.
  body="$(mktemp "${PLUGIN_DATA_DIR}/vr-req.XXXXXX" 2>/dev/null \
          || mktemp "${TMPDIR:-/tmp}/vr-req.XXXXXX")" || return 1
  chmod 600 "$body" 2>/dev/null
  printf '%s' "$payload" > "$body"
  esc="$(printf '%s' "$auth" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  curl -sS --max-time "$(get_tuning_num CLOUD_HTTP_TIMEOUT 45)" \
    -X POST "$url" \
    -H 'Content-Type: application/json' \
    -d "@$body" \
    -o "$out" -w '%{http_code}' \
    --config - <<CURLCFG
header = "$esc"
CURLCFG
  rc=$?
  rm -f "$body"
  return "$rc"
}

# Model ids are vendor identifiers — letters, digits, dot, dash, underscore —
# and go straight into a URL path or a JSON field. Anything else arriving from
# the config file is a typo or an attempt to point the request somewhere it was
# not meant to go, so fall back to the shipped default rather than sending it.
# sanitize_model VALUE DEFAULT
sanitize_model() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) printf '%s' "$2" ;;
    *)                    printf '%s' "$1" ;;
  esac
}

# Gemini API TTS: sends text to a Gemini-TTS model, gets back raw PCM audio
# (16-bit, 24kHz, mono, no WAV header — see Gemini API speech-generation
# docs), wraps it as a WAV and plays it via termux-media-player. Needs
# network + an API key from Google AI Studio; falls back to the ondevice
# backend on any failure so an API outage or a missing key doesn't go silent.
speak_gemini() {
  local text="$1"
  local cap="$2"
  local api_key
  api_key="$(get_gemini_api_key)"
  if [ -z "$api_key" ]; then
    log error "gemini backend selected but no API key set (toggle.sh gemini-key <KEY>)"
    return 1
  fi
  if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v termux-media-player >/dev/null 2>&1; then
    log error "gemini backend needs ffmpeg + termux-media-player, one is missing"
    return 1
  fi

  local model; model="$(sanitize_model "${VOICE_READOUT_GEMINI_MODEL:-gemini-2.5-flash-preview-tts}" gemini-2.5-flash-preview-tts)"
  local voice="${VOICE_READOUT_GEMINI_VOICE:-Kore}"
  local payload response audio_b64

  payload="$(jq -n --arg text "$text" --arg voice "$voice" '{
    contents: [{parts: [{text: $text}]}],
    generationConfig: {
      responseModalities: ["AUDIO"],
      speechConfig: {voiceConfig: {prebuiltVoiceConfig: {voiceName: $voice}}}
    }
  }')"

  # 20s used to be enough, but a long full-mode readout (200+ chars) can
  # legitimately take Gemini past that and curl aborts with an empty body,
  # which reads as a generic API failure — observed 2026-07-20 benchmarking.
  # Key and body both stay off the command line — see cloud_post.
  local resp_file http
  resp_file="$(mktemp "${PLUGIN_DATA_DIR}/vr-resp.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/vr-resp.XXXXXX")" || return 1
  chmod 600 "$resp_file" 2>/dev/null
  http="$(cloud_post "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
                     "x-goog-api-key: ${api_key}" "$payload" "$resp_file")"
  audio_b64="$(jq -r '.candidates[0].content.parts[0].inlineData.data // empty' "$resp_file" 2>/dev/null)"
  if [ -z "$audio_b64" ]; then
    log error "gemini TTS request failed (http ${http}): $(tr -d '\n' < "$resp_file" 2>/dev/null | cut -c1-200)"
    rm -f "$resp_file"; return 1
  fi
  rm -f "$resp_file"

  # termux-media-player is how Termux:API actually reaches the phone speaker
  # (it hands the file to Android's own MediaPlayer). ffplay/aplay running
  # directly in this shell has no audio device (no /dev/snd here — this is a
  # proot container), so it silently hangs instead of making sound. The file
  # must also live somewhere Android's Termux:API app can open by path: this
  # proot's own /tmp isn't bind-mounted into the real Termux filesystem, only
  # $TERMUX_HOME (and /storage/emulated/0) are — see `mount` output.
  local termux_home="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}"
  local scratch_dir="$termux_home/.voice-readout-tmp"
  [ -d "$scratch_dir" ] || { mkdir -p "$scratch_dir" 2>/dev/null && chmod 700 "$scratch_dir" 2>/dev/null; }
  if [ ! -d "$scratch_dir" ]; then
    log error "gemini backend: cannot create $scratch_dir (wrong TERMUX_HOME?)"
    return 1
  fi
  local pcm_file="$scratch_dir/audio-$$.pcm"
  local wav_file="$scratch_dir/audio-$$.wav"
  printf '%s' "$audio_b64" | base64 -d > "$pcm_file" 2>/dev/null
  if ! ffmpeg -y -f s16le -ar 24000 -ac 1 -i "$pcm_file" "$wav_file" -loglevel error 2>/dev/null; then
    log error "gemini TTS: ffmpeg failed to build wav"
    rm -f "$pcm_file" "$wav_file"
    return 1
  fi
  rm -f "$pcm_file"

  termux-media-player play "$wav_file" >/dev/null 2>&1

  # termux-media-player is fire-and-forget (the play command returns
  # immediately), so poll `info` until playback stops to know when we're done.
  local waited=0
  while [ "$waited" -lt "$cap" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    if ! termux-media-player info 2>/dev/null | grep -q 'Status: Playing'; then
      break
    fi
  done
  termux-media-player stop >/dev/null 2>&1
  rm -f "$wav_file"

  if [ "$waited" -ge "$cap" ]; then
    log error "gemini TTS playback exceeded cap (${cap}s)"
    return 1
  fi
  log spoke "gemini-tts (model ${model}, voice ${voice}, ${waited}s)"
  return 0
}

# Inworld Realtime TTS API (Mini model by default): sends text to
# https://api.inworld.ai/tts/v1/voice, gets back base64 audio and plays it via
# termux-media-player. Unlike the Gemini backend, Inworld's "LINEAR16"
# response is already a complete WAV file (RIFF/WAVE header included, verified
# against a live response 2026-07-20) — no ffmpeg wrapping needed, so this
# backend has one fewer dependency than gemini. Needs network + an API key
# from the Inworld portal; falls back to the ondevice backend on any failure
# so an API outage or a missing key doesn't go silent.
# See docs.inworld.ai/api-reference/ttsAPI/texttospeech/synthesize-speech.
speak_inworld() {
  local text="$1"
  local cap="$2"
  local api_key
  api_key="$(get_inworld_api_key)"
  if [ -z "$api_key" ]; then
    log error "inworld backend selected but no API key set (toggle.sh inworld-key <KEY>)"
    return 1
  fi
  if ! command -v termux-media-player >/dev/null 2>&1; then
    log error "inworld backend needs termux-media-player, not found"
    return 1
  fi

  local model; model="$(sanitize_model "${VOICE_READOUT_INWORLD_MODEL:-inworld-tts-1.5-mini}" inworld-tts-1.5-mini)"
  # "Olivia" (English-native, young British) — picked 2026-07-20 after
  # comparing against Hina/Asuka/Sarah/Selene/Evelyn for Japanese readouts;
  # her voice is en-native but the cross-lingual model still speaks $lang.
  local voice="${VOICE_READOUT_INWORLD_VOICE:-Olivia}"
  local lang="${VOICE_READOUT_INWORLD_LANG:-ja}"
  local payload response audio_b64

  payload="$(jq -n --arg text "$text" --arg voice "$voice" --arg model "$model" --arg lang "$lang" '{
    text: $text,
    voiceId: $voice,
    modelId: $model,
    language: $lang,
    audioConfig: {audioEncoding: "LINEAR16", sampleRateHertz: 24000}
  }')"

  # Matches the Gemini backend's cap — see the comment there for why 20s
  # wasn't enough for long full-mode readouts.
  local resp_file http
  resp_file="$(mktemp "${PLUGIN_DATA_DIR}/vr-resp.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/vr-resp.XXXXXX")" || return 1
  chmod 600 "$resp_file" 2>/dev/null
  http="$(cloud_post "https://api.inworld.ai/tts/v1/voice" \
                     "Authorization: Basic ${api_key}" "$payload" "$resp_file")"
  audio_b64="$(jq -r '.audioContent // empty' "$resp_file" 2>/dev/null)"
  if [ -z "$audio_b64" ]; then
    log error "inworld TTS request failed (http ${http}): $(tr -d '\n' < "$resp_file" 2>/dev/null | cut -c1-200)"
    rm -f "$resp_file"; return 1
  fi
  rm -f "$resp_file"

  # Same proot/Termux:API path constraint as the Gemini backend — see the
  # comment there for why the file must live under $TERMUX_HOME.
  local termux_home="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}"
  local scratch_dir="$termux_home/.voice-readout-tmp"
  [ -d "$scratch_dir" ] || { mkdir -p "$scratch_dir" 2>/dev/null && chmod 700 "$scratch_dir" 2>/dev/null; }
  if [ ! -d "$scratch_dir" ]; then
    log error "inworld backend: cannot create $scratch_dir (wrong TERMUX_HOME?)"
    return 1
  fi
  local wav_file="$scratch_dir/audio-$$.wav"
  printf '%s' "$audio_b64" | base64 -d > "$wav_file" 2>/dev/null
  if [ ! -s "$wav_file" ]; then
    log error "inworld TTS: base64 decode produced an empty file"
    rm -f "$wav_file"
    return 1
  fi

  termux-media-player play "$wav_file" >/dev/null 2>&1

  local waited=0
  while [ "$waited" -lt "$cap" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    if ! termux-media-player info 2>/dev/null | grep -q 'Status: Playing'; then
      break
    fi
  done
  termux-media-player stop >/dev/null 2>&1
  rm -f "$wav_file"

  if [ "$waited" -ge "$cap" ]; then
    log error "inworld TTS playback exceeded cap (${cap}s)"
    return 1
  fi
  log spoke "inworld-tts (model ${model}, voice ${voice}, ${waited}s)"
  return 0
}

# ElevenLabs TTS API (eleven_flash_v2_5 model by default — their low-latency
# model, ~75ms model inference per their docs): sends text to
# https://api.elevenlabs.io/v1/text-to-speech/{voice_id} and gets back raw MP3
# bytes directly in the response body (not JSON/base64, unlike Gemini and
# Inworld). termux-media-player hands off to Android's MediaPlayer, which
# plays MP3 natively, so the file is saved as-is with no decode step. Needs
# network + an API key from the ElevenLabs dashboard; falls back to the
# ondevice backend on any failure so an API outage or a missing key doesn't go
# silent. See elevenlabs.io/docs/api-reference/text-to-speech/convert.
speak_elevenlabs() {
  local text="$1"
  local cap="$2"
  local api_key
  api_key="$(get_elevenlabs_api_key)"
  if [ -z "$api_key" ]; then
    log error "elevenlabs backend selected but no API key set (toggle.sh elevenlabs-key <KEY>)"
    return 1
  fi
  if ! command -v termux-media-player >/dev/null 2>&1; then
    log error "elevenlabs backend needs termux-media-player, not found"
    return 1
  fi

  # Model is config-selectable (toggle.sh tune ELEVENLABS_MODEL <id>). Default
  # stays the low-latency eleven_flash_v2_5; set eleven_v3 for the highest-
  # quality / most expressive voice (slower + pricier). The env var, if set,
  # provides the fallback default when no config value is present.
  local model
  model="$(sanitize_model "$(get_tuning ELEVENLABS_MODEL "${VOICE_READOUT_ELEVENLABS_MODEL:-eleven_flash_v2_5}")" eleven_flash_v2_5)"
  # "アマテラステラス2" (middle-aged, ja-kanto accent) — a custom voice already
  # in the account's ElevenLabs voice library, picked 2026-07-20 for a mature,
  # Japanese-native-sounding tone.
  local voice="${VOICE_READOUT_ELEVENLABS_VOICE:-blVzlvngVR9lhf4Gflnk}"
  local payload http_code

  payload="$(jq -n --arg text "$text" --arg model "$model" '{text: $text, model_id: $model}')"

  local termux_home="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}"
  local scratch_dir="$termux_home/.voice-readout-tmp"
  [ -d "$scratch_dir" ] || { mkdir -p "$scratch_dir" 2>/dev/null && chmod 700 "$scratch_dir" 2>/dev/null; }
  if [ ! -d "$scratch_dir" ]; then
    log error "elevenlabs backend: cannot create $scratch_dir (wrong TERMUX_HOME?)"
    return 1
  fi
  local mp3_file="$scratch_dir/audio-$$.mp3"

  http_code="$(cloud_post "https://api.elevenlabs.io/v1/text-to-speech/${voice}" \
                          "xi-api-key: ${api_key}" "$payload" "$mp3_file")"

  if [ "$http_code" != "200" ] || [ ! -s "$mp3_file" ]; then
    log error "elevenlabs TTS request failed (http ${http_code}): $(head -c 200 "$mp3_file" 2>/dev/null | tr -d '\n')"
    rm -f "$mp3_file"
    return 1
  fi

  # Optional volume attenuation. termux-media-player has no volume flag, so
  # cloud audio plays at ElevenLabs' master level — often louder than the
  # on-device voice, which uses a different output path. When ELEVENLABS_GAIN is
  # anything other than 1.0, re-encode through ffmpeg's volume filter so this
  # backend can be made quieter (<1) or louder (>1) independently of the device
  # media volume. Default 1.0 = untouched, so behaviour is unchanged unless set.
  local gain play_file adj_file
  # Validated like every other value that reaches an external command: this one
  # is interpolated into an ffmpeg filter string, where a non-numeric value
  # would add filters of its own rather than set a volume.
  gain="$(get_tuning ELEVENLABS_GAIN 1.0)"
  case "$gain" in ''|*[!0-9.]*) gain=1.0 ;; esac
  play_file="$mp3_file"
  if [ -n "$gain" ] && [ "$gain" != "1.0" ] && [ "$gain" != "1" ] && command -v ffmpeg >/dev/null 2>&1; then
    adj_file="$scratch_dir/audio-$$-adj.mp3"
    if ffmpeg -y -i "$mp3_file" -af "volume=${gain}" "$adj_file" -loglevel error 2>/dev/null && [ -s "$adj_file" ]; then
      play_file="$adj_file"
    else
      log error "elevenlabs gain: ffmpeg failed (gain=${gain}), playing at original volume"
    fi
  fi

  termux-media-player play "$play_file" >/dev/null 2>&1

  local waited=0
  while [ "$waited" -lt "$cap" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    if ! termux-media-player info 2>/dev/null | grep -q 'Status: Playing'; then
      break
    fi
  done
  termux-media-player stop >/dev/null 2>&1
  rm -f "$mp3_file" "$play_file"

  if [ "$waited" -ge "$cap" ]; then
    log error "elevenlabs TTS playback exceeded cap (${cap}s)"
    return 1
  fi
  log spoke "elevenlabs-tts (model ${model}, voice ${voice}, ${waited}s)"
  return 0
}

# Windows on-device TTS via the built-in SAPI voice, reached from Git Bash by
# shelling out to PowerShell. This is the Windows counterpart to the
# termux-tts-speak path: no API key, no network, offline. It is only ever
# reached when termux-tts-speak is absent (see speak()'s ondevice branch), so it
# never runs on the phone. Returns non-zero when there is no PowerShell to call,
# which is how a genuinely unsupported host falls through to a real error.
speak_windows_sapi() {
  local text="$1"
  local ps
  # powershell.exe is the real Windows shell as seen from Git Bash; plain
  # "powershell" is a fallback for setups that alias it.
  if command -v powershell.exe >/dev/null 2>&1; then
    ps=powershell.exe
  elif command -v powershell >/dev/null 2>&1; then
    ps=powershell
  else
    return 1
  fi

  # Hand the text over as a UTF-8 file rather than as a command-line argument:
  # embedding Japanese (and quotes/newlines) directly in `powershell -Command`
  # mangles both the encoding (PS 5.1 is not UTF-8 by default) and the quoting.
  # PowerShell reads it back with an explicit UTF-8 decode.
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/voice-readout-sapi.XXXXXX")" || return 1
  printf '%s' "$text" > "$tmp"

  # PowerShell (a Windows process) cannot open Git Bash's /tmp path; cygpath -w
  # turns it into the C:\... form Windows understands.
  local winpath="$tmp"
  command -v cygpath >/dev/null 2>&1 && winpath="$(cygpath -w "$tmp")"

  # Map the on-device rate multiplier (1.0 = normal, config default 1.3) onto
  # SAPI's -10..10 scale, clamped.
  local rate sapi_rate
  rate="$(resolve_speed TTS_RATE 1.01)"
  sapi_rate="$(awk -v r="$rate" 'BEGIN{v=int((r-1)*10+0.5); if(v>10)v=10; if(v<-10)v=-10; print v}')"

  "$ps" -NoProfile -Command \
    "Add-Type -AssemblyName System.Speech; \
     \$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; \
     \$s.Rate = $sapi_rate; \
     \$s.Speak([System.IO.File]::ReadAllText('$winpath', [System.Text.Encoding]::UTF8))"
  local rc=$?

  rm -f "$tmp" 2>/dev/null
  if [ "$rc" -eq 0 ]; then
    log spoke "windows-sapi (rate ${sapi_rate})"
    return 0
  fi
  log error "windows-sapi failed (exit $rc)"
  return 1
}

# Fixed absolute path on purpose — see bin/readout-switch.sh. Every other path
# in this file is built from CLAUDE_PLUGIN_DATA; this one must not be, because
# redirecting that variable is precisely how the ordinary toggles get
# bypassed.
STOP_SWITCH_FILE="/data/data/com.termux/files/home/.voice-readout-stopped"

# ---------------------------------------------------------------------------
# Chunked, prefetching cloud readout.
#
# speak_gemini/inworld/elevenlabs above each send the WHOLE text in one request,
# so a long readout waits for the entire clip to generate before any sound comes
# out (measured 2026-07-24: 26-50s for a ~650-char response) and long text can
# blow CLOUD_HTTP_TIMEOUT and fail into a summary. Splitting the text into
# sentence-bounded chunks fixes both: the first (short) chunk starts speaking in
# a few seconds, and while each chunk plays the next is generated in the
# background. Every measured backend generates a chunk well under its own
# playback time (gen/audio ratio ~0.2-0.7 at 120 chars), so after the first
# chunk playback stays continuous.
#
# CLOUD_CHUNK_CHARS is a baked-in default (120), chosen from those measurements
# to work for every backend without starving. It is deliberately NOT something
# an end user tunes: they pick a TTS backend, this picks the chunk size. The
# gen_* helpers below are the generation halves of the speak_* functions (no
# playback), so the pipeline can generate one chunk while playing another.
# ---------------------------------------------------------------------------

# Scratch dir both this container and Termux's media player can reach. Echoes
# the path; non-zero if it can't be created.
_cloud_scratch_dir() {
  local d="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}/.voice-readout-tmp"
  if [ ! -d "$d" ]; then
    # 0700 on creation: what lands here is the audio of whatever is being read
    # aloud. Termux and this proot share a uid, so the media player can still
    # open it (verified 2026-07-25 — real uid 10502 on both sides).
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
  fi
  [ -d "$d" ] || { log error "cloud backend: cannot create $d (wrong TERMUX_HOME?)"; return 1; }
  printf '%s' "$d"
}

# Deterministic per-(backend,uid) audio path, so a backgrounded generator and
# the foreground player agree on the filename without passing it over a pipe.
# Chunk audio is named per readout as well as per chunk index. It used to be
# the index alone (vr-0.mp3, vr-1.mp3, …), which two readouts running at the
# same time both wrote to: the newer one overwrote chunk files the older one
# had not played yet, so the older readout played its successor's audio under
# its own index and the listener heard the two responses interleaved out of
# order (observed 2026-07-25). Superseding (see readout_speaking_begin) should
# keep readouts from overlapping in the first place; this makes a collision
# harmless even in the window before the old readout notices.
_cloud_audio_path() {
  local d; d="$(_cloud_scratch_dir)" || return 1
  case "$1" in
    elevenlabs) printf '%s/vr-%s-%s.mp3' "$d" "$VOICE_READOUT_RUN_ID" "$2" ;;
    *)          printf '%s/vr-%s-%s.wav' "$d" "$VOICE_READOUT_RUN_ID" "$2" ;;
  esac
}

# gen_gemini TEXT OUTFILE — produce a WAV at OUTFILE. No playback. Returns 0/1.
gen_gemini() {
  local text="$1" out="$2" api_key model voice payload response http audio_b64 pcm
  api_key="$(get_gemini_api_key)"
  [ -z "$api_key" ] && { log error "gemini backend selected but no API key set"; return 1; }
  command -v ffmpeg >/dev/null 2>&1 || { log error "gemini backend needs ffmpeg"; return 1; }
  model="$(sanitize_model "$(get_tuning GEMINI_MODEL "${VOICE_READOUT_GEMINI_MODEL:-gemini-2.5-flash-preview-tts}")" gemini-2.5-flash-preview-tts)"
  voice="${VOICE_READOUT_GEMINI_VOICE:-Kore}"
  # Gemini TTS has no speed parameter — its default pace is fine for reading a
  # novel aloud but too slow for Claude Code readouts. Pace is instead steered by
  # a natural-language directive prefixed to the prompt; the model applies it as
  # a style and does not speak the directive itself. GEMINI_SPEED (config/env,
  # default 1.4) sets the multiplier; 1.0/1 disables the prefix. Validate numeric
  # so a bad value can't inject arbitrary text into the prompt.
  local speed spoken="$text"
  speed="$(resolve_speed GEMINI_SPEED 0.83)"
  case "$speed" in ''|*[!0-9.]*) speed=1.4 ;; esac
  # Directive is in English on purpose: Gemini follows an English style prompt
  # more reliably, and it can never be mistaken for Japanese content to speak.
  if [ "$speed" != "1.0" ] && [ "$speed" != "1" ]; then
    spoken="Read the following Japanese text aloud naturally, at about ${speed}x the normal speaking pace — noticeably faster and crisper than the default, but still clear. Do not read this instruction."$'\n\n'"${text}"
  fi
  payload="$(jq -n --arg text "$spoken" --arg voice "$voice" '{contents:[{parts:[{text:$text}]}],generationConfig:{responseModalities:["AUDIO"],speechConfig:{voiceConfig:{prebuiltVoiceConfig:{voiceName:$voice}}}}}')"
  # Key travels as a header via cloud_post's stdin config, not in the URL — see
  # the comment on cloud_post. Response lands in a file because that is what
  # keeps the request body off the command line too.
  response="$(mktemp "${PLUGIN_DATA_DIR}/vr-resp.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/vr-resp.XXXXXX")" || return 1
  chmod 600 "$response" 2>/dev/null
  http="$(cloud_post "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
                     "x-goog-api-key: ${api_key}" "$payload" "$response")"
  audio_b64="$(jq -r '.candidates[0].content.parts[0].inlineData.data // empty' "$response" 2>/dev/null)"
  if [ -z "$audio_b64" ]; then
    log error "gemini TTS request failed (http ${http}): $(tr -d '\n' < "$response" 2>/dev/null | cut -c1-160)"
    rm -f "$response"; return 1
  fi
  rm -f "$response"
  pcm="${out%.wav}.pcm"
  printf '%s' "$audio_b64" | base64 -d > "$pcm" 2>/dev/null
  if ! ffmpeg -y -f s16le -ar 24000 -ac 1 -i "$pcm" "$out" -loglevel error 2>/dev/null; then
    log error "gemini TTS: ffmpeg failed to build wav"; rm -f "$pcm" "$out"; return 1
  fi
  rm -f "$pcm"; return 0
}

# gen_inworld TEXT OUTFILE — produce a WAV at OUTFILE. Returns 0/1.
gen_inworld() {
  local text="$1" out="$2" api_key model voice lang rate payload response http audio_b64
  api_key="$(get_inworld_api_key)"
  [ -z "$api_key" ] && { log error "inworld backend selected but no API key set"; return 1; }
  model="$(sanitize_model "$(get_tuning INWORLD_MODEL "${VOICE_READOUT_INWORLD_MODEL:-inworld-tts-1.5-mini}")" inworld-tts-1.5-mini)"
  voice="${VOICE_READOUT_INWORLD_VOICE:-Olivia}"
  lang="${VOICE_READOUT_INWORLD_LANG:-ja}"
  # speakingRate: 0.5-1.5 (1.0 = native). Inworld's native pace runs slow for
  # Japanese readouts, so the shipped default is 1.3 and it's config-tunable via
  # INWORLD_SPEAKING_RATE. Validate it's numeric before handing it to jq's
  # --argjson (a bad value would abort payload construction).
  rate="$(resolve_speed INWORLD_SPEAKING_RATE 1.11)"
  case "$rate" in ''|*[!0-9.]*) rate=1.3 ;; esac
  payload="$(jq -n --arg text "$text" --arg voice "$voice" --arg model "$model" --arg lang "$lang" --argjson rate "$rate" '{text:$text,voiceId:$voice,modelId:$model,language:$lang,audioConfig:{audioEncoding:"LINEAR16",sampleRateHertz:24000,speakingRate:$rate}}')"
  response="$(mktemp "${PLUGIN_DATA_DIR}/vr-resp.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/vr-resp.XXXXXX")" || return 1
  chmod 600 "$response" 2>/dev/null
  http="$(cloud_post "https://api.inworld.ai/tts/v1/voice" \
                     "Authorization: Basic ${api_key}" "$payload" "$response")"
  audio_b64="$(jq -r '.audioContent // empty' "$response" 2>/dev/null)"
  if [ -z "$audio_b64" ]; then
    log error "inworld TTS request failed (http ${http}): $(tr -d '\n' < "$response" 2>/dev/null | cut -c1-160)"
    rm -f "$response"; return 1
  fi
  rm -f "$response"
  printf '%s' "$audio_b64" | base64 -d > "$out" 2>/dev/null
  [ -s "$out" ] || { log error "inworld TTS: empty decode"; rm -f "$out"; return 1; }
  return 0
}

# gen_elevenlabs TEXT OUTFILE — produce an MP3 at OUTFILE (ELEVENLABS_GAIN
# applied when set). Returns 0/1.
gen_elevenlabs() {
  local text="$1" out="$2" api_key model voice speed payload http gain tempo filters raw
  api_key="$(get_elevenlabs_api_key)"
  [ -z "$api_key" ] && { log error "elevenlabs backend selected but no API key set"; return 1; }
  model="$(sanitize_model "$(get_tuning ELEVENLABS_MODEL "${VOICE_READOUT_ELEVENLABS_MODEL:-eleven_flash_v2_5}")" eleven_flash_v2_5)"
  voice="${VOICE_READOUT_ELEVENLABS_VOICE:-blVzlvngVR9lhf4Gflnk}"
  # speed via voice_settings (1.0 = normal), config-tunable via ELEVENLABS_SPEED.
  # Measured limits (2026-07-24): eleven_v3 IGNORES speed entirely; flash/v2/turbo
  # honour it but only within 0.7-1.2 (out-of-range 400s and falls back). Default
  # 1.0 is safe for every model. Validate numeric for jq's --argjson.
  speed="$(get_tuning ELEVENLABS_SPEED 1.0)"
  case "$speed" in ''|*[!0-9.]*) speed=1.0 ;; esac
  payload="$(jq -n --arg text "$text" --arg model "$model" --argjson speed "$speed" '{text:$text, model_id:$model, voice_settings:{speed:$speed}}')"
  raw="${out%.mp3}-raw.mp3"
  http="$(cloud_post "https://api.elevenlabs.io/v1/text-to-speech/${voice}" \
                     "xi-api-key: ${api_key}" "$payload" "$raw")"
  if [ "$http" != "200" ] || [ ! -s "$raw" ]; then
    log error "elevenlabs TTS request failed (http ${http}): $(head -c 160 "$raw" 2>/dev/null | tr -d '\n')"; rm -f "$raw"; return 1
  fi
  # Post-process volume and speed in ONE ffmpeg pass. Speed lives here, not in
  # the request, because eleven_v3 ignores voice_settings.speed outright:
  # measured 2026-07-25 on this device, 1.0/1.2/1.4 all returned 8.67/8.67/8.36s
  # for the same sentence (within run-to-run noise) — and unlike flash_v2_5,
  # which honours speed and rejects anything outside 0.7-1.2 with a 400, v3
  # accepts the value and silently drops it. atempo changes tempo without
  # shifting pitch, so the voice is unchanged; it is free whenever a non-default
  # gain is set, since that pass already runs.
  # Validated like every other value that reaches an external command: this one
  # is interpolated into an ffmpeg filter string, where a non-numeric value
  # would add filters of its own rather than set a volume.
  gain="$(get_tuning ELEVENLABS_GAIN 1.0)"
  case "$gain" in ''|*[!0-9.]*) gain=1.0 ;; esac
  tempo="$(resolve_speed ELEVENLABS_ATEMPO 0.92)"
  case "$tempo" in ''|*[!0-9.]*) tempo=1.0 ;; esac
  # A single atempo filter only accepts 0.5-2.0; out-of-range would make ffmpeg
  # fail and drop us to the unprocessed audio, silently ignoring the setting.
  case "$(awk -v t="$tempo" 'BEGIN{print (t>=0.5 && t<=2.0) ? "ok" : "bad"}')" in
    bad) log error "ELEVENLABS_ATEMPO=${tempo} out of range (0.5-2.0), ignoring"; tempo=1.0 ;;
  esac
  filters=""
  case "$gain" in  ''|1|1.0|1.00) ;; *) filters="volume=${gain}" ;; esac
  case "$tempo" in ''|1|1.0|1.00) ;; *) filters="${filters:+${filters},}atempo=${tempo}" ;; esac
  if [ -n "$filters" ] && command -v ffmpeg >/dev/null 2>&1 \
     && ffmpeg -y -i "$raw" -af "$filters" "$out" -loglevel error 2>/dev/null && [ -s "$out" ]; then
    rm -f "$raw"
  else
    mv -f "$raw" "$out"
  fi
  return 0
}

# Test only (CHUNK_MARKER on): append the boundary cue to a just-generated chunk
# file, in place, so it plays as the tail of the SAME playback — no second media
# player call, so no ~2s round-trip gap between the chunk and the cue. Both are
# normalised to 24kHz mono s16 first so the concat filter accepts any backend's
# format (gemini/inworld wav, elevenlabs mp3) and the .wav byte-length math in
# _audio_duration stays valid. No-op unless the toggle is on. Best-effort: on any
# ffmpeg failure the chunk is left unmarked rather than lost.
_append_chunk_marker() {
  local f="$1" ext tmp
  [ "$(get_tuning CHUNK_MARKER off)" = "on" ] || return 0
  [ -f "$CHUNK_MARKER_CLIP" ] || return 0
  command -v ffmpeg >/dev/null 2>&1 || return 0
  ext="${f##*.}"; tmp="${f%.*}-marked.${ext}"
  if ffmpeg -y -i "$f" -i "$CHUNK_MARKER_CLIP" -filter_complex \
       '[0:a]aresample=24000,aformat=sample_fmts=s16:channel_layouts=mono[a0];[1:a]aresample=24000,aformat=sample_fmts=s16:channel_layouts=mono[a1];[a0][a1]concat=n=2:v=0:a=1' \
       "$tmp" -loglevel error 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
  return 0
}

# gen_cloud BACKEND TEXT UID — generate one chunk's audio to the deterministic
# path for (BACKEND, UID). Returns 0/1.
gen_cloud() {
  local backend="$1" text="$2" uid="$3" out
  out="$(_cloud_audio_path "$backend" "$uid")" || return 1
  # These names have to be predictable — the backgrounded generator and the
  # foreground player agree on them without a pipe — so the write is guarded
  # instead of the name being made unguessable. rm -f takes away a symlink
  # planted at the path rather than writing through it, and clears a stale file
  # left by a readout that died before its own cleanup. The two extra names are
  # the intermediates the backends build beside the output (gemini's .pcm,
  # elevenlabs' -raw.mp3).
  rm -f "$out" "${out%.wav}.pcm" "${out%.mp3}-raw.mp3" 2>/dev/null
  case "$backend" in
    gemini)     gen_gemini "$text" "$out" ;;
    inworld)    gen_inworld "$text" "$out" ;;
    elevenlabs) gen_elevenlabs "$text" "$out" ;;
    *)          return 1 ;;
  esac || return 1
  _append_chunk_marker "$out"
  return 0
}

# The exact text speak_cloud_chunked would generate FIRST for TEXT. Used by the
# hybrid handover (speak_hybrid): a speculative generator produces that chunk in
# advance, and speak_cloud_chunked then accepts the finished file as its chunk 0
# instead of generating it again. Both sides read the same two config keys in
# the same process, so the two splits are identical by construction — if they
# ever diverged the seed would be audio of the wrong text, which is why this
# derives the chunk rather than approximating it.
_cloud_first_chunk() {
  local c=""
  IFS= read -r -d '' c \
    < <(split_into_speech_chunks "$1" \
          "$(get_tuning_num CLOUD_CHUNK_CHARS 200)" \
          "$(get_tuning_num CLOUD_FIRST_CHUNK_CHARS 80)") || true
  printf '%s' "$c"
}

# Best-effort audio length in seconds. WAV from gemini/inworld is 24kHz mono
# 16-bit = 48000 bytes/sec, so bytes/48000 is exact and cheap (and ffprobe often
# can't read Inworld's streamed WAV header anyway). MP3 from elevenlabs needs
# ffprobe. Prints nothing if it can't tell.
_audio_duration() {
  local f="$1" bytes dur
  case "$f" in
    *.wav)
      bytes="$(wc -c < "$f" 2>/dev/null)" || return
      [ -n "$bytes" ] && [ "$bytes" -gt 44 ] 2>/dev/null && awk "BEGIN{printf \"%.1f\", ($bytes-44)/48000}"
      ;;
    *.mp3)
      command -v ffprobe >/dev/null 2>&1 || return
      # nw = noprint_wrappers, nk = nokey. `np` is NOT an abbreviation ffprobe
      # knows: it fails the writer with "Failed to set option 'np'", exits 1 and
      # prints nothing — which silently sent every ElevenLabs chunk down the
      # no-lead polling branch of _play_media_file (~8s of dead air per seam).
      dur="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" 2>/dev/null)" || return
      case "$dur" in ''|*[!0-9.]*) return ;; esac
      printf '%s' "$dur"
      ;;
  esac
}

# Play a file via the Termux media player. We know each chunk's exact length
# (see _audio_duration), so we sleep for it instead of polling `termux-media-
# player info` (each info call is a ~2-3s round-trip that over-ran the true end).
#
# LEAD (3rd arg, seconds) returns that much BEFORE the audio ends, so the caller
# can issue the next chunk's `play` early: a `play` does NOT stop the current
# track until the new one is prepared (~2s Termux:API round-trip), so that
# prepare overlaps this chunk's tail and the next chunk takes over right as this
# one finishes — hiding the round-trip that used to be a ~4s inter-chunk gap
# (verified seamless at LEAD≈1.4 on 2026-07-24). LEAD=0 (the final chunk, or the
# unknown-length fallback) plays fully. We do NOT rm/stop here: with the handoff
# the file may still be feeding the media service; the caller cleans up once the
# chunk is safely done.
#
# STARTED (4th arg, epoch seconds) says this file's `play` was already issued
# elsewhere and its audio began at that moment — see the pre-play in
# speak_hybrid. There is then nothing to start, only the right amount of it left
# to wait out, so the elapsed time is subtracted from the sleep. Measuring
# elapsed *after* the duration probe is deliberate: the probe is ~0.4s of
# ffprobe that has already been eaten out of the playback.
_play_media_file() {
  local file="$1" cap="$2" lead="${3:-0}" started="${4:-}" dur elapsed=0
  dur="$(_audio_duration "$file")"
  if [ -n "$started" ]; then
    elapsed="$(awk "BEGIN{e=$(date +%s.%N)-$started; if(e<0)e=0; printf \"%.1f\", e}")"
  else
    termux-media-player play "$file" >/dev/null 2>&1
  fi
  if [ -n "$dur" ]; then
    sleep "$(awk "BEGIN{d=$dur-$lead-$elapsed; if(d<0)d=0; if(d>$cap)d=$cap; printf \"%.1f\", d}")"
  else
    local waited=0
    while [ "$waited" -lt "$cap" ]; do
      sleep 1
      waited=$(( waited + 1 ))
      termux-media-player info 2>/dev/null | grep -q 'Status: Playing' || break
    done
    termux-media-player stop >/dev/null 2>&1
    rm -f "$file"
  fi
  return 0
}

# speak_cloud_chunked BACKEND TEXT CAP — sentence-chunk the text and read it while
# a rolling buffer of chunks generates ahead in the background.
#
# Prefetch depth is PREFETCH_DEPTH chunks: while chunk i plays, chunks i+1..i+D
# are already generating (or done). Because a chunk generates faster than it
# plays (gen/audio ~0.2-0.7), that buffer *fills up* during playback, so after
# the first chunk the seams between later chunks are essentially gap-free — the
# longer the text, the smoother it gets. Depth 2 is the sweet spot for Inworld;
# raise it for a backend whose generation is slower relative to playback, at the
# cost of that many parallel API calls in flight.
#
# SEED (4th arg, optional) is a path to audio already generated for this text's
# first chunk — see speak_hybrid, which generates it speculatively while the
# on-device engine covers the opening. It is moved into chunk 0's place and its
# generation is skipped, so the handover has no generation wait at all.
# PLAN (5th arg, optional) is that same caller's pre-built chunk plan, so the
# handover has no split wait either — see _cloud_prep_ahead and the use below.
# PLAYING (6th arg, optional) is the epoch at which that seed's `play` was
# already issued and its audio began — the caller started chunk 0 before the
# handover, so here it is only waited out, never started.
#
# Returns 0 if it spoke everything (or was stopped mid-way), 1 only if the very
# first chunk could not be generated, so the caller can fall back to ondevice.
speak_cloud_chunked() {
  local backend="$1" text="$2" cap="$3" seed="${4:-}" plan="${5:-}" playing="${6:-}"
  command -v termux-media-player >/dev/null 2>&1 || { log error "${backend}: termux-media-player not found"; return 1; }

  local chunks=() c
  # PLAN (5th arg, optional): a chunk plan the caller had built ahead of time,
  # NUL-separated, one chunk per record — see _cloud_prep_ahead. Consumed here
  # so the split (and the scratch sweep that came with it) is not paid for on
  # the critical path. It was built from this same TEXT, so using it changes
  # nothing about what gets spoken; if it is missing or unreadable the split
  # below runs as usual.
  if [ -n "$plan" ] && [ -s "$plan" ]; then
    while IFS= read -r -d '' c; do [ -n "$c" ] && chunks+=("$c"); done < "$plan"
    rm -f "$plan" 2>/dev/null
  fi

  # Few, large chunks minimise the per-chunk termux-media-player play round-trip
  # (~2–5s each) that is the dominant inter-chunk gap; the first chunk is kept
  # small so audio still starts quickly. Generation keeps up even so (measured
  # gen/audio <1 for every backend at these sizes, incl. Gemini once its ~6s
  # TTFB is amortised over a big enough chunk), aided by the depth-2 prefetch.
  # Per-readout audio names mean a readout that dies before its own cleanup
  # (killed, device asleep, crash) leaves files nobody will ever reclaim by
  # name. Sweep anything older than an hour — far longer than any readout, so
  # this can never touch a live one's chunks.
  local chunk_max first_max play_lead _scratch
  if [ "${#chunks[@]}" -eq 0 ]; then
    if _scratch="$(_cloud_scratch_dir)"; then
      find "$_scratch" -maxdepth 1 -name 'vr-*' -type f -mmin +60 -delete 2>/dev/null
    fi
    chunk_max="$(get_tuning_num CLOUD_CHUNK_CHARS 200)"
    first_max="$(get_tuning_num CLOUD_FIRST_CHUNK_CHARS 80)"
    while IFS= read -r -d '' c; do [ -n "$c" ] && chunks+=("$c"); done \
      < <(split_into_speech_chunks "$text" "$chunk_max" "$first_max")
  fi
  # Seconds to issue the next chunk's play before the current one ends, so the
  # next chunk's prepare overlaps this tail (see _play_media_file). 0 disables
  # the overlap. Validate numeric.
  play_lead="$(get_tuning CLOUD_PLAY_LEAD 1.4)"
  case "$play_lead" in ''|*[!0-9.]*) play_lead=1.4 ;; esac
  local n=${#chunks[@]}
  [ "$n" -eq 0 ] && return 1

  # Test aid: the CHUNK_MARKER cue is appended to each chunk's audio file at
  # generation time (see gen_cloud / _append_chunk_marker), NOT played as a
  # separate clip. A second termux-media-player call would cost its own ~2s
  # round-trip before the cue sounds — that latency IS the gap between the chunk
  # and the cue. Concatenating into one file removes it: the cue plays as the
  # tail of the same playback, seamlessly. Nothing to set up here.

  # Per-chunk playback ceiling. A <=chunk_max-char chunk is at most ~40s of
  # speech even on the slowest-talking backend; 90s is a safe cap. Poll overhead
  # (each `info` is a Termux:API round-trip) makes `waited` undercount wall time,
  # so this only trips on a genuinely stuck player.
  local pcap=90

  local prefetch=2   # in-flight lookahead buffer; see the header comment.

  # gen_pid[k] = background PID generating chunk k (once launched). Sparse.
  # gen_done[k] = chunk k's audio was already in place before the loop started
  # (the SEED), so there is no generator to wait for.
  local -a gen_pid=()
  local -a gen_done=()

  # A caller that already generated chunk 0 hands the file over here. Moved
  # rather than copied: the deterministic per-chunk name is what the play loop
  # below looks for, and leaving a second copy behind would outlive the readout.
  # The rename is safe even when the seed is already playing (PLAYING): it is a
  # same-directory rename, the media service is holding an open descriptor, and
  # a descriptor does not care what the file is called.
  if [ -n "$seed" ] && [ -s "$seed" ]; then
    local seed_dest; seed_dest="$(_cloud_audio_path "$backend" 0)"
    if [ "$seed" = "$seed_dest" ] || mv -f "$seed" "$seed_dest" 2>/dev/null; then
      gen_done[0]=1
      if [ -n "$playing" ]; then
        log info "${backend} pipeline: chunk 0 pre-generated and already playing"
      else
        log info "${backend} pipeline: chunk 0 pre-generated, skipping its generation"
      fi
    fi
  fi

  # Seed the buffer: chunk 0 plus PREFETCH chunks ahead, all generating in
  # parallel from the start. Chunk 0's own generation is the only wait the
  # listener sees before the first sound.
  local k
  for (( k = 0; k <= prefetch && k < n; k++ )); do
    [ -n "${gen_done[$k]:-}" ] && continue
    gen_cloud "$backend" "${chunks[$k]}" "$k" &
    gen_pid[$k]=$!
  done

  local i=0
  while [ "$i" -lt "$n" ]; do
    # Stop switch re-checked at every boundary, like the ondevice loop, so a
    # mid-readout 停止 drops the remaining chunks instead of playing on. Reap the
    # still-running generators first so they don't leak past the readout.
    if [ -e "$STOP_SWITCH_FILE" ]; then
      log skip "読み上げ停止中 (stop switch, ${i}/${n} chunks spoken)"
      local p
      for (( p = i; p < n; p++ )); do
        [ -n "${gen_pid[$p]:-}" ] && wait "${gen_pid[$p]}" 2>/dev/null
        rm -f "$(_cloud_audio_path "$backend" "$p")"
      done
      return 0
    fi

    # Wait for chunk i (its generator was launched earlier) and check it worked.
    # A seeded chunk has no generator: its audio was finished before we started.
    if [ -n "${gen_done[$i]:-}" ]; then
      :
    elif [ -z "${gen_pid[$i]:-}" ] || ! wait "${gen_pid[$i]}"; then
      if [ "$i" -eq 0 ]; then
        # Nothing spoken yet — let the caller retry the whole text on ondevice.
        log error "${backend} pipeline: first chunk failed to generate, falling back"
        local p
        for (( p = 1; p < n; p++ )); do
          [ -n "${gen_pid[$p]:-}" ] && wait "${gen_pid[$p]}" 2>/dev/null
          rm -f "$(_cloud_audio_path "$backend" "$p")"
        done
        return 1
      fi
      # A later chunk failed — speak the rest on-device rather than drop it. Each
      # chunk is <=chunk_max (<240) so the ondevice ceiling won't force a summary.
      log fallback "${backend} pipeline: chunk ${i} failed, remaining via ondevice"
      local p
      for (( p = i + 1; p < n; p++ )); do
        [ -n "${gen_pid[$p]:-}" ] && wait "${gen_pid[$p]}" 2>/dev/null
        rm -f "$(_cloud_audio_path "$backend" "$p")"
      done
      local j
      for (( j = i; j < n; j++ )); do
        [ -e "$STOP_SWITCH_FILE" ] && break
        VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 speak "${chunks[$j]}" "$pcap" ""
      done
      return 0
    fi

    # Top up the lookahead so the buffer keeps filling while this chunk plays.
    # Generation (network + ffmpeg) and playback (media player) are separate
    # resources, so they don't collide; only one file plays at a time.
    local ahead=$(( i + prefetch ))
    if [ "$ahead" -lt "$n" ] && [ -z "${gen_pid[$ahead]:-}" ]; then
      gen_cloud "$backend" "${chunks[$ahead]}" "$ahead" &
      gen_pid[$ahead]=$!
    fi

    # Overlap every chunk but the last: the last has no successor to hide behind,
    # so it plays out fully (lead 0).
    local lead=0
    [ "$i" -lt "$(( n - 1 ))" ] && lead="$play_lead"
    if [ "$i" -eq 0 ] && [ -n "$playing" ]; then
      _play_media_file "$(_cloud_audio_path "$backend" "$i")" "$pcap" "$lead" "$playing"
    else
      _play_media_file "$(_cloud_audio_path "$backend" "$i")" "$pcap" "$lead"
    fi
    i=$(( i + 1 ))
  done
  # Cleanup deferred to here: with the lead handoff a chunk can still be feeding
  # the media service just after _play_media_file returns, so removing files mid
  # loop could pull one out from under playback. By now the last chunk (lead 0)
  # has played out and all earlier ones are long done.
  local k
  for (( k = 0; k < n; k++ )); do rm -f "$(_cloud_audio_path "$backend" "$k")"; done
  log spoke "${backend}-tts (pipelined, ${n} chunks)"
  return 0
}

# ---------------------------------------------------------------------------
# full hybrid — start on the on-device engine, hand over to the cloud voice
# ---------------------------------------------------------------------------
#
# A cloud readout's first sound costs generation (~6s on gemini) plus the
# ~2s termux-media-player round trip; the on-device engine starts in ~3s and
# needs no network. Hybrid spends that difference: speak the opening on-device
# while the cloud generates, then switch voices for the rest.
#
# The hard part is that the handover point cannot be chosen in advance. Decide
# it too early and a slow cloud leaves a silence; too late and the listener
# hears more of the on-device voice than they had to. So the text is cut into
# small on-device UNITS, and at each unit boundary we ask "is the cloud ready
# yet?" — the handover lands wherever the answer first becomes yes.
#
# What is generated speculatively is therefore not "the next chunk" but "the
# whole rest of the text, starting at boundary b":
#
#   text:      [unit 0][unit 1][unit 2 .....................]
#   candidate 1        └─ cloud takes over from here
#   candidate 2                └─ cloud takes over from here
#
# The candidates OVERLAP and are mutually exclusive. Candidate 1 contains unit
# 1; candidate 2 does not, and is only usable because the on-device engine read
# unit 1 in the meantime. That is what keeps the two voices from either
# repeating a sentence or skipping one.
#
# If the cloud is not ready when a boundary arrives we do not wait in silence:
# the candidate is thrown away, the next unit is read on-device, and a fresh
# candidate is launched one boundary later — which then has that unit's whole
# reading time (~11s at 60 chars) to finish in. Cascading more than once is
# rare because of that, and the discarded generation is the price of never
# going quiet. HYBRID_SPECULATION=2 keeps two candidates in flight instead,
# trading one guaranteed wasted API call per readout for a faster recovery.
#
# Playback is strictly sequential and that is load-bearing: termux-tts-speak
# (the TTS engine) and termux-media-player (Android's media service) are
# independent outputs and will happily talk over each other. speak() blocks
# until its unit has finished, so the cloud never starts while a unit is still
# being spoken.
#
# Returns 1 WITHOUT speaking when hybrid does not apply (no on-device engine,
# or text too short to split), so the caller can run the ordinary cloud path.
# Any other outcome returns 0 — once a unit has been spoken, falling back to
# "read the whole text again" would repeat the opening aloud.

# _cloud_prep_ahead TEXT PLAN_FILE — do speak_cloud_chunked's setup work before
# it is called: sweep the scratch dir and split TEXT into its chunk plan, saved
# NUL-separated to PLAN_FILE. That is ~1-3s of shell work which on the hybrid
# path would otherwise run *after* the on-device voice has stopped, i.e. inside
# the handover silence (measured 2026-07-27: ~3s of the ~7s gap). Called from
# the speculative generator, it happens while the on-device voice is still
# speaking. Written to a temp name and moved into place, so a half-written plan
# is never readable by the reader on the other side.
_cloud_prep_ahead() {
  local text="$1" plan="$2" scratch
  if scratch="$(_cloud_scratch_dir)"; then
    find "$scratch" -maxdepth 1 -name 'vr-*' -type f -mmin +60 -delete 2>/dev/null
  fi
  if split_into_speech_chunks "$text" \
       "$(get_tuning_num CLOUD_CHUNK_CHARS 200)" \
       "$(get_tuning_num CLOUD_FIRST_CHUNK_CHARS 80)" > "${plan}.tmp" 2>/dev/null; then
    mv -f "${plan}.tmp" "$plan" 2>/dev/null
  fi
  rm -f "${plan}.tmp" 2>/dev/null
  return 0
}

# _hyb_spec_launch BACKEND SUFFIX_TEXT BOUNDARY — start generating the audio the
# cloud pipeline would need first if it took over at BOUNDARY. Prints the PID.
# The exit status goes to a marker file beside the audio, because the readiness
# check has to be non-blocking and `wait` is not.
_hyb_spec_launch() {
  local backend="$1" suffix_text="$2" b="$3" out
  out="$(_cloud_audio_path "$backend" "hyb-$b")" || return 1
  rm -f "${out}.rc" 2>/dev/null
  # >/dev/null is not tidiness, it is what makes this asynchronous. The PID is
  # returned through a command substitution, and a background job started inside
  # one inherits the substitution's pipe: bash waits for EVERY holder of the
  # write end to close it, so without this the caller blocks until the generator
  # exits — i.e. the on-device opening would not start until the cloud audio was
  # already finished, which is exactly the wait hybrid exists to remove
  # (measured: the opening began 53s in, after a 45s generation, instead of ~8s).
  (
    # The plan is built first and the chunk to generate is taken from it, so
    # the seed audio is by construction the same text as chunk 0 of the plan
    # speak_cloud_chunked will play from — one split instead of two, and no way
    # for the two to disagree. Falls back to a direct split if the plan could
    # not be written (read-only scratch, disk full).
    _cloud_prep_ahead "$suffix_text" "${out}.plan"
    first=""
    IFS= read -r -d '' first < "${out}.plan" 2>/dev/null || true
    [ -n "$first" ] || first="$(_cloud_first_chunk "$suffix_text")"
    gen_cloud "$backend" "$first" "hyb-$b"
    printf '%s' "$?" > "${out}.rc"
  ) >/dev/null 2>&1 &
  printf '%s' "$!"
}

# _hyb_spec_state BACKEND BOUNDARY — pending | ok | fail. "fail" is a generation
# that finished badly (no key, no network, API error) and means hybrid should
# give up on the cloud entirely rather than keep speculating into the same wall.
_hyb_spec_state() {
  local out rc
  out="$(_cloud_audio_path "$1" "hyb-$2")" || { printf 'fail'; return; }
  [ -s "${out}.rc" ] || { printf 'pending'; return; }
  rc="$(cat "${out}.rc" 2>/dev/null)"
  if [ "$rc" = "0" ] && [ -s "$out" ]; then printf 'ok'; else printf 'fail'; fi
}

# _hyb_spec_discard BACKEND BOUNDARY [PID] — abandon a candidate. The generator
# is killed best-effort (its curl is a child, hence the pkill -P) to stop paying
# for audio nobody will hear; if it survives and writes its file anyway, the
# name is per-readout and the scratch sweep in speak_cloud_chunked reclaims it.
_hyb_spec_discard() {
  local out; out="$(_cloud_audio_path "$1" "hyb-$2")" || return 0
  if [ -n "${3:-}" ]; then
    command -v pkill >/dev/null 2>&1 && pkill -P "$3" 2>/dev/null
    kill "$3" 2>/dev/null
  fi
  rm -f "$out" "${out}.rc" "${out}.plan" "${out}.plan.tmp" \
        "${out%.wav}.pcm" "${out%.mp3}-raw.mp3" 2>/dev/null
  return 0
}

# _ondevice_speech_secs TEXT — how long speak() will take to say TEXT on the
# Termux engine, as "fixed startup + chars / rate". The two terms are kept apart
# on purpose. The startup (Termux:API round trip, then the engine's own latency
# before the first syllable) does not scale with the text, and hybrid units are
# short — 26-60 chars — so the single ~5.3 chars/sec figure the unit sizing is
# based on, fitted to one 175-char run, underestimates a unit by several
# seconds. Both terms are measured; see the defaults and ONDEVICE_START_SECS /
# ONDEVICE_CHARS_PER_SEC to retune per device.
# Fitted 2026-07-27 on this device at rate 1.31, four warm runs of 19/37/64/91
# chars: 4.10s + chars/8.15, residuals within +-0.6s. The nominal ~5.3 chars/sec
# elsewhere in this file is the same data seen without an intercept, which is
# why it reads so much slower.
_ondevice_speech_secs() {
  local chars=${#1} start rate
  start="$(get_tuning_dec ONDEVICE_START_SECS 4.1)"
  rate="$(get_tuning_dec ONDEVICE_CHARS_PER_SEC 8.15)"
  awk "BEGIN{r=$rate; if(r<=0)r=8.15; printf \"%.1f\", $start + $chars/r}"
}

# _ondevice_is_warm — true when the engine spoke successfully recently enough
# that _ondevice_speech_secs can be trusted. A cold Android TextToSpeech binding
# costs about 5 extra seconds before the first syllable (measured 2026-07-27:
# 10.3s for a 10-char line that the warm model puts at 5.3s), and 5 seconds is
# far more error than the pre-play below can absorb — it would start the cloud
# voice while the on-device one is still mid-sentence. Deliberately the same
# signal and window the preflight gate in speak() uses, so "warm" means one
# thing in this file.
_ondevice_is_warm() {
  local window last now
  window="$(get_tuning_num WARM_SKIP_WINDOW 120)"
  [ "$window" -gt 0 ] 2>/dev/null || return 1
  last="$(cat "$ONDEVICE_LASTSPOKE_FILE" 2>/dev/null)"
  [ -n "$last" ] || return 1
  now="$(date +%s)"
  [ "$(( now - last ))" -lt "$window" ] 2>/dev/null
}

# _hyb_speak_with_preplay BACKEND BOUNDARY UNIT CAP — speak UNIT on the on-device
# engine and, if the cloud candidate for BOUNDARY is ready before that unit
# ends, issue its `play` while the unit is still being spoken.
#
# This is the ondevice->cloud counterpart of the CLOUD_PLAY_LEAD overlap used
# between cloud chunks, and it exists because `play` costs a ~1.9s Termux:API
# round trip that cannot be made cheaper: pre-preparing the track and resuming
# it later buys nothing (measured 2026-07-27 — a resume on an already-prepared
# track still costs 1.8-2.2s, so the cost is the round trip itself, not
# MediaPlayer's prepare). The only place to put it where nobody hears it is
# underneath the on-device voice.
#
# termux-tts-speak reports nothing until it returns, so "still speaking" has to
# be predicted rather than observed: the unit is spoken in the background and
# the `play` is issued LEAD seconds before its estimated end. The two failure
# modes are not symmetric. Firing late only leaves the gap that was already
# there; firing early makes the TTS engine and the media service — independent
# outputs that will happily run at once — talk over each other. So the default
# LEAD is deliberately shorter than the round trip it is hiding, which trades a
# little residual gap for never overlapping on an ordinary unit.
#
# Sets _HYB_PREPLAY_STARTED to the epoch the audio began at, empty if no
# pre-play happened. Nothing is consumed here: the candidate's audio and its .rc
# marker are left exactly as they were, so the caller's boundary check still
# sees "ok" and the ordinary handover runs on top of this.
_hyb_speak_with_preplay() {
  local backend="$1" b="$2" unit="$3" cap="$4"
  _HYB_PREPLAY_STARTED=""

  # A cold engine takes ~5s longer than the model says, which is exactly the
  # error that turns a hidden round trip into two voices at once. Cold means no
  # pre-play and the ordinary seam, which is what we had before this existed.
  if ! _ondevice_is_warm; then
    VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 \
      speak "$unit" "$cap" ""
    return 0
  fi

  local est lead wait_for
  est="$(_ondevice_speech_secs "$unit")"
  # Deliberately shorter than the ~1.9s round trip it hides. Two error sources
  # eat the difference: the model's own +-0.6s residual, and the fact that it
  # was fitted against termux-tts-speak alone while the sleep starts one moment
  # earlier, at speak()'s entry — its lock file, tuning lookups and chunking are
  # a few tenths on top. At 1.0 the cloud voice would still not have overlapped
  # on any of the four fitted runs, and the leftover gap is ~0.2-1.5s in place
  # of 3.3s. Raise it toward 1.9 to chase the last of the gap, at the price of
  # occasionally clipping the on-device voice's last syllable.
  lead="$(get_tuning_dec HYBRID_PREPLAY_LEAD 1.0)"
  wait_for="$(awk "BEGIN{d=$est-$lead; if(d<0.5)d=0.5; printf \"%.1f\", d}")"

  VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 \
    speak "$unit" "$cap" "" &
  local spid=$!

  sleep "$wait_for"

  # The stop switch is re-read here, not just at the loop's boundary check: this
  # is the last instant before sound comes out, and a 停止 pressed during the
  # unit must not be answered by the cloud voice starting up.
  if [ ! -e "$STOP_SWITCH_FILE" ] && [ "$(_hyb_spec_state "$backend" "$b")" = ok ]; then
    local seed; seed="$(_cloud_audio_path "$backend" "hyb-$b")"
    if [ -s "$seed" ]; then
      termux-media-player play "$seed" >/dev/null 2>&1
      _HYB_PREPLAY_STARTED="$(date +%s.%N)"
      log info "hybrid: pre-played cloud chunk 0 under the ondevice voice (unit est ${est}s, lead ${lead}s)"
    fi
  fi

  wait "$spid" 2>/dev/null
  return 0
}

speak_hybrid() {
  local backend="$1" text="$2" cap="$3"
  command -v termux-tts-speak >/dev/null 2>&1 || return 1
  command -v termux-media-player >/dev/null 2>&1 || return 1

  local unit_max ondevice_cap depth omax
  # Unit size is the granularity of the handover, so it is also the maximum
  # amount of on-device voice the listener can be made to sit through past the
  # moment the cloud became ready. 60 chars is ~11s at the on-device engine's
  # ~5.3 chars/sec, comfortably longer than any backend's generation, so the
  # usual outcome is exactly one unit on-device and no cascade at all.
  unit_max="$(get_tuning_num HYBRID_UNIT_CHARS 60)"
  # Past this many characters read on-device, stop consuming units and wait for
  # the cloud instead. Reading on and on is what wedges the Termux:API engine
  # (see the ceiling in speak()), and by this point the cloud is misbehaving
  # anyway — a few seconds of silence is the cheaper failure.
  ondevice_cap="$(get_tuning_num HYBRID_MAX_ONDEVICE_CHARS 240)"
  depth="$(get_tuning_num HYBRID_SPECULATION 1)"
  [ "$depth" -lt 1 ] && depth=1
  # A unit is spoken by a single ondevice speak() call, so it must fit under
  # that backend's own ceiling or speak() would decline it (rc 3) and the unit
  # would be silently skipped.
  omax="$(ondevice_max_chars)"
  [ "$unit_max" -gt "$omax" ] && unit_max="$omax"
  [ "$unit_max" -lt 10 ] && unit_max=10

  local units=() u
  while IFS= read -r -d '' u; do [ -n "$u" ] && units+=("$u"); done \
    < <(split_into_speech_chunks "$text" "$unit_max")
  local n=${#units[@]}
  # One unit means there is no "rest" to hand over — the whole text would be
  # read on-device and the cloud voice the user chose would never be heard. Let
  # the caller speak it the ordinary way instead.
  [ "$n" -le 1 ] && return 1

  # suffix[j] = everything from unit j to the end, i.e. what the cloud takes
  # over if the handover happens at boundary j. Built by concatenating the units
  # themselves rather than by slicing the original text, so the on-device part
  # and the cloud part meet exactly: no sentence can be dropped between them or
  # spoken twice.
  local suffix=() j p
  suffix[$(( n - 1 ))]="${units[$(( n - 1 ))]}"
  for (( j = n - 2; j >= 0; j-- )); do
    suffix[$j]="${units[$j]}${suffix[$(( j + 1 ))]}"
  done

  # How long to wait for the cloud once the on-device cap is reached, before
  # giving up and reading the remainder on-device. Longer than any healthy
  # generation, short enough not to feel like a hang.
  local wait_cap=30

  # From here on this function owns the readout, several speak() calls plus a
  # cloud pipeline long. Hold the Termux wake lock across all of it instead of
  # letting each unit take and release its own: the release is a ~1.9s API
  # round trip and would otherwise fall between the last on-device unit and the
  # cloud voice. Every exit below goes through ondevice_wake_unlock_held.
  #
  # Taken here rather than being left to the first speak(): units are spoken in
  # a background subshell now (see _hyb_speak_with_preplay), and a lock acquired
  # in a subshell would set the "held" flag only in that subshell — the release
  # at the bottom of this function would then find nothing to release and the
  # wake lock would leak for the rest of the session. Acquiring in this shell
  # also means the per-unit speak() calls find the flag already set and skip
  # their own acquisition, which is what they did before.
  VOICE_READOUT_KEEP_WAKELOCK=1
  ondevice_wake_lock

  local b=1 i=0 od_chars=0 state
  local -a spec_pid=()
  # Epoch at which a pre-played cloud chunk 0 began sounding; empty when the
  # last unit did not manage one. Set by _hyb_speak_with_preplay (dynamic scope)
  # and handed to speak_cloud_chunked so it waits the audio out instead of
  # starting it a second time.
  local _HYB_PREPLAY_STARTED=""

  while [ "$i" -lt "$n" ]; do
    if [ -e "$STOP_SWITCH_FILE" ]; then
      log skip "読み上げ停止中 (hybrid, ${i}/${n} units spoken)"
      # A pre-played chunk 0 is already coming out of the speaker, and unlike
      # the candidates below it cannot be dealt with by deleting a file.
      [ -n "$_HYB_PREPLAY_STARTED" ] && termux-media-player stop >/dev/null 2>&1
      for (( p = 0; p < n; p++ )); do
        if [ -n "${spec_pid[$p]:-}" ]; then _hyb_spec_discard "$backend" "$p" "${spec_pid[$p]}"; fi
      done
      VOICE_READOUT_KEEP_WAKELOCK=""; ondevice_wake_unlock_held
      return 0
    fi

    if [ "$i" -eq "$b" ]; then
      state="$(_hyb_spec_state "$backend" "$b")"
      if [ "$state" = pending ] && [ "$od_chars" -ge "$ondevice_cap" ]; then
        local waited=0
        while [ "$waited" -lt "$wait_cap" ] && [ "$state" = pending ]; do
          [ -e "$STOP_SWITCH_FILE" ] && break
          sleep 1
          waited=$(( waited + 1 ))
          state="$(_hyb_spec_state "$backend" "$b")"
        done
        log info "hybrid: ondevice cap reached (${od_chars} chars), waited ${waited}s for cloud -> ${state}"
      fi

      case "$state" in
        ok)
          for (( p = 0; p < n; p++ )); do
            [ "$p" -eq "$b" ] && continue
            if [ -n "${spec_pid[$p]:-}" ]; then _hyb_spec_discard "$backend" "$p" "${spec_pid[$p]}"; fi
          done
          local seed; seed="$(_cloud_audio_path "$backend" "hyb-$b")"
          rm -f "${seed}.rc" 2>/dev/null
          log info "hybrid: handing over to ${backend} at unit ${b}/${n} (${od_chars} chars read ondevice)"
          if speak_cloud_chunked "$backend" "${suffix[$b]}" "$cap" "$seed" "${seed}.plan" "$_HYB_PREPLAY_STARTED"; then
            VOICE_READOUT_KEEP_WAKELOCK=""; ondevice_wake_unlock_held
            return 0
          fi
          # Seeding means the first chunk is already in hand, so this should be
          # unreachable — but if the pipeline gives up anyway the listener has
          # heard only an opening. Finish on-device rather than stop there.
          log fallback "hybrid: cloud pipeline failed after handover, remaining via ondevice"
          break
          ;;
        fail)
          log fallback "hybrid: cloud generation failed at unit ${b}, remaining via ondevice"
          break
          ;;
        pending)
          # Throw this candidate away and aim one boundary further on.
          _hyb_spec_discard "$backend" "$b" "${spec_pid[$b]:-}"
          unset "spec_pid[$b]"
          b=$(( i + 1 ))
          log info "hybrid: cloud not ready at unit ${i}/${n}, reading on and retargeting handover to ${b}"
          ;;
      esac
    fi

    # Keep the speculation window (boundaries b .. b+depth-1) filled. This sits
    # AFTER the retarget above and BEFORE the unit is spoken, and both halves of
    # that matter: a candidate launched here generates during this unit's ~11s
    # of speech, so it has a real chance of being ready at the next boundary.
    # Filling at the top of the loop instead put the new candidate's launch
    # *after* the unit was spoken, so every boundary from the first cascade on
    # was checked microseconds after its generator started, always came back
    # pending, and the readout degenerated to entirely on-device (observed in
    # the stub harness: retarget 1→2→3, no handover, no cloud audio at all).
    for (( j = b; j < b + depth && j < n; j++ )); do
      if [ -z "${spec_pid[$j]:-}" ]; then
        spec_pid[$j]="$(_hyb_spec_launch "$backend" "${suffix[$j]}" "$j")"
      fi
    done

    # b == i+1 means the boundary check at the top of the NEXT iteration decides
    # the handover, i.e. this is the last unit before the cloud could take over
    # — the one worth hiding the play round trip under. Any earlier unit has a
    # boundary check between it and the cloud, so there is nothing to pre-play.
    if [ "$b" -eq "$(( i + 1 ))" ] && [ -n "${spec_pid[$b]:-}" ]; then
      _hyb_speak_with_preplay "$backend" "$b" "${units[$i]}" "$cap"
    else
      _HYB_PREPLAY_STARTED=""
      VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 \
        speak "${units[$i]}" "$cap" ""
    fi
    od_chars=$(( od_chars + ${#units[$i]} ))
    i=$(( i + 1 ))
  done

  # Reached either because every unit was read on-device (the handover boundary
  # ran off the end of the text) or because the cloud failed. Either way, drop
  # any candidate still in flight and speak whatever is left on-device.
  for (( p = 0; p < n; p++ )); do
    if [ -n "${spec_pid[$p]:-}" ]; then _hyb_spec_discard "$backend" "$p" "${spec_pid[$p]}"; fi
  done
  while [ "$i" -lt "$n" ]; do
    [ -e "$STOP_SWITCH_FILE" ] && break
    VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 \
      speak "${units[$i]}" "$cap" ""
    i=$(( i + 1 ))
  done
  VOICE_READOUT_KEEP_WAKELOCK=""; ondevice_wake_unlock_held
  log spoke "hybrid: ${n} units, all ondevice (no cloud handover)"
  return 0
}

speak() {
  # Checked first, before the config, before the enable toggles, before the
  # backend is even resolved. Anything that reads configuration can be
  # redirected at it; this cannot. If the user has pressed 停止, nothing in
  # this plugin speaks, whatever else it was told to do.
  if [ -e "$STOP_SWITCH_FILE" ]; then
    log_repeat skip "読み上げ停止中 (stop switch is on)"
    return 0
  fi

  local text="$1"
  local cap="${2:-90}"
  # Which of the four functions is speaking: notification | summary | full |
  # file. Selects that function's configured backend (see get_tts_backend).
  # Empty is allowed and just means "use the global setting".
  local fn="${3:-}"
  case "$(get_tts_backend "$fn")" in
    gemini|inworld|elevenlabs)
      # All cloud backends go through the chunked, prefetching pipeline (see
      # speak_cloud_chunked). It sentence-splits long text so the first chunk
      # speaks within seconds and the rest generate while earlier chunks play;
      # short text stays a single request. On a hard failure it returns 1 and we
      # fall back to ondevice, exactly as the per-backend calls used to.
      local _cloud_backend; _cloud_backend="$(get_tts_backend "$fn")"
      # "full hybrid" (HYBRID_TTS): speak the opening on the on-device engine
      # while the cloud voice generates, then hand over — see speak_hybrid.
      # Only for the full function: a notification or a one-sentence summary is
      # over before a voice change could pay for itself, and switching voices
      # inside a short phrase would be all seam and no benefit. speak_hybrid
      # returns 1 without speaking when it does not apply, and then the ordinary
      # cloud path below runs unchanged.
      if [ "$fn" = "full" ] && [ "$(get_tuning HYBRID_TTS off)" = "on" ]; then
        if speak_hybrid "$_cloud_backend" "$text" "$cap"; then
          clear_failure_notifications
          return 0
        fi
      fi
      if speak_cloud_chunked "$_cloud_backend" "$text" "$cap"; then
        clear_failure_notifications
      else
        log fallback "${_cloud_backend} backend failed, retrying via ondevice"
        VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 speak "$text" "$cap" "$fn"
      fi
      ;;
    ondevice)
      if command -v termux-tts-speak >/dev/null 2>&1; then
        # Hard length ceiling, checked before touching the engine at all.
        #
        # Termux:API wedges partway through a sustained readout and then
        # refuses every subsequent call until the app is force-stopped by
        # hand — an upstream bug open and unfixed since 2018
        # (termux/termux-api#244: "after repeated use, all termux-api
        # commands hang", not fixed by clearing app data). Nothing on this
        # side prevents it: chunking, backoff, wake-locks, removing every
        # source of concurrent interference — all were tried on 2026-07-20
        # and it still wedges.
        #
        # Since it can't be recovered from without the user physically
        # force-stopping an app, the only honest design is to never enter
        # the range where it happens. Measured on this device by reading the
        # same file three times: 250 characters completed every time, 336
        # characters failed every time, always at the same chunk. A timed
        # run put 175 characters at 33s, i.e. ~5.3 chars/sec, which places
        # that failure boundary right around a minute of speech. 240
        # characters (~45s) stays under the last known-good point with
        # margin left over.
        #
        # Over the ceiling, decline (rc 3) and let the caller degrade to a
        # summary read on-device — deliberately do NOT hand off to a cloud
        # backend. Choosing the on-device backend is a choice the user made on
        # purpose, and a registered cloud key does not override it: whoever
        # wants a cloud voice selects it explicitly. So an over-length on-device
        # readout stays on-device (the caller summarizes it and speaks the
        # summary) rather than silently switching to a cloud voice not asked for.
        local max_chars="$(ondevice_max_chars)"
        if [ "${#text}" -gt "$max_chars" ]; then
          log skip "text too long for ondevice (${#text} chars > ${max_chars}), caller will summarize"
          return 3
        fi

        if ! precleanup_stuck_tts; then
          # A live call is already inside its own deadline — leave it alone
          # instead of SIGKILLing it (see precleanup_stuck_tts for why that
          # used to self-inflict the very engine-wedge this exists to clear).
          log skip "ondevice readout already in progress, skipping this one"
          return 0
        fi

        # Fail fast on an already-wedged engine instead of only finding out
        # after the full-length call below times out (up to $cap seconds —
        # minutes, for a long full-mode readout).
        #
        # Warm-skip: the probe itself binds the engine (~2s) and runs before
        # every readout. When the last readout succeeded within the warm window
        # the engine is still up, so skip the probe and let the speak call's own
        # timeout+retry catch the rare case where it went cold anyway (that one
        # readout is slower; the safety net is not lost). Fewer probes also means
        # one less engine-binding operation to collide with a concurrent call.
        local warm_window last_spoke now_secs skip_preflight=0
        warm_window="$(get_tuning_num WARM_SKIP_WINDOW 120)"
        if [ "$warm_window" -gt 0 ] 2>/dev/null; then
          last_spoke="$(cat "$ONDEVICE_LASTSPOKE_FILE" 2>/dev/null)"
          now_secs="$(date +%s)"
          if [ -n "$last_spoke" ] && [ "$(( now_secs - last_spoke ))" -lt "$warm_window" ] 2>/dev/null; then
            skip_preflight=1
          fi
        fi
        if [ "$skip_preflight" -eq 0 ] && ! engine_is_responsive; then
          log error "ondevice engine not responding to preflight probe"
          notify_failure
          start_recovery_watcher
          return 0
        fi

        local tts_args=(-r "$(resolve_speed TTS_RATE 1.01)" -p "$(get_tuning TTS_PITCH 1.0)")
        [ -n "${VOICE_READOUT_TTS_ENGINE:-}" ] && tts_args+=(-e "$VOICE_READOUT_TTS_ENGINE")
        [ -n "${VOICE_READOUT_TTS_LANG:-}" ] && tts_args+=(-l "$VOICE_READOUT_TTS_LANG")
        [ -n "${VOICE_READOUT_TTS_REGION:-}" ] && tts_args+=(-n "$VOICE_READOUT_TTS_REGION")
        [ -n "${VOICE_READOUT_TTS_VARIANT:-}" ] && tts_args+=(-v "$VOICE_READOUT_TTS_VARIANT")
        # Scale the timeout with text length: a fixed 10s cut long (but
        # healthy) readouts mid-sentence and misreported them as a stuck
        # engine. Byte count (Japanese is ~3 bytes/char in UTF-8; ~4 chars/sec
        # observed at rate 1.3) — deliberately generous. Cap is per-caller:
        # one-sentence summaries pass the 90s default; full-text readouts
        # pass a much larger cap since a genuine multi-paragraph readout can
        # legitimately run minutes (this hook is async, so it doesn't block
        # the interactive session either way).
        local bytes timeout_secs
        bytes="$(printf '%s' "$text" | wc -c)"
        timeout_secs=$(( 10 + bytes / 4 ))
        [ "$timeout_secs" -gt "$cap" ] && timeout_secs="$cap"

        # Recorded so a concurrent invocation's precleanup_stuck_tts can tell
        # this call is still within its expected window rather than stuck.
        printf '%s:%s' "$$" "$(( $(date +%s) + timeout_secs ))" > "$ONDEVICE_LOCK_FILE" 2>/dev/null

        # A long full-mode readout can run this Termux-hosted shell for over a
        # minute with no foreground activity, which looks to Android like a
        # background process overstaying its welcome — plausibly why OS-level
        # "keeps stopping" / restart warnings kept appearing right around
        # long-readout completion even when this script logged a clean
        # success (2026-07-20). termux-wake-lock is Termux's own mechanism for
        # telling Android "this is intentional, don't idle/kill it" during
        # exactly this kind of extended background work.
        ondevice_wake_lock

        # One long call per readout used to trip the ResultReturner issue
        # above regardless of wake-locking, so speak it as several short
        # calls instead — each chunk gets its own timeout scaled the same way
        # the whole text used to.
        local chunk_max="$(get_tuning_num TTS_CHUNK_CHARS 100)"
        local chunk_retries="$(get_tuning_num TTS_CHUNK_RETRIES 4)"
        # Linear backoff between attempts: base, 2x base, 3x base, capped.
        local retry_wait_base="$(get_tuning_num TTS_RETRY_WAIT_BASE 20)"
        local retry_wait_max="$(get_tuning_num TTS_RETRY_WAIT 90)"
        # Collect every chunk up front rather than streaming them into a
        # `while read` loop. termux-tts-speak / termux-tts-engines drain
        # whatever stdin they inherit (verified 2026-07-20: a 7-item loop ran
        # exactly one iteration once a termux-* call was placed inside it),
        # so with a process substitution feeding the loop they ate the
        # remaining chunks — the readout stopped a few chunks in, and because
        # every chunk that *did* run succeeded, it was then logged as a clean
        # success with an undercounted chunk total. Reading into an array
        # first removes the shared stdin entirely; the </dev/null on each
        # termux call below is the second line of defence.
        local chunks=() chunk
        while IFS= read -r -d '' chunk; do
          [ -n "$chunk" ] && chunks+=("$chunk")
        done < <(split_into_speech_chunks "$text" "$chunk_max")

        local total_chunks="${#chunks[@]}"
        local chunk_count=0 failed=0 rc=0
        for chunk in "${chunks[@]}"; do
          # Re-checked every chunk, not just once on the way in. Checking only
          # at the top of speak() meant pressing 停止 during a long readout
          # silenced the *next* readout while the current one talked on to the
          # end — minutes, with retries. Here it takes effect within one
          # chunk and the remaining chunks are dropped, which is what someone
          # reaching for a stop button actually wants.
          if [ -e "$STOP_SWITCH_FILE" ]; then
            log skip "読み上げ停止中 (stop switch pressed mid-readout, ${chunk_count}/${total_chunks} spoken)"
            rm -f "$ONDEVICE_LOCK_FILE" 2>/dev/null
            ondevice_wake_unlock
            return 0
          fi
          chunk_count=$(( chunk_count + 1 ))
          local cbytes ctimeout attempt
          cbytes="$(printf '%s' "$chunk" | wc -c)"
          ctimeout=$(( 10 + cbytes / 4 ))
          [ "$ctimeout" -gt "$cap" ] && ctimeout="$cap"

          # A flat 1s pause-and-retry (the old design) mostly just hit the
          # same still-wedged engine again — recovery-watcher.sh's own log
          # shows real recoveries taking anywhere from well under a minute to
          # much longer. The user has explicitly said a slower-but-eventually-
          # completes readout beats a fast failure (2026-07-20), so this waits
          # for engine_is_responsive to actually confirm recovery (bounded by
          # retry_wait_max) between attempts instead of guessing, and allows
          # more attempts than before.
          rc=0
          for attempt in $(seq 1 "$chunk_retries"); do
            # Refresh the shared deadline before every attempt (including the
            # first) so a concurrent invocation's precleanup_stuck_tts sees
            # "still legitimately in flight" throughout potentially several
            # minutes of retrying, rather than "past its original deadline,
            # safe to kill" — which would recreate the self-inflicted
            # collision this lock exists to prevent.
            printf '%s:%s' "$$" "$(( $(date +%s) + ctimeout + retry_wait_max + 10 ))" > "$ONDEVICE_LOCK_FILE" 2>/dev/null
            timeout "$ctimeout" termux-tts-speak "${tts_args[@]}" "$chunk" </dev/null
            rc=$?
            [ "$rc" -eq 0 ] && break
            [ "$attempt" -eq "$chunk_retries" ] && break

            # Not precleanup_stuck_tts here: its lock check would see our own
            # still-valid deadline (just refreshed above) and refuse to touch
            # anything — correct for other invocations, wrong for cleaning up
            # our own just-failed attempt before retrying it.
            local stale_pids
            stale_pids="$(ps aux 2>/dev/null | awk '$0 ~ /libexec\/termux-api TextToSpeech/ && $0 !~ /awk|grep/ {print $2}')"
            [ -n "$stale_pids" ] && kill -9 $stale_pids 2>/dev/null

            # Deliberately does NOT poll engine_is_responsive while waiting.
            # Every probe is itself a fresh binding attempt, and a probe that
            # times out leaves its libexec/termux-api child alive holding that
            # binding (timeout signals the sh wrapper, not the grandchild) —
            # observed 2026-07-20 with two stuck LIST_AVAILABLE probes
            # accumulating during a single recovery wait. Polling every few
            # seconds therefore piles connections onto an engine that is
            # already refusing to serve them, which plausibly explains why a
            # wedged engine "never recovered on its own" and always seemed to
            # need a manual force-stop. Waiting quietly gives the engine an
            # idle window to unwedge in; the retry itself is the next probe.
            local backoff=$(( retry_wait_base * attempt ))
            [ "$backoff" -gt "$retry_wait_max" ] && backoff="$retry_wait_max"
            log info "chunk ${chunk_count}/${total_chunks} attempt ${attempt}/${chunk_retries} failed, backing off ${backoff}s"
            printf '%s:%s' "$$" "$(( $(date +%s) + ctimeout + backoff + 30 ))" > "$ONDEVICE_LOCK_FILE" 2>/dev/null
            # Slept in slices rather than one long sleep so 停止 lands here
            # too: a minute of backoff is exactly the sort of quiet gap where
            # someone decides they have had enough and reaches for the button,
            # and a stop that only takes effect after the wait finishes would
            # be indistinguishable from a stop that did nothing.
            local slept=0
            while [ "$slept" -lt "$backoff" ]; do
              if [ -e "$STOP_SWITCH_FILE" ]; then
                log skip "読み上げ停止中 (stop switch pressed during backoff)"
                rm -f "$ONDEVICE_LOCK_FILE" 2>/dev/null
                ondevice_wake_unlock
                return 0
              fi
              sleep 2
              slept=$(( slept + 2 ))
            done
          done
          if [ "$rc" -ne 0 ]; then
            failed=1
            break
          fi
        done

        rm -f "$ONDEVICE_LOCK_FILE" 2>/dev/null
        # Report spoken/total, not just a bare count: an undercount silently
        # passing as success is exactly what the stdin-drain bug above looked
        # like from the log, so make a partial readout visible on its face.
        if [ "$failed" -eq 0 ] && [ "$chunk_count" -eq "$total_chunks" ]; then
          log spoke "termux-tts-speak (${tts_args[*]}, ${chunk_count}/${total_chunks} chunks, timeout ${timeout_secs}s total budget)"
          # Mark the engine confirmed-warm so the next readout within the warm
          # window can skip the preflight probe (see the preflight gate above).
          date +%s > "$ONDEVICE_LASTSPOKE_FILE" 2>/dev/null
          # Backgrounded: it is the tidying-up of a hang that is already over,
          # and its termux-notification-remove is another ~1.9s Termux:API round
          # trip. Called synchronously it landed between the last on-device unit
          # and the cloud voice — measured 2026-07-27, a 3.3s handover seam
          # became 5.3s on the first readout after a recovery.
          clear_failure_notifications &
        else
          log error "termux-tts-speak timed out or failed (exit $rc, stopped at chunk ${chunk_count}/${total_chunks})"
          precleanup_stuck_tts
          notify_failure
          start_recovery_watcher
        fi
        ondevice_wake_unlock
      elif speak_windows_sapi "$text"; then
        # Not on the phone: fall back to the host's built-in on-device voice.
        # None of the Termux length-ceiling / chunking / wedge-recovery above
        # applies — that machinery exists solely for the Termux:API engine bug.
        clear_failure_notifications
      else
        log error "no on-device TTS available (need termux-tts-speak, or PowerShell/SAPI on Windows)"
      fi
      ;;
    *)
      # Future TTS backends (e.g. cloud APIs) plug in here.
      log error "unknown TTS backend: ${VOICE_READOUT_TTS_BACKEND:-}"
      ;;
  esac
}
