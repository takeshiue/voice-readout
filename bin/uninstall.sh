#!/bin/bash
# Removes everything this plugin put on the machine, on both sides of the proot
# boundary. Written because "uninstall the plugin" is not the whole job here and
# two of the leftovers are ones a user cannot clear by guessing:
#
#   - the stop-switch notification is posted --ongoing, so it cannot be swiped
#     away; it needs termux-notification-remove, and it needs to go BEFORE the
#     plugin does, or its button is left pointing at a script that no longer
#     exists
#   - the statusLine entry lives in the user's own settings.json. The plugin
#     asked them to put it there, so taking it back out belongs here rather
#     than in a "now edit this JSON by hand" instruction
#
# What it deliberately does NOT do is remove the plugin itself. Claude Code is
# the package manager here, and removing the package is its job — the same
# division of labour apt and npm use, where a shipped script cleans up side
# effects and the manager owns the files it installed. It prints the two
# commands at the end for the user to run.
#
# Usage: uninstall.sh [--yes] [--keep-data]
#   --yes        don't ask for confirmation
#   --keep-data  keep the config/keys/log directory (default is to delete it)
#
# Every step is skipped harmlessly when the thing it removes is absent or the
# command it needs is missing (a Windows checkout has no termux-* at all), so
# this is safe to re-run.

set -u

ASSUME_YES=0
KEEP_DATA=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y)    ASSUME_YES=1 ;;
    --keep-data) KEEP_DATA=1 ;;
    -h|--help)     sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Same resolution as tts-lib.sh / toggle.sh, and for the same reason: the data
# directory is only handed to hooks, so a script run by hand has to work it out.
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  DATA_DIR="$CLAUDE_PLUGIN_DATA"
elif [ -n "${HOME:-}" ]; then
  DATA_DIR="${HOME}/.claude/plugins/data/voice-readout-voice-readout"
else
  DATA_DIR=""
fi

TERMUX_HOME="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}"

say() { printf '  %s\n' "$1"; }

echo "voice-readout をアンインストールします。消すもの:"
say "常駐通知（ストップスイッチ / 故障通知）"
say "settings.json の statusLine 登録（このプラグインを指している場合のみ）"
[ "$KEEP_DATA" -eq 0 ] && say "設定・APIキー・ログ: ${DATA_DIR:-（不明）}"
say "Termux 側の残骸: ${TERMUX_HOME}/.voice-readout-{stopped,switch.sh,tmp/}"
echo

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '続けますか？ [y/N] '
  # Read from the terminal rather than stdin, so this still asks when the script
  # is run with its input redirected. The open is TESTED first: with no
  # controlling terminal (a pipeline, a hook, CI) the redirection fails and the
  # SHELL prints the error, which no 2>/dev/null on `read` can suppress — the
  # stderr redirection has to come first to catch it. Falling back to stdin
  # keeps the answer readable when it was piped in; an unanswerable prompt
  # then leaves reply empty, which aborts.
  if : 2>/dev/null </dev/tty; then
    read -r reply </dev/tty || reply=""
  else
    read -r reply || reply=""
  fi
  case "$reply" in y|Y|yes|YES) ;; *) echo "中止しました。"; exit 0 ;; esac
  echo
fi

# --- 1. Notifications first. ------------------------------------------------
# Before anything else: the buttons on these notifications run a script in the
# Termux home directory, and step 4 deletes it. Removing the plugin while the
# notification is still up leaves a button that does nothing.
if command -v termux-notification-remove >/dev/null 2>&1; then
  termux-notification-remove voice-readout-switch 2>/dev/null
  termux-notification-remove voice-readout-fix 2>/dev/null
  echo "✓ 通知を削除しました"
else
  echo "- 通知: termux-notification-remove が無いので省略（Termux 以外なら正常）"
fi
command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null

# The recovery watcher is detached (setsid/nohup) and can outlive the plugin,
# probing an engine for a plugin that is gone. Matched on its full path so this
# cannot hit anything else.
if command -v pkill >/dev/null 2>&1; then
  pkill -f 'bin/recovery-watcher\.sh' 2>/dev/null && echo "✓ 復旧ウォッチャーを停止しました"
fi

# --- 2. statusLine out of whichever settings file carries it. ---------------
# statusLine is not a plugin component — Claude Code has no such slot, so this
# plugin's README asks the user to register bin/statusline.sh in settings.json
# themselves. That means it can be in any of the settings files Claude Code
# merges, not just the user-level one this originally checked.
#
# Only removed when it actually points at THIS plugin: the key belongs to the
# user, and someone who has since repointed it at a different script must not
# lose theirs. jq rewrites the file's formatting, so a .bak is kept — these are
# hand-edited files.
strip_statusline() {
  local f="$1"
  [ -f "$f" ] || return 1
  jq -e '(.statusLine.command // "") | test("voice-readout")' "$f" >/dev/null 2>&1 || return 1
  cp "$f" "${f}.bak-voice-readout" 2>/dev/null
  if jq 'del(.statusLine)' "$f" > "${f}.tmp" 2>/dev/null && [ -s "${f}.tmp" ]; then
    mv "${f}.tmp" "$f"
    echo "✓ statusLine を削除しました: $f （元は ${f}.bak-voice-readout）"
  else
    rm -f "${f}.tmp"
    echo "! 書き換えに失敗しました。$f の statusLine を手で消してください"
  fi
  return 0
}

if command -v jq >/dev/null 2>&1; then
  sl_found=0
  # The user-level pair, plus the project-level pair for wherever this was run
  # from. A project file somewhere else on disk cannot be found from here, so
  # the miss is reported rather than passed over in silence.
  for s in "${HOME:-}/.claude/settings.json" \
           "${HOME:-}/.claude/settings.local.json" \
           "$PWD/.claude/settings.json" \
           "$PWD/.claude/settings.local.json"; do
    strip_statusline "$s" && sl_found=1
  done
  if [ "$sl_found" -eq 0 ]; then
    echo "- statusLine: このプラグインを指す登録は見つかりませんでした"
    echo "    プロジェクト側に登録していた場合は、そのディレクトリで次を実行して探せます:"
    echo "    grep -l voice-readout .claude/settings*.json"
  fi
else
  echo "! jq が無いので settings.json は触りません。statusLine の行を手で消してください"
fi

# --- 3. Config, API keys, log. ----------------------------------------------
if [ "$KEEP_DATA" -eq 1 ]; then
  echo "- 設定・鍵・ログ: --keep-data のため残しました（${DATA_DIR}）"
elif [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ]; then
  rm -rf "$DATA_DIR" && echo "✓ 設定・APIキー・ログを削除しました"
else
  echo "- 設定・鍵・ログ: 見つからないので省略"
fi

# --- 4. The Termux side. ----------------------------------------------------
removed=0
for p in "$TERMUX_HOME/.voice-readout-stopped" "$TERMUX_HOME/.voice-readout-switch.sh"; do
  [ -e "$p" ] && { rm -f "$p" && removed=1; }
done
[ -d "$TERMUX_HOME/.voice-readout-tmp" ] && { rm -rf "$TERMUX_HOME/.voice-readout-tmp" && removed=1; }
[ "$removed" -eq 1 ] && echo "✓ Termux 側の残骸を削除しました" \
                     || echo "- Termux 側の残骸: 無し"

# --- 5. What is left for the user. ------------------------------------------
# The plugin's own files are the package manager's business, not this script's.
echo
echo "後始末は完了しました。残りは2つです。"
echo
echo "1. プラグイン本体の削除（Claude Code の中で）:"
echo "     /plugin uninstall voice-readout@voice-readout"
echo "     /plugin marketplace remove voice-readout"
echo "   ターミナルからなら:"
echo "     claude plugin uninstall voice-readout@voice-readout"
echo "     claude plugin marketplace remove voice-readout"
echo
echo "2. APIキーの失効:"
echo "   クラウドTTSを使っていた場合、ローカルの鍵ファイルを消してもキー自体は"
echo "   生きています。発行元（Google AI Studio / Inworld Portal / ElevenLabs）の"
echo "   ダッシュボードで削除してください。"
exit 0
