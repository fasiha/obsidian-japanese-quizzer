# Compound Verb Browser — Design and Work Plan

## Goal

Japanese compound verbs (複合動詞) are formed by combining the masu-stem of one verb
with a second verb: 歩き出す, 吹き抜ける, 繰り返す. A small set of ~12–15 suffixes
(込む, 出す, 上げる, 付ける, …) accounts for the majority of productive patterns.

The goal is to let users tap a compound verb in WordDetailSheet (either from
DocumentReaderView.swift or from VocabBrowserView.swift) and from there navigate to a
CompoundVerbDetailSheet that shows the suffix's meaning(s) and sibling words — the same
navigation pattern used for transitive-intransitive pairs (TransitivePairDetailSheet from
WordDetailSheet).

A secondary view: from within the CompoundVerbDetailSheet, browsing by prefix
(e.g. "all words starting with 歩き~") anchors suffix learning in familiar base verbs.

## Decisions

- **Suffix-first curation.** Suffixes are the learnable patterns; prefixes are
  broadly distributed across common verbs with no dominant entries. Prefix browsing
  is a secondary view derived from the same data, not a separate curation effort.

- **corpus-independent file.** `compound-verbs.json` follows the same convention as
  `transitive-pairs.json` and `grammar-equivalences.json`: it is a generic NLP
  resource containing only JMDict entry IDs, not references to the Obsidian corpus.
  Linking corpus words to compound verb entries is done at runtime or in the
  prepare-publish step, not stored in this file.

- **Small addition to vocab.json entries.** Each vocab entry may gain two optional
  fields: `"compoundV1"` and `"compoundV2"`, both strings (kanji form of the
  component verb). These are populated during the prepare-publish step by matching
  the entry's kanji form against `headwords.json`. Their presence confirms the word
  is in the VV Lexicon and provides the component verbs without requiring a runtime
  join against headwords data. Example:
  ```json
  { "id": 1234567, "compoundV1": "歩く", "compoundV2": "出す" }
  ```
  WordDetailSheet uses `compoundV2` to look up the suffix entry in
  `compound-verbs.json`; the prefix browser uses `compoundV1` to group siblings.

- **Senses within each suffix.** A suffix like 出す has multiple distinct meanings
  (sudden start; bring outward) and a tail of opaque lexicalized forms. Each sense
  gets its own meaning description, productivity rating, and example JMDict IDs.

- **Productivity levels:** `"high"` (fully compositional, meaning predictable from
  parts), `"medium"` (compositional but restricted or nuanced), `"low"` (opaque /
  lexicalized — treat examples as vocabulary items to memorize individually).

- **Example counts by productivity:** high and medium senses need 2–4 examples to
  illustrate the pattern; low-productivity senses need ~8–12 examples because each
  is an independent vocabulary item with no generalizable pattern.

- **Scope:** ~12–15 suffixes for the initial file, covering the top entries by
  frequency in the NINJAL VV Lexicon (込む 255, 上げる 133, 出す 132, 付ける 99,
  上がる 79, 入れる 74, …). Below ~20 entries per suffix the diminishing returns
  are clear and curation can stop or be deferred. The pipeline is designed to
  handle all 470 unique v2s (and all v1s) if scope ever expands — the 15-suffix
  limit is a prioritization choice, not an architectural one.

- **Frequency trimming for large suffixes.** For suffixes with many compounds
  (e.g. 込む with 255), trim to the top ~75% by cumulative BCCWJ frequency before
  sending to LLM passes. This keeps prompts manageable without losing coverage of
  common words. For 込む, the top 75% is approximately the top 44 compounds by
  BCCWJ frequency. The cap is "top 75% or top 50, whichever is higher" — so for
  a suffix with only 20 compounds, all 20 are sent rather than artificially
  cutting to 15.

## Data Sources

- **NINJAL Compound Verb Lexicon** (https://www2.ninjal.ac.jp/vvlexicon/)
  `headwords.json` — full VV lexicon with v1/v2 decomposition, readings, romaji,
  definitions in five languages, and usage examples. Fields used: `v2` (suffix),
  `v2_reading`, `headword1` (full compound kanji), `reading`, `senses`.
  NLB links (e.g. `V.05546`) provide per-100k frequency counts useful for ranking
  which opaque compounds to include as examples.

- **JMDict via jmdict.sqlite** — authoritative source for JMDict entry IDs, readings,
  senses, and kanji forms. All `examples` arrays in the JSON store JMDict entry IDs.
  Use `lookup.mjs` (supports wildcard queries, e.g. `node lookup.mjs '*出す'`) to
  find candidate JMDict IDs for a given suffix.

- **BCCWJ Frequency List (LUW v2)** — `BCCWJ_frequencylist_luw2_ver1_0.tsv` provides
  official frequency counts for Long Unit Words from the Balanced Corpus of
  Contemporary Written Japanese. This is preferred over NLB API because:
  - No rate limiting (instant lookup vs 60+ sec/request)
  - Standardized, versioned data (`luw2_ver1_0`)
  - Documented methodology (per-million-word normalization, LUW tokenization)
  - Fast static lookup vs dynamic API scraping
  
  The survey and classification scripts use this TSV to rank low-productivity
  examples by corpus frequency. Download from:
  http://doi.org/10.15084/00003214 and place `BCCWJ_frequencylist_luw2_ver1_0.tsv`
  in the `compound-verbs/` directory.

## Output JSON Schema

File: `compound-verbs.json`

```json
[
  {
    "id": "dasu-suffix",
    "kanji": "出す",
    "reading": "だす",
    "role": "suffix",
    "senses": [
      {
        "meaning": "start to V suddenly",
        "productivity": "high",
        "examples": [1234567, 2345678, 3456789]
      },
      {
        "meaning": "V outward, bring something forth",
        "productivity": "medium",
        "examples": [4567890, 5678901, 6789012]
      },
      {
        "meaning": "opaque / lexicalized — learn as vocabulary",
        "productivity": "low",
        "examples": [7890123, 8901234, 9012345, 1023456, 1123456, 1223456]
      }
    ]
  }
]
```

Field notes:
- `id` — stable kebab-case identifier, used to link from vocab metadata if needed later
- `kanji` / `reading` — display forms; reading is hiragana only (no kanji)
- `role` — always `"suffix"` for now; `"prefix"` reserved for future expansion
- `senses` — ordered array; `high` and `medium` entries come first, at most one `low`
  entry at the end. Multiple `high` / `medium` senses are expected (e.g. 出す has
  "start suddenly" and "bring outward" as distinct productive meanings).
- `senses[].meaning` — required for `high` and `medium`; optional for `low` (the app
  displays a default label "opaque / lexicalized — learn as vocabulary" when absent)
- `senses[].examples` — array of JMDict entry IDs (integers), ordered by usefulness
  as illustrations (most prototypical first for `high`/`medium`; most frequent
  by NLB corpus count first for `low`)

## Work Plan

### Phase 1 — Data preparation (Node.js + LLM)

**0. Survey script (`compound-verbs/survey.mjs`)** — already written

Inputs: `headwords.json`, `jmdict.sqlite`, optional list of target v2s.

For each v2 (default: all 470; in practice filtered to the target ~15):
- Pull all NINJAL entries with that v2, including their definitions and usage examples
- Resolve each compound's JMDict entry ID via sqlite (flag any misses)
- Output one JSON file per v2 (e.g. `compound-verbs/survey/出す.json`) containing
  the enriched entry list

The script is designed to run for all v2s so that future expansion requires no
code changes — just running it again and feeding more output files to the LLM.

**1. LLM Pass 1: Discover Suffix Meanings (`compound-verbs/cluster-meanings.mjs`)**

Given all compounds for a suffix (with all their JMDict and NINJAL senses), ask the
LLM to identify the distinct meanings the suffix contributes as a component.

Input: one survey file (e.g. `compound-verbs/survey/出す.json`), trimmed to the top ~75%
or top 50 (whichever is larger) by cumulative BCCWJ frequency for large suffixes. (`python3
plot-one.py v2 込む` can output the table of compounds sorted by frequency and cumulative
%.)

The prompt presents every compound with all its senses (JMDict and NINJAL together,
with BCCWJ frequency noted). The LLM returns a short list of distinct suffix-meaning
descriptions — for example, for 立てる: "do V vigorously or intensely", "bring into
an upright or established state", "raise or put up forcefully". These are the
productive meanings the suffix can contribute across all its compounds.

Output: `compound-verbs/clusters/出す-meanings-<timestamp>-<model>.json` (timestamped
archive) plus a canonical `compound-verbs/clusters/出す-meanings.json` (latest run).
All LLM pass scripts follow this same caching convention so run history is preserved
for comparison without overwriting prior results.

```json
[
  { "meaning": "start to V suddenly", "productivity": "high" },
  { "meaning": "V outward, bring something forth", "productivity": "medium" }
]
```

The lexicalized tail is not enumerated here — Pass 3 derives it as
`allCompounds − union(all meaning assignment arrays)`, with no LLM prompt surface.

**2. LLM Pass 2: Assign Compounds to Meanings (`compound-verbs/assign-examples.mjs`)**

One LLM call per productive meaning identified in Pass 1. Each call asks: given this
meaning description and all the compounds for this suffix, which compounds (and which
of their senses) exemplify this meaning?

Input: the meanings file from Pass 1 plus the survey file. The prompt quotes the
meaning description verbatim from the Pass 1 output so the wording is consistent
across runs and easy to trace.

Running one call per meaning (rather than one big assignment call) keeps each prompt
focused and makes it easy to re-run a single meaning if the examples look wrong.

Compounds that no meaning call claims become the lexicalized tail in Pass 3 — no
additional prompt needed.

Output: `compound-verbs/clusters/出す-assignments-<timestamp>-<model>.json` (archive)
plus canonical `compound-verbs/clusters/出す-assignments.json` (latest run).
```json
{
  "start to V suddenly":            ["言い出す", "走り出す", "泣き出す"],
  "V outward, bring something forth": ["引き出す", "取り出す"]
}
```
Keys are verbatim meaning strings from `出す-meanings.json`. A compound may appear
under more than one meaning if different senses of the same headword evince different
suffix meanings.

**3. Enrich and generate JSON (`compound-verbs/select-examples.mjs`)**

Merges the meanings and assignments files, resolves headwords to JMDict IDs via the
survey file, and sorts examples by BCCWJ frequency descending within each sense.
Compounds without JMDict IDs are excluded from the final output (they may have
informed the meaning discovery in Pass 1 but cannot be linked from the app).

Output: writes the final suffix entry to `compound-verbs.json` via the writer script.

**4. Writer script (`compound-verbs/write.mjs`)**

A small script that accepts structured operations and applies them to
`compound-verbs.json`. Operations it supports:

- `replace-entry <suffix-id> <entry-json>` — wholesale replace a suffix's entry
  (used when reruns any pass)
- `add-example <suffix-id> <sense-index> <jmdict-id>` — append an example to a sense
- `move-example <suffix-id> <from-sense-index> <to-sense-index> <jmdict-id>` — reclassify
  an example into a different sense
- `remove-example <suffix-id> <jmdict-id>` — remove an example from wherever it appears
- `add-sense <suffix-id> <sense-json>` — append a new sense to a suffix
- `edit-sense-meaning <suffix-id> <sense-index> <new-meaning>` — update a sense's
  description text
- `edit-sense-productivity <suffix-id> <sense-index> <productivity>` — change
  productivity rating

This script is called by pass 3 to write the final JSON, and can be used directly
by hand for incremental tweaks without rerunning all LLM passes.

**5. Validation script (`compound-verbs/validate.mjs`)**

Runs as a final check and as a pre-commit gate:
- Every JMDict ID in `compound-verbs.json` exists in `jmdict.sqlite`
- No JMDict ID appears more than once within a single suffix entry
- All required fields present and typed correctly
- No suffix ID is duplicated at the top level

### Phase 2 — iOS (Swift / SwiftUI)

1. **Load compound-verbs.json.** Add `compound-verbs.json` to the app bundle.
   Write a `CompoundVerbStore` (or extend an existing store) that loads the file
   at startup and provides two lookups:
   - by JMDict entry ID → which suffix entry (if any) contains this word
   - by suffix ID → full suffix entry with all senses and example IDs

2. **WordDetailSheet link.** When the word being displayed appears as an example
   in any compound verb suffix entry, show a "Part of ~suffix compound verb family"
   row that navigates to CompoundVerbDetailSheet. Follow the existing pattern used
   for the transitive pair link.

3. **CompoundVerbDetailSheet.** Displays:
   - Suffix kanji + reading + role header
   - Each sense as a section: meaning, productivity badge, list of example words
     (fetched from JMDict by ID, shown with furigana and primary English gloss)
   - A "Browse by prefix" section listing all corpus words that share the same
     v1 (prefix stem), grouped under their base verb — derived at runtime from
     vocab.json IDs cross-referenced against compound-verbs.json

4. **Prefix browser.** Within CompoundVerbDetailSheet, tapping a prefix group
   (e.g. "歩き~") shows sibling compounds using that prefix across *all* suffixes
   in the store. This is a filtered view, not a new sheet, since the data is
   already loaded.

## Open Questions

- Should low-productivity ("opaque") examples link to their WordDetailSheet on tap,
  or just display inline? Probably tap-to-WordDetailSheet, consistent with how
  transitive pair entries work.

- The prefix browser requires knowing which corpus words are compound verbs and what
  their v1 stem is. This is resolved by the `compoundV1` / `compoundV2` fields in
  vocab.json (see Decisions above): the app groups corpus entries by `compoundV1` at
  runtime to build the prefix browser, no additional data needed.

- **How many distinct meanings should Pass 1 return?** This is an open research
  question — too few meanings collapse genuinely different patterns; too many produce
  hairsplitting distinctions that are not useful to learners. The script should
  accept a `--meanings-range MIN MAX` argument (e.g. `--meanings-range 3 7`) so the
  range can be varied and results compared across runs. What the right range is for a
  given suffix size is unknown and worth experimenting on the first few suffixes before
  fixing defaults.

- How many suffixes to ship in v1? Suggest starting with the top 6 by NINJAL
  frequency (込む, 上げる, 出す, 付ける, 上がる, 入れる) and expanding based on
  what appears in the corpus.

## Action Items

- [ ] **Update README.md** with requirement to download and place
  `BCCWJ_frequencylist_luw2_ver1_0.tsv` in the `compound-verbs/` directory before
  running classification scripts. Link to http://doi.org/10.15084/00003214
- [ ] **Write `compound-verbs/cluster-meanings.mjs`** (Pass 1)
- [ ] **Write `compound-verbs/assign-examples.mjs`** (Pass 2)

---

## Appendix: Earlier Pipeline Design (Rejected)

The original plan used a per-compound LLM pass (Pass 1) that rated the productivity
of each sense of each compound individually, followed by clustering passes (Pass 2a/2b)
that grouped compounds by suffix meaning.

**Why it was rejected:**

1. **Pass 1 was redundant.** Rating productivity per-compound requires the same
   holistic judgment about suffix meanings that the clustering step needs anyway.
   There is no clean intermediate output: the per-sense ratings get collapsed to a
   single compound-level label immediately, discarding the reasoning, and the
   clustering step has to re-derive suffix meanings from scratch.

2. **Inconsistent role descriptions across independent calls.** Because each compound
   was processed in isolation, the same underlying suffix meaning could be described
   differently for different compounds ("adds vigorous force" vs "intensifies the
   action"). The clustering step then had to reconcile inconsistently-worded
   descriptions rather than clustering raw senses — harder than doing the clustering
   in one pass.

3. **Per-sense rating of a single compound is not the goal.** The student-facing
   output is a list of suffix meanings with example compounds, not a per-compound
   productivity score. Classifying each sense of each compound individually is more
   work than the final output requires.

4. **A single compound can evince multiple suffix meanings across its senses.**
   Collapsing to "max productivity" loses this signal entirely. The new design
   handles this naturally: a compound can appear under more than one meaning cluster
   in Pass 2.

The old scripts (`compound-verbs/classify-productivity.mjs` and the planned
`cluster-productive.mjs`, `cluster-medium.mjs`, `assemble-lexicalized.mjs`) are
superseded by the two-pass design above.
