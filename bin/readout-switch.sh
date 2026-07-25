#!/bin/bash
# The stop switch: a single file whose presence silences every readout.
#
# This is deliberately the crudest mechanism in the plugin, because it is the
# one that has to work when nothing else does. speak() checks it before it
# checks anything else — before the per-function backend, before the enable
# toggles, before it looks at any config at all — so no environment variable,
# no alternate CLAUDE_PLUGIN_DATA, and no caller passing clever arguments can
# talk their way past it.
#
# That matters because the ordinary toggles could be bypassed, and were: on
# 2026-07-20 a test run wrote its own config with the readout enabled and
# spoke through the real speaker while the user's own setting said off. A
# stop the user cannot rely on is not a stop.
#
# Usage: readout-switch.sh <stop|resume|status|notify|session-end>
#   stop         silence all readouts until resumed
#   resume       allow readouts again
#   status       print the current state
#   notify       (re)post the notification that shows the state and its button
#   session-end  (SessionEnd hook) remove the notification on exit, but only
#                when enabled — a stopped state is kept visible; skips /clear

set -u

# Fixed absolute path, NOT derived from CLAUDE_PLUGIN_DATA. Everything else in
# this plugin honours that variable, which is exactly why the switch must not:
# redirecting it is one of the ways the ordinary toggles get bypassed. This
# also has to live somewhere both sides can reach — the notification's buttons
# are executed by the Termux app, which cannot see this container's /root,
# while the plugin runs in the container; the Termux home directory is visible
# to both.
STOP_FILE="/data/data/com.termux/files/home/.voice-readout-stopped"
NOTIF_ID="voice-readout-switch"

# The button action runs on the Termux side, which cannot execute anything
# inside this container — and a stop switch that depends on the thing it is
# stopping would be no switch at all. So the toggle logic is installed as a
# tiny self-contained script in Termux's own home directory, which both sides
# can reach, and the button just runs that.
#
# It has to re-post the notification itself. A first attempt had the buttons
# call bare touch/rm, which flipped the file but left the notification showing
# its old label — so after pressing 停止 there was no 再開 button anywhere and
# the switch was one-way, strandable in the off state with no way back except
# asking Claude, which is the exact dependency this whole mechanism exists to
# remove.
HELPER="/data/data/com.termux/files/home/.voice-readout-switch.sh"

install_helper() {
  # Written through a temp file and moved into place, not with `cat > $HELPER`.
  # A redirection follows a symlink and writes to wherever it points; `mv`
  # replaces the link itself. That matters more for this file than for any
  # other the plugin writes, because it is the one the notification button
  # executes — whatever ends up here runs when the user taps 停止.
  # Mode 700 for the same reason: this uid is the only one that ever needs to
  # read or run it. Termux and this proot share it (verified 2026-07-25: real
  # uid 10502 on both sides, and a 0700 file written here is readable by a
  # Termux-side binary), so tightening it does not break the button.
  local tmp="${HELPER}.tmp.$$"
  local old_umask; old_umask="$(umask)"
  umask 077
  cat > "$tmp" <<HELPER_EOF
#!/data/data/com.termux/files/usr/bin/sh
# Installed by voice-readout (bin/readout-switch.sh). Toggles the stop switch
# and re-posts the notification so it always shows the current state.
STOP_FILE="$STOP_FILE"
NOTIF_ID="$NOTIF_ID"

if [ -e "\$STOP_FILE" ]; then
  rm -f "\$STOP_FILE"
  termux-notification --id "\$NOTIF_ID" --title "voice-readout 読み上げ 有効" \\
    --content "[停止する]ボタンで即・全停止できます" --ongoing --priority low \\
    --button1 "停止する" --button1-action "sh \$0"
else
  touch "\$STOP_FILE"
  termux-notification --id "\$NOTIF_ID" --title "voice-readout 読み上げ 停止中" \\
    --content "読み上げは止まっています。[再開する]で元に戻ります" --ongoing --priority low \\
    --button1 "再開する" --button1-action "sh \$0"
fi
HELPER_EOF
  chmod 700 "$tmp" 2>/dev/null
  mv -f "$tmp" "$HELPER" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  umask "$old_umask"
}

post_notification() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  install_helper
  if [ -e "$STOP_FILE" ]; then
    termux-notification \
      --id "$NOTIF_ID" \
      --title "voice-readout 読み上げ 停止中" \
      --content "読み上げは止まっています。[再開する]で元に戻ります" \
      --ongoing \
      --priority low \
      --button1 "再開する" \
      --button1-action "sh $HELPER" \
      2>/dev/null
  else
    termux-notification \
      --id "$NOTIF_ID" \
      --title "voice-readout 読み上げ 有効" \
      --content "[停止する]ボタンで即・全停止できます" \
      --ongoing \
      --priority low \
      --button1 "停止する" \
      --button1-action "sh $HELPER" \
      2>/dev/null
  fi
}

case "${1:-}" in
  stop)
    touch "$STOP_FILE" 2>/dev/null
    post_notification
    echo "voice-readout: 読み上げ 停止中"
    ;;
  resume)
    rm -f "$STOP_FILE" 2>/dev/null
    post_notification
    echo "voice-readout: 読み上げ 有効"
    ;;
  status)
    if [ -e "$STOP_FILE" ]; then
      echo "停止中 ($STOP_FILE)"
    else
      echo "有効"
    fi
    ;;
  notify)
    post_notification
    ;;
  session-end)
    # Called from the SessionEnd hook. Take the button down when Claude Code
    # exits so it isn't left in the shade with nothing to stop — but only when
    # readout is currently ENABLED. If it's stopped, leave the notification up:
    # that's a deliberate state the user should still see and be able to 再開
    # without relaunching, and it's why the next session would be silent.
    # /clear fires SessionEnd too but the session continues, so keep the button.
    REASON="$(cat 2>/dev/null | jq -r '.reason // empty' 2>/dev/null)"
    [ "$REASON" = "clear" ] && exit 0
    # Detach the removal. This is a synchronous SessionEnd hook, and the
    # termux-notification-remove round trip (~1-2s) outlasts the window Claude
    # Code gives SessionEnd hooks before it aborts them ("Hook cancelled"), so a
    # foreground call is killed mid-flight and the button lingers. setsid puts it
    # in its own session so the hook's process group being killed can't take it
    # down; the hook returns immediately.
    if [ ! -e "$STOP_FILE" ] && command -v termux-notification-remove >/dev/null 2>&1; then
      setsid sh -c "termux-notification-remove '$NOTIF_ID' 2>/dev/null" >/dev/null 2>&1 </dev/null &
      disown 2>/dev/null || true
    fi
    ;;
  *)
    echo "Usage: $0 <stop|resume|status|notify|session-end>" >&2
    exit 1
    ;;
esac

exit 0
