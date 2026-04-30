# iOS vocabulary quiz architecture (Pug app)

## Checklist for new quiz types

Every new facet or quiz type must satisfy all of the following. Verify each one by smoke-testing before shipping.

### Question and answer display

- [ ] **Question bubble** identifies exactly which question was asked — if the drill has multiple variants (e.g. two cues), the specific one shown to the student must appear in the question bubble, not just a generic label.
- [ ] **"Don't know" / reveal path** preserves the question bubble so the student can see which question they were on. The answer bubble shows only the answer(s) relevant to the specific question asked — not every possible answer for the whole drill.
- [ ] **Answer bubble (graded path)** includes the student's answer and the correct answer for wrong/partial results.

### Notes field (review record)

- [ ] The `notes` string stored on the `reviews` row must be enough to reconstruct the quiz from history without the chat transcript. It must include: which cue/drill was shown, the student's answer(s), and correct/wrong verdict per field.
- [ ] Fast-path (no LLM call) notes are as informative as slow-path notes — the notes field is the only record when no chat is written to `chat.sqlite`.

### Tutor mode

- [ ] **System prompt** tells the model exactly what was asked (the specific cue), what the correct answer is, and what the student answered. It must not say "when the student describes their answer" — the opening message already contains everything.
- [ ] **Opening message** is fully self-contained: cue + student's answer (or "tapped don't know") + correct answer. Claude must be able to respond immediately without asking clarifying questions.
- [ ] **"Don't know" → tutor** works: when the student tapped "don't know" rather than submitting an answer, `lastAnswers` is nil — the opening message must handle this case with a "I had no idea" framing that still includes the cue and correct answer.
- [ ] Tutor session fires with the right `chatContext` so the conversation is linked to the review via `session_id`.

### Passive Ebisu updates

- [ ] Declare which sibling facets receive passive updates (score = 0.5) after an active review of this facet, and why (what information is revealed by the Q+A pair).
- [ ] Passive updates use `item.wordType` and `item.wordId` — verify these are correct for the new quiz type.

### Scheduling and Ebisu rows

- [ ] All Ebisu rows for the new facet are planted at enrollment. If there is an unlock/graduation condition, document the threshold and where it is enforced (enrollment time vs. scheduler time).
- [ ] Any unlock condition is enforced in `QuizContext.build()` at scheduling time, not at question-generation time.

### History and chat linking

- [ ] Reviews appear in the correct detail sheet (`WordDetailSheet`, `TransitivePairDetailSheet`, `GrammarDetailSheet`), queryable by `word_type` and `word_id`.
- [ ] `quiz_type` value is human-readable when displayed in the history list (no raw snake_case that needs translation).
- [ ] `session_id` is set on every review row so `ReviewDetailSheet` can load the post-quiz chat.

### Prefetch parity

- [ ] `prefetchQuestion()` handles the new facet in the same dispatch order as `generateQuestion()`. See the type-dispatch order note in the counter section below.
- [ ] `prefetchQuestion()` does **not** read any session-level mutable state that `generateQuestion()` sets before building the stem (e.g. `counterExampleQueue`, `currentCounterNumber`). Those fields belong to the item currently on-screen. The prefetch runs while that item is still displayed, so reading them gives the wrong item's data. Any state needed to build the next item's stem must be derived directly from the next `QuizItem` and its corpus data, then stored in the `prefetched` tuple and restored when the prefetch is consumed.
- [ ] If the new facet's stem depends on state that `generateQuestion()` normally sets (a shuffled queue, a randomly drawn value, etc.), add that state as a field on the `prefetched` tuple and restore it in the consume block inside `generateQuestion()`. Failing to do this causes the same question to appear twice (prefetch uses current item's state to build next item's stem) and/or wrong grading (grading reads stale state from the previous item).

# Vocab quiz architecture

## Four facets

| Facet | Prompt shows | Student produces |
|---|---|---|
| `reading-to-meaning` | kana only (kanji withheld) | English meaning |
| `meaning-to-reading` | English meaning | kana reading |
| `kanji-to-reading` | word with committed kanji shown, uncommitted kanji replaced by kana | kana reading |
| `meaning-reading-to-kanji` | English + kana | kanji written form |

The last two facets **only exist** for words where the user has committed to learning kanji (via `word_commitment.kanji_chars`).

## Substitution-based distractor generation (meaning-reading-to-kanji and kanji-to-reading)

Both facets use a **substitution-based strategy** rather than asking the LLM to produce full distractor strings:

1. **App builds the stem locally** — no LLM call for the stem.
   - *Meaning-reading-to-kanji*: `meaningReadingToKanjiStem()` picks a random corpus-attested sense, joins all glosses with "; ", then appends the kana reading.
   - *Kanji-to-reading*: stem is built inline as "What is the reading for: \(displayForm)?".

2. **LLM fills substitution slots only**: The prompt pre-populates an array of slots, one per kanji position to vary. The LLM returns **only** the replacements, not full distractor strings.
   - *Meaning-reading-to-kanji*: slots are `[kanji, "?"]` — the LLM provides a visually-similar or same-reading replacement kanji.
   - *Kanji-to-reading*: slots are `[correct-segment-reading, "?"]` — the LLM provides a wrong kana reading for that segment. Showing the correct segment reading (e.g. "おこ" rather than the kanji 怒) is essential: without it the LLM cannot tell where the kanji reading ends and the okurigana begins, and produces full-word replacements that double up the okurigana when spliced in.

3. **Swift parser reconstructs distractors**: applies each substitution to build a full distractor string, then validates against a `seen` set seeded with all forbidden forms.
   - *Meaning-reading-to-kanji* (`parseMeaningReadingToKanjiSubstitutions`): `seen` is seeded with all of the word's known written forms so no valid orthography appears as a distractor.
   - *Kanji-to-reading* (`parseKanjiToReadingMoraSubstitutions`): `seen` is seeded with `kanaTexts` (all readings of this JMDict entry) **plus** `siblingKanaReadings` (readings of every other enrolled word that shares the exact same written form, e.g. 怒る/いかる when the student is being tested on 怒る/おこる). Matching on the full written form including okurigana prevents false positives: a word 怒らる with different okurigana would not pollute the sibling set.

**Rationale:**

- **Stem consistency**: Fixing the stem prevents students from pattern-matching on a fixed English phrase (meaning-reading-to-kanji) or an inconsistently worded question (kanji-to-reading).
- **Controlled distractors**: Substitution-based generation ensures distractors are always one-segment-difference away from the correct form (pedagogically gradual).
- **Enforcement**: The Swift parser's `seen` set is the ground truth. The system prompt's instructions are a hint to Haiku; the real correctness guarantee lives in the parser.
- **Fallback**: If Haiku violates constraints, the parser rejects that pair and moves to the next. The prompt asks for 4 pairs to provide slack. After a few weeks, check `chat.sqlite` for whether the 4th backup is ever used. If not, consider removing it to save tokens.

## Word commitment & partial kanji

When a user commits to a word, they choose:
1. A specific **furigana form** (e.g. 入り込む vs 這入り込む) stored in `word_commitment.furigana`.
2. Which **kanji characters** to learn, stored in `word_commitment.kanji_chars` — may be a subset of the word's kanji (partial commitment).

Partial commitment affects kanji facet quizzes: only committed kanji are tested. For example, if 前例 has `kanji_chars=["前"]`, kanji-to-reading shows `前れい` (only 前 is hidden), not `ぜんれい`.

## Multiple choice vs free-answer

All facets start as multiple choice and graduate to free-answer once the facet has ≥ 3 reviews **and** halflife ≥ 48 hours. The one exception: `meaning-reading-to-kanji` is **always** multiple choice (never free-answer).

## Who generates and grades

- **Multiple choice**: LLM generates the question, or the app builds it locally if conditions allow (see below). App scores instantly (1.0/0.0). LLM then discusses the result in a chat turn but does not emit SCORE.
  - *reading-to-meaning / meaning-to-reading*: LLM returns a full JSON object `{stem, choices}`.
  - *kanji-to-reading / meaning-reading-to-kanji*: substitution-based — LLM fills replacement slots only; the app reconstructs the full question and distractors locally (see **Substitution-based distractor generation** above).
- **Free-answer**: App builds the question stem locally (no LLM call). Student types answer. LLM grades and emits `SCORE: X.X` (Bayesian confidence 0.0–1.0, not percentage-correct).
- **Tool usage**: No facet uses tools. reading-to-meaning and meaning-to-reading draw distractors from the corpus of enrolled words (or LLM knowledge as fallback). kanji-to-reading and meaning-reading-to-kanji use substitution prompts with no tool calls.

## Distractor source: documents vs. AI

**Motivation:** Some learners want to drill only the words they've committed to learning. Document-based distractors ensure all 4 choices (correct answer + 3 distractors) are enrolled words drawn from the same corpus texts the student is reading. This eliminates distracting interference from unenrolled words or vaguely familiar words from other sources.

**Two modes:**

1. **Documents mode** (`DistractorSource.documents`): For `reading-to-meaning` and `meaning-to-reading` facets, the app builds multiple-choice questions locally from enrolled words that appear in the same documents as the quiz word.

2. **AI mode** (default): The LLM generates distractors using its own knowledge. No document constraints; optimal distraction difficulty chosen by the model.

**App-side generation (documents mode):**

When building a question for `reading-to-meaning` or `meaning-to-reading`, the app:

1. Looks up all enrolled words that appear in the same corpus documents as the quiz word.
2. If fewer than 3 other enrolled words share documents, expands the search to adjacent documents in the story list (±1, ±2, … offsets).
3. If still fewer than 3, gives up and falls back to AI mode.
4. When successful: picks 3 of these enrolled words as distractors, selecting one random corpus-attested sense per candidate word, then one random gloss within that sense (two-stage selection ensures even sense weight). The correct answer uses the same two-stage selection from the quiz word's corpus senses.

**Sense selection strategy:**

Both correct answers and distractors use two-stage random selection: pick one random corpus-attested sense (equal weight per sense), then pick one random gloss string within that sense (equal weight per gloss). This prevents senses with more gloss strings from being over-represented and produces clean, singular answers like "to eat" instead of "to eat, to consume; to live on, to subsist on, …".

## Prompt variations

Each unique combination of **facet × question format × kanji commitment level** produces a distinct system prompt. The TestHarness `--dump-prompts` mode iterates all of them.

| Word type | Variations | Breakdown |
|---|---|---|
| Kana-only | 4 | 2 facets × (multiple choice + free) |
| 1 committed kanji | 7 | + kanji-to-reading full (multiple choice + free) + meaning-reading-to-kanji full (multiple choice only) |
| 2+ committed kanji | 10 | + kanji-to-reading partial (multiple choice + free) + meaning-reading-to-kanji partial (multiple choice only) |

## Prefetching

`QuizSession` (vocabulary quizzes only — grammar quizzes do not prefetch) prefetches the next question in the background while the student reads feedback on the current one. `prefetchQuestion(for:item:)` in `QuizSession.swift` is a **parallel implementation** of `generateQuestion()` and must stay in sync with it.

Critical rule: **the type-dispatch order in `prefetchQuestion` must match `generateQuestion` exactly.** In particular, counter items must be handled before the `isFreeAnswer` check, because counter facets such as `counter-number-to-reading` can have `isFreeAnswer == true` but require their own stem-building logic (`buildCounterNumberStem`). If the `isFreeAnswer` branch runs first, it calls `freeAnswerStem`, which returns `""` for that facet, producing an empty question and a grading failure.

Whenever you add a new word type or facet:
1. Update `generateQuestion()` to handle it.
2. Update `prefetchQuestion()` in the same way, in the same order.
3. Update `freeAnswerStem()` if the facet is free-answer.

## State changes and Ebisu models

Whenever you add a new state-change action in `WordDetailSheet` (reading, kanji, counter, etc.), **always call `await loadEbisuModels()` after the state is persisted**. This ensures the Ebisu halflives section refreshes to show the newly created models without requiring the user to close and reopen the sheet. See `setReadingState()`, `setKanjiState()`, and the counter enrollment picker for examples.

## Testing

See `docs/TESTING.md` for TestHarness usage (`--dump-prompts`, `--live`, `--grade`).

---

# Counter quiz architecture

## Two facets

| Facet | Prompt | Student produces | Grading |
|---|---|---|---|
| `meaning-to-reading` | First example from `countExamples` | Counter reading (kana) | Deterministic: matches `counter.reading` |
| `counter-number-to-reading` | Number from {1, 3, 6, 8, 10} + kanji + reading | Pronunciation after phonetic modification | Deterministic: matches any item in `counter.pronunciations[number].primary` |

Both facets are **free-answer only** — no multiple choice, no LLM grading.

## Counter word_type

Counter items are `word_type="counter"` (not `word_type="jmdict"`), with a stable kana-based `word_id`
derived from the counter's reading and disambiguated by kanji when needed (e.g. `かい-階` for floors vs `かい-回` for occurrences). This avoids Ebisu key collisions when the same JMDict entry serves both
a vocabulary meaning and a counter meaning. See `docs/TODO-counters.md` for the rationale and the
full `counters.json` schema.

## Question generation and grading

- **Question stem**: built on-device without LLM. `meaning-to-reading` shows the first example from `countExamples` (or falls back to `whatItCounts`); `counter-number-to-reading` displays `{number} + {kanji}({kana})` with number drawn at quiz time.
- **Grading**: deterministic string matching. No LLM call. `applyLocalGrade()` records the result to Ebisu immediately.
- **Free-answer input**: `submitFreeAnswer()` checks the student's kana input against the correct reading(s).

---

# Transitive-intransitive pair quiz architecture

## Three facets

| Facet | Prompt shows | Student produces | Score |
|---|---|---|---|
| `pair-discrimination` | Two English cues (intransitive + transitive) | Both dictionary forms | 1.0 / 0.5 / 0.0 |
| `intransitive` | One English cue (intransitive) | Intransitive dictionary form | 1.0 or 0.0 |
| `transitive` | One English cue (transitive) | Transitive dictionary form | 1.0 or 0.0 |

All three facets are free-answer only. No multiple-choice variant.

## Ebisu rows per pair

All three Ebisu rows are planted at enrollment (or by migration v13 for existing pairs). `pair-discrimination` gets the enrollment halflife (24h); `transitive` and `intransitive` inherit the pair-discrimination halflife so they start at the same maturity level.

## Unlock / scheduler suppression

`QuizContext.build()` suppresses `transitive` and `intransitive` from the candidate queue until `pair-discrimination` meets **both** unlock criteria:
- halflife ≥ `singleLegUnlockHalflife` (72h)
- review count ≥ `singleLegUnlockMinReviews` (4)

After unlock, all three facets compete normally; the most-urgent (lowest predicted recall) is scheduled.

## Passive cross-updates

After any pair facet review, sibling facets receive a passive update (score = 0.5):
- `pair-discrimination` → passively updates `transitive` and `intransitive` (both legs revealed in Q+A)
- `transitive` → passively updates `pair-discrimination` (one leg demonstrated)
- `intransitive` → passively updates `pair-discrimination` (one leg demonstrated)
Single-leg facets do **not** passively update each other.

## Grading

**Fast path** (no LLM): string match against kana, any kanji form, or romaji equivalent.

**Slow path** (LLM): when string match fails, one LLM call grades the asked field(s). For `pair-discrimination`, the LLM grades both fields in one call. For single-leg facets, the prompt asks about only the one field.

## Question generation

Questions are built app-side from the `drills` array in `transitive-pairs.json` — no LLM call at question-generation time. A random drill is selected; `PairQuestion.askedLeg` (nil / `.transitive` / `.intransitive`) tells the view and grader which fields to show and evaluate.

## Post-quiz chat and history

Post-quiz coaching chat is available for all three facets (via "Tutor me" on wrong answers). Review history for all three facets appears in `TransitivePairDetailSheet`'s Quiz History section. Tapping any row opens `ReviewDetailSheet`, which loads the post-quiz chat using `review.sessionId`.

---

## Implementation order in generateQuestion() and prefetchQuestion()

Counter items must be detected and routed **before** the `isFreeAnswer` check. This is critical: the free-answer dispatcher assumes it can call `freeAnswerStem()`, which returns `""` for counter facets because their stems are deterministic. If `isFreeAnswer` runs first, it will create a question with an empty stem.

**Type dispatch order** (same in both `generateQuestion()` and `prefetchQuestion()`):
1. Counter items (both facets)
2. Transitive-intransitive pair drills (all three facets: pair-discrimination, transitive, intransitive)
3. Vocabulary items (split by `isFreeAnswer`)
4. Grammar items

## Pronunciation table encoding

Counter pronunciations are stored in `counters.json` as a `pronunciations` object mapping numbers (and "how-many") to structured objects:

```json
"pronunciations": {
  "1": { "primary": ["いっぽん"], "rare": [] },
  "6": { "primary": ["ろっぽん", "ろくほん"], "rare": [] },
  "8": { "primary": ["はっぽん", "はちほん"], "rare": [] }
}
```

Both `primary` readings are equally correct and both grade as 1.0. Rare variants (parenthesized in the Tofugu source) are stored but not accepted as correct answers — they exist for reference and future coach explanations.

## Coaching

When a student answers incorrectly, the "Tutor me" button appears. `counterTutorSystemPrompt()` builds a prompt that explains the counter's meaning (for `meaning-to-reading`) or phonetic modification pattern (for `counter-number-to-reading`). The tutor chat has access to the full toolset (`lookup_jmdict`, `lookup_kanjidic`, etc.) and integrates with the existing quiz chat infrastructure.

---

For more details, see `docs/TODO-counters.md`, which documents the design decisions, data sources, and the work plan.

---

# Grammar quiz architecture

## Two facets, multiple tiers

| Facet | Tier 1 | Tier 2 | Tier 3 |
|---|---|---|---|
| `production` | Multiple choice (4 full sentences) | Fill-in-the-blank (gapped sentence) | Free text (English context) |
| `recognition` | Multiple choice (4 English translations) | Free text (English translation) | — |

**Current shipping scope: Tier 1 only** (both facets, multiple choice). Tiers 2 and 3 are
planned for future releases. See `docs/TODO-grammar.md` for the full roadmap and design
decisions.

## Key architectural concepts

**Equivalence groups:** grammar topics from three databases (Genki, Bunpro, DBJG) are
clustered into equivalence groups in `grammar/grammar-equivalences.json`. When a topic is
reviewed, all its siblings in the group are updated with the same score. This prevents
redundant quizzing of the same grammar point from different sources.

**Generation:** Tier 1 questions are LLM-generated (Haiku) with pure-logic grading (app-side).
Production shows an English context + 4 full Japanese sentences; recognition shows a
Japanese sentence + 4 English translations. Distractors are semantic variants (same
vocabulary/situation, different grammar construction).

**Token efficiency:** Grammar quizzes require at least one LLM call per question generation.
Tier 1 budgets ~1500 tokens per multiple-choice generation. Post-answer discussion (like
vocab) is one additional call.

## Equivalence-group updates and Ebisu propagation

When a student reviews a grammar topic from an equivalence group, the app:
1. Records one `reviews` row for the quizzed topic with the student's score, including
   the `sub_use_index` that was targeted in generation.
2. Updates the topic's `ebisu_models` row with the new recall model
3. **Write-time copy**: updates all sibling rows in the same equivalence group (pure copy of
   the score, no discount). Siblings may have phantom Ebisu models (existing but never
   directly quizzed) — they now reflect the reviewed score.

At quiz scheduling time (`GrammarQuizContext.build()`), equivalence groups are collapsed:
only one representative topic per group is selected to avoid back-to-back quizzing of the
same grammar point. Production and recognition facets remain separate (different skills).

The next sub-use index for that topic+facet is derived from the most recent review's
recorded `sub_use_index`, incremented mod the count of enrolled sub-uses. This ensures
each quiz targets a different sub-use from the group, cycling through the student's
enrolled list.

## Sub-use targeting and enrollment

Each equivalence group specifies a list of **sub-uses** — concrete usage patterns or
contexts for the grammar point, each with a stable ID and a Japanese example. Quiz
generation uses round-robin: for each topic+facet, an internal counter cycles through
the group's sub-uses, ensuring the student sees varied sentence contexts rather than the
same scenario repeatedly.

**User control:** Students can opt out of specific sub-uses within a group via
`grammar_subuse_enrollment` in the quiz database. When a quiz is generated, the system:
1. Looks up which sub-uses the user has opted out of for this equivalence group.
2. Filters the list to only enrolled (opted-in) sub-uses.
3. Cycles through the enrolled subset for round-robin targeting.

If a user opts out of all sub-uses, the system falls back to the full list (treating
opt-out as advisory). New sub-uses added to `grammar-equivalences.json` are
automatically enrolled — the user must explicitly opt out if they wish to exclude them.

**In the prompt:** For generation calls (not grading), the system appends:
`\nTarget this specific sub-use: [Japanese example from the sub-use text]`

This guides Haiku to produce a sentence exemplifying that particular sub-use, improving
variety and semantic coverage.

## Multiple-choice generation format

Tier 1 production/recognition use a 4-step chain-of-thought in the generation prompt:

**Production:**
1. English stem (concrete situation)
2. Correct Japanese sentence using target grammar
3. Three distractors (same words/situation, different grammar form)
4. Self-check: does each distractor express a different meaning? (verifying distractors
   don't accidentally match the English stem)

**Recognition:**
1. Japanese sentence using target grammar
2. Correct English translation
3. Three distractor translations (natural English, not grammar labels — testing comprehension)
4. Self-check: is no distractor close enough to the correct answer?

---

For the complete grammar quiz design including tiers 2 & 3, open items, prompt
engineering, and alternatives considered, see `docs/TODO-grammar.md`.

## Quiz history in detail sheets

Every detail sheet — `WordDetailSheet`, `TransitivePairDetailSheet`, and
`GrammarDetailSheet` — shows a **Quiz History** section at the bottom listing all past
reviews for the item, newest first. Tapping any row opens `ReviewDetailSheet` where the
student can read the full question and answer and continue a chat about it.

**Word and counter quizzes** (`WordDetailSheet`): reviews are fetched for both
`word_type="jmdict"` (the vocabulary word) and `word_type="counter"` (any counter nouns
linked to the same JMDict entry), merged and sorted by timestamp. Counter IDs are
reading strings like `し`; JMDict IDs are numeric strings.

**Transitive pair quizzes** (`TransitivePairDetailSheet`): reviews are fetched for
`word_type="transitive-pair"` using the pair's string ID. The query returns rows for all
three quiz types (`pair-discrimination`, `transitive`, `intransitive`) together, sorted by
timestamp. The `quiz_type` column is displayed verbatim in the history list.

**Grammar quizzes** (`GrammarDetailSheet`): reviews are fetched across all topics in
the equivalence group (e.g. `genki:naru-to-become` and `bunpro:naru-to-become` together)
using `word_type="grammar"`.

### Per-attempt chat linking

Each quiz review row is linked to its post-quiz chat via `session_id`:
- Vocab, counter, and transitive-pair reviews have had `session_id` since the feature was
  introduced (migration v11).
- Grammar reviews gained `session_id` in April 2026. Legacy grammar reviews without a
  `session_id` fall back to the topic-level `grammar:<topicId>` chat context when
  `ReviewDetailSheet` opens.

The `session_id` on the review row matches the `context` column suffix in `chat.sqlite`:
- Vocab/counter/pair: `quiz:<wordId>:<facet>:<sessionId>`
- Grammar: `quiz:<topicId>:<facet>:<sessionId>`

### HistoryView

`HistoryView` shows all recent reviews across all word types as a flat list. Tapping any
row opens `ReviewDetailSheet`. There is no inline chat expansion in the list — the detail
sheet is the single place to read and continue a post-quiz chat.
