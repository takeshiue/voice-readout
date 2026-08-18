#!/usr/bin/env python3
"""Generate 30 filler WAV audio clips using Inworld API."""

import base64
import json
import os
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


def load_inworld_key() -> str:
    env_file = Path("/root/.claude/plugins/data/voice-readout-voice-readout/voice-readout.env")
    if env_file.exists():
        with open(env_file, "r") as f:
            for line in f:
                if line.startswith("INWORLD_API_KEY="):
                    return line.strip().split("=", 1)[1]
    return os.environ.get("INWORLD_API_KEY", "")


def generate_clip(text: str, api_key: str, out_file: Path):
    url = "https://api.inworld.ai/tts/v1/voice"
    payload = {
        "text": text,
        "model": "inworld-tts-1.5-max",
        "voice_id": "male-1",  # natural voice
        "audio_config": {
            "audio_encoding": "LINEAR16",
            "sample_rate_hertz": 24000,
            "speaking_rate": 1.3,
        },
    }

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Basic {api_key}",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        audio_b64 = data.get("audio_content", "")
        if audio_b64:
            audio_bytes = base64.b64decode(audio_b64)
            with open(out_file, "wb") as f:
                f.write(audio_bytes)
            return True
    return False


def main():
    api_key = load_inworld_key()
    if not api_key:
        print("Error: INWORLD_API_KEY not found", file=sys.stderr)
        sys.exit(1)

    out_dir = Path("/root/dev/voice-readout/assets/fillers")
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Generating {len(FILLERS)} high-quality filler WAV clips into {out_dir}...")

    success_count = 0
    for filename, text in FILLERS:
        target_path = out_dir / filename
        print(f"Generating [{filename}]: '{text}' ...", end=" ", flush=True)
        try:
            if generate_clip(text, api_key, target_path):
                print(f"OK ({target_path.stat().st_size} bytes)")
                success_count += 1
            else:
                print("Failed (no audio)")
        except Exception as e:
            print(f"Error: {e}")

    print(f"\nDone! Generated {success_count}/{len(FILLERS)} filler clips.")


if __name__ == "__main__":
    main()
