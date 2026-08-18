#!/bin/bash
# Test ElevenLabs Hybrid pipeline on Episode 5 Finale (Heavy Yamasaki Toyoko style)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_ep5_finale.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"第5話完結編をお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"一年後、島崎美由紀の名は銀座の夜の勢力図を塗り替えた『若き伝説』として轟いていた。\n彼女を騙して沈めようとした石田貴政のグループは、美由紀が握った不正取引の証拠によって警察と国税局の捜査を受け、完全に破滅した。かつての復讐を果たしたその夜、美由紀は店のオーナーの座を後輩に譲り渡し、夜の街から静かに身を引いた。\n降り立ったのは、春の陽光が降り注ぐ安曇野の無人駅であった。\n両手いっぱいの荷物を抱えて畦道を歩く美由紀を迎えたのは、完治した母の朗らかな笑い声と、芽吹き始めたわさび田の清冽なせせらぎだった。\n『美由紀、本当にお疲れ様。もうどこへも行かなくていいんだよ』\n母の温かい胸に顔を埋めた瞬間、美由紀の瞳から大粒の涙が零れ落ちた。泥にまみれた母の手を握りしめ、美由紀は深く息を吸い込んだ。胸を満たすのは、冷たい銀座の香水の匂いではなく、懐かしい故郷の土と風の匂いだった。夜の伏魔殿を生き抜いた誇りと、決して失われなかった真心の光を胸に、島崎美由紀の新しい人生が、この静かな大地から始まろうとしていた。"}
EOF

echo "Launching Episode 5 Finale via ElevenLabs Hybrid Pipeline..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_ep5_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_ep5_input.json
