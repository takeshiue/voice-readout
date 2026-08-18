#!/bin/bash
# Test optimized Inworld Hybrid pipeline with Episode 2 (Heavy Yamasaki Toyoko style)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_ep2_heavy.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"第2話をお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"案内されたのは、銀座の雑居ビルの地下深くに潜む、看板のない会員制のバーであった。重厚なマホガニーのカウンターに腰を下ろすと、石田貴政は手慣れた仕草でバーテンダーに合図を送り、美由紀のために琥珀色のカクテルを注文した。仄暗い間接照明に照らされた貴政の横顔は、彫刻のように端正で、洗練された都会の余裕に満ち溢れていた。\n『美由紀さんのその澄んだ瞳を見ていると、東京の汚れきった空気が洗われるようだ』\n貴政の囁くような甘美な声音に、美由紀の胸の奥は甘く疼いた。だが、その陶酔の合間に、彼女は微かな違和感を拭い去れずにいた。カウンターに無造作に置かれた貴政のスマートフォンが、無音のまま幾度も画面を明滅させ、女性の名と思われる通知が次々と浮かび上がっては消えていくのだ。\nやがて、銀のトレイに載せられた勘定書が置かれた。貴政は財布を開く素振りを見せ、わざとらしく眉間に皺を寄せた。\n『あ、いけない。今日に限ってメインカードの更新手続き中だったんだ。美由紀さん、すまないが今夜だけ立て替えておいてくれないか。明日一番で振り込むから』\n差し出された伝票の数字は、美由紀の月給の手取り額を遥かに超える二十五万円と記されていた。"}
EOF

echo "Launching Episode 2 via Optimized Inworld Hybrid Pipeline..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_ep2_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_ep2_input.json
