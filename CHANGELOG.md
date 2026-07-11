# Changes

This document will contain brief notes on changes made, so that in the future when we're debugging something, we can look back through Git history and have some natural words explaining the problem we faced, some idea of the solutions tried, what we settled on, and how we tested/validated.

## 2026-07-11

### Fix: Haiku over-nudging correct reading-to-meaning answers

User reported that after giving a "spray of meanings" (multiple rough synonyms) for words like 入り込む, どことなく, and 剥がす, Haiku would acknowledge the answer was essentially right but then keep asking them to narrow it to one canonical word — sometimes leaking the enrolled glosses in the process as "the word can also mean…" bullet lists.

Root cause: the shared "When to grade" instruction read "offer one or two nudges, then grade," which Haiku interpreted as a default step sequence even when the first attempt already contained a correct enrolled sense.

Two prompt changes, both in the `gradeAnswerForTesting` / free-answer branch of `systemPrompt(for:)`:

1. **Shared "When to grade" line**: reworded from "attempt → nudge → grade" to "check correctness first — grade immediately if any part of the attempt satisfies the facet criterion; nudge only when the answer is genuinely missing or unclear."
2. **reading-to-meaning coaching stance**: added "judge by the best part of a multi-part answer; natural-English paraphrases are full marks, not just exact dictionary glosses." Also tightened the no-leak rule to explicitly include listing enrolled senses back at the student.
3. **Scoring rubric 1.0 bullet**: extended to note that for reading-to-meaning, any natural phrasing whose best part conveys an enrolled sense is 1.0 — people explain word meanings in their own words.

Validated with a new `--grade-turns` mode in TestHarness (replays a multi-turn transcript with real accumulated history, unlike `--grade` which sends each answer independently). All three reported transcripts now grade on the first turn; a regression check confirmed a genuinely wrong answer on meaning-to-reading still gets nudged rather than immediately scored.
