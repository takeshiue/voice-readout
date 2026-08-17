# Shared TTS helpers for voice-readout hooks. Sourced, not executed.
# Callers must be registered with "async": true and must always exit 0.

# json_get_field / have_jq / _json_escape — portable JSON field reads with a
# PowerShell fallback for hosts without jq (see json-lib.sh for why).
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/json-lib.sh"

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

# Per-engine knobs: KEY_<BACKEND> if that is set, otherwise KEY, otherwise the
# built-in default. The knobs governing chunk sizes and how far ahead to
# generate are not preferences, they are descriptions of an engine — how fast it
# generates, how fast it speaks, whether it drops text — and those differ enough
# between backends that one shared value is guaranteed to be wrong for somebody.
# Every figure tuned on this device so far was measured on whichever engine
# happened to be selected that hour, and then applied to all of them: gemini
# generates roughly twice as slowly as elevenlabs relative to how fast it speaks,
# so a chunk size that leaves elevenlabs 30s of slack leaves gemini seconds.
#
# _num and _dec variants mirror get_tuning_num / get_tuning_dec, and both fall
# through the same way, so a config with no per-engine keys behaves exactly as
# it did before.
_tuning_backend_key() {
  printf '%s_%s' "$1" "$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
}

# Built-in defaults that differ per engine. Not a convenience: the shipped
# numbers were all measured on elevenlabs, and almost nobody will be using
# elevenlabs. Its free tier is ~10 minutes a month and forbids commercial use,
# so choosing it means choosing to pay; inworld most people have never heard of.
# Gemini's free tier is what makes a cloud voice reachable at all, which makes it
# the engine the DEFAULTS have to suit — and gemini is the one they fit worst,
# generating at 0.8-1.0x playback where elevenlabs manages 0.55x, with a 6-10s
# first generation. Someone installing this and asking for the free cloud voice
# would otherwise start with numbers measured on an engine they are not using,
# with no way to know the numbers exist. Measured 2026-07-28; a per-engine config
# key still overrides all of it.
_engine_default() {  # KEY BACKEND — prints a default, or fails if there is none
  case "$1:$2" in
    HYBRID_MIN_ONDEVICE_CHARS:gemini) printf '60' ;;   # cover a 6-10s first generation
    HYBRID_PREGEN_CHUNKS:gemini)      printf '3' ;;    # little slack, so work further ahead
    CLOUD_SECOND_CHUNK_CHARS:gemini)  printf '200' ;;  # ~6s of fixed TTFB: do not slice it thin
    *) return 1 ;;
  esac
}
get_tuning_num_for() {  # KEY BACKEND DEFAULT
  local d; d="$(_engine_default "$1" "$2")" || d="$3"
  get_tuning_num "$(_tuning_backend_key "$1" "$2")" "$(get_tuning_num "$1" "$d")"
}
get_tuning_dec_for() {  # KEY BACKEND DEFAULT
  local d; d="$(_engine_default "$1" "$2")" || d="$3"
  get_tuning_dec "$(_tuning_backend_key "$1" "$2")" "$(get_tuning_dec "$1" "$d")"
}

# How far ahead of a chunk's end to issue the next chunk's play. What has to be
# hidden is the termux-media-player round trip plus this loop's own overhead,
# and that is a property of the PHONE — its Termux:API latency, its CPU, its
# Android version. A constant here is a number measured on one device and
# shipped to everyone else's; on this one it is 2.1-3.2s, and neither the person
# on a slower phone nor the person on a faster one has any way to know that the
# figure exists, let alone what theirs should be.
#
# So it is measured, but as a CALIBRATION rather than a control loop: samples
# are collected for the first CLOUD_PLAY_LEAD_SAMPLES seams, a value is written
# once, and nothing is written or recomputed afterwards. Chasing the last
# measurement forever would be worse than a constant — a single slow moment
# would set the lead too high and clip the next chunk's last syllable — and a
# value that never settles is not a property of the phone, which is what this is
# supposed to be.
#
# The statistic is mean MINUS mean absolute deviation, not the mean. The error
# is not symmetric: too small leaves a short silence at a sentence boundary, too
# large cuts words off, and the round trip has a hard floor with a long slow
# tail, so the mean sits above the floor and would clip on every good run. This
# form also has the right instinct built in — a phone that measures consistently
# converges on its true cost and the seam disappears; an erratic one widens the
# deviation and automatically backs off to the safe side.
#
# CLOUD_PLAY_LEAD=auto (the default) means learn it. Any number there is the
# user's decision and is used as-is, with no sampling, like every other "auto"
# knob in this file.
# What to use until the learning period finishes. NOT a neutral placeholder: the
# learning period is several readouts long and the listener hears every one of
# them, so starting from a value nobody measured would mean shipping a few
# minutes of worse seams to every new install for no reason. 2.2 is the round
# trip measured on the development device, and the same order as the 1.8-2.0s
# measured across all three cloud backends — a better first guess than a smaller
# number, and wrong in the safe direction if a phone turns out to be quicker,
# since too small only leaves a short silence while too large clips words.
#
# Off Android there is nothing for the lead to hide. Everything above describes
# the Termux:API round trip, and ffplay has none of it: `play` is a local exec
# that returns in milliseconds, so starting the next chunk 2.2s early does not
# cover a gap, it overlaps 2.2s of speech with the tail of the chunk before it
# and the listener hears both at once. Measured 2026-08-15 on Windows/ffplay:
# 0 leaves no audible seam at all. So the lead — and the calibration that
# learns it, which is sampling a latency that isn't there — applies to the
# phone only. The player, not the OS, is what matters (Termux:API is the thing
# with the latency), which is why this keys off termux-media-player exactly the
# way _audio_play_start does rather than sniffing uname.
if command -v termux-media-player >/dev/null 2>&1; then
  CLOUD_PLAY_LEAD_START=2.2
else
  CLOUD_PLAY_LEAD_START=0
fi
PLAY_LEAD_FILE="${PLUGIN_DATA_DIR}/voice-readout-play-lead"
PLAY_LEAD_SAMPLE_FILE="${PLUGIN_DATA_DIR}/voice-readout-play-lead-samples"
# A notice waiting to be shown in the transcript. Written by whatever wants to
# tell the user something, read and cleared by the next SessionStart hook:
# announce_user only renders from a hook process whose stdout is still open, and
# a readout worker's is not.
PENDING_NOTICE_FILE="${PLUGIN_DATA_DIR}/voice-readout-notice"

_cloud_play_lead() {
  local v; v="$(get_tuning CLOUD_PLAY_LEAD auto)"
  case "$v" in
    ''|auto) ;;
    *[!0-9.]*) printf '%s' "$CLOUD_PLAY_LEAD_START" ; return ;;
    *) printf '%s' "$v"; return ;;
  esac
  local c; c="$(cat "$PLAY_LEAD_FILE" 2>/dev/null)"
  case "$c" in
    ''|*[!0-9.]*) printf '%s' "$CLOUD_PLAY_LEAD_START" ;;
    *)            printf '%s' "$c" ;;
  esac
}

# True while CLOUD_PLAY_LEAD is auto and no calibration has been written yet.
# Never true off Android: with ffplay the quantity being measured is zero (see
# CLOUD_PLAY_LEAD_START), so sampling 24 seams could only average up off the
# floor and reintroduce the overlap that 0 exists to avoid. auto there means
# "0, settled" rather than "0, still learning".
_cloud_play_lead_learning() {
  command -v termux-media-player >/dev/null 2>&1 || return 1
  case "$(get_tuning CLOUD_PLAY_LEAD auto)" in ''|auto) ;; *) return 1 ;; esac
  [ ! -s "$PLAY_LEAD_FILE" ]
}

# _cloud_play_lead_finish — called after enough samples have been appended.
_cloud_play_lead_finish() {
  local want; want="$(get_tuning_num CLOUD_PLAY_LEAD_SAMPLES 24)"
  local have; have="$(wc -l < "$PLAY_LEAD_SAMPLE_FILE" 2>/dev/null || echo 0)"
  [ "$have" -ge "$want" ] 2>/dev/null || return 0
  local value
  value="$(awk '{ s += $1; v[NR] = $1 }
                END { if (NR == 0) exit
                      m = s / NR
                      for (i = 1; i <= NR; i++) { d = v[i] - m; if (d < 0) d = -d; ad += d }
                      lead = m - ad / NR
                      if (lead < 0.5) lead = 0.5
                      if (lead > 4.0) lead = 4.0
                      printf "%.1f", lead }' "$PLAY_LEAD_SAMPLE_FILE")"
  [ -n "$value" ] || return 0
  printf '%s' "$value" > "$PLAY_LEAD_FILE"
  rm -f "$PLAY_LEAD_SAMPLE_FILE" 2>/dev/null
  log info "play lead calibrated to ${value}s from ${have} samples"
  printf '%s' "ボイスリードアウト：この端末に合わせて継ぎ目の調整が完了しました（${value}秒、${have}回の実測から）。やり直すには「校正をやり直して」。" \
    > "$PENDING_NOTICE_FILE"
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
  # Memoised per (key, factor) for the life of the process. Two get_tuning greps
  # plus an awk measured 0.58s per call here, and the on-device path calls this
  # once per unit — on a hybrid readout that is a fixed cost paid several times
  # over, all of it inside the window the cloud generation is racing against.
  # Cache key is flattened into a variable name because bash 3 (macOS) has no
  # associative arrays and this file still has to run there.
  local cvar; cvar="_RESOLVE_SPEED_CACHE_${key}_${factor//./_}"
  if [ -n "${!cvar:-}" ]; then printf '%s' "${!cvar}"; return; fi
  val="$(get_tuning "$key" auto)"
  local out
  case "$val" in
    ''|auto) out="$(awk -v s="$(get_tuning READOUT_SPEED 1.2)" -v f="$factor" 'BEGIN{printf "%.2f", s*f}')" ;;
    *)       out="$val" ;;
  esac
  # Config changes mid-readout are not a case worth serving: the readout already
  # in flight was planned against the old value, and honouring a new one halfway
  # would change speed mid-sentence.
  printf -v "$cvar" '%s' "$out" 2>/dev/null || eval "$cvar=\$out"
  printf '%s' "$out"
}

# Surface a one-line notice to the USER in the Claude Code transcript. The hook
# JSON protocol shows a `systemMessage` field to the user; plain SessionStart
# stdout, by contrast, is fed to Claude's context and never displayed. This also
# renders from an "async": true hook, but only once that hook process exits — so
# callers emit it from the fast-returning hook process, never from a detached
# worker whose stdout is already closed. No-op on empty text (rather than emit
# broken JSON that would leak into Claude's context instead). Builds the JSON
# with jq when available; otherwise hand-escapes the one string field itself
# (_json_escape, from json-lib.sh) rather than requiring jq for output this
# simple.
announce_user() {
  local text="$1"
  [ -n "$text" ] || return 0
  if have_jq; then
    jq -cn --arg m "$text" '{systemMessage: $m}'
  else
    printf '{"systemMessage":"%s"}\n' "$(_json_escape "$text")"
  fi
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
    fishaudio) echo fishaudio ;;
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

get_fishaudio_api_key() {
  if [ -n "${VOICE_READOUT_FISHAUDIO_API_KEY:-}" ]; then
    printf '%s' "$VOICE_READOUT_FISHAUDIO_API_KEY"
    return
  fi
  get_env_value FISHAUDIO_API_KEY
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
  # 240 is a Termux:API number: it exists to stay clear of the engine hang
  # described in speak()'s ondevice branch (measured there as 250 chars fine /
  # 336 chars wedged every time). SAPI has no such failure — a 1053-char readout
  # completed on it unaided (2026-08-15) — so applying Android's ceiling off
  # Android would cap the on-device voice for a bug it cannot have. It matters
  # for hybrid in particular: the opening has to cover the cloud's first-sound
  # wait, 13-15s on gemini, and 240 chars is only ~45s at the on-device pace, so
  # a ceiling far above it leaves the handover free to pick the length it needs.
  # An explicit ONDEVICE_MAX_CHARS still wins on either platform.
  local d=240
  command -v termux-tts-speak >/dev/null 2>&1 || d=2000
  printf '%s' "$(get_tuning_num ONDEVICE_MAX_CHARS "$d")"
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

# _capture_played_file FILE TAG — mirror an audio file into CAPTURE_DIR as it
# goes out to the speaker, for screen recordings.
#
# Android's internal-audio capture does not hear this plugin. A screen recorder
# set to "internal audio" picks up the on-device engine (termux-tts-speak hands
# off to the system TTS app, which is capturable) but records digital silence
# for everything termux-media-player plays. Measured 2026-07-29 on a hybrid
# readout: the 122 chars read on-device are in the recording at -16dB, the
# ElevenLabs remainder — 15s of audio the phone definitely played — is all-zero
# samples. So a recording of a cloud or hybrid readout loses its voice halfway
# through, with nothing on screen to say why.
#
# Re-recording the voice by hand off the speaker would work and sound like it.
# This is the cheaper half: the exact file that was played, plus the wall-clock
# instant it started, so the track can be rebuilt against the video afterwards.
# Only files pass through here — an on-device unit has no file to copy, but that
# half is the half the recorder already gets, so between the two the whole
# readout is recoverable.
#
# Call it just AFTER the play returns, not before. The file is still on disk
# there (every caller cleans up later, once the poll is done), and "play
# returned" is what this script already treats as the moment audio began —
# _PLAY_LAST_AUDIO_AT is set from exactly that instant. Timestamping before the
# call would put every capture ~2s early, which is the whole Termux:API round
# trip and more than enough to hear as lip-sync drift.
#
# Off unless CAPTURE_DIR names a directory. Copies are never cleaned up: this is
# a recording aid you point at a scratch dir and empty yourself, and silently
# deleting takes would defeat it. Failures are ignored — a recording aid must
# never be able to break a readout.
_capture_played_file() {
  local file="$1" tag="${2:-}"
  # Resolved once per process. get_tuning falls through to a grep of the config
  # file whenever the env var is unset, which is the normal case, and this sits
  # in the seam path of every chunk — the default must cost nothing after the
  # first call.
  if [ -z "${_CAPTURE_DIR_MEMO+set}" ]; then
    _CAPTURE_DIR_MEMO="$(get_tuning CAPTURE_DIR '')"
  fi
  [ -n "$_CAPTURE_DIR_MEMO" ] || return 0
  [ -s "$file" ] || return 0
  mkdir -p "$_CAPTURE_DIR_MEMO" 2>/dev/null || return 0
  local at name
  at="${EPOCHREALTIME:-$(date +%s.%N)}"
  # Sortable, collision-free, and carries its own timestamp: two chunks can be
  # copied inside the same second, and $$ separates concurrent hooks.
  name="$(date +%Y%m%d-%H%M%S)-$$-${tag:-clip}.${file##*.}"
  cp "$file" "$_CAPTURE_DIR_MEMO/$name" 2>/dev/null || return 0
  # Absolute epoch, not an offset from the first capture: the video it gets
  # aligned to started at some unrelated moment, and the offset is worked out
  # against that later. Tab-separated so awk can drive the assembly.
  printf '%s\t%s\t%s\n' "$at" "$name" "$tag" >>"$_CAPTURE_DIR_MEMO/capture.tsv" 2>/dev/null
  return 0
}

# Cross-platform playback primitives. termux-media-player is Termux:API's only
# path to the phone speaker and stays the sole implementation on Android. Off
# Android — detected simply by termux-media-player's absence — ffplay (bundled
# with the ffmpeg this plugin already requires for the cloud backends, so no
# new dependency to document) plays the same WAV/MP3 files with no GUI window.
# Both players are fire-and-forget (their "play" returns immediately), so every
# caller already polls _audio_is_playing / calls _audio_stop rather than
# blocking on play itself — that shape carries over unchanged; only what is
# underneath it differs. ffplay exposes no equivalent of `info`, so its
# "is it still playing" is tracked here as a PID or the ffplay side of this
# is really just process liveness.
FFPLAY_PID_FILE="${PLUGIN_DATA_DIR}/voice-readout-ffplay.pid"
# The on-device (SAPI) host's pid while it is speaking. Exists for the same reason
# FFPLAY_PID_FILE does — something has to be killable — but for the on-device
# voice, whose Speak()/PlaySync() cannot be interrupted from inside.
SAPI_PID_FILE="${PLUGIN_DATA_DIR}/voice-readout-sapi.pid"

# Kill an in-flight on-device utterance. Used by the stop switch, and by anything
# that needs the speaker quiet now rather than at the end of the sentence.
_sapi_stop() {
  local pid; pid="$(cat "$SAPI_PID_FILE" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  # Killing the bash-side job is not enough on Windows: powershell.exe is a
  # separate Win32 process holding the audio device, and it survives its parent.
  # taskkill /T takes the tree; the bash kill is the fallback where it is absent.
  if command -v taskkill >/dev/null 2>&1; then
    local wpid
    # ps in Git Bash reports the Windows pid in the WINPID column.
    wpid="$(ps -W 2>/dev/null | awk -v p="$pid" '$1==p {print $4; exit}')"
    [ -n "$wpid" ] && taskkill //PID "$wpid" //T //F >/dev/null 2>&1
  fi
  kill "$pid" 2>/dev/null
  local waited=0
  while [ "$waited" -lt 15 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1; waited=$(( waited + 1 ))
  done
  rm -f "$SAPI_PID_FILE" 2>/dev/null
}

_audio_player_available() {
  command -v termux-media-player >/dev/null 2>&1 || command -v ffplay >/dev/null 2>&1
}

# Is there an on-device (no key, no network) voice on this platform? The two
# implementations are Android's termux-tts-speak and Windows' SAPI, and speak()'s
# ondevice branch already picks between them; this is for callers that need to
# know BEFORE committing to a path — speak_hybrid, which must decline cleanly and
# let the ordinary cloud path run rather than half-start a handover it cannot
# finish. Kept beside _audio_player_available because they are asked together.
_ondevice_voice_available() {
  command -v termux-tts-speak >/dev/null 2>&1 && return 0
  # Mirrors speak_windows_sapi's own requirement (PowerShell + System.Speech).
  command -v powershell.exe >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1
}

_audio_play_start() {
  local file="$1"
  if command -v termux-media-player >/dev/null 2>&1; then
    termux-media-player play "$file" >/dev/null 2>&1
    return
  fi
  command -v ffplay >/dev/null 2>&1 || return 1
  ffplay -nodisp -autoexit -loglevel quiet "$file" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  printf '%s' "$!" > "$FFPLAY_PID_FILE" 2>/dev/null
}

_audio_is_playing() {
  if command -v termux-media-player >/dev/null 2>&1; then
    termux-media-player info 2>/dev/null | grep -q 'Status: Playing'
    return
  fi
  local pid; pid="$(cat "$FFPLAY_PID_FILE" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_audio_stop() {
  # The on-device voice too, not just the clip player: on Windows these are two
  # different processes and "stop the audio" has to mean both, or a stop pressed
  # during the on-device half of a hybrid readout silences the cloud voice that
  # is not playing yet and leaves the one that is.
  _sapi_stop
  if command -v termux-media-player >/dev/null 2>&1; then
    termux-media-player stop >/dev/null 2>&1
    return
  fi
  local pid; pid="$(cat "$FFPLAY_PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    # A bare kill only sends the signal — it does not wait for the process (and
    # the file handle it holds) to actually go away. Every caller rm's the audio
    # file immediately after calling this, and that raced ffplay's own shutdown
    # on Windows ("Device or resource busy", observed 2026-07-31). Bounded at
    # 2s so a wedged ffplay can't hang the caller.
    local waited=0
    while [ "$waited" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 0.1
      waited=$(( waited + 1 ))
    done
  fi
  rm -f "$FFPLAY_PID_FILE" 2>/dev/null
}

# Play a pre-rendered fixed-phrase clip (a bundled .wav) through the phone
# speaker, returning 0 if it played and 1 if the clip is unavailable so the
# caller can fall back to live TTS of the phrase. These "決まり文句" are
# rendered once with a good cloud voice and shipped in assets/, so they cost no
# API call and no engine time at readout.
#
# Two constraints mirror speak_gemini(): a bundled player is the only path to
# the real speaker (no /dev/snd in a Termux proot, and no audio device opened
# directly by this shell on Windows either), and on Termux specifically that
# player can only open files under $TERMUX_HOME/storage — the bundled asset
# lives on the proot side, so copy it into the scratch dir first
# (_cloud_scratch_dir, shared with the cloud backends below). The stop switch
# is honoured up front so a fixed cue can't slip through after the user has
# silenced readout. The optional 2nd arg picks how the clip is timed:
#   wait   (default) — block until the clip finishes, then stop the player, so a
#          readout that FOLLOWS the clip (the overflow summary, the pipeline
#          summary) can't talk over it. Costs extra player round trips (info
#          poll + stop), ~2s each on Termux.
#   nowait — the clip is terminal: nothing is spoken after it (a notification
#          cue, the recovery announce, the session-end farewell). Don't poll and
#          don't stop — every termux-media-player sub-command is a ~2s Termux:API
#          round trip, and here they buy nothing. `play` hands the clip to
#          the OS media service, which finishes it on its own even after this
#          process exits (verified with the session-end clip on Termux). This is
#          what makes a fixed notification cue sound promptly instead of ~8s later.
play_notice_clip() {
  local clip="$1"
  local mode="${2:-wait}"
  [ -e "$STOP_SWITCH_FILE" ] && return 0
  [ -f "$clip" ] || return 1
  _audio_player_available || return 1
  local scratch_dir; scratch_dir="$(_cloud_scratch_dir)" || return 1
  local dest="$scratch_dir/$(basename "$clip")"
  # Same guard as gen_cloud: a fixed name in a shared directory, so clear
  # whatever is at it before copying rather than following a link.
  rm -f "$dest" 2>/dev/null
  cp "$clip" "$dest" 2>/dev/null || return 1
  if ! _audio_play_start "$dest"; then
    rm -f "$dest"
    return 1
  fi
  _capture_played_file "$dest" clip
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
    _audio_is_playing || break
  done
  _audio_stop
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
  # Optional 4th arg: the same for the SECOND chunk. The first chunk is the only
  # thing covering the second one's generation, and it is deliberately tiny, so
  # that one seam has far less room than any other: measured 2026-07-28 on
  # elevenlabs v3, a 73-char chunk 0 buys 10.8s of playback while a 197-char
  # chunk 1 takes 17.4s to generate — 1.2s of margin, against 30s+ everywhere
  # after it. A middle step turns the schedule into 80 -> ~120 -> max, which is
  # the growing-chunk idea narrowed to the one seam that needs it. Later chunks
  # do not need it: by then two chunks of playback are covering each generation.
  local second_max="${4:-$max}"
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
    # First chunk fills to first_max, second to second_max, the rest to max.
    case "$emitted" in
      0) lim="$first_max" ;;
      1) lim="$second_max" ;;
      *) lim="$max" ;;
    esac
    if [ -n "$chunk" ] && [ $(( ${#chunk} + ${#p} )) -gt "$lim" ]; then
      printf '%s\0' "$chunk"
      emitted=$(( emitted + 1 ))
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
  local url="$1" auth="$2" payload="$3" out="$4" extra="${5:-}" body esc esc2 rc
  # Prefer the plugin's own 0700 data dir over a shared /tmp; fall back only if
  # that is somehow unusable, since failing here would silence the readout.
  body="$(mktemp "${PLUGIN_DATA_DIR}/vr-req.XXXXXX" 2>/dev/null \
          || mktemp "${TMPDIR:-/tmp}/vr-req.XXXXXX")" || return 1
  chmod 600 "$body" 2>/dev/null
  printf '%s' "$payload" > "$body"
  esc="$(printf '%s' "$auth" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  # EXTRA (5th arg, optional) is a second header for vendors that need one
  # besides the credential — Fish Audio selects its model that way rather than
  # in the body. It goes through the same --config file as the credential
  # instead of a plain -H so that neither can be read out of the process list.
  esc2="$(printf '%s' "$extra" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  curl -sS --max-time "$(get_tuning_num CLOUD_HTTP_TIMEOUT 45)" \
    -X POST "$url" \
    -H 'Content-Type: application/json' \
    -d "@$body" \
    -o "$out" -w '%{http_code}' \
    --config - <<CURLCFG
header = "$esc"
${extra:+header = "$esc2"}
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
  if ! command -v ffmpeg >/dev/null 2>&1 || ! _audio_player_available; then
    log error "gemini backend needs ffmpeg + a player (termux-media-player, or ffplay on Windows), one is missing"
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

  # The file must live somewhere the player can open by path. On Termux that
  # means $TERMUX_HOME specifically (this proot's own /tmp isn't bind-mounted
  # into the real Termux filesystem the media player sees); off Termux, ffplay
  # runs directly in this same shell so any private scratch dir works —
  # _cloud_scratch_dir picks the right one for whichever player is present.
  local scratch_dir; scratch_dir="$(_cloud_scratch_dir)" || return 1
  local pcm_file="$scratch_dir/audio-$$.pcm"
  local wav_file="$scratch_dir/audio-$$.wav"
  printf '%s' "$audio_b64" | base64 -d > "$pcm_file" 2>/dev/null
  if ! ffmpeg -y -f s16le -ar 24000 -ac 1 -i "$pcm_file" "$wav_file" -loglevel error 2>/dev/null; then
    log error "gemini TTS: ffmpeg failed to build wav"
    rm -f "$pcm_file" "$wav_file"
    return 1
  fi
  rm -f "$pcm_file"

  _audio_play_start "$wav_file"
  _capture_played_file "$wav_file" gemini

  # The player is fire-and-forget (play returns immediately), so poll until
  # playback stops to know when we're done.
  local waited=0
  while [ "$waited" -lt "$cap" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    _audio_is_playing || break
  done
  _audio_stop
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
  if ! _audio_player_available; then
    log error "inworld backend needs a player (termux-media-player, or ffplay on Windows), none found"
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

  # Same path constraint as the Gemini backend — see _cloud_scratch_dir for why
  # this differs between Termux and everywhere else.
  local scratch_dir; scratch_dir="$(_cloud_scratch_dir)" || return 1
  local wav_file="$scratch_dir/audio-$$.wav"
  printf '%s' "$audio_b64" | base64 -d > "$wav_file" 2>/dev/null
  if [ ! -s "$wav_file" ]; then
    log error "inworld TTS: base64 decode produced an empty file"
    rm -f "$wav_file"
    return 1
  fi

  _audio_play_start "$wav_file"
  _capture_played_file "$wav_file" inworld

  local waited=0
  while [ "$waited" -lt "$cap" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    _audio_is_playing || break
  done
  _audio_stop
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
  if ! _audio_player_available; then
    log error "elevenlabs backend needs a player (termux-media-player, or ffplay on Windows), none found"
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

  local scratch_dir; scratch_dir="$(_cloud_scratch_dir)" || return 1
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

  _audio_play_start "$play_file"
  _capture_played_file "$play_file" elevenlabs

  local waited=0
  while [ "$waited" -lt "$cap" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    _audio_is_playing || break
  done
  _audio_stop
  rm -f "$mp3_file" "$play_file"

  if [ "$waited" -ge "$cap" ]; then
    log error "elevenlabs TTS playback exceeded cap (${cap}s)"
    return 1
  fi
  log spoke "elevenlabs-tts (model ${model}, voice ${voice}, ${waited}s)"
  return 0
}

# Fish Audio TTS. Same shape as the ElevenLabs backend — POST text, get MP3
# back, hand the file to termux-media-player — with two differences worth
# knowing before picking it.
#
# It has a speed knob in the API (prosody.speed, 0.5-2.0), so unlike ElevenLabs
# there is no ffmpeg atempo pass afterwards: one less decode of the whole file
# per chunk, which is time taken straight out of the gap before the voice
# starts. And the model is chosen with a *header*, not a body field, which is
# why cloud_post grew a second header argument.
#
# The shipped default is the free model, and its terms are the reason this
# backend is not the default anywhere:
#   - "Requests may be used to improve model quality." This plugin sends the
#     text of Claude's replies, which is the user's own work. That is a
#     disclosure, not a detail, and it belongs in front of anyone installing
#     this from an article.
#   - No latency guarantee — "built for experimentation". The seamless-handoff
#     design rests on generation running faster than playback (~0.55x measured
#     elsewhere); a best-effort backend is free to break that assumption on any
#     given day, and the failure shows up as silence at the seams.
#   - Free access is stated to run through 2026-08-31. Set FISHAUDIO_MODEL to a
#     paid model (s1, s2-pro, s2.1-pro) to stop depending on that date.
# See docs.fish.audio/api-reference/endpoint/openapi-v1/text-to-speech.
speak_fishaudio() {
  local text="$1"
  local cap="$2"
  local api_key
  api_key="$(get_fishaudio_api_key)"
  if [ -z "$api_key" ]; then
    log error "fishaudio backend selected but no API key set (toggle.sh fishaudio-key <KEY>)"
    return 1
  fi
  if ! _audio_player_available; then
    log error "fishaudio backend needs a player (termux-media-player, or ffplay on Windows), none found"
    return 1
  fi

  local model
  model="$(sanitize_model "$(get_tuning FISHAUDIO_MODEL "${VOICE_READOUT_FISHAUDIO_MODEL:-s2.1-pro-free}")" s2.1-pro-free)"

  # A voice from the Fish Audio library, or one cloned in the account. Empty
  # means the model's own default voice, which is the only thing that works
  # without a trip to the dashboard — so that is the shipped state.
  local voice="${VOICE_READOUT_FISHAUDIO_VOICE:-$(get_tuning FISHAUDIO_VOICE '')}"

  # READOUT_SPEED times this backend's factor, like every other engine, so one
  # setting still governs them all. The factor starts at 1.0 because nothing has
  # been measured against this engine yet — the others (0.83, 1.11, 0.92) were
  # all arrived at by listening, and this one should be too. The API rejects
  # anything outside 0.5-2.0, so clamp rather than let a config typo 422 the
  # request and drop the readout to the fallback.
  local speed
  speed="$(resolve_speed FISHAUDIO_SPEED 1.0)"
  speed="$(awk -v s="$speed" 'BEGIN{ if (s+0 < 0.5) s=0.5; if (s+0 > 2.0) s=2.0; printf "%.2f", s }')"

  local payload
  # --argjson for the number: quoted, the API reads it as a string and 422s.
  payload="$(jq -n --arg text "$text" --arg voice "$voice" --argjson speed "$speed" \
    '{text: $text, format: "mp3", mp3_bitrate: 128, latency: "balanced",
      prosody: {speed: $speed}}
     + (if $voice == "" then {} else {reference_id: $voice} end)')"

  local scratch_dir; scratch_dir="$(_cloud_scratch_dir)" || return 1
  local mp3_file="$scratch_dir/audio-$$.mp3"

  local http_code
  http_code="$(cloud_post "https://api.fish.audio/v1/tts" \
                          "Authorization: Bearer ${api_key}" "$payload" "$mp3_file" \
                          "model: ${model}")"

  if [ "$http_code" != "200" ] || [ ! -s "$mp3_file" ]; then
    # 402 is the one worth naming: it is what a lapsed free tier or an exhausted
    # balance looks like, and it is indistinguishable from a bad key otherwise.
    case "$http_code" in
      402) log error "fishaudio: payment required (http 402) — free model withdrawn, or balance spent" ;;
      *)   log error "fishaudio TTS request failed (http ${http_code}): $(head -c 200 "$mp3_file" 2>/dev/null | tr -d '\n')" ;;
    esac
    rm -f "$mp3_file"
    return 1
  fi

  # Same reason as the ElevenLabs backend: cloud audio arrives at the vendor's
  # master level, which is not the on-device voice's level, and the player has
  # no volume flag to even them out with.
  local gain play_file adj_file
  gain="$(get_tuning FISHAUDIO_GAIN 1.0)"
  case "$gain" in ''|*[!0-9.]*) gain=1.0 ;; esac
  play_file="$mp3_file"
  if [ -n "$gain" ] && [ "$gain" != "1.0" ] && [ "$gain" != "1" ] && command -v ffmpeg >/dev/null 2>&1; then
    adj_file="$scratch_dir/audio-$$-adj.mp3"
    if ffmpeg -y -i "$mp3_file" -af "volume=${gain}" "$adj_file" -loglevel error 2>/dev/null && [ -s "$adj_file" ]; then
      play_file="$adj_file"
    else
      log error "fishaudio gain: ffmpeg failed (gain=${gain}), playing at original volume"
    fi
  fi

  _audio_play_start "$play_file"
  _capture_played_file "$play_file" fishaudio

  local waited=0
  while [ "$waited" -lt "$cap" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    _audio_is_playing || break
  done
  _audio_stop
  rm -f "$mp3_file" "$play_file"

  if [ "$waited" -ge "$cap" ]; then
    log error "fishaudio TTS playback exceeded cap (${cap}s)"
    return 1
  fi
  log spoke "fishaudio-tts (model ${model}, voice ${voice:-default}, speed ${speed}, ${waited}s)"
  return 0
}

# gen_fishaudio TEXT OUTFILE — produce an MP3 at OUTFILE. No playback.
# The generation half of speak_fishaudio above, which is what the chunked
# pipeline actually calls; see _gen_cloud_once. Returns 0/1.
gen_fishaudio() {
  local text="$1" out="$2" api_key model voice speed payload http
  api_key="$(get_fishaudio_api_key)"
  [ -n "$api_key" ] || { log error "fishaudio: no API key set (toggle.sh fishaudio-key <KEY>)"; return 1; }

  model="$(sanitize_model "$(get_tuning FISHAUDIO_MODEL "${VOICE_READOUT_FISHAUDIO_MODEL:-s2.1-pro-free}")" s2.1-pro-free)"
  voice="${VOICE_READOUT_FISHAUDIO_VOICE:-$(get_tuning FISHAUDIO_VOICE '')}"
  speed="$(resolve_speed FISHAUDIO_SPEED 1.0)"
  speed="$(awk -v s="$speed" 'BEGIN{ if (s+0 < 0.5) s=0.5; if (s+0 > 2.0) s=2.0; printf "%.2f", s }')"

  if have_jq; then
    payload="$(jq -n --arg text "$text" --arg voice "$voice" --argjson speed "$speed" \
      '{text: $text, format: "mp3", mp3_bitrate: 128, latency: "balanced",
        prosody: {speed: $speed}}
       + (if $voice == "" then {} else {reference_id: $voice} end)')"
  else
    # speed is already clamped to 0.5-2.0 above, safe to interpolate as-is.
    local ref_field=""
    [ -n "$voice" ] && ref_field=",\"reference_id\":\"$(_json_escape "$voice")\""
    payload="$(printf '{"text":"%s","format":"mp3","mp3_bitrate":128,"latency":"balanced","prosody":{"speed":%s}%s}' \
      "$(_json_escape "$text")" "$speed" "$ref_field")"
  fi

  http="$(cloud_post "https://api.fish.audio/v1/tts" \
                     "Authorization: Bearer ${api_key}" "$payload" "$out" \
                     "model: ${model}")"
  if [ "$http" != "200" ] || [ ! -s "$out" ]; then
    case "$http" in
      402) log error "fishaudio: payment required (http 402) — free model withdrawn, or balance spent" ;;
      *)   log error "fishaudio gen failed (http ${http}): $(head -c 200 "$out" 2>/dev/null | tr -d '\n')" ;;
    esac
    rm -f "$out"
    return 1
  fi
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

  # Delegated to bin/sapi-speak.ps1, which synthesises to memory and trims the
  # voice's fixed ~550ms of trailing silence before playing. Measured 2026-08-15:
  # 1.22s -> 0.88s for one character, and the saving is the same at any length
  # because the padding is constant. Worth having beyond politeness — the
  # on-device voice covers the cloud's first-chunk generation on a hybrid
  # handover and is called once per unit, so this is paid repeatedly inside the
  # window the cloud is racing against.
  #
  # A file rather than -Command: the trimming needs real code, and inlining it
  # through bash quoting into a PowerShell one-liner is how quoting bugs get
  # made. The script falls back to a plain Speak() if the WAV container is not
  # what it expects, so an unusual voice degrades to the old behaviour rather
  # than going silent.
  # Run it in the BACKGROUND and poll, rather than calling it and waiting.
  #
  # Speak()/PlaySync() block for the whole utterance and offer no way in, so a
  # foreground call cannot be interrupted: pressing 停止 mid-sentence left the
  # audio running to the end (observed 2026-08-15), and with a long unit that is
  # tens of seconds of speech after the switch says everything is stopped. The
  # cloud side never had this problem because its player is a separate process
  # that _audio_stop can kill; the on-device side needs the same shape.
  #
  # So: start the host detached, remember its pid, and watch the switch while it
  # runs. On 停止 the process is killed and the audio dies with it — that is what
  # makes the stop immediate here, not "immediate for the next unit".
  local sapi_script="$(dirname "${BASH_SOURCE[0]}")/sapi-speak.ps1"
  local rc sapi_pid
  if [ -f "$sapi_script" ]; then
    local win_script="$sapi_script"
    command -v cygpath >/dev/null 2>&1 && win_script="$(cygpath -w "$sapi_script")"
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$win_script" \
      -TextFile "$winpath" -Rate "$sapi_rate" &
    sapi_pid=$!
  else
    # Script missing (partial install, or running from a stripped copy): speak
    # the old way rather than not at all.
    "$ps" -NoProfile -Command \
      "Add-Type -AssemblyName System.Speech; \
       \$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; \
       \$s.Rate = $sapi_rate; \
       \$s.Speak([System.IO.File]::ReadAllText('$winpath', [System.Text.Encoding]::UTF8))" &
    sapi_pid=$!
  fi
  printf '%s' "$sapi_pid" > "$SAPI_PID_FILE" 2>/dev/null

  # 0.2s poll: fast enough that a 停止 is not audible as a delay, cheap enough
  # that a 30s unit costs 150 file tests.
  while kill -0 "$sapi_pid" 2>/dev/null; do
    if [ -e "$STOP_SWITCH_FILE" ]; then
      # Kill the whole tree: powershell.exe is a Windows process and the audio is
      # held by it, so the bash-side pid alone can leave the sound playing.
      _sapi_stop
      rm -f "$tmp" "$SAPI_PID_FILE" 2>/dev/null
      log skip "読み上げ停止中 (stop switch pressed mid-utterance, ondevice killed)"
      return 0
    fi
    sleep 0.2
  done
  wait "$sapi_pid" 2>/dev/null
  rc=$?
  rm -f "$SAPI_PID_FILE" 2>/dev/null

  rm -f "$tmp" 2>/dev/null
  if [ "$rc" -eq 0 ]; then
    log spoke "windows-sapi (rate ${sapi_rate})"
    # Speak() is synchronous, so this point IS the end of the audio — the cue can
    # be played rather than pre-concatenated (see _play_chunk_marker). One cue
    # per call, which is what makes repeated on-device fallbacks audible.
    _play_chunk_marker
    # Same stamp the termux-tts-speak path writes on success. _hyb_preplay_ok()
    # requires it to decide the on-device engine is warm enough to predict, and
    # with only the Android path writing it the file never existed on Windows, so
    # pre-play was refused on every single readout ("no pre-play, engine idle past
    # HYBRID_PREPLAY_MAX_IDLE") and the cloud's `play` was issued only after the
    # on-device voice had already stopped. That is the handover seam the listener
    # hears: 18s of it, measured 2026-08-15.
    date +%s > "$ONDEVICE_LASTSPOKE_FILE" 2>/dev/null
    return 0
  fi
  log error "windows-sapi failed (exit $rc)"
  return 1
}

# Fixed absolute path on purpose — see bin/readout-switch.sh. Every other path
# in this file is built from CLAUDE_PLUGIN_DATA; this one must not be, because
# redirecting that variable is precisely how the ordinary toggles get
# bypassed.
#
# The Termux path does not exist off Android, so a `touch` of it FAILS there
# (verified 2026-08-15 on Windows) — which meant the stop switch, the one
# mechanism that has to work when nothing else does, silently did nothing on
# Windows: readout-switch.sh created no file and speak() never saw a stop.
# Windows gets its own fixed path under USERPROFILE, chosen for the same reason
# the Termux one is what it is: a location both the readout (running under Git
# Bash) and the stop button (a separate PowerShell process) can reach. Still
# NOT derived from CLAUDE_PLUGIN_DATA — the bypass this guards against is the
# same on either platform.
if [ -n "${USERPROFILE:-}" ] && [ ! -d /data/data/com.termux ]; then
  STOP_SWITCH_FILE="$(cygpath "$USERPROFILE" 2>/dev/null || printf '%s' "$HOME")/.voice-readout-stopped"
else
  STOP_SWITCH_FILE="/data/data/com.termux/files/home/.voice-readout-stopped"
fi

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

# Scratch dir the player can reach. Echoes the path; non-zero if it can't be
# created. On Termux this must be $TERMUX_HOME/.voice-readout-tmp specifically
# — Termux:API can only open files under $TERMUX_HOME/storage, and the
# generating process is a proot container whose own /tmp is not the same
# filesystem Termux's media player sees. Off Termux (ffplay, run directly in
# this same shell) there is no such split: any private directory this process
# can write to and read back works, so use the plugin's own data directory
# instead of inventing a path nothing else needs.
_cloud_scratch_dir() {
  local d
  if command -v termux-media-player >/dev/null 2>&1; then
    d="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}/.voice-readout-tmp"
  else
    d="${PLUGIN_DATA_DIR}/.voice-readout-tmp"
  fi
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
    elevenlabs|fishaudio) printf '%s/vr-%s-%s.mp3' "$d" "$VOICE_READOUT_RUN_ID" "$2" ;;
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
  if have_jq; then
    payload="$(jq -n --arg text "$spoken" --arg voice "$voice" '{contents:[{parts:[{text:$text}]}],generationConfig:{responseModalities:["AUDIO"],speechConfig:{voiceConfig:{prebuiltVoiceConfig:{voiceName:$voice}}}}}')"
  else
    payload="$(printf '{"contents":[{"parts":[{"text":"%s"}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"%s"}}}}}' \
      "$(_json_escape "$spoken")" "$(_json_escape "$voice")")"
  fi
  # Key travels as a header via cloud_post's stdin config, not in the URL — see
  # the comment on cloud_post. Response lands in a file because that is what
  # keeps the request body off the command line too.
  response="$(mktemp "${PLUGIN_DATA_DIR}/vr-resp.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/vr-resp.XXXXXX")" || return 1
  chmod 600 "$response" 2>/dev/null
  http="$(cloud_post "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
                     "x-goog-api-key: ${api_key}" "$payload" "$response")"
  audio_b64="$(json_get_gemini_audio "$response")"
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
  if have_jq; then
    payload="$(jq -n --arg text "$text" --arg voice "$voice" --arg model "$model" --arg lang "$lang" --argjson rate "$rate" '{text:$text,voiceId:$voice,modelId:$model,language:$lang,audioConfig:{audioEncoding:"LINEAR16",sampleRateHertz:24000,speakingRate:$rate}}')"
  else
    # rate is already validated numeric above, safe to interpolate unescaped.
    payload="$(printf '{"text":"%s","voiceId":"%s","modelId":"%s","language":"%s","audioConfig":{"audioEncoding":"LINEAR16","sampleRateHertz":24000,"speakingRate":%s}}' \
      "$(_json_escape "$text")" "$(_json_escape "$voice")" "$(_json_escape "$model")" "$(_json_escape "$lang")" "$rate")"
  fi
  response="$(mktemp "${PLUGIN_DATA_DIR}/vr-resp.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/vr-resp.XXXXXX")" || return 1
  chmod 600 "$response" 2>/dev/null
  http="$(cloud_post "https://api.inworld.ai/tts/v1/voice" \
                     "Authorization: Basic ${api_key}" "$payload" "$response")"
  audio_b64="$(json_get_field_file "$response" audioContent)"
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
  if have_jq; then
    payload="$(jq -n --arg text "$text" --arg model "$model" --argjson speed "$speed" '{text:$text, model_id:$model, voice_settings:{speed:$speed}}')"
  else
    # speed is already validated numeric above (falls back to 1.0 otherwise),
    # so it is safe to interpolate unescaped; text and model go through
    # _json_escape since text is Claude's own response and may contain
    # quotes/backslashes/newlines.
    payload="$(printf '{"text":"%s","model_id":"%s","voice_settings":{"speed":%s}}' \
      "$(_json_escape "$text")" "$(_json_escape "$model")" "$speed")"
  fi
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
# The on-device counterpart of _append_chunk_marker, for engines whose finish is
# OBSERVABLE. SAPI's $s.Speak() is synchronous — it returns when the last
# syllable is out — so the cue can simply be played after it, and there is no
# file to concatenate onto anyway (PowerShell speaks straight to the speaker).
# Android needs the concat trick precisely because termux-tts-speak reports
# nothing until it returns, so nothing there knows when to play a cue.
#
# What this is FOR: counting. One cue per on-device call means the listener can
# hear how many times the local voice was used — and a hybrid readout that keeps
# falling back to it, over and over, is one where the cloud engine never catches
# up. That count is the measurement that says whether the on-device stretch is
# the right length, and without a cue there is no way to take it by ear.
#
# Played synchronously (not backgrounded): out of order it would land inside the
# next unit's speech and stop marking a boundary at all. It costs the ~0.8s of
# the clip, which is why this only runs with the toggle on.
_play_chunk_marker() {
  # The stop switch outranks everything, including a diagnostic cue: while it is
  # pressed NOTHING may come out of the speaker. This function was missing the
  # test and kept clicking through a stopped readout (2026-08-15) — a stop that
  # still makes noise is not a stop, which is the whole premise of the switch
  # (see bin/readout-switch.sh). A bare file test, cheaper than the config read
  # below and correct to put first.
  [ -e "$STOP_SWITCH_FILE" ] && return 0
  # Then the toggle, before the two filesystem checks: it is the cheapest of them
  # and the one that is false almost always, so the off case stays a single grep
  # — measured 0.31s when the file tests ran first, on a call that was going to
  # return immediately anyway.
  [ "$(get_tuning CHUNK_MARKER off)" = "on" ] || return 0
  [ -f "$CHUNK_MARKER_CLIP" ] || return 0
  command -v ffplay >/dev/null 2>&1 || return 0
  ffplay -nodisp -autoexit -loglevel error "$CHUNK_MARKER_CLIP" >/dev/null 2>&1
  return 0
}

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
  _gen_cloud_once "$backend" "$text" "$out" || return 1

  # A backend can return audio that stops partway through the text — measured
  # 2026-07-28 on gemini: 184 characters that take 25.2s to read came back as
  # 16.8s, a third of the sentence simply missing. Nothing about the response
  # says so; it is a valid, complete, short file, and the pipeline played it and
  # moved on. The listener hears the readout cut mid-sentence.
  #
  # Length is the only signal available without listening to it. Compare against
  # the reading pace the plugin is already asking every engine for
  # (READOUT_SPEED, 1.0 = 300 characters a minute) and regenerate once when the
  # audio comes back far shorter than the text could possibly be read in.
  # The threshold is deliberately loose: engines run 5-30% faster than the pace
  # they are asked for, and the two truncated chunks seen so far came in at 59%
  # and 60% against 79-98% for every healthy one. Erring loose costs one extra
  # generation; erring tight costs the listener the end of a sentence.
  local ratio; ratio="$(get_tuning_dec_for CLOUD_MIN_AUDIO_RATIO "$backend" 0.65)"
  if ! _cloud_audio_looks_complete "$out" "${#text}" "$ratio"; then
    log fallback "${backend}: audio came back short for ${#text} chars, regenerating once"
    rm -f "$out" "${out%.wav}.pcm" "${out%.mp3}-raw.mp3" 2>/dev/null
    _gen_cloud_once "$backend" "$text" "$out" || return 1
  fi

  _append_chunk_marker "$out"
  return 0
}

_gen_cloud_once() {
  case "$1" in
    gemini)     gen_gemini "$2" "$3" ;;
    inworld)    gen_inworld "$2" "$3" ;;
    elevenlabs) gen_elevenlabs "$2" "$3" ;;
    fishaudio)  gen_fishaudio "$2" "$3" ;;
    *)          return 1 ;;
  esac
}

# True unless FILE is far shorter than CHARS characters could be read in. An
# unreadable duration (no ffprobe, odd container) returns true: this guards
# against a truncated generation, not against the probe, and a probe that
# cannot answer must not cost a second API call on every chunk.
_cloud_audio_looks_complete() {
  local file="$1" chars="$2" ratio="$3" dur
  [ "$chars" -gt 0 ] 2>/dev/null || return 0
  dur="$(_audio_duration "$file")"
  [ -n "$dur" ] || return 0
  awk "BEGIN{ speed=$(get_tuning READOUT_SPEED 1.2); if(speed<=0) speed=1.0;
              expected = $chars / (5.0 * speed);
              exit !($dur >= expected * $ratio) }"
}

# The exact text speak_cloud_chunked would generate FIRST for TEXT. Used by the
# hybrid handover (speak_hybrid): a speculative generator produces that chunk in
# advance, and speak_cloud_chunked then accepts the finished file as its chunk 0
# instead of generating it again. Both sides read the same two config keys in
# the same process, so the two splits are identical by construction — if they
# ever diverged the seed would be audio of the wrong text, which is why this
# derives the chunk rather than approximating it.
_cloud_first_chunk() {  # TEXT BACKEND
  local c=""
  IFS= read -r -d '' c \
    < <(split_into_speech_chunks "$1" \
          "$(get_tuning_num_for CLOUD_CHUNK_CHARS "$2" 200)" \
          "$(get_tuning_num_for CLOUD_FIRST_CHUNK_CHARS "$2" 80)" \
          "$(get_tuning_num_for CLOUD_SECOND_CHUNK_CHARS "$2" 120)") || true
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
#
# Publishes _PLAY_LAST_DUR and _PLAY_LAST_AUDIO_AT (the moment the audio began:
# when `play` returned, or STARTED when somebody else issued it) for callers
# measuring their own seams — speak_cloud_chunked's timing summary is built from
# these. Published rather than returned because the return value is the play's
# success, and re-probing the file to get the duration a second time would cost
# another ~0.4s of ffprobe out of the playback.
_play_media_file() {
  local file="$1" cap="$2" lead="${3:-0}" started="${4:-}" dur elapsed=0
  dur="$(_audio_duration "$file")"
  if [ -n "$started" ]; then
    elapsed="$(awk "BEGIN{e=$(date +%s.%N)-$started; if(e<0)e=0; printf \"%.1f\", e}")"
    _PLAY_LAST_AUDIO_AT="$started"
  else
    _audio_play_start "$file"
    _PLAY_LAST_AUDIO_AT="${EPOCHREALTIME:-$(date +%s.%N)}"
    _capture_played_file "$file" chunk
  fi
  _PLAY_LAST_DUR="$dur"
  if [ -n "$dur" ]; then
    sleep "$(awk "BEGIN{d=$dur-$lead-$elapsed; if(d<0)d=0; if(d>$cap)d=$cap; printf \"%.1f\", d}")"
    # ffplay -autoexit needs a brief moment after the audio itself ends to
    # actually flush and release the file handle. The sleep above targets the
    # audio's own duration exactly, so the caller's deferred cleanup rm (right
    # after this function returns) landed inside that gap and raced ffplay's
    # own shutdown on Windows ("Device or resource busy", observed 2026-07-31).
    # termux-media-player has no such handle of its own to release — Android's
    # media service owns the file independently — so this only applies here.
    command -v termux-media-player >/dev/null 2>&1 || sleep 0.3
  else
    local waited=0
    while [ "$waited" -lt "$cap" ]; do
      sleep 1
      waited=$(( waited + 1 ))
      _audio_is_playing || break
    done
    _audio_stop
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
  local backend="$1" text="$2" cap="$3" seed="${4:-}" plan="${5:-}" playing="${6:-}" pregen_uid="${7:-}"
  _audio_player_available || { log error "${backend}: no player available (termux-media-player, or ffplay on Windows)"; return 1; }

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
  local chunk_max first_max second_max play_lead _scratch
  if [ "${#chunks[@]}" -eq 0 ]; then
    if _scratch="$(_cloud_scratch_dir)"; then
      find "$_scratch" -maxdepth 1 -name 'vr-*' -type f -mmin +60 -delete 2>/dev/null
    fi
    chunk_max="$(get_tuning_num_for CLOUD_CHUNK_CHARS "$backend" 200)"
    first_max="$(get_tuning_num_for CLOUD_FIRST_CHUNK_CHARS "$backend" 80)"
    second_max="$(get_tuning_num_for CLOUD_SECOND_CHUNK_CHARS "$backend" 120)"
    while IFS= read -r -d '' c; do [ -n "$c" ] && chunks+=("$c"); done \
      < <(split_into_speech_chunks "$text" "$chunk_max" "$first_max" "$second_max")
  fi
  # Seconds to issue the next chunk's play before the current one ends, so the
  # next chunk's prepare overlaps this tail (see _play_media_file). 0 disables
  # the overlap. Validate numeric.
  play_lead="$(_cloud_play_lead)"
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

  # PREGEN_UID (7th arg): the uid the speculative generator used for the seed —
  # its chunks 1..N were pre-generated alongside it, at "$PREGEN_UID-1" and so
  # on. They are usually still in flight when we get here (chunk 0 finished
  # first, which is what let the handover happen), so each is ADOPTED rather
  # than started again. The adopter stands in for a generator: the loop waits on
  # this PID and reads its exit status exactly as it would a gen_cloud, and if
  # the pre-generation failed or never lands it generates the chunk the ordinary
  # way rather than dropping the readout to on-device.
  local pg=1 pgsrc
  while [ -n "$pregen_uid" ] && [ "$pg" -lt "$n" ]; do
    pgsrc="$(_cloud_audio_path "$backend" "${pregen_uid}-${pg}")" || break
    [ -e "${pgsrc}.pending" ] || break
    [ -z "${gen_done[$pg]:-}" ] || { pg=$(( pg + 1 )); continue; }
    (
      w=0
      while [ ! -s "${pgsrc}.rc" ] && [ "$w" -lt 120 ]; do sleep 0.5; w=$(( w + 1 )); done
      if [ "$(cat "${pgsrc}.rc" 2>/dev/null)" = "0" ] && [ -s "$pgsrc" ] \
         && mv -f "$pgsrc" "$(_cloud_audio_path "$backend" "$pg")" 2>/dev/null; then
        rm -f "${pgsrc}.rc" "${pgsrc}.pending" 2>/dev/null
      else
        rm -f "$pgsrc" "${pgsrc}.rc" "${pgsrc}.pending" 2>/dev/null
        gen_cloud "$backend" "${chunks[$pg]}" "$pg" || exit 1
      fi
      printf '%s' "${EPOCHREALTIME:-$(date +%s.%N)}" > "$(_cloud_audio_path "$backend" "$pg").gen"
    ) &
    gen_pid[$pg]=$!
    pg=$(( pg + 1 ))
  done

  # Seed the buffer: chunk 0 plus PREFETCH chunks ahead, all generating in
  # parallel from the start. Chunk 0's own generation is the only wait the
  # listener sees before the first sound.
  # Each generator stamps its own completion time. The loop cannot measure this:
  # it only looks at a chunk once the previous one has nearly played out, so a
  # generator that finished long before is indistinguishable from one that
  # finished a moment ago — the wait returns instantly either way. That is the
  # same shape as the summarizer mis-measurement of 2026-07-23, and the slack at
  # each seam is precisely what the chunk schedule has to be tuned against.
  local k
  for (( k = 0; k <= prefetch && k < n; k++ )); do
    [ -n "${gen_done[$k]:-}" ] && continue
    [ -n "${gen_pid[$k]:-}" ] && continue
    ( gen_cloud "$backend" "${chunks[$k]}" "$k" \
        && printf '%s' "${EPOCHREALTIME:-$(date +%s.%N)}" > "$(_cloud_audio_path "$backend" "$k").gen" ) &
    gen_pid[$k]=$!
  done

  # Per-chunk timing. Recorded as it happens, but summed and logged only after
  # the last chunk: the seams are the thing being measured, and a log call at a
  # seam would be dead air of exactly the kind under investigation (the lesson
  # from the on-device instrumentation in speak(), where a single log line cost
  # 19s on a throttled device). EPOCHREALTIME is a bash builtin, so taking a
  # timestamp here costs no fork at all.
  local -a t_ready=() t_audio=() t_dur=()
  local t0="${EPOCHREALTIME:-$(date +%s.%N)}"

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

    t_ready[$i]="${EPOCHREALTIME:-$(date +%s.%N)}"

    # Top up the lookahead so the buffer keeps filling while this chunk plays.
    # Generation (network + ffmpeg) and playback (media player) are separate
    # resources, so they don't collide; only one file plays at a time.
    local ahead=$(( i + prefetch ))
    if [ "$ahead" -lt "$n" ] && [ -z "${gen_pid[$ahead]:-}" ]; then
      ( gen_cloud "$backend" "${chunks[$ahead]}" "$ahead" \
          && printf '%s' "${EPOCHREALTIME:-$(date +%s.%N)}" > "$(_cloud_audio_path "$backend" "$ahead").gen" ) &
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
    t_audio[$i]="${_PLAY_LAST_AUDIO_AT:-}"
    t_dur[$i]="${_PLAY_LAST_DUR:-}"
    i=$(( i + 1 ))
  done
  # Cleanup deferred to here: with the lead handoff a chunk can still be feeding
  # the media service just after _play_media_file returns, so removing files mid
  # loop could pull one out from under playback. By now the last chunk (lead 0)
  # has played out and all earlier ones are long done.
  local k f
  local -a t_gen=()
  for (( k = 0; k < n; k++ )); do
    f="$(_cloud_audio_path "$backend" "$k")"
    [ -r "${f}.gen" ] && t_gen[$k]="$(cat "${f}.gen" 2>/dev/null)"
    rm -f "$f" "${f}.gen"
  done

  # gen   = when this chunk's audio finished generating (falls back to when the
  #         loop picked it up, for a seeded chunk with no generator of its own).
  # gap   = this chunk's audio started this long after the previous one ended.
  #         Negative is the CLOUD_PLAY_LEAD overlap working as intended; positive
  #         is dead air the listener hears.
  # slack = how long before its play had to go out the audio was ready. This is
  #         the margin the chunk schedule is tuned against: a seam with a small
  #         slack is one perturbation away from a gap even while it reads +0.0.
  local trec="" k2
  for (( k2 = 0; k2 < n; k2++ )); do
    trec+="${k2} ${#chunks[$k2]} ${t_ready[$k2]:-0} ${t_audio[$k2]:-0} ${t_dur[$k2]:-0} ${t_gen[$k2]:-0}"$'\n'
  done
  log info "${backend} pipeline timing:$(printf '%s' "$trec" | awk -v t0="$t0" -v lead="$play_lead" '
    { k=$1+0; c[k]=$2; r[k]=$3; a[k]=$4; d[k]=$5; g[k]=$6; last=k }
    END {
      for (k = 0; k <= last; k++) {
        if (a[k]+0 <= 0) continue
        s = sprintf(" %d:%dc gen%+.1f aud%.1f", k, c[k], (g[k]+0 > 0 ? g[k]-t0 : r[k]-t0), d[k])
        if (k > 0 && a[k-1]+0 > 0 && d[k-1]+0 > 0) {
          s = s sprintf(" gap%+.1f", a[k]-(a[k-1]+d[k-1]))
          # Slack: how long before its play had to go out the audio was ready.
          if (g[k]+0 > 0) s = s sprintf(" slack%+.1f", (a[k-1]+d[k-1]-lead) - g[k])
        }
        printf "%s;", s
      }
    }')"
  # One sample per seam: the lead that was used plus the gap it left is the
  # cost that should have been hidden. Taken here, after the last chunk, so
  # nothing in the measurement lands between two chunks.
  if _cloud_play_lead_learning; then
    for (( k2 = 1; k2 < n; k2++ )); do
      [ -n "${t_audio[$k2]:-}" ] && [ -n "${t_audio[$(( k2 - 1 ))]:-}" ] && [ -n "${t_dur[$(( k2 - 1 ))]:-}" ] || continue
      awk -v lead="$play_lead" -v a="${t_audio[$k2]}" \
          -v pa="${t_audio[$(( k2 - 1 ))]}" -v pd="${t_dur[$(( k2 - 1 ))]}" \
          'BEGIN{ c = lead + (a - (pa + pd)); if (c > 0 && c < 10) printf "%.2f\n", c }' \
          >> "$PLAY_LEAD_SAMPLE_FILE"
    done
    _cloud_play_lead_finish
  fi

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
_cloud_prep_ahead() {  # TEXT PLAN_FILE BACKEND
  local text="$1" plan="$2" backend="${3:-}" scratch
  if scratch="$(_cloud_scratch_dir)"; then
    find "$scratch" -maxdepth 1 -name 'vr-*' -type f -mmin +60 -delete 2>/dev/null
  fi
  if split_into_speech_chunks "$text" \
       "$(get_tuning_num_for CLOUD_CHUNK_CHARS "$backend" 200)" \
       "$(get_tuning_num_for CLOUD_FIRST_CHUNK_CHARS "$backend" 80)" \
       "$(get_tuning_num_for CLOUD_SECOND_CHUNK_CHARS "$backend" 120)" > "${plan}.tmp" 2>/dev/null; then
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
    _cloud_prep_ahead "$suffix_text" "${out}.plan" "$backend"
    # Everything the on-device opening can pay for gets generated here, not just
    # the seed. What a chunk has to hide its generation behind is the playback of
    # the chunks before it, and the early ones have almost none: chunk 1 had only
    # chunk 0's ~9s (measured slack -2.7s, 2.8s of silence after the voices
    # changed), and chunk 2 only chunk 0 + chunk 1, which on Gemini meant 16.8s
    # of playback against a 20.9s generation — 7.9s of dead air mid-sentence.
    # Both start at the handover otherwise, so a LONGER opening does not help
    # them: it delays their start by exactly as much. Generating them during the
    # opening does, and that time is free — the listener is being read to.
    local pregen; pregen="$(get_tuning_num_for HYBRID_PREGEN_CHUNKS "$backend" 2)"
    first=""
    exec 3< "${out}.plan" 2>/dev/null || true
    IFS= read -r -d '' first <&3 2>/dev/null || true
    local extra="" j=1
    while [ "$j" -le "$pregen" ]; do
      IFS= read -r -d '' extra <&3 2>/dev/null || extra=""
      [ -n "$extra" ] || break
      # Parallel, not sequential: generations in flight do not slow each other
      # (measured 2- and 3-way), and chunk 0 must not be made to wait — the
      # handover is gated on its .rc alone, written the moment it lands.
      #
      # The .pending marker is written BEFORE the generator starts, and is the
      # only reliable way for the reader on the other side to tell "being
      # generated" from "never asked for". A chunk in flight has no audio file
      # yet — gen_cloud removes the name first and the backend writes it last —
      # so keying off the audio would miss exactly the case that matters, the
      # one still generating at the handover, and generate it a second time.
      : > "$(_cloud_audio_path "$backend" "hyb-$b-$j").pending"
      ( gen_cloud "$backend" "$extra" "hyb-$b-$j"
        printf '%s' "$?" > "$(_cloud_audio_path "$backend" "hyb-$b-$j").rc" ) &
      j=$(( j + 1 ))
    done
    exec 3<&- 2>/dev/null || true
    [ -n "$first" ] || first="$(_cloud_first_chunk "$suffix_text" "$backend")"
    gen_cloud "$backend" "$first" "hyb-$b"
    printf '%s' "$?" > "${out}.rc"
    wait
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
  # The chunks generated alongside the candidate. A discarded candidate's
  # chunk 1 is audio of text the listener is about to hear read on-device
  # instead, so leaving it behind would be worse than wasteful. Swept by glob
  # rather than by the current HYBRID_PREGEN_CHUNKS: the config may have changed
  # since the generator was launched, and a leftover here is wrong audio at a
  # name the next readout would trust.
  local out1
  for out1 in "${out%.*}"-[0-9]*; do
    [ -e "$out1" ] || continue
    rm -f "$out1" "${out1}.rc" "${out1}.pending" "${out1%.wav}.pcm" "${out1%.mp3}-raw.mp3" 2>/dev/null
  done
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
# First fitted 2026-07-27 on four warm runs of 19/37/64/91 chars: 4.10s +
# chars/8.15, residuals within +-0.6s. Refitted 2026-07-28 on the eight in-window
# samples the instrumentation collected from ordinary use, which came in much
# slower: 4.0s + chars/5.6. Those four runs were the only thing happening on the
# phone; a real hybrid unit is spoken while the next cloud chunk is being
# generated, and the contention shows. The three samples taken mid-readout (idle
# 3-4s, i.e. with a generator running) ran 2.5-5.6s over the old model, while
# the ones at the head of a readout sat within a second of it.
#
# The defaults below are NOT that mean fit but a line at or above almost every
# sample (4.6 + chars/5.0). Which side to err on is not symmetric: over-estimate
# and _hyb_speak_with_preplay simply falls back to the seam it was hiding;
# under-estimate and the cloud voice talks over the on-device one, which is what
# 17.1s of speech against an 11.5s estimate did on 2026-07-28.
_ondevice_speech_secs() {
  local chars=${#1} start rate dstart=4.6 drate=5.0
  # 4.6s / 5.0 chars-per-sec are termux-tts-speak numbers: the 4.6 is mostly the
  # Termux:API round trip before the first syllable, which SAPI does not pay, and
  # the 5.0 was measured at that engine's pace. Applied to SAPI they overestimate
  # badly — 105 chars measured 14.1s against a 25.6s estimate (2026-08-15) — and
  # for hybrid the estimate is not cosmetic: the pre-play is issued LEAD seconds
  # before the predicted end, so an estimate 11s long means the cloud's `play` is
  # issued 11s late and the listener hears exactly that as the handover seam.
  # SAPI, taken from the LOG of real readouts (2026-08-15) — the interval between
  # "hybrid: opening merged into one unit (N chars)" and the "[spoke]
  # windows-sapi" that closes it, i.e. wall time from asking for the utterance to
  # the audio actually being over:
  #   271c/41s  320c/38s  303c/52s  275c/39s
  #   289c/45s  313c/38s  281c/39s  327c/55s
  # = 5.8-8.4 chars/sec, so 7.0 with a ~1s fixed cost.
  #
  # NOT the duration of the synthesised WAV. Measuring that gave 20.1 chars/sec
  # and it is a real number — it is just not this one: the wall time also carries
  # the host process start and the device open, and at ~300 chars the two differ
  # by a factor of three (16.6s predicted against 55s actual, seen in the log).
  # What the estimate is used for is deciding when the on-device voice will stop
  # so the cloud's play can be issued just before it, so wall time is the only
  # quantity that means anything here. Three earlier passes got this wrong by
  # fitting a rate to something other than wall time.
  if ! command -v termux-tts-speak >/dev/null 2>&1; then dstart=1.0; drate=7.0; fi
  start="$(get_tuning_dec ONDEVICE_START_SECS "$dstart")"
  rate="$(get_tuning_dec ONDEVICE_CHARS_PER_SEC "$drate")"
  awk "BEGIN{r=$rate; if(r<=0)r=$drate; printf \"%.1f\", $start + $chars/r}"
}

# _ondevice_preplay_safe — true when the engine last spoke recently enough that
# _ondevice_speech_secs can be trusted to within the pre-play's margin.
#
# What makes a long gap dangerous is not the TTS engine going cold: the binding
# survives (measured 2026-07-27 — after 6 idle minutes with the device kept
# awake, 8.27s against 8.15s warm, i.e. no penalty at all). It is the PHONE
# going to sleep. Android's doze freezes background work, and a readout that
# lands on a deeply-dozing device runs slow even after the wake lock is taken.
# From the instrumentation in speak(): 17 minutes idle came in +0.8s over the
# model, 91 minutes idle +9.5s. The second one would have started the cloud
# voice nine seconds into the on-device sentence.
#
# Deliberately NOT WARM_SKIP_WINDOW, which this used to borrow. That window
# decides whether to skip the preflight probe, and on an engine that wedges as
# often as this one does, widening it delays noticing a hang. The two questions
# only looked alike; they trade off against different things.
_ondevice_preplay_safe() {
  local window last now
  window="$(get_tuning_num HYBRID_PREPLAY_MAX_IDLE 600)"
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
# That asymmetry is only true if a too-long estimate really does cost nothing,
# and until 2026-07-28 it did not: the wait was a flat sleep, so an estimate that
# overshot held the `play` back past the end of the voice and left a seam LONGER
# than an unassisted handover. The wait now ends on whichever comes first, the
# estimate or the voice, which is what lets _ondevice_speech_secs be tuned to
# the safe side of the samples instead of to their middle.
#
# Sets _HYB_PREPLAY_STARTED to the epoch the audio began at, empty if no
# pre-play happened. Nothing is consumed here: the candidate's audio and its .rc
# marker are left exactly as they were, so the caller's boundary check still
# sees "ok" and the ordinary handover runs on top of this.
_hyb_speak_with_preplay() {
  local backend="$1" b="$2" unit="$3" cap="$4"
  _HYB_PREPLAY_STARTED=""

  # A phone deep in doze runs the unit seconds slower than the model says, which
  # is exactly the error that turns a hidden round trip into two voices at once.
  # Too long a gap means no pre-play and the ordinary seam, which is what we had
  # before this existed.
  if ! _ondevice_preplay_safe; then
    # Backgrounded: this sits immediately before the opening, and the whole
    # point of the opening is that it starts at once.
    ( log info "hybrid: no pre-play, engine idle past HYBRID_PREPLAY_MAX_IDLE" ) &
    VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 \
      speak "$unit" "$cap" ""
    return 0
  fi

  local est lead wait_for
  est="$(_ondevice_speech_secs "$unit")"
  # Deliberately shorter than the ~1.9s round trip it hides. Two error sources
  # eat the difference: the model's own residual, and the fact that it was
  # fitted against termux-tts-speak alone while the wait starts one moment
  # earlier, at speak()'s entry — its lock file, tuning lookups and chunking are
  # a few tenths on top. Raise it toward 1.9 to chase the last of the gap, at
  # the price of occasionally clipping the on-device voice's last syllable.
  lead="$(get_tuning_dec HYBRID_PREPLAY_LEAD 1.0)"
  wait_for="$(awk "BEGIN{d=$est-$lead; if(d<0.5)d=0.5; printf \"%.1f\", d}")"

  # The estimate covers speech, so it has to be counted from the first syllable,
  # not from the call: speak() spends seconds on the preflight probe, the wake
  # lock and the split before anything is audible, and counting those as speech
  # fired the pre-play that much early — 7s of two voices at once on 2026-07-28.
  local mark="${PLUGIN_DATA_DIR}/voice-readout-speak-mark"
  rm -f "$mark" 2>/dev/null

  VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 \
    VOICE_READOUT_SPEAK_MARK_FILE="$mark" speak "$unit" "$cap" "" &
  local spid=$!

  # Nothing is at stake in this loop's granularity — it runs before the voice
  # starts, not at a seam — and it ends either way, on the mark or on a speak()
  # that gave up before reaching it.
  while [ ! -s "$mark" ]; do
    kill -0 "$spid" 2>/dev/null || break
    sleep 0.2
  done

  # Whichever finishes first — the estimate, or the voice it was estimating.
  # A timer process rather than a poll loop: polling would have to ask the clock
  # or count its own sleeps, and on a throttled phone the per-iteration overhead
  # accumulates into exactly the kind of late fire this is here to avoid.
  sleep "$wait_for" &
  local tpid=$!
  wait -n "$spid" "$tpid" 2>/dev/null
  kill "$tpid" 2>/dev/null
  local under=yes
  kill -0 "$spid" 2>/dev/null || under=no

  # The stop switch is re-read here, not just at the loop's boundary check: this
  # is the last instant before sound comes out, and a 停止 pressed during the
  # unit must not be answered by the cloud voice starting up.
  if [ ! -e "$STOP_SWITCH_FILE" ] && [ "$(_hyb_spec_state "$backend" "$b")" = ok ]; then
    local seed; seed="$(_cloud_audio_path "$backend" "hyb-$b")"
    if [ -s "$seed" ]; then
      _audio_play_start "$seed"
      _HYB_PREPLAY_STARTED="$(date +%s.%N)"
      # Captured here rather than in _play_media_file: that function's
      # pre-played branch never issues a `play`, so this is the only site that
      # sees chunk 0 of a hybrid handover go out.
      _capture_played_file "$seed" hyb-chunk0
      if [ "$under" = yes ]; then
        log info "hybrid: pre-played cloud chunk 0 under the ondevice voice (unit est ${est}s, lead ${lead}s)"
      else
        # The estimate overshot. Nothing is hidden, but the play goes out at the
        # moment the voice stopped, one step earlier than the handover would
        # have managed on its own — and the log says so, which is the signal
        # that _ondevice_speech_secs is running long for this device.
        log info "hybrid: ondevice voice ended before its ${est}s estimate, played cloud chunk 0 at once"
      fi
    fi
  elif [ ! -e "$STOP_SWITCH_FILE" ]; then
    # Nothing to pre-play: the cloud audio does not exist yet. Said out loud
    # because it is indistinguishable by ear from the pre-play misfiring, and
    # both leave the listener the same silence at the handover. It means the
    # opening was shorter than the backend's first generation — gemini's, at
    # 6-10s, outruns a 26-char opening every time.
    ( log info "hybrid: no pre-play, cloud chunk 0 not generated yet when the unit ended" ) &
  fi

  wait "$spid" 2>/dev/null

  # The one seam nothing measured. speak_cloud_chunked's gap column starts at
  # chunk 1 — chunk 0 has no predecessor there — so the moment the voices change,
  # which is the moment a listener actually notices, was the only join in the
  # readout with no number against it. Negative means the cloud audio was already
  # sounding when the on-device voice stopped, which is the whole intent.
  #
  # Read it as optimistic. The reference point is speak() returning, and that is
  # at or AFTER the last syllable — the call still has its bookkeeping to do — so
  # a seam reported as slightly negative can still be a short silence in the
  # room. It is a lower bound on the gap, which is enough to tell a seam that is
  # working from one that is seconds wide.
  if [ -n "$_HYB_PREPLAY_STARTED" ]; then
    local ended="${EPOCHREALTIME:-$(date +%s.%N)}"
    ( log info "hybrid: handover seam $(awk "BEGIN{printf \"%+.1f\", $_HYB_PREPLAY_STARTED - $ended}")s" ) &
  fi
  return 0
}

speak_hybrid() {
  local backend="$1" text="$2" cap="$3"
  # What this needs is AN on-device voice and A player, not Android's two in
  # particular. Gating on termux-tts-speak/termux-media-player by name meant
  # hybrid silently never ran off Android (found 2026-08-15 on Windows: the
  # config said on, the statusline said on, and speak_hybrid returned 1 before
  # doing anything) — on the platform that needs it most, since it is where the
  # slowest first-sound wait was measured (gemini, 13-15s).
  #
  # Both halves already have cross-platform implementations in this file, so the
  # gate is the only thing that was Android-only: the opening is spoken by
  # recursing into speak() with the ondevice backend, which picks SAPI when
  # termux-tts-speak is absent, and the seed chunk goes through
  # _audio_play_start / _audio_stop, which wrap ffplay the same way.
  _ondevice_voice_available || return 1
  _audio_player_available || return 1

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

  # With a minimum opening set, the units inside it become ONE unit. No handover
  # can happen in that stretch — the first candidate is aimed past it — so
  # splitting it buys nothing, and every extra call costs a measured 2.7s of
  # engine spin-up before its first syllable: silence in the middle of the
  # opening, which a listener hears as the readout cutting out. (Measured
  # 2026-07-28 on this device: 58 and 54 characters as two calls, 10.9s; the same
  # 112 characters as one call, 8.2s.) Capped at the on-device ceiling, or the
  # merged unit would be declined by speak() and silently skipped; and it always
  # leaves a unit for the cloud. speak() still applies its own TTS_CHUNK_CHARS
  # split inside the merged unit, so that knob caps how much of this is gained.
  # Per backend before global: how long an opening is needed is a property of
  # the engine, not of the user's taste. Elevenlabs has a chunk ready in the time
  # one unit takes to read and wants no minimum at all; gemini's 6-10s first
  # generation outruns a short opening every time. One global value would have to
  # be wrong for one of them.
  local min_od
  min_od="$(get_tuning_num_for HYBRID_MIN_ONDEVICE_CHARS "$backend" 0)"
  if [ "$min_od" -gt 0 ]; then
    local acc=0 m=0 merged=""
    while [ "$m" -lt "$(( n - 1 ))" ] && [ "$acc" -lt "$min_od" ]; do
      [ "$m" -eq 0 ] || [ "$(( acc + ${#units[$m]} ))" -le "$omax" ] || break
      merged="${merged}${units[$m]}"
      acc=$(( acc + ${#units[$m]} ))
      m=$(( m + 1 ))
    done
    if [ "$m" -gt 1 ]; then
      units=("$merged" "${units[@]:$m}")
      n=${#units[@]}
      log info "hybrid: opening merged into one unit (${acc} chars) for HYBRID_MIN_ONDEVICE_CHARS=${min_od}"
    fi
  fi

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

  # Which boundary to aim the first cloud candidate at. Boundary 1 — hand over
  # after a single unit — assumes the cloud can produce a chunk in the time one
  # unit takes to read. On elevenlabs it can; on gemini a 26-character opening
  # (8.3s) against a 6-10s first generation is a coin toss, and losing it costs
  # twice: the candidate generated for boundary 1 is thrown away, and with no
  # audio in hand at the end of the unit there is nothing to pre-play, so the
  # ~2s play round trip lands in the open as silence at the very moment the
  # voices change.
  #
  # HYBRID_MIN_ONDEVICE_CHARS handles this by making the opening one longer
  # unit (see the merge above), so the first boundary is past it by
  # construction and this stays at 1. Deliberately a length rather than "gemini
  # hands over at unit 2": what has to be covered is the backend's first
  # generation, which is a duration, and units are whatever length the sentences
  # happen to be. Default 0 keeps the old behaviour; the cost of raising it is
  # more of the readout in the on-device voice.
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
      [ -n "$_HYB_PREPLAY_STARTED" ] && _audio_stop
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
          if speak_cloud_chunked "$backend" "${suffix[$b]}" "$cap" "$seed" "${seed}.plan" \
               "$_HYB_PREPLAY_STARTED" "hyb-$b"; then
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
    gemini|inworld|elevenlabs|fishaudio)
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

        # Instrumentation for the handover pre-play (see _ondevice_speech_secs):
        # what the duration model predicted, what it actually took, and how long
        # the engine had been idle beforehand. Measuring this from outside the
        # plugin turned out to be impossible — a script that waits for the phone
        # to go idle is itself frozen by Android's doze (measured 2026-07-27: a
        # 6-minute sleep took 50 minutes of wall time), and every readout of the
        # conversation warming the engine invalidated the wait. Recording it from
        # in here instead costs two `date` calls and makes ordinary use the
        # experiment. Cheap enough to leave on permanently.
        local _t_start _t_idle
        _t_start="$(date +%s.%N)"
        _t_idle="$(awk -v n="$(date +%s)" -v l="$(cat "$ONDEVICE_LASTSPOKE_FILE" 2>/dev/null)" \
                     'BEGIN{ if (l == "") print "?"; else print n - l }')"

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
        # 150, not the 100 this was set to while chasing the 2026-07-20 engine
        # hangs. The ceiling exists because a call running ~80s breaks
        # Termux:API's result-return channel; 100 characters is 10-20s of speech,
        # so it was far below what the hazard required, and every extra call
        # costs a measured 2.7s of engine spin-up BEFORE its first syllable —
        # silence in the middle of a sentence, which is what a listener reports
        # as the readout cutting out. A 150-character call was timed on this
        # device at 9.7s, still nowhere near the 80s that breaks anything.
        local chunk_max="$(get_tuning_num TTS_CHUNK_CHARS 150)"
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

        # Everything above this line happens before a sound comes out: the
        # preflight probe, the wake lock (a ~1.9s Termux:API round trip of its
        # own), the tuning reads, the split. The handover pre-play used to time
        # itself from speak()'s entry and so counted all of it as speech —
        # measured 2026-07-28, the cloud voice started SEVEN seconds into the
        # on-device sentence and the two talked over each other the whole way.
        # A caller that needs to know when the voice really starts passes a path
        # here and reads the stamp; nobody else pays anything.
        [ -n "${VOICE_READOUT_SPEAK_MARK_FILE:-}" ] && \
          printf '%s' "${EPOCHREALTIME:-$(date +%s.%N)}" > "$VOICE_READOUT_SPEAK_MARK_FILE" 2>/dev/null

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
          # In a subshell, backgrounded, because this exact point is the handover
          # seam: on the hybrid path the cloud voice is waiting on the next few
          # lines, and the date/awk/config reads this line needs are not free —
          # measured at 19s on a throttled (dozing) device, where they would have
          # been 19s of silence between the two voices.
          ( log info "ondevice timing: ${#text} chars, took $(awk "BEGIN{printf \"%.1f\", $(date +%s.%N)-$_t_start}")s, model said $(_ondevice_speech_secs "$text")s, idle before ${_t_idle}s" ) &
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
