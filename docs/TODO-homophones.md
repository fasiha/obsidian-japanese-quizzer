# Homophone handling in reading-to-meaning quizzes

## Problem

When multiple enrolled words share the same kana reading (e.g., 奴(め), 目(め), 芽(め)),
the reading-to-meaning question "What does め mean?" is ambiguous. The student cannot know
which word is being tested.

Note: this applies regardless of kanji commitment. Even if the student hasn't committed to
learning kanji for a word, the kana-only quiz becomes unfair when homophones exist.

## Detection

At quiz construction time, query enrolled words to find others sharing any kana reading
with the current word:
- For words with kanji commitment: check other enrolled words' committed readings
  (from `word_commitment` table)
- For kana-only words: check if any other enrolled word has a kana form matching the
  current word's kana

Return a list of homophones with their `word_text`, meanings, and part of speech.
If the list is empty, no changes needed — existing prompts apply as-is.

## Multiple choice (LLM generates stem + choices)

Inject a homophone alert block into the system prompt:

```
⚠️ Homophone alert: the student is also learning these words with the same reading "め":
- 目 (め): eye; vision; experience  [noun]
- 芽 (め): bud; sprout  [noun]

Your question stem MUST disambiguate which word is being asked about WITHOUT revealing
the English meaning. Use a short example sentence, usage context, grammatical role,
or register hint. Do NOT use just the bare kana.
```

The choices remain English meanings as before. The LLM handles disambiguation naturally.

## Free-text (app builds stem, LLM grades)

Currently `freeAnswerStem(for:)` returns `"What does め mean?"` — ambiguous when homophones exist.

**Plan (Option A)**: when homophones are detected, skip the locally-built stem and instead
call the LLM to generate a disambiguated stem before showing the question. This adds one
extra API call, but only for the rare homophone edge case.

The stem-generation call can reuse the multiple choice system prompt (with the homophone
alert block) but ask for a stem only — no choices, no correct index.

The grading prompt also needs the homophone list, plus an explicit instruction:

```
The student is being quizzed on 奴 (め) specifically.
If they give the meaning of a homophone (e.g., "eye" for 目),
score 0.0 — wrong word, even though the reading is the same.
```

## Code changes needed

1. **Homophone query** — new function on `QuizDB` or `QuizContext`: given a word's kana
   readings, return other enrolled words sharing those readings.

2. **`systemPrompt(for:isGenerating:...)`** — accept optional `homophones` parameter;
   inject the alert block when non-empty.

3. **`freeAnswerStem(for:)`** — when homophones are present for reading-to-meaning, signal
   to the caller that LLM generation is needed instead of a local stem.

4. **`QuizSession` phase state machine** — for reading-to-meaning free-text with homophones,
   add a new mini-step: call LLM to generate a disambiguated stem, then show the question
   and await the student's typed answer as usual.
