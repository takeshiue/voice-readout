#!/usr/bin/env python3
"""
Benchmark Gemini TTS Generation Time vs Character Count.
Measures exact HTTP request + generation latency for different character lengths.
"""
import time
import subprocess
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
TTS_LIB = os.path.join(ROOT_DIR, "bin", "tts-lib.sh")

TEST_CASES = [
    ("30文字 (超軽量)", "本システムは、ログファイルを自動的に監視します。"),
    ("50文字 (軽量)", "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。"),
    ("80文字 (中規模)", "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく動作します。"),
    ("120文字 (標準)", "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく動作します。さらに、多様なクラウド音声合成エンジンと連携することで、極めて自然で明瞭なアナウンスを実現しています。"),
    ("180文字 (長文)", "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく動作します。さらに、多様なクラウド音声合成エンジンと連携することで、極めて自然で明瞭なアナウンスを実現しています。革新的なスケーリングと徹底したAIセーフティという異なる哲学が激突するこの覇権争いは歴史的な転換点です。")
]

print("=" * 75)
print("Gemini TTS: Character Count vs Generation Time Benchmark")
print("=" * 75)

results = []

for label, text in TEST_CASES:
    char_len = len(text)
    cmd = [
        "bash", "-c",
        f"source '{TTS_LIB}' && gen_cloud 'gemini' '{text}' 'bench_{char_len}' >/dev/null 2>&1"
    ]
    t0 = time.time()
    subprocess.run(cmd, check=True)
    t1 = time.time()
    elapsed = t1 - t0
    results.append((label, char_len, elapsed))
    print(f"[{label:12s}] ({char_len:3d}文字) ──▶ 生成時間: {elapsed:5.2f} 秒")

print("=" * 75)
