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

Read all lines. You now have the full vocab inventory with semantic content and review history in a compact form.

---

## Step 2 — Select words and write session

Pick 5–10 words to quiz. Use both the review metadata *and* your semantic understanding:
- Prioritise never-reviewed words, then words with long gaps or low average scores.
- Prefer a mix of word types (verbs, nouns, adverbs) and difficulty levels.
- Notice semantic relationships — words that sound alike or share kanji make good distractor pairs.

Write the session plan (pass IDs as positional args in quiz order):

```bash
node .claude/scripts/write-quiz-session.mjs <id1> <id2> <id3> ...
```

---

## Step 3 — Quiz one word at a time

For each word in the session, send **one question per message**. Show progress (e.g. **Question 2 / 7**).

Vary the question type each turn to keep it interesting:
- Show kanji → ask for the reading (kana)
- Show kanji + reading → ask for the English meaning
- Show English meaning → ask which kanji/kana form is correct

For multiple-choice, provide exactly 4 options (A–D). Choose distractors from the other words in the session (you have all their summaries from Step 1) or from your own Japanese knowledge. Make distractors plausible, not obviously wrong.

Wait for the user's answer before continuing.

---

## Step 4 — Grade, record, repeat

After each answer:

1. Grade it (0.0–1.0). Briefly explain what was right or wrong.
2. Record it immediately:

```bash
node .claude/scripts/record-review.mjs \
  --word-id WORD_ID \
  --word-text "WORD_TEXT" \
  --score SCORE \
  --notes "NOTES"
```

The `--reviewer` flag defaults to the OS username. Pass it explicitly if needed (e.g. `--reviewer roommate`).

3. Ask the next question (go back to Step 3).

---

## Step 5 — Finish

After the last answer is graded and recorded:

```bash
node .claude/scripts/clear-quiz-session.mjs
```

Give a brief summary: words quizzed, overall score, any patterns worth noting (e.g. "you consistently mixed up the readings for 市場 and 舞う").
