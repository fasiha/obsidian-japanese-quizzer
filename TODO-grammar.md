# Grammar feature plan

## Concepts

### Grammar databases
Three sources, each providing topic IDs:
- **Genki** (`grammar-stolaf-genki.tsv`): ~123 topics, slugified IDs like `potential-verbs`
- **Bunpro** (`grammar-bunpro.tsv`): ~943 topics, IDs like `られる-Potential`
- **DBJG** (`grammar-dbjg.md`): ~370 entries from Dictionary of Basic Japanese Grammar table of contents

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

- [ ] Slugify DBJG entries into a proper TSV (id, option, title-en) matching the Genki/Bunpro format
  - Handle cross-references like `chau <shimau>` — these become aliases pointing to the main entry
  - Numbering disambiguates homographs: `ageru1`, `ageru2`
  - `option` = `"basic"` for all (future: `"intermediate"`, `"advanced"` for the sequel books)
- [ ] Build grammar database loader in `.claude/scripts/` — reads all three TSVs, prefixes IDs by source
- [ ] Parse `<details><summary>Grammar</summary>` blocks from Markdown (parallel to vocab extraction)
- [ ] Build `check-grammar.mjs` — validates grammar tags against known databases, reports unknown IDs
- [ ] Build equivalence groups: LLM-assisted clustering of topics across databases
  - Output: `grammar-equivalences.json` — array of arrays of topic IDs
  - One-time generation, manually reviewed, checked into repo
- [ ] Generate `grammar.json` (analogous to `vocab.json`)
  - `sources`: metadata per database
  - `topics`: keyed by prefixed ID, contains title, level, href, example sentences, equivalence group
- [ ] Update `prepare-publish.mjs` (or equivalent) to produce `grammar.json` alongside `vocab.json`

### Phase 1 — iOS app

- [ ] GRDB migration: `grammar_enrollment` table (user_id, topic_id, status)
  - Reuse existing `ebisu_models` and `reviews` tables with `word_type = 'grammar'`
- [ ] Grammar JSON loader — fetch and parse `grammar.json` from same host as `vocab.json`
- [ ] Grammar topic list view — filterable by source, level, enrollment status
- [ ] GrammarDetailSheet — example sentences, chat box (Claude), mnemonic support
  - Reuses mnemonic infrastructure with `word_type = 'grammar'`
- [ ] Grammar quiz: multiple choice (tier 1) — both production and recognition facets
  - System prompt: topic info + example sentences + scaffolding grammar list
  - Claude returns JSON: stem + 4 choices + correct index
  - Pure-logic grading, then discussion turn
- [ ] Grammar quiz: fill-in-the-blank (tier 2)
- [ ] Grammar quiz: free text with opportunistic passive grading (tier 3)
- [ ] Integrate grammar items into unified quiz scheduling (alongside vocab)

### Future

- [ ] Error-correction and sentence-completion quiz variants
- [ ] Cross-database linking UI — surface equivalences to user, allow manual adjustments
- [ ] Dictionary of Intermediate / Advanced Japanese Grammar databases
- [ ] Grammar → vocab connections (e.g., a grammar quiz sentence uses enrolled vocab)
- [ ] Difficulty analytics — track which grammar points have low recall, suggest review strategies
