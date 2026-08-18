#!/usr/bin/env python3
"""agy_readout.py - Antigravity CLI (agy) transcript extractor & text normalizer.

Part of the Voice Readout system. Designed for cross-platform execution (Android/Termux,
Linux, macOS, and Windows).
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Optional


def clean_for_speech(text: str) -> str:
    """Strip code blocks, URLs, markdown formatting, and extra whitespace for TTS."""
    if not text:
        return ""

    # 1. Remove fenced code blocks (```...```)
    text = re.sub(r"```[\s\S]*?```", " ", text)

    # 2. Remove inline code (`...`)
    text = re.sub(r"`[^`\n]+`", " ", text)

    # 3. Replace markdown links [text](url) with just text, and remove standalone URLs
    text = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", text)
    text = re.sub(r"https?://\S+", " ", text)

    # 4. Remove HTML tags
    text = re.sub(r"<[^>]+>", " ", text)

    # 5. Remove markdown headers, list markers, blockquotes, horizontal rules
    text = re.sub(r"^[ \t]*[#]+[ \t]+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^[ \t]*[-*+][ \t]+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^[ \t]*\d+\.[ \t]+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^[ \t]*>[ \t]*", "", text, flags=re.MULTILINE)
    text = re.sub(r"^[ \t]*[-*_]{3,}[ \t]*$", "", text, flags=re.MULTILINE)

    # 6. Remove bold / italic / strikethrough markdown markers
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"\*([^*]+)\*", r"\1", text)
    text = re.sub(r"__([^_]+)__", r"\1", text)
    text = re.sub(r"_([^_]+)_", r"\1", text)
    text = re.sub(r"~~([^~]+)~~", r"\1", text)

    # 7. Normalize whitespace
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n", text)
    text = text.strip()

    return text


def excerpt_for_speech(text: str, max_chars: int = 160) -> str:
    """Produce a concise excerpt for summary-mode speech."""
    if not text or len(text) <= max_chars:
        return text

    # Try sentence boundary truncation near max_chars
    truncated = text[:max_chars]
    for punct in ("。", "．", "\n", "！", "？", "!", "?", ". "):
        idx = truncated.rfind(punct)
        if idx >= max_chars // 2:
            return truncated[: idx + (0 if punct == "\n" else len(punct))].strip()

    # Fallback to character truncation with ellipsis
    return truncated.rstrip() + "、以下略。"


def extract_last_message_from_transcript(transcript_path: Path) -> Optional[str]:
    """Scan transcript.jsonl (or transcript_full.jsonl) in reverse to find the latest assistant message."""
    if not transcript_path.is_file():
        return None

    try:
        # Read lines in reverse for fast lookup
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()

        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue

            # Check if this is an assistant response step
            step_type = entry.get("type")
            source = entry.get("source")
            content = entry.get("content")

            if source == "MODEL" and step_type == "PLANNER_RESPONSE" and content:
                # If content is a non-empty string, we found our response
                if isinstance(content, str) and content.strip():
                    return content.strip()

            # Some versions log final text under content directly when DONE
            if step_type == "PLANNER_RESPONSE" and isinstance(content, str) and content.strip():
                return content.strip()

    except Exception as e:
        sys.stderr.write(f"Error reading transcript {transcript_path}: {e}\n")

    return None


def extract_last_message_from_hook_payload(payload_str: str) -> Optional[str]:
    """Extract last message from agy hook JSON payload received on stdin."""
    if not payload_str.strip():
        return None

    try:
        payload = json.loads(payload_str)
    except Exception as e:
        sys.stderr.write(f"Failed to parse hook payload JSON: {e}\n")
        return None

    # 1. Direct last_assistant_message if present (Claude/Codex compatibility)
    if "last_assistant_message" in payload and payload["last_assistant_message"]:
        return str(payload["last_assistant_message"])

    # 2. Extract from transcriptPath (Antigravity agy standard)
    transcript_path_str = payload.get("transcriptPath")
    if transcript_path_str:
        tpath = Path(transcript_path_str)
        # If truncated transcript exists, check it first; otherwise check full
        msg = extract_last_message_from_transcript(tpath)
        if msg:
            return msg

        # Fallback to full transcript in same directory if truncated didn't have content
        full_tpath = tpath.parent / "transcript_full.jsonl"
        if full_tpath.exists() and full_tpath != tpath:
            msg = extract_last_message_from_transcript(full_tpath)
            if msg:
                return msg

    return None


def pick_random_filler(fillers_dir: Path, history_file: Optional[Path] = None) -> Optional[Path]:
    """Pick a random filler WAV file, excluding recently played ones."""
    if not fillers_dir.is_dir():
        return None

    all_fillers = sorted(list(fillers_dir.glob("*.wav")))
    if not all_fillers:
        return None

    recent: list[str] = []
    if history_file and history_file.is_file():
        try:
            with open(history_file, "r", encoding="utf-8") as f:
                recent = [line.strip() for line in f if line.strip()]
        except Exception:
            pass

    # Exclude recent files (keep pool fresh)
    pool = [p for p in all_fillers if p.name not in recent[-5:]]
    if not pool:
        pool = all_fillers

    import random
    chosen = random.choice(pool)

    if history_file:
        try:
            recent.append(chosen.name)
            history_file.parent.mkdir(parents=True, exist_ok=True)
            with open(history_file, "w", encoding="utf-8") as f:
                f.write("\n".join(recent[-10:]) + "\n")
        except Exception:
            pass

    return chosen


def main():
    parser = argparse.ArgumentParser(description="Antigravity Voice Readout Processor")
    subparsers = parser.add_subparsers(dest="command")

    # Command: parse-hook
    p_parse = subparsers.add_parser("parse-hook", help="Parse hook payload JSON and output cleaned speech text")
    p_parse.add_argument("--mode", choices=["full", "summary"], default="summary", help="Readout mode")
    p_parse.add_argument("--max-chars", type=int, default=160, help="Max characters for summary mode")
    p_parse.add_argument("--file", type=str, help="Path to input JSON file (reads stdin if omitted)")

    # Command: clean-text
    p_clean = subparsers.add_parser("clean-text", help="Clean raw text for TTS")
    p_clean.add_argument("--mode", choices=["full", "summary"], default="summary")
    p_clean.add_argument("--max-chars", type=int, default=160)
    p_clean.add_argument("--file", type=str, help="Path to input text file (reads stdin if omitted)")

    # Command: pick-filler
    p_filler = subparsers.add_parser("pick-filler", help="Pick a random filler audio clip path")
    p_filler.add_argument("--dir", type=str, default="/root/dev/voice-readout/assets/fillers")
    p_filler.add_argument("--history", type=str, default="/root/.claude/plugins/data/voice-readout-voice-readout/recent-fillers.txt")

    args = parser.parse_args()

    if args.command == "pick-filler":
        chosen = pick_random_filler(Path(args.dir), Path(args.history) if args.history else None)
        if chosen:
            print(str(chosen))
        else:
            sys.exit(1)

    elif args.command == "parse-hook":
        if args.file:
            with open(args.file, "r", encoding="utf-8", errors="replace") as f:
                payload_str = f.read()
        else:
            payload_str = sys.stdin.read()

        raw_msg = extract_last_message_from_hook_payload(payload_str)
        if not raw_msg:
            sys.exit(1)

        cleaned = clean_for_speech(raw_msg)
        if not cleaned:
            sys.exit(2)  # Code only or stripped to empty

        if args.mode == "full":
            print(cleaned)
        else:
            print(excerpt_for_speech(cleaned, max_chars=args.max_chars))

    elif args.command == "clean-text":
        if args.file:
            with open(args.file, "r", encoding="utf-8", errors="replace") as f:
                raw_text = f.read()
        else:
            raw_text = sys.stdin.read()

        cleaned = clean_for_speech(raw_text)
        if not cleaned:
            sys.exit(2)

        if args.mode == "full":
            print(cleaned)
        else:
            print(excerpt_for_speech(cleaned, max_chars=args.max_chars))
    else:
        parser.print_help()


if __name__ == "__main__":
    main()

