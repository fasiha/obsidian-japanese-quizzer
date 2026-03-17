# Tier 2 production: alternative extraction architectures

Chronological record of approaches tried, from earliest to latest.

Background: see `TODO-grammar.md` §"Tier 2 answer extraction: two-pass architecture
and grammar classification (2026-03-17)" for the full problem statement.

---

## Original — One-pass with embedded gaps (pre-`81e1755`, on `main`)

Generation prompt asked Haiku to write the sentence *with* `___` tokens already
embedded at the grammar slots. The sentence itself was the gapped display; no
extraction step needed.

**Abandoned because**: Haiku inconsistently placed the `___` — sometimes too wide
(blanking a full clause), sometimes too narrow (blanking only a particle when the
full conjugated form was needed). The model was simultaneously writing natural
Japanese and deciding what to hide, and it conflated content choices with form choices.

---

## One-pass substring extraction (`81e1755`, on `main`)

Generation prompt asks Haiku to write a complete sentence (no gaps) and then, in the
same call, quote the exact answer substrings from that sentence. The app blanks the
quoted substrings to produce the gapped display. The chain of thought instructs Haiku
to include the full conjugated form including stem + morpheme + any attached ending
(e.g. `弾けます` not just `ます`).

### Test results (2026-03-17, 3 runs each, worktree retest)

| Topic | Run | Extracted answers | Gap sentence | Pass/Fail | Notes |
|---|---|---|---|---|---|
| potential | 1 | `弾ける` | `難しいソナタが___ようになった` | ✅ | Clean full form |
| potential | 2 | *(only 1 run captured)* | | | |
| potential | 3 | *(only 1 run captured)* | | | |
| し | 1 | `低いし, 遠いし` | `給料が___、通勤が___` | ✅ | Over-includes predicate |
| し | 2 | `つまらないし, 遠いし` | `プレゼンが___、ホテルが___` | ✅ | Over-includes predicate |
| し | 3 | `つまらないし, あるし` | `パーティーは___、宿題も___` | ✅ | Over-includes predicate |
| たり-たりする | 1 | `弾いたり, 読んだりしている` | `ギターを___雑誌を___` | ✅ | Run 1: includes `している` in last answer |
| たり-たりする | 2 | `したり, 見たり` | `ゲームを___映画を___します` | ✅ | No closing する slot; `します` visible |
| たり-たりする | 3 | `読んだり, 聴いたり` | `本を___、音楽を___する` | ✅ | No closing する slot; `する` visible |

**Pattern**: One-pass reliably extracts the answer and passes validation, but for し it
consistently over-includes the predicate (`低いし` instead of `し`). For たり-たりする
the closing `する`/`している`/`します` is sometimes captured in the last answer (run 1),
sometimes left fully visible (runs 2–3) — inconsistent across runs.

---

## Two-pass extraction refinement (`dd864bf`, on `main`)

After the generation call produces a sentence, a second `refineAnswerExtraction` call
re-extracts the answer substrings with a focused "worksheet builder" prompt. This
separates sentence quality from extraction precision.

### Test results (2026-03-17)

**Historical results** (from TODO-grammar.md, "worksheet builder" prompt, mixed Haiku/Sonnet):

| Topic | Model | Extraction | Quality |
|---|---|---|---|
| genki:shi (し) | Haiku | `し, し, し` | ✅ Perfect — just the particle |
| genki:shi (し) | Haiku | `遠いし, 高いし, うるさいし` | ❌ Earlier prompt version — too greedy |
| bunpro:causative | Haiku | `させた` | ✅ Perfect — just the inflectional suffix |
| bunpro:Verb[potential] | Sonnet | `が書ける` | ⚠️ Slightly greedy — grabbed particle shift too |
| bunpro:たり-たりする | Sonnet | `んだり, したり` | ✅ Good — correct morpheme boundary |
| bunpro:たり-たりする | Haiku | `たり, たり, たり` | ⚠️ Works for た-row but would fail for だり |
| bunpro:たり-たりする (fixed expr category) | Haiku | `たり, たり, たり, する` | ❌ する conjugates in context → validation failure |

**Worktree retest (2026-03-17, 3 runs each, Haiku)**:

| Topic | Run | Extracted answers | Gap sentence | Pass/Fail | Notes |
|---|---|---|---|---|---|
| potential | 1 | `られる` | `難しい質問に答え___と思う` | ✅ | Clean suffix only |
| potential | 2 | *(validation fail — returned `られるようになった`, not in sentence)* | — | ❌ | Extracted form not verbatim in sentence |
| potential | 3 | `弾ける` | `簡単なメロディーが___ようになったね` | ✅ | Clean full form |
| し | 1 | `し, し, し` | `店長も厳しい___、給料も安い___、夜遅いシフトだ___` | ✅ | Perfect |
| し | 2 | `し, し, し` | `カリキュラムも厳しい___、教授も有名だ___、場所も美しい___` | ✅ | Perfect |
| し | 3 | `し, し` | `仕事場に近い___、レストランもたくさんある___` | ✅ | Perfect |
| たり-たりする | 1 | `たり, たり` | `映画を見___部屋を片付け___` | ✅ | Missing closing する slot |
| たり-たりする | 2 | `たり, たり, たり, した` | `コンサートに行っ___、映画を見___、庭仕事をし______` | ✅ | Correctly captures closing `した` |
| たり-たりする | 3 | `たり, たり, たり` | `雑誌を読んだり、ポッドキャストを聞い___、ノートに書い___した` | ✅ | Missing closing する; gap count wrong (3 answers but sentence shows 2 blanks + visible `した`) |

**Pattern**: Two-pass extraction is the only approach where し comes out clean (`し, し, し`)
consistently. For potential verbs it is mostly clean but has a 1-in-3 validation failure
(extracted form not verbatim in sentence). For たり-たりする it is inconsistent: sometimes
captures the closing する conjugation (run 2), sometimes drops it entirely (runs 1, 3).

---

## Approach A — Two-field generation (`experiment-1-two-field` branch)

### Core idea

The generation call emits two fields instead of one:

- `sentence`: the complete, correct Japanese sentence with no gaps
- `gapped`: the same sentence with grammar slot(s) marked using 【】 brackets

Example output JSON:
```json
{
  "sentence": "彼はギターが弾ける。",
  "gapped": "彼はギターが【弾ける】。",
  "english": "He can play guitar."
}
```

### Why it helps

The old single-pass approach asked Haiku to simultaneously write good Japanese *and*
decide what to blank. Splitting into two fields separates those concerns while keeping
both in one generation call — the model marks the gap while its reasoning is still
fresh, not in a separate re-reading pass.

### Validation

Strip 【content】 from `gapped`, replacing each bracket pair with its inner content,
and verify the result equals `sentence`. Any mismatch (hallucinated content inside
brackets, wrong verb form, etc.) is caught structurally before the question is shown
to the student. On validation failure, fall back to the two-pass extraction call or
the VOCAB_ASSUMED-softened over-extraction path.

### Multi-gap grammar

Works naturally: emit multiple bracket pairs.
```json
{
  "sentence": "部屋が広いし、駅にも近いし、いいアパートだ。",
  "gapped":   "部屋が広い【し】、駅にも近い【し】、いいアパートだ。",
  "english":  "The room is spacious, and it's close to the station too — it's a great apartment."
}
```

### Generation prompt change

Add to the JSON schema instructions:

```
"gapped": same sentence as "sentence" but with the grammar slot(s) wrapped in 【】.
Include only the grammar form inside the brackets — not the surrounding vocabulary
or verb stems. Validation: removing the brackets should reproduce "sentence" exactly.
```

### Tradeoffs

- Adds ~20–40 tokens to the generation output (the duplicated sentence)
- Eliminates the separate extraction call entirely for well-formed outputs
- Validation is a simple string equality check — fast, no LLM
- Does not require grammar category metadata

---

## Approach B — Structured token list

### Core idea

Replace the `sentence` string with a flat array that interleaves plain text segments
and cloze (blank) objects. The app assembles the display and knows the answers without
any extraction step.

Example output JSON for し:
```json
{
  "tokens": [
    "部屋が広い",
    {"blank": "し"},
    "、駅にも近い",
    {"blank": "し"},
    "、いいアパートだ。"
  ],
  "english": "The room is spacious, and it's close to the station too — it's a great apartment."
}
```

Example for potential verbs:
```json
{
  "tokens": [
    "彼はギターが",
    {"blank": "弾ける"},
    "。"
  ],
  "english": "He can play guitar."
}
```

### Why it helps

The blank is explicit in the data structure. There is no extraction problem — the
model emits the answer directly as a typed field. Validation: concatenating all
segments (replacing `{"blank": X}` with X) must produce a valid Japanese sentence.

### App rendering

```
plain_text + "___" + plain_text + "___" + plain_text
```

The answer array is `tokens.filter(isBlank).map(b => b.blank)`.
For multi-slot grammar the student fills each blank in order.

### Generation prompt change

Replace the `sentence` field instruction with:

```
"tokens": a JSON array. Each element is either a plain string (visible to the
student) or an object {"blank": "..."} (hidden — the student must produce this).
Put the grammar form(s) inside blank objects. Everything else is a plain string.
Concatenating all elements (substituting blank values) must produce a grammatical
Japanese sentence.
```

### Tradeoffs

- More structurally robust than string-with-markers (no bracket-stripping, no regex)
- Validation is a simple concatenation check
- Requires the app to render a token list rather than a plain string — modest UI change
- Generation is more constrained (structured JSON output); Haiku may need examples
  in the prompt to produce well-formed token arrays reliably
- Does not require grammar category metadata

---

## Approach C — Grammar-outward generation (`experiment-3-grammar-outward` branch)

### Core idea

Invert the chain of thought: make the grammar form the *anchor* that the sentence is
built around, rather than something extracted from a finished sentence.

Chain of thought for a conjugation grammar topic (e.g. potential verbs):

```
Step 1 — Grammar form: Write the target inflectional suffix/pattern (e.g. ける/られる).
Step 2 — Choose a verb: Pick a concrete verb that exercises this form.
          Avoid 食べる, 飲む, 泳ぐ — choose something varied.
Step 3 — Inflected form: Produce the fully inflected target string (e.g. 弾ける).
          This is the answer. Record it.
Step 4 — Build the sentence: Write a natural Japanese sentence containing the
          inflected form from Step 3. Do not introduce any other instance of the
          same grammar in the sentence.
Step 5 — English: Translate the sentence into natural English.
```

By the time the sentence exists, the answer (`弾ける`) is already recorded — it was
derived in Step 3 before the sentence was written. No extraction is needed.

### Multi-slot grammar

For grammar with multiple slots (し...し, たり...たりする, ば...ほど):

```
Step 1 — Pattern: Write the multi-slot pattern (e.g. ...し、...し).
Step 2 — Choose slot count: Decide how many instances (e.g. 3 for し).
Step 3 — Fill each slot: For each slot, choose a predicate and produce the
          inflected/attached form. Record all slot fills as an array.
Step 4 — Assemble the sentence: Combine the slot fills with connective tissue
          into a complete, natural Japanese sentence.
Step 5 — English: Translate.
```

### Output JSON

```json
{
  "answers": ["弾ける"],
  "sentence": "彼はギターが弾ける。",
  "english": "He can play guitar."
}
```

For multi-slot し:
```json
{
  "answers": ["し", "し", "し"],
  "sentence": "部屋が広いし、駅にも近いし、静かだし、いいアパートだ。",
  "english": "The room is spacious, it's close to the station, and it's quiet — it's a great apartment."
}
```

Validation: each answer in `answers` must appear as a verbatim substring of
`sentence`. The app reconstructs the gapped sentence by finding and blanking each
answer substring (left to right, first occurrence).

### Tradeoffs

- Chain of thought is grammar-category-specific — requires different Step 1–3
  instructions for conjugation vs. fixed expressions vs. grammatical frames
- For fixed expressions (し, から, はず), Step 2 ("choose a verb") doesn't apply —
  the chain of thought simplifies to: choose predicates, then assemble
- Answers array is small and unambiguous; validation is fast string search
- Generation prompt is longer (multi-step reasoning) but likely improves sentence
  quality by forcing the model to commit to its grammar form before writing prose
- Rendaku / phonological variants (たり → だり): Step 3 naturally produces the
  correct surface form because the model chooses the verb first, then inflects;
  the resulting `だり` or `たり` is whatever the model produces, and validation
  just checks it appears in the sentence

---

## Comparison

| | Approach A (two-field) | Approach B (token list) | Approach C (grammar-outward) |
|---|---|---|---|
| Extraction call needed | Never (on success) | Never | Never |
| Validation | String equality | Concatenation check | Substring search |
| Prompt complexity | Low | Medium | Medium–High |
| App change needed | No (parse brackets) | Yes (render token list) | No (substring blank) |
| Multi-gap support | Yes | Yes (natural) | Yes (answers array) |
| Handles rendaku | Same as before | Same as before | Yes (derives surface form) |
| Grammar metadata needed | No | No | Category-specific prompts |

---

## What each approach is good at (by approach)

- **Literal string search (no LLM)**: fixed expressions where the surface forms are
  known at publish time — し, から, はず, したがって, どころか, etc.

- **Approach C (grammar-outward)**: conjugation grammar — potential, causative,
  passive, て-form derivatives. Answer committed before sentence is written; no
  extraction judgment needed.

- **Two-pass extraction with worksheet-builder prompt**: best LLM option for fixed
  expressions when literal search isn't set up yet. Consistently extracts `し, し, し`
  where other LLM approaches over-include the predicate.

- **Nothing yet**: たり-たりする and other hybrids where (a) the grammar particle has
  phonological variants (たり/だり) and (b) the closing する conjugates. Needs explicit
  metadata listing surface variants and flagging the closing conjugation.

---

## What each approach is good at (by grammar topic)

- **Fixed expressions (し, から, はず, したがって, …)**: no LLM extraction needed at all.
  The answer strings are known at publish time — store them as `surfaceForms` in
  grammar metadata and do a literal string search in the generated sentence. Every
  approach that delegates this decision to the LLM risks over-including the predicate.
  Two-pass with the worksheet-builder prompt is the best LLM option (consistently
  extracts `し, し, し`), but literal search removes the failure mode entirely.

- **Conjugation grammar (potential, causative, passive, て-form derivatives)**:
  **Approach C** (grammar-outward). The answer is committed in Step 3 before the
  sentence is written, so it appears verbatim by construction. The polite/plain
  mismatch (e.g. committing `弾ける` then writing `弾けます`) is a fixable prompt
  issue (instruct: use plain form throughout). One-pass also works here but is
  less reliable; two-pass has ~1/3 validation failures.

- **Grammatical frames (てはいけない, ようにする, を余儀なくされる, …)**: not yet
  tested, but both Approach A (bracket the whole frame) and Approach C (commit the
  frame string in Step 3) should work — frames are long contiguous strings with no
  ambiguous stem boundary.

- **たり-たりする and other hybrids**: no tested approach handles the closing する
  reliably. Requires explicit grammar metadata: list the per-slot surface forms
  (`["たり", "だり"]`) and flag that the closing する conjugates. Two-pass gets it
  right 1/3 of the time; the rest of the time it drops the する slot entirely.
  Literal metadata is the only robust solution.

---

## Approach D — Per-topic generation prompts (2026-03-17)

### Core insight

Every previous approach tried to write a *generic* prompt that works for all grammar
topics, then patched failures with a second extraction call or a 3-category classifier.
The fundamental problem: what constitutes "the grammar" in a sentence differs so much
between topics (conjugation suffix vs. fixed particle vs. multi-slot frame vs. hybrid)
that no single instruction set handles them all.

**Solution**: each grammar topic in `grammar-equivalences.json` carries its own
`generationSteps` field — a per-topic chain of thought that tells Haiku exactly how to
construct the sentence *and* identify the answer substrings, in one call. No extraction
pass. No category classifier. The chain of thought is Approach C (grammar-outward) but
with the reasoning steps customized per topic rather than per category.

### How it fits with existing prompts

The system prompt is **unchanged** — it still injects `summary`, `subUses`, `cautions`,
and `recentNotes` from the equivalence group. These describe *what the grammar is* and
guide Haiku toward natural, varied sentences.

The user-turn question request currently has two generic steps:

```
Step 1 — English stem: [scenario description]
Step 2 — Full sentence: Write one complete, natural Japanese sentence using the target grammar.
```

Under Approach D, the user turn becomes:

```
Step 1 — English stem: [same as before — concrete scenario, no Japanese]
{generationSteps}      ← injected from grammar-equivalences.json
Final — JSON output    ← same structure for all topics
```

The `generationSteps` field replaces the old generic "Step 2" with topic-specific
reasoning that produces both `sentence` and `answers[]`. The JSON output schema is
uniform across all topics:

```json
{"stem":"<Step 1>","sentence":"<full sentence>","choices":[["<answer1>","<answer2>",...]],"correct":0,"sub_use":"<phrase>"}
```

- `choices` is a single entry (index 0) containing the answer substring(s) — same
  shape as today's tier-2 output after extraction refinement.
- `sentence` is the full Japanese sentence. The app blanks each answer substring
  (left-to-right, first unused occurrence) to produce the gapped display.

### `generationSteps` field format

The field is an **array of strings**, each element one numbered step. The app
injects them into the user turn as `Step 2`, `Step 3`, etc. (Step 1 is always the
English stem, supplied by the app). This gives structure without being so rigid
that it can't accommodate different step counts per topic.

Example value in `grammar-equivalences.json`:
```json
"generationSteps": [
  "Choose a verb: Pick a verb that fits the scenario.",
  "Conjugate: Write the causative form (e.g. 走る→走らせた). Record ONLY the inflectional suffix (e.g. らせた, not 走らせた) — this is the answer.",
  "Build sentence: Write a natural Japanese sentence containing the full conjugated verb. Every answer substring must appear verbatim in the sentence."
]
```

The app renders this as:
```
Step 2 — Choose a verb: Pick a verb that fits the scenario.
Step 3 — Conjugate: Write the causative form (e.g. 走る→走らせた). ...
Step 4 — Build sentence: Write a natural Japanese sentence ...
```

The "avoid 食べる, 飲む, 泳ぐ" instruction is **not** in `generationSteps` — it
already lives in the system prompt's `quirkyNote` (line 418 of GrammarQuizSession.swift)
and applies to all topics uniformly.

### Example `generationSteps` for each grammar type

**Conjugation (e.g. causative)**:
```json
[
  "Choose a verb: Pick a verb that fits the scenario.",
  "Conjugate: Write the causative form of that verb (e.g. 走る→走らせた). Record ONLY the inflectional suffix (e.g. らせた, not 走らせた) — this is the answer.",
  "Build sentence: Write a natural Japanese sentence containing the full conjugated verb. Use plain form throughout (not です/ます). The answer substring must appear verbatim."
]
```

**Fixed expression (e.g. し〜し)**:
```json
[
  "Choose predicates: Pick 2–3 predicates that fit the scenario.",
  "Answers: The answer for each slot is literally \"し\". Record [\"し\", \"し\"] (or 3 entries).",
  "Build sentence: Write a natural Japanese sentence connecting the predicates with し."
]
```

**Grammatical frame (e.g. てはいけない)**:
```json
[
  "Choose a verb: Pick a verb that fits the scenario.",
  "Frame string: The answer is \"てはいけない\" (or conjugated form: \"てはいけません\", etc.). Record the exact frame substring as it will appear in the sentence.",
  "Build sentence: Write a natural Japanese sentence where the verb attaches to the frame. The frame substring must appear verbatim."
]
```

**Hybrid (e.g. たり〜たりする)**:
```json
[
  "Choose verbs: Pick 2–3 verbs that fit the scenario.",
  "Conjugate each: For each verb, write the たり/だり form (e.g. 読む→読んだり). Record each たり/だり substring.",
  "Closing する: Decide the conjugation of the closing する (した, します, している, etc.). Record it as an additional answer substring.",
  "Build sentence: Assemble the full sentence. Every answer substring must appear verbatim."
]
```

### Validation (unchanged)

Every answer in `choices[0]` must appear as a verbatim substring of `sentence`. The app
finds and blanks each one left-to-right. This is the same validation as today — only the
generation path changes.

### `choices` schema change (tier 2 production)

Today the generation call returns `"choices": [[""]]` (placeholder) and a second
`refineAnswerExtraction` call fills in the real answer substrings. Under Approach D,
the generation call returns the answers directly: `"choices": [["し", "し"]]`.

This is **not** a breaking change to the app's internal contract:
- The `GrammarMultipleChoiceQuestion` struct already handles `choices[0]` as an
  array of answer strings — that's how it looks *after* refinement today.
- Tier-1 questions (4 choices) are unaffected — they don't use `generationSteps`.
- There is no persistent cache of tier-2 generation results; each question is
  generated fresh. No migration needed.

The only change is that `choices[0]` arrives populated from the generation call
instead of being empty and then filled by a second call.

### What `refineAnswerExtraction` becomes

Eliminated entirely. The per-topic chain of thought produces correct answer substrings
by construction.

### `disambiguateGaps`

Still needed. When the same answer substring (e.g. "し") appears in the sentence both
as a grammar slot and as part of unrelated text, the app needs to know *which*
occurrences to blank. `disambiguateGaps` handles this by asking Haiku to confirm
positional indices. This is a display concern, not an extraction concern, and it's
orthogonal to Approach D — it runs after generation regardless of how answers were
produced.

### No fallback needed

`generationSteps` is a **required** field — every entry in `grammar-equivalences.json`
must have it. No one is using grammar quizzes yet, so there are no backward-compatibility
concerns. The old generic Step 2 and `refineAnswerExtraction` can be deleted outright
once the new steps are written and tested.

### What changes in code

**`grammar-equivalences.json`** — add `generationSteps` string to each of the 12 entries.

**`GrammarQuizItem`** (model) — add `generationSteps: String?` property, populated from
the equivalence group data.

**`GrammarQuizSession.questionRequest(for:)`** — for tier-2 production, replace the
generic Step 2 with `item.generationSteps`. The Step 1 (English stem) and final JSON
block remain the same template.

**`GrammarQuizSession.runGenerationLoop(for:...)`** — remove the
`refineAnswerExtraction` call for tier-2 production. The generation call now returns
populated `choices[0]` directly.

**`refineAnswerExtraction`** — delete (or keep as dead-code safety net during testing).

**TestHarness** — update `--dump-prompts` to show the per-topic generation steps;
update `--live` tier-2 tests to verify 1-shot extraction.

### Work breakdown

- [ ] Draft `generationSteps` (array of strings) for all 12 grammar topics in `grammar-equivalences.json`
- [ ] Add `generationSteps: [String]` field (required) to `GrammarQuizItem` model and wire it from DB/JSON
- [ ] Update `questionRequest(for:)` tier-2 production branch: inject numbered steps, tell the model to populate `choices`
- [ ] Update `runGenerationLoop`: remove `refineAnswerExtraction` call; keep `disambiguateGaps` unconditionally
- [ ] Run TestHarness `--live --tier 2` for all 12 topics, 3 runs each, record results in a new table below
- [ ] Reliability threshold: **all answer substrings must appear verbatim in the sentence** (validation pass). Target: ≥ 11/12 topics pass all 3 runs (≥ 33/36 total). Any topic that fails 2+ of 3 runs gets its `generationSteps` revised and retested before proceeding.
- [ ] Delete `refineAnswerExtraction` (no fallback needed — field is required)
- [ ] Update `--dump-prompts` to show per-topic generation steps
