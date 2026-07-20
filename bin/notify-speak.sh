#!/bin/bash
# Notification hook: speak a short Japanese phrase when Claude Code is blocked
# waiting on the user (tool permission Yes/No, idle input prompt). The Stop
# hook never fires mid-turn, so without this the session goes silent exactly
# when it needs attention. Registered with "async": true; always exit 0.

set -u

if [ "${VOICE_READOUT_GUARD:-}" = "1" ]; then
  exit 0
fi
export VOICE_READOUT_GUARD=1

source "$(dirname "$0")/tts-lib.sh"

if ! is_enabled NOTIFICATION_READOUT; then
  log skip "notification readout disabled via toggle"
  exit 0
fi

INPUT_JSON="$(cat)"
MESSAGE="$(printf '%s' "$INPUT_JSON" | jq -r '.message // empty' 2>/dev/null)"

log notification "$MESSAGE"

# These are static phrases (no LLM call — a permission prompt wants an
# instant readout), so tone can't be derived from free-text persona content
# like the Haiku-summarized Stop hook does. Instead: persona file present ->
# sweet preset phrases, absent -> plain short neutral phrases. Add more
# presets here in tandem with new files under personas/ if that's ever needed.
if [ -z "$MESSAGE" ]; then
  log skip "no message in Notification hook input"
  exit 0
fi

if persona_active; then
  case "$MESSAGE" in
    *"permission to use "*)
      TOOL="$(printf '%s' "$MESSAGE" | sed -E 's/.*permission to use //; s/[[:punct:]]*$//')"
      PHRASE="ねえ、${TOOL}を動かしてもいいかしら。あなたの確認、待ってるのよ"
      ;;
    *permission*)
      PHRASE="実行の許可がほしいの。確認してくれると嬉しいわ"
      ;;
    *"waiting for your input"*|*idle*)
      PHRASE="ねえ、お返事待ってるのよ。そろそろ聞かせてほしいな"
      ;;
    *)
      PHRASE="ちょっと確認してほしいことがあるの。お願いね"
      ;;
  esac
else
  case "$MESSAGE" in
    *"permission to use "*)
      TOOL="$(printf '%s' "$MESSAGE" | sed -E 's/.*permission to use //; s/[[:punct:]]*$//')"
      PHRASE="${TOOL}の実行許可を求めています"
      ;;
    *permission*)
      PHRASE="実行許可の確認が待っています"
      ;;
    *"waiting for your input"*|*idle*)
      PHRASE="入力を待っています"
      ;;
    *)
      PHRASE="確認が必要です"
      ;;
  esac
fi

# Always ondevice here, regardless of the TTS_BACKEND toggle: permission/idle
# prompts want an instant cue, and Gemini's ~5-7s network round trip before
# any sound starts defeats the purpose (measured 2026-07-20). The backend
# toggle only affects the Stop-hook summary readout (summarize-and-speak.sh).
VOICE_READOUT_TTS_BACKEND=ondevice speak "$PHRASE"

exit 0
