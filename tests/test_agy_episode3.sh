#!/bin/bash
# Test agy hook pipeline with Episode 3 text
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure stop switch is clear
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_ep3.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"第3話をお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"『美由紀、俺たちの将来のために少しだけ協力してくれないか？』\n石田貴政は、いつもの甘い眼差しで私の手を握りしめた。立ち上げようとしている事業の資金がどうしても足りないのだと、彼は悔しそうに眉をひそめる。\n『美由紀の美貌なら、夜の店で少しの間バイトするだけで、あっという間に稼げると思うんだ。俺、絶対美由紀を幸せにするから』\nその言葉を、25歳の島崎美由紀はまだ純粋に信じていた。田舎で病気がちな母が一人、畑を耕しながら送ってくれる米の味を知っている美由紀にとって、誰かを疑うこと自体が罪のように思えたのだ。\nそうして足を踏み入れたネオンの街。煌びやかなドレスに身を包み、グラスに酒を注ぐ日々の中で、美由紀の耳に入ってきたのは、他のホステスたちの噂話だった。『あの石田って男、女を何人も店に沈めて金巻き上げてる有名なヒモだよ』。\n氷が溶けるように、信じていた世界が音を立てて崩れていく。\n――騙されていたんだ。\nグラスを見つめる美由紀の瞳から、それまでの純朴な光がすっと消え失せ、冷たく妖艶な光が宿り始めていた。"}
EOF

echo "Launching Episode 3 readout via agy Stop hook pipeline..."
printf '{"transcriptPath": "%s"}\n' "$TMP_TRANSCRIPT" | "$ROOT_DIR/bin/agy-summarize-and-speak.sh"
echo "Hook finished immediately. Playback started in background."
