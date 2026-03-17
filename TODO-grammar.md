# Grammar feature plan

## Concepts

### Grammar databases
Three sources, each providing topic IDs:
- **Genki** (`grammar-stolaf-genki.tsv`): ~123 topics, slugified IDs like `potential-verbs`
- **Bunpro** (`grammar-bunpro.tsv`): ~943 topics, IDs like `られる-Potential`
- **DBJG** (`grammar-dbjg.tsv`): ~370 entries from Dictionary of Basic Japanese Grammar table of contents (slugified from `grammar-dbjg.md` via `slugify-dbjg.mjs`)

All IDs are prefixed by source in annotations and in the app: `genki:potential-verbs`,
`bunpro:られる-Potential`, `dbjg:rareru2`.

### Equivalence groups
Many topics across databases describe the same grammar (e.g., Genki `potential-verbs`,
Bunpro `られる-Potential`, DBJG `rareru2`). At publish time, an LLM-assisted step
clusters these into equivalence groups. When a quiz updates Ebisu for one topic, all
topics in the same group are updated. This prevents redundant quizzing.

### Markdown annotation
```markdown
<details><summary>Grammar</summary>
- genki:potential-verbs
- dbjg:noni1
</details>
```
Bullets **must** be source-prefixed (`source:id`). Unprefixed IDs are rejected.
Valid prefixes: `genki:`, `bunpro:`, `dbjg:`. Prefix matching is case-insensitive
(`DBJG:` = `dbjg:`). Optionally followed by free-text notes
(e.g., `bunpro:causative in ならせて`). The note is preserved for display but
only the first token (up to first space) is the topic ID used for lookup.

### Quiz facets

| Facet | Prompt shows | Student produces | Status |
|-------|-------------|-----------------|--------|
| `production` | English sentence/context | Japanese using target grammar | Launch facet |
| `recognition` | Japanese sentence | English meaning | Launch facet |
| `error-correction` | Japanese sentence with deliberate grammar mistake | Corrected sentence | Future |
| `sentence-completion` | Beginning of Japanese sentence | Completion using target grammar | Future |

`error-correction` and `sentence-completion` are future variants that may live
within existing facets rather than as independent facets.

### Format tiers

The two facets have different tier progressions:

**Recognition** (Japanese → English): two tiers
| Tier | Format | Generation | Grading |
|------|--------|------------|---------|
| 1. Multiple choice | Pick English meaning from 4 choices | LLM (Haiku) | Pure logic (zero tokens) |
| 2. Free text | Open English translation | LLM (Haiku) | LLM (Haiku) |

**Production** (English → Japanese): three tiers
| Tier | Format | Generation | Grading |
|------|--------|------------|---------|
| 1. Multiple choice | English stem + 4 full Japanese sentences; student taps a button | LLM (Haiku) | Pure logic (zero tokens) |
| 2. Fill-in-the-blank | English stem + gapped Japanese sentence; student types the correct form(s) | LLM (Haiku) | String match, fallback to coaching LLM |
| 3. Free text | Full translation from English prompt | LLM (Haiku) | LLM (Haiku, multi-turn coaching) |

Recognition collapses to two tiers because fill-in-the-blank in a Japanese sentence
is production by another name — it tests supplying the grammar form, not comprehending it.

Graduation thresholds (higher than vocab because grammar production is harder):

| Threshold | Reviews | Halflife |
|-----------|---------|---------|
| Tier 2 (production fill-in-the-blank; recognition free text) | ≥ 3 | ≥ 72 h |
| Tier 3 (production free text) | ≥ 6 | ≥ 120 h |

### Production tiers 1 and 2: format design (decided 2026-03-15)

**Tier 1 (multiple choice):** Haiku generates an English stem describing a concrete
situation, one correct Japanese sentence using the target grammar, and three distractor
sentences that use the same vocabulary/situation but swap in a different grammar form
(e.g. causative instead of potential, passive instead of conditional). The distractors
express different meanings from the English stem because they use the wrong grammar
construction — the student's job is to pick the sentence that correctly matches the
English scenario.

**Tier 2 (fill-in-the-blank):** Haiku generates an English stem and a complete Japanese
sentence, plus only the correct answer substring(s) — the exact form(s) that embody the
target grammar (no distractors). The app creates the gapped display by replacing those
substrings with `___`; the student types the form(s). Grading is string match first; if
that fails, a coaching LLM session guides the student. This is a separate generation call
from tier 1 — the two tiers do not share a question.

JSON format for tier 1:
```json
{"stem": "Yuki practices every day and can now play a difficult Beethoven piece.",
 "sentence": "",
 "choices": [
   ["ユキは毎日練習しているので、今ベートーベンの難しい曲が弾かせるようになりました。"],
   ["ユキは毎日練習しているので、今ベートーベンの難しい曲が弾けるようになりました。"],
   ["ユキは毎日練習しているので、今ベートーベンの難しい曲が弾かれるようになりました。"],
   ["ユキは毎日練習しているので、今ベートーベンの難しい曲が弾くようになりました。"]
 ],
 "correct": 1}
```
`"sentence"` is always empty string for tier 1. Each choice is a 1-element array containing a
complete Japanese sentence. `correct` is randomized 0–3.

JSON format for tier 2:
```json
{"stem": "Your younger brother refuses to clean his room.",
 "sentence": "弟が遊びに行きたいなら、まず部屋を掃除させなければならない。",
 "choices": [["させ"]],
 "correct": 0}
```
`"sentence"` is the **full** Japanese sentence with no gaps. `"choices"` has exactly one
entry: the correct answer substring(s). `correct` is always 0. Each choice is an array
with one element per grammar slot (e.g. `["し","し"]` for two slots). Swift creates the
gapped display by replacing each answer substring with `___`.

**Tier 2 gapping: substring replacement with Haiku disambiguation fallback**

Swift creates the gapped display by searching for each answer substring in `sentence` and
replacing it with `___`. The naive approach (replace first occurrence) breaks for short
substrings like `の`, `は`, or `し` that appear multiple times in a sentence — the wrong
occurrence may get gapped.

To handle this, after parsing the LLM response the app checks whether any answer substring
appears in the sentence more times than it is needed as a grammar slot (e.g. `["の"]` needs
1, but the sentence has 2 `の`s; or `["し","し","し"]` needs 3, but the sentence has 4).
If so, a second cheap LLM call is made — using whatever model is already configured — asking
which specific occurrence(s) are the grammar slot(s). The prompt shows each occurrence with
surrounding context and the substring highlighted in `[brackets]`, and asks for a
comma-separated list of 1-based occurrence numbers. Swift then gaps exactly those
occurrences and caches the result in `GrammarMultipleChoiceQuestion.resolvedGappedSentence`.

This call is a rarity in practice — Haiku naturally writes sentences where conjugated
answer forms (弾けます, 削除されて) are long enough to be unambiguous. The fallback exists
for short particles and listing particles. Tested via `--test-disambiguation` in the
TestHarness with cases including `のだ先輩の車` (の appears in a name and as possessive)
and `少し疲れたけど…好きだし…好きだし…好きだし` (し in 少し vs three listing particles).

**Key distractor rules for tier 1** (enforced in the generation prompt):
- Same core vocabulary and situation — only the grammar form changes
- Each distractor uses a clearly different grammar construction (not just a particle swap)
- No distractor may use a valid alternative for the target grammar's meaning (e.g. if
  target is potential verbs, ことができる is excluded — it's also correct)
- Each distractor must be grammatically valid Japanese (even though it expresses the
  wrong meaning for the English stem)
- Distractors express a DIFFERENT meaning from the English stem (not the same meaning
  in a different form — that makes the correct choice much harder to identify)

**Prompt ordering: English-first** (Step 1 = English stem, Step 2 = correct Japanese,
Step 3 = distractors, Step 4 = self-check). Tested against Japanese-first ordering.
English-first produced better results: more varied verbs/settings, no self-revision
loops that burned tokens, and stricter adherence to the "same sentence frame" constraint
for distractors.

**Distractor semantics**: distractors do NOT have the same meaning as the correct
sentence — they express a different meaning because they use a different grammar form.
The English stem fixes the intended meaning; the student picks the grammar form that
matches.

**Implementation**: `GrammarMultipleChoiceQuestion.choices` is `[[String]]`.
For full-sentence multiple choice, each sub-array has one element. The JSON parser
also accepts legacy flat `[String]` format (auto-wrapped into 1-element sub-arrays).
The parser accepts either 4 choices (multiple choice) or 1 choice (fill-in-the-blank).

### Recognition tiers 1 and 2: format design

**Tier 1 (multiple choice):** Haiku generates a natural Japanese sentence using the
target grammar, the correct English translation, and three distractor English translations
that a student would produce by confusing the target grammar with a related grammar point.
The student sees the Japanese sentence and picks the best English translation.

**Key design point**: distractor choices must be natural English sentences, not grammar
labels or descriptions. This is a test-validity constraint (testing comprehension, not
grammar-terminology recognition), not a "hide the grammar topic" rule. The student may
know they are being quizzed on causative — they still have to read and understand the
Japanese sentence to pick the right English translation.

**Tier 2 (free text):** Haiku generates a Japanese sentence. The student writes a free
English translation. Haiku grades with SCORE. No PASSIVE grading for recognition — the
student writes English, so their response cannot demonstrate "use" of Japanese grammar
patterns in the way PASSIVE requires.

### Opportunistic passive grading (production only)
On tier 3 production free-text quizzes, Claude emits one `PASSIVE: <prefixed-topic-id>
<score>` line per additional enrolled grammar topic it observes *correctly used* in
the student's Japanese response. The app applies `updateRecall(..., score, 1, elapsed)`
for each. The test harness validates that any `PASSIVE:` lines present are well-formed.

Recognition facets do not emit PASSIVE — the student's response is English, which
cannot demonstrate syntactic use of Japanese grammar patterns.

**Passive grading of incorrect extra topics**: when the student's response shows
incorrect use of a non-target grammar topic from the GRAMMAR_TOPICS list, Haiku skips
emitting a PASSIVE line for that topic. Only emit PASSIVE when there is genuine positive
evidence. Rationale: the student's attention is on the main quiz topic; errors in
peripheral grammar may reflect inattention rather than lack of knowledge.

### Difficulty scaling via known grammar
At quiz generation time, Claude receives the list of grammar topics the student knows
well (from `GrammarQuizContext`). Claude uses these as scaffolding — building sentences
that incorporate well-known grammar patterns around the target point. A beginner studying
potential verbs gets simple sentences; someone who also has solid passive + causative
gets compound sentences using those patterns.

When scaffolding topics are provided, the tier-3 production and tier-2 recognition
stem-generation step asks Haiku to emit a `GRAMMAR_TOPICS: [...]` JSON array listing
which scaffolding topics the sentence exercises. These IDs are passed to the grading
prompt, which uses them for PASSIVE lines. This avoids the grader guessing topic IDs.
When scaffolding is empty, no `GRAMMAR_TOPICS` line is requested and no PASSIVE is possible.

### Extra grammar (scaffolding) — neither Haiku nor Sonnet uses it (2026-03-16)

Tested three modes for `--extra-grammar` with `genki:potential-verbs` and 6 enriched
scaffolding topics (causative, passive, て-form, てならない, ては-ては, のように-のような),
`--live --gen-only --facet production --repeat 2`:

```
EXTRA="bunpro:causative,bunpro:Verb[passive],dbjg:-te,bunpro:てならない,bunpro:ては-ては,bunpro:のように-のような"
for mode in all sample none; do
  .build/debug/TestHarness --grammar genki:potential-verbs --live --gen-only \
    --facet production --repeat 2 --extra-grammar "$EXTRA" --extra-grammar-mode $mode
done
```

**Haiku results:**
- **`all`** (6 topics with full descriptions): 5636-byte tier-3 prompt
- **`none`** (no extra grammar): 2732-byte tier-3 prompt (~2.1× token cost for `all`)
- `GRAMMAR_TOPICS: []` in every run — never wove scaffolding into sentences
- Sentence variety indistinguishable; all modes gravitated toward Yuki + music/performance

**Sonnet 4.6 results (same command with `ANTHROPIC_MODEL=claude-sonnet-4-6`):**
- **`all`**: ~1690 average input tokens; **`none`**: ~1007 average input tokens (~1.7× for `all`)
- `GRAMMAR_TOPICS: []` in every run — also never used scaffolding grammar
- Sentence variety is better than Haiku (car/bicycle/violin/printer scenarios instead of
  defaulting to Yuki + music), but indistinguishable across `all` / `sample` / `none` modes

**Conclusion**: extra-grammar scaffolding does nothing for either Haiku or Sonnet. The
2026-03-14 model comparison where "Sonnet wove scaffolding into richer sentences" was
comparing against an older prompt format (comma-separated topics, no descriptions) — the
richer sentences were likely Sonnet's general quality improvement, not a response to the
scaffolding list. The extra-grammar feature provides no benefit at any tested capability
level. The iOS app correctly defaults to empty `extraGrammarTopics`; do not re-enable
without a controlled experiment that specifically demonstrates scaffolding-driven content.

### Token cost awareness
Grammar quizzes always require at least one LLM call for question generation (unlike
vocab where stems can be built locally). Keep prompts tight: topic ID, title, level,
example sentences, scaffolding grammar list. No database dumps. Post-answer discussion
is one additional call (same as vocab). Monitor via existing `api_events` telemetry.

Current token budgets (as of 2026-03-15):
- Multiple-choice generation (`runGenerationLoop`): **1500** tokens — chain-of-thought
  steps use ~400–500 reasoning tokens before the JSON
- Free-text stem generation (tier 3 production + tier 2 recognition): **512** tokens
- Coaching/grading responses (all coaching paths): **512** tokens

---

## Phases

### Phase 0 — content pipeline (no iOS)

- [x] Slugify DBJG entries into a proper TSV (id, option, title-en) matching the Genki/Bunpro format
  - Handle cross-references like `chau <shimau>` — these become aliases pointing to the main entry
  - Numbering disambiguates homographs: `ageru1`, `ageru2`
  - `option` = `"basic"` for all (future: `"intermediate"`, `"advanced"` for the sequel books)
  - Done: `grammar/slugify-dbjg.mjs` → `grammar/grammar-dbjg.tsv`
- [x] Build grammar database loader in `.claude/scripts/` — reads all three TSVs, prefixes IDs by source
  - Done: `loadGrammarDatabases()` in `.claude/scripts/shared.mjs`
- [x] Parse `<details><summary>Grammar</summary>` blocks from Markdown (parallel to vocab extraction)
  - Done: `extractGrammarBullets()` in `.claude/scripts/shared.mjs`
- [x] Build `check-grammar.mjs` — validates grammar tags against known databases, reports unknown IDs
  - Done: `.claude/scripts/check-grammar.mjs`
- [x] Build equivalence groups: LLM-assisted clustering of topics across databases
  - Output: `grammar/grammar-equivalences.json` — generic, version-controlled, no user content.
    Array of objects: `{ topics: [...], summary, subUses, cautions, stub? }`.
    Covers only annotated topics today; grows incrementally via `/cluster-grammar-topics`.
  - `add-grammar-equivalence.mjs`: pure graph operation script
    - 1 argument: adds topic as a singleton group
    - 2+ arguments: merges all into one group (union-find style), idempotent
    - Reads/writes `grammar/grammar-equivalences.json`
  - `/cluster-grammar-topics` skill: finds topics in `grammar.json` missing from `grammar/grammar-equivalences.json`, uses LLM to suggest matches against all three databases, calls `add-grammar-equivalence.mjs` to apply
  - Checked into repo, manually reviewable
- [x] Generate `grammar.json` (analogous to `vocab.json`)
  - Personal, generated at publish time, pushed to the Gist alongside `vocab.json`
  - `sources`: metadata per database
  - `topics`: keyed by prefixed ID, contains title, level, href, sources (which Markdown files annotate it), equivalenceGroup (peer topic IDs — convenience denormalization for the iOS app)
  - Does NOT contain descriptions (summary/subUses/cautions) — those live in `grammar/grammar-equivalences.json`
  - Done: `prepare-publish.mjs` collects grammar annotations and writes `grammar.json`
- [x] Update `prepare-publish.mjs` (or equivalent) to produce `grammar.json` alongside `vocab.json`
- [x] `prepare-publish.mjs` validation: fail if any topic in `grammar.json` is missing from `grammar/grammar-equivalences.json`

### Content workflow

1. Edit Markdown files — add `<details><summary>Grammar</summary>` blocks with `source:id` bullets
2. Run `check-grammar.mjs` — validates all IDs exist in the three grammar databases
3. Run `prepare-publish.mjs` — produces `grammar.json` (and `vocab.json`); **fails** if `grammar/grammar-equivalences.json` is missing any topics
4. If step 3 fails, run `/cluster-grammar-topics` — adds new topics to `grammar/grammar-equivalences.json` (LLM-assisted, then manually review the diff)
5. Re-run `prepare-publish.mjs`
6. [x] `publish.mjs` pushes `grammar.json` alongside `vocab.json`
7. TODO: push `grammar/grammar-equivalences.json` to the Gist alongside `grammar.json` so
   the iOS app can fetch descriptions without requiring an app update (see Infrastructure section)

### Phase 1A — Core library (TestHarness-compatible)

All items complete as of 2026-03-15:

- [x] GRDB migration: `grammar_enrollment` table (topic_id, status, enrolled_at)
  - Reuse existing `ebisu_models` and `reviews` tables with `word_type = 'grammar'`
- [x] Grammar JSON loader — `GrammarSync.swift`; model types `GrammarManifest`, `GrammarTopic`, `GrammarSourceMeta`; URL derived from vocab URL (same Gist)
- [x] `GrammarQuizContext.swift` — `GrammarQuizItem` + context builder ranked by Ebisu recall; scaffolding topic list for difficulty scaling; `QuizDB` extensions for grammar enrollment and review counts
- [x] `GrammarQuizSession.swift` — all tiers for both facets; system prompt builder; `generateQuestionForTesting` + `gradeAnswerForTesting` entry points
- [x] TestHarness integration: `--grammar <topic_id>` mode with `--dump-prompts`, `--live`, `--facet`, `--gen-only`, `--repeat`, `--extra-grammar`
- [x] Update documentation in TESTING.md
- [x] Tier 1 production + tier 1 recognition: multiple choice generation (LLM) + pure-logic grading (app-side)
- [x] Tier 2 production: fill-in-the-blank
  - Fast path: `gradeFillin(studentAnswers:correctFills:)` — pure Swift string match (normalize trailing 。/、 and whitespace). Score 1.0 immediately, no LLM.
  - Fallback coaching path: `gradeTier2FallbackForTesting(item:stem:referenceAnswer:studentAnswer:)` — multi-turn Haiku coaching until SCORE emitted or max turns reached.
  - Separate generation call from tier 1 — does not reuse the tier 1 question
- [x] Tier 3 production: free-text
  - Stem generation: `generateFreeTextStemForTesting()` — Haiku writes English context; parses `GRAMMAR_TOPICS: [...]` for passive grading
  - Grading: `gradeTier3ProductionForTesting()` — multi-turn coaching; emits SCORE + PASSIVE lines
- [x] Tier 2 recognition: free-text
  - Stem generation: `generateFreeTextStemForTesting()` (same function, recognition branch) — Haiku writes Japanese sentence; parses `GRAMMAR_TOPICS: [...]`
  - Grading: `gradeAnswerForTesting()` — single-turn; emits SCORE only (no PASSIVE for recognition)
- [x] `GrammarQuizItem.tier: Int` added (1/2/3 for production, 1/2 for recognition); computed from review count + halflife in `GrammarQuizContext.build()`
- [x] `--extra-grammar topic1,topic2` flag in TestHarness to simulate a student who knows specific grammar

### Phase 1A.5 — Pre-UI outstanding items

Three items that should be resolved before Phase 1B, in this order:

- [x] **Enriched topic descriptions** — per-equivalence-group descriptions stored in
  `grammar/grammar-equivalences.json`. Generated/reviewed via the `/cluster-grammar-topics`
  skill. Descriptions are generic (no user content), committed to the repo, and fetched
  by the iOS app independently of `grammar.json`.

  Decided:
  - Per-equivalence-group (not per-topic)
  - Descriptions live only in `grammar/grammar-equivalences.json` — NOT merged into
    `grammar.json` (which is personal/generated). The iOS app fetches both files.
  - No `sourcesSeen` field — user content sentences stay out of the generic descriptions
    file. The enrichment script passes content sentences to the LLM at generation time
    but does not store them. Re-enrichment when content changes must be triggered
    manually by running `/cluster-grammar-topics`.
  - No sub-topic Ebisu modeling — sub-uses are enumerated in the description and Haiku
    varies across them naturally; quiz `reviews.notes` tracks which sub-use was exercised,
    and recent notes are fed back into generation for diversity
  - `stub: true` flag retained — marks groups whose description was generated without
    any user content sentences (web pages + LLM knowledge only). Used by TestHarness
    to warn when running unannotated topics.

  Task breakdown:
  - [x] **1. Evolve `grammar/grammar-equivalences.json` schema** — migrated from
    array-of-arrays to array-of-objects: `{ topics: [...], summary, subUses, cautions, stub? }`.
    Migration in `add-grammar-equivalence.mjs` reads either format.
  - [x] **2. Move `grammar-equivalences.json` to `grammar/` directory** — keeps generic
    version-controlled assets together. Dropped `sourcesSeen` field. All scripts updated.
  - [x] **3. Build description generation logic** — `.claude/scripts/enrich-grammar-descriptions.mjs`
    gathers context (topic metadata, annotated sentences from Markdown files); the
    `/cluster-grammar-topics` skill fetches Bunpro/St Olaf pages, calls Claude to
    produce summary/subUses/cautions, then writes back via `--write` mode.
    Sets `stub: true` if no content sentences were found.
  - [x] **4. Extend `/cluster-grammar-topics` skill** — fetches reference URLs before
    clustering (so equivalence decisions are well-informed), then enriches descriptions
    for new and changed groups. Added critical-evaluation directive and self-review step
    to improve description quality (avoid textbook oversimplifications, precise cautions).
  - [x] **5. Wire descriptions into quiz prompts** — update
    `GrammarQuizSession.systemPrompt()` to inject `summary`, `subUses`, and `cautions`
    from the topic's equivalence group. The iOS app fetches `grammar/grammar-equivalences.json`
    alongside `grammar.json` (new `GrammarSync` fetch); `GrammarTopic` gains optional
    description fields populated at sync time. Pass `stub: true` topics through
    unchanged (Haiku still gets a reasonable description).
  - [x] **6. TestHarness: load `grammar/grammar-equivalences.json` directly** — removed
    the `grammar.json` overlay path in `GrammarDumpPrompts.swift`. TestHarness builds its
    manifest from TSV files + `grammar/grammar-equivalences.json` only, never needing
    `grammar.json` (which is personal/user-specific). When a topic's equivalence group has
    no description (or `stub: true`), prints a warning on stderr and continues (quiz works
    without descriptions, just less informative prompts). No `--enrich` flag — the
    `/cluster-grammar-topics` skill handles enrichment end-to-end via
    `enrich-grammar-descriptions.mjs`; manual invocation of that script is never needed.
  - [x] **7. Feed review notes back into generation** — generation prompts accept a
    `recentNotes: [String]` list (from `reviews.notes`) and instruct Haiku to avoid
    repeating those sub-uses. All generation paths (multiple-choice JSON and free-text
    stems) emit the targeted sub-use: `"sub_use"` field in the JSON response, or
    `SUB_USE:` line after the `---` divider. Parsed into
    `GrammarMultipleChoiceQuestion.subUse` and the free-text stem return tuple.
    `GrammarQuizContext.build()` loads notes via `QuizDB.grammarAllRecentNotes()` and
    passes them to `GrammarQuizItem.recentNotes`. TestHarness: `--recent-note "phrase"`
    (repeatable) mocks prior notes. Storing `subUse` in `reviews.notes` is Phase 1B
    (iOS UI writes reviews).

- [ ] **VOCAB_ASSUMED contract** — define which generation paths emit a
  `VOCAB_ASSUMED: word1,word2,...` line, how the app parses and stores it alongside the
  stem, and what the "Show vocabulary" button does in the UI.
  Open questions to resolve:
  - Which tiers emit it: tier 3 production and tier 2 recognition are the clear cases;
    tier 1/2 production arguably don't need it (the Japanese sentence already shown)
  - Storage: add a `vocab_assumed` column to wherever stems are cached, or compute on
    the fly from the generation response
  - JMDict lookup: look up meanings at generation time and cache, or look up lazily
    when the student taps "Show vocabulary"
  - Passive vocab boost: if any VOCAB_ASSUMED word is enrolled in vocab, emit
    `PASSIVE_VOCAB: word_id score` from the grading step (see Open items section)

- [ ] **Equivalence-group Ebisu propagation** — when a quiz updates Ebisu for one topic,
  all other topics in the same equivalence group should receive the same update. Without
  this, the scheduler will re-queue `bunpro:られる-Potential` after the student has already
  demonstrated mastery via `genki:potential-verbs`.
  Open questions to resolve:
  - Where to wire it in: at review-write time in `GrammarQuizSession` (write one review
    row + N Ebisu updates), or at scheduling time in `GrammarQuizContext` (read all
    group members' Ebisu states and take the best)? Write-time propagation is simpler
    and keeps the Ebisu states consistent; read-time merging avoids phantom review rows
    for topics the student never explicitly studied
  - What score to propagate: same score as the primary review (full weight), or a
    discounted passive score (e.g. 0.9×)?

### Phase 1B — iOS Views

- [ ] Grammar topic list view — filterable by source, level, enrollment status
- [ ] GrammarDetailSheet — example sentences, chat box (Claude), mnemonic support
  - Reuses mnemonic infrastructure with `word_type = 'grammar'`
- [ ] Grammar quiz view — tier 1 multiple choice for both facets
- [ ] Grammar quiz: tier 2 production fill-in-the-blank
- [ ] Grammar quiz: tier 2 recognition free text
- [ ] Grammar quiz: tier 3 production free text with opportunistic passive grading
- [ ] Integrate grammar items into unified quiz scheduling (alongside vocab)

---

## Prompt design decisions

### Target grammar strictness (all production grading paths)
All production grading — tier 2 fill-in-the-blank fallback and tier 3 free text —
requires the student to use the *specific target grammar form*, not a semantically
equivalent alternative construction. If the student writes correct Japanese that uses
a different construction (e.g. ことができる instead of potential verb form), Haiku
coaches them toward the target form rather than scoring immediately. If they cannot
produce it after coaching, score is 0.0–0.2.
Rationale: without this, the Ebisu model for the target grammar never gets meaningful signal.

### Production tier 3 grading is multi-turn coaching
Like tier 2 fallback, tier 3 production grading uses a multi-turn coaching conversation
(`gradeTier3ProductionForTesting`). Haiku also points out other errors in the student's
Japanese (wrong particles, conjugation mistakes) as coaching notes — but these don't affect
the SCORE for the target grammar.

### Recognition tier 2 expects English translation only
The recognition tier 2 grading prompt expects a plain English translation. SCORE reflects
whether the translation captures the meaning that the target grammar conveys.

### Stem generation: reasoning + divider format
Free-text stem generation (production tier 3, recognition tier 2) allows Haiku to reason
before a `---` divider. After the divider: only the stem text. The parser strips everything
before `---`. This improves output quality without polluting the stem.

### Verb-variety nudge is generation-only
The `"Vary the verb and setting; 食べる, 飲む, and 泳ぐ are overused."` instruction appears
only in generation system prompts, not grading prompts. Grading prompts are for focused
evaluation; the nudge is irrelevant there and would be noise.

### GRAMMAR_TOPICS: stem generation emits topic IDs for passive grading
When scaffolding topics are provided, the stem generation step asks Haiku to emit a
`GRAMMAR_TOPICS: [id1, id2, ...]` JSON array listing which scaffolding topics the sentence
exercises. These IDs are parsed and passed to the grading prompt, which uses them for
PASSIVE lines. This avoids the grader guessing topic IDs (which may not match actual IDs
in the system). When scaffolding is empty, no GRAMMAR_TOPICS line is requested and no
PASSIVE is possible.

### Recognition chain-of-thought (added 2026-03-15)
Recognition tier 1 user message now uses the same explicit four-step chain-of-thought as
production tier 1: Step 1 = Japanese stem, Step 2 = correct translation, Step 3 =
distractors (each naming the confusion it exploits), Step 4 = self-check that no distractor
is close enough to the correct answer that a student could argue for it. Before this change,
Haiku occasionally produced a distractor like "The students were forced to run against their
will" alongside a correct answer of "The teacher made the students run" — essentially the
same meaning, just framed differently.

### Model selection: Haiku is the right choice (2026-03-14)
Ran `genki:potential-verbs` production facet (all paths, with `bunpro:causative` and
`bunpro:Verb[passive]` scaffolding) against Haiku, Sonnet 4.6, and Opus 4.6 in parallel.
All three models passed all validation checks. Key findings:

- **Latency**: Haiku 2–9 s per call; Sonnet 5–18 s; Opus 13–22 s. For a quiz app where
  the student is waiting at a spinner, Sonnet and Opus are too slow for real-time use.
- **Verb variety**: Haiku repeatedly defaulted to 食べる/食べ物 scenarios even with
  scaffolding; Sonnet and Opus naturally varied their verbs and wove scaffolding grammar
  into richer multi-clause sentences.
- **GRAMMAR_TOPICS accuracy**: Haiku (old comma-separated prompt) hallucinated
  `bunpro:causative` for a sentence that contained no causative construction. Switching to
  a JSON array format with "only include if syntactically present" fixed the hallucination.
- **Coaching quality**: Sonnet and Opus produced cleaner, more focused coaching responses.
  Haiku occasionally echoed template language from the prompt that didn't apply to the
  student's actual mistake.

**Conclusion**: Haiku quality gaps are addressable with prompt improvements. The latency
gap is large enough that Sonnet/Opus are not viable for synchronous use. Revisit Sonnet
if prefetch (generating the next question while the student reads feedback) makes the
latency acceptable.

---

## Open items and known limitations

### Prompt quality

- **Enriched topic descriptions**: see Phase 1A.5 task breakdown. The ら抜き言葉 handling
  for `genki:potential-verbs` is covered by the `cautions` field in the description.

- **Part-of-speech annotation for coaching accuracy**: Haiku occasionally misidentifies verb
  class in coaching responses (e.g. calling 弾く a "る-verb"). This happens because the
  coaching prompt only receives the correct fill string (e.g. `弾ける`) without knowing how
  it was derived.
  - **Option A** (preferred): ask the generation step to include a `verbNote` field
    (e.g. `"verbNote": "godan: 弾く → 弾ける"`) alongside `sentence` and `choices`. The
    coaching prompt receives this as a plain-text hint, no extra tool calls.
  - **Option B**: give the coaching LLM access to `lookup_jmdict` so it can look up the
    verb's part-of-speech tag. Adds latency and tokens on every coaching turn.
  - Current priority: low — the error is rare and the student can still reach the correct
    answer despite the wrong hint.

- **`verbNote` field for coaching accuracy**: Haiku occasionally misidentifies verb class
  in coaching responses (observed: calling 弾く a "る-verb" and directing the student
  toward the ichidan potential pattern 食べ**られ**る, when the correct godan pattern is
  弾**け**る). This happens because the coaching prompt only receives the correct fill
  string (e.g. `弾ける`) without knowing how it was derived.
  - **Option A** (preferred): ask the generation step to include a `verbNote` field
    (e.g. `"verbNote": "godan: 弾く → 弾ける"`) alongside `sentence` and `choices`. The
    coaching prompt receives this as a plain-text hint with no extra tool calls or latency.
  - **Option B**: give the coaching LLM access to `lookup_jmdict` so it can look up the
    verb's part-of-speech tag (e.g. `v5k` = godan-ku). Adds latency and tokens on every
    coaching turn; `lookup_jmdict` already returns part-of-speech data (via `ToolHandler.swift`)
    so the data is available if needed.
  - Current priority: low — the error is rare and the student can still reach the correct
    answer despite the wrong hint. Revisit if coaching quality becomes a complaint.

- **VOCAB_ASSUMED: on-demand vocabulary glossary for grammar quiz stems**: grammar quiz
  stems use vocabulary that the student may not know — vocabulary knowledge should not
  block grammar testing.
  - **Design**: during stem generation, Haiku emits a `VOCAB_ASSUMED: word1,word2,...` line
    listing the key content words the student needs to answer the question. This line is
    parsed and stored; it is NOT shown to the student by default.
  - **App UX**: a "Show vocabulary" button appears below the stem. Tapping it reveals a
    glossary with the assumed words and their meanings (looked up from local JMDict).
    Experienced students who know the words can ignore it; beginners can refer to it
    without penalty.
  - Most useful for tier 3 production and recognition tier 2 free-text. For tier 2
    production fill-in-the-blank, the correct answer itself implicitly reveals the key
    vocabulary.
  - Keep to 2–5 essential content words (verbs, nouns). Particles, copulas, and the
    target grammar structure itself should not be listed.

- **Furigana for unknown kanji in recognition stems**: recognition stems are LLM-generated
  Japanese sentences. Students who haven't learned all the kanji may be blocked by reading
  difficulty rather than tested on grammar comprehension.
  - **TODO**: Show furigana (ruby text) on kanji the student hasn't enrolled or committed
    to. Two approaches: (a) ask the LLM to emit furigana alongside the sentence, or (b)
    add furigana via local lookup (JmdictFurigana) after generation. Option (a) is simpler
    to implement first.

### Infrastructure

- **Publish `grammar/grammar-equivalences.json` to the Gist**: `grammar.json` is already
  pushed by `publish.mjs`. `grammar/grammar-equivalences.json` (generic descriptions, no
  user content) should also be pushed so the iOS app can fetch it without an app update.
  `GrammarSync.swift` would derive the URL the same way as `grammar.json` (substituting
  the filename). Once pushed, `GrammarTopic` description fields can be populated at sync
  time (Phase 1A.5 task 5).

- **Offline / bundling**: both `grammar.json` and `grammar/grammar-equivalences.json` could
  also be bundled in the app binary for offline use and faster first launch. Lower priority
  than getting the Gist fetch working first.

---

## Alternative designs considered (for reference)

### Fill-in-the-blank as tier 1 (implemented 2026-03-14, superseded 2026-03-15)
Instead of four complete sentences, originally the tier 1 multiple-choice question generated
a gapped Japanese sentence with `___` and four short conjugation-level fills. This solves
the particle-only-variation problem by reducing choices to the grammar slot itself. Better
for multi-gap patterns (〜し〜し, ば〜ほど) where short fills per gap are cleaner than four
long sentences. The generation prompt used a 5-step chain of thought.

This design was superseded because the tier 1 / tier 2 distinction became unclear, and
because full-sentence choices make the grammatical contrast between options more salient.
The fill-in-the-blank format is now exclusively tier 2.

Fill-in-the-blank prompt (for reference):
```
Step 1 — Full sentence: Write a complete Japanese sentence using the target grammar. No gaps yet.
Step 2 — Slot: Mark the grammar slot(s) using 【】 brackets. Bracket enough so that every
  choice combines cleanly with the text outside the brackets. For conjugation grammar,
  include any attached auxiliary: 彼女はピアノが【弾けない】。For conjunction/particle
  grammar, the particle itself is the complete unit: 先生は厳しい【し】、宿題も多い【し】。
Step 3 — Self-check: Does the target grammar form appear OUTSIDE the 【】 brackets
  anywhere in Step 1? If yes, rewrite Step 1 so it does not.
Step 4 — English stem: One or two English sentences describing a concrete situation.
Step 5 — Distractors: Three wrong fills. Each must be a real Japanese form — wrong for
  this context but not a nonsense string. Substitute each into the gap: the result must
  be grammatically valid Japanese.
```

### Japanese-first chain of thought (tested 2026-03-15, rejected)
Step 1 = write the correct Japanese sentence first, Step 2 = derive English from it.
Hypothesis: thinking in Japanese first produces more natural sentences. Results: Haiku
got stuck in visible self-revision loops (rewriting the sentence 3–5 times before
settling), burning ~600 extra tokens. Verb variety was worse. Distractors occasionally
broke the "same sentence frame" constraint. For し, one run produced a correct answer
that only used し once (mixed with から), weakening the quiz.

### Tiers 1 and 2 sharing a generation call (pre-2026-03-15)
Originally the plan was to share one generation call between production tiers 1 and 2:
tier 1 shows it as tap-a-button (pick a full sentence), tier 2 shows it as
fill-in-the-blank (type the gap). The only difference would be the halflife in the Memory
line. This was abandoned because the two formats require genuinely different prompts and
question shapes — full-sentence choices versus a gapped sentence with a single correct
fill — and sharing the call would have forced compromises in both.

---

## Future

- [ ] Error-correction and sentence-completion quiz variants
- [ ] Cross-database linking UI — surface equivalences to user, allow manual adjustments
- [ ] Dictionary of Intermediate / Advanced Japanese Grammar databases
- [ ] Grammar → vocab connections (e.g., a grammar quiz sentence uses enrolled vocab)
- [ ] Difficulty analytics — track which grammar points have low recall, suggest review strategies
