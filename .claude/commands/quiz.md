---
description: Spaced-repetition quiz on vocabulary from all Markdown reading files
---

## Step 0 — Quiz style preference

Check `MEMORY.md` for a `quiz_style` entry:
- **Found**: note it silently and apply it in Steps 2–3.
- **Not found**: ask — "Do you prefer **varied** practice (each word/facet once per session) or **intensive drill** (revisit difficult items within the same session)?" Save to `MEMORY.md` as `quiz_style: varied` or `quiz_style: intensive`.

---

## Step 1 — Check for existing session / load context

```bash
node .claude/scripts/read-quiz-session.mjs
```

- **Exit code 0 (session found)**: its non-comment lines are the remaining word queue — skip to Step 3. The context file (`.claude/quiz-context.txt`) from the original session is still available for distractor selection.
- **Exit code 1 (no session)**: load the full quiz context:

```bash
node .claude/scripts/get-quiz-context.mjs
```

This writes `.claude/quiz-context.txt`. Each line:

```
<jmdictId>  <forms> <meanings> {kanji-ok|no-kanji} [<review status>]
```

- `{kanji-ok}` — all four types apply: `kanji-to-reading`, `reading-to-meaning`, `meaning-to-reading`, `meaning-reading-to-kanji`.
- `{no-kanji}` — only `reading-to-meaning` and `meaning-to-reading`; no kanji questions.

Also check `MEMORY.md` for `corpus_level` and `corpus_word_count`. If absent or word count has grown >20% since the last estimate, re-estimate from the vocabulary and save both to `MEMORY.md`.

---

## Step 2 — Select words and write session

*(Only reached when no session was found in Step 1.)*

Pick 5–10 words from the context using the review metadata and your semantic understanding:
- Prioritise never-reviewed words, then long gaps or low average scores.
- For words with per-facet data, prioritise facets with low scores or no reviews.
- Prefer a mix of word types and difficulty levels.
- Notice semantic relationships — words that share kanji or sound alike make good distractor pairs.

Apply `quiz_style`:
- **Varied**: prefer facets not recently reviewed; avoid repetition within the session.
- **Intensive**: freely revisit recently-tested facets, prioritising low-scoring ones.

Write the session (filters the context file for the chosen IDs):

```bash
node .claude/scripts/write-quiz-session.mjs <id1> <id2> ...
```

**Session opacity:** Once the session is written, transition immediately to Step 3 with no preamble. Do NOT narrate which words were selected, how many are never-reviewed, what question types are planned, or any other summary of the session contents. The first thing the user sees should be Question 1.

---

## Step 3 — Quiz one word at a time

Show progress (e.g. **Question 2 / 7**). Send **one question per message** and wait for the answer before continuing.

**Question type** — choose based on which facet most needs practice:

| Type | Prompt shown | Answer expected | Words | `--quiz-type` value |
|------|-------------|-----------------|-------|---------------------|
| reading-to-meaning | kana reading only | English meaning | all | `reading-to-meaning` |
| meaning-to-reading | English meaning only | kana reading | all | `meaning-to-reading` |
| kanji-to-reading | kanji form only (hide kana) | kana reading | `{kanji-ok}` only | `kanji-to-reading` |
| meaning-reading-to-kanji | English meaning + kana reading | correct kanji form | `{kanji-ok}` only | `meaning-reading-to-kanji` |

**Hard rules:**

1. **`{no-kanji}` words: only `reading-to-meaning` and `meaning-to-reading`.** No kanji questions ever.

2. **`meaning-reading-to-kanji` is always multiple choice** (4 options, A–D). The kanji form must never appear in the question stem — show meaning + kana as the joint prompt; put the candidate written forms in the answer options. The correct kanji appears only as an answer option.

3. **Prompt purity — never leak the answer form into the prompt:**
   - `reading-to-meaning`: show kana **only** — never include the kanji form. ❌ "What does 木陰 (こかげ) mean?" ✅ "What does こかげ mean?"
   - `meaning-to-reading`: show English **only** — never include the Japanese form (neither kanji nor kana). ❌ "What is the reading of 木陰 (shade of a tree)?" ✅ "Give the reading: shade of a tree; bower."
   - `kanji-to-reading`: show kanji **only** — never include the kana reading alongside it. ❌ "What is the reading of 木陰 (こかげ)?" ✅ "What is the reading of 木陰?"

**Free answer vs. multiple choice** (for the other three types):
- **Never-reviewed words: always multiple choice** (4 options, A–D). No exceptions.
- **Well-reviewed words (3+ reviews, good scores): free answer** by default.
- If the user requests multiple choice after a free-answer question, provide it — but cap the score at 0.7 and note that hints were given.

**Distractors for multiple choice:** prefer corpus words (from Step 1) that are semantically adjacent, share kanji, or have similar sounds. Also draw on your knowledge of Japanese at the learner's `corpus_level`. Avoid reusing other session words — it creates an elimination effect as the session progresses.

**Mid-question pauses:** if the user asks for a mnemonic, etymology, or radical breakdown, engage fully. For kanji info call:

```bash
node .claude/scripts/get-kanji-info.mjs <kanji1> <kanji2> ...
```

After any discussion, **re-ask the exact same question** before advancing.

---

## Step 4 — Grade, record, repeat

After each answer:

1. Grade 0.0–1.0 and briefly explain what was right or wrong.
2. Record immediately (this also removes the word from the session queue):

```bash
node .claude/scripts/record-review.mjs \
  --word-id WORD_ID \
  --word-text "WORD_TEXT" \
  --score SCORE \
  --quiz-type QUIZ_TYPE \
  --notes "NOTES"
```

   The `--reviewer` flag defaults to the OS username; pass it explicitly if needed (e.g. `--reviewer roommate`).

3. **Notes:** a short, self-contained sentence. Never reference answer letters; always spell out what was chosen.
   - Good: `"Gave correct reading どなる"`
   - Good: `"Chose 怒鳴る (correct); noted confusion with 怒る"`
   - Good: `"Could not produce kanji form; guessed 怒鳴 (wrong); correct is 怒鳴る"`
   - Bad: `"guessed A"` — the letter means nothing without the question context

4. Ask the next question (go back to Step 3).

---

## Step 5 — Finish

After the last answer is graded and recorded:

```bash
node .claude/scripts/clear-quiz-session.mjs
```

Give a brief summary: words quizzed, overall score, any patterns worth noting.
