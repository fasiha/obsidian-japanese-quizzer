# TODO

- [ ] `ebisu_models` currently lacks a review count column, so `get-quiz-context.mjs` must join on the `reviews` table to compute the `free` flag. Eventually add a `review_count INTEGER NOT NULL DEFAULT 0` column to `ebisu_models` (incremented by `record-review.mjs`) to eliminate that join — especially important if the reviews table grows large or the script is ported to a constrained runtime.
- [ ] how will get-kanji-info.mjs handle radicals that aren't in kanjidic2 like ｜ 亅?
- [ ] How hard would it be to use macOS dictionary support?
- [ ] clarify/document the `{kanji}` opt-in system: words without `{kanji}` are never asked kanji-type questions; consider whether to surface this to the user during the session when a word could have kanji study added.
- [ ] Some want to see the sentence it was used in when you quiz them on a word for the first time. And other example sentences.
- [ ] Should the quizzer update facets that it didn't ask for but that the student correctly answers…?
- [ ] `/quiz` skill: let user declare strength of a new item mid-session (e.g. "I already know this one well") and have the skill adjust score/question type accordingly instead of always defaulting to multiple choice for never-reviewed words.

## Question integrity validation (real-app architecture)

In the Claude Code skill, the pre-question self-check runs in the same session that
generated the question — the model knows the answer while validating, which creates
confirmation bias (same reason humans miss their own typos). A real Node.js app can
do better with a two-call pattern:

```
generateQuestion(word, facet)          → candidateQuestion   # Sonnet/Haiku
validateQuestion(word, facet, candidate) → { valid, issue }  # Haiku, fresh context
if (!valid) regenerate or patch
```

The validator call is tiny (~200 tokens in, ~50 out) and receives no conversation
history — it evaluates cold whether the answer form is visible in the stem. Near-zero
cost, and architecturally cleaner than self-validation. This is a concrete forcing
function for migrating to a proper app.

## Per-user quiz preferences (design question)

Currently per-user preferences live ad-hoc in `MEMORY.md` (Claude Code only) or
hardcoded in `quiz.md`. A real multi-user system needs a proper preferences store
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

Open question: when migrating to a web app, these should be a `user_preferences`
table (or per-user JSON config), not free-text in a memory file.

## Vocab enrichment skill (`/enrich-vocab` or similar)

Currently vocab in Obsidian reflects only words *I* don't know — curated for a single
reader. For the iOS app to serve a wider audience, the Markdown files need comprehensive
vocabulary coverage: words even beginner readers might not know, not just the author's
personal gaps.

A new Claude Code skill should:
- Read a story Markdown file sentence by sentence
- Identify words a beginner–intermediate learner (N5–N3) might not know
- Cross-check each candidate against JMdict (via `findExact`) to get canonical forms
- Propose additions to the file's `<details><summary>Vocab</summary>` block, in the
  existing bullet format (`- 怒鳴る どなる` etc.), skipping words already present
- Output a diff-style preview for the author to accept/edit/reject before writing

Design questions:
- Should it propose vocab per-sentence (preserving locality) or globally per-file?
- How to handle words that are in JMdict but have multiple senses — propose the most
  contextually relevant meaning, or list all?
- Grammar points (verb forms, particles, expressions) are out of scope for now but the
  skill should be designed so they can be added later without restructuring the file format.

This skill is the authoring counterpart to the app's learner-side enrollment model.

## Future quiz types

- [ ] Grammar points (`word_type = 'grammar'`, `quiz_type = 'conjugation'` / `'usage'`)
- [ ] Sentence translation (`word_type = 'sentence'`, `quiz_type = 'translation'`)
- [ ] `--reviewer` flag wired up to the `/quiz` skill via `$ARGUMENTS`


## App todo
- [ ] extra definitions per word table+tool
- [x] practicing kanji-to-reading shouldn't passively updating reading<->meaning and reading-meaning-to-kanji, since meaning might not be exercised. Consider adding a meaning facet after kanji-to-reading?
- [x] if user's first chat message after quiz involves a mnemonic, nothing gets shown in the first chat bubble from 
- [ ] When the spinner is shown (generating question), it might be nice to show what's happening (because I think this happens when Claude is calling tools?)
- [ ] consider adding mnemonics for KOMU or KAKARU and other prefix/suffix vocab/grammar?

## Prompt review findings (2026-03-11)

### Path inventory

| # | Path | System prompt | Tools | Who scores |
|---|------|--------------|-------|-----------|
| 1 | **Multiple choice generation** | `systemPrompt(isGenerating:true)` | facet-dependent (0–2) | app |
| 2 | **Multiple choice post-tap chat** | `systemPrompt(isGenerating:false)` + `multipleChoiceResult` | all 5 | app already did |
| 3 | **Free-answer grading** (opening turn) | `systemPrompt(isGenerating:false, isFreeAnswer)` | all 5 | Claude via SCORE |
| 4 | **Follow-up chat** (any subsequent turn) | same system prompt as 2 or 3 | all 5 | already graded |
| 5 | **Item selection** | none (user prompt only) | none | n/a |
| 6 | **WordExploreSession** | separate tutor prompt | all 5 | n/a |

### Issues

- [x] **kanji-to-reading distractor tool mismatch**: split distractor instructions per facet — kanji-to-reading now references `lookup_kanjidic`, meaning-reading-to-kanji references both tools.
- [x] **TestHarness stem out of sync**: grade-mode now exits with error for kanji-to-reading/meaning-reading-to-kanji (always multiple choice in app).
- [x] **Full kanji-to-reading: added explicit correct answer**: added `CORRECT ANSWER IS EXACTLY` to full kanji-to-reading generation prompt too (cheap, prevents drift). Removed redundant `!committed.isEmpty` guard (UI prevents it).
- [x] **`{kanji-ok}`/`{no-kanji}` tags removed**: leftover from `quiz.md` skill; removed from system prompt (saves tokens, had no meaning in app context).
- [x] **Dead free-answer generation code**: removed `questionRequest` free-answer branch, `extractQuestion`/`---QUIZ---` sentinel, `validateQuestion`, `skipValidation`, and the free-answer validation path from `runGenerationLoop`. Generation loop is now multiple-choice-only.
- [x] **`freeAnswerMinReviews` was 0**: fixed back to 3 (matching App.md).