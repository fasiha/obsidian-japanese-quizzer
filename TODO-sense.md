# Multi-sense vocabulary tagging

## Problem

Words like かぶせる have 7 JMDict senses spanning concrete physical actions and
abstract social metaphors. Reading-to-meaning quizzes can pick a distant sense
(e.g. "place blame on someone") as the correct answer even though the student
learned the word in a physical-covering context. The quiz becomes unfair: the
student "knows" the word but fails because they're tested on a sense they never
encountered.

The same issue applies to meaning-to-reading quizzes: the distractors can be
drawn from senses the student doesn't care about.

---

## Work breakdown

### Step 1 — iOS app: default to first sense (DONE)

**Goal:** immediately fix the "Haiku picks a random distant sense" bug without
any data pipeline work.

**What was built:**
- `VocabSync.swift`: added `LlmSense` struct with `sense_indices: [Int]`
  (decoded from `"llm_sense"` JSON key); added `llmSense: LlmSense?` field to
  `VocabWordEntry`.
- `QuizContext.swift`: added `enrolledSenseIndices: [Int]` and computed
  `enrolledSenses: [SenseExtra]` to `QuizItem`. `QuizContext.build()` now reads
  the cached vocab.json at startup and maps each word to its enrolled sense
  indices, defaulting to `[0]` when absent or empty.
- `QuizSession.swift`:
  - `systemPrompt()` filters `allMeanings` to enrolled senses only; reading-to-meaning
    and meaning-to-reading facet rules explicitly name the enrolled senses and
    say not to use others.
  - `freeAnswerStem()` for meaning-to-reading now shows just the meaning text
    (no "What is word for:" preamble) using enrolled senses.
  - Free-answer **grading** is intentionally left sense-agnostic: demonstrating
    any sense (enrolled or not) is 1.0. This preserves the e7e716f intent — the
    student shouldn't be penalized for knowing a sense they personally associate
    with the word (e.g. answering "hot spring" for 湯 when sense 0 is "hot
    water").
  - Sense coaching after grading also remains sense-agnostic.
- `TestHarness/DumpPrompts.swift` and `TestHarness/main.swift`: updated
  `QuizItem` constructors with `enrolledSenseIndices: [0]`.
- `TestHarness/VocabSync.swift` symlink added so TestHarness can compile.

**Key semantic rule:**

| `llm_sense.sense_indices` value | iOS quiz behavior |
|---|---|
| field absent (old vocab.json) | treat as `[0]` |
| `[]` (Haiku had no usable context) | treat as `[0]` |
| `[0, 2]` | restrict question generation to senses 0 and 2 |

---

### Step 2 — Node.js: add line numbers and sentence context to extraction (DONE)

**Goal:** extend `prepare-publish.mjs` / `shared.mjs` to capture, per vocab
token, the line number it appeared on and the context sentence/paragraph. This
is prerequisite for Step 3 (sense analysis) and also lays groundwork for a
future "show source sentence in WordDetailSheet" feature.

**What to do:**
- Extend `extractJapaneseTokens` in `.claude/scripts/shared.mjs` to return, per
  token: line number and context text.
- Context text = the nearest preceding block of contiguous prose (the paragraph
  above the `<details>` tag). Scan backward from the `<details>` opening line
  for the first contiguous block of non-blank, non-bullet, non-tag text.
- Also capture any narration text in the bullet line itself (e.g. `- 市場 いちば
  this 市 is same as 市川`). Both paragraph and bullet narration are useful signals.
- If no paragraph context is found and the bullet is bare, context is `null`.
- Populate `references` in each word's vocab.json entry:
  ```json
  "references": {
    "path/to/File": [
      { "line": 42, "context": "prose paragraph before <details>", "narration": "non-Japanese text on bullet" },
      { "line": 107, "context": null, "narration": null }
    ]
  }
  ```
  `context` and `narration` are `null` when absent. `sources` (flat string array) stays unchanged for iOS compatibility.

**Files to change:** `.claude/scripts/shared.mjs`, `prepare-publish.mjs`.

---

### Step 3 — Node.js: LLM sense analysis in prepare-publish.mjs (TODO)

**Goal:** for each word, ask Haiku which JMDict senses are actually used in the
student's corpus and write `llm_sense` to vocab.json.

**What to do:**
- Add Anthropic client call (using `ANTHROPIC_API_KEY` from `.env`) to
  `prepare-publish.mjs`.
- Per word, collect all context paragraphs and bullet narrations across all
  source files (together, not per-file).
- Optimization: skip if the word has only one sense (i.e., the `sense` array in the JMDict entry has only length 1).
- Call Haiku with: written forms, all JMDict senses numbered 0-based, and the
  collected contexts. Note that the contexts might have <ruby> annotations so strip those.
- Haiku returns JSON `{ "sense_indices": [0, 2] }`. Empty array is valid and
  means "insufficient context."
- If context is null for all occurrences, skip the Haiku call and write
  `sense_indices: []` directly.

**Caching (use vocab.json itself):**
- At the start of a run, load the existing `vocab.json` if present.
- For each word, derive the current cache key: collect all non-null `context`
  and `narration` strings from all occurrences across all files, then
  **sort** the array (canonical form, independent of file order or line numbers).
- Compare against `llm_sense.computed_from`. If identical, skip the Haiku call
  and carry `sense_indices` forward.
- Recompute when any context or narration text changes (or a new one appears).
  File renames and line number shifts alone do not trigger recomputation.
- Manual override: delete `llm_sense` from a word entry and re-run. A
  `--recompute-senses` flag could bulk-clear `llm_sense` for all words.

**vocab.json schema for each word entry:**
```json
{
  "id": "1234567",
  "sources": ["path/to/File"],
  "references": {
    "path/to/File": [
      { "line": 42, "context": "...", "narration": null },
      { "line": 107, "context": "...", "narration": "this 市 is same as 市川" }
    ]
  },
  "llm_sense": {
    "sense_indices": [0, 2],
    "computed_from": ["context sentence 1", "narration text", "context sentence 2"]
  }
}
```

**Files to change:** `prepare-publish.mjs` (+ `.env` for `ANTHROPIC_API_KEY`).

---

### Step 4 — iOS app: in-app sense enrollment (FUTURE)

After a quiz or in WordDetailSheet, show all JMDict senses with checkboxes. The
student ticks which senses they are learning. Store in a new
`word_commitment.sense_indices` DB column (parallel to `kanji_chars`). This
overrides the vocab.json default from Step 3.

Not designed in detail. Depends on Steps 1-3 landing first to establish
`sense_indices` as a first-class field and to give the student a reasonable
automatic starting point.

---

## Options considered (design archive)

### Option 1 — Cover all senses in one quiz (rejected)
Cognitively overloaded and punishing.

### Option 2 — Prompt-only: model focuses on common senses (partial mitigation)
Tell the LLM to prefer basic/prototypical senses. Helps, but "common" from the
LLM's perspective is corpus frequency, not the student's personal exposure.
Superseded by Steps 1-3 but could be applied as an interim measure.

### Option 3 — Source-sentence sense tagging at publish time (chosen; Steps 2-3)
One-time cost, clean pipeline separation, no quiz session latency.

### Option 3b — Bundle source sentences at quiz-generation time (rejected)
Adds latency to every quiz session, re-derives the same information on every
call. The source sentences are fixed once the Markdown file exists.

### Option 4 — In-app sense enrollment (future; Step 4 above)
Escape hatch for when the student wants to expand/narrow the auto-selected
senses. Analogy to grammar sub-uses, but implemented as explicit enrollment in
`word_commitment` rather than notes-column tracking.

---

## Notes on grading vs. question generation

Enrolled senses only affect **question generation** (what the LLM uses as the
correct answer and distractor pool). They do not affect grading or coaching:
- Free-answer grading for reading-to-meaning: demonstrating any sense (enrolled
  or not) is 1.0. A student who answers "hot spring" for 湯 (enrolled sense 0 =
  "hot water") passes — they clearly know the word.
- Sense coaching after grading: considers all senses the model knows, not just
  enrolled ones.

---

## Decision log

| Date | Decision |
|---|---|
| 2026-03-24 | Chose Option 3 (publish-time sense tagging) as the primary fix, with Option 4 (in-app enrollment) as future complement. Rejected Option 3b (runtime sentence bundling). |
| 2026-03-24 | Settled semantics: absent or empty sense_indices → treat as [0]. iOS app change (Step 1) is safe to ship before pipeline work. |
| 2026-03-24 | Context extraction: closest preceding contiguous prose paragraph + bullet narration text. No context → skip Haiku call, write sense_indices: []. |
| 2026-03-24 | Contronyms: no special handling. Enrolled senses (even contradictory) passed as-is to quiz generation. |
| 2026-03-24 | Grading and coaching remain sense-agnostic. Only question generation respects enrolled senses. Rationale: student shouldn't be penalized for knowing the word via a non-enrolled sense. |
| 2026-03-24 | Step 1 (iOS app default-to-first-sense) implemented and compiles. Steps 2-4 are TODO. |
