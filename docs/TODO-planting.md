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

Planting works in small batches (suggested size: 3–5 words; pick a constant to tune later).
Within a batch the pattern is:

1. **Introduce word 1** — show the introduce card (see below), user taps "Got it"
2. **Drill word 1** — one quiz question (all facets; see "Facets" below)
3. **Introduce word 2** — show introduce card
4. **Drill words 1 & 2** — one question each, interleaved
5. **Introduce word 3** — show introduce card
6. **Drill words 1, 2 & 3** — one question each
7. Repeat until batch is exhausted, then loop back and drill the whole batch again until
   every item-facet in the batch has received at least **N reviews** (suggested N = 3;
   tune later)
8. Move on to the next batch

Session ends when all new words in the document have been introduced and drilled to the N
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

The introduce card is purely passive — the user reads it, optionally chats, then taps
"Start drilling" (or similar). No quiz question on this card itself.

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

Users are busy; sessions will be interrupted. Recovery logic on session start:

1. Look at all words introduced in previous planting sessions for this document (words
   with Ebisu models created within the last, say, 24–48 hours whose review count is
   below N).
2. If any such "partially planted" words exist, treat them as the start of the new
   session's drill queue.
3. If there is room left in the batch (for example, only 1 word was left unfinished last
   time), introduce one fewer new word so the total active batch stays at the target
   batch size.
4. This means a returning user seamlessly finishes what was started and keeps moving
   forward — no explicit "resume" prompt needed.

---

## Already-Known Words

If a word is already in the user's vocab with Ebisu models that have been reviewed more
than N times (i.e., clearly past the planting threshold), planting silently skips it and
moves to the next unplanted word. The user never sees a "you already know this" card —
skipping is invisible.

---

## Facets Drilled

Planting drills **all facets** selected for a word (reading-to-meaning,
meaning-to-reading, kanji-to-meaning, kanji-to-reading — depending on the kanji toggle on
the introduce card). The existing intensive-versus-varied user preference setting is
**not** consulted during planting for now; planting is always intensive by design.
Revisit this decision after initial implementation.

---

## Open Questions / Decisions Deferred

- **Introduction order**: Use document order — sort words by the first (minimum) `line`
  value in `references[documentTitle]`. This matches how `VocabBrowserView` presents
  words (which reflects `vocab.json` insertion order, itself approximately first-appearance
  order). Sorting by `min(line)` per document makes this exact and robust rather than
  relying on `vocab.json` array position.
- **Batch size**: 3–5 is the suggested range; pick a concrete default constant (e.g., 4)
  and expose it as a tunable constant in the code (not necessarily a user-facing setting
  at first).
- **N reviews threshold**: Suggested 2–3; make it a named constant.
- **Short halflife value**: Suggested 1–2 hours for newly introduced items; make it a
  named constant.
- **Lookback window for recovery**: How far back to look for "partially planted" items
  (suggested 24–48 hours). If a user introduced words a week ago and never finished, do
  we treat those as planted or resume? Leaning toward: if Ebisu model exists and review
  count < N, always treat as needing planting regardless of age.
- **"Learn" button state**: Should the Learn button be visually distinct (e.g., a count
  badge showing how many words remain to plant) vs. always the same appearance?
