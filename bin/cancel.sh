#!/bin/bash
# Manually cancel all active speech readouts, generation workers, and queue backlog.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/tts-lib.sh"

cancel_active_readouts
echo "voice-readout: 音声読み上げを停止・キャンセルしました。"
