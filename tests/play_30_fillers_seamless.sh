#!/bin/bash
# Concatenate all 30 filler clips with minimal 0.3s gap into a single audio file and play seamlessly
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

FILLERS_DIR="$ROOT_DIR/assets/fillers"
TMP_DIR="/tmp/concat_fillers"
mkdir -p "$TMP_DIR"
rm -f "$TMP_DIR"/*

# Create a 0.3s silence WAV
ffmpeg -y -f lavfi -i "anullsrc=r=24000:cl=mono" -t 0.35 -ar 24000 -ac 1 "$TMP_DIR/silence.wav" >/dev/null 2>&1

# Build concat list
CONCAT_TXT="$TMP_DIR/concat.txt"
rm -f "$CONCAT_TXT"

for idx in $(seq -w 1 30); do
  f="filler_${idx}.wav"
  if [ -f "$FILLERS_DIR/$f" ]; then
    echo "file '$FILLERS_DIR/$f'" >> "$CONCAT_TXT"
    echo "file '$TMP_DIR/silence.wav'" >> "$CONCAT_TXT"
  fi
done

OUT_COMBINED="$ROOT_DIR/assets/all_fillers_continuous.wav"
ffmpeg -y -f concat -safe 0 -i "$CONCAT_TXT" -c copy "$OUT_COMBINED" >/dev/null 2>&1

echo "Generated continuous combined audio ($OUT_COMBINED)."
echo "Playing all 30 fillers seamlessly with 0.3s gap..."

play_notice_clip "$OUT_COMBINED" nowait
