# Claude instructions for llm-review

See `README.md` for a full project overview. The bulk of this repo is now the iOS app (Pug).
Node.js scripts in `.claude/scripts/` still exist for the CLI quiz skill and vocab checking,
but most development happens in `Pug/`. Claude never writes directly to SQLite and never
writes to the user's Markdown content.

## Documentation upkeep

When implementing any new feature or making a non-trivial change, always check
whether `README.md`, `App.md`, `TESTING.md`, and any relevant `.claude/commands/*.md`
skill prompts need updating.

Do this as part of the same task, not as a separate follow-up.

## Writing style

Avoid opaque abbreviations in code comments, documentation, and commit messages.
Write out full names like `reading-to-meaning`, `multiple choice`, and
`kanji-to-reading` instead of shorthand like `rtm`, `MCQ`, or `ktr`. This project
aims to be accessible to beginners and non-native English speakers.

---

## iOS SwiftUI architecture rules (Pug app)

### Environment vs explicit props

**Observable shared data → SwiftUI environment.**
`VocabCorpus`, `GrammarStore` (wrapping `GrammarManifest?`), and `CorpusStore`
(wrapping `[CorpusEntry]`) are injected at `AppRootView` via `.environment()` and
read with `@Environment` at the leaf views that need them. Do not thread these as
explicit `let` props through intermediate views.

**Service objects with side effects → explicit props.**
`db: QuizDB`, `client: AnthropicClient`, `toolHandler: ToolHandler?`, and
`jmdict: any DatabaseReader` stay as explicit parameters. They are infrastructure,
not shared data, and keeping them explicit makes it obvious which views perform
I/O or API calls.

**Before adding a new parameter to any view, ask:**
- Will this need to reach leaf views several layers down? If yes, prefer environment.
- Does it have side effects (database writes, network calls)? If yes, keep it explicit.

---

## iOS quiz architecture (Pug app)

### Four facets

| Facet | Prompt shows | Student produces |
|---|---|---|
| `reading-to-meaning` | kana only (kanji withheld) | English meaning |
| `meaning-to-reading` | English meaning | kana reading |
| `kanji-to-reading` | word with committed kanji shown, uncommitted kanji replaced by kana | kana reading |
| `meaning-reading-to-kanji` | English + kana | kanji written form |

The last two facets **only exist** for words where the user has committed to learning kanji (via `word_commitment.kanji_chars`).

### Word commitment & partial kanji

When a user commits to a word, they choose:
1. A specific **furigana form** (e.g. 入り込む vs 這入り込む) stored in `word_commitment.furigana`.
2. Which **kanji characters** to learn, stored in `word_commitment.kanji_chars` — may be a subset of the word's kanji (partial commitment).

Partial commitment affects kanji facet quizzes: only committed kanji are tested. For example, if 前例 has `kanji_chars=["前"]`, kanji-to-reading shows `前れい` (only 前 is hidden), not `ぜんれい`.

### Multiple choice vs free-answer

All facets start as multiple choice and graduate to free-answer once the facet has ≥ 3 reviews **and** halflife ≥ 48 hours. The one exception: `meaning-reading-to-kanji` is **always** multiple choice (never free-answer).

### Who generates and grades

- **Multiple choice**: LLM generates the question (stem + 4 choices + correct index as JSON). App scores instantly (1.0/0.0). LLM then discusses the result in a chat turn but does not emit SCORE.
- **Free-answer**: App builds the question stem locally (no LLM call). Student types answer. LLM grades and emits `SCORE: X.X` (Bayesian confidence 0.0–1.0, not percentage-correct).
- **Tool usage**: reading-to-meaning and meaning-to-reading need **no tools** (LLM writes distractors from its own knowledge). kanji-to-reading uses `lookup_kanjidic`; meaning-reading-to-kanji uses `lookup_jmdict`.

### Prompt variations

Each unique combination of **facet × question format × kanji commitment level** produces a distinct system prompt. The TestHarness `--dump-prompts` mode iterates all of them.

| Word type | Variations | Breakdown |
|---|---|---|
| Kana-only | 4 | 2 facets × (multiple choice + free) |
| 1 committed kanji | 7 | + kanji-to-reading full (multiple choice + free) + meaning-reading-to-kanji full (multiple choice only) |
| 2+ committed kanji | 10 | + kanji-to-reading partial (multiple choice + free) + meaning-reading-to-kanji partial (multiple choice only) |

### Testing

See `TESTING.md` for TestHarness usage (`--dump-prompts`, `--live`, `--grade`).

---

## Grammar quiz architecture (Pug app)

### Data sources and equivalence groups

- **Three sources**: Genki (~123 topics), Bunpro (~943), DBJG (~370). All topic IDs are source-prefixed: `genki:potential-verbs`, `bunpro:られる-Potential`, `dbjg:rareru2`.
- **Equivalence groups**: Topics across sources covering the same grammar point are clustered in `grammar/grammar-equivalences.json`. Each group has a shared `summary`, `subUses` list, and `cautions` list (generated via `/cluster-grammar-topics` skill). `stub: true` marks groups with no user-annotated content sentences.
- **`grammar.json`**: personal per-user publish artifact (parallel to `vocab.json`), produced by `prepare-publish.mjs`. The iOS app fetches both `grammar.json` and `grammar/grammar-equivalences.json` (descriptions are generic and repo-committed, not personal).

### Enrollment and scheduling

- **Enrollment is equivalence-group-wide**: enrolling any topic creates `ebisu_models` rows for all siblings × both facets (`word_type='grammar'`). Uses existing `ebisu_models` and `reviews` tables.
- **Ebisu propagation at write time**: after reviewing one topic, all sibling rows that already exist in `ebisu_models` are updated with the same score.
- **`GrammarQuizContext.build()`**: ranks enrolled topics by recall probability, collapses equivalence groups (one representative per group per facet, lowest recall wins), selects 3–5 from the top-10 pool.

### Facets and tiers (only Tier 1 is active in the iOS app; higher tiers implemented in GrammarQuizSession but gated by review-count/halflife thresholds set absurdly high)

| Facet | Prompt shows | Student produces |
|---|---|---|
| `production` | English context sentence | Japanese using the target grammar |
| `recognition` | Japanese sentence | English meaning |

- **Tier 1** (current): always multiple choice. LLM generates stem + 4 choices + correct index as JSON; app scores instantly (1.0/0.0). LLM then coaches in a chat turn.
- **Tier 2 production**: fill-in-the-blank (cloze). Fast-path pure-Swift string match; fallback Haiku coaching if match fails.
- **Tier 3 production / Tier 2 recognition**: free-text, LLM-graded with `SCORE: X.X`.

### Sub-use diversity

- Each question generation call includes `recentNotes` (last 3 `reviews.notes` entries for that topic+facet) and instructs Haiku to target a different sub-use. The LLM response includes `"sub_use"` (JSON) or `SUB_USE:` (free-text) identifying which sub-use was exercised; this is stored in `reviews.notes`.

### Assumed vocabulary ("Show vocabulary" button)

- After generating a tier-1 question, a separate async Haiku call identifies N4-unfamiliar content words in the stem sentence. Each word is resolved against JMDict (`findExact`); JMDict's gloss is used when available, Haiku's gloss as fallback.
