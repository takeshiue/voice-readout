#!/bin/bash
# Record a real readout and measure the dead air a listener actually hears.
#
# The pipeline's own `gap` figure is taken when `play` is ISSUED, not when sound
# arrives, so it cannot see the player's startup cost. On 2026-08-20 it reported
# the on-device -> cloud handover as -0.2s while a microphone measured 2.99s of
# silence there, and a 3.16s gap inside the on-device half had no log field at
# all. This drives a real readout, records it, and reports both numbers so they
# can be compared.
#
# PRIVACY: this records the MICROPHONE, so it captures the room, not just the
# speaker. The audio is deleted as soon as it has been reduced to a loudness
# envelope. --keep-audio suppresses that; do not use it on a machine where
# other people are talking.
#
#   tests/measure-seams.sh [-n RUNS] [--fail-over SEC] [--keep-audio]
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

RUNS=1
FAIL_OVER=1.5
KEEP_AUDIO=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n) RUNS="$2"; shift 2 ;;
    --fail-over) FAIL_OVER="$2"; shift 2 ;;
    --keep-audio) KEEP_AUDIO=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Fixed corpus: comparing runs requires the same input every time, and the
# length has to be enough to force a hybrid handover plus several cloud chunks.
TEXT="四月、桜がまだ散りきらない校門を、二十三歳の彼女は初めて教師としてくぐった。若すぎる、と誰もが言った。教室に立つと声が震え、名簿を読む指先が汗ばんだ。彼はいつも窓際の一番後ろにいた。授業の終わり、誰も気づかなかった小さな言い間違いを、彼だけが静かに指摘した。悪意はない。ただ、ちゃんと聞いていた目だった。放課後の職員室で答案をめくりながら、彼女はふいに自分の心臓の音に気づいてしまう。そして気づいた瞬間に、それが決して越えてはならない線の向こう側にあることも、同時に分かってしまった。"

WORK="$(_cloud_scratch_dir)" || { echo "scratch dir unavailable" >&2; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${VOICE_READOUT_SEAM_OUTDIR:-$ROOT_DIR/.seam-measurements}"
mkdir -p "$OUTDIR"

# The microphone must never be left running because a script died. This fires on
# normal exit, on error and on Ctrl-C alike.
stop_recorder() {
  command -v termux-microphone-record >/dev/null 2>&1 && \
    termux-microphone-record -q >/dev/null 2>&1 || true
  [ -n "${FFMPEG_REC_PID:-}" ] && kill "$FFMPEG_REC_PID" 2>/dev/null || true
}
cleanup() {
  stop_recorder
  [ "$KEEP_AUDIO" -eq 0 ] && rm -f "$WORK"/seam-*.aac "$WORK"/seam-*.wav 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM

start_recording() {  # $1 = output path (no extension)
  if command -v termux-microphone-record >/dev/null 2>&1; then
    termux-microphone-record -q >/dev/null 2>&1 || true
    termux-microphone-record -f "$1.aac" -l 600 -e aac -r 44100 -c 1 >/dev/null 2>&1
    RAW="$1.aac"
  elif command -v ffmpeg >/dev/null 2>&1; then
    # Windows/Git Bash: the default capture device via DirectShow.
    ffmpeg -y -f dshow -i audio="${VOICE_READOUT_SEAM_MIC:-Microphone}" \
           -ar 44100 -ac 1 "$1.wav" -loglevel error >/dev/null 2>&1 &
    FFMPEG_REC_PID=$!
    RAW="$1.wav"
  else
    echo "no recorder available (need termux-microphone-record or ffmpeg)" >&2
    exit 1
  fi
}

# Markers are what let the analyser say WHICH seam a silence belongs to. 40ms
# each, so switching them on barely perturbs the thing being measured.
export VOICE_READOUT_CHUNK_MARKER=on

overall=0
for (( run = 1; run <= RUNS; run++ )); do
  base="$WORK/seam-$STAMP-$run"
  echo "=== 実行 $run/$RUNS: 録音開始 ==="
  start_recording "$base"
  sleep 1

  backend="$(get_tuning TTS_BACKEND_FULL "$(get_tuning TTS_BACKEND elevenlabs)")"
  t0="$(date +%s)"
  speak_hybrid "$backend" "$TEXT" "${#TEXT}"
  t1="$(date +%s)"
  sleep 1
  stop_recorder
  sleep 1

  wav="$base-analysis.wav"
  ffmpeg -y -i "$RAW" -ar 24000 -ac 1 "$wav" -loglevel error 2>/dev/null || {
    echo "録音の変換に失敗しました" >&2; overall=1; continue; }

  echo "--- 読み上げ所要 $((t1 - t0))s / バックエンド $backend ---"
  python3 "$ROOT_DIR/scripts/audio_gap_analyzer.py" "$wav" \
      --fail-over "$FAIL_OVER" \
      --envelope "$OUTDIR/envelope-$STAMP-$run.csv" \
      --json "$OUTDIR/result-$STAMP-$run.json" || overall=1

  echo "--- パイプライン自身の申告値（比較用） ---"
  grep -E 'pipeline timing|handover seam' "$LOG_FILE" 2>/dev/null | tail -3 | sed 's/^/    /'

  if [ "$KEEP_AUDIO" -eq 0 ]; then
    rm -f "$RAW" "$wav"
    echo "録音を削除しました（エンベロープのみ $OUTDIR に保存）"
  fi
  echo
done

exit "$overall"
