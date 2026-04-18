# Dispute UI for mis-graded grammar multiple-choice questions

## Problem

Grammar tier-1 multiple-choice questions are generated and graded entirely by the app —
`tapChoice` in `GrammarAppSession` simply checks `index == question.correctIndex`. The
`correctIndex` is set at question-generation time. If Haiku records the wrong index in its
JSON output (e.g., confusing the passive and potential forms of られる), the student is marked
wrong for a correct answer and the Ebisu model is wrongly updated.

The root fix is to **shuffle app-side** (see `runGenerationLoop` in `GrammarQuizSession.swift`)
so Haiku always writes the correct answer at index 0 and the app introduces randomness —
eliminating the class of bug where Haiku mis-tracks an index during permutation.

If that belt is not enough, a **verbatim cross-check** could be added: the generation prompt asks
Haiku to emit a `CORRECT: "<verbatim quote>"` line immediately before the JSON, and the parser
verifies `choices[correctIndex][0] == correctQuote`. A mismatch causes a regeneration retry.
Neither the cross-check nor the Dispute UI is implemented yet.

## Proposed Dispute UI

When a student suspects Haiku mis-graded a multiple-choice question, they need a way to void
the wrong score and restore the pre-quiz Ebisu state.

### What to build

1. **"Dispute grading" button** — shown next to the score badge in `GrammarQuizView` only when
   `gradedScore == 0.0` after a multiple-choice tap (not for uncertainty or production grading).

2. **Confirmation sheet** — "Treat this as a passive review? Haiku's grading will be ignored."
   Keep it one tap; no elaborate explanation needed.

3. **On confirm:**
   - Insert a `Review` row with `notes: "disputed: grader error"` and score omitted or sentinel
     (audit trail — do not silently delete the bad review).
   - Restore the pre-quiz `EbisuRecord` (full alpha, beta, t, lastReview) for the primary topic
     **and all equivalence-group siblings** — restoring just the halflife via `rescaleHalflife`
     is not sufficient because the review already updated alpha/beta.
   - Set `gradedScore = nil` so the score badge disappears.
   - Call `nextQuestion()` as usual.

### What to snapshot

In `generateQuestion()` (`GrammarAppSession.swift:265`), the app already captures
`preQuizRecall` and `preQuizHalflife`. Extend this to snapshot the full `EbisuRecord?` for
the primary topic and a `[String: EbisuRecord]` for siblings, so the dispute handler can
restore them exactly.

### What not to build (at least initially)

- An LLM arbiter that re-evaluates the question: the failure rate is rare enough that the cost
  of an extra Haiku call on every disputed question is not worth it.
- Retroactive dispute of past sessions: the session variables are not persisted across app
  launches, so the dispute button is only available during the quiz session that produced the
  bad grade.
