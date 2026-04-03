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

- **NINJAL Language Bank (NLB) API** — the `NLB_link` field in `headwords.json`
  (e.g. `V.05546`) is a key into several NLB endpoints that return frequency and
  usage data as JSON:
  - `https://nlb.ninjal.ac.jp/basicinfob/V.05546/` — basic info (balanced corpus)
  - `https://nlb.ninjal.ac.jp/basicinfosc/V.05546/` — spoken corpus
  - `https://nlb.ninjal.ac.jp/basicinfosj/V.05546/` — written corpus
  - `https://nlb.ninjal.ac.jp/patternfreqorder/V.05546/` — argument pattern frequencies
  
  The survey script can fetch frequency data for each compound word to rank
  low-productivity examples by real-world usage rather than guessing.

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

The pipeline separates mechanical data gathering from LLM analysis, and further
decomposes the LLM work into focused, single-purpose passes that are easier to
understand, debug, and iterate on.

**0. Survey script (`compound-verbs/survey.mjs`)**

Inputs: `headwords.json`, `jmdict.sqlite`, optional list of target v2s.

For each v2 (default: all 470; in practice filtered to the target ~15):
- Pull all NINJAL entries with that v2, including their definitions and usage examples
- Resolve each compound's JMDict entry ID via sqlite (flag any misses)
- Output one JSON file per v2 (e.g. `compound-verbs/survey/出す.json`) containing
  the enriched entry list; NLB frequency is intentionally not fetched here

The script is designed to run for all v2s so that future expansion requires no
code changes — just running it again and feeding more output files to the LLM.

**1. NLB frequency fetcher (`compound-verbs/fetch-nlb.mjs`)**

A separate script that runs independently and incrementally:
- Scans all files in `compound-verbs/survey/` for words missing NLB data
- Checks `compound-verbs/nlb-cache.json` (a flat map of `NLB_link → full API
  response`) to skip already-fetched entries
- For each missing entry, fetches `https://nlb.ninjal.ac.jp/basicinfob/{NLB_link}/`
  and saves the entire response payload into `nlb-cache.json`
- Waits a random delay between requests (e.g. 30–120 seconds) to avoid overwhelming
  the server
- Is safe to interrupt and rerun — it only fetches what is not yet cached

`nlb-cache.json` is kept locally only. Subsequent LLM passes read frequency from 
this cache rather than hitting the API themselves. If the cache is lost, the 
fetcher script can rebuild it by rescraping.

**2. LLM Pass 1: Productivity Classification (`compound-verbs/classify-productivity.mjs`)**

Classifies each compound verb individually (one LLM call per compound).

Input: one survey file (e.g. `compound-verbs/survey/出す.json`) plus relevant
NLB cache entries and `jmdict.sqlite` for v1 and v2 definitions. Refuses to proceed
if any word lacks NLB data — user must run the fetcher first.

For each compound, the LLM classifies it as:
- `highly-productive` — meaning is transparently compositional from base + suffix
- `medium` — partially idiomatic or restricted to certain verb types
- `fully-lexicalized` — opaque, must be learned as standalone vocabulary

The prompt includes:
- JMDict definitions of v1 (base verb) and v2 (suffix) if available
- JMDict senses of the compound itself
- NINJAL characterization of the compound
- Explicit instruction that VVLexicon and JMDict may disagree, and the task is to
  judge whether the pattern is productive, not to reconcile the sources

Output: `compound-verbs/classify/出す.jsonl` (one JSON object per line, one per compound)
with fields: `{ headword, reading, v1, classification, reasoning }`.

**3. LLM Pass 2a: Cluster High-Productivity Compounds (`compound-verbs/cluster-productive.mjs`)**

Groups highly-productive compounds by the distinct *meanings* the suffix contributes.

Input: the `jsonl` file from Pass 1 (filtered to `classification: "highly-productive"`).

The LLM identifies all distinct senses and clusters the compounds under each. Output:
`compound-verbs/clusters/出す-productive.json` with fields per sense: `{ meaning, examples: [headwords] }`.

**4. LLM Pass 2b: Cluster Medium Compounds (`compound-verbs/cluster-medium.mjs`)**

Groups medium compounds by meaning.

Input: the `jsonl` file from Pass 1 (filtered to `classification: "medium"`).

Output: `compound-verbs/clusters/出す-medium.json` with the same schema as 2a.

**5. Assemble Lexicalized Senses (`compound-verbs/assemble-lexicalized.mjs`)**

No LLM call — each fully-lexicalized compound from Pass 1 becomes its own sense.

Input: the `jsonl` file from Pass 1 (filtered to `classification: "fully-lexicalized"`).

Output: `compound-verbs/clusters/出す-lexicalized.json`, one sense per compound.

**6. Pass 3: Enrich and Generate JSON (`compound-verbs/select-examples.mjs`)**

Merges the three cluster files from steps 3–5 and enriches them with JMDict data.

Inputs:
- `compound-verbs/clusters/出す-productive.json`
- `compound-verbs/clusters/出す-medium.json`
- `compound-verbs/clusters/出す-lexicalized.json`
- The original survey file (for JMDict IDs and frequency data)

For each sense, includes all compounds that have a JMDict ID (compounds without
JMDict IDs are excluded from the final output but may have informed the sense
clustering in Pass 2a/2b). The examples array contains only JMDict IDs, sorted
by NLB frequency descending. The iOS app or any downstream processor decides
how many examples to display.

Output: generates the final entry JSON and writes it to `compound-verbs.json` via
a call to the writer script (below).

**7. Writer script (`compound-verbs/write.mjs`)**

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

**8. Validation script (`compound-verbs/validate.mjs`)**

Runs as a final check and as a pre-commit gate:
- Every JMDict ID in `compound-verbs.json` exists in `jmdict.sqlite`
- No JMDict ID appears more than once within a single suffix entry
- All required fields present and typed correctly
- No suffix ID is duplicated at the top level

### Phase 2 — iOS (Swift / SwiftUI)

5. **Load compound-verbs.json.** Add `compound-verbs.json` to the app bundle.
   Write a `CompoundVerbStore` (or extend an existing store) that loads the file
   at startup and provides two lookups:
   - by JMDict entry ID → which suffix entry (if any) contains this word
   - by suffix ID → full suffix entry with all senses and example IDs

6. **WordDetailSheet link.** When the word being displayed appears as an example
   in any compound verb suffix entry, show a "Part of ~suffix compound verb family"
   row that navigates to CompoundVerbDetailSheet. Follow the existing pattern used
   for the transitive pair link.

7. **CompoundVerbDetailSheet.** Displays:
   - Suffix kanji + reading + role header
   - Each sense as a section: meaning, productivity badge, list of example words
     (fetched from JMDict by ID, shown with furigana and primary English gloss)
   - A "Browse by prefix" section listing all corpus words that share the same
     v1 (prefix stem), grouped under their base verb — derived at runtime from
     vocab.json IDs cross-referenced against compound-verbs.json

8. **Prefix browser.** Within CompoundVerbDetailSheet, tapping a prefix group
   (e.g. "歩き~") shows sibling compounds using that prefix across *all* suffixes
   in the store. This is a filtered view, not a new sheet, since the data is
   already loaded.

## Open Questions

- Should low-productivity ("opaque") examples link to their WordDetailSheet on tap,
  or just display inline? Probably tap-to-WordDetailSheet, consistent with how
  transitive pair entries work.

- The prefix browser (step 8) requires knowing which corpus words are compound verbs
  and what their v1 stem is. This is resolved by the `compoundV1` / `compoundV2`
  fields in vocab.json (see Decisions above): the app groups corpus entries by
  `compoundV1` at runtime to build the prefix browser, no additional data needed.

- How many suffixes to ship in v1? Suggest starting with the top 6 by NINJAL
  frequency (込む, 上げる, 出す, 付ける, 上がる, 入れる) and expanding based on
  what appears in the corpus.
