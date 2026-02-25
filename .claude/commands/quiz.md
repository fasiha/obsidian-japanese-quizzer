---
description: Spaced-repetition quiz on vocabulary from all Markdown reading files
---

## Check for an existing session

```bash
node .claude/scripts/read-quiz-session.mjs
```

- **Exit code 1 / "No active quiz session"** → no prior session, proceed to Step 1.
- **Session found** → tell the user only the session metadata (start timestamp and word count), and ask: resume or start fresh? Do **not** reveal which words are planned.
  - Resume: skip to Step 3, using quiz history to infer which words were already recorded.
  - Fresh: run `node .claude/scripts/clear-quiz-session.mjs`, then proceed to Step 1.

---

## Step 1 — Load quiz context

```bash
node .claude/scripts/get-quiz-context.mjs
```

This outputs one compact line per quizzable vocab item:

```
<jmdictId>  <forms> <meanings> (#<id>) [<review status>]
```

Words committed to kanji-recognition study have a `{kanji}` marker:

```
1445740  怒鳴る, どなる to shout in anger (#1445740) {kanji} [never reviewed]
```

When per-facet quiz_type data exists, review status shows per-facet breakdown:

```
1445740  怒鳴る, どなる ... {kanji} [meaning:1d/0.50×1, reading:never, kanji:never]
```

Read all lines. You now have the full vocab inventory with semantic content and review history in a compact form.

---

## Step 2 — Select words and write session

Pick 5–10 words to quiz. Use both the review metadata *and* your semantic understanding:
- Prioritise never-reviewed words, then words with long gaps or low average scores.
- For words with per-facet data, prioritise facets with low scores or no reviews.
- Prefer a mix of word types (verbs, nouns, adverbs) and difficulty levels.
- Notice semantic relationships — words that sound alike or share kanji make good distractor pairs.

Write the session plan (pass IDs as positional args in quiz order):

```bash
node .claude/scripts/write-quiz-session.mjs <id1> <id2> <id3> ...
```

---

## Step 3 — Quiz one word at a time

For each word in the session, send **one question per message**. Show progress (e.g. **Question 2 / 7**).

Choose the question type based on which facet most needs practice:
- **reading** — show kanji → ask for the reading (kana). Record with `--quiz-type reading`.
- **meaning** — show kanji + reading (or kana alone) → ask for English meaning. Record with `--quiz-type meaning`.
- **kanji** — show English meaning or reading → ask which kanji/kana form is correct. Record with `--quiz-type kanji`. Only ask this type for words marked `{kanji}`.

For words without `{kanji}`, vary between `reading` and `meaning` questions only.

For multiple-choice, provide exactly 4 options (A–D). Choose distractors from the other words in the session (you have all their summaries from Step 1) or from your own Japanese knowledge. Make distractors plausible, not obviously wrong.

**Handling pauses:** If the user asks for a mnemonic, etymology, radical breakdown, clarification, or any other discussion mid-question, engage with it fully. For kanji breakdowns, call:

```bash
node .claude/scripts/get-kanji-info.mjs <kanji1> <kanji2> ...
```

This outputs each kanji's radicals (from kradfile), on/kun readings, English meanings, stroke count, JLPT level, and school grade. Use this data to suggest concrete mnemonics. After any discussion, **re-ask the exact same question** before moving on. Only advance to Step 4 after the user has actually answered.

Wait for the user's answer before continuing.

---

## Step 4 — Grade, record, repeat

After each answer:

1. Grade it (0.0–1.0). Briefly explain what was right or wrong.
2. Record it immediately, including the facet tested:

```bash
node .claude/scripts/record-review.mjs \
  --word-id WORD_ID \
  --word-text "WORD_TEXT" \
  --score SCORE \
  --quiz-type QUIZ_TYPE \
  --notes "NOTES"
```

Where `QUIZ_TYPE` is `reading`, `meaning`, or `kanji` depending on what was asked.
The `--reviewer` flag defaults to the OS username. Pass it explicitly if needed (e.g. `--reviewer roommate`).

3. Ask the next question (go back to Step 3).

---

## Step 5 — Finish

After the last answer is graded and recorded:

```bash
node .claude/scripts/clear-quiz-session.mjs
```

Give a brief summary: words quizzed, overall score, any patterns worth noting (e.g. "you consistently mixed up the readings for 市場 and 舞う").
