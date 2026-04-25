# iOS vocabulary quiz architecture (Pug app)

## Four facets

| Facet | Prompt shows | Student produces |
|---|---|---|
| `reading-to-meaning` | kana only (kanji withheld) | English meaning |
| `meaning-to-reading` | English meaning | kana reading |
| `kanji-to-reading` | word with committed kanji shown, uncommitted kanji replaced by kana | kana reading |
| `meaning-reading-to-kanji` | English + kana | kanji written form |

The last two facets **only exist** for words where the user has committed to learning kanji (via `word_commitment.kanji_chars`).

## Word commitment & partial kanji

When a user commits to a word, they choose:
1. A specific **furigana form** (e.g. 入り込む vs 這入り込む) stored in `word_commitment.furigana`.
2. Which **kanji characters** to learn, stored in `word_commitment.kanji_chars` — may be a subset of the word's kanji (partial commitment).

Partial commitment affects kanji facet quizzes: only committed kanji are tested. For example, if 前例 has `kanji_chars=["前"]`, kanji-to-reading shows `前れい` (only 前 is hidden), not `ぜんれい`.

## Multiple choice vs free-answer

All facets start as multiple choice and graduate to free-answer once the facet has ≥ 3 reviews **and** halflife ≥ 48 hours. The one exception: `meaning-reading-to-kanji` is **always** multiple choice (never free-answer).

## Who generates and grades

- **Multiple choice**: LLM generates the question (stem + 4 choices + correct index as JSON), or the app builds it locally if conditions allow (see below). App scores instantly (1.0/0.0). LLM then discusses the result in a chat turn but does not emit SCORE.
- **Free-answer**: App builds the question stem locally (no LLM call). Student types answer. LLM grades and emits `SCORE: X.X` (Bayesian confidence 0.0–1.0, not percentage-correct).
- **Tool usage**: reading-to-meaning and meaning-to-reading need **no tools** (distractors come from the corpus of enrolled words, or from the LLM's own knowledge as fallback). kanji-to-reading uses `lookup_kanjidic`; meaning-reading-to-kanji uses `lookup_jmdict`.

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

## Implementation order in generateQuestion() and prefetchQuestion()

Counter items must be detected and routed **before** the `isFreeAnswer` check. This is critical: the free-answer dispatcher assumes it can call `freeAnswerStem()`, which returns `""` for counter facets because their stems are deterministic. If `isFreeAnswer` runs first, it will create a question with an empty stem.

**Type dispatch order** (same in both `generateQuestion()` and `prefetchQuestion()`):
1. Counter items (both facets)
2. Transitive-intransitive pair drills
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
1. Records one `reviews` row for the quizzed topic with the student's score
2. Updates the topic's `ebisu_models` row with the new recall model
3. **Write-time copy**: updates all sibling rows in the same equivalence group (pure copy of
   the score, no discount). Siblings may have phantom Ebisu models (existing but never
   directly quizzed) — they now reflect the reviewed score.

At quiz scheduling time (`GrammarQuizContext.build()`), equivalence groups are collapsed:
only one representative topic per group is selected to avoid back-to-back quizzing of the
same grammar point. Production and recognition facets remain separate (different skills).

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
`word_type="transitive-pair"` using the pair's string ID.

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
