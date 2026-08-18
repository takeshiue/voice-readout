#!/bin/bash
# Test Inworld Hybrid pipeline with lead=2.3s on Episode 3 (Heavy Yamasaki Toyoko style)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_ep3_heavy.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"第3話をお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"美由紀の蓄えのほぼ全額であった二十五万円を立て替えてから一週間、石田貴政からの返済は滞ったままであった。問い詰める美由紀に対し、貴政は丸の内の高級ホテルのラウンジで苦渋に満ちた表情を浮かべて見せた。\n『本当にすまない。新規事業の提携先が急に不渡りを出してね。今、僕の口座も一時的に凍結されているんだ。だが、あと五百万円さえ用意できれば、全ての資金が還流して美由紀さんにも利息をつけて倍にして返せる』\n貴政は美由紀の細い肩を抱き寄せ、耳元で悪魔のように甘美な囁きを落とした。\n『銀座の一流クラブなら、美由紀さんのその高貴な美貌と教養があれば、ほんの二、三ヶ月手伝うだけで五百万など容易に作れる。僕たちの将来のためだ、美由紀さん。君だけが頼りなんだ』\nその真摯を装った瞳の奥にある冷酷な計算を、美由紀は見抜くことができなかった。安曇野の土の匂いに育まれ、信じることしか教わってこなかった彼女にとって、愛する男の危機を見捨てる選択肢はなかった。こうして島崎美由紀は、煌びやかなシャンデリアが照らす夜の伏魔殿へと、その純白の身を投じることとなったのである。"}
EOF

echo "Launching Episode 3 via Inworld Hybrid (play-lead tuned to 2.3s)..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_ep3_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_ep3_input.json
