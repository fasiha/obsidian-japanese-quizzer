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
