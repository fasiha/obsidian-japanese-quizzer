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

- **Multiple choice**: LLM generates the question (stem + 4 choices + correct index as JSON). App scores instantly (1.0/0.0). LLM then discusses the result in a chat turn but does not emit SCORE.
- **Free-answer**: App builds the question stem locally (no LLM call). Student types answer. LLM grades and emits `SCORE: X.X` (Bayesian confidence 0.0–1.0, not percentage-correct).
- **Tool usage**: reading-to-meaning and meaning-to-reading need **no tools** (LLM writes distractors from its own knowledge). kanji-to-reading uses `lookup_kanjidic`; meaning-reading-to-kanji uses `lookup_jmdict`.

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
