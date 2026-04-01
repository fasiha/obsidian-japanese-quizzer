#!/usr/bin/env python3
"""
Align song lyrics to audio timestamps using Stable Whisper.

Usage:
  python generate.py LYRICS AUDIO [--output OUTPUT.srt] [--model MODEL] [--language LANG] [--word-level]

Examples:
  python generate.py plain.txt song.m4a
  python generate.py plain.txt song.m4a --output timestamps.srt --model kotoba-tech/kotoba-whisper-v2.2
  python generate.py plain.txt song.m4a --language en --word-level
"""

import argparse
import sys
from pathlib import Path
import stable_whisper


def main():
    parser = argparse.ArgumentParser(
        description="Align song lyrics to audio timestamps using Stable Whisper.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    parser.add_argument(
        "lyrics",
        type=Path,
        help="Path to plain text file with one lyric line per line",
    )
    parser.add_argument(
        "audio",
        type=Path,
        help="Path to audio file (e.g., song.m4a, song.mp3)",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=None,
        help="Output SRT file (default: auto-generated from audio filename)",
    )
    parser.add_argument(
        "--model",
        "-m",
        default="large-v2",
        help='Stable Whisper model ID (default: large-v2). Use "kotoba-tech/kotoba-whisper-v2.2" for Japanese.',
    )
    parser.add_argument(
        "--language",
        "-l",
        default="ja",
        help="Language code (default: ja)",
    )
    parser.add_argument(
        "--word-level",
        action="store_true",
        help="Output word-level timings (default: line-level only)",
    )

    args = parser.parse_args()

    # Resolve paths
    lyrics_path = args.lyrics.resolve()
    audio_path = args.audio.resolve()

    if not lyrics_path.exists():
        print(f"Error: lyrics file not found: {lyrics_path}", file=sys.stderr)
        sys.exit(1)

    if not audio_path.exists():
        print(f"Error: audio file not found: {audio_path}", file=sys.stderr)
        sys.exit(1)

    # Default output path
    if args.output is None:
        output_path = audio_path.with_suffix(".srt")
    else:
        output_path = args.output.resolve()

    print(f"Loading model: {args.model}")
    model = stable_whisper.load_model(args.model)

    print(f"Reading lyrics: {lyrics_path}")
    lines = [l.strip() for l in lyrics_path.open() if l.strip()]
    print(f"  Found {len(lines)} lyric lines")

    print(f"Aligning to audio: {audio_path} (language: {args.language})")
    result = model.align(
        str(audio_path),
        "\n".join(lines),
        language=args.language,
        original_split=True,
    )

    print(f"Writing timestamps: {output_path}")
    result.to_srt_vtt(str(output_path), word_level=args.word_level)
    print("Done!")


if __name__ == "__main__":
    main()
