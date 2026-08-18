#!/bin/bash
# Record Complete Hybrid Pipeline to WAV and Run VAD Acoustic Waveform Analysis
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

RECORD_DIR="/tmp/vad_record"
mkdir -p "$RECORD_DIR"
rm -f "$RECORD_DIR"/*

echo "================================================================="
echo "Generating Audio Stream for VAD Waveform Analysis..."
echo "================================================================="

# 1. Filler Clip
FILLER_WAV="$ROOT_DIR/assets/fillers/filler_25.wav"
cp "$FILLER_WAV" "$RECORD_DIR/01_filler.wav"

# 2. Local Opening Audio (generate via termux-tts-speak / local TTS to WAV)
LOCAL_TEXT="人類史上最大の宇宙望遠鏡であるジェームズウェッブは、宇宙誕生から間もない初期銀河の姿を次々と捉えています。"
# Generate local opening wav
python3 -c "
import urllib.request, subprocess
url = 'https://translate.google.com/translate_tts?ie=UTF-8&q=' + urllib.parse.quote('''$LOCAL_TEXT''') + '&tl=ja&client=tw-ob'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(req) as resp, open('$RECORD_DIR/local.mp3', 'wb') as f:
    f.write(resp.read())
"
ffmpeg -y -i "$RECORD_DIR/local.mp3" -filter:a "atempo=1.31" -ar 24000 -ac 1 "$RECORD_DIR/02_local.wav" >/dev/null 2>&1

# 3. Gemini Cloud Chunks
CHUNK0_TEXT="従来のハッブル望遠鏡を遥かに凌ぐ赤外線観測能力により、ビッグバンからわずか数億年後に誕生したとされる最古の星々の光を鮮明に捉えることに成功しました。"
CHUNK1_TEXT="さらに、太陽系外惑星の大気成分の精密なスペクトル分析により、水蒸気や二酸化炭素の存在を検出するなど、生命居住可能惑星の探査においても歴史的なマイルストーンを刻み続けています。"
CHUNK2_TEXT="宇宙の暗黒時代を照らし出すこの壮大なプロジェクトは、私たちがどこから来たのかという根源的な問いに対する決定的な手がかりをもたらしつつあります。"

gen_cloud "gemini" "$CHUNK0_TEXT" "0" >/dev/null 2>&1
gen_cloud "gemini" "$CHUNK1_TEXT" "1" >/dev/null 2>&1
gen_cloud "gemini" "$CHUNK2_TEXT" "2" >/dev/null 2>&1

P0="$(_cloud_audio_path "gemini" 0)"
P1="$(_cloud_audio_path "gemini" 1)"
P2="$(_cloud_audio_path "gemini" 2)"

cp "$P0" "$RECORD_DIR/03_gemini_0.wav" 2>/dev/null || true
cp "$P1" "$RECORD_DIR/04_gemini_1.wav" 2>/dev/null || true
cp "$P2" "$RECORD_DIR/05_gemini_2.wav" 2>/dev/null || true

# Simulate current pipeline timing with measured process seams
# 0.5s pause after filler, 0.0s seam after local, 0.3s between Gemini chunks
ffmpeg -y -f lavfi -i "anullsrc=r=24000:cl=mono" -t 0.5 -ar 24000 -ac 1 "$RECORD_DIR/pause_05s.wav" >/dev/null 2>&1
ffmpeg -y -f lavfi -i "anullsrc=r=24000:cl=mono" -t 0.05 -ar 24000 -ac 1 "$RECORD_DIR/seam_local.wav" >/dev/null 2>&1
ffmpeg -y -f lavfi -i "anullsrc=r=24000:cl=mono" -t 0.3 -ar 24000 -ac 1 "$RECORD_DIR/pause_03s.wav" >/dev/null 2>&1

cat << EOF > "$RECORD_DIR/concat.txt"
file '$RECORD_DIR/01_filler.wav'
file '$RECORD_DIR/pause_05s.wav'
file '$RECORD_DIR/02_local.wav'
file '$RECORD_DIR/seam_local.wav'
file '$RECORD_DIR/03_gemini_0.wav'
file '$RECORD_DIR/pause_03s.wav'
file '$RECORD_DIR/04_gemini_1.wav'
file '$RECORD_DIR/pause_03s.wav'
file '$RECORD_DIR/05_gemini_2.wav'
EOF

COMBINED_WAV="$RECORD_DIR/full_pipeline_stream.wav"
ffmpeg -y -f concat -safe 0 -i "$RECORD_DIR/concat.txt" -ar 24000 -ac 1 "$COMBINED_WAV" >/dev/null 2>&1

echo "Combined Audio Generated: $COMBINED_WAV"
echo "Running Python VAD Acoustic Waveform Analysis..."
python3 "$ROOT_DIR/scripts/vad_analyzer.py" "$COMBINED_WAV"
