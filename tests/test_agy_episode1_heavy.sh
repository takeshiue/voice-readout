#!/bin/bash
# Test agy hook pipeline with Episode 1 (Heavy detail Yamasaki Toyoko style)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure stop switch is clear
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_ep1_heavy.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"第1話を山崎豊子風の重厚な描写でお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"初冬の丸の内、仲通りを渡る風は研ぎ澄まされた刃のように冷たかった。街路樹のイルミネーションが濡れた石畳に橙色の影を落とす中、島崎美由紀は襟元をかき合わせ、時計の針を気にしていた。信州・安曇野の山懐で育ち、丸の内の中堅商社で経理事務を執る彼女の身なりは、手入れの行き届いた紺のウールコートに無地のマフラーと、いかにも堅実そのものであった。\n『待たせてしまったね、美由紀さん』\n背後からかけられた滑らかなバリトンに振り返ると、そこには完璧な笑みを湛えた石田貴政が立っていた。仕立ての良いチャコールグレーのカシミアコートに、わずかに覗くバーバリーのチェック。整った鼻梁と知性を滲ませる細身の眼鏡の奥で、彼の双眸は獲物の値踏みを済ませた捕食者のように冷たく澄んでいた。\n『いえ、私も今着いたところですから』\n嘘をつく美由紀の手を、貴政は手袋越しではなく、わざわざ外した素手で優しく包み込んだ。触れた手のひらの熱に、美由紀の白い頬がかすかに上気する。病弱な母が一人遺る信州の寒村から上京して三年。孤独な都会の夜に差し伸べられたその温もりが、彼女の人生を狂わせる甘い罠であることなど、この時の彼女は知る由もなかった。"}
EOF

echo "Launching Episode 1 (Yamasaki Toyoko style) readout via agy Stop hook pipeline..."
printf '{"transcriptPath": "%s"}\n' "$TMP_TRANSCRIPT" | "$ROOT_DIR/bin/agy-summarize-and-speak.sh"
echo "Hook finished immediately."
