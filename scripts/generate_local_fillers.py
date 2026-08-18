#!/usr/bin/env python3
"""Generate 30 filler WAV clips using Google Text-to-Speech (Android standard local voice)."""

import os
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

FILLERS = [
    # A. お待たせしました／できました系 (8種)
    ("filler_01.wav", "お待たせしました"),
    ("filler_02.wav", "大変お待たせしました"),
    ("filler_03.wav", "お待たせっ"),
    ("filler_04.wav", "お待たせいたしました"),
    ("filler_05.wav", "お待たせ、できたよ"),
    ("filler_06.wav", "準備ができました"),
    ("filler_07.wav", "まとまりました"),
    ("filler_08.wav", "できましたよ"),
    # B. 思考・会話クッション系 (8種)
    ("filler_09.wav", "えっとですね…"),
    ("filler_10.wav", "ええと…"),
    ("filler_11.wav", "そうですね…"),
    ("filler_12.wav", "うーん、そうですね"),
    ("filler_13.wav", "ええ、そうですね"),
    ("filler_14.wav", "なるほどですね"),
    ("filler_15.wav", "はい、えーっと…"),
    ("filler_16.wav", "えっと、こちらはですね"),
    # C. それでは説明・お答えします系 (8種)
    ("filler_17.wav", "それではお答えします"),
    ("filler_18.wav", "お答えしますね"),
    ("filler_19.wav", "回答いたします"),
    ("filler_20.wav", "ご説明しますね"),
    ("filler_21.wav", "内容をお伝えします"),
    ("filler_22.wav", "お伝えしますね"),
    ("filler_23.wav", "結果をお話しします"),
    ("filler_24.wav", "はい、お答えします"),
    # D. 導入・読み上げ開始系 (6種)
    ("filler_25.wav", "では、読み上げます"),
    ("filler_26.wav", "それでは参ります"),
    ("filler_27.wav", "では、いきますね"),
    ("filler_28.wav", "結果はこちらです"),
    ("filler_29.wav", "回答はこちらです"),
    ("filler_30.wav", "内容はこちらです"),
]


def generate_local_voice_clip(text: str, target_path: Path):
    encoded_text = urllib.parse.quote(text)
    url = f"https://translate.google.com/translate_tts?ie=UTF-8&q={encoded_text}&tl=ja&client=tw-ob"

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Mobile Safari/537.36",
        },
    )

    tmp_mp3 = Path(f"/tmp/gtts_tmp_{os.getpid()}.mp3")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            with open(tmp_mp3, "wb") as f:
                f.write(resp.read())

        # Convert to 24kHz mono WAV, speeding up to crisp fast rate (1.55x)
        cmd = [
            "ffmpeg",
            "-y",
            "-i",
            str(tmp_mp3),
            "-filter:a",
            "atempo=1.55",
            "-ar",
            "24000",
            "-ac",
            "1",
            str(target_path),
        ]
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        return True
    finally:
        if tmp_mp3.exists():
            tmp_mp3.unlink()


def main():
    out_dir = Path("/root/dev/voice-readout/assets/fillers")
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Generating {len(FILLERS)} Local-Voice matching filler clips into {out_dir}...")

    success = 0
    for filename, text in FILLERS:
        target = out_dir / filename
        print(f"Generating [{filename}]: '{text}' ...", end=" ", flush=True)
        try:
            if generate_local_voice_clip(text, target):
                print(f"OK ({target.stat().st_size} bytes)")
                success += 1
            else:
                print("Failed")
        except Exception as e:
            print(f"Error: {e}")

    print(f"\nDone! Successfully regenerated {success}/{len(FILLERS)} local-voice filler clips.")


if __name__ == "__main__":
    main()
