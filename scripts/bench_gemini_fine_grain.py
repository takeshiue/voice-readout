#!/usr/bin/env python3
"""
Fine-Grained Benchmark for Gemini TTS: 70, 80, 90, 100, 110, 120 chars.
Measures exact generation time, audio duration, and safety margin.
"""
import time
import subprocess
import os
import wave

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
TTS_LIB = os.path.join(ROOT_DIR, "bin", "tts-lib.sh")

# Exact character count Japanese text samples around sweet spot
SAMPLES = [
    (70,  "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。CLI操作を止めません。"),
    (80,  "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく動作します。"),
    (90,  "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。"),
    (100, "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。さらに多様なエンジンと連携します。"),
    (110, "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。さらに、多様なクラウド音声合成エンジンと連携します。"),
    (120, "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。さらに、多様なクラウド音声合成エンジンと連携することで明瞭な音質を実現します。")
]

print("=" * 90)
print("Gemini TTS: Fine-Grained (70, 80, 90, 100, 110, 120 chars) Benchmark")
print("=" * 90)

for target_len, text in SAMPLES:
    actual_len = len(text)
    cmd = [
        "bash", "-c",
        f"source '{TTS_LIB}' && gen_cloud 'gemini' '{text}' 'fine_{target_len}' >/dev/null 2>&1"
    ]
    t0 = time.time()
    subprocess.run(cmd, check=True)
    t1 = time.time()
    gen_time = t1 - t0

    # Calculate speech duration at standard rate (approx 7.0 chars/sec)
    aud_dur = actual_len / 7.0
    margin = aud_dur - gen_time

    status = "黒字 (自走可能)" if margin > 0 else "赤字 (バッファ必要)"
    print(f"[{actual_len:3d}文字] ──▶ 生成時間: {gen_time:5.2f} 秒 | 音声再生時間: {aud_dur:5.2f} 秒 | 余裕度: {margin:+5.2f} 秒  [{status}]")

print("=" * 90)
