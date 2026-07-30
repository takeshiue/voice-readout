#!/bin/bash
# Flips a voice-readout setting. Meant to be run by Claude when the user asks
# in chat ("音声読み上げをオフにして" / "フル読み上げにして" etc).
#
# Usage: toggle.sh <stop|notification|all|greeting|farewell|overflow-pipeline|hybrid|chunk-marker> <on|off>
#        toggle.sh mode <summary|full>
#        toggle.sh speed <0.5-2.0>
#        toggle.sh backend <ondevice|gemini|inworld|elevenlabs|fishaudio>
#        toggle.sh backend-<notification|summary|full|file> <ondevice|gemini|inworld|elevenlabs|fishaudio>
#        toggle.sh tune <KEY> <VALUE>
#        toggle.sh init
#        toggle.sh recalibrate
#        toggle.sh gemini-key <API_KEY|clear>
#        toggle.sh inworld-key <API_KEY|clear>
#        toggle.sh elevenlabs-key <API_KEY|clear>
#        toggle.sh fishaudio-key <API_KEY|clear>
#        toggle.sh env-template
#   stop         Stop-hook readout (summarizes/reads the final response)
#   notification Notification-hook readout (permission/idle prompts)
#   all          stop + notification together (not greeting — that is separate)
#   greeting     SessionStart greeting, spoken once at launch/resume so you can
#                hear whether the readout path works. Text: tune STARTUP_GREETING_TEXT
#   farewell     SessionEnd farewell, a fixed clip (assets/session-end.wav)
#                played once when the session ends (also separate from "all")
#   overflow-pipeline  read the opening verbatim while the summary is generated
#   hybrid       "full hybrid": in full mode with a cloud voice, speak the
#                opening on the on-device engine while the cloud audio is still
#                generating, then hand over mid-readout. Removes the cloud's
#                first-sound wait at the cost of the voice changing once, at a
#                sentence boundary. No effect in summary mode or on an ondevice
#                backend. Tune HYBRID_UNIT_CHARS / HYBRID_MAX_ONDEVICE_CHARS /
#                HYBRID_SPECULATION. Default off.
#   chunk-marker Diagnostic aid: play a short cue (assets/chunk-marker.wav) at
#                every cloud chunk boundary, so where the text was split and how
#                seamless the handoff sounds are both audible. Default off.
#   speed        reading pace for EVERY engine: 1.0 is about 300 characters a
#                minute (announcer pace), 1.2 the shipped default. Each engine's
#                own knob is derived from it (they differ in native speed), so
#                one number changes them all. Set a knob to a number to override.
#   mode         summary = one-sentence Haiku summary (default)
#                full    = verbatim readout of the response (minus code/URLs)
#   backend      the default for every function
#   backend-*    that one function's engine, overriding the default:
#                notification = permission/idle prompts
#                summary      = one-sentence summary of a response
#                full         = verbatim readout of a response
#                file         = external text file readout
#                Each is the user's choice; all four default to ondevice
#                because it needs no key, no network, and starts instantly.
#                ondevice   = on-device Android TTS via Termux:API (default, offline)
#                gemini     = Gemini API TTS (needs network + gemini-key set)
#                inworld    = Inworld Realtime TTS-1.5 Mini (needs network + inworld-key set)
#                elevenlabs = ElevenLabs eleven_flash_v2_5 (needs network + elevenlabs-key set)
#                fishaudio  = Fish Audio s2.1-pro-free (needs network + fishaudio-key set)
#   tune         set a numeric/scalar tuning value in the config file (the
#                knobs that used to be environment-variable-only). Valid keys:
#                ONDEVICE_MAX_CHARS TTS_CHUNK_CHARS TTS_CHUNK_RETRIES
#                TTS_RETRY_WAIT_BASE TTS_RETRY_WAIT PREFLIGHT_TIMEOUT
#                WARM_SKIP_WINDOW (skip preflight if last readout succeeded
#                within N sec; 0 disables)
#                HYBRID_UNIT_CHARS
#                HYBRID_MAX_ONDEVICE_CHARS HYBRID_MIN_ONDEVICE_CHARS[_GEMINI|_INWORLD|_ELEVENLABS] HYBRID_SPECULATION
#                HYBRID_PREGEN_CHUNKS (how many cloud chunks AFTER the first
#                are generated during the on-device opening; they have almost
#                no playback ahead of them to hide behind otherwise)
#                HYBRID_PREPLAY_LEAD (start the cloud voice this many sec
#                before the on-device unit is due to end, hiding the ~1.9s
#                play round trip; 0 disables) HYBRID_PREPLAY_MAX_IDLE
#                (skip the pre-play when the engine last spoke more than N sec
#                ago — past that the phone has dozed and runs slower than the
#                duration model predicts) ONDEVICE_START_SECS
#                ONDEVICE_CHARS_PER_SEC (the on-device duration model that
#                lead is measured against)
#                WATCH_INTERVAL LOG_MAX_BYTES
#                TTS_RATE TTS_PITCH NOTIFY_COOLDOWN
#                STARTUP_GREETING_TEXT (the session-start greeting text)
#   gemini-key      sets/clears the Gemini API key used by the gemini backend
#   inworld-key     sets/clears the Inworld API key used by the inworld backend
#   elevenlabs-key  sets/clears the ElevenLabs API key used by the elevenlabs backend
#   fishaudio-key   sets/clears the Fish Audio API key used by the fishaudio backend
set -eu

# Same resolution as tts-lib.sh's PLUGIN_DATA_DIR — kept in step with it by
# hand rather than sourced, because this script is standalone and runs under
# `set -eu`. See the long comment there for why the old /tmp fallback had to
# go: THIS script is the one that wrote API keys into it, since it is normally
# run from a terminal, where Claude Code sets no CLAUDE_PLUGIN_DATA.
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  PLUGIN_DATA_DIR="$CLAUDE_PLUGIN_DATA"
elif [ -n "${HOME:-}" ]; then
  PLUGIN_DATA_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/voice-readout-voice-readout"
else
  PLUGIN_DATA_DIR="${TMPDIR:-/tmp}/voice-readout-$(id -u 2>/dev/null || echo 0)"
fi
[ -d "$PLUGIN_DATA_DIR" ] || {
  mkdir -p "$PLUGIN_DATA_DIR" 2>/dev/null && chmod 700 "$PLUGIN_DATA_DIR" 2>/dev/null
}

CONFIG_FILE="${PLUGIN_DATA_DIR}/voice-readout-config"
ENV_FILE="${PLUGIN_DATA_DIR}/voice-readout.env"

usage() {
  echo "Usage: $0 <stop|notification|all|greeting|farewell|overflow-pipeline|hybrid|chunk-marker> <on|off>" >&2
  echo "       $0 mode <summary|full>" >&2
  echo "       $0 speed <0.5-2.0>" >&2
  echo "       $0 backend <ondevice|gemini|inworld|elevenlabs|fishaudio>" >&2
  echo "       $0 backend-<notification|summary|full|file> <ondevice|gemini|inworld|elevenlabs|fishaudio>" >&2
  echo "       $0 tune <KEY> <VALUE>" >&2
  echo "       $0 gemini-key <API_KEY|clear>" >&2
  echo "       $0 inworld-key <API_KEY|clear>" >&2
  echo "       $0 elevenlabs-key <API_KEY|clear>" >&2
  echo "       $0 fishaudio-key <API_KEY|clear>" >&2
  echo "       $0 env-template" >&2
  exit 1
}

# `init` is the one subcommand that takes no second argument.
if [ "${1:-}" = "init" ]; then
  TARGET=init
  STATE=""
elif [ "${1:-}" = "recalibrate" ]; then
  TARGET=recalibrate
  STATE=""
elif [ "${1:-}" = "env-template" ]; then
  TARGET=env-template
  STATE=""
elif [ "${1:-}" = "tune" ]; then
  # tune takes two arguments (KEY VALUE), unlike every other subcommand.
  [ $# -eq 3 ] || usage
  TARGET=tune
  TUNE_KEY="$2"
  TUNE_VAL="$3"
  STATE=""
else
  [ $# -eq 2 ] || usage
  TARGET="$1"
  STATE="$2"
fi

# Rewrite the file (drop the old line, append the new one) rather than editing
# it in place with sed. The sed form this replaces —
#   sed -i -E "s/^${key}=.*/${key}=${value}/"
# — interpolated the value straight into the sed EXPRESSION, so a value
# containing "/" could close the s/// command and append sed commands of its
# own. GNU sed's `e` runs the result as a shell command, which made
#   toggle.sh tune STARTUP_GREETING_TEXT 'おはよう/;e id > /tmp/pwned #'
# arbitrary command execution as whoever runs the plugin (verified 2026-07-25).
# That value is not some internal knob either: the documented way to change the
# greeting is to ask in chat, so free-form user text reaches this line by
# design. Passing the value as data to printf can't have that class of bug.
# The value is single-line by construction: a newline would split one setting
# into two lines, the second of which the readers below would parse as its own
# KEY=VALUE.
set_key() {
  local key="$1" value="$2"
  case "$value" in
    *$'\n'*) echo "value must not contain a newline" >&2; exit 1 ;;
  esac
  touch "$CONFIG_FILE"
  { grep -v -E "^${key}=" "$CONFIG_FILE" 2>/dev/null || true; printf '%s=%s\n' "$key" "$value"; } \
    > "${CONFIG_FILE}.tmp"
  mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

# API keys go in ENV_FILE, not CONFIG_FILE: they are secrets, and this is the
# file the two writers below keep at 0600. (The original reason was narrower — a
# base64 key's "/" and "=" broke set_key()'s sed substitution — but that
# substitution is gone now, and keeping secrets in their own locked-down file is
# the better reason anyway.)
# umask first, chmod after: the file (and the .tmp it is rewritten through)
# must never EXIST at the default 0644, not merely end up at 0600. The previous
# form chmod'ed only at the end, so every key was world-readable for the moment
# between being written and being locked down — and clear_env_key below had no
# chmod at all, so clearing one key moved a fresh 0644 .tmp over the file and
# left every REMAINING key world-readable for good (verified 2026-07-25).
set_env_key() {
  local key="$1" value="$2"
  local old_umask; old_umask="$(umask)"
  umask 077
  touch "$ENV_FILE"
  { grep -v -E "^${key}=" "$ENV_FILE" 2>/dev/null || true; printf '%s=%s\n' "$key" "$value"; } \
    > "${ENV_FILE}.tmp"
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  umask "$old_umask"
}

clear_env_key() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  local old_umask; old_umask="$(umask)"
  umask 077
  grep -v -E "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  umask "$old_umask"
}

has_env_key() {
  local key="$1"
  [ -f "$ENV_FILE" ] && grep -q -E "^${key}=" "$ENV_FILE" 2>/dev/null
}

case "$TARGET" in
  init)
    # Writes every setting at its default, so the config file itself shows
    # what can be changed. Users don't read source to find out what knobs
    # exist. Only fills in keys that are missing — an existing choice is
    # never overwritten, so this is safe to re-run after an upgrade adds
    # new settings.
    touch "$CONFIG_FILE"
    add_default() {
      grep -q -E "^$1=" "$CONFIG_FILE" 2>/dev/null || printf '%s=%s\n' "$1" "$2" >> "$CONFIG_FILE"
    }
    add_default STOP_READOUT on
    add_default NOTIFICATION_READOUT on
    add_default READOUT_MODE summary
    # Spoken once at session start (SessionStart hook) so the user can hear
    # immediately whether the readout path works. Text is configurable.
    add_default STARTUP_GREETING on
    add_default STARTUP_GREETING_TEXT ボイスリードアウト、準備できたよ
    # Played once at session end (SessionEnd hook): a fixed farewell clip
    # (assets/session-end.wav), not live TTS. On by default.
    add_default SESSION_END_GREETING on
    # Text shown in the transcript at session end (the audio stays the fixed
    # clip). Displayed only; not spoken.
    add_default SESSION_END_GREETING_TEXT ボイスリードアウト、またね
    # One engine per function, each the user's own choice. All default to
    # ondevice: no API key, no network, speaks immediately.
    add_default TTS_BACKEND ondevice
    add_default TTS_BACKEND_NOTIFICATION ondevice
    add_default TTS_BACKEND_SUMMARY ondevice
    add_default TTS_BACKEND_FULL ondevice
    add_default TTS_BACKEND_FILE ondevice
    # Tuning knobs — every value that used to be environment-variable-only, kept
    # here so the whole configuration is visible and editable in one place.
    # Change with `toggle.sh tune <KEY> <VALUE>` or by editing this file; a
    # VOICE_READOUT_<KEY> env var still overrides for a one-off run.
    add_default ONDEVICE_MAX_CHARS 240
    add_default TTS_CHUNK_CHARS 150
    add_default TTS_CHUNK_RETRIES 4
    add_default TTS_RETRY_WAIT_BASE 20
    add_default TTS_RETRY_WAIT 90
    add_default PREFLIGHT_TIMEOUT 10
    add_default WARM_SKIP_WINDOW 120
    add_default OVERFLOW_PIPELINE off
    add_default OVERFLOW_OPENING_CHARS 150
    # "full hybrid": in full mode with a cloud voice, cover the cloud's
    # first-sound wait with the on-device engine and hand over mid-readout.
    # UNIT_CHARS is the handover granularity (also the most on-device voice the
    # listener can hear past the moment the cloud was ready); MAX_ONDEVICE_CHARS
    # is where hybrid stops reading on and waits for the cloud instead;
    # SPECULATION is how many handover candidates are generated at once (2 = one
    # wasted API call per readout, faster recovery when the cloud lags).
    add_default HYBRID_TTS off
    add_default HYBRID_UNIT_CHARS 60
    add_default HYBRID_MAX_ONDEVICE_CHARS 240
    add_default HYBRID_SPECULATION 1
    add_default CLOUD_PLAY_LEAD auto
    add_default WATCH_INTERVAL 120
    add_default LOG_MAX_BYTES 1048576
    # One reading-pace index for every engine (1.0 = about 300 chars/min, an
    # announcer's pace). The per-engine knobs below stay "auto": each is derived
    # from this index, scaled by that engine's own native pace, so a single
    # number gives the same speed on all four. Put a number in one of them to
    # override just that engine. See resolve_speed() in tts-lib.sh.
    add_default READOUT_SPEED 1.2
    add_default TTS_RATE auto
    add_default GEMINI_SPEED auto
    add_default INWORLD_SPEAKING_RATE auto
    add_default ELEVENLABS_ATEMPO auto
    add_default TTS_PITCH 1.0
    add_default NOTIFY_COOLDOWN 1800
    # Diagnostic: plays a short cue at every cloud chunk boundary, making the
    # chunking and the prefetch handoff audible. Listed here (rather than left
    # as a code-only switch) so the config file shows it exists — but default
    # off, because during normal listening the cue is just interruption.
    add_default CHUNK_MARKER off
    echo "voice-readout: config initialised at $CONFIG_FILE"
    cat "$CONFIG_FILE"
    exit 0
    ;;
  stop|notification|all|greeting|farewell|overflow-pipeline|hybrid|chunk-marker)
    case "$STATE" in on|off) ;; *) usage ;; esac
    case "$TARGET" in
      stop) set_key STOP_READOUT "$STATE" ;;
      notification) set_key NOTIFICATION_READOUT "$STATE" ;;
      # Independent of "all": the startup greeting and the farewell are separate
      # cues, so turning off the two readouts does not silence them (or v.v.).
      greeting) set_key STARTUP_GREETING "$STATE" ;;
      farewell) set_key SESSION_END_GREETING "$STATE" ;;
      # Experimental: read the opening verbatim while summarizing in the
      # background, so a long readout starts immediately. Default off.
      overflow-pipeline) set_key OVERFLOW_PIPELINE "$STATE" ;;
      # full hybrid: on-device opening, cloud voice for the rest. Only bites in
      # full mode with a cloud backend; harmless (ignored) otherwise.
      hybrid) set_key HYBRID_TTS "$STATE" ;;
      # Diagnostic: append the cue clip to the end of each cloud chunk so the
      # chunk boundaries are audible. Default off; turn on when checking how the
      # text got split or whether the chunk handoff still sounds seamless.
      chunk-marker) set_key CHUNK_MARKER "$STATE" ;;
      all)
        set_key STOP_READOUT "$STATE"
        set_key NOTIFICATION_READOUT "$STATE"
        ;;
    esac
    ;;
  mode)
    case "$STATE" in summary|full) ;; *) usage ;; esac
    set_key READOUT_MODE "$STATE"
    ;;
  speed)
    # One reading-pace index for every engine: 1.0 is about 300 characters a
    # minute (an announcer's pace), and each engine's own knob is derived from
    # it, since the four do not talk at the same speed unadjusted. See
    # resolve_speed() in tts-lib.sh. Range-checked so a typo cannot make the
    # readout unlistenable — 0.5 is half pace, 2.0 is twice.
    case "$STATE" in
      ''|*[!0-9.]*) echo "speed must be a number, e.g. 1.2" >&2; exit 1 ;;
    esac
    if [ "$(awk -v s="$STATE" 'BEGIN{print (s>=0.5 && s<=2.0) ? "ok" : "bad"}')" = bad ]; then
      echo "speed out of range (0.5-2.0): $STATE" >&2; exit 1
    fi
    set_key READOUT_SPEED "$STATE"
    ;;
  backend|backend-notification|backend-summary|backend-full|backend-file)
    case "$STATE" in ondevice|gemini|inworld|elevenlabs|fishaudio) ;; *) usage ;; esac
    if [ "$STATE" = gemini ] && ! has_env_key GEMINI_API_KEY; then
      echo "warning: gemini backend selected but no API key set yet." >&2
      echo "         run: $0 gemini-key <API_KEY>" >&2
    fi
    if [ "$STATE" = inworld ] && ! has_env_key INWORLD_API_KEY; then
      echo "warning: inworld backend selected but no API key set yet." >&2
      echo "         run: $0 inworld-key <API_KEY>" >&2
    fi
    if [ "$STATE" = elevenlabs ] && ! has_env_key ELEVENLABS_API_KEY; then
      echo "warning: elevenlabs backend selected but no API key set yet." >&2
      echo "         run: $0 elevenlabs-key <API_KEY>" >&2
    fi
    if [ "$STATE" = fishaudio ]; then
      if ! has_env_key FISHAUDIO_API_KEY; then
        echo "warning: fishaudio backend selected but no API key set yet." >&2
        echo "         run: $0 fishaudio-key <API_KEY>" >&2
      fi
      # Said once, here, because the default model is the free one and its
      # terms are not what someone picking a voice would assume.
      echo "note: the default model (s2.1-pro-free) is free, but Fish Audio may" >&2
      echo "      use requests to improve their models — and what this plugin" >&2
      echo "      sends is the text of Claude's replies, i.e. your own work." >&2
      echo "      Free access is stated to run to 2026-08-31. For neither, set" >&2
      echo "      a paid model: $0 tune FISHAUDIO_MODEL s2.1-pro" >&2
    fi
    # "backend" sets the shared default; the per-function forms set only their
    # own function, so a user can give, say, notifications a different voice
    # from a file readout without disturbing the rest.
    case "$TARGET" in
      backend)              set_key TTS_BACKEND "$STATE" ;;
      backend-notification) set_key TTS_BACKEND_NOTIFICATION "$STATE" ;;
      backend-summary)      set_key TTS_BACKEND_SUMMARY "$STATE" ;;
      backend-full)         set_key TTS_BACKEND_FULL "$STATE" ;;
      backend-file)         set_key TTS_BACKEND_FILE "$STATE" ;;
    esac
    ;;
  gemini-key)
    if [ "$STATE" = clear ]; then
      clear_env_key GEMINI_API_KEY
      echo "voice-readout: gemini-key -> cleared"
    else
      set_env_key GEMINI_API_KEY "$STATE"
      echo "voice-readout: gemini-key -> saved (${#STATE} chars) in $ENV_FILE"
    fi
    exit 0
    ;;
  inworld-key)
    if [ "$STATE" = clear ]; then
      clear_env_key INWORLD_API_KEY
      echo "voice-readout: inworld-key -> cleared"
    else
      set_env_key INWORLD_API_KEY "$STATE"
      echo "voice-readout: inworld-key -> saved (${#STATE} chars) in $ENV_FILE"
    fi
    exit 0
    ;;
  elevenlabs-key)
    if [ "$STATE" = clear ]; then
      clear_env_key ELEVENLABS_API_KEY
      echo "voice-readout: elevenlabs-key -> cleared"
    else
      set_env_key ELEVENLABS_API_KEY "$STATE"
      echo "voice-readout: elevenlabs-key -> saved (${#STATE} chars) in $ENV_FILE"
    fi
    exit 0
    ;;
  fishaudio-key)
    if [ "$STATE" = clear ]; then
      clear_env_key FISHAUDIO_API_KEY
      echo "voice-readout: fishaudio-key -> cleared"
    else
      set_env_key FISHAUDIO_API_KEY "$STATE"
      echo "voice-readout: fishaudio-key -> saved (${#STATE} chars) in $ENV_FILE"
    fi
    exit 0
    ;;
  env-template)
    # The *-key subcommands above are the only way this plugin asks for a
    # secret to go through a shell command instead of a chat message — but a
    # shell command is itself a barrier for anyone not comfortable with a
    # terminal. Handing over a file to open and paste into is the more
    # familiar shape (copy the value, paste after "=", save), so offer that as
    # an equally supported path rather than the only one.
    #
    # Only ever CREATES the file; never touches one that already exists, so
    # re-running this after keys are already saved cannot lose them or reset
    # their permissions.
    if [ -f "$ENV_FILE" ]; then
      echo "voice-readout: $ENV_FILE はすでにあります（上書きしません）"
    else
      old_umask="$(umask)"
      umask 077
      cat > "$ENV_FILE" <<'ENV_TEMPLATE_EOF'
# voice-readout: 使うクラウドTTSのAPIキーを、下の対応する行の "=" の後ろに
# 貼り付けて保存してください。使わないサービスの行は空のままで構いません。
# 保存したら Claude Code を再起動するか、"バックエンドを gemini にして" のように
# チャットで頼めば反映されます（このファイル自体はチャットからは読み書きしません）。
GEMINI_API_KEY=
INWORLD_API_KEY=
ELEVENLABS_API_KEY=
FISHAUDIO_API_KEY=
ENV_TEMPLATE_EOF
      chmod 600 "$ENV_FILE"
      umask "$old_umask"
      echo "voice-readout: 雛形を作成しました -> $ENV_FILE"
    fi
    echo "  各行の \"=\" の後ろにキーを貼り付けて保存してください。"
    exit 0
    ;;
  recalibrate)
    # Throw away what was learned about this phone's play round trip and start
    # the learning period again — for a new device, or when the seams stop
    # sounding right. Only meaningful while CLOUD_PLAY_LEAD is auto; a number
    # there is the user's own decision and nothing is learned at all.
    rm -f "${PLUGIN_DATA_DIR}/voice-readout-play-lead" \
          "${PLUGIN_DATA_DIR}/voice-readout-play-lead-samples" 2>/dev/null
    echo "voice-readout: play lead calibration cleared; it will be measured again over the next few readouts"
    exit 0
    ;;
  tune)
    # A per-engine override is the base key with _GEMINI / _INWORLD /
    # _ELEVENLABS on the end (see get_tuning_num_for in tts-lib.sh). Only the
    # values that describe an ENGINE take one — how fast it generates, how long
    # its chunks should be — while the framework around them stays shared.
    # Validate the base key so a new per-engine knob needs no entry of its own.
    case "$TUNE_KEY" in
      *_GEMINI|*_INWORLD|*_ELEVENLABS|*_FISHAUDIO) TUNE_BASE="${TUNE_KEY%_*}" ;;
      *)                               TUNE_BASE="$TUNE_KEY" ;;
    esac
    case "$TUNE_BASE" in
      # STARTUP_GREETING_TEXT is the one free-text key here; the rest are
      # numeric. set_key's sed substitution can't carry a '/' in the value, so
      # keep the greeting text slash-free (edit the config file directly for
      # anything unusual).
      ONDEVICE_MAX_CHARS|TTS_CHUNK_CHARS|TTS_CHUNK_RETRIES|TTS_RETRY_WAIT_BASE|TTS_RETRY_WAIT|PREFLIGHT_TIMEOUT|WARM_SKIP_WINDOW|OVERFLOW_OPENING_CHARS|HYBRID_UNIT_CHARS|HYBRID_MAX_ONDEVICE_CHARS|HYBRID_MIN_ONDEVICE_CHARS|HYBRID_SPECULATION|HYBRID_PREGEN_CHUNKS|HYBRID_PREPLAY_LEAD|HYBRID_PREPLAY_MAX_IDLE|ONDEVICE_START_SECS|ONDEVICE_CHARS_PER_SEC|WATCH_INTERVAL|LOG_MAX_BYTES|TTS_RATE|TTS_PITCH|NOTIFY_COOLDOWN|ELEVENLABS_GAIN|ELEVENLABS_ATEMPO|ELEVENLABS_MODEL|ELEVENLABS_SPEED|GEMINI_MODEL|GEMINI_SPEED|INWORLD_MODEL|INWORLD_SPEAKING_RATE|FISHAUDIO_MODEL|FISHAUDIO_SPEED|FISHAUDIO_GAIN|FISHAUDIO_VOICE|CLOUD_HTTP_TIMEOUT|CLOUD_MIN_AUDIO_RATIO|CLOUD_CHUNK_CHARS|CLOUD_FIRST_CHUNK_CHARS|CLOUD_SECOND_CHUNK_CHARS|CLOUD_PLAY_LEAD|CLOUD_PLAY_LEAD_SAMPLES|STARTUP_GREETING_TEXT|SESSION_END_GREETING_TEXT) ;;
      *)
        echo "unknown tuning key: $TUNE_KEY" >&2
        echo "valid keys: ONDEVICE_MAX_CHARS TTS_CHUNK_CHARS TTS_CHUNK_RETRIES TTS_RETRY_WAIT_BASE TTS_RETRY_WAIT PREFLIGHT_TIMEOUT WARM_SKIP_WINDOW OVERFLOW_OPENING_CHARS HYBRID_UNIT_CHARS HYBRID_MAX_ONDEVICE_CHARS HYBRID_MIN_ONDEVICE_CHARS[_GEMINI|_INWORLD|_ELEVENLABS] HYBRID_SPECULATION HYBRID_PREGEN_CHUNKS HYBRID_PREPLAY_LEAD HYBRID_PREPLAY_MAX_IDLE ONDEVICE_START_SECS ONDEVICE_CHARS_PER_SEC WATCH_INTERVAL LOG_MAX_BYTES TTS_RATE TTS_PITCH NOTIFY_COOLDOWN ELEVENLABS_GAIN ELEVENLABS_ATEMPO ELEVENLABS_MODEL ELEVENLABS_SPEED GEMINI_MODEL GEMINI_SPEED INWORLD_MODEL INWORLD_SPEAKING_RATE FISHAUDIO_MODEL FISHAUDIO_SPEED FISHAUDIO_GAIN FISHAUDIO_VOICE CLOUD_HTTP_TIMEOUT CLOUD_MIN_AUDIO_RATIO CLOUD_CHUNK_CHARS CLOUD_FIRST_CHUNK_CHARS CLOUD_SECOND_CHUNK_CHARS CLOUD_PLAY_LEAD CLOUD_PLAY_LEAD_SAMPLES STARTUP_GREETING_TEXT SESSION_END_GREETING_TEXT" >&2
        exit 1
        ;;
    esac
    set_key "$TUNE_KEY" "$TUNE_VAL"
    echo "voice-readout: ${TUNE_KEY} -> ${TUNE_VAL}"
    cat "$CONFIG_FILE"
    exit 0
    ;;
  *) usage ;;
esac

echo "voice-readout: ${TARGET} -> ${STATE}"
cat "$CONFIG_FILE"
