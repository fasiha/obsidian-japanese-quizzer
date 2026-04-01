# Music: Lyrics + Timestamps + Vocabulary

This directory contains a pipeline for annotating song lyrics with vocabulary and aligning them to audio timestamps.

## Setup

Install Python. Then install [Stable Whisper](https://github.com/jianfch/stable-ts) for timestamp alignment:

```bash
python -m pip install stable-ts
```

See the [Stable Whisper setup guide](https://github.com/jianfch/stable-ts?tab=readme-ov-file#setup) for additional dependencies (ffmpeg, etc.) and optional HuggingFace token setup if using gated models.

Optionally, install [Aegisub](https://aegisub.org) for manual timestamp refinement (Stable Whisper is good but not perfect).

## Pipeline

### 1. Start with lyrics

Create a Markdown file with song lyrics (ideally with `<ruby>` tags for kanji):

```markdown
---
llm-review: true
---

<ruby>目覚<rt>めざ</rt></ruby>めては<ruby>繰<rt>く</rt></ruby>り<ruby>返<rt>かえ</rt></ruby>す
```

### 2. Annotate vocabulary with `/annotate-file`

Run the `annotate-file` skill to add JMDict vocabulary for N5-level learners:

```bash
/annotate-file Music/song-lyrics.md
```

This produces `song-lyrics.annotated.md` with `<details>` blocks containing vocabulary for each lyric line. Review the annotations to ensure you understand the lyrics and still enjoy them.

### 3. Transcribe and time-align with Stable Whisper

**Extract plain lyrics** (no ruby/details tags) to a text file:

```bash
grep -v '<' song-lyrics.md | grep -v '^---' | grep -v '^$' > plain.txt
```

and review `plain.txt` to ensure it just contains lines you expect in the audio.

**Align the audio** using `generate.py`:

```bash
# Japanese with the default large-v2 model
python generate.py plain.txt song.m4a

# Or use a better Japanese model
python generate.py plain.txt song.m4a --model kotoba-tech/kotoba-whisper-v2.2

# Custom output file or English
python generate.py plain.txt song.m4a --output timestamps.srt --language en
```

This generates `song.srt` (or specified output) with line-level timestamps. Stable Whisper is good but not perfect — adjust start/end times in [Aegisub](https://aegisub.org) as needed.

### 4. Inject timestamps into annotated lyrics

Use `inject-timestamps.mjs` to merge the SRT timestamps with the annotated Markdown. The script:
- Iterates through SRT entries in order
- Searches forward through Markdown for matching lyric lines
- Strips `<ruby>` tags when matching (preserves them in output)
- Skips `<details>` blocks and other non-lyric content
- Injects `<audio>` tags with precise start/end times

```bash
node inject-timestamps.mjs output.srt "My Soul, Your Beats.annotated.md" song.m4a > result.md
```

The output preserves all vocab annotations and ruby tags while adding audio playback controls.

## Scripts

### `generate.py`

Aligns song lyrics to audio using Stable Whisper.

```bash
python generate.py LYRICS AUDIO [--output OUTPUT.srt] [--model MODEL] [--language LANG] [--word-level]
```

**Options:**
- `--model` (default: `large-v2`) — Whisper model. Try `kotoba-tech/kotoba-whisper-v2.2` for better Japanese.
- `--language` (default: `ja`) — Language code.
- `--word-level` — Output word-level timings instead of line-level.

### `inject-timestamps.mjs`

Merges SRT timestamps with annotated Markdown.

```bash
node inject-timestamps.mjs FILE.srt LYRICS.md [audio-filename]
```

Outputs the Markdown to stdout with `<audio>` tags injected. The audio filename is used verbatim in the `data-src` attribute (relative to the Markdown file's directory); it defaults to the SRT filename with `.mp3` extension.
