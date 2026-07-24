#!/bin/bash
# statusLine command: show the current readout state at the bottom of the
# Claude Code console, so "will the next response be spoken or not" is visible
# at a glance. Reads the exact same config file and stop-switch path the hooks
# use, so it can never disagree with what actually gets spoken.
#
# Wire it up in settings.json (NOT a plugin hook, so ${CLAUDE_PLUGIN_ROOT} is
# not expanded here — use an absolute path):
#   "statusLine": { "type": "command", "command": "<abs path to this file>" }
#
# Claude Code pipes session JSON on stdin; we don't need it, so we ignore it.
# The command runs on every render, so keep it to cheap file reads only.

set -u

# Read the SAME config the hooks read. Hooks run with CLAUDE_PLUGIN_DATA set by
# Claude Code, but a statusLine command does NOT get that variable — so falling
# back to /tmp (as the hooks' own default does) reads a different, stale file
# and the line lies about the state. Prefer CLAUDE_PLUGIN_DATA when present,
# otherwise point straight at the plugin's real data dir, never /tmp.
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  CONFIG_FILE="$CLAUDE_PLUGIN_DATA/voice-readout-config"
else
  CONFIG_FILE="${HOME}/.claude/plugins/data/voice-readout-voice-readout/voice-readout-config"
fi
# Fixed absolute path, matching readout-switch.sh / tts-lib.sh. The stop switch
# deliberately does NOT honour CLAUDE_PLUGIN_DATA, so neither does this reader.
STOP_SWITCH_FILE="/data/data/com.termux/files/home/.voice-readout-stopped"

# Read one KEY=value from the config. Prints nothing if unset or file missing.
# Enable semantics match is_enabled(): only the literal "off" disables; an
# absent key (or no file at all) counts as on.
cfg() {
  [ -f "$CONFIG_FILE" ] || return
  grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2
}

# The stop switch is the top-level cutoff: when it's pressed nothing is spoken,
# no matter what resp/notif say. Show that instead of the per-toggle state so an
# enabled toggle can't be mistaken for "it should be talking but isn't".
if [ -e "$STOP_SWITCH_FILE" ]; then
  printf '🛑 ALL MUTED'
  exit 0
fi

# ON -> speaker with sound, OFF -> muted speaker. Only "off" is off.
icon() { [ "$1" = "off" ] && printf '🔇' || printf '🔊'; }

# Each readout function can use a different backend, so show each one's backend
# next to its own icon — the backend NAME (gemini/inworld/elevenlabs/ondevice),
# not the full model string. Notifications use TTS_BACKEND_NOTIFICATION; the
# response uses TTS_BACKEND_FULL or _SUMMARY depending on the mode. Both fall
# back to the global TTS_BACKEND, then to ondevice (the shipped default).
notif_backend="$(cfg TTS_BACKEND_NOTIFICATION)"
[ -n "$notif_backend" ] || notif_backend="$(cfg TTS_BACKEND)"
[ -n "$notif_backend" ] || notif_backend="ondevice"

# Full mode reads verbatim; summary mode runs the response through the
# summarizer first. Mark that difference on the line: full shows just the
# backend (resp <icon> <backend>), summary inserts a short "sum" tag before the
# backend (resp <icon> sum <backend>) so which mode is live is visible too.
if [ "$(cfg READOUT_MODE)" = "full" ]; then
  resp_backend="$(cfg TTS_BACKEND_FULL)"
  resp_mode=""
else
  resp_backend="$(cfg TTS_BACKEND_SUMMARY)"
  resp_mode="sum "
fi
[ -n "$resp_backend" ] || resp_backend="$(cfg TTS_BACKEND)"
[ -n "$resp_backend" ] || resp_backend="ondevice"

printf 'notif %s %s  resp %s %s%s' \
  "$(icon "$(cfg NOTIFICATION_READOUT)")" "$notif_backend" \
  "$(icon "$(cfg STOP_READOUT)")" "$resp_mode" "$resp_backend"
