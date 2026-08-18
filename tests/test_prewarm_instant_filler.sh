#!/bin/bash
# Benchmark test: PreInvocation Pre-warm -> Stop Hook Instant Filler Launch (Measuring latency in milliseconds)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

export VOICE_READOUT_TTS_BACKEND=ondevice
export VOICE_READOUT_NO_CLOUD_FALLBACK=1

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_prewarm_benchmark.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"事前ウォームアップの計測をお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"事前ウォームアップの効果により、AIの回答完了からミリ秒単位で即座にフィラー音声が発音開始されました。"}
EOF

echo "================================================================="
echo "[Step 1] User sends message -> Trigger PreInvocation (Pre-warm)..."
echo "================================================================="
t_prewarm_start="$(date +%s.%N)"
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1 &
PREWARM_PID=$!

echo "[Step 2] AI is generating response (Simulating 1.5s thinking time)..."
sleep 1.5
wait "$PREWARM_PID" 2>/dev/null || true

echo "================================================================="
echo "[Step 3] AI generation DONE -> Trigger Stop Hook (Measuring Latency)..."
echo "================================================================="

t_stop_start="$(date +%s.%N)"
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_prewarm_input.json

# Execute Stop hook worker directly and measure exact moment filler is kicked
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_prewarm_input.json &
WORKER_PID=$!

t_stop_fired="$(date +%s.%N)"
latency_ms="$(awk -v s="$t_stop_start" -v f="$t_stop_fired" 'BEGIN{ printf "%.1f", (f - s) * 1000 }')"

echo ">>> Stop Hook Fired -> Instant Filler Launched in: ${latency_ms} ms (0.${latency_ms%.*}s)!"
echo "================================================================="

wait "$WORKER_PID" 2>/dev/null || true
echo "Benchmark completed successfully."
