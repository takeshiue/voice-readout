#!/bin/bash
# Test story pipeline, record full output, and analyze gaps/silence between chunks
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

RECORD_DIR="/tmp/test_story_vad"
mkdir -p "$RECORD_DIR"
rm -f "$RECORD_DIR"/*

SAMPLE_TEXT="案内されたのは、路地裏に佇む落ち着いたグリルダイニングだった。相良さん、どんな食事がいいですか？と尋ねた俺に、涼香は目を輝かせて、高タンパクで最高の赤身肉が食べられるお店があるんですと胸を張ったのだ。運ばれてきた分厚い牛赤身肉のローストを前に、彼女は無邪気に微笑む。ここのお肉、脂質が少なくてアミノ酸スコアも抜群なんです。相良さん、最近お仕事でお忙しそうだったから、筋肉の疲労回復に絶対いいと思って。"

echo "=== 1. Splitting text into speech units/chunks ==="
export VOICE_READOUT_TTS_BACKEND=gemini
export VOICE_READOUT_GEMINI_MODEL=gemini-2.5-flash-preview-tts

# Test split logic
python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, '$ROOT_DIR/bin')
import agy_readout

text = '''$SAMPLE_TEXT'''
print('Length:', len(text), 'chars')
"

# Generate cloud chunks directly using pipeline logic to inspect each chunk
echo "=== 2. Generating Gemini Chunks ==="
CHUNK1="案内されたのは、路地裏に佇む落ち着いたグリルダイニングだった。相良さん、どんな食事がいいですか？と尋ねた俺に、涼香は目を輝かせて、高タンパクで最高の赤身肉が食べられるお店があるんですと胸を張ったのだ。"
CHUNK2="運ばれてきた分厚い牛赤身肉のローストを前に、彼女は無邪気に微笑む。ここのお肉、脂質が少なくてアミノ酸スコアも抜群なんです。相良さん、最近お仕事でお忙しそうだったから、筋肉の疲労回復に絶対いいと思って。"

gen_gemini "$CHUNK1" "$RECORD_DIR/chunk_0.wav"
gen_gemini "$CHUNK2" "$RECORD_DIR/chunk_1.wav"

echo "=== 3. Measuring Duration and Silence at Boundaries ==="
python3 -c "
import subprocess, json

def get_silence(wav_path):
    cmd = [
        'ffmpeg', '-i', str(wav_path), '-af',
        'silencedetect=noise=-30dB:d=0.2', '-f', 'null', '-'
    ]
    p = subprocess.run(cmd, stderr=subprocess.PIPE, universal_newlines=True)
    return p.stderr

def get_duration(wav_path):
    cmd = ['ffprobe', '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'json', str(wav_path)]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, universal_newlines=True)
    return float(json.loads(p.stdout)['format']['duration'])

d0 = get_duration('$RECORD_DIR/chunk_0.wav')
d1 = get_duration('$RECORD_DIR/chunk_1.wav')
print(f'Chunk 0 duration: {d0:.2f}s ({len(\"\"\"$CHUNK1\"\"\")} chars)')
print(f'Chunk 1 duration: {d1:.2f}s ({len(\"\"\"$CHUNK2\"\"\")} chars)')

# Inspect trailing silence of chunk 0
s0 = get_silence('$RECORD_DIR/chunk_0.wav')
print('Chunk 0 silence detection:\n', '\n'.join([line for line in s0.splitlines() if 'silence_' in line]))
"

echo "=== 4. Simulating Seamless Concatenation ==="
# Concatenate chunks with current lead timing
cat << EOF > "$RECORD_DIR/concat.txt"
file '$RECORD_DIR/chunk_0.wav'
file '$RECORD_DIR/chunk_1.wav'
EOF

ffmpeg -y -f concat -safe 0 -i "$RECORD_DIR/concat.txt" -c copy "$RECORD_DIR/full_output.wav" >/dev/null 2>&1
cp "$RECORD_DIR/full_output.wav" "/data/data/com.termux/files/home/storage/shared/Download/test_gemini_seamless.wav" 2>/dev/null || true

echo "Saved combined test audio to: /sdcard/Download/test_gemini_seamless.wav"
