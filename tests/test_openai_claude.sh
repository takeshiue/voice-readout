#!/bin/bash
# Test OpenAI vs Claude 600-char Explanation via Gemini TTS Hybrid (Tuned for 0.5s gaps)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_openai_claude.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"OpenAIとClaudeの戦いについて説明してください"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"ご説明しますね。……　現代の生成AI業界において、最も熾烈な主導権争いを繰り広げているのがOpenAIとAnthropicの二大巨頭です。\nChatGPTで世界に衝撃を与えたOpenAIは、圧倒的な計算資源と巨額の資金力を武器に、マルチモーダル化と汎用人工知能AGIの早期実現を猛烈なスピードで推し進めています。これに対し、元OpenAIのコアメンバーたちが安全性を最優先に掲げて立ち上げたAnthropicは、モデル『Claude』を通じて独自の対抗軸を築き上げました。\n特に最新のClaude 3.5 Sonnetは、長文コンテキストの正確な把握能力や、プログラミングおよび論理的思考力においてGPT-4oを凌駕するベンチマークを叩き出し、世界中のエンジニアや研究者から絶大な支持を集めています。\nOpenAIがエコシステムの拡大と商業的プラットフォーム化を加速させる一方で、Claudeは緻密なコーディング支援やアーティファクト機能など、開発者の思考を拡張するツールとしての完成度を極限まで高めています。\n革新的なスケーリングと徹底したAIセーフティという異なる哲学が激突するこの覇権争いは、今後のテクノロジーの進化の方向性を決定づける歴史的な転換点となっています。"}
EOF

echo "Launching OpenAI vs Claude (536 chars) via Gemini TTS Hybrid (play-lead tuned for 0.5s gap)..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_openai_claude_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_openai_claude_input.json
