Run these two commands from the project root and read both outputs before doing anything else:

```bash
node .claude/scripts/get-vocab.mjs
```

```bash
node .claude/scripts/get-quiz-history.mjs --days 30
```

**Step 1 — Select words to quiz**

From the vocab list, only consider items where `matchCount === 1` (items with 0 or 2+ matches are broken and can't be quizzed). Pick 5–10 words to review using this priority order:
1. Never quizzed (not in quiz history at all)
2. Quizzed longest ago (`daysSinceLastReview` highest)
3. Lowest `averageScore` (most struggled with)
4. Spread across different source files if possible

**Step 2 — Create the quiz**

For each selected word, create one question. Vary the question type to make the quiz interesting:
- Reading quiz: show kanji, ask for the reading (kana)
- Meaning quiz: show kanji+kana, ask for the English meaning
- Production quiz: show English meaning, ask which kanji/kana form is correct

For multiple-choice questions, provide exactly 4 options (A–D) with one correct answer. Choose distractors thoughtfully — draw from other words in the vocab list, semantically similar words, words with similar readings or kanji, or whatever would make a pedagogically useful distractor. Don't make distractors obviously wrong.

Present all questions at once and wait for the user's answers before grading.

**Step 3 — Grade and record**

After the user answers, grade each question (score 0.0–1.0). Award partial credit for close answers. Write a brief note about what the user got right or wrong.

Then, for each quizzed word, run:

```bash
node .claude/scripts/record-review.mjs \
  --word-id WORD_ID \
  --word-text "WORD_TEXT" \
  --score SCORE \
  --notes "NOTES"
```

Run one command per word. The `--reviewer` flag is optional and defaults to the OS username; pass it explicitly if needed (e.g. `--reviewer roommate`).

Do not ask the user to confirm before recording — record all results immediately after grading.
