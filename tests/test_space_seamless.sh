#!/bin/bash
# Test Space Science Narrative (James Webb Telescope, ~520 chars) via Perfect Seamless Pipeline
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_space.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"ジェームズウェッブ宇宙望遠鏡の発見について教えてください"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"ご説明しますね。……　人類史上最大の宇宙望遠鏡であるジェームズウェッブは、宇宙誕生から間もない初期銀河の姿を次々と捉えています。\n従来のハッブル望遠鏡を遥かに凌ぐ赤外線観測能力により、ビッグバンからわずか数億年後に誕生したとされる最古の星々の光を鮮明に捉えることに成功しました。これらの観測データは、初期宇宙における銀河形成のスピードが従来の理論モデルを大きく上回っていた可能性を示唆しており、現代の天文学に大きな衝撃を与えています。\nさらに、太陽系外惑星の大気成分の精密なスペクトル分析により、水蒸気や二酸化炭素の存在を検出するなど、生命居住可能惑星の探査においても歴史的なマイルストーンを刻み続けています。\n宇宙の暗黒時代を照らし出すこの壮大なプロジェクトは、私たちがどこから来たのかという根源的な問いに対する決定的な手がかりをもたらしつつあります。"}
EOF

echo "================================================================="
echo "[Step 1] Trigger PreInvocation (Pre-warming audio engine & lastspoke)..."
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1

echo "[Step 2] Launching Space Science Narrative via Gemini TTS Hybrid..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_space_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_space_input.json
