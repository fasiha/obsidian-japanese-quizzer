# Compound Verb Browser — Design and Work Plan

- [Compound Verb Browser — Design and Work Plan](#compound-verb-browser--design-and-work-plan)
  - [Goal](#goal)
  - [Decisions](#decisions)
  - [Data Sources](#data-sources)
  - [Output JSON Schema](#output-json-schema)
  - [Work Plan](#work-plan)
    - [Phase 1 — Data preparation (Node.js + LLM)](#phase-1--data-preparation-nodejs--llm)
    - [Phase 2 — iOS (Swift / SwiftUI)](#phase-2--ios-swift--swiftui)
  - [Open Questions](#open-questions)
  - [Meaning Quality — Failure Modes and Validation](#meaning-quality--failure-modes-and-validation)
    - [Pass 1b: Sharpening (`sharpen-meanings.mjs`)](#pass-1b-sharpening-sharpen-meaningsmjs)
    - [Meaning quality: failure modes and evaluation (observed across 立てる, 出す, 付ける, 上がる, 付く)](#meaning-quality-failure-modes-and-evaluation-observed-across-立てる-出す-付ける-上がる-付く)
    - [Pass 2b: Validation (`validate-assignments.mjs`)](#pass-2b-validation-validate-assignmentsmjs)
    - [Recommended workflow per v2](#recommended-workflow-per-v2)
  - [Action Items](#action-items)
  - [Appendix: Earlier Pipeline Design (Rejected)](#appendix-earlier-pipeline-design-rejected)

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

- **No changes to vocab.json for compound verb data.** `compound-verbs.json` is
  bundled in the app (like `transitive-pairs.json`). iOS builds a reverse map at
  startup — JMDict ID → (suffix entry, sense index) — so `WordDetailSheet` just
  does a single lookup. `vocab.json` stays untouched. The v1 stem needed by the
  prefix browser is derived at runtime by stripping the v2 suffix kanji from the
  compound's kanji form; no stored field is needed.

- **Compound verbs not in VV Lexicon.** Some JMDict verb entries are compound verbs
  that NINJAL did not include in their lexicon — e.g. 震え出す (JMDict 1633520,
  "to begin to tremble") is a perfectly regular compound of 震える + 出す but is
  absent from `headwords.json`. To handle these, a Node.js script runs MeCab on
  every verb entry in the corpus that is not already in `compound-verbs.json`. If
  MeCab tokenizes the kanji form as `[動詞-一般][動詞-非自立可能]` (general verb +
  bound verb) and the second token's dictionary form matches a known suffix in
  `compound-verbs.json`, the compound is assigned a sense via a lightweight Haiku
  classification call, then added to `compound-verbs.json` as
  `{ "id": "<jmdict-id>", "source": "pug-inferred" }` in the matched sense's
  examples array. If the second token is not a known suffix, the word is skipped
  with a warning (unknown suffix — out of scope for now). Because the inferred
  examples live in `compound-verbs.json`, iOS picks them up through the same reverse
  map with no special handling.

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
        "specializedMeaning": "For the subject to begin <verb>-ing abruptly or spontaneously…",
        "examples": [
          { "id": "1234567", "source": "vvlexicon", "v1Id": "1111111" },
          { "id": "2345678", "source": "vvlexicon", "v1Id": "2222222" }
        ]
      },
      {
        "meaning": "V outward, bring something forth",
        "specializedMeaning": "For something previously internal or concealed to <verb> outward…",
        "examples": [
          { "id": "4567890", "source": "vvlexicon", "v1Id": "4444444" },
          { "id": "5678901", "source": "pug-inferred", "v1Id": "5555555" }
        ]
      },
      {
        "meaning": "",
        "examples": [
          { "id": "7890123", "source": "vvlexicon", "v1Id": "7777777" },
          { "id": "8901234", "source": "vvlexicon", "v1Id": "8888888" }
        ]
      }
    ]
  }
]
```

Field notes:
- `id` — stable kebab-case identifier, used to link from vocab metadata if needed later
- `kanji` / `reading` — display forms; reading is hiragana only (no kanji)
- `jmdictId` — JMDict entry ID string for the suffix verb itself; null if not found
- `role` — always `"suffix"` for now; `"prefix"` reserved for future expansion
- `senses` — ordered array of meaning senses, with a final lexicalized sense at the end
  if any compounds were unassigned. Multiple productive senses are expected (e.g. 出す has
  "start suddenly" and "bring outward" as distinct meanings).
- `senses[].meaning` — learner-friendly display string from Pass 1 (`<v2>-meanings.json`).
  Empty string `""` for the final lexicalized/opaque sense (the app signals this state by
  the absence of a meaning label, not by a fixed string).
- `senses[].specializedMeaning` — optional. Present when a sharpened meanings file was
  used during Pass 2 (`<v2>-meanings-sharpened.json`). Contains the precise, unambiguous
  classification rule written by Pass 1b. Omitted when sharpened and original strings are
  identical, and omitted on the lexicalized sense. Useful for future LLM passes and for
  debugging classification decisions; not intended as primary display text.
- `senses[].examples` — array of `{id, source, v1Id?}` objects, ordered by BCCWJ
  frequency descending. Compounds without JMDict IDs are excluded. All ID fields are
  decimal strings (strings are used rather than integers because some JMDict IDs
  exceed JavaScript's `Number.MAX_SAFE_INTEGER`). `source` is one of:
  - `"vvlexicon"` — compound appears in the NINJAL VV Lexicon (`headwords.json`)
  - `"pug-inferred"` — not in VV Lexicon; v1/v2 split inferred via MeCab, sense
    assigned via LLM classification against the known suffix senses
- `senses[].examples[].v1Id` — optional JMDict entry ID string for the base verb (v1).
  Present whenever v1 was found in JMDict — which is attempted for every entry
  regardless of whether the compound itself is in JMDict. vvlexicon sometimes stores
  multiple kanji spellings for v1 as a comma-separated string (e.g. `擦る,摺る,摩る`);
  survey.mjs tries each in turn. Some v1s are genuinely absent from JMDict (archaic,
  colloquial, or kana-only verbs). Missing `v1Id` always produces a warning, never an
  error. Enables iOS to link to the base verb's WordDetailSheet and to group
  prefix-browser siblings by base verb rather than raw masu-stem string.

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

**1. LLM Pass 1: Discover Suffix Meanings (`compound-verbs/cluster-meanings.mjs`)** — written

Input: one survey file (e.g. `compound-verbs/survey/出す.json`), trimmed to the top ~75%
or top 50 (whichever is larger) by cumulative BCCWJ frequency for large suffixes. (`python3
plot-one.py v2 込む` can output the table of compounds sorted by frequency and cumulative
%.)

The LLM is asked: "what does appending -V2 to a verb do to it?" — framed as a learner
orientation task, not a corpus analysis. The prompt opens with an 込む few-shot example
(Imabi's four usages: go inside / put inside / remain as-is / do thoroughly) to calibrate
the desired abstraction level — broad roles covering many compounds, not fine-grained
sense distinctions.

The script has several prompt modes selectable by flag:
- `--simple` — sends only the headword list; relies on the LLM's own knowledge of the compounds
- `--simple-with-senses jmdict|ninjal|both` — sends headwords plus selected sense sources
- (default, no flag) full prompt — sends complete JMDict + NINJAL senses with detailed instructions

In practice, `--simple` and `--simple-with-senses ninjal` produced the cleanest learner-oriented
output in testing on 出す. The full prompt tends to over-split when unconstrained. The right
mode for rare suffixes (where the LLM has less prior knowledge) is an open question.

The prompt instructs the LLM to prefer broad roles and err on the side of merging. Each role
must be a genuine recurring pattern, not a description that fits only one or two compounds.

Output: `compound-verbs/clusters/出す-meanings-<timestamp>-<model>.json` (timestamped
archive) plus a canonical `compound-verbs/clusters/出す-meanings.json` (latest run).
The raw LLM response text is also saved as a `.txt` file alongside each archive.

Example output from `--simple` (Haiku, headwords only, no sense data):
```json
[
  { "meaning": "to bring/take out or extract something from a place or state" },
  { "meaning": "to begin or start an action, often with a sense of initiative" },
  { "meaning": "to reveal, expose, or produce something previously hidden" }
]
```

The lexicalized tail is not enumerated here — Pass 3 derives it as
`allCompounds − union(all meaning assignment arrays)`, with no LLM prompt surface.

**1b. LLM Pass 1b: Sharpen Meanings (`compound-verbs/sharpen-meanings.mjs`)** — written

Rewrites Pass 1 meanings as precise, unambiguous classification rules. See the Meaning Quality section for failure modes this pass addresses. The sharpened meanings are written to `<v2>-meanings-sharpened.json`; the original `<v2>-meanings.json` is preserved as user-facing display text. Use `--use-sharpened` in Pass 2 to classify against the sharpened meanings.

**2. LLM Pass 2: Assign Compounds to Meanings (`compound-verbs/assign-examples.mjs`)** — written

One LLM call for all meanings at once. The model sees the full list of meanings and
the full compound list, and assigns each compound to whichever meaning(s) it fits.
A compound may legitimately appear under more than one meaning (e.g. 打ち返す fits
both "reverse an action" and "reciprocate"). Compounds assigned to no meaning become
the lexicalized tail in Pass 3 — no additional prompt needed.

Input: the meanings file from Pass 1 plus the survey file. The prompt quotes all
meaning descriptions verbatim from the Pass 1 output.

**Prompt design notes (from testing on 返す):**
- One call for all meanings avoids cross-call conservatism: with per-meaning calls,
  Haiku already globally categorizes all compounds in its reasoning for call 1, then
  hedges on borderline words in later calls ("belongs to another meaning"), causing
  valid assignments to be missed. One call makes the same global decision explicitly.
- Rare compounds (BCCWJ frequency = 0 or no JMDict ID) should be augmented inline
  with their NINJAL gloss so the model can categorize them confidently:
  `誘い返す（invite back in return）`. Common compounds Haiku already knows from
  training data do not need the gloss.
- The prompt should explicitly permit a compound to appear under multiple meanings.
- When a compound is ambiguous between two meanings, the prompt should direct the model
  to assign it to both rather than omit it. Omission should be reserved for compounds
  where the role of the suffix is genuinely unpredictable (opaque or fully lexicalized).
  Without this distinction, the model conflates "ambiguous between meanings" with
  "opaque", inflating the lexicalized tail with compositional compounds that just happen
  to fit more than one meaning.

**Multi-run voting:** the archive `.txt` files (one per run) are the source of truth
for individual calls. The canonical `assignments.json` is always a flat object — the
best current result for Pass 3. If vote aggregation across multiple runs is desired,
a separate script reads N archive `.txt` files, tallies assignments, and writes the
merged `assignments.json`. This keeps the format simple and the aggregation auditable.
Do not store arrays of arrays in `assignments.json` — you cannot distinguish "same
prompt sampled N times" from "N different prompt experiments" without storing the
full prompt alongside each run, which the `.txt` archives already do.

Output: `compound-verbs/clusters/<v2>-assignments-<timestamp>-<model>.txt` (archive
that includes flags, prompt, and model output) plus canonical
`compound-verbs/clusters/<v2>-assignments.json` (latest run).
```json
{
  "start to V suddenly":            ["言い出す", "走り出す", "泣き出す"],
  "V outward, bring something forth": ["引き出す", "取り出す", "言い出す"]
}
```
Keys are verbatim meaning strings from `<v2>-meanings.json`. A compound may appear
under more than one meaning key.

**2b. LLM Pass 2b: Validate Assignments (`compound-verbs/validate-assignments.mjs`)** — written

Sends the assignments and meanings to Sonnet, which flags misclassifications, incorrectly lexicalized compounds, and missing multi-assignments. Output is advisory — human review required before applying corrections. See the Meaning Quality section for details.

Output: `compound-verbs/clusters/<v2>-validation-<timestamp>-<model>.txt` — contains the flags header, the full prompt, and the model's reasoning followed by a JSON blob at the end:
```json
{
  "flags": [
    {
      "headword": "のし上がる",
      "issue": "misclassified",
      "suggested": ["For the subject to <verb> such that something swells…"],
      "reason": "…"
    }
  ]
}
```

**2c. Apply Validation Flags (`compound-verbs/apply-validation.mjs`)** — not yet written

Bridges the advisory validation flags from Pass 2b into the canonical `assignments.json`.
Human review happens by editing the validation txt file before running this script —
delete any flag lines you disagree with, then run the script to apply the rest.

Usage:
```
node compound-verbs/apply-validation.mjs <v2>-validation-<timestamp>-<model>.txt
```

The script:
1. Parses the JSON blob from the bottom of the txt file (everything after the last `` ` `` ` `` `json` `` ` `` ` `` fence)
2. Reads `<v2>-assignments.json` (derived from the suffix in the txt file's flags header)
3. Applies each flag to the assignments:
   - `misclassified` — removes the compound from all its current meaning keys, adds it to the `suggested` meanings
   - `should-be-assigned` — adds the compound to the `suggested` meanings (it was absent from all keys)
   - `missing-multi-assignment` — adds the compound to the `suggested` meanings while keeping existing assignments
4. Writes the updated `assignments.json` in-place

**3. Enrich and generate JSON (`compound-verbs/select-examples.mjs`)** — written

Reads the corrected `assignments.json` (after Pass 2c), both `<v2>-meanings.json` and
`<v2>-meanings-sharpened.json` (if present), and the survey file. Builds the final
suffix entry for `compound-verbs.json`.

Steps:
1. Load `assignments.json` — keys are the sharpened meaning strings (or original strings if no sharpened file exists)
2. Load `meanings.json` and `meanings-sharpened.json` — match keys in `assignments.json` to original display strings by index position
3. For each meaning, collect all assigned compounds, resolve each to its JMDict ID via the survey file, and sort by BCCWJ frequency descending
4. Derive the lexicalized set: all compounds in the survey file that appear in no meaning key in `assignments.json`; resolve to JMDict IDs and sort by BCCWJ frequency descending
5. Build the suffix entry object: one sense per meaning (using the original display string as `meaning`), plus a final lexicalized sense (`meaning: ""`) if any unassigned compounds had JMDict IDs
6. When sharpened meanings were used as assignment keys, each productive sense also gets `specializedMeaning` set to the sharpened string
7. Compounds without JMDict IDs are excluded from all senses (they may have informed meaning discovery in Pass 1 but cannot be linked from the app)

Output: calls `write.mjs replace-entry` to upsert the entry into `compound-verbs.json`.

Usage:
```
node compound-verbs/select-examples.mjs <v2>
node compound-verbs/select-examples.mjs <v2> --dry-run
```

**4. Writer script (`compound-verbs/write.mjs`)** — written

A small script that accepts structured operations and applies them to
`compound-verbs.json`. Creates the file as an empty array if it does not exist yet.
Operations it supports:

- `replace-entry <suffix-id> <entry-json>` — wholesale replace (or insert) a suffix's
  entry; `<entry-json>` may be a path to a JSON file or an inline JSON string
- `add-example <suffix-id> <sense-index> <jmdict-id>` — append an example to a sense
- `move-example <suffix-id> <from-sense-index> <to-sense-index> <jmdict-id>` — reclassify
  an example into a different sense
- `remove-example <suffix-id> <jmdict-id>` — remove an example from wherever it appears
- `add-sense <suffix-id> <sense-json>` — append a new sense to a suffix
- `edit-sense-meaning <suffix-id> <sense-index> <new-meaning>` — update a sense's
  description text

This script is called by Pass 3 to write the final JSON, and can be used directly
by hand for incremental tweaks without rerunning all LLM passes.

**5. Schema integrity check (`compound-verbs/validate.mjs`)** — not yet written

Runs as a final check and as a pre-commit gate on the finished `compound-verbs.json`:
- Every JMDict ID exists in `jmdict.sqlite`
- No JMDict ID appears more than once within a single suffix entry
- All required fields present and typed correctly
- No suffix ID is duplicated at the top level

Note: this is distinct from Pass 2b (`validate-assignments.mjs`), which validates semantic correctness of LLM assignments before they reach `compound-verbs.json`.

**6. Inferred compound detection (`.claude/scripts/check-compound-verbs.mjs`)** — ✅ implemented

Module exports three functions and integrates into `prepare-publish.mjs` workflow:
- `parseMecabOutput(output)` — parse MeCab tokenization output
- `analyzeWithMecab(kanjiForm)` — detect compound verb structure, returning v1 + suffix forms
- `checkAndUpdateCompoundVerbs(options)` — main orchestration function

Integration:
- Runs automatically at the end of `prepare-publish.mjs` workflow (after vocab/grammar compilation)
- Respects `--no-llm` flag to skip LLM calls
- Supports `--max-compound-verbs N` flag to limit LLM calls per run
- Usage: `node prepare-publish.mjs [--no-llm] [--max-compound-verbs N]`

Workflow:
1. Build a set of JMDict IDs already present in `compound-verbs.json` examples.
2. For each verb entry in `vocab.json` not already flagged as non-compound, run MeCab on its kanji form.
3. If the output is exactly two tokens with POS `動詞-一般` then `動詞-非自立可能`, treat it as a compound verb candidate. Otherwise skip — mark as `notCompound: true` in vocab.json to avoid re-checking.
4. Extract the v1 base form (first token dictionary form) from MeCab output.
5. Look up the v2 (suffix) dictionary form in `compound-verbs.json`. If not found, warn and skip (unknown suffix — out of scope for now).
6. Batch all candidates for a given suffix together and send one Haiku call to assign each to a sense. The prompt provides the suffix's senses from `compound-verbs.json` and each candidate's JMDict gloss; asks for the best-fit sense index (or `null` for opaque/unclassifiable).
7. Add each inferred compound to the appropriate suffix entry in `compound-verbs.json` as `{ "id": "<jmdict-id>", "source": "pug-inferred", "v1Id": "<v1-jmdict-id>" }` in the matched sense's examples array (or the lexicalized sense if unclassified).
8. Persist verbs found to not be compound verbs in `vocab.json` with `notCompound: true` flag so we skip the check next time.

**v1Id enrichment:** After classifying compounds with Haiku, look up each v1 base form in JMDict to get its JMDict ID and add it as `v1Id` to the example. This ensures pug-inferred compounds have the same structure as vvlexicon examples (which get v1Id from survey files).

**Design decisions:**
- v1Id comes from JMDict lookup (not survey files), making this approach work for verbs not in the NLB study
- Filtering skips: already-marked non-compounds, IDs already in compound-verbs.json, non-verbs
- Unknown suffixes emit a warning and skip the verb (compound-verbs.json is manually curated; new suffixes must be added before we can classify)

**Known gap:** 震え出す (JMDict 1633520, "to begin to tremble") is the first observed
example: in JMDict, not in `headwords.json`, MeCab tokenizes it as 震える + 出す.

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

- **Should Pass 1 include JMDict senses for the v1 (base verb) of each compound?**
  The purpose of Pass 1 is to identify what the suffix v2 *adds* to the base verb v1.
  If the model does not know v1, seeing only the compound sense may not let it
  decompose the contribution correctly. Counterargument: the top-50 by BCCWJ frequency
  tend to have common, well-known v1s; rare v1s cluster in the low-frequency tail that
  gets trimmed. In practice this may never matter — but if Pass 1 results look confused
  for less common v1s, try including their JMDict senses in the prompt.

- **How many distinct meanings should Pass 1 return, and which prompt mode to use?**
  Tested on 出す, 立てる, 返す across Haiku, Sonnet, and Opus: `--simple --no-productivity
  --allow-reasoning` (no sense data, LLM uses prior knowledge, no productivity labels,
  reasoning before JSON) consistently produced 3–4 clean broad roles and the models
  converged closely. The full prompt tends to over-split when unconstrained. Haiku
  is good enough and much cheaper; variation between models looks like sampling noise
  rather than a capability gap. **Standard invocation for Pass 1:**
  `node compound-verbs/cluster-meanings.mjs <v2> --simple --no-productivity --allow-reasoning`
  The open question is whether `--simple` holds up for rare v2s where the LLM has less
  training data — in that case `--simple-with-senses ninjal` or `both` may be necessary.

- How many suffixes to ship in v1? Suggest starting with the top 6 by NINJAL
  frequency (込む, 上げる, 出す, 付ける, 上がる, 入れる) and expanding based on
  what appears in the corpus.

## Meaning Quality — Failure Modes and Validation

Pass 1 (`cluster-meanings.mjs`) optimises for human comprehension — its output is evocative and learner-friendly but the boundaries between meanings can be fuzzy. Pass 2 (`assign-examples.mjs`) uses those meanings as classifiers, so fuzzy boundaries cause compounds to land in the wrong bucket.

### Pass 1b: Sharpening (`sharpen-meanings.mjs`)

An optional sharpening pass sits between Pass 1 and Pass 2. It sends the Pass 1 meanings plus the full compound list to the LLM and asks it to rewrite each meaning as an unambiguous classification rule. Technical linguistic terms are explicitly encouraged (precision over learner-friendliness). The sharpened meanings are written to `<v2>-meanings-sharpened.json`, leaving the original `<v2>-meanings.json` untouched for use as user-facing display text.

Pass 2 and Pass 2b automatically use the sharpened meanings file if it exists (`<v2>-meanings-sharpened.json`), logging a bright notice to stdout. If the sharpened file is absent, both scripts fall back to `<v2>-meanings.json` silently.

To promote sharpened meanings to canonical: `cp compound-verbs/clusters/<v2>-meanings-sharpened.json compound-verbs/clusters/<v2>-meanings.json`

**Caveat:** the sharpening pass sees the same compound list it will later classify, which gives it an unfair advantage when evaluated on that same list. Test on a held-out v2 when possible.

**Prompt decisions (cluster-meanings.mjs):** the Pass 1 prompt was updated based on testing across 立てる, 出す, 付ける, 上がる, 付く, 上げる, 返す:
- The "N4–N5 level" framing was replaced with "for a Japanese language learning app." The level label was causing the model to silently skip patterns it judged too advanced (including the 上げる honorific use), while the app framing still anchors the desired abstraction level without implying a difficulty ceiling.
- The hard "1–4" numeric cap is kept (4 maximum), with "err on the side of merging" as the tie-breaking instruction. Raising the cap is tempting when a genuine 5th pattern exists, but in practice the right fix is a manual edit to `<v2>-meanings.json` — letting the model decide to add a 5th meaning produces over-splitting.

**Prompt decisions (sharpen-meanings.mjs):** two bullets were added to the sharpening prompt:
- *Symmetric exclusions:* if meaning 3 excludes meaning 2, meaning 2 must also exclude meaning 3. Testing showed the model applies this reliably for adjacent, semantically close meaning pairs (where it matters most) but may skip it for distant pairs. Asymmetric exclusions between semantically distant meanings did not cause observable classification errors.
- *Gap detection:* scan the compound list for any compound that does not fit any draft meaning and name it explicitly. This fires reliably and is the main mechanism for catching honorific-use gaps before Pass 2.

### Meaning quality: failure modes and evaluation (observed across 立てる, 出す, 付ける, 上がる, 付く)

These are pitfalls in how meanings are worded and how to spot them in assignment output. Wording failures are all fixable in the sharpening pass; evaluation items apply after each assignment run.

**1. Missing `<verb>` placeholder** — every meaning string must include `<verb>` explicitly, showing where v1 fits (e.g. "to `<verb>` someone into action"). When absent, the semantic role of v1 is ambiguous and compounds land in the wrong bucket.
*How to spot:* any meaning where you can't tell from the string what the prefix verb is doing.

**2. Over-broad object type** — writing "someone/something" as the object of a meaning conflates distinct semantic patterns. Specify the object type precisely: "a person" vs "a physical object" vs "an abstract result." Example: "propel someone/something" merged motivational-drive compounds (駆り立てる) with physical-force compounds (突き立てる).
*How to spot:* siblings in a bucket have clearly different object types (one is a person, another is a physical thing).

**3. Catch-all residual meanings** — vague intensifiers ("emphatic," "assertive") or broad qualifiers ("emotional state," "magnitude") cause a meaning to absorb anything that doesn't fit elsewhere. Fix: replace vague qualifiers with concrete observable properties, and add explicit negative exclusions pointing at adjacent meanings (see item 4).
*How to spot:* one bucket is disproportionately large; its compounds share no obvious common thread beyond "doesn't fit the others."

**4. Adjacent meanings need explicit negative exclusions** — when two meanings share a family resemblance (both involve outward motion, both involve upward change), a positive description alone is not enough. Each meaning must explicitly exclude the adjacent one by name. Examples that worked: "something that did not previously exist (not extract or reveal something hidden)" for 出す meaning 3; "excludes upward spatial movement (meaning 1) and processes that simply reach exhaustion or completion (meaning 2)" for 上がる meaning 3. These exact phrases were later cited in the validator's reasoning when it correctly flagged misclassifications.
*How to spot:* the same compound plausibly fits two adjacent meanings with no clear tiebreaker.

**5. Over-inclusive or over-restrictive physical-contact wording** — contact meanings can fail in both directions. Too restrictive: "adheres or bonds" excludes tying, placing, and writing, pushing those compounds into the lexicalized bucket. Too inclusive: the contact type must still be specific enough not to overlap with an adjacent meaning. Use wording that covers the full range of physical contact for the suffix in question (e.g. "including by tying, applying, placing, or writing onto it").
*How to spot:* compositional compounds end up lexicalized (too restrictive), or physically-different operations share a bucket (too inclusive).

**6. Bucket size and sibling coherence** — after each assignment run, check: do siblings within a bucket share a clear, equally teachable relationship with v1? If not, meaning wording needs tightening. Zero multi-assignments despite obvious candidates suggests meanings are over-narrow or assignment rules too strict.

**7. Validator flags are advisory** — Pass 2b (validate-assignments.mjs) flags misclassifications, incorrectly lexicalized compounds, and missing multi-assignments. Treat each flag as a question, not a command. Polysemous compounds with both literal and metaphorical uses (e.g. 持ち上がる: "be lifted up" vs "a problem comes up") may be correctly left under one meaning. Apply only flags where the reasoning is unambiguous.

**8. Missing honorific/register-marker meaning** — some suffixes (上げる being the clearest case) have a productive honorific or humble-register use (謙譲語/尊敬語) that is semantically distinct from all other meanings and will not be discovered by Pass 1 unless prompted explicitly. The cluster-meanings prompt does not mention keigo — adding such a hint risks spurious honorific meanings for suffixes where one or two edge-case compounds should simply be lexicalized. Instead: after Pass 1, check whether any high-frequency compounds (top 10 by BCCWJ) are unaccounted for by the proposed meanings. If a clear register-marker pattern emerges, add it manually to `<v2>-meanings.json` before running Pass 1b. The sharpening pass will flag unaccounted compounds in its reasoning (due to the gap-detection bullet) but cannot add a meaning on its own.
*How to spot:* a high-frequency compound like 申し上げる, 差し上げる, or 存じ上げる sits at the top of the corpus list but fits none of the proposed meanings.

### Pass 2b: Validation (`validate-assignments.mjs`)

Written and tested on 上がる. Reads the assignments JSON and sends it to Sonnet with the meanings, asking it to flag:
- Compounds assigned to a meaning they don't fit (misclassified)
- Compounds in the lexicalized bucket that appear compositional (should-be-assigned)
- Compounds that belong under multiple meanings but were only assigned to one (missing-multi-assignment)

Sonnet is preferred over Haiku for this pass because the task requires subtle semantic judgment rather than classification throughput. On the 上がる run: correctly identified 6 misclassifications, 3 incorrectly lexicalized compounds, and 4 missing multi-assignments across 79 compounds.

### Proposed Pass 2 redesign: per-compound assignment with full semantic context

**Background.** The original Pass 2 (`assign-examples.mjs`) sends all compounds for a suffix to the LLM in a single prompt with one-line glosses (or no glosses). Testing revealed three problems:

1. **Single-sense glosses mislead classification.** The `--all-glosses` flag only showed the first JMDict sense. For compounds with multiple senses mapping to different suffix meanings (38% of 出す compounds), this biased the model. Example: 弾き出す shown as "to flick out" hid "to calculate" (lexicalized) and "to expel" (M4). This likely explains why all-glosses runs hurt Claude — incomplete glosses were worse than no glosses.

2. **No prefix verb context.** Without seeing what the prefix verb (v1) alone means, the model cannot distinguish "suffix adds meaning" from "suffix adds nothing." 弾く already means "to calculate"; 弾き出す also means "to calculate" — so -出す contributes nothing for that sense. But the model sees the compound's gloss and tries to assign a suffix meaning anyway.

3. **Joint prompts don't produce cross-compound reasoning.** Analysis of thinking traces from the validation experiment showed models reason compound-by-compound even when given all compounds together. The joint context intended to help calibration goes largely unused.

**New approach: `assign-per-compound.py`.** Each compound gets a prompt containing:
- All suffix meanings (from the sharpened meanings file, as before)
- All JMDict senses of the compound verb (not just the first)
- All JMDict senses of the prefix verb (v1), looked up by both kanji and reading to disambiguate homographs (e.g., 弾く はじく "to flick" vs ひく "to play an instrument")

The model compares compound senses against prefix verb senses to determine what -出す adds per sense. A compound sense that matches a prefix verb sense exactly is lexicalized for that sense. A compound can be assigned to multiple meanings if different senses reflect different suffix contributions, and still be lexicalized for other senses.

Compounds are processed in batches (default 25 per prompt) with rate-limit retry logic. The suffix verb's own dictionary senses are *not* included — the sharpened meanings are the classification authority and the raw dictionary senses can conflict with them.

**Tested on 出す with Haiku (25 compounds, 5 runs: 1 solo + 4 batch).**

Reasoning quality: dramatically better than the original joint approach. The model correctly identified lexicalized senses that no previous run caught:
- 弾き出す sense 2 "to calculate" → lexicalized (弾く already means "to calculate")
- 切り出す sense 3 "to start a fire" → lexicalized (切る sense 22 is identical)
- 思い出す "to recall" → lexicalized (思う sense 8 is "to recall; to remember")

Solo-vs-batch variance: **47% exact agreement.** Batch-vs-batch variance: **50% exact agreement.** These are statistically indistinguishable — batching does not introduce systematic bias beyond normal temperature noise. 11/25 compounds (44%) were stable across all 5 runs (4+ of 5 agreeing); the remaining 14 are genuinely ambiguous.

**Proposed production workflow:**

1. Pass 1 + 1b: generate and sharpen meanings (unchanged)
2. Pass 2: `python3 compound-verbs/assign-per-compound.py --suffix <v2> --all --batch-size 25` — run 3 times with Haiku
3. Dawid-Skene consensus across the 3 runs: stable compounds (3/3 agree) ship directly; unstable compounds (split votes) are flagged for optional human review
4. Skip Pass 2b (validation) — the validation experiment showed self-validation does not improve D-S consensus, and D-S on 3 raw runs provides a natural confidence signal

This eliminates Pass 2b, Pass 2c, and human review of validation flags from the workflow. The only human review point is the meanings themselves (Pass 1b) and optionally the unstable compounds from D-S.

**Cost estimate for all suffixes:** ~470 suffixes × ~30 compounds average × 3 runs ÷ 25 per batch ≈ 1,700 Haiku calls. At Haiku pricing this is approximately $2–5 total, completing in ~15 minutes of parallelized API time.

**Remaining bottleneck:** Only 5 of 470 suffixes have meanings files. The meanings pipeline (Pass 1 + 1b) needs to run for the remaining suffixes before per-compound assignment can proceed. Most suffixes have fewer compounds than 出す and simpler semantics; batch generation with spot-check review of the top 20 suffixes by compound count is likely sufficient.

### Recommended workflow per v2 (original, see above for proposed replacement)

Check where you are at any time:
```
node compound-verbs/status.mjs <v2>          # one suffix
node compound-verbs/status.mjs               # all known suffixes
```

`status.mjs` reads the cluster files for each suffix and prints a checklist of
completed passes with the exact command to run next. It derives "validation
applied" from `_metadata.validations_applied` in `assignments.json`, which
`apply-validation.mjs` stamps on each run.

1. Pass 1: `node compound-verbs/cluster-meanings.mjs <v2> --simple --no-productivity --allow-reasoning`
2. Pass 1b: `node compound-verbs/sharpen-meanings.mjs <v2>` — review sharpened meanings before continuing
3. Pass 2: `node compound-verbs/assign-examples.mjs <v2>` (Haiku — auto-uses sharpened meanings if present)
4. Pass 2b: `node compound-verbs/validate-assignments.mjs <v2>` (Sonnet — auto-uses sharpened meanings if present)
5. Human review — edit the validation txt file to remove any flags you disagree with
6. Pass 2c: `node compound-verbs/apply-validation.mjs clusters/<v2>-validation-<timestamp>.txt`
   (repeat steps 3–6 if major restructuring is needed)
7. Pass 3: `node compound-verbs/select-examples.mjs <v2>`
8. `validate.mjs` — schema integrity check (not yet written)

## Action Items

- [ ] **Write `compound-verbs/infer-from-corpus.mjs`** (Phase 1 step 6):
  MeCab tokenization of corpus verb entries not already in compound-verbs.json,
  batched Haiku sense assignment, add `pug-inferred` examples to compound-verbs.json.
  First test case: 震え出す (JMDict 1633520).
- [ ] **Update README.md** with requirement to download and place
  `BCCWJ_frequencylist_luw2_ver1_0.tsv` in the `compound-verbs/` directory before
  running classification scripts. Link to http://doi.org/10.15084/00003214
- [x] **Write `compound-verbs/cluster-meanings.mjs`** (Pass 1) — written and tested on 出す
- [ ] **Run Pass 1 on target suffixes** (込む, 上げる, 出す, 付ける, 上がる, 入れる) — use `--simple --no-productivity --allow-reasoning` (standard invocation)
- [ ] **Rewrite `compound-verbs/assign-examples.mjs`** (Pass 2) — first version written and tested on 返す; needs: (a) collapse to one LLM call for all meanings, (b) augment rare/unknown compounds with NINJAL gloss inline, (c) permit multi-meaning assignment explicitly in prompt

---

## Appendix: Model Comparison for Pass 2 (Assignment)

### Background

Pass 2 asks an LLM to assign each compound to one or more suffix meanings, or to omit it as lexicalized/opaque. 12 model configurations were evaluated on 立てる (51 compounds, 4 meanings) and 出す (100 compounds, 4 meanings):

- **Gemini 2.5 Flash and Pro** ("fast" and "think") — ran with rare glosses only and with all glosses
- **Claude Sonnet 4 and Haiku 4.5** — ran with rare glosses only and with all glosses
- **Gemma 4 31b** (dense, ~12 tokens/second locally) — ran with all glosses at temperatures 1.2 and 1.5
- **Gemma 4 26b-a4b** (mixture-of-experts, ~48 tokens/second locally) — ran with all glosses at temperatures 1.2 and 1.5

Earlier Gemma runs at temperature 1.0 with rare glosses only are excluded from the comparison. Those runs had two confounding problems: Gemma 4 performs substantially better at temperature 1.2–1.5 (per Reddit anecdotes), and without glosses the Gemma models lack the kanji-to-meaning knowledge needed to classify most compounds — they were failing at word recognition, not classification reasoning.

Raw bucket-size tables: `node compound-verbs/validate-comparison.mjs`

### Why glosses matter (and why they help some models but hurt others)

Adding English glosses to all compounds (`--all-glosses`) dramatically improved Gemma results: 31b went from 58 unassigned to 1–3 on 出す; 26b-a4b went from 68 to 5–12. This confirmed that the original evaluation was testing kanji recall, not classification capability.

The same glosses *hurt* Claude on 出す: Sonnet went from 1 unassigned to 39; Haiku went from 15 to 23. Gemini was unaffected (0→2 for think, 6→6 for fast). This is a Claude-specific pattern — the English definitions appear to introduce hesitation that Claude's Japanese intuition would otherwise resolve confidently. For Gemma, which lacks that Japanese intuition, the glosses provide essential information.

**Practical consequence:** use `--all-glosses` for local Gemma runs; do not use it for Claude API runs.

### Principled evaluation: binary Dawid-Skene

Counting unassigned compounds is a poor metric — a model that assigns everything is not necessarily better than one that omits a few genuinely opaque items. To compare models properly, we use inter-annotator reliability methods from the multi-annotator labeling literature.

Each compound is decomposed into 4 independent binary questions: "does -立てる/-出す contribute meaning M_k in this compound? yes or no." A compound assigned to M1+M2 contributes "yes" to M1 and M2, "no" to M3 and M4. An omitted compound contributes "no" to all four. This avoids modeling "omit" as a special class and naturally handles multi-label assignments.

For each binary problem we compute:

1. **Krippendorff's Alpha** — measures inter-rater agreement beyond chance. Tells us how well-defined each meaning is as a classification target, independent of which models we're using.
2. **Dawid-Skene EM** — jointly estimates the true latent label for each compound and a sensitivity/specificity profile for each rater. Down-weights unreliable raters rather than treating all models as equally credible.

Full output: `compound-verbs/analysis.md`
Script: `python3 compound-verbs/annotator-analysis.py`

### Per-meaning task quality (Krippendorff's Alpha)

**立てる** — mean α = 0.751

| Meaning | α | Interpretation |
|---------|---|----------------|
| M1 (vertical/pile) | 0.757 | acceptable |
| M2 (intensity/repetition) | 0.788 | acceptable |
| M3 (formal/legal) | 1.000 | perfect agreement |
| M4 (transform/status) | 0.458 | tentative — needs sharper definition |

**出す** — mean α = 0.590

| Meaning | α | Interpretation |
|---------|---|----------------|
| M1 (extract) | 0.455 | tentative |
| M2 (sudden begin) | 0.584 | tentative |
| M3 (create/produce) | 0.700 | acceptable |
| M4 (forced removal) | 0.620 | tentative |

立てる M3 (formal/legal) has perfect agreement — every model classifies 申し立てる and 打ち立てる the same way. 立てる M4 (transformation) and 出す M1 (extraction) are the weakest — these are the meanings whose definitions would benefit most from further sharpening.

The low α for 出す M1 (0.455) is the dominant issue: extraction is the largest bucket and the one with the most boundary disputes against M4 (forced removal). Models disagree on whether 投げ出す, 引っ張り出す, 救い出す, etc. involve force or not.

### Per-model quality (Dawid-Skene balanced accuracy)

**立てる** — ranked by mean of (sensitivity + specificity) / 2 across all four meanings:

| Rank | Model | Balanced accuracy |
|------|-------|-------------------|
| 1 | Sonnet (rare glosses only) | 82% |
| 2 | Haiku (all glosses) | 79% |
| 3 | Sonnet (all glosses) | 79% |
| 4 | Gemini-fast (all glosses) | 79% |
| 5 | Gemini-think (rare glosses only) | 77% |
| 6–7 | Haiku (rare glosses only), 31b@1.2 | 77% |
| 8–9 | Gemini-think (all glosses), 31b@1.5 | 75% |
| 10 | Gemini-fast (rare glosses only) | 74% |
| 11 | 26b-a4b@1.2 | 73% |
| 12 | 26b-a4b@1.5 | 70% |

**出す** — same metric:

| Rank | Model | Balanced accuracy |
|------|-------|-------------------|
| 1 | 26b-a4b@1.5 (all glosses) | 91% |
| 2 | 26b-a4b@1.2 (all glosses) | 88% |
| 3 | 31b@1.5 (all glosses) | 86% |
| 4 | Sonnet (rare glosses only) | 86% |
| 5 | 31b@1.2 (all glosses) | 85% |
| 6–7 | Haiku (all glosses), Haiku (rare glosses only) | 84% |
| 8–10 | Gemini-think (rare), Gemini-think (all), Gemini-fast (rare) | 81% |
| 11 | Gemini-fast (all glosses) | 80% |
| 12 | Sonnet (all glosses) | 78% |

The rankings differ strikingly between suffixes. 26b-a4b is last on 立てる but first on 出す. This is not noise — the sensitivity/specificity breakdown reveals why:

- For **立てる**, 26b-a4b has very low M4 sensitivity (25%) — it almost never detects functional transformation. It defaults to M2 (intensity) for ambiguous cases. The M1/M4 distinction in 立てる requires Japanese semantic intuition about spatial vs. functional metaphor that goes beyond what the English gloss conveys.
- For **出す**, all four meanings map more directly onto the English glosses ("extract," "begin suddenly," "create," "force out"), so 26b-a4b's reliance on gloss-based reasoning is not a liability. Its high specificity across the board (≥80%) means when it does assign, it's usually right.

### Systematic biases

The Dawid-Skene confusion matrices reveal consistent patterns:

- **31b and 26b-a4b** have a "M4→omit" bias on 立てる (57% of true-M4 compounds are omitted). These models are blind to functional transformation for this suffix.
- **Sonnet** has the opposite bias: "omit→M4" (100% — when a compound should be omitted, Sonnet assigns it to M4 instead). Sonnet over-assigns transformation.
- **Claude models** (Sonnet and Haiku) show high M4 sensitivity for 出す but also push many M1 (extraction) compounds into M4 (forced removal) — they read coercion into compounds other models treat as simple extraction.
- **Gemini models** tend to collapse multi-label compounds into M1 only, missing the secondary meaning.

### Dawid-Skene vs. majority vote

Dawid-Skene disagrees with majority vote on 9 items for 立てる and 22 for 出す. Nearly all disagreements involve D-S finding a multi-label assignment where majority vote picks one:

Examples from 立てる: 組み立てる → D-S says M1+M4 ("both structural assembly and transformation to finished product"), majority says M1 only. 塗り立てる → D-S says M2+M4 ("both intensity and transformation"), majority says M2 only.

These multi-label findings are arguably more pedagogically useful — showing a learner that 組み立てる involves *both* structural building and transformation to a usable product is more accurate than forcing one meaning.

### Practical conclusions

1. **No single model dominates.** Sonnet (rare glosses only) is best for 立てる; 26b-a4b (all glosses) is best for 出す. Model selection should depend on the suffix's characteristics.
2. **Use `--all-glosses` for Gemma, rare glosses only for Claude.** This single prompt decision is more impactful than model choice or temperature.
3. **The biggest quality gains come from better meaning definitions, not better models.** 立てる M4 (α=0.458) and 出す M1 (α=0.455) are where human effort should focus.
4. **Multi-label assignment is real.** Dawid-Skene identifies ~10–20% of compounds per suffix as genuinely belonging to two meanings. The pipeline should preserve this rather than forcing single-label.
5. **Local Gemma 4 models are competitive** for Pass 2 when given glosses and appropriate temperature. 26b-a4b at ~48 tokens/second is practical for rapid iteration; 31b at ~12 tokens/second is more reliable across suffix types.

### Appendix: Validation experiment (Pass 2b vs Dawid-Skene)

**Question:** Does adding a validation pass (Pass 2b) improve consensus labels, or can we skip it and rely on Dawid-Skene over raw multi-classifier assignments?

**Setup:** `compound-verbs/validation-experiment.py` runs self-validation: each annotator's assignments are sent back to the same model as a validation prompt, flags are applied, and Krippendorff's alpha is compared before and after. Tested on 出す and 立てる with Gemma 26b-a4b (temperatures 1.2 and 1.5) and 31b (temperature 1.2).

**Findings:**

1. **Self-validation does not improve Dawid-Skene consensus.** Mean alpha was flat or slightly negative across every run tested (range: -0.008 to +0.003). The validator improves its own balanced accuracy (+2–3%) while degrading other annotators' accuracy (-1–4%), indicating it's homogenizing toward its own biases rather than correcting genuine errors.

2. **The validator reasons compound-by-compound.** Despite seeing all assignments grouped by meaning, the model's thinking trace shows independent per-compound reasoning with no systematic cross-compound comparisons. The joint context intended to help the model compare siblings within a bucket goes unused.

3. **Glosses significantly affect flag quality.** Runs without glosses produced fewer flags; runs with glosses produced more but also surfaced a deeper problem (see item 4). The model's reasoning quality improved with glosses — less hallucination about what compounds mean — but this didn't translate to better consensus.

4. **Single-sense glosses actively mislead classification.** The original `--all-glosses` flag in assign-examples.mjs only showed the first JMDict sense. For compounds with multiple senses mapping to different suffix meanings (38% of 出す compounds), this biased both assignment and validation. Example: 弾き出す shown as "to flick out" (sense 1 → M1) hid "to calculate" (sense 2 → lexicalized) and "to expel" (sense 3 → M4). This likely explains why all-glosses runs *hurt* Claude in the assignment benchmarks — incomplete glosses were worse than no glosses.

5. **Missing prefix verb context.** Without seeing what the prefix verb (v1) alone means, the model cannot distinguish "suffix adds meaning" from "suffix adds nothing." 弾く already means "to calculate"; 弾き出す also means "to calculate" — so -出す contributes nothing here (lexicalized). But the model sees the compound's gloss and tries to assign a suffix meaning anyway.

**Conclusion:** Skip the validation pass for production. Use Dawid-Skene directly on 3–4 raw classifier outputs. Invest effort instead in improving the assignment prompt: show all JMDict senses (not just the first) and include prefix verb glosses so the model can identify what the suffix actually contributes.

**Open questions:**
- Would cross-validation (a *different* model reviewing assignments) help more than self-validation? The self-validation trap (model agrees with itself) might not apply.
- Would per-compound validation (asking about one compound at a time with full context) produce better reasoning than the current all-at-once prompt?
- After fixing the all-senses gloss issue, do the "rare glosses only" vs "all glosses" rankings change for Claude?
