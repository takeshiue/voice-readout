#!/bin/bash
# Test CEO Speech: AI Adoption Passionate Narrative via Final Optimal Settings
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_ceo_speech.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"社員に向けてAI活用を促す社長の熱いスピーチをお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"お伝えしますね。……　全社員の皆さん、聞いてください。AIの急速な進化は、私たちの仕事を奪う脅威ではなく、一人ひとりの可能性を何倍にも解き放つ史上最大のチャンスです。\n実は私自身、最初はAIに頼ることに戸惑いがありました。しかし自らコードを書き、企画を練る中でAIを対等な壁打ち相手として活用し始めた瞬間、思考の視野が一気に広がり、開発スピードが劇的に向上したのです。\nルーチン作業をAIに任せることで、私たちは人間にしかできない『情熱を込めた創造』や『本質的な課題解決』にすべてのエネルギーを注ぎ込めるようになります。\n自らの殻を破り、新しい技術を味方につけた皆さんと共に、業界の未来を切り拓いていけると確信しています。失敗を恐れず、AIという最高の相棒と共に、次のステージへ力強く駆け上がりましょう！"}
EOF

echo "================================================================="
echo "[Step 1] Trigger PreInvocation (Pre-warming audio engine & lastspoke)..."
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1

echo "[Step 2] Launching Passionate CEO Speech via Optimal Voice Pipeline..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_ceo_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_ceo_input.json
