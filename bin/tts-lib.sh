# Shared TTS helpers for voice-readout hooks. Sourced, not executed.
# Callers must be registered with "async": true and must always exit 0.

LOG_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout.log"
log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null
}

# On/off toggles, controlled via bin/toggle.sh (invoked by asking Claude in
# chat, e.g. "音声読み上げをオフにして"). Missing file or missing key means
# enabled — the feature must work with zero setup on a fresh install.
CONFIG_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/voice-readout-config"
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
get_tts_backend() {
  if [ -n "${VOICE_READOUT_TTS_BACKEND:-}" ]; then
    echo "$VOICE_READOUT_TTS_BACKEND"
    return
  fi
  [ -f "$CONFIG_FILE" ] || { echo ondevice; return; }
  local val
  val="$(grep -E '^TTS_BACKEND=' "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
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
  local cooldown="${VOICE_READOUT_NOTIFY_COOLDOWN:-1800}"
  local now last
  now="$(date +%s)"
  last="$(cat "$stamp_file" 2>/dev/null || echo 0)"
  case "$last" in *[!0-9]*|"") last=0 ;; esac
  if [ $(( now - last )) -lt "$cooldown" ]; then
    log skip "failure notification suppressed (cooldown ${cooldown}s)"
    return 0
  fi
  printf '%s' "$now" > "$stamp_file" 2>/dev/null

  # Two separate notifications, one per app: tapping a button closes the
  # notification shade, so a single 2-button notification loses its second
  # step the moment the first is used. Step ① is Termux:API: the wedge lives
  # in its held TTS binding, and restarting it also re-binds to the Google
  # engine — force-stopping only Google fixed nothing (2026-07-20).
  # Posting order is ② then ①: Android shows the newest notification on top,
  # so the step to do first must be sent last.
  termux-notification \
    --id voice-readout-fix-google \
    --title "⚠️ 読み上げ停止 ②直らなければ Google音声も" \
    --content "①で直らないときだけ。タップして「強制停止」を押してください" \
    --priority high \
    --action "$GOOGLE_TTS_INTENT" \
    --button1 "設定画面を開く" \
    --button1-action "$GOOGLE_TTS_INTENT" \
    2>/dev/null
  # Posted back-to-back the two can land in the same instant and keep an
  # arbitrary order — a beat in between makes ① reliably the newest (= top).
  sleep 1
  termux-notification \
    --id voice-readout-fix-termux \
    --title "⚠️ 読み上げ停止 ①まず Termux:API を強制停止" \
    --content "タップして開いた画面で「強制停止」を押してください（これだけで直ることが多いです）" \
    --priority high \
    --action "$TERMUX_API_INTENT" \
    --button1 "設定画面を開く" \
    --button1-action "$TERMUX_API_INTENT" \
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
    termux-notification-remove voice-readout-fix-google 2>/dev/null
    termux-notification-remove voice-readout-fix-termux 2>/dev/null
    log info "cleared recovery notifications after successful readout"
  fi
}

# A stuck TextToSpeech call from a previous invocation never exits, so any
# process still alive here is already broken (a single one-sentence summary
# finishes in a few seconds). Clear it before adding a new one to the pile.
precleanup_stuck_tts() {
  local pids
  pids="$(ps aux 2>/dev/null | awk '$0 ~ /libexec\/termux-api TextToSpeech/ && $0 !~ /awk|grep/ {print $2}')"
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null
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

  local model="${VOICE_READOUT_ELEVENLABS_MODEL:-eleven_flash_v2_5}"
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

  termux-media-player play "$mp3_file" >/dev/null 2>&1

  local waited=0
  while [ "$waited" -lt "$cap" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    if ! termux-media-player info 2>/dev/null | grep -q 'Status: Playing'; then
      break
    fi
  done
  termux-media-player stop >/dev/null 2>&1
  rm -f "$mp3_file"

  if [ "$waited" -ge "$cap" ]; then
    log error "elevenlabs TTS playback exceeded cap (${cap}s)"
    return 1
  fi
  log spoke "elevenlabs-tts (model ${model}, voice ${voice}, ${waited}s)"
  return 0
}

speak() {
  local text="$1"
  local cap="${2:-90}"
  case "$(get_tts_backend)" in
    gemini)
      if speak_gemini "$text" "$cap"; then
        clear_failure_notifications
      else
        log fallback "gemini backend failed, retrying via ondevice"
        VOICE_READOUT_TTS_BACKEND=ondevice speak "$text" "$cap"
      fi
      ;;
    inworld)
      if speak_inworld "$text" "$cap"; then
        clear_failure_notifications
      else
        log fallback "inworld backend failed, retrying via ondevice"
        VOICE_READOUT_TTS_BACKEND=ondevice speak "$text" "$cap"
      fi
      ;;
    elevenlabs)
      if speak_elevenlabs "$text" "$cap"; then
        clear_failure_notifications
      else
        log fallback "elevenlabs backend failed, retrying via ondevice"
        VOICE_READOUT_TTS_BACKEND=ondevice speak "$text" "$cap"
      fi
      ;;
    ondevice)
      if command -v termux-tts-speak >/dev/null 2>&1; then
        precleanup_stuck_tts
        local tts_args=(-r "${VOICE_READOUT_TTS_RATE:-1.3}" -p "${VOICE_READOUT_TTS_PITCH:-1.0}")
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
        if timeout "$timeout_secs" termux-tts-speak "${tts_args[@]}" "$text"; then
          log spoke "termux-tts-speak (${tts_args[*]}, timeout ${timeout_secs}s)"
          clear_failure_notifications
        else
          local rc=$?
          if [ "$rc" -eq 137 ]; then
            # SIGKILL means a newer readout's precleanup replaced this one —
            # by design during quick exchanges, not an engine failure.
            log skip "readout superseded by a newer one"
          else
            log error "termux-tts-speak timed out or failed (exit $rc, timeout ${timeout_secs}s)"
            precleanup_stuck_tts
            notify_failure
            start_recovery_watcher
          fi
        fi
      else
        log error "termux-tts-speak not found"
      fi
      ;;
    *)
      # Future TTS backends (e.g. cloud APIs) plug in here.
      log error "unknown TTS backend: ${VOICE_READOUT_TTS_BACKEND:-}"
      ;;
  esac
}
