---
description: Spaced-repetition quiz on vocabulary from all Markdown reading files
---

## Check for an existing session

```bash
node .claude/scripts/read-quiz-session.mjs
```

- **Exit code 1 / "No active quiz session"** → no prior session, proceed to Step 0.
- **Session found** → silently resume. Skip to Step 3, using quiz history to infer which words were already recorded.

---

## Step 0 — Quiz style preference

Check `MEMORY.md` for a `quiz_style` entry:
- **Found**: note it silently and apply it in Steps 2–3.
- **Not found**: ask the user — "Do you prefer **varied** practice (tend toward seeing each word/facet once per session, avoiding repetition) or **intensive drill** (revisit difficult items within the same session)?" Save the answer to `MEMORY.md` as `quiz_style: varied` or `quiz_style: intensive`.

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

Also check `MEMORY.md` for `corpus_level` (e.g. "N3") and `corpus_word_count`:
- If absent, or if the current word count has grown more than ~20% since the last estimate: use your JLPT knowledge to estimate the learner's level from the vocabulary in the corpus, and save `corpus_level` and `corpus_word_count` to `MEMORY.md`. This estimate is used for calibrating distractor selection in Step 3 and should be revisited as the corpus grows.

---

## Step 2 — Select words and write session

Pick 5–10 words to quiz. Use both the review metadata *and* your semantic understanding:
- Prioritise never-reviewed words, then words with long gaps or low average scores.
- For words with per-facet data, prioritise facets with low scores or no reviews.
- Prefer a mix of word types (verbs, nouns, adverbs) and difficulty levels.
- Notice semantic relationships — words that sound alike or share kanji can make good distractor pairs later.

Apply the quiz style from memory:
- **Varied** (default): give preference to facets not recently reviewed for a given word — avoid repetition where possible, but use judgment rather than hard rules.
- **Intensive**: feel free to revisit recently-tested facets, prioritising low-scoring ones.

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

For words without `{kanji}`, only ask **meaning** questions. Display both the kanji and kana forms together (e.g. **分厚い (ぶあつい)**) for passive kanji exposure, but the answer expected is the English meaning.

**Question format — free answer vs. multiple choice:**
- **Free answer** (default for well-reviewed words): simply ask "What does X mean?" or "What is the reading of X?" and wait for a typed response. This is harder and better tests genuine recall.
- **Multiple choice** (default for words with no or few reviews): provide exactly 4 options (A–D) to keep engagement high while the word is still new.
- Use judgment: a word reviewed 3+ times with good scores warrants free answer; a word seen once or never warrants MC. The threshold is a soft guideline, not a rule.

If the user asks for multiple choice after a free-answer question was posed, provide options — but note in the record that hints were given and reduce the score modestly (e.g. cap at 0.7 for an otherwise correct answer).

**When using multiple choice**, choose distractors that make the question genuinely challenging, as if the learner encountered the word in real reading with no limited candidate pool:
- **Preferred source**: other words from the full corpus inventory (seen in Step 1) that are semantically adjacent — same domain, overlapping kanji, similar sounds or conjugation patterns.
- **Also use**: your general knowledge of Japanese vocabulary at the learner's estimated level (from `corpus_level` in memory) — especially forms or meanings that could plausibly be confused.
- **Avoid** defaulting to other session words as distractors. The session is a small pool; reusing it creates an elimination-game effect where later questions become easier as options narrow.

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

**Notes format:** Write a short, self-contained sentence that captures *what* the user knew or didn't know — never reference answer letters (A/B/C/D). For multiple-choice, always spell out what was chosen.

- Good: `"Gave correct reading どなる"`
- Good: `"Chose 怒鳴る (correct); user noted they confused it with 怒る"`
- Good: `"Could not produce kanji form; guessed 怒鳴 (wrong); correct is 怒鳴る"`
- Bad: `"guessed A"` — letter A means nothing without the question context
- Bad: `"answered quickly"` or `"hesitated"` — Claude cannot observe message timing in this interface (though a future REST API with keystroke/submission timestamps could enable this)

Only record what is directly observable: the answer given, whether it was correct, and any confusion the user explicitly mentioned.

3. Ask the next question (go back to Step 3).

---

## Step 5 — Finish

After the last answer is graded and recorded:

```bash
node .claude/scripts/clear-quiz-session.mjs
```

Give a brief summary: words quizzed, overall score, any patterns worth noting (e.g. "you consistently mixed up the readings for 市場 and 舞う").
