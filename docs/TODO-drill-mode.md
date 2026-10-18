# Drill mode: exhaustively review the sentences/documents a word appears in

Status: **implemented 2026-10-17**, not yet tried on a device. Opened 2026-10-17; simplified 2026-10-17. Where the build differs from the design, see [Implementation notes](#implementation-notes) at the end.

## The itch

Today a vocabulary quiz session is a random sample: `QuizSession.selectItems` takes the
top `QuizContext.selectionPoolSize` most-urgent items (lowest recall first) and, in
`SessionLength.short`, always takes the weakest plus 2–4 uniformly random others from the
pool (in `.long`, the exact top 10). That is fine for daily upkeep. After days or weeks away,
a handful of scattered items leaves the student adrift.

The proposal is an **opt-in, bounded** alternative: after answering a quiz item, the student
can tap **Drill sentences** or **Drill documents** to *append* every related word to the
current session's queue. Not a sprinkle of neighbours into the random mix: an exhaustive
pass, added to the end of what is already queued.

## How sessions work today (verified in code)

- The queue lives in SQLite, table `quiz_session(position, word_id)` with `word_id` unique
  ([QuizDB.swift](../Pug/Pug/Models/QuizDB.swift)). Word IDs only; no facet or scope.
- Every launch calls `QuizSession.start()` → `loadItems()`, which **resumes** the saved queue
  if one exists. The facet is recomputed from current recall each time (the existing
  facet-picker); the queue only decides *which words*.
- Only grading removes a row (`recordReview` → `removeFromSession`). **Skip does not**, so
  skipped items come back on the next launch. (This design changes that.)
- On resume the progress label restarts at "1 / remaining".
- ⋯ → **New Session** (`refreshSession`) clears the queue and rolls a fresh one. This is the
  escape hatch for a drill that turns out to be too big.

## Design

1. **Skip evicts.** Skipping removes the word from the saved queue (in every session, not
   just drills). A skipped item no longer returns on the next launch.
2. **Session "seen" set.** `QuizSession` remembers the word IDs answered or skipped this
   session. Drills never re-add them. This also makes re-tapping safe: a second tap adds
   only what is not already seen or queued.
3. **Drill buttons**, shown in the post-answer area for ordinary vocabulary items
   (hidden for kanji, counter and transitive-pair items, which have no sentence):
   - **Drill sentences**: all other words in every sentence the current word appears in
     (across all its documents).
   - **Drill documents**: all other words in every document the current word appears in.
   - Each button shows its count ("+5", "+62") and is disabled when the count is 0.
     After a tap, a brief "Added N" confirmation appears.
4. **Sibling lookup** uses `VocabSync.cached()` references. Two words are sentence siblings
   when they share `(source, context)`; document siblings when they share a source. Siblings
   are drawn from the **unscoped** enrolled pool (`allEnrolledCandidates`), filtered to
   ordinary vocabulary (`wordType == "jmdict"`). Siblings that are not enrolled are silently
   skipped. Only word IDs are queued; the existing facet-picker chooses the facet for each
   word when it is presented. No picker UI for sentences or documents.
5. **Ordering of each drill batch** ("noisy sort"):
   1. sort the new siblings weakest-first (ascending recall);
   2. walk left to right, swapping each adjacent pair with probability 0.25 (a swap may
      cascade, so a word can occasionally slip further; this is intentional);
   3. drop words that are seen or already queued (an already-queued word keeps its earlier
      position);
   4. **append** to the end of the queue and rewrite the remaining queue with `saveSession`.

   Two drills in a row therefore produce: remaining queue, first drill's batch, second
   drill's batch.
6. **Why append, not shuffle in.** Appending never changes the next slot, so the
   prefetched question stays valid. If the current item is the last one, nothing was
   prefetched, so nothing goes stale. The cost is that random items still ahead of the
   student come first; that matches the "bounded, drill-like" intent.
7. **No new `SessionLength` case.** Drilling is a per-session action, not a global
   preference. (Adding a case would also break the exhaustive `switch` in
   [GrammarAppSession.swift](../Pug/Pug/Claude/GrammarAppSession.swift), line ~253.) The
   automatic version of this idea (weakest item plus its neighbours) is where a
   `SessionLength` case could fit later.
8. **Escape hatch.** Skip per item, and ⋯ → New Session for the whole queue. The progress
   label ("2 / 43") is the only indicator; no banner or resume prompt for now.

## Known risks / sizes

- A very common word in several documents can add 100+ items with no confirmation; the
  "+N" on the button and New Session are the mitigations.
- Sizes (upper bounds, all corpus words from the 2026-06-14 `vocab.json`; only enrolled
  words count): documents have a median 53 distinct words (90th percentile 82, max 97);
  most words in one sentence has a median of 2 (max 21).
- Document-scope quizzes narrow `allCandidates`; siblings must come from the unscoped pool.
- Setting `documentScope` also changes distractor pools (`appSideMultipleChoice`); drills
  must not change it.

## Work plan

1. Pure function `drillBatch(siblings:seen:queued:swapProbability:rng:)` that takes sibling
   items with recall, returns the ordered, deduplicated list. Injectable random generator.
2. Sibling lookup helper over `VocabSync.cached()` references (sentence and document modes),
   plus count computation for the button labels.
3. `QuizSession`: `seenWordIds`, `drillSentences()`, `drillDocuments()`, skip eviction
   (`QuizDB.removeFromSession` on skip), and rewriting the remaining queue
   (`items[currentIndex...]`) via `saveSession`. Reset `seenWordIds` in `start()` and
   `refreshSession()`.
4. UI: buttons with counts and the "Added N" confirmation in
   [PostAnswerChatView.swift](../Pug/Pug/Views/PostAnswerChatView.swift) and the wiring in
   [QuizView.swift](../Pug/Pug/Views/QuizView.swift). Check
   [feature-parity.md](feature-parity.md) for other quiz views.
5. Docs: update [quiz-architecture.md](quiz-architecture.md) and `feature-parity.md`.
6. Tests: add a fuzz area in the TestHarness (see [TODO-fuzzing.md](TODO-fuzzing.md)) with
   free-oracle invariants for `drillBatch`: the output is a duplicate-free subset of the
   input; no seen or already-queued word appears; with swap probability 0 the output is
   exactly weakest-first; with any probability it is a permutation of the filtered input;
   re-running with the output added to `queued` yields an empty batch.
   Run `swift run TestHarness --fuzz <area>` before reporting done.

## Implementation notes

Differences from the design above, and why:

- **Skip evicts everywhere.** `nextQuestion()` evicts the current word, so automatic skips (after a generation failure) evict too, not only manual skips.
- **The queue rewrite excludes the current word.** It writes `items[(currentIndex + 1)...]` plus the batch. The design's `items[currentIndex...]` would have put the graded word back in the saved queue, and it would have returned on the next launch.
- **Drill buttons appear only after grading.** This matches "Details…", and it keeps the next item fixed while Claude is still grading a free answer.
- **Drill buttons sit behind a "Drill" button, below "Report problem".** Design item 3 put them beside "Next Question →", where they were too easy to tap by accident. The "Drill" button reveals the two drill buttons. Each question starts collapsed, because `QuizView` keys the chat view by `currentIndex`.
- **Saved queues resolve against the unscoped pool.** The design left this open. A document-scoped launch resumes the whole saved queue, so drilled words outside the scope are kept. The scope still narrows fresh selection only. Revert to the scoped `byId` in `loadItems` if you would rather a scoped launch show only its own words.
- **Counts and taps share one function**, `pendingDrillIds(_:)`, so a button's number always matches what a tap adds.
- **Known gap:** `seenWordIds` is in memory. After an app restart, a drill can re-add a word answered earlier in the same sitting.
- **Unrelated fix:** `ToolHandler.lookupKanjidic` needed `await` on `db.read`. Without it, the current Xcode fails to compile the TestHarness and the app.

Details of the implementation are in [quiz-architecture.md](quiz-architecture.md#skip-eviction-and-drill-mode).
