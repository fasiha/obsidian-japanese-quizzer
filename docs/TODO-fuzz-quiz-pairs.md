# Fuzzing quiz answer pairs (work plan)

## Goal

Make `TestHarness --fuzz` prove that every normal Vocab quiz combination works, and keeps working.
A "combination" is an item kind, followed by an answer outcome, followed by the next item kind, under
each "multiple choice only" setting. Each combination runs through both the prefetch path and the direct
path, and the two must agree.

Today `prefetch-consume` ([Fuzz.swift](../Pug/TestHarness/Sources/TestHarness/Fuzz.swift), area Q) covers only
the correct answer for six item kinds (multiple choice, free answer, two counter kinds, two pair legs). The
gaps are:

| Gap | Why it is not covered yet | Cost |
|---|---|---|
| Wrong answers (multiple choice tap, typed counter reading, typed free answer, pair drill) | Sequence runner only answers correctly | Small |
| "No idea" / "Inkling" taps (`tapUncertain`, `tapTextUncertain`, `tapFreeAnswerUncertain`, pair "don't know") | Each starts an opening Haiku turn | Medium: needs the Haiku seam |
| Haiku-graded free answers and tutor sessions (`doOpeningChatTurn`, `doChatTurn`, counter and pair tutors) | `client.send` goes to the network | Medium: needs the seam and realistic `SCORE:` replies |
| Kanji quiz items (`KanjiQuizData`, `buildKanjiMultipleChoice`) | No fixture; needs data from `kanjidic2.sqlite` | Moderate |

## Current facts (verified in code)

- The harness compiles the app's own sources through symlinks in `Pug/TestHarness/Sources/TestHarness/`
  (`QuizSession.swift`, `AnthropicClient.swift`, `QuizContext.swift`, …). Fuzzing runs the shipping code.
- `AnthropicClient.callAPI` (in `Pug/Pug/Claude/AnthropicClient.swift`) always calls `URLSession.shared`.
  The fuzzer builds clients with `apiKey: "not-needed"`, so an unstubbed call would fail with HTTP 401,
  not silently succeed. It must still never reach the network.
- Existing test-only hooks follow a `…ForTesting` naming pattern in `QuizSession.swift`
  (`awaitPrefetchForTesting`, `discardPrefetchForTesting`, `awaitAdvanceForTesting`, `gradeAnswerForTesting`).
- Grading paths:
  - `tapChoice(index)` → `applyLocalGrade` (score 1.0 or 0.0, no Haiku).
  - `gradeCounterAnswer` → exact string match against `counter.reading` or `pronunciations`, no Haiku.
  - `tapUncertain(score:)` → `doOpeningChatTurn(shouldParseScore: false)`: one Haiku call.
  - `tapTextUncertain(score:)` → same, one Haiku call.
  - `tapFreeAnswerUncertain(score:)` → records the score only, no Haiku.
  - `submitTransitivePairDrillAnswer` → `gradeTransitiveDrillWithLLM` (Haiku) for some answers.
  - `submitFreeAnswer` → `doOpeningChatTurn(shouldParseScore: true)` (Haiku) for some answers. **To verify:** which
    answers skip Haiku.
  - `startTutorSession`, `startCounterTutorSession`, `startTransitiveDrillTutorSession` → one Haiku call each.

## Design

### The seam (shared by every phase)

- Add a test-only responder to `AnthropicClient`: an optional stored closure, `nil` in both app initializers.
  `callAPI` checks it first. If it returns a response, use it. If the closure is set and returns `nil`, throw
  an error that names the unstubbed call. That error is the fuzzer's **no-network guarantee**: no unexpected
  call can reach the network, and an unexpected Haiku call is a reported failure.
- Record every call the responder sees (system prompt prefix, message count, last user text). Oracles check
  these counts: correct answers make zero Haiku calls, "No idea" makes exactly one, and so on.
- Canned replies must look like real model output. For graded replies, use the `SCORE:` line format that
  `parseScore(from:)` reads. Check its exact format before writing any canned reply.

### Oracles (free, per combination)

1. Each item arrives in its expected phase (existing).
2. No stale multiple-choice result, tutor prompt, or early prefetch carries over (existing).
3. Prefetch path and direct path show the same phase and score for each step (existing).
4. **New:** a correct answer scores 1.0. A wrong answer scores 0.0 (multiple choice and typed counter reading).
   "No idea" scores 0.0 and "Inkling" scores 0.25, and each is recorded in the review log.
5. **New:** the Haiku call count matches the outcome: 0 for local grades, 1 for uncertainty opening turns,
   1 for Haiku-graded free answers. The canned score is written to `gradedScore` when `shouldParseScore` is true.
6. **New:** after any outcome, the next item has no leftover `chatInput`, `isSendingChat` stays false,
   and `uncertaintyUnlocked` resets.

### Mutation checks (required for every phase)

Each phase must show the new oracles fail when the app code is broken on purpose. Use a temporary,
reverted edit, one bug at a time. For example:
- Make `tapChoice` score wrong answers as 0.5.
- Make the uncertainty path skip the opening Haiku turn.
- Make the counter typed path use `contains` instead of `==`.

The previous fix (commit 0c25902) set this bar: reversing the fix failed all 61 runs.

## Phases (one session each is reasonable)

### Phase 1: seam, wrong answers, and the no-network guard (DONE)
- [x] Added `replyStub` to `AnthropicClient` (`Pug/Pug/Claude/AnthropicClient.swift`). It is `nil` in the app.
      When set, `callAPI` answers from the stub, and a `nil` reply throws `AnthropicError.unstubbedCall`.
- [x] Added `ScriptedReplies` to `Fuzz.swift`. It records every model call and currently returns `nil` for all
      of them, because no phase has scripted a reply yet.
- [x] Split outcomes into `PrefetchOutcome` (`correct`, `wrong`) and `PrefetchStop` (kind + outcome). Wrong
      outcomes cover multiple choice and both counter kinds. Free answers and pair drills are correct-only,
      because a wrong one goes to Haiku.
- [x] Oracles: score equals 1.0 or 0.0; result bubble starts with ✓ or ✗ (skipped for exact-match free answers,
      which show plain typed text); zero model calls per run.
- [x] Baseline before the change: 61 checked, 0 model calls reached `callAPI`. After: 128 checked, 16 skipped
      (free answer with multiple choice only), all PASS.
- [x] Mutation checks (QuizSession restored and verified identical to git):
  - `tapChoice` always correct: 30 failures.
  - Counter meaning-to-reading always correct: 68 failures.
  - Counter number-to-reading always correct: 72 failures.
- [x] Oracle 6 (next item starts clean) was added in Phase 2.
- [ ] Not run: `--fuzz all`. Only `prefetch-consume` matched the edited paths.

### Phase 2: "No idea" and "Inkling" (DONE)
- [x] Outcomes `noIdea`, `inkling` for multiple choice, both counter kinds, free answer, and pair "don't know"
      (the pair drill is graded locally, so it makes zero model calls).
- [x] Outcomes `noIdeaWhileGrading`, `inklingWhileGrading` for free answers: submit a partly right answer, then tap
      the admission before Haiku's grade comes back. Haiku's grade is 0.5, so the check tells the self-reported
      score apart from it. This needed a canned grading reply, which Phase 3 would otherwise have added.
- [x] Oracle 5: each answer makes exactly the model calls its kind and outcome expect (`expectedModelCalls(for:)`),
      and the run's total matches the sum of those.
- [x] Oracle 6: each item arrives clean (`chatInput`, `isSendingChat`, `uncertaintyUnlocked`, `gradedScore`).
- [x] `ScriptedReplies` answers the opening explanation turn and the grading reply. Any other call is unexpected.
- [x] Clean run: 572 checked, 168 skipped, all PASS (about one minute).
- [x] Mutation checks (QuizSession restored and verified identical to git after each):
  - No opening explanation after an admission: 331 failures.
  - Haiku's grade overwrites a self-reported score: 78 failures.
  - Inkling stored as no idea (0.0 instead of 0.25): 29 failures.
- Timing lesson: `awaitChatIdle` waits for a chat turn to finish, and it caps the wait at a quarter second.
  An earlier one-second-to-five-second cap made each broken run take over ten minutes, because every stuck step
  waited the full cap. Keep the cap short, since replies are stubbed and finish in milliseconds.
- Not covered yet: a wrong free answer, and a Haiku-graded pair drill. Both are Phase 3.

### Phase 3: Haiku-graded free answers and tutor sessions
- [ ] Find which free-answer inputs go to Haiku (`submitFreeAnswer`) and which are graded locally. Write canned
      replies in the real `SCORE:` format, one correct and one wrong, for each path.
- [ ] Add the three tutor entry points (`startTutorSession`, `startCounterTutorSession`,
      `startTransitiveDrillTutorSession`) after a wrong answer. Oracle: the tutor prompt is set for this item only.
- [ ] Mutation-check: drop the tutor prompt clear, confirm failures.

### Phase 4: kanji quiz items
- [ ] Read `KanjiQuizData` and `buildKanjiMultipleChoice` (`QuizSession.swift`, around lines 2737–2880).
- [ ] Build a fixture from `kanjidic2.sqlite` (already in the repo) for a few kanji with known readings.
      Decide whether to load it from the repo or to write a small committed JSON snapshot.
- [ ] Add kanji multiple choice and kanji typed outcomes to the sequence runner, with prefetch and direct paths.
- [ ] Mutation-check on the kanji reading validation (`validReadings`).

### Phase 5: coverage and docs
- [ ] Print a coverage matrix from the runner: each item kind by each outcome by each setting, with pass counts.
- [ ] Update `docs/TESTING.md`, the `prefetch-consume` section of `docs/TODO-fuzzing.md`, and `CHANGELOG.md`.
- [ ] Run `swift run TestHarness --fuzz all` (or `--fuzz prefetch-consume` if `all` is too slow) and confirm exit 0.

## Open questions

- Does `submitFreeAnswer` send every non-exact answer to Haiku? Confirm before writing Phase 3 replies.
- Where should the kanji fixture live? A committed snapshot keeps the fuzzer hermetic. Reading
  `kanjidic2.sqlite` at run time matches the existing `kanjidic2` area.
- Runtime budget: the current runner runs 61 sequences twice each. Adding outcomes multiplies this. Measure
  after Phase 1 and decide whether the combinations should split into a separate area (for example
  `prefetch-outcomes`).

## Safety rules for this work

- The fuzzer must never call the real Anthropic API. Every client in the harness uses the responder, and an
  unstubbed call is a failure. Check this before adding each phase.
- Do not run any script that calls the Anthropic API without asking first (project memory).
