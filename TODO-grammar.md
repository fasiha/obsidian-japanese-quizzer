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
| `recognition` | Japanese sentence | English meaning / identify grammar | Launch facet |
| `error-correction` | Japanese sentence with deliberate grammar mistake | Corrected sentence | Future |
| `sentence-completion` | Beginning of Japanese sentence | Completion using target grammar | Future |

Both `production` and `recognition` share the same three format tiers (below).
`error-correction` and `sentence-completion` are future variants that may live
within existing facets rather than as independent facets.

### Format tiers

All facets progress through format tiers, graduated by Ebisu thresholds:

| Tier | Format | Generation | Grading |
|------|--------|------------|---------|
| 1. Multiple choice | Pick from 4 choices | LLM (Haiku) | Pure logic (zero tokens) |
| 2. Fill-in-the-blank | Sentence with gap for the grammar point | LLM (Haiku) | Possibly pure logic (string match) or LLM |
| 3. Free text | Full translation (production) or open explanation (recognition) | LLM (Haiku) | LLM (Haiku) |

Note: tiers 1 and 2 are both fill-in-the-blank conceptually — the difference is
whether the student picks from choices (tier 1) or types freely (tier 2).

Graduation thresholds TBD but likely higher than vocab (grammar production is harder).

**Difficulty scaling via known grammar, not halflife.** At quiz generation time, Claude
receives the list of grammar topics the student has at or above the quiz target's
establishment level. Claude uses these as scaffolding — building sentences that
incorporate well-known grammar patterns around the target point. A beginner studying
potential verbs gets simple sentences; someone who also has solid passive + causative
gets compound sentences using those patterns.

**Opportunistic passive grading.** On free-text quizzes, Claude also grades any
other enrolled grammar topics visible in the student's response. The scheduled topic
gets a full-weight Ebisu update; other topics get passive updates (`updateRecall(...,
0.5, 1, elapsed)`). This makes free-text grading token-efficient — one LLM call yields
multiple Ebisu updates.

### Token cost awareness
Grammar quizzes always require at least one LLM call for question generation (unlike
vocab where stems can be built locally). Keep prompts tight: topic ID, title, level,
example sentences, scaffolding grammar list. No database dumps. Post-answer discussion
is one additional call (same as vocab). Monitor via existing `api_events` telemetry.

The vocab system evolved from fully-LLM to hybrid (logic where possible). Expect
grammar to follow the same trajectory — start with LLM everywhere, migrate
deterministic parts to pure logic as patterns emerge.

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
  - Output: `grammar-equivalences.json` — array of arrays of prefixed topic IDs (e.g. `[["bunpro:causative", "genki:causative", "dbjg:saseru"]]`)
  - `add-grammar-equivalence.mjs`: pure graph operation script
    - 1 argument: adds topic as a singleton group
    - 2+ arguments: merges all into one group (union-find style), idempotent
    - Reads/writes `grammar-equivalences.json`
  - `/cluster-grammar-topics` skill: finds topics in `grammar.json` missing from `grammar-equivalences.json`, uses LLM to suggest matches against all three databases, calls `add-grammar-equivalence.mjs` to apply
  - Checked into repo, manually reviewable
- [x] Generate `grammar.json` (analogous to `vocab.json`)
  - `sources`: metadata per database
  - `topics`: keyed by prefixed ID, contains title, level, href, example sentences, equivalence group
  - Done: `prepare-publish.mjs` collects grammar annotations and writes `grammar.json`
- [x] Update `prepare-publish.mjs` (or equivalent) to produce `grammar.json` alongside `vocab.json`
- [x] `prepare-publish.mjs` validation: fail if any topic in `grammar.json` is missing from `grammar-equivalences.json`

### Content workflow

1. Edit Markdown files — add `<details><summary>Grammar</summary>` blocks with `source:id` bullets
2. Run `check-grammar.mjs` — validates all IDs exist in the three grammar databases
3. Run `prepare-publish.mjs` — produces `grammar.json` (and `vocab.json`); **fails** if `grammar-equivalences.json` is missing any topics
4. If step 3 fails, run `/cluster-grammar-topics` — adds new topics to `grammar-equivalences.json` (LLM-assisted, then manually review the diff)
5. Re-run `prepare-publish.mjs`
6. [x] `publish.mjs` pushes `grammar.json` alongside `vocab.json`
7. TODO: bundle `grammar.json` and `grammar-equivalences.json` into the iOS app

### Phase 1A — Core library (TestHarness-compatible)

- [x] GRDB migration: `grammar_enrollment` table (topic_id, status, enrolled_at)
  - Reuse existing `ebisu_models` and `reviews` tables with `word_type = 'grammar'`
- [x] Grammar JSON loader — `GrammarSync.swift`; model types `GrammarManifest`, `GrammarTopic`, `GrammarSourceMeta`; URL derived from vocab URL (same Gist)
- [x] `GrammarQuizContext.swift` — `GrammarQuizItem` + context builder ranked by Ebisu recall; scaffolding topic list for difficulty scaling; `QuizDB` extensions for grammar enrollment and review counts
- [x] `GrammarQuizSession.swift` — tier-1 multiple choice only (production + recognition); system prompt builder with topic info + scaffolding list; `generateQuestionForTesting` + `gradeAnswerForTesting` entry points; `GrammarMultipleChoiceQuestion` parsed from Claude JSON
- [x] TestHarness integration: `--grammar <topic_id>` mode with `--dump-prompts`, `--live`, and single-item generate; symlinks added for all three new Swift files
- [x] Update documentation in TESTING.md
- [ ] Tier 2 (fill-in-the-blank) library — `GrammarQuizSession` support for fill-in-the-blank format: LLM generates sentence with `___` gap + correct fill + distractors; grading is string-match or lightweight LLM; graduation threshold TBD
  - [ ] TestHarness: add `--tier 2` flag to `--dump-prompts` and `--live` modes
- [ ] Tier 3 (free text) library — `GrammarQuizSession` support for free-text production/recognition; LLM-generated stem cached between turns; SCORE grading; opportunistic passive grading (`PASSIVE: topic_id score` lines) for other enrolled grammar visible in response
  - [ ] TestHarness: add `--tier 3` flag; validate SCORE token, passive grading lines, and correct-answer score ≥ 0.8
- [ ] `--scaffold topic1,topic2` flag in TestHarness to simulate a student who knows specific grammar, for testing difficulty scaling

### Phase 1B — iOS Views

- [ ] Grammar topic list view — filterable by source, level, enrollment status
- [ ] GrammarDetailSheet — example sentences, chat box (Claude), mnemonic support
  - Reuses mnemonic infrastructure with `word_type = 'grammar'`
- [ ] Grammar quiz view — tier 1 multiple choice (reuses `GrammarQuizSession` from Phase 1A)
- [ ] Grammar quiz: fill-in-the-blank (tier 2) — requires tier 2 library from Phase 1A
- [ ] Grammar quiz: free text with opportunistic passive grading (tier 3) — requires tier 3 library from Phase 1A; passive Ebisu updates for all `PASSIVE:` lines in response
- [ ] Integrate grammar items into unified quiz scheduling (alongside vocab)

### Prompt quality observations (from 2026-03-14 live tests)

Tested `genki:potential-verbs`, `bunpro:causative`, and `bunpro:てならない` against Haiku.
All 6 generation paths passed validation. Notes for future prompt work:

- **Technically-correct distractor problem**: for `genki:potential-verbs` production, Haiku generated
  `泳ぐことができます` as a distractor — but that is a correct way to express ability in Japanese
  (ことができる construction). The system prompt currently asks for "plausible but incorrect grammar"
  but doesn't distinguish between "wrong Japanese" and "correct Japanese that doesn't use the
  target grammar form." For tier-1 questions, this is only cosmetically wrong (the app marks it
  incorrect), but it could confuse or mislead the student.
  - **TODO**: Clarify the system prompt to distinguish between (a) grammatically wrong choices and
    (b) grammatically correct choices that use a *different* construction than the target. Explicitly
    note which distractors are "wrong Japanese" vs "correct Japanese, wrong form", or just instruct
    Claude to avoid alternative-correct constructions entirely.

- **Enriched topic descriptions**: the current prompt provides only topic ID, title, level, and a
  reference URL (which Haiku cannot fetch). For well-known topics like potential verbs and causative,
  Haiku's internal knowledge is sufficient. For more obscure or ambiguous topics this may be
  insufficient.
  - **TODO**: Consider adding an LLM-generated summary per equivalence group at `prepare-publish.mjs`
    time and injecting it into the quiz system prompt. This would be especially useful for topics
    where the title alone is ambiguous (e.g. `bunpro:てならない` — "Very, Extremely, Can't help but
    do" is enough, but a two-sentence gloss of the conjugation pattern could prevent errors on
    unusual topics).

- **Furigana for unknown kanji in quiz questions**: recognition stems are Japanese sentences
  containing the target grammar. Students who haven't learned all the kanji in a sentence may be
  blocked by kanji they've never seen rather than tested on the grammar.
  - **TODO**: Show furigana (ruby text) on kanji the student hasn't enrolled or committed to. The
    app already has vocab enrollment and kanji commitment data; the quiz display layer could suppress
    furigana only for kanji the student has committed to and reveal it for everything else. This is
    non-trivial because the sentence is LLM-generated (not from JMDict), so furigana would need to
    be either (a) generated by the LLM alongside the sentence, or (b) added via a local lookup
    (JmdictFurigana or similar) after generation. LLM-side is simpler to implement first.

### Future

- [ ] Error-correction and sentence-completion quiz variants
- [ ] Cross-database linking UI — surface equivalences to user, allow manual adjustments
- [ ] Dictionary of Intermediate / Advanced Japanese Grammar databases
- [ ] Grammar → vocab connections (e.g., a grammar quiz sentence uses enrolled vocab)
- [ ] Difficulty analytics — track which grammar points have low recall, suggest review strategies
