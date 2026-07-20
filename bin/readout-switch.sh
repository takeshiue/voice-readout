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

# The button actions are plain `touch`/`rm` run by the Termux app. They
# deliberately call nothing from this plugin: the Termux side cannot execute
# scripts living in the container, and a stop switch that depends on the
# thing it is stopping is not much of a switch. The trade-off is that the
# notification's own label does not change on tap — the plugin re-posts it
# from post_notification() the next time it runs.
post_notification() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  if [ -e "$STOP_FILE" ]; then
    termux-notification \
      --id "$NOTIF_ID" \
      --title "読み上げ 停止中" \
      --content "タップで再開します" \
      --ongoing \
      --priority low \
      --button1 "再開" \
      --button1-action "rm -f $STOP_FILE" \
      2>/dev/null
  else
    termux-notification \
      --id "$NOTIF_ID" \
      --title "読み上げ 有効" \
      --content "タップで停止します" \
      --ongoing \
      --priority low \
      --button1 "停止" \
      --button1-action "touch $STOP_FILE" \
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
