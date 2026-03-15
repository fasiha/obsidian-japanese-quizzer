# Test harness (`TestHarness/`)

A macOS command-line Swift binary that exercises `QuizSession` with real API calls,
without running the iOS simulator. Useful for iterating on system prompts and spotting
regressions before shipping.

**Build & run** (from `Pug/TestHarness/`):
```sh
swift build

# Generate a multiple-choice question (calls Claude API):
.build/debug/TestHarness <word_id> [facet]
# facet defaults to reading-to-meaning
# e.g.: .build/debug/TestHarness 1314010 meaning-to-reading

# Grade free-text answers (calls Claude API):
.build/debug/TestHarness <word_id> [facet] --grade "answer1" "answer2"
# e.g.: .build/debug/TestHarness 1358340 meaning-to-reading --grade "たべもの" "tabemono"

# Dump all system prompts for every quiz path (NO API calls):
.build/debug/TestHarness <word_id> --dump-prompts
# Pipe to an LLM for sanity-checking prompt correctness

# Live test: send all paths to Haiku and validate responses:
.build/debug/TestHarness <word_id> --live

# Live test restricted to one facet, repeated N times (for prompt iteration):
.build/debug/TestHarness <word_id> --live --facet meaning-to-reading --repeat 3 --gen-only
```

**Modes**:
- **generate** (default): builds a `QuizItem`, calls `generateQuestionForTesting()`, prints the multiple-choice question. Only supports reading-to-meaning and meaning-to-reading facets (kanji-to-reading/meaning-reading-to-kanji require kanji commitment data not available in the harness).
- **grade**: builds the app-side free-answer stem, then calls `gradeAnswerForTesting()` for each answer. Same facet restrictions as generate.
- **dump-prompts**: iterates a triple loop over **facet × mode × commitment** and prints every system prompt + user message. Covers all 4–10 paths depending on word shape. No API key needed. Requires `JmdictFurigana.json` (see below).
- **live**: sends all prompt paths to Haiku (or `ANTHROPIC_MODEL`) and validates responses automatically — checks for answer leakage, correct-answer accuracy, SCORE parsing, and A/B/C/D contamination. Requires API key and `JmdictFurigana.json`. Flags: `--facet <name>` restricts the run to a single facet (omit for all); `--repeat N` repeats each generation path N times; `--gen-only` skips free-text grading paths.

**Dump-prompts path coverage** (facet × mode × commitment):

| Word type | Paths | Example |
|-----------|-------|---------|
| No kanji | 4 | reading-to-meaning / meaning-to-reading × multiple-choice/free |
| 1 kanji | 7 | + kanji-to-reading full multiple-choice/free + meaning-reading-to-kanji full multiple-choice |
| 2+ kanji | 10 | + kanji-to-reading/meaning-reading-to-kanji partial multiple-choice + kanji-to-reading partial free |

Skip rules enforced in the loop:
- kanji-to-reading / meaning-reading-to-kanji require kanji commitment (skip "none")
- reading-to-meaning / meaning-to-reading don't use commitment (skip "full"/"partial")
- meaning-reading-to-kanji is always multiple choice (skip "free-grading")

**Reference word IDs** for testing:

| ID | Word | Kanji | Notes |
|----|------|-------|-------|
| 1394190 | 前例 ぜんれい | 前, 例 | 2 kanji → all 10 paths |
| 1358340 | 食べ物 たべもの | 食, 物 | 2 kanji + okurigana |
| 1463770 | 日 ひ | 日 | 1 kanji → 7 paths |
| 1002430 | お茶 おちゃ | 茶 | 1 kanji (prefix kana) |
| 1006810 | そっと | (none) | kana-only → 4 paths |
| 2028920 | は | (none) | particle, kana-only → 4 paths |
| 2272660 | 感慨深い かんがいぶかい | several | unusual word |

**Required data files** (searched by walking up from cwd):
- `jmdict.sqlite` — always required
- `JmdictFurigana.json` — required for `--dump-prompts` and `--live` modes; provides real furigana segmentation so partial-kanji templates match iOS app behavior (e.g. `前れい` not `前〇`). Download from [JmdictFurigana releases](https://github.com/Doublevil/JmdictFurigana/releases).
- `kanjidic2.sqlite` — optional; needed for `--live` mode kanji-to-reading/meaning-reading-to-kanji tool calls
- `quiz.sqlite` — optional; used for telemetry logging so test runs appear in `telemetry-report.mjs` output
- `ANTHROPIC_API_KEY` in `.env` — required for generate, grade, and live modes (not dump-prompts)

**Entry point added to `QuizSession`**: `generateQuestionForTesting(item:)` and
`gradeAnswerForTesting(item:stem:answer:)` are `internal` methods that bypass the phase
state machine. Helpers (`systemPrompt`, `questionRequest`, `freeAnswerStem`,
`runGenerationLoop`) were de-privatised to `internal` to support this. `QuizDB` gained a
`static func open(path:)` factory for arbitrary file paths (vs `makeDefault()` which
uses the iOS Documents directory).

---

## Grammar quiz testing (`--grammar <topic_id>`)

Grammar quizzes use `GrammarQuizSession` (parallel to `QuizSession` for vocab).
Pass `--grammar <topic_id>` as the first argument instead of a word ID.

```sh
# Generate a multiple-choice question for a grammar topic:
.build/debug/TestHarness --grammar genki:potential-verbs [--facet production]
# facet defaults to "production"; other option: "recognition"

# Dump all system prompts for every grammar path (NO API calls):
.build/debug/TestHarness --grammar genki:potential-verbs --dump-prompts

# Live test: send all grammar paths to Haiku and validate responses:
.build/debug/TestHarness --grammar genki:potential-verbs --live

# Live test restricted to one facet, repeated N times:
.build/debug/TestHarness --grammar genki:potential-verbs --live --facet production --repeat 3
```

**Grammar path coverage** (facet × mode):

| Paths | Description |
|-------|-------------|
| 2 | production + recognition × multiple-choice-generation (Phase 1A) |
| 2 | production + recognition × free-grading (Phase 1B preview) |

**Required additional file** (searched by walking up from cwd):
- `grammar.json` — required for grammar mode; run `node prepare-publish.mjs` to generate it.

**Reference grammar topic IDs** (from current `grammar.json`):

| Topic ID | Title | Level |
|----------|-------|-------|
| `genki:potential-verbs` | Potential verbs | Genki II |
| `bunpro:causative` | To make/let/have | JLPT N4 |
| `bunpro:Verb[passive]` | Was done to ~ by ~ | JLPT N4 |
| `bunpro:てならない` | Very, Extremely | JLPT N2 |

**Validation checks** (live mode):
- production: stem contains no Japanese characters (English only)
- recognition: stem contains Japanese characters
- free-grading: response contains `SCORE:` token; correct answer scores ≥ 0.8
