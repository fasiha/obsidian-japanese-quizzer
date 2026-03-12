# Quiz Prompt Bugs

Found via `TestHarness --live 1394190` (前例, 2-kanji word, all 10 paths).

---

## Open bugs

### [ ] kanji-to-reading full commitment: distractor ぜんし violates length constraint
Prompt says "Keep the same length and rhythm as the correct answer." Correct answer ぜんれい is 4 kana; model generated ぜんし (3 kana) as a distractor. The other two distractors were correctly 4 kana. This is model misbehavior — the constraint was stated but not followed. No fix needed in code; the constraint wording is already correct.

### [ ] kanji-to-reading partial multiple-choice generation: reasoning error on voiced reading

In PATH 6 (前例, partial commitment, multiple choice), Haiku's chain-of-thought said: *"Current reading of 前: せん (from ぜんれい)"* — wrong; the reading is **ぜん**. It self-corrected two lines later and produced correct output, but the reasoning error is a fragility: for words where the model doesn't self-correct, distractors could substitute the wrong mora.

**No output bug observed.** Possible fix: explicitly state the committed kanji's current reading in the partial prompt (e.g. "前 is read ぜん in this word"). Not yet implemented.

### [ ] reading-to-meaning multiple choice: distractor semantically too close to correct answer

For 前例 (precedent), distractor **"example"** was included. Since 前例 contains 例 (example/instance) and "prior example" is a valid gloss, a student who picks "example" may be showing partial knowledge rather than ignorance. One of the four choices is less discriminating than intended.

**Possible fix:** Add to the distractor instruction: "Avoid distractors that are partial synonyms or sub-concepts of the correct answer." Not yet implemented — assess frequency in practice first.

### [ ] Meaning boost token not detected in some contexts
Grader says "✅ Meaning knowledge noted" but `MEANING_DEMONSTRATED` was apparently not
in the raw response. May be a model reliability issue (token not emitted) or a stripping
bug in `strippingMetadata`.

### [ ] Score not sent / sent incorrectly formatted in open chat
Model failed to emit `SCORE:` at all across several turns, even when prompted. May be
related to inconsistent format, or a separate issue with the multiple-choice result line
suppressing the grading path.
