#!/bin/bash
# Launches the Windows stop-button window (bin/stop-button.ps1), detached, with
# a single-instance guard. No-op on Android, where the persistent Termux
# notification posted by bin/readout-switch.sh already provides the button.
#
# Usage: stop-button.sh <start|stop|status>
#   start   open the button window if it isn't already open
#   stop    close it (leaves the stop switch itself untouched)
#   status  print whether a button window is running

set -u

source "$(dirname "${BASH_SOURCE[0]}")/tts-lib.sh"

# Android already has a button; ffplay-only platforms are the ones that need
# this. Keyed off termux-media-player like every other platform split here.
if command -v termux-media-player >/dev/null 2>&1; then
  exit 0
fi
command -v powershell.exe >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1 || exit 0

PS_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/stop-button.ps1"
[ -f "$PS_SCRIPT" ] || { echo "stop-button.ps1 not found beside this script" >&2; exit 1; }

# The pid file lives in the plugin data dir, unlike the stop switch itself. It
# is bookkeeping, not the mechanism: if it is lost or redirected the worst case
# is a second window, whereas a redirected STOP_SWITCH_FILE would be a stop
# that silences nothing.
BUTTON_PID_FILE="${PLUGIN_DATA_DIR}/voice-readout-stop-button.pid"

_button_running() {
  local pid; pid="$(cat "$BUTTON_PID_FILE" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  # A pid file outliving its process is the normal case after a crash or a
  # reboot, so liveness is checked rather than trusted. Without this the guard
  # would refuse to ever open the window again.
  kill -0 "$pid" 2>/dev/null
}

case "${1:-start}" in
  start)
    if _button_running; then
      exit 0
    fi
    # Paths are converted to Windows form because PowerShell cannot resolve the
    # /c/... form Git Bash uses.
    win_stop="$(cygpath -w "$STOP_SWITCH_FILE" 2>/dev/null || printf '%s' "$STOP_SWITCH_FILE")"
    win_pidf="$(cygpath -w "$BUTTON_PID_FILE" 2>/dev/null || printf '%s' "$BUTTON_PID_FILE")"
    win_ps="$(cygpath -w "$PS_SCRIPT" 2>/dev/null || printf '%s' "$PS_SCRIPT")"
    win_cfg="$(cygpath -w "$CONFIG_FILE" 2>/dev/null || printf '%s' "$CONFIG_FILE")"
    # Passed so the voice row can offer only the engines whose keys exist. The
    # window tests for key NAMES and never reads a value (see the header there).
    win_env="$(cygpath -w "$ENV_FILE" 2>/dev/null || printf '%s' "$ENV_FILE")"
    PS_BIN="$(command -v powershell.exe 2>/dev/null || command -v powershell)"

    # The settings rows write through toggle.sh rather than editing the config
    # from PowerShell (see the header in stop-button.ps1), so the button needs
    # both bash and that script. Passed as Windows paths: PowerShell starts
    # bash.exe as a plain process and cannot resolve the /c/... form. The
    # toggle path stays a Unix path — bash itself is what opens it.
    win_bash="$(cygpath -w "$(command -v bash)" 2>/dev/null || printf '%s' "$(command -v bash)")"
    toggle_sh="$(dirname "${BASH_SOURCE[0]}")/toggle.sh"

    # Asked with speak_hybrid()'s OWN gate helpers rather than a copy of its
    # conditions, so the panel cannot drift from what that function will actually
    # do. (It did drift once: the gate named Android's two commands directly, and
    # this check named them too, which reported 非対応 on Windows even after
    # hybrid gained a SAPI/ffplay path.)
    hybrid_flag=""
    if _ondevice_voice_available && _audio_player_available; then
      hybrid_flag="-HybridSupported"
    fi

    # -WindowStyle Hidden hides POWERSHELL's own console, not the WinForms
    # window the script opens; without it a black console box sits behind the
    # button for the whole session. nohup + disown so the window outlives this
    # hook process — a SessionStart hook's children are otherwise reaped with it.
    nohup "$PS_BIN" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
      -File "$win_ps" -StopFile "$win_stop" -PidFile "$win_pidf" \
      -ConfigFile "$win_cfg" -EnvFile "$win_env" \
      -BashExe "$win_bash" -ToggleScript "$toggle_sh" $hybrid_flag \
      </dev/null >/dev/null 2>&1 &
    button_pid=$!
    disown 2>/dev/null || true
    printf '%s' "$button_pid" > "$BUTTON_PID_FILE" 2>/dev/null
    log info "stop button window opened (pid ${button_pid})"
    ;;
  stop)
    pid="$(cat "$BUTTON_PID_FILE" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null ;; esac
    rm -f "$BUTTON_PID_FILE" 2>/dev/null
    ;;
  status)
    if _button_running; then
      echo "stop button: running (pid $(cat "$BUTTON_PID_FILE" 2>/dev/null))"
    else
      echo "stop button: not running"
    fi
    echo "stop switch: $STOP_SWITCH_FILE"
    if [ -e "$STOP_SWITCH_FILE" ]; then echo "state: 停止中"; else echo "state: 有効"; fi
    ;;
  *)
    echo "Usage: $0 <start|stop|status>" >&2
    exit 1
    ;;
esac

exit 0
