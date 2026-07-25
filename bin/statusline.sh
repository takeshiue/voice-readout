#!/bin/bash
# statusLine command: show the current readout state at the bottom of the
# Claude Code console, so "will the next response be spoken or not" is visible
# at a glance. Reads the exact same config file and stop-switch path the hooks
# use, so it can never disagree with what actually gets spoken. Looks like:
#   greet 🔊🔇|notif 🔊 gemini|resp 🔊 sum inworld|×1.2
#   greet 🔊🔊|notif 🔊 local|resp 🔊 full gemini|×1.3|🔔
# (×N = reading pace, 🔔 = chunk marker on)
#
# On a terminal too narrow for all of it, the segments wrap onto further rows
# rather than being cut off:
#   greet 🔊🔊|notif 🔊 inworld
#   resp 🔊 full inworld|×1.3|🔔
#
# Wire it up in settings.json (NOT a plugin hook, so ${CLAUDE_PLUGIN_ROOT} is
# not expanded here — use an absolute path):
#   "statusLine": { "type": "command", "command": "<abs path to this file>" }
#
# Claude Code pipes session JSON on stdin; we don't need it, so we ignore it.
# The command runs on every render, so keep it to cheap file reads only.

set -u

# ${#s} must count characters, not bytes, for the width arithmetic below.
export LC_ALL=C.utf8

# How wide the row actually is. Claude Code captures this script's output rather
# than attaching it to the terminal, so tput and every language-level width
# probe report the fallback 80 — it exports COLUMNS instead (v2.1.153+). Older
# versions export nothing, and no information means no wrapping: one long line,
# exactly what this script did before.
# Two columns are held back for the interface's own spacing around the row.
COLS=0
case "${COLUMNS:-}" in
  ''|*[!0-9]*) ;;
  *) COLS=$(( COLUMNS - 2 )) ;;
esac

# Display width in terminal columns. Every emoji this script prints is a single
# code point that occupies two columns, so the character count plus one per
# emoji is exact — no need for a wcwidth table or an external process, and this
# runs on every render.
# The declaration is split deliberately: written as `local s="$1" w=${#s}`, the
# ${#s} is expanded before s is local, so it measures the CALLER's s — emit()'s
# loop variable — and every width came out short enough that nothing ever
# wrapped.
dwidth() {
  local s="$1"
  local w=${#s} t e
  for e in 🔊 🔇 🔔 🛑; do
    t="${s//$e/}"
    w=$(( w + ${#s} - ${#t} ))
  done
  printf '%s' "$w"
}

# Collect segments, then emit them packed into rows that fit COLS. Wrapping to a
# second row rather than trimming content: the terminal is a phone, its width
# varies with the handset, the font size and the orientation, so any fixed
# budget is wrong for somebody. Truncation also fails silently in the worst way
# — the ellipsis lands mid-value, so the number you wanted is the part you lose.
SEGMENTS=()
seg() { SEGMENTS+=("$1"); }
emit() {
  local line="" cand s
  for s in "${SEGMENTS[@]}"; do
    [ -z "$s" ] && continue
    if [ -z "$line" ]; then cand="$s"; else cand="$line|$s"; fi
    if [ -n "$line" ] && [ "$COLS" -gt 0 ] && [ "$(dwidth "$cand")" -gt "$COLS" ]; then
      printf '%s\n' "$line"
      line="$s"
    else
      line="$cand"
    fi
  done
  [ -n "$line" ] && printf '%s' "$line"
}

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

# Display-only names. The line has to fit a phone terminal, but abbreviating the
# services themselves (gem/inw/elab) failed the only test that matters: you have
# to recognise the engine at a glance, and "gem" does not read as Gemini. So the
# product names stay spelled out; only elevenlabs is shortened, to its own common
# 11labs. The width is bought back from separators and labels instead.
# ondevice, which has no product name, becomes "local" — it says what the actual
# distinction is (runs here, no network) — rather than "dev" (reads as
# development) or "ond" (unpronounceable). English rather than 端末, a column
# shorter, so the line needs no redesign when the UI is translated.
# Config values are NOT renamed: `toggle.sh backend ondevice` still takes the
# long name; only what is drawn here differs (README carries the mapping).
short_backend() {
  case "$1" in
    ondevice)   printf 'local' ;;
    gemini)     printf 'gemini' ;;
    inworld)    printf 'inworld' ;;
    elevenlabs) printf '11labs' ;;
    *)          printf '%s' "$1" ;;
  esac
}

# Each readout function can use a different backend, so show each one's backend
# next to its own icon — the backend NAME (gemini/inworld/elevenlabs/ondevice),
# not the full model string. Notifications use TTS_BACKEND_NOTIFICATION; the
# response uses TTS_BACKEND_FULL or _SUMMARY depending on the mode. Both fall
# back to the global TTS_BACKEND, then to ondevice (the shipped default).
notif_backend="$(cfg TTS_BACKEND_NOTIFICATION)"
[ -n "$notif_backend" ] || notif_backend="$(cfg TTS_BACKEND)"
[ -n "$notif_backend" ] || notif_backend="ondevice"

# Full mode reads verbatim; summary mode runs the response through the
# summarizer first. Mark that difference on the line with a short tag before the
# backend — "full" or "sum" — always printed, so the live mode is readable on
# its own rather than inferred from the absence of a tag.
if [ "$(cfg READOUT_MODE)" = "full" ]; then
  resp_backend="$(cfg TTS_BACKEND_FULL)"
  resp_mode="full "
else
  resp_backend="$(cfg TTS_BACKEND_SUMMARY)"
  resp_mode="sum "
fi
[ -n "$resp_backend" ] || resp_backend="$(cfg TTS_BACKEND)"
[ -n "$resp_backend" ] || resp_backend="ondevice"

# The two 決まり文句 (session start / session end) are toggled independently of
# the readout itself, and both play fixed clips rather than a chosen backend —
# so they get one shared "greet" segment with no backend name: left icon is the
# startup greeting (STARTUP_GREETING), right icon the farewell
# (SESSION_END_GREETING).
# Segments are divided by "|". Spaces alone did not read as boundaries — every
# field is itself space-separated, so the eye cannot tell where "greet" ends and
# "notif" begins. A plain ASCII pipe rather than a box-drawing bar: renders in
# any terminal font, and costs one column. The pipe carries the boundary on its
# own, so it gets no padding.
seg "$(printf 'greet %s%s' \
  "$(icon "$(cfg STARTUP_GREETING)")" "$(icon "$(cfg SESSION_END_GREETING)")")"
seg "$(printf 'notif %s %s' \
  "$(icon "$(cfg NOTIFICATION_READOUT)")" "$(short_backend "$notif_backend")")"
seg "$(printf 'resp %s %s%s' \
  "$(icon "$(cfg STOP_READOUT)")" "$resp_mode" "$(short_backend "$resp_backend")")"

# Chunk marker: shown ONLY while it is on. It is off almost always, so a
# permanent segment would spend width on "off" every session — and the one
# moment the state matters is when cues are sounding and it is not obvious why.
# Appearing at all is therefore the signal: cues are on because you asked. The
# bell alone, with no "mark" label: when it is visible there is only one thing
# it can mean, so the word is five columns spent on nothing.
# Reading pace, always shown: it applies to whichever engine is speaking, and
# "is it me or is this fast today" is exactly the question the line should
# answer without asking. 1.0 is roughly an announcer's pace; see resolve_speed()
# in tts-lib.sh for how each engine's own knob is derived from it.
# The "speed" label is dropped for the same reason the bell carries no "mark":
# × is a multiplier sign, and nothing else on this line is a multiplier. The
# label cost six columns off the right edge of a phone terminal, which is where
# this segment sits — so the number itself was what got cut.
speed="$(cfg READOUT_SPEED)"; [ -n "$speed" ] || speed="1.2"
seg "×$speed"

[ "$(cfg CHUNK_MARKER)" = "on" ] && seg '🔔'

emit

exit 0
