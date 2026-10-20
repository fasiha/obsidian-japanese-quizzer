# Changes

This document will contain brief notes on changes made, so that in the future when we're debugging something, we can look back through Git history and have some natural words explaining the problem we faced, some idea of the solutions tried, what we settled on, and how we tested/validated.

## 2026-10-19

### Fix: counter answers went to Haiku, and stale state leaked into the next quiz item

Problem: with "always ask multiple choice questions" on, a counter quiz (6 + 個) appeared as a chat message instead of a text box. The typed answer (ろっこ) went to Haiku, which had no question to answer, so Haiku replied "I'm not sure what you're asking about." Nothing was graded, and the item stayed in the saved queue.

Root cause: after a multiple-choice grade, the next item is built ahead of time (its prefetch). Two parts of consuming that prefetch were wrong:
- Counter items fell through to the chat branch whenever "multiple choice only" was on, because that setting turns off `isFreeAnswer`. Counter items are built free, and the direct path already sent them to the typed-answer branch.
- The prefetch path cleared the previous item's multiple-choice result and tutor prompts only in the multiple-choice branch. The other branches kept them, so Haiku saw a stale "Multiple choice result: …" line about the previous word.

What changed:
- `QuizSession`: a `clearPreviousItemTutorState()` helper clears the multiple-choice result and tutor state. Both the prefetch path and the direct path call it. Counter items always take the typed-answer branch. `currentCounterNumber` is left alone, because the prefetch sets it.
- Test seams for the harness: `QuizSession` (prefetch wait, prefetch index, advance wait), `CounterCorpus.setItemsForTesting`, and `TransitivePairCorpus.setItemsForTesting`.

Testing: `TestHarness --fuzz prefetch-consume` (no API calls). It runs every ordered pair of item kinds (multiple choice, free answer, counter number-to-reading, counter meaning-to-reading, transitive pair both legs, transitive pair intransitive leg), plus a few triples, through the prefetch path and the direct path, with "multiple choice only" both on and off. Each run must match the direct path, with no early prefetch, no stale state, and a score of 1.0 for each correct answer. Before the fix, every checked sequence failed (207 failures). After the fix, all pass. The file was also compiled by the macOS harness, which symlinks the app source. The iOS target was not built for this change.

## 2026-10-17

### Feature: drill mode (sentence and document drills)

Problem: after days away, a vocabulary quiz is a random sample of scattered items, which leaves the student adrift. Drill mode lets the student opt in, after grading a vocabulary item, to append every enrolled word that shares a sentence or a document with it to the end of the current queue.

What changed:
- `Pug/Models/DrillBatch.swift` (new): `DrillIndex` groups words by sentence (story + context) and by document (story), built once per session from the cached `vocab.json`. `drillBatch` removes seen and queued words, sorts weakest-first, then applies a noisy sort (adjacent swaps with probability 0.25).
- `QuizSession`: skipping now evicts the word from the saved queue (for manual and automatic skips), and `seenWordIds` tracks answered and skipped words. Drills append to `items` and rewrite the saved queue after the current word. Queue writes run through a serial chain.
- `PostAnswerChatView` and `QuizView`: "Drill sentences +N" and "Drill documents +N" buttons after grading, with an "Added N" confirmation. Hidden for other word types and for `PlantView`.
- `ToolHandler.swift`: added `await` to the `db.read` call in `lookupKanjidic`. Without it, the current Xcode fails to compile the TestHarness and the app target.

Known limitation: `seenWordIds` lives in memory, so after an app restart a drill can re-add a word answered earlier in the same sitting.

Testing: `TestHarness --fuzz drill` (8,004 checks, passing). A planted bug (dropping the seen filter) fails 812 checks, so the fuzzer does catch regressions. The app builds for the iOS simulator. The drill flow has not been exercised on a device.

## 2026-07-11

### Fix: Haiku over-nudging correct reading-to-meaning answers

User reported that after giving a "spray of meanings" (multiple rough synonyms) for words like 入り込む, どことなく, and 剥がす, Haiku would acknowledge the answer was essentially right but then keep asking them to narrow it to one canonical word — sometimes leaking the enrolled glosses in the process as "the word can also mean…" bullet lists.

Root cause: the shared "When to grade" instruction read "offer one or two nudges, then grade," which Haiku interpreted as a default step sequence even when the first attempt already contained a correct enrolled sense.

Two prompt changes, both in the `gradeAnswerForTesting` / free-answer branch of `systemPrompt(for:)`:

1. **Shared "When to grade" line**: reworded from "attempt → nudge → grade" to "check correctness first — grade immediately if any part of the attempt satisfies the facet criterion; nudge only when the answer is genuinely missing or unclear."
2. **reading-to-meaning coaching stance**: added "judge by the best part of a multi-part answer; natural-English paraphrases are full marks, not just exact dictionary glosses." Also tightened the no-leak rule to explicitly include listing enrolled senses back at the student.
3. **Scoring rubric 1.0 bullet**: extended to note that for reading-to-meaning, any natural phrasing whose best part conveys an enrolled sense is 1.0 — people explain word meanings in their own words.

Validated with a new `--grade-turns` mode in TestHarness (replays a multi-turn transcript with real accumulated history, unlike `--grade` which sends each answer independently). All three reported transcripts now grade on the first turn; a regression check confirmed a genuinely wrong answer on meaning-to-reading still gets nudged rather than immediately scored.
