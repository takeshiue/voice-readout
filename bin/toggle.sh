#!/bin/bash
# Flips a voice-readout setting. Meant to be run by Claude when the user asks
# in chat ("音声読み上げをオフにして" / "フル読み上げにして" etc).
#
# Usage: toggle.sh <stop|notification|all|greeting> <on|off>
#        toggle.sh mode <summary|full>
#        toggle.sh persona <on|off>
#        toggle.sh backend <ondevice|gemini|inworld|elevenlabs>
#        toggle.sh backend-<notification|summary|full|file> <ondevice|gemini|inworld|elevenlabs>
#        toggle.sh tune <KEY> <VALUE>
#        toggle.sh init
#        toggle.sh gemini-key <API_KEY|clear>
#        toggle.sh inworld-key <API_KEY|clear>
#        toggle.sh elevenlabs-key <API_KEY|clear>
#   stop         Stop-hook readout (summarizes/reads the final response)
#   notification Notification-hook readout (permission/idle prompts)
#   all          stop + notification together (not greeting — that is separate)
#   greeting     SessionStart greeting, spoken once at launch/resume so you can
#                hear whether the readout path works. Text: tune STARTUP_GREETING_TEXT
#   mode         summary = one-sentence Haiku summary (default)
#                full    = verbatim readout of the response (minus code/URLs)
#   persona      on  = apply the tone preset in personas/persona.md
#                off = plain, short, neutral phrasing (default)
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
#   tune         set a numeric/scalar tuning value in the config file (the
#                knobs that used to be environment-variable-only). Valid keys:
#                ONDEVICE_MAX_CHARS TTS_CHUNK_CHARS TTS_CHUNK_RETRIES
#                TTS_RETRY_WAIT_BASE TTS_RETRY_WAIT PREFLIGHT_TIMEOUT
#                WATCH_INTERVAL LOG_MAX_BYTES TTS_RATE TTS_PITCH NOTIFY_COOLDOWN
#                STARTUP_GREETING_TEXT (the session-start greeting text)
#   gemini-key      sets/clears the Gemini API key used by the gemini backend
#   inworld-key     sets/clears the Inworld API key used by the inworld backend
#   elevenlabs-key  sets/clears the ElevenLabs API key used by the elevenlabs backend
set -eu

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-config"
PERSONA_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-persona.md"
PERSONA_PRESET="$PLUGIN_DIR/personas/persona.md"
ENV_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout.env"

usage() {
  echo "Usage: $0 <stop|notification|all|greeting> <on|off>" >&2
  echo "       $0 mode <summary|full>" >&2
  echo "       $0 persona <on|off>" >&2
  echo "       $0 backend <ondevice|gemini|inworld|elevenlabs>" >&2
  echo "       $0 backend-<notification|summary|full|file> <ondevice|gemini|inworld|elevenlabs>" >&2
  echo "       $0 tune <KEY> <VALUE>" >&2
  echo "       $0 gemini-key <API_KEY|clear>" >&2
  echo "       $0 inworld-key <API_KEY|clear>" >&2
  echo "       $0 elevenlabs-key <API_KEY|clear>" >&2
  exit 1
}

# `init` is the one subcommand that takes no second argument.
if [ "${1:-}" = "init" ]; then
  TARGET=init
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

set_key() {
  local key="$1" value="$2"
  touch "$CONFIG_FILE"
  if grep -q -E "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i -E "s/^${key}=.*/${key}=${value}/" "$CONFIG_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}

# API keys go in ENV_FILE, not CONFIG_FILE: base64 key values contain "/" and
# "=" characters that would break set_key()'s sed substitution, so this
# rewrites the file (filter out the old line, append the new one) instead.
set_env_key() {
  local key="$1" value="$2"
  touch "$ENV_FILE"
  grep -v -E "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

clear_env_key() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -v -E "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
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
    add_default STARTUP_GREETING_TEXT voice-readout、準備できたよ
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
    add_default TTS_CHUNK_CHARS 100
    add_default TTS_CHUNK_RETRIES 4
    add_default TTS_RETRY_WAIT_BASE 20
    add_default TTS_RETRY_WAIT 90
    add_default PREFLIGHT_TIMEOUT 10
    add_default WATCH_INTERVAL 120
    add_default LOG_MAX_BYTES 1048576
    add_default TTS_RATE 1.3
    add_default TTS_PITCH 1.0
    add_default NOTIFY_COOLDOWN 1800
    echo "voice-readout: config initialised at $CONFIG_FILE"
    cat "$CONFIG_FILE"
    exit 0
    ;;
  stop|notification|all|greeting)
    case "$STATE" in on|off) ;; *) usage ;; esac
    case "$TARGET" in
      stop) set_key STOP_READOUT "$STATE" ;;
      notification) set_key NOTIFICATION_READOUT "$STATE" ;;
      # Independent of "all": the startup greeting is a separate cue, so
      # turning off the two readouts does not silence it (and vice versa).
      greeting) set_key STARTUP_GREETING "$STATE" ;;
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
  persona)
    case "$STATE" in on|off) ;; *) usage ;; esac
    if [ "$STATE" = on ]; then
      [ -f "$PERSONA_PRESET" ] || { echo "persona preset not found: $PERSONA_PRESET" >&2; exit 1; }
      cp "$PERSONA_PRESET" "$PERSONA_FILE"
    else
      rm -f "$PERSONA_FILE"
    fi
    echo "voice-readout: persona -> ${STATE}"
    exit 0
    ;;
  backend|backend-notification|backend-summary|backend-full|backend-file)
    case "$STATE" in ondevice|gemini|inworld|elevenlabs) ;; *) usage ;; esac
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
  tune)
    case "$TUNE_KEY" in
      # STARTUP_GREETING_TEXT is the one free-text key here; the rest are
      # numeric. set_key's sed substitution can't carry a '/' in the value, so
      # keep the greeting text slash-free (edit the config file directly for
      # anything unusual).
      ONDEVICE_MAX_CHARS|TTS_CHUNK_CHARS|TTS_CHUNK_RETRIES|TTS_RETRY_WAIT_BASE|TTS_RETRY_WAIT|PREFLIGHT_TIMEOUT|WATCH_INTERVAL|LOG_MAX_BYTES|TTS_RATE|TTS_PITCH|NOTIFY_COOLDOWN|STARTUP_GREETING_TEXT) ;;
      *)
        echo "unknown tuning key: $TUNE_KEY" >&2
        echo "valid keys: ONDEVICE_MAX_CHARS TTS_CHUNK_CHARS TTS_CHUNK_RETRIES TTS_RETRY_WAIT_BASE TTS_RETRY_WAIT PREFLIGHT_TIMEOUT WATCH_INTERVAL LOG_MAX_BYTES TTS_RATE TTS_PITCH NOTIFY_COOLDOWN STARTUP_GREETING_TEXT" >&2
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
