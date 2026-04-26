# TODO: "Learn" (Planting) Feature

A guided, document-scoped vocabulary introduction mode inspired by Memrise's "plant" workflow.
Complements the existing "Quiz" (watering/SRS review) flow without replacing it.

---

## Motivation

Some learners prefer a structured, guided path through a document's vocabulary rather than
tapping individual words in the Vocab Browser or Document Reader. The "Learn" mode lets a
user commit to learning all new vocabulary in a document by introducing small batches of
words and immediately drilling them intensively. Planted words enter the normal SRS quiz
queue immediately upon introduction (an `ebisu_models` row is created with a short
halflife), so the Learn and Quiz flows share the same underlying data with no separation.

---

## Document-Scoped "Quiz" (Watering)

The existing quiz flow already supports filtering by document: launching Quiz from a
document row in `VocabBrowserView` should restrict the quiz session to only the words
sourced from that document, using the normal SRS due-date logic within that subset.

This is the "watering" half of the Memrise analogy — it reviews already-planted words
from a specific document rather than drawing from the global pool. This may already be
partially or fully implemented; confirm and document the existing behavior. If not yet
wired up, it is a prerequisite for the full Learn + Quiz per-document experience.

---

## Entry Point

In `VocabBrowserView`, each document title row (the collapsible section header) gets two
buttons:

- **Learn** — launches planting (this feature)
- **Quiz** — launches the existing document-scoped quiz

Both buttons should be visible even if some or all words are already known; "Learn" simply
fast-forwards through already-planted words (see "Already-known words" below).

---

## Session Scope: One Batch Per Tap

**Implemented.** A single "Learn" session covers exactly one batch (`batchSize = 4` words,
or fewer if fewer remain). When the batch is finished the app shows a **Batch Done** summary
card listing the words just planted, with a single "Done" button that dismisses the sheet
and returns the user to `VocabBrowserView`.

To plant the next batch the user simply taps "Learn" again. `loadSession` automatically
skips any words whose facets are already at `reviewThreshold` reviews, so it always opens
on the next unplanted word. This design keeps individual planting sessions short and
manageable regardless of how many words a document contains.

Batches smaller than `batchSize` (including a single-word batch) are fully supported — the
drill still covers all facets of every word to `reviewThreshold`.

When the last word in the document is planted the session ends with an **All Done**
celebration screen instead of the Batch Done card.

---

## Core Session Flow: Single-Queue Interleaved Introduce + Drill

Planting is driven by a single shuffled `pendingQueue` of `PlantQuizItem`s. A separate
`sessionCounts` dictionary (keyed by `"wordId\0facet"`) tracks how many times each
(word, facet) pair has been drilled **this session** (independent of long-term DB counts).

### Queue building — after each "Got it"

When the user taps "Got it" on the introduce card for word *i* (0-indexed within the batch):

1. **All facets of the newly introduced word** are appended to `pendingQueue`.
2. **One facet per older introduced word** is appended — the facet with the lowest
   `sessionCounts` value for that word (ties broken by facet order), so facets
   round-robin across introductions rather than always re-drilling the same one.
3. **If this is the last word in the batch**, additional items are appended so that every
   `(word, facet)` pair in the batch reaches `reviewThreshold` total reviews. The topup
   counts already-answered (`sessionCounts`) plus already-queued items toward the target,
   so no pair is over-drilled.

The chunk built in steps 1–3 is shuffled before being appended. A light adjacency pass
then swaps items to avoid the same wordId appearing back-to-back at the queue/chunk
boundary or within the chunk itself.

### Advancing

After each answered drill question the session calls `drainOrAdvance`:
- If `pendingQueue` is not empty → pop the next item and show it.
- Else if more words remain to introduce in this batch → show the next introduce card.
- Else → the batch is complete → show Batch Done (or All Done for the final batch).

### Recovery batch (all words already introduced)

If every word in the first batch was introduced in a prior interrupted session, no "Got it"
tap will fire. In this case `loadSession` calls `enqueueRecoveredOnlyBatch`, which seeds
`pendingQueue` with `reviewThreshold` copies of every facet for all recovered words and
shuffles the result.

### Drill question format

All planting drills are app-generated multiple-choice (4 choices). No LLM call is needed
for question generation. Distractors are drawn from other words in the same document using:

- **Reading distractors** — `commitment?.committedReading ?? annotatorResolved?.kana ?? kanaTexts.first`
- **Kanji distractors** — `commitment?.committedWrittenText ?? annotatorResolved?.writtenForm.text ?? writtenTexts.first`
- **Gloss distractors** — the first gloss of the document-attested sense for each
  distractor word (same sense-index resolution used for the quiz question itself)

This ensures distractors use the same written/kana form the annotator chose for the
document, not an arbitrary JMDict-default form.

---

## Post-Drill Feedback UI

**Implemented.** After the student taps a multiple-choice answer, planting transitions to
the same post-answer chat view used by the normal vocabulary quiz (`PostAnswerChatView`,
shared between `QuizView` and `PlantView`). The view shows:

- A **question bubble** (left) with the stem and all four labeled choices.
- An **answer bubble** (right) with the student's choice and a ✓/✗ indicator plus the
  correct answer on wrong attempts.
- A **score badge** ("Correct" / "Incorrect").
- A **"Tutor me"** button (shown on wrong answers, hides after the first reply) that
  auto-sends a predefined explanation request to Haiku.
- A **"Details…"** button that opens `WordDetailSheet` for the drilled word.
- A **chat input** for optional follow-up questions to Haiku.
- A **"Continue →"** button to advance to the next drill question or introduce card.

`PostAnswerChatView` is a standalone view with no coupling to either `QuizSession` or
`PlantingSession`. Both callers pass plain data (message arrays, bindings, closures).

---

## The "Introduce" Card

A lightweight new card design (not the full Word Detail Sheet) showing:

- Kanji form(s) and kana reading(s)
- Senses relevant to this document (same filtering logic as VocabBrowser)
- A toggle: **"I'll learn the kanji spelling too"** — when on, kanji-reading and
  kanji-to-meaning facets are included in drills; when off, only kana-based facets
- A **"Chat with AI / make a mnemonic"** button (calls Haiku) so the user can
  build a memory hook before drilling begins

The introduce card is purely passive — the user reads it, optionally chats, then chooses
one of three actions (no quiz question on this card itself):

- **Got it →** — creates Ebisu models and starts drilling the word immediately.
- **Known** — moves the word's facets to the learned table, skipping it permanently in
  all future planting sessions for this document. No drill is shown.
- **Skip** — removes the word from this session's queue without any DB changes, so it
  will reappear at the start of the next planting session.

---

## SRS Integration

When the user taps "Got it" on an introduce card for a word not yet in their vocab:

- **Create Ebisu models** for all selected facets of that word with a short initial
  halflife (suggested: 1–2 hours). This immediately makes the word visible to the
  normal Quiz flow — planting and quizzing share the same underlying data.
- Each drill question during a planting session calls the normal `updateRecall` path,
  just like a Quiz question would. No special planting-only data store.

"Planted" is defined operationally: every (word, facet) pair introduced in the current
batch has been drilled at least `reviewThreshold` times this session.

---

## Session Recovery (Interrupted Planting)

**Implemented.** On session start, `loadSession` fetches all enrolled Ebisu word IDs
alongside the review counts. Unplanted words for the document are split into two groups:

1. **Already introduced** — words that have Ebisu models but review counts below
   `reviewThreshold`. These are sorted to the front of `remainingWords`, preserving
   document order within the group.
2. **Not yet introduced** — words with no Ebisu models. These follow the already-introduced
   words in the queue.

`batchIntroducedCount` is initialized to the number of already-introduced words in the
first batch, so `introduceNextWord` skips their introduce cards and goes directly to
drilling. No explicit "resume" prompt is shown — the session opens with the introduce
card for the first new word and the recovered words participate silently in the first
drill chunk.

Recovered words inherit their kanji-enabled state from whatever Ebisu facets already
exist in the database (no re-prompt of the kanji toggle).

Recovery is age-agnostic: if a word has an Ebisu model and its review count is below
`reviewThreshold`, it is always recovered regardless of when it was introduced.

---

## Already-Known Words

If a word is already in the user's vocab with Ebisu models that have been reviewed more
than N times (i.e., clearly past the planting threshold), planting silently skips it and
moves to the next unplanted word.

Words whose facets are in the learned table (either moved there by tapping "Known" on the
introduce card, or marked known elsewhere in the app) are also silently skipped at session
load time. The user never sees a card for either case — skipping is invisible.

---

## Facets Drilled

Planting drills **all facets** selected for a word (reading-to-meaning,
meaning-to-reading, kanji-to-meaning, kanji-to-reading — depending on the kanji toggle on
the introduce card). The existing intensive-versus-varied user preference setting is
**not** consulted during planting for now; planting is always intensive by design.
Revisit this decision after initial implementation.

---

## Open Questions / Decisions Deferred

- **Introduction order**: Implemented — words are sorted by the first (minimum) `line`
  value in `references[documentTitle]`, matching document reading order exactly.
- **Batch size**: Implemented — `batchSize = 4` (named constant in `PlantingSession`).
- **N reviews threshold**: Implemented — `reviewThreshold = 2` (named constant).
- **Short halflife value**: Implemented — `initialHalflife = 1.5` hours (named constant).
- **"Learn" button state**: Should the Learn button be visually distinct (e.g., a count
  badge showing how many words remain to plant) vs. always the same appearance?
