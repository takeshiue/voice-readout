#!/bin/bash
# Flips a voice-readout setting. Meant to be run by Claude when the user asks
# in chat ("音声読み上げをオフにして" / "フル読み上げにして" etc).
#
# Usage: toggle.sh <stop|notification|all> <on|off>
#        toggle.sh mode <summary|full>
#        toggle.sh persona <on|off>
#        toggle.sh backend <ondevice|gemini|inworld|elevenlabs>
#        toggle.sh gemini-key <API_KEY|clear>
#        toggle.sh inworld-key <API_KEY|clear>
#        toggle.sh elevenlabs-key <API_KEY|clear>
#   stop         Stop-hook readout (summarizes/reads the final response)
#   notification Notification-hook readout (permission/idle prompts)
#   all          stop + notification together
#   mode         summary = one-sentence Haiku summary (default)
#                full    = verbatim readout of the response (minus code/URLs)
#   persona      on  = apply the tone preset in personas/persona.md
#                off = plain, short, neutral phrasing (default)
#   backend      ondevice   = on-device Android TTS via Termux:API (default, offline)
#                gemini     = Gemini API TTS (needs network + gemini-key set)
#                inworld    = Inworld Realtime TTS-1.5 Mini (needs network + inworld-key set)
#                elevenlabs = ElevenLabs eleven_flash_v2_5 (needs network + elevenlabs-key set)
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
  echo "Usage: $0 <stop|notification|all> <on|off>" >&2
  echo "       $0 mode <summary|full>" >&2
  echo "       $0 persona <on|off>" >&2
  echo "       $0 backend <ondevice|gemini|inworld|elevenlabs>" >&2
  echo "       $0 gemini-key <API_KEY|clear>" >&2
  echo "       $0 inworld-key <API_KEY|clear>" >&2
  echo "       $0 elevenlabs-key <API_KEY|clear>" >&2
  exit 1
}

[ $# -eq 2 ] || usage
TARGET="$1"
STATE="$2"

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
  stop|notification|all)
    case "$STATE" in on|off) ;; *) usage ;; esac
    case "$TARGET" in
      stop) set_key STOP_READOUT "$STATE" ;;
      notification) set_key NOTIFICATION_READOUT "$STATE" ;;
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
  backend)
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
    set_key TTS_BACKEND "$STATE"
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
  *) usage ;;
esac

echo "voice-readout: ${TARGET} -> ${STATE}"
cat "$CONFIG_FILE"
