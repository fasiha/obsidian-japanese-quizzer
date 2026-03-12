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

## Prompt audit (2026-03-11, word 1394190 前例)

Reviewed all 10 dump-prompts paths. No correctness bugs found — all facet rules,
commitment logic, and stem leak guards are correct. Issues below are token waste
and minor clarity improvements.

- [ ] **1. reading-to-meaning generation: duplicate kana in wordLine** (`QuizSession.swift:930`)
  `Word: kana ぜんれい [Word data: ... kana=ぜんれい ...]` — the bare `kana ぜんれい`
  prefix predates the entry ref and is now redundant. Drop it; the facet rule already
  says "Show kana ONLY." ~5 tokens/prompt.

- [ ] **2. meaning-to-reading generation: `englishHint` duplicates entry ref** (`QuizSession.swift:938`)
  `— English: precedent` repeats `meanings=precedent` from the entry ref.
  Drop `englishHint` from this wordLine. ~5 tokens/prompt.

- [ ] **3. kanji-to-reading full generation: distractor line doesn't name the committed kanji** (`QuizSession.swift:1024`)
  Partial path explicitly says `committed kanji (前)` but full path just says
  "the committed kanji." Minor — Haiku can infer from wordLine, but explicit is
  cheaper for a small model.

- [ ] **4. Free-grading: "never reference A/B/C/D letters" is irrelevant** (`QuizSession.swift:1053`)
  Free-answer mode has no A/B/C/D options. This instruction is leftover from
  shared multiple choice post-answer chat. Remove from the free-grading block. ~8 tokens/prompt.

- [ ] **5. meaning-reading-to-kanji full generation: `writtenHint` + kana duplicate entry ref** (`QuizSession.swift:992`)
  `— written: 前例` and `Stem kana: ぜんれい` both repeat data already in the entry
  ref. Keep the "NEVER in stem" guard but reference the entry ref instead of
  restating the values. ~15 tokens/prompt.

- [ ] **6. Grading rubric compression** (~180 → ~60 tokens)
  The 5-tier scoring block is the largest single element. Could compress to a
  one-line scale. Medium risk — Haiku may need the expanded anchors to score
  accurately. Test before shipping.

- [ ] **7. `set_mnemonic overwrites` on every chat path** (`QuizSession.swift:1055,1066`)
  14 tokens on every prompt, but mnemonics are rarely invoked. Low priority but
  worth noting as a constant tax.

### UX correctness issues

- [ ] **A. Entry ref label lost its guard instruction** (`QuizSession.swift:923`)
  App.md documents the format as `[Entry ref — never copy verbatim into question
  stem: written=X kana=Y meanings=Z]` but the code produces `[Word data: ...]`.
  The documented label embeds a "never copy verbatim" instruction right next to the
  data — an important second line of defense for Haiku. Without it, the only guard
  against e.g. kanji leaking into a reading-to-meaning stem is the facet rule ("Show kana ONLY").

- [ ] **B. Partial kanji-to-reading/meaning-reading-to-kanji free-grading doesn't weight studied vs. context kanji**
  (`QuizSession.swift:958,986`)
  For partial commitment (e.g. studying 前 in 前例), if the student writes ぜんらい
  (前 correct, 例 wrong) vs. まえれい (前 wrong, 例 correct), both get the same
  generic grading. The prompt should tell Claude which mora correspond to the studied
  kanji so it can weight errors on the studied portion more heavily for the Ebisu
  update.

- [ ] **C. "A/B/C/D" mention in free-grading primes a false frame** (same as item 4)
  "Never reference A/B/C/D letters" tells Haiku options exist when they don't.
  On a small model, "don't do X" can prime X. Remove entirely from the free-grading
  block.

