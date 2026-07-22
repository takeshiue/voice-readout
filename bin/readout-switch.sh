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
# Usage: readout-switch.sh <stop|resume|status|notify>
#   stop    silence all readouts until resumed
#   resume  allow readouts again
#   status  print the current state
#   notify  (re)post the notification that shows the state and its button

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
  cat > "$HELPER" <<HELPER_EOF
#!/data/data/com.termux/files/usr/bin/sh
# Installed by voice-readout (bin/readout-switch.sh). Toggles the stop switch
# and re-posts the notification so it always shows the current state.
STOP_FILE="$STOP_FILE"
NOTIF_ID="$NOTIF_ID"

if [ -e "\$STOP_FILE" ]; then
  rm -f "\$STOP_FILE"
  termux-notification --id "\$NOTIF_ID" --title "読み上げ 有効" \\
    --content "[停止する]ボタンで即・全停止できます" --ongoing --priority low \\
    --button1 "停止する" --button1-action "sh \$0"
else
  touch "\$STOP_FILE"
  termux-notification --id "\$NOTIF_ID" --title "読み上げ 停止中" \\
    --content "読み上げは止まっています。[再開する]で元に戻ります" --ongoing --priority low \\
    --button1 "再開する" --button1-action "sh \$0"
fi
HELPER_EOF
  chmod +x "$HELPER" 2>/dev/null
}

post_notification() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  install_helper
  if [ -e "$STOP_FILE" ]; then
    termux-notification \
      --id "$NOTIF_ID" \
      --title "読み上げ 停止中" \
      --content "読み上げは止まっています。[再開する]で元に戻ります" \
      --ongoing \
      --priority low \
      --button1 "再開する" \
      --button1-action "sh $HELPER" \
      2>/dev/null
  else
    termux-notification \
      --id "$NOTIF_ID" \
      --title "読み上げ 有効" \
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
  *)
    echo "Usage: $0 <stop|resume|status|notify>" >&2
    exit 1
    ;;
esac

exit 0
