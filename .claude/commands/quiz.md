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

This writes `.claude/quiz-context.txt`. Lines are sorted by urgency — lowest Ebisu recall probability first, `[new]` words (no model yet) at the end. Each line:

```
<jmdictId>  <forms>  {kanji-ok|no-kanji}  <meanings>  →<facet>@<recall>
<jmdictId>  <forms>  {kanji-ok|no-kanji}  <meanings>  →<facet>@<recall> free
<jmdictId>  <forms>  {kanji-ok|no-kanji}  <meanings>  →<facet>@new
<jmdictId>  <forms>  {no-kanji}  <meanings>  [new]
```

- `→<facet>@<recall>` — the single most-urgent facet for this word and its current recall probability (0–1). Lower = more forgotten. Use **multiple choice**.
- `→<facet>@<recall> free` — same, but this facet qualifies for **free answer** (script has verified ≥3 reviews AND model halflife ≥48 h).
- `→<facet>@new` — word has Ebisu models for other facets, but this specific facet has never been initialized (e.g. `[kanji]` tag added after introduction). Sorted at the word's lowest existing recall. Use **multiple choice**.
- `[new]` — no Ebisu model exists yet for any facet.
- `{kanji-ok}` — all four facets apply: `kanji-to-reading`, `reading-to-meaning`, `meaning-to-reading`, `meaning-reading-to-kanji`.
- `{no-kanji}` — only `reading-to-meaning` and `meaning-to-reading`; no kanji questions.

Both `@new` and `[new]` items use the **teaching approach** in Step 3 (call `introduce-word.mjs`, not `record-review.mjs`).

For full per-facet review history when needed:

```bash
node .claude/scripts/get-word-history.mjs --word-id WORD_ID
```

Also check `MEMORY.md` for `corpus_level` and `corpus_word_count`. If absent or word count has grown >20% since the last estimate, re-estimate from the vocabulary and save both to `MEMORY.md`.

---

## Step 2 — Select words and write session

*(Only reached when no session was found in Step 1.)*

Pick 3–6 items from the context:
- **Reviewed words** (`→facet@recall`): the list is already sorted by urgency — favour items near the top, but use semantic judgment to assemble a varied, motivating session. Don't take the top N mechanically; avoid quizzing near-synonyms or confusable pairs back-to-back, and prefer thematic variety.
- **Teaching items** (`[new]` or `→facet@new`): select at most 1–2 per session combined. Use the **teaching approach** — call `introduce-word.mjs`, not `record-review.mjs` (see Step 3).
- Apply `quiz_style`: **varied** — avoid facets reviewed in the last session; **intensive** — prioritise lowest-recall items regardless of recency.

Write the session:

```bash
node .claude/scripts/write-quiz-session.mjs <id1> <id2> ...
```

**Session opacity:** Transition immediately to Step 3 with no preamble. The first thing the user sees should be Question 1 (or the first teaching introduction).

---

## Step 3 — Quiz one word at a time

Show progress (e.g. **Question 2 / 7**). Send **one question per message** and wait for the answer before continuing.

### For teaching items (`[new]` or `→facet@new`)

Both call `introduce-word.mjs` instead of `record-review.mjs`. The scope differs:

**`[new]` — full introduction:** present reading + meaning, link to words the user already knows (shared kanji, similar sound, semantic field), propose a mnemonic. Ask "completely new, or faintly familiar?" to calibrate halflife. Pass the full targeted facet list (`{kanji-ok}`: all 4; `{no-kanji}`: 2).

**`→facet@new` — facet-only introduction:** the word is already known; just open the new angle:
- `kanji-to-reading`: show the kanji, ask for the reading, explain composition.
- `meaning-reading-to-kanji`: show meaning + reading, ask for the kanji form, explain components.
- `reading-to-meaning` / `meaning-to-reading`: quick check in the new direction.

Pass **only the unmodeled facet(s)** — do not overwrite existing models. Pass the already-modelled sibling(s) via `--passive-facets` so their timestamps advance with a neutral 0.5 score.

```bash
node .claude/scripts/introduce-word.mjs \
  --word-id WORD_ID \
  --word-text "WORD_TEXT" \
  --facets "FACET1,FACET2,..." \
  --passive-facets "SIBLING1,SIBLING2,..." \
  --halflife HOURS
```

Default halflife 24 h; 48–72 h if the user already knows the word/angle well.

### For reviewed words — quiz approach

**Question type** — use the facet shown in the context (`→facet@recall`); this is the most urgent one for that word:

| Type | Prompt shown | Answer expected | Words | `--quiz-type` value |
|------|-------------|-----------------|-------|---------------------|
| reading-to-meaning | kana reading only | English meaning | all | `reading-to-meaning` |
| meaning-to-reading | English meaning only | kana reading | all | `meaning-to-reading` |
| kanji-to-reading | kanji form only (hide kana) | kana reading | `{kanji-ok}` only | `kanji-to-reading` |
| meaning-reading-to-kanji | English meaning + kana reading | correct kanji form | `{kanji-ok}` only | `meaning-reading-to-kanji` |

**Hard rules:**

1. **`{no-kanji}` words: only `reading-to-meaning` and `meaning-to-reading`.** No kanji questions ever.

2. **`meaning-reading-to-kanji` is always multiple choice** (4 options, A–D), even if the context line has `free`. The kanji form must never appear in the question stem — show meaning + kana as the joint prompt; put the candidate written forms in the answer options. The correct kanji appears only as an answer option.

3. **Prompt purity — never leak the answer form into the prompt:**
   - `reading-to-meaning`: show kana **only** — never include the kanji form. ❌ "What does 木陰 (こかげ) mean?" ✅ "What does こかげ mean?"
   - `meaning-to-reading`: show English **only** — never include the Japanese form (neither kanji nor kana). ❌ "What is the reading of 木陰 (shade of a tree)?" ✅ "Give the reading: shade of a tree; bower."
   - `kanji-to-reading`: show kanji **only** — never include the kana reading alongside it. ❌ "What is the reading of 木陰 (こかげ)?" ✅ "What is the reading of 木陰?"

**Free answer vs. multiple choice:**
- **Context line ends with `free`: free answer** by default.
- **Otherwise (no `free` flag, or `@new`): multiple choice** (4 options, A–D).
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

3. **Passive updates** (`varied` mode only — skip in `intensive` mode, where the user prefers each facet tested explicitly): if during the quiz or follow-up discussion you exposed other facets of the same word (e.g. you revealed the meaning while quizzing kanji-to-reading, or the user demonstrated they knew the reading unprompted), add `--passive-facets` to passively move those facet models forward in time:

```bash
node .claude/scripts/record-review.mjs \
  --word-id WORD_ID --word-text "WORD_TEXT" \
  --score SCORE --quiz-type QUIZ_TYPE \
  --passive-facets "reading-to-meaning,meaning-to-reading" \
  --notes "NOTES"
```

4. **Notes:** a short, self-contained sentence. Never reference answer letters; always spell out what was chosen.
   - Good: `"Gave correct reading どなる"`
   - Good: `"Chose 怒鳴る (correct); noted confusion with 怒る"`
   - Good: `"Could not produce kanji form; guessed 怒鳴 (wrong); correct is 怒鳴る"`
   - Bad: `"guessed A"` — the letter means nothing without the question context

5. Ask the next question (go back to Step 3).

---

## Step 5 — Finish

After the last answer is graded and recorded:

```bash
node .claude/scripts/clear-quiz-session.mjs
```

Give a brief summary: words quizzed, overall score, any patterns worth noting.
