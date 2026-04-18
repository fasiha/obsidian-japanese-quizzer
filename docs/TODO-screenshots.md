# Screenshot Tour for README.md

## What story are we telling?

The README's central claim: **AI made previously-impossible features practical.**

Before AI, a serious quiz app was conceivable but no app ever shipped:
- Drilling transitive-intransitive verb pairs (the data may have existed (SLJFAQ's table of pairs) but too niche to build by hand)
- Drilling number + counter rendaku (fun vs. bun, yon-hiki vs. shi-hiki, hatsuka) — pure tutor knowledge
- Generating a fresh sentence for every quiz question, tuned to your level
- Letting you ask mid-session "wait, why is it yon and not shi here?" and getting a real answer

The *hero moment* is the post-quiz clarification exchange: the app generates a novel sentence,
asks a question, you answer, and then you can ask the AI to explain the grammar or a vocab nuance
right there in context. That's a human tutor, not a flashcard deck.

The two heroes:
1. **Post-quiz clarification** — shows the AI-tutor moment (fresh sentence + follow-up Q&A)
2. **Reader with annotations** — shows the corpus-first philosophy (real literary text drives everything)

The dashboard is beautiful but secondary — it's "we have depth" not "we're different."

---

## How to navigate the simulator

```sh
# One-time requirements
brew tap facebook/fb
brew install idb-companion
python -m pip install fb-idb

# Find the booted simulator UDID
xcrun simctl list devices booted

# Take a screenshot
xcrun simctl io <udid> screenshot /tmp/sim-NAME.png

# Tap at screen coordinates
idb ui tap --udid <udid> <x> <y>

# Inspect the full accessibility tree (to find element coordinates by name)
idb ui describe-all --udid <udid> --nested --json

# Type text into the focused field
idb ui text --udid <udid> "your text here"
```

The workflow is: screenshot → read image → decide where to tap → tap → screenshot → repeat.
Claude Code can read PNG files directly (multimodal), so the full loop runs in-conversation.

---

## Hero 1: Post-quiz clarification exchange

The goal is one screenshot (or composite) showing: AI-generated sentence → question → answer → 
user asks for clarification → AI explains inline.

### Scripting challenge

The grammar quiz generates questions via Haiku, so we can't guarantee what sentence it produces.
But we can maximize control:

1. **Reset quiz state**: run `reset-sim-quiz.sh` to wipe `quiz.sqlite`
2. **Enroll exactly one grammar topic**: write a single row directly into `grammar_enrollment`
   in the simulator's `quiz.sqlite` (path found via `find ~/Library/Developer/CoreSimulator/Devices/<udid> -name quiz.sqlite`):
   ```sql
   INSERT INTO grammar_enrollment VALUES ('genki:transitive-pairs', 'learning', '2026-04-18T00:00:00Z');
   ```
3. **Launch the grammar quiz**: navigate to Grammar tab → tap the quiz button
4. With only one enrolled topic, the quiz will always ask about transitive pairs
5. Haiku still generates the sentence freely — run the quiz a few times (re-reset between runs)
   until the generated sentence is natural and clear, then capture that run

**Post-answer clarification**: after answering, type a follow-up question like
「なぜ「乗せる」じゃなくて「乗る」ですか？」or in English "why does this use 乗る and not 乗せる?"
and screenshot the AI's response alongside the question.

- [ ] Run `reset-sim-quiz.sh`
- [ ] Enroll `genki:transitive-pairs` only in `quiz.sqlite`
- [ ] Navigate to Grammar tab → start quiz
- [ ] Screenshot: AI-generated sentence + multiple-choice options
- [ ] Submit answer
- [ ] Screenshot: post-answer feedback from AI
- [ ] Type a clarification question
- [ ] Screenshot: AI's explanation (this is the hero frame)
- [ ] Decide: single best frame, or vertical composite of the exchange

---

## Hero 2: Reader with annotations

A single screenshot showing real literary text with furigana + vocab chip + grammar chip visible.
If a song is open, the audio play button on a line makes it even more distinctive.

- [ ] Navigate to Reader tab → open a document (prefer a song with audio if available)
- [ ] Expand or scroll to a line that has both a vocab annotation and a grammar annotation
- [ ] Screenshot: annotated line with chips visible (and audio button if present)

---

## Supporting screenshots (lower priority)

- [ ] Dashboard racetrack gauges — shows depth of progress tracking
- [ ] Verb pair detail sheet — both verbs, example sentences, definitions
- [ ] Grammar browser equivalence group — Genki + Bunpro + DBJG + Kanshudo siblings
- [ ] Word detail sheet — per-sense enrollment + furigana form picker

---

## Notes
- Final images → `Pug/Screenshots/`, linked from README.md
- Device: iPhone Air (`B12635A1-838D-4C8D-A915-8EB7EC146C90`) as of 2026-04-18
  — re-check UDID each session with `xcrun simctl list devices booted`
- `quiz.sqlite` lives at:
  `~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/Data/Application/<app-uuid>/Documents/quiz.sqlite`
  Find it with: `find ~/Library/Developer/CoreSimulator/Devices/<udid> -name quiz.sqlite`
