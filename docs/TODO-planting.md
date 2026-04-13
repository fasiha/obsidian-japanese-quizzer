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

## Core Session Flow: Interleaved Introduce + Drill

Planting works in small batches (default size: 4 words, tunable via `batchSize`).
Within a batch the pattern is round-based:

1. **Introduce word 1** — show the introduce card (see below), user taps "Got it"
2. **Round of 1** — one shuffled drill question for word 1
3. **Introduce word 2** — show introduce card
4. **Round of 2** — one shuffled drill question each for words 1 and 2
5. **Introduce word 3** — show introduce card
6. **Round of 3** — one shuffled drill question each for words 1, 2, and 3
7. … continue until all words in the batch have been introduced …
8. **Repeat rounds** until every (word, facet) pair in the batch has been reviewed at
   least **N times** (default N = 2, tunable via `reviewThreshold`)
9. Move on to the next batch

A **round** is a pre-built, shuffled list with one question per introduced word — the
first facet of that word still below `reviewThreshold`. The shuffle is adjusted at
round boundaries so the same word does not appear back-to-back (a one-position rotate
if the first item of the new round matches the last word drilled).

Words introduced earlier in the batch accumulate more total drills because they
participate in more rounds, but every (word, facet) pair reaches the same minimum of
`reviewThreshold` reviews before the batch advances.

**Session opening behavior:** When a session loads, new (unintroduced) words are shown
first. If recovery words exist (see Session Recovery below), the session opens with the
introduce card for the first new word and the recovered words are treated as already
introduced — so the first drill round includes both recovered and newly introduced words
together. This means recovered words are not drilled in isolation before new words are
introduced.

Session ends when all new words in the document have been introduced and drilled to the
review threshold.

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

"Planted" is defined operationally: every item-facet introduced in the current batch has
been reviewed at least N times since its Ebisu model was created. The planting session
checks this condition to decide when to advance to the next batch.

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
drill round.

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
- **Session opening with recovered words**: Currently the session opens by introducing
  the next new word even when recovered (already-introduced) words exist. The alternative
  would be to drill recovered words first before introducing anything new. Deferring to
  user feedback — see "Session Opening Behavior" note in the Core Session Flow section.
- **"Learn" button state**: Should the Learn button be visually distinct (e.g., a count
  badge showing how many words remain to plant) vs. always the same appearance?
