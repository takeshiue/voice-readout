#!/bin/bash
# Reconstruct Exact Timeline of CEO Speech and Run VAD Waveform Analysis
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

RECORD_DIR="/tmp/vad_ceo_speech"
mkdir -p "$RECORD_DIR"
rm -f "$RECORD_DIR"/*

# 1. Filler (filler_13.wav)
FILLER_WAV="$ROOT_DIR/assets/fillers/filler_13.wav"
cp "$FILLER_WAV" "$RECORD_DIR/01_filler.wav"

# 2. Local Opening Audio (53 chars)
LOCAL_TEXT="全社員の皆さん、聞いてください。AIの急速な進化は、私たちの仕事を奪う脅威ではなく、一人ひとりの可能性を何倍にも解き放つ史上最大のチャンスです。"
python3 -c "
import urllib.request, subprocess
url = 'https://translate.google.com/translate_tts?ie=UTF-8&q=' + urllib.parse.quote('''$LOCAL_TEXT''') + '&tl=ja&client=tw-ob'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(req) as resp, open('$RECORD_DIR/local.mp3', 'wb') as f:
    f.write(resp.read())
"
ffmpeg -y -i "$RECORD_DIR/local.mp3" -filter:a "atempo=1.31" -ar 24000 -ac 1 "$RECORD_DIR/02_local.wav" >/dev/null 2>&1

# 3. Gemini Chunks
CHUNK0_TEXT="実は私自身、最初はAIに頼ることに戸惑いがありました。しかし自らコードを書き、企画を練る中でAIを対等な壁打ち相手として活用し始めた瞬間、思考の視野が一気に広がり、開発スピードが劇的に向上したのです。"
CHUNK1_TEXT="ルーチン作業をAIに任せることで、私たちは人間にしかできない『情熱を込めた創造』や『本質的な課題解決』にすべてのエネルギーを注ぎ込めるようになります。"
CHUNK2_TEXT="自らの殻を破り、新しい技術を味方につけた皆さんと共に、業界の未来を切り拓いていけると確信しています。失敗を恐れず、AIという最高の相棒と共に、次のステージへ力強く駆け上がりましょう！"

gen_cloud "gemini" "$CHUNK0_TEXT" "ceo_0" >/dev/null 2>&1
gen_cloud "gemini" "$CHUNK1_TEXT" "ceo_1" >/dev/null 2>&1
gen_cloud "gemini" "$CHUNK2_TEXT" "ceo_2" >/dev/null 2>&1

P0="$(_cloud_audio_path "gemini" "ceo_0")"
P1="$(_cloud_audio_path "gemini" "ceo_1")"
P2="$(_cloud_audio_path "gemini" "ceo_2")"

cp "$P0" "$RECORD_DIR/03_gemini_0.wav" 2>/dev/null || true
cp "$P1" "$RECORD_DIR/04_gemini_1.wav" 2>/dev/null || true
cp "$P2" "$RECORD_DIR/05_gemini_2.wav" 2>/dev/null || true

# Actual playback timeline with measured waited 1.0s + player startup lag
# Local -> Gemini 0: waited 1.0s + 0.8s player startup = 1.8s
ffmpeg -y -f lavfi -i "anullsrc=r=24000:cl=mono" -t 0.5 -ar 24000 -ac 1 "$RECORD_DIR/pause_filler.wav" >/dev/null 2>&1
ffmpeg -y -f lavfi -i "anullsrc=r=24000:cl=mono" -t 1.0 -ar 24000 -ac 1 "$RECORD_DIR/seam_local_cloud.wav" >/dev/null 2>&1
ffmpeg -y -f lavfi -i "anullsrc=r=24000:cl=mono" -t 0.3 -ar 24000 -ac 1 "$RECORD_DIR/pause_cloud.wav" >/dev/null 2>&1

cat << EOF > "$RECORD_DIR/concat.txt"
file '$RECORD_DIR/01_filler.wav'
file '$RECORD_DIR/pause_filler.wav'
file '$RECORD_DIR/02_local.wav'
file '$RECORD_DIR/seam_local_cloud.wav'
file '$RECORD_DIR/03_gemini_0.wav'
file '$RECORD_DIR/pause_cloud.wav'
file '$RECORD_DIR/04_gemini_1.wav'
file '$RECORD_DIR/pause_cloud.wav'
file '$RECORD_DIR/05_gemini_2.wav'
EOF

COMBINED_WAV="$RECORD_DIR/ceo_speech_full.wav"
ffmpeg -y -f concat -safe 0 -i "$RECORD_DIR/concat.txt" -ar 24000 -ac 1 "$COMBINED_WAV" >/dev/null 2>&1

echo "CEO Speech Combined Audio Generated: $COMBINED_WAV"
echo "Running VAD Waveform Analysis on CEO Speech..."
python3 "$ROOT_DIR/scripts/vad_analyzer.py" "$COMBINED_WAV"
