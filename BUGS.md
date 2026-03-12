# Quiz Prompt Bugs

Found via `TestHarness --live 1394190` (前例, 2-kanji word, all 10 paths).

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
