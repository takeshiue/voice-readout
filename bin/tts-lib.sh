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

# Persisted settings live here (written by bin/toggle.sh, seeded by
# `toggle.sh init`). Defined up front because the tuning values below read from
# it. A missing file or missing key falls through to a built-in default, so a
# fresh install works with zero setup.
CONFIG_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-config"

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

LOG_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout.log"
# This file is appended to indefinitely across sessions with nothing else
# trimming it, so self-rotate once it grows past a threshold instead of
# growing forever.
LOG_MAX_BYTES="$(get_tuning LOG_MAX_BYTES 1048576)"
log() {
  local size=0
  # Guarded on existence rather than relying on `2>/dev/null`: that silences
  # wc's stderr, but a failed `<` redirection is reported by the shell itself
  # and would still print on the very first call of a fresh install.
  if [ -f "$LOG_FILE" ]; then
    size="$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
  fi
  case "$size" in *[!0-9]*|"") size=0 ;; esac
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
  fi
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null
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

# "summary" (default, one sentence via Haiku) or "full" (verbatim, no LLM).
get_readout_mode() {
  [ -f "$CONFIG_FILE" ] || { echo summary; return; }
  local val
  val="$(grep -E '^READOUT_MODE=' "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
  case "$val" in full) echo full ;; *) echo summary ;; esac
}

# Tone lives outside the scripts: an empty/missing persona file means plain,
# short, neutral phrasing. A non-empty file's contents are appended to the
# Haiku prompt as extra style instructions, and its presence also switches
# notify-speak.sh's static phrases to a matching preset (only "sweet" exists
# today; extend PERSONA_FILE contents + notify-speak.sh together for more).
PERSONA_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-persona.md"
persona_active() {
  [ -s "$PERSONA_FILE" ]
}
get_persona_style() {
  persona_active && cat "$PERSONA_FILE" || true
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
ENV_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout.env"
get_env_value() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Legacy per-key file from before keys were consolidated into voice-readout.env
# (kept so installs that already ran `toggle.sh gemini-key` don't lose it).
GEMINI_KEY_FILE_LEGACY="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-gemini-key"
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
  local stamp_file="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-last-notify"
  local cooldown="$(get_tuning NOTIFY_COOLDOWN 1800)"
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
  local stamp_file="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-last-notify"
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
ONDEVICE_LOCK_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-ondevice.lock"

# Epoch seconds of the last fully-successful on-device readout. Used to skip the
# ~2s preflight probe when the engine was confirmed working very recently (it is
# still warm, so re-probing it only adds latency to every follow-up readout in
# an active conversation). Written on success below; read at the preflight gate.
ONDEVICE_LASTSPOKE_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-ondevice-lastspoke"

# Longest text the on-device engine reliably finishes — see the ceiling check
# in speak() for how this number was arrived at. Exposed as a function so
# callers that would rather shorten their text than be refused (the Stop
# hook's summary path) can ask instead of hardcoding it.
ondevice_max_chars() {
  printf '%s' "$(get_tuning ONDEVICE_MAX_CHARS 240)"
}

# Spoken as a short preface when an over-length readout is degraded to a summary
# (see the on-device ceiling in speak()). Lets a listener who asked for the full
# text or a file know they are hearing a summary instead of the whole thing.
# Deliberately a fixed Japanese system message (no persona, no per-language
# variants): Japanese is the most compact — the same wording in English runs
# nearly twice the character count against the on-device ceiling — and the
# summary that follows is always Japanese too, so the two stay consistent.
READOUT_OVERFLOW_NOTICE="${VOICE_READOUT_OVERFLOW_NOTICE:-長文のため要約にします。}"

# Bridge phrase spoken between the verbatim opening and the summary in the
# experimental overflow pipeline (summarize-and-speak.sh, toggle OVERFLOW_PIPELINE).
OVERFLOW_PIPELINE_BRIDGE="${VOICE_READOUT_OVERFLOW_PIPELINE_BRIDGE:-残りは要約します。}"

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
  mkdir -p "$scratch_dir" 2>/dev/null || return 1
  local dest="$scratch_dir/$(basename "$clip")"
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
  if timeout "$(get_tuning PREFLIGHT_TIMEOUT 10)" termux-tts-engines >/dev/null 2>&1 </dev/null; then
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
  local chunk="" p
  for p in "${pieces[@]}"; do
    if [ -n "$chunk" ] && [ $(( ${#chunk} + ${#p} )) -gt "$max" ]; then
      printf '%s\0' "$chunk"
      chunk="$p"
    else
      chunk="${chunk}${p}"
    fi
  done
  [ -n "$chunk" ] && printf '%s\0' "$chunk"
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

  local model="${VOICE_READOUT_GEMINI_MODEL:-gemini-2.5-flash-preview-tts}"
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
  response="$(curl -sS --max-time 45 \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${api_key}" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null)"

  audio_b64="$(printf '%s' "$response" | jq -r '.candidates[0].content.parts[0].inlineData.data // empty' 2>/dev/null)"
  if [ -z "$audio_b64" ]; then
    log error "gemini TTS request failed: $(printf '%s' "$response" | tr -d '\n' | cut -c1-200)"
    return 1
  fi

  # termux-media-player is how Termux:API actually reaches the phone speaker
  # (it hands the file to Android's own MediaPlayer). ffplay/aplay running
  # directly in this shell has no audio device (no /dev/snd here — this is a
  # proot container), so it silently hangs instead of making sound. The file
  # must also live somewhere Android's Termux:API app can open by path: this
  # proot's own /tmp isn't bind-mounted into the real Termux filesystem, only
  # $TERMUX_HOME (and /storage/emulated/0) are — see `mount` output.
  local termux_home="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}"
  local scratch_dir="$termux_home/.voice-readout-tmp"
  mkdir -p "$scratch_dir" 2>/dev/null
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

  local model="${VOICE_READOUT_INWORLD_MODEL:-inworld-tts-1.5-mini}"
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
  response="$(curl -sS --max-time 45 \
    "https://api.inworld.ai/tts/v1/voice" \
    -H "Authorization: Basic ${api_key}" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null)"

  audio_b64="$(printf '%s' "$response" | jq -r '.audioContent // empty' 2>/dev/null)"
  if [ -z "$audio_b64" ]; then
    log error "inworld TTS request failed: $(printf '%s' "$response" | tr -d '\n' | cut -c1-200)"
    return 1
  fi

  # Same proot/Termux:API path constraint as the Gemini backend — see the
  # comment there for why the file must live under $TERMUX_HOME.
  local termux_home="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}"
  local scratch_dir="$termux_home/.voice-readout-tmp"
  mkdir -p "$scratch_dir" 2>/dev/null
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
  model="$(get_tuning ELEVENLABS_MODEL "${VOICE_READOUT_ELEVENLABS_MODEL:-eleven_flash_v2_5}")"
  # "アマテラステラス2" (middle-aged, ja-kanto accent) — a custom voice already
  # in the account's ElevenLabs voice library, picked 2026-07-20 for a mature,
  # Japanese-native-sounding tone.
  local voice="${VOICE_READOUT_ELEVENLABS_VOICE:-blVzlvngVR9lhf4Gflnk}"
  local payload http_code

  payload="$(jq -n --arg text "$text" --arg model "$model" '{text: $text, model_id: $model}')"

  local termux_home="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}"
  local scratch_dir="$termux_home/.voice-readout-tmp"
  mkdir -p "$scratch_dir" 2>/dev/null
  if [ ! -d "$scratch_dir" ]; then
    log error "elevenlabs backend: cannot create $scratch_dir (wrong TERMUX_HOME?)"
    return 1
  fi
  local mp3_file="$scratch_dir/audio-$$.mp3"

  http_code="$(curl -sS --max-time 45 -w '%{http_code}' \
    -X POST "https://api.elevenlabs.io/v1/text-to-speech/${voice}" \
    -H "xi-api-key: ${api_key}" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    -o "$mp3_file" 2>/dev/null)"

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
  gain="$(get_tuning ELEVENLABS_GAIN 1.0)"
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
  rate="$(get_tuning TTS_RATE 1.3)"
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

speak() {
  # Checked first, before the config, before the enable toggles, before the
  # backend is even resolved. Anything that reads configuration can be
  # redirected at it; this cannot. If the user has pressed 停止, nothing in
  # this plugin speaks, whatever else it was told to do.
  if [ -e "$STOP_SWITCH_FILE" ]; then
    log skip "読み上げ停止中 (stop switch is on)"
    return 0
  fi

  local text="$1"
  local cap="${2:-90}"
  # Which of the four functions is speaking: notification | summary | full |
  # file. Selects that function's configured backend (see get_tts_backend).
  # Empty is allowed and just means "use the global setting".
  local fn="${3:-}"
  case "$(get_tts_backend "$fn")" in
    gemini)
      if speak_gemini "$text" "$cap"; then
        clear_failure_notifications
      else
        log fallback "gemini backend failed, retrying via ondevice"
        VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 speak "$text" "$cap" "$fn"
      fi
      ;;
    inworld)
      if speak_inworld "$text" "$cap"; then
        clear_failure_notifications
      else
        log fallback "inworld backend failed, retrying via ondevice"
        VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 speak "$text" "$cap" "$fn"
      fi
      ;;
    elevenlabs)
      if speak_elevenlabs "$text" "$cap"; then
        clear_failure_notifications
      else
        log fallback "elevenlabs backend failed, retrying via ondevice"
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
        warm_window="$(get_tuning WARM_SKIP_WINDOW 120)"
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

        local tts_args=(-r "$(get_tuning TTS_RATE 1.3)" -p "$(get_tuning TTS_PITCH 1.0)")
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
        command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null

        # One long call per readout used to trip the ResultReturner issue
        # above regardless of wake-locking, so speak it as several short
        # calls instead — each chunk gets its own timeout scaled the same way
        # the whole text used to.
        local chunk_max="$(get_tuning TTS_CHUNK_CHARS 100)"
        local chunk_retries="$(get_tuning TTS_CHUNK_RETRIES 4)"
        # Linear backoff between attempts: base, 2x base, 3x base, capped.
        local retry_wait_base="$(get_tuning TTS_RETRY_WAIT_BASE 20)"
        local retry_wait_max="$(get_tuning TTS_RETRY_WAIT 90)"
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
            command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null
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
                command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null
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
          clear_failure_notifications
        else
          log error "termux-tts-speak timed out or failed (exit $rc, stopped at chunk ${chunk_count}/${total_chunks})"
          precleanup_stuck_tts
          notify_failure
          start_recovery_watcher
        fi
        command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null
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
