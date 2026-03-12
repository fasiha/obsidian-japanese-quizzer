# Quiz Prompt Bugs

Found via `TestHarness --live 1394190` (前例, 2-kanji word, all 10 paths).

---

## Bugs found 2026-03-12 (via --live 1394190)

### [x] kanji-to-reading full commitment: stem generated in Japanese
System prompt for full-commitment kanji-to-reading generation was missing "Question stem must be in English", unlike the partial-commitment path which had it. Model generated a Japanese-language stem ("次の漢字を読んでください。\n\n前例"). **Fixed** in `QuizSession.swift` by adding the English-stem instruction to the full-commitment facet rule.

### [x] meaning-reading-to-kanji partial commitment: stem is bare data, not a question
Partial-commitment generation prompt told the model what to show and how to constrain distractors, but never said to form a question. Model produced "precedent; ぜんれい" rather than a proper question. Full-commitment path produces "What is the correct kanji form for…?" correctly. **Fixed** in `QuizSession.swift` by adding "Ask which option is the correct kanji form." to the partial facet rule.

### [ ] kanji-to-reading full commitment: distractor ぜんし violates length constraint
Prompt says "Keep the same length and rhythm as the correct answer." Correct answer ぜんれい is 4 kana; model generated ぜんし (3 kana) as a distractor. The other two distractors were correctly 4 kana. This is model misbehavior — the constraint was stated but not followed. No fix needed in code; the constraint wording is already correct.

---

## Pre-existing bugs (carried forward)

### [ ] Meaning boost token not detected in some contexts
Grader says "✅ Meaning knowledge noted" but `MEANING_DEMONSTRATED` was apparently not
in the raw response. May be a model reliability issue (token not emitted) or a stripping
bug in `strippingMetadata`.

### [ ] Score not sent / sent incorrectly formatted in open chat
Model failed to emit `SCORE:` at all across several turns, even when prompted. May be
related to inconsistent format, or a separate issue with the multiple-choice result line
suppressing the grading path.
