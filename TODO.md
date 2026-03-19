# TODO

- [ ] `ebisu_models` currently lacks a review count column, so `get-quiz-context.mjs` must join on the `reviews` table to compute the `free` flag. Eventually add a `review_count INTEGER NOT NULL DEFAULT 0` column to `ebisu_models` (incremented by `record-review.mjs`) to eliminate that join — especially important if the reviews table grows large or the script is ported to a constrained runtime.
- [ ] how will get-kanji-info.mjs handle radicals that aren't in kanjidic2 like ｜ 亅?
- [ ] How hard would it be to use macOS dictionary support?
- [ ] Some want to see the sentence it was used in when you quiz them on a word for the first time. And other example sentences.

## Per-user quiz preferences (design question)

A real multi-user system needs a proper preferences store
(DB table or per-user config). Known preferences that vary critically across users:

- `quiz_style`: varied vs intensive — in iOS app: `UserPreferences` (UserDefaults) + `SettingsView`; passive facet update logic in `QuizSession.recordReview`. Still only via `MEMORY.md` in the Claude Code skill.
- `recall_asymmetry`: how much to weight production (`meaning-to-reading`) vs
  recognition (`reading-to-meaning`). Currently noted in `MEMORY.md` but not
  referenced in `quiz.md` Step 2 word-selection logic.
- `confuser_strategy`: group semantically similar/confusable words together in a
  session (stress discrimination) vs keep them apart (avoid frustration). No
  guidance in `quiz.md` yet.
- `first-time context`: show the source sentence when quizzing a word for the
  first time.
- Others anticipated: preferred session length, kanji vs kana weighting, tolerance
  for never-reviewed words in a session, etc.

## Future quiz types

- [ ] Grammar points (`word_type = 'grammar'`, `quiz_type = 'conjugation'` / `'usage'`)
- [ ] Sentence translation (`word_type = 'sentence'`, `quiz_type = 'translation'`)
- [ ] `--reviewer` flag wired up to the `/quiz` skill via `$ARGUMENTS`


## App todo
- [ ] extra definitions per word table+tool
- [ ] When the spinner is shown (generating question), it might be nice to show what's happening (because I think this happens when Claude is calling tools?)
- [ ] consider adding mnemonics for KOMU or KAKARU and other prefix/suffix vocab/grammar?

- [x] prefix/suffix strip in production
- [x] tool use for mnemonic in grammar quizzes
- [x] "no idea" vs "inkling" should both engage
- [x] any time the autograder is wrong it should give you the right answer
- [x] furigana for grammar items
- [x] maybe play audio
- [ ] mark sentence/quiz as favorite (to export later)