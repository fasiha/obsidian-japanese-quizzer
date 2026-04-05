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
        "specializedMeaning": "For the subject to begin <verb>-ing abruptly or spontaneously…",
        "examples": [1234567, 2345678, 3456789]
      },
      {
        "meaning": "V outward, bring something forth",
        "specializedMeaning": "For something previously internal or concealed to <verb> outward…",
        "examples": [4567890, 5678901, 6789012]
      },
      {
        "meaning": "",
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
- `senses[].examples` — array of JMDict entry IDs (integers), ordered by BCCWJ frequency
  descending. Compounds without JMDict IDs are excluded.

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

### Pass 2b: Validation (`validate-assignments.mjs`)

Written and tested on 上がる. Reads the assignments JSON and sends it to Sonnet with the meanings, asking it to flag:
- Compounds assigned to a meaning they don't fit (misclassified)
- Compounds in the lexicalized bucket that appear compositional (should-be-assigned)
- Compounds that belong under multiple meanings but were only assigned to one (missing-multi-assignment)

Sonnet is preferred over Haiku for this pass because the task requires subtle semantic judgment rather than classification throughput. On the 上がる run: correctly identified 6 misclassifications, 3 incorrectly lexicalized compounds, and 4 missing multi-assignments across 79 compounds.

### Recommended workflow per v2

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

- [ ] **Update README.md** with requirement to download and place
  `BCCWJ_frequencylist_luw2_ver1_0.tsv` in the `compound-verbs/` directory before
  running classification scripts. Link to http://doi.org/10.15084/00003214
- [x] **Write `compound-verbs/cluster-meanings.mjs`** (Pass 1) — written and tested on 出す
- [ ] **Run Pass 1 on target suffixes** (込む, 上げる, 出す, 付ける, 上がる, 入れる) — use `--simple --no-productivity --allow-reasoning` (standard invocation)
- [ ] **Rewrite `compound-verbs/assign-examples.mjs`** (Pass 2) — first version written and tested on 返す; needs: (a) collapse to one LLM call for all meanings, (b) augment rare/unknown compounds with NINJAL gloss inline, (c) permit multi-meaning assignment explicitly in prompt

---

## Appendix: Gemma 4 Model Evaluation Against Failure Modes (2026-04-05)

### Background

Pass 1b (sharpening) was originally developed and tested with Claude Haiku. Two local Gemma 4 models were then run through the same pipeline on the same five suffixes (出す, 付く, 立てる, 返す, 歩く):

- **google-gemma-4-31b** — dense 31-billion-parameter model, ~3 tokens/second on a local laptop, zero API cost
- **google-gemma-4-26b-a4b** — mixture-of-experts 26B-active-4B model, ~30 tokens/second locally, zero API cost

Output lives in `compound-verbs/gemma-clusters/`. Haiku runs from the same date are in `compound-verbs/clusters/` (files timestamped `2026-04-05_04-2*`).

### Confound: prompt version difference

The Gemma runs were produced with an **earlier version** of `sharpen-meanings.mjs`. Two instructions present in the Haiku prompt were absent from the Gemma prompt:

1. *"Exclusions between adjacent meanings must be symmetric: if meaning 3 says 'excludes meaning 2', then meaning 2 must also say 'excludes meaning 3'. Check every pair of meanings and ensure the exclusion boundary is stated in both directions."*
2. *"Before writing your answer, scan the compound list for any compound that does not fit any of the draft meanings. Name it and explain why."*

This means any Gemma weakness on failure mode 4 (missing symmetric exclusions) or on lexicalized-compound detection is at least partly a prompt effect, not purely a model capability difference. A fair model comparison requires re-running all three models with identical prompts. See the re-run plan below.

Additionally, the Gemma and Haiku sharpening runs processed **different draft meanings** as input — because Pass 1 (`cluster-meanings.mjs`) was also run separately for each model, producing different starting clusters for 出す (Haiku produced 4 meanings; Gemma-26b-a4b produced 3; Gemma-31b got 4 but differently worded). This means we are evaluating the whole pipeline (Pass 1 + Pass 1b) per model, not just the sharpening step in isolation.

### Rubric: mapping failure modes to observable signals

The seven failure modes from the main document map to these observable checks on a sharpened-meanings file:

| Check | Failure mode | What to look for in the JSON |
|-------|-------------|------------------------------|
| **A** | 1 — missing `<verb>` | Every meaning string contains the literal token `<verb>` |
| **B** | 2 — over-broad object | No meaning uses "someone/something" as object without further qualification |
| **C** | 3 — catch-all residual | Reasoning section explicitly names the at-risk meaning and adds concrete exclusions |
| **D** | 4 — asymmetric exclusions | Every pair of adjacent meanings that one member excludes is also excluded in the other direction |
| **E** | 5 — contact wording | Meanings about physical attachment mention at least two contact modalities (adhesion, clinging, wrapping, etc.) |
| **F** | 6 — bucket coherence | Not evaluable without an assignment run; deferred to Phase 2 |
| **G** | faithfulness | Output count matches input count (no merging or splitting of meanings) |

Checks A–E and G can be scored on the existing files with no additional LLM calls.

### Qualitative scoring of existing files

**`<verb>` placeholder (check A)**

All three models include `<verb>` in their final JSON across all suffixes, but the phrasing style differs:

- *Haiku*: natural active construction — `"to <verb> and come out / become visible"`
- *Gemma-31b*: natural — `"To <verb> such that a tangible object ... moves"`
- *Gemma-26b-a4b*: passive frame — `"To cause the prefix <verb> to result in..."` — technically present but the phrase `"prefix <verb>"` is non-standard and could confuse a downstream classifier that substitutes a verb form for `<verb>` literally

**Symmetric exclusions (check D)**

This is the sharpest difference and is at least partly confounded by the prompt version:

- *Haiku* (newer prompt): fully symmetric in all four suffixes reviewed. Explicitly labels directions: `"Excludes: ... (meaning 2); ... (meaning 3)."` and the corresponding reverse exclusions appear in meanings 2 and 3.
- *Gemma-31b* (older prompt): exclusions appear in reasoning prose but are **inconsistently carried into the final JSON**. For 返す, the final JSON has zero cross-references despite the reasoning identifying the boundary risks. For 立てる, meaning 2 excludes meanings 3 and 4 but meanings 3 and 4 do not exclude meaning 2.
- *Gemma-26b-a4b* (older prompt): partially symmetric in 立てる (`"excludes purely vertical movement and purely repetitive/noisy temporal patterns"` appears in multiple meanings). For 出す, exclusions appear in prose but only meaning 3 carries them into the JSON.

**Catch-all identification (check C)**

All three models correctly identify the at-risk meaning in their reasoning. Gemma-31b's identification for 立てる is notably narrow — it restricts meaning 2 to *vocalizations and insistent behaviors* only, which likely pushes 煮立てる (bring to a boil) into the lexicalized tail even though it is compositional. Haiku's identification for 立てる correctly notes that the vehemence/intensity meaning risks becoming residual, and gives concrete examples (掻き立てる, 責め立てる, 攻め立てる) to calibrate the boundary.

**Lexicalized compound detection (check implicit)**

Haiku explicitly names 見立てる as fitting none of the 立てる meanings and recommends lexicalized treatment. Neither Gemma model surfaced this — though the older prompt did not ask them to. This check is only meaningful with the updated prompt.

**Meaning faithfulness (check G)**

- *Gemma-31b*: ✓ for all four suffixes reviewed (output count = input count)
- *Gemma-26b-a4b*: ✓ where input was 3 meanings, output was 3; where input was 4, output was 4 (for 付く)
- *Haiku*: ✓ generally faithful; for 付く the starting cluster happened to produce only 2 meanings and the sharpened output stayed at 2

**Summary table (existing runs, older prompt for Gemma)**

| | Gemma-31b | Gemma-26b-a4b | Haiku |
|-|-----------|---------------|-------|
| A — `<verb>` present | ✓ | partial (passive frame) | ✓ |
| B — no over-broad object | ✓ | ✓ | ✓ |
| C — catch-all named | ✓ | ✓ | ✓ (with examples) |
| D — symmetric exclusions | ✗ (prose only) | partial | ✓ |
| E — contact wording | ✓ (付く run) | ✓ | ✓ |
| G — faithful count | ✓ | ✓ | ✓ |

### Re-run plan (normalize the prompt variable)

Before drawing conclusions about model capability, re-run sharpening for 出す, 付く, 立てる, and 返す through both Gemma models using the *current* `sharpen-meanings.mjs` (which includes symmetric-exclusion and lexicalized-compound-scan instructions). Use the **same Pass 1 clusters** as the Haiku runs (copy the canonical `<v2>-meanings.json` files before running) to also eliminate the cluster-input variable.

```bash
# For each suffix: copy Haiku's cluster as the canonical, then run sharpening with each Gemma model
node compound-verbs/sharpen-meanings.mjs 出す   # run once per model via --model flag or env var
node compound-verbs/sharpen-meanings.mjs 付く
node compound-verbs/sharpen-meanings.mjs 立てる
node compound-verbs/sharpen-meanings.mjs 返す
```

Note: `sharpen-meanings.mjs` currently hardcodes the Haiku API. Gemma runs required patching the model endpoint to point at the local LM Studio server. The flag or environment variable to select the model target may need to be formalized in the script before re-running.

### Downstream assignment evaluation (Phase 2)

Rubric scores are a proxy. The ground truth is whether the sharpened meanings lead to fewer misclassifications in Pass 2. For one suffix (出す, 100 compounds), run the full Pass 1b → Pass 2 → Pass 2b chain for each model's sharpened output and count validation flags from Pass 2b (Sonnet):

- Total flags (misclassified + incorrectly-lexicalized + missing-multi-assignment) is the primary metric
- Breakout: misclassified and incorrectly-lexicalized flags indicate boundary failures; missing-multi-assignment flags indicate over-narrow meanings

This is a roughly 3 × (Pass 2 + Pass 2b) = 6 LLM calls at Haiku and Sonnet prices — under $0.50 total. The Gemma assignment runs can use Haiku for Pass 2 (the assignment step) and Sonnet for Pass 2b (validation), same as the standard workflow.

### Hypothesis and practical recommendation

Based on the existing (older-prompt) runs:

- Gemma-31b produces technically sound output but under-specifies exclusions in the final JSON when the prompt does not explicitly require them. With the updated prompt, it likely performs comparably to Haiku on checks A–E. The 3 tok/s throughput makes it slow for sharpening (one suffix takes ~5 minutes) but perfectly acceptable for an infrequent, one-per-suffix pass.
- Gemma-26b-a4b's passive phrasing style ("To cause the prefix `<verb>` to result in...") is a consistent stylistic pattern that may confuse a downstream assignment classifier. Worth checking in Phase 2 whether this matters in practice.
- Haiku remains the default for Pass 1b until Phase 2 evidence suggests otherwise. The cost difference is small (sharpening is one call per suffix, not per compound).

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
