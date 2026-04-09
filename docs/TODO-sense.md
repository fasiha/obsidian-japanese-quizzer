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

### Step 3 — Node.js: LLM sense analysis in prepare-publish.mjs (DONE)

**Goal:** for each word, ask Haiku which JMDict senses are relevant for quizzing
the student, given their corpus contexts, and write `llm_sense` to vocab.json.

**What was built:**
- Anthropic client call (using `ANTHROPIC_API_KEY` from `.env`, loaded via
  `node --env-file=.env`; no dotenv package needed on Node 20.6+) added to
  `prepare-publish.mjs`.
- Per word, collect all context paragraphs and bullet narrations across all
  source files (together, not per-file). Sorted and deduplicated — this is both
  the cache key (`computed_from`) and the content sent to Haiku.
- `<ruby>/<rt>/<rp>` tags stripped from context before sending; kanji base text
  is kept (more informative than the reading for sense disambiguation).
- Optimization: skip if the word has only one sense.
- If all context/narration strings are null, skip the Haiku call and write
  `sense_indices: []` directly.
- vocab.json written after each Haiku call so a crash doesn't lose prior work.
- Reasoning log written to `/tmp/sense-reasoning-<timestamp>.log`; path printed
  to stdout for easy reference.

**Prompt design (after iteration):**
- Framing: "Which senses are relevant for quizzing this student?" rather than
  "Which senses did the student encounter?" — the latter invites unnecessary
  narrowness for near-synonym senses.
- Inclusion rule: include a sense if directly evidenced OR if it is a
  near-synonym / shares a core meaning with an evidenced sense.
- Reasoning allowed: Haiku thinks step by step, then ends with a fenced JSON
  block. `max_tokens: 600`. The parser extracts the last ` ```json ``` ` block.
- Allowing reasoning (rather than "JSON only") improved results: for 裸
  (bare tree stump context), it correctly includes both sense 0 ("nakedness;
  nudity") and sense 1 ("bareness; being uncovered") by recognising sense 0 as
  the foundational sense from which sense 1 derives. The "JSON only" prompt
  returned only sense 1.
- Token cost: ~300–400 extra tokens per word for reasoning. At 124 multi-sense
  words in the current corpus this is negligible. If cost ever becomes a concern,
  switching back to "JSON only" (with `max_tokens: 64`) is the easy lever — but
  note it may produce overly narrow results for near-synonym senses.

**Flags:**
- `--no-llm`: skip all Haiku calls; pass through any existing `llm_sense` values.
- `--max-senses N`: analyze at most N words per run (useful for spot-checking).
- No `--recompute-senses` flag — delete individual `llm_sense` entries manually
  and rerun to override. Bulk recompute was considered too risky.

**Caching (use vocab.json itself):**
- At the start of a run, load the existing `vocab.json` if present.
- For each word, derive the current cache key: collect all non-null `context`
  and `narration` strings from all occurrences across all files, then
  sort and deduplicate (canonical form, independent of file order or line numbers).
- Compare against `llm_sense.computed_from`. If identical, skip the Haiku call
  and carry `sense_indices` forward.
- Recompute when any context or narration text changes (or a new one appears).
  File renames and line number shifts alone do not trigger recomputation.

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

**Files changed:** `prepare-publish.mjs` (+ `.env` for `ANTHROPIC_API_KEY`).

---

### Step 4 — iOS app: highlight enrolled senses in WordDetailSheet (FUTURE)

**Goal:** in the word detail sheet, make it visually clear which JMDict senses
the student is currently being quizzed on (the `llm_sense.sense_indices` set),
so they can see at a glance whether the automatic selection matches their
expectations before or after a quiz session.

**Motivation:** right now the sense analysis runs silently in the pipeline and
there is no way for the student to know which senses were selected without
reading vocab.json by hand. Surfacing this in the UI closes the feedback loop.

**Design decisions:**

- *Visual treatment:* dim non-enrolled senses to ~40% opacity (matching the
  pattern used for non-selected furigana forms elsewhere in the sheet). No extra
  icon needed — the contrast is explanation enough.

- *When `llm_sense` is absent or `sense_indices` is empty:* show no dimming at
  all. The selection was not evidence-based, so treating sense 0 as special
  would be misleading.

- *Explanatory label:* wrap the sense list in an `infoGroup` with heading
  "Senses used in quizzes" when `llm_sense` is present with non-empty indices.
  This makes the feature approachable to learners who would otherwise have no
  idea why some senses look faded.

**Implementation sketch (not yet agreed):**

1. Add `enrolledSenseIndices: [Int]` to `VocabItem`; populate from
   `entry.llmSense?.senseIndices ?? []` in `VocabCorpus.load()`.
2. In `senseExtrasSection`, pass the index alongside `SenseExtra` (already uses
   `enumerated`). For each sense, check `enrolledSenseIndices.contains(index)`.
3. Apply chosen visual treatment.

No DB changes required — `enrolledSenseIndices` comes from vocab.json, same
source as `QuizContext`.

---

### Step 5 — iOS app: in-app sense enrollment (FUTURE)

**Goal:** when the student commits to learning a word, record *which senses* they
are committing to, seeded from the document they were browsing. After commitment
they can tap any sense row to add or remove it from their quiz. This replaces
the current implicit behavior where quizzes use the corpus-wide union of all
senses the word appears with across all documents.

**Depends on:** Step 6 (per-reference `llm_sense`) must be complete so each
corpus occurrence carries its own `sense_indices`.

**Also requires audit:** all places that currently read enrolled senses
(`QuizContext`, `QuizSession`, and especially document-sourced reading-to-meaning
distractors added in commit 2cd96b9) must be updated to prefer
`word_commitment.sense_indices` over the corpus-wide union.

---

#### Subpart A — DB: add `sense_indices` to `word_commitment`

Add a nullable JSON column `sense_indices` to the `word_commitment` table,
parallel to `kanji_chars`:

```sql
ALTER TABLE word_commitment ADD COLUMN sense_indices TEXT; -- JSON array of Int, e.g. "[0,2]"
```

`NULL` means "not yet migrated" — the word was committed before v10 and has not
yet been seeded with sense data. On first `VocabCorpus.load()` after the v10
migration, any committed word with `sense_indices = NULL` is automatically seeded
from the corpus sense union in vocab.json (the senses the publish pipeline found
in the student's actual reading texts). Once written, `sense_indices` is non-null
and the seeding never runs again for that word. Words with no corpus sense data
(empty `corpusSenseIndices`) are left as NULL and the UI falls back to showing
all senses.

Newly committed words always get an explicit array written at commit time (see
Subpart D). Even if the student re-selects every sense, write the full explicit
array rather than converting back to `NULL` — `NULL` is reserved as the
"not yet migrated" marker.

Update `WordCommitment` struct in `QuizDB.swift`:
```swift
var senseIndices: String?   // JSON array of Int, or nil = all senses (legacy/default)
```

Add helpers to `QuizDB` (parallel to `setKanjiChars`):
- `func setCommittedSenseIndices(wordId:senseIndices:)` — write JSON array
- Access via `corpus.setCommittedSenseIndices(...)` after enrolling

---

#### Subpart B — Origin passing: WordDetailSheet knows its source

`WordDetailSheet` needs to know where it was opened from so it can highlight the
relevant senses and seed commitment correctly. The term "origin" (like a browser's
back-navigation origin) reflects that this is an ephemeral piece of navigation
context, not persistent data.

Add an optional parameter:

```swift
struct WordDetailSheet: View {
    let initialItem: VocabItem
    let db: QuizDB
    // ... existing params ...
    let origin: WordDetailOrigin?  // new
}

enum WordDetailOrigin {
    case document(title: String)                // opened from VocabBrowserView
    case reference(title: String, line: Int)    // opened from DocumentReaderView
}
```

All callers of `WordDetailSheet` pass their origin. VocabBrowserView passes
`.document(title:)` for whichever document's words it is currently showing.
DocumentReaderView passes `.reference(title:line:)` for the tapped word's line.

Derive `originSenseIndices: [Int]` from `origin` lazily inside the sheet:
- `.reference(title, line)` → find `item.references[title]?.first { $0.line == line }?.llmSense?.senseIndices ?? []`
- `.document(title)` → union of `senseIndices` across all `item.references[title]` references

---

#### Subpart C — JMDictSenseListView: two-layer sense highlighting

`JMDictSenseListView` currently accepts `corpusSenseIndices: [Int]` and dims
non-enrolled senses. Replace that single layer with two orthogonal layers:

```swift
struct JMDictSenseListView: View {
    var senseExtras: [SenseExtra]
    var originSenseIndices: [Int] = []      // senses from the navigation origin (doc/line)
    var committedSenseIndices: [Int]? = nil // nil = all senses; non-nil = user's explicit selection
    var onToggleSense: ((Int) -> Void)? = nil  // nil = read-only; non-nil = interactive checkboxes
}
```

Visual treatment per sense row (when `onToggleSense` is non-nil, i.e. word is committed):

| Condition | Treatment |
|---|---|
| In `committedSenseIndices` (or `committedSenseIndices` is nil = all enrolled) | Normal opacity, filled checkmark |
| In `originSenseIndices` only (not committed) | Normal opacity, empty checkbox ring |
| In neither | 40% opacity, empty checkbox ring |

When the word is not yet committed (`onToggleSense` is nil), show no checkboxes:
just dim senses not in `originSenseIndices` to 40% opacity — same as current
behavior but scoped to the navigation origin rather than the corpus-wide union.

---

#### Subpart D — WordDetailSheet: sense section + commitment flow

**Before commitment (reading state = `.unknown`):**
- Pass `originSenseIndices` and `committedSenseIndices: nil` to
  `JMDictSenseListView` — senses from the origin are full brightness, others
  dimmed. No checkboxes, no toggles.
- "Learning" button (existing Reading picker → `.learning`) triggers
  `setReadingState(.learning)` **and** immediately calls
  `setCommittedSenseIndices(wordId:senseIndices:)` with the `originSenseIndices`.
  If `originSenseIndices` is empty (the reference had no `llm_sense` data), write
  an empty array `[]` — not `NULL` — to signal "explicitly no senses selected."
  The quiz layer treats `[]` as "use sense 0" (existing fallback from Step 1).

**After commitment (reading state = `.learning` or `.known`):**
- Pass `originSenseIndices`, `committedSenseIndices` (decoded from
  `item.committedSenseIndices`), and `onToggleSense` to `JMDictSenseListView`.
- Every sense row shows a checkbox. Tapping calls `toggleCommittedSense(index:)`:
  - If index is in the current committed set → remove it.
  - If index is not in the set → add it.
  - Write updated array back via `corpus.setCommittedSenseIndices(...)`.
- No "all must be checked" guard — an empty committed array is valid and falls
  back to sense 0 in quizzes (Step 1 behavior).
- No explanatory label needed; the checkboxes are self-evident.

**Encountering the word again from a different document:**
- Senses in `originSenseIndices` that are not in `committedSenseIndices` appear
  at full brightness with an empty checkbox. The student sees them as unchecked
  and can tap to add them. No banner or pop-up needed — the visual state is
  sufficient.

---

#### Subpart E — QuizContext and QuizSession: prefer committed senses

In `QuizContext.build()`, after loading committed words, check
`word_commitment.sense_indices`:
- Non-null non-empty array → decode and use as `enrolledSenseIndices`
- Null (legacy "all senses") → use all sense indices for the word from JMDict
- Empty array → treat as `[0]` (Step 1 fallback)

```swift
// In QuizContext.build(), where corpusSensesMap is populated:
if let committedSensesJSON = commitment?.senseIndices,
   let committed = try? JSONDecoder().decode([Int].self, from: Data(committedSensesJSON.utf8)) {
    corpusSensesMap[entry.id] = committed.isEmpty ? [0] : committed
} else {
    // NULL: enroll all senses — use full JMDict sense count for this word
    corpusSensesMap[entry.id] = Array(0 ..< (wordSenseExtras[entry.id]?.count ?? 1))
}
```

Also audit `QuizSession.swift` and the document-sourced reading-to-meaning
distractor logic (added in commit 2cd96b9) — any place that reads
`corpusSenseIndices` from `VocabItem` or `QuizItem.enrolledSenseIndices` should
go through this same preference chain, not bypass it by reading vocab.json
directly.

---

#### Subpart F — VocabCorpus: expose committed senses on VocabItem

Add to `VocabItem`:
```swift
/// User's explicitly enrolled sense indices. nil = legacy "all senses" state.
/// Use committedSensesForDisplay to get the indices to show in the UI.
var committedSenseIndices: [Int]?
```

Add a computed helper:
```swift
/// Indices to treat as enrolled: the committed array if set, otherwise all indices.
func committedSensesForDisplay(totalSenseCount: Int) -> [Int] {
    committedSenseIndices ?? Array(0 ..< totalSenseCount)
}
```

Populate from `item.commitment?.senseIndices` in `VocabCorpus` wherever
`commitment` is already set. This lets `WordDetailSheet` and
`JMDictSenseListView` read directly from the item rather than decoding JSON
inline.

---

#### Summary of file changes

| File | Change |
|---|---|
| `QuizDB.swift` | Add `senseIndices` to `WordCommitment`; add `setCommittedSenseIndices` helper |
| `VocabCorpus.swift` | Add `committedSenseIndices` to `VocabItem` + `committedSensesForDisplay` helper; populate in load/refresh |
| `WordDetailSheet.swift` | Accept `origin: WordDetailOrigin?`; derive `originSenseIndices`; seed committed senses on commit; pass toggles to sense list post-commit |
| `JMDictSenseListView.swift` | Replace `corpusSenseIndices` with `originSenseIndices` + `committedSenseIndices` + `onToggleSense`; update all callers |
| `VocabBrowserView.swift` | Pass `.document(title:)` origin when opening `WordDetailSheet` |
| `DocumentReaderView.swift` | Pass `.reference(title:line:)` origin when opening `WordDetailSheet` |
| `QuizContext.swift` | Prefer committed senses (non-null) over corpus union; null = all senses |
| `QuizSession.swift` | Audit: ensure enrolled senses come from committed set, not corpus union |
| Document-sourced distractor logic (commit 2cd96b9) | Audit: same sense preference chain |
| DB migration | `ALTER TABLE word_commitment ADD COLUMN sense_indices TEXT` |

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

### Option 4 — In-app sense enrollment (future; Step 5 above)
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

---

### Step 6 — Per-reference sense assignment (DONE)

**Goal:** record, for each corpus reference of a word, which JMDict sense(s) that
specific occurrence embodies. This enables the iOS reader to show exactly the
right sense for each source line rather than defaulting to the first couple.

**Schema change** — each reference occurrence gains an optional `llm_sense` field:
```json
"references": {
  "path/to/File": [
    { "line": 42, "context": "…", "narration": null, "llm_sense": { "sense_indices": [2], "computed_from": ["…"], "reasoning": "<Haiku reasoning>" } },
    { "line": 107, "context": "…", "narration": null, "llm_sense": { "sense_indices": [0, 1], "computed_from": ["…"] } }
  ]
}
```

- `sense_indices`: which JMDict senses this specific occurrence embodies. A
  reference can have multiple if the sentence genuinely covers more than one
  sense (e.g. a metaphorical extension that also echoes the literal sense).
- `computed_from`: sorted array of the non-null `context` and `narration`
  strings for this reference, used to detect staleness on future runs.
- `reasoning`: Haiku's chain-of-thought text; present only when Haiku was
  called for this reference (i.e. when the word has more than one JMDict sense).
  For the migration, `reasoning` is copied from the old top-level `llm_sense`
  only when the word has exactly one reference (the aggregate reasoning is then
  about that specific occurrence).
- `llm_sense` is absent when the assignment has not yet been determined.

With this in place, the top-level `llm_sense` key (which contained
`sense_indices`, `computed_from`, and `reasoning`) is dropped from the word
object. (The iOS app reads from vocab.json only after publishing, so there is no
window where old iOS and new vocab.json are live together that would cause a
problem.)

**One-time migration — `migrate-sense-refs.mjs`:**
- Standalone script; does not re-parse Markdown, does not call Haiku.
- For each word that has a top-level `llm_sense`:
  - **`sense_indices` is `[]`** (no context was available): stamp every
    reference with `{ "sense_indices": [], "computed_from": [] }` and drop the
    top-level `llm_sense`.
  - **`sense_indices` has exactly one element**: stamp every reference with
    `{ "sense_indices": [X], "computed_from": <non-null context+narration for that ref> }`.
    Additionally include `"reasoning"` copied from the top-level `llm_sense`
    if and only if the word has exactly one reference. Drop the top-level
    `llm_sense`.
  - **`sense_indices` has two or more elements** (ambiguous): leave all
    references without an `llm_sense` key; keep the top-level `llm_sense`
    so it is visible as a signal for manual disambiguation.
- Writes the resulting vocab.json.
- Prints a count of words that still have a top-level `llm_sense` (i.e.
  still need manual disambiguation), so we know when we're done.
- Manual overrides (hand-editing specific references) can be appended as
  inline edits at the bottom of the script and re-run as needed.

**Pipeline change — `prepare-publish.mjs`:**
- Single-sense JMDict words: stamp every reference `[0]` with no LLM call.
- Multi-sense JMDict words: new `analyzeReferenceSense(anthropic, jmWord, reference)`:
  - **Skip** if `reference.llm_sense` already exists and `computed_from`
    matches the current non-null context/narration values for that reference
    (cache hit).
  - **Skip with `sense_indices: []`** if both `context` and `narration` are
    null (nothing to send to Haiku).
  - Otherwise call Haiku with the single sentence and ask which sense(s) the
    word is used in. Store the result as `reference.llm_sense` with
    `sense_indices`, `computed_from`, and `reasoning`.
  - Per-sentence calls are more accurate than sending all sentences together:
    the model classifies one unambiguous target rather than solving a joint
    assignment problem.

**iOS reader change (TODO — see TODO-reader.md Phase 9):**
- `DocumentReaderView` inverted map extended to carry `senseIndices?` per word-id.
- Vocab chips in the disclosure group show only the matched sense(s) instead of
  defaulting to the first couple.

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
| 2026-03-26 | Step 6 complete: migration script (migrate-sense-refs.mjs) and pipeline change (prepare-publish.mjs) both implemented and tested. Original design settled: per-reference llm_sense with computed_from for cache invalidation; reasoning copied only when word has exactly one reference; ambiguous top-level entries left in place for manual disambiguation; null-context references skip Haiku and receive sense_indices: []. |
