#!/usr/bin/env bash
# voice-readout doctor — one-shot report on why this host is not talking.
#
# Prints a labelled report and exits. Safe to run any time: it reads state and
# speaks three short test phrases, and changes nothing else.
#
# The three phrases are the point, not padding. The Windows port's open bug is
# "spoke once, then silence", and the same shape has three very different
# causes: the speech engine itself failing on a repeat call, a gate inside the
# plugin skipping the second readout, or the summariser hanging before either
# gets a chance. Speaking straight from here bypasses both the gates and the
# summariser, so if all three are audible the fault is above this layer, and if
# only the first is audible it is the engine. That is the whole split, and it
# costs one run to get.
#
# Usage:  bash bin/doctor.sh
set -u

say() { printf '\n=== %s ===\n' "$1"; }
ok()  { printf '  [ok]   %s\n' "$1"; }
bad() { printf '  [MISS] %s\n' "$1"; }
kv()  { printf '  %-22s %s\n' "$1" "$2"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say "host"
kv "uname" "$(uname -a 2>/dev/null || echo '?')"
kv "bash" "${BASH_VERSION:-?}"
kv "OSTYPE" "${OSTYPE:-?}"
kv "TMPDIR" "${TMPDIR:-<unset>}"

say "commands"
# Split by platform so a missing Termux tool on Windows does not read as a
# fault: each host only needs its own column. jq is shared and is the one the
# Windows install actually has to add by hand.
for c in bash awk sed grep curl jq ffmpeg ffprobe; do
  command -v "$c" >/dev/null 2>&1 && ok "$c -> $(command -v "$c")" || bad "$c"
done
printf '  -- termux --\n'
for c in termux-tts-speak termux-media-player termux-notification; do
  command -v "$c" >/dev/null 2>&1 && ok "$c" || bad "$c (fine off Android)"
done
printf '  -- windows --\n'
for c in powershell.exe powershell cygpath; do
  command -v "$c" >/dev/null 2>&1 && ok "$c" || bad "$c (fine off Windows)"
done

say "plugin data dir"
# The hook environment and an interactive shell do not necessarily agree on
# this, and when they disagree every piece of state below is read from a
# different place than the one the hooks write. That mismatch has already
# caused one misdiagnosis on Android, so print the raw variable, not just the
# resolved path.
kv "CLAUDE_PLUGIN_DATA" "${CLAUDE_PLUGIN_DATA:-<unset — this shell is not a hook>}"
data="${CLAUDE_PLUGIN_DATA:-}"
if [ -z "$data" ]; then
  # Where the hooks actually write when the variable is not in the environment,
  # which is every interactive shell. Guessing the repo directory instead sends
  # every check below at a directory that is always empty, and reads as "no
  # config, no log, nothing wrong" — the exact shape of a past misdiagnosis.
  for d in "$HOME/.claude/plugins/data/voice-readout-voice-readout" \
           "$HOME/.claude/plugins/data/voice-readout"; do
    [ -d "$d" ] && { data="$d"; break; }
  done
fi
[ -n "$data" ] || data="$(dirname "$here")"
kv "resolved" "$data"
if [ -d "$data" ]; then
  ok "exists"
else
  bad "missing"
fi

say "state files"
for f in voice-readout-config voice-readout.env voice-readout.log \
         voice-readout-ondevice.lock voice-readout-last-notify; do
  p="$data/$f"
  if [ -e "$p" ]; then
    kv "$f" "$(wc -c <"$p" 2>/dev/null | tr -d ' ') bytes, mtime $(date -r "$p" '+%F %T' 2>/dev/null || echo '?')"
  else
    kv "$f" "-"
  fi
done
# The stop switch is deliberately at a fixed absolute path that no config or
# env var can move, so it is checked literally and not under $data. If this
# file is present, everything is meant to be silent and nothing below is a bug.
if [ -e /tmp/voice-readout-stop ]; then
  printf '  [STOP] /tmp/voice-readout-stop is present — readout is switched OFF\n'
else
  ok "stop switch clear"
fi

say "log tail"
log="$data/voice-readout.log"
if [ -f "$log" ]; then
  tail -n 25 "$log"
else
  # Interactive shells often resolve the data dir differently from the hooks,
  # so a miss here is not proof there is no log — go and look.
  echo "  no log at $log"
  found="$(find "$HOME/.claude" /tmp -name voice-readout.log 2>/dev/null | head -3)"
  [ -n "$found" ] && { echo "  found elsewhere:"; echo "$found" | sed 's/^/    /'; }
fi

say "speech test (3 calls)"
echo "  Listen. All three audible = engine fine, look higher up."
echo "  Only the first = the engine stops answering on repeat calls."
echo
if [ -f "$here/tts-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$here/tts-lib.sh" 2>/dev/null || echo "  (tts-lib.sh would not source — testing the engine raw)"
fi
for i in 1 2 3; do
  printf '  call %d ... ' "$i"
  rc=1
  if command -v termux-tts-speak >/dev/null 2>&1; then
    termux-tts-speak "テスト $i 回目" >/dev/null 2>&1; rc=$?
  elif declare -f speak_windows_sapi >/dev/null 2>&1; then
    speak_windows_sapi "テスト $i 回目" >/dev/null 2>&1; rc=$?
  else
    ps=""
    command -v powershell.exe >/dev/null 2>&1 && ps=powershell.exe
    [ -z "$ps" ] && command -v powershell >/dev/null 2>&1 && ps=powershell
    if [ -n "$ps" ]; then
      "$ps" -NoProfile -Command \
        "Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak('テスト $i 回目')" \
        >/dev/null 2>&1; rc=$?
    else
      echo "no engine found"; break
    fi
  fi
  printf 'exit=%d\n' "$rc"
  sleep 1
done

say "summariser"
# The readout of a long response goes through a nested `claude -p` call, and a
# hang there is silent from the outside: the hook is simply still waiting when
# the user gives up. Time it, so a slow one is visible as a number.
if command -v claude >/dev/null 2>&1; then
  kv "claude" "$(command -v claude)"
  t0=$(date +%s)
  out="$(claude --safe-mode -p --model haiku 'Reply with the single word: ok' 2>&1 | head -c 120)"
  kv "took" "$(( $(date +%s) - t0 ))s"
  kv "said" "${out:-<nothing>}"
else
  bad "claude not on PATH — summarised readouts cannot work"
fi

printf '\n=== done ===\n'
