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

## Approach D — Per-topic prompts (2026-03-17)

### Core insight

Every previous approach tried to write a *generic* prompt that works for all grammar
topics, then patched failures with a second extraction call or a 3-category classifier.
The fundamental problem: what constitutes "the grammar" in a sentence differs so much
between topics (conjugation suffix vs. fixed particle vs. multi-slot frame vs. hybrid)
that no single instruction set handles them all.

**Solution**: each grammar topic in `grammar-equivalences.json` can carry per-topic
prompt fields that customize how questions are generated and graded for that topic.
Different tiers need different fields — tier 1 needs the least customization, while
tiers 2 and 3 need progressively more. We roll out tier by tier.

### Tier analysis: how well English constrains the target grammar

Surveyed the full corpus (~1400 topics across Bunpro, DBJG, and Genki). Topics fall
into three groups based on how well an English stem determines which Japanese grammar
the student should use:

**Group A — English uniquely determines the grammar (~200-300 topics).**
The English meaning *is* the grammar point. A neutral scenario works for all tiers.
- Causative, passive, potential, causative-passive
- ば〜ほど ("the more...the more"), ても ("even if"), てしまう ("accidentally")
- Most N2-N1 compound expressions: わけにはいかない, ずにはいられない, を余儀なくされる

**Group B — English is ambiguous but can be pragmatically framed (~200-300 topics).**
Multiple Japanese forms could express the same English. The stem can be crafted to
make one form more natural than others, but alternatives remain valid.
- し〜し vs て-form listing vs たり (reasons vs sequence vs sampling)
- ようにする vs ことにする ("try to" vs "decide to")
- から vs ので (casual vs objective "because")
- おかげで vs せいで (positive vs negative attribution)
- Discourse connectors: ところが vs それなのに vs そこで (different logical relations)

**Group C — English cannot distinguish the grammar (~100-200 topics).**
Structural/particle-level Japanese distinctions with no English equivalent.
- は vs が (topic vs subject), particle も
- の (nominalizer), って vs と (register)
- Sentence-final particles (よ, ね, さ, かな, かしら)
- Honorific/humble pairs (お〜になる vs お〜する)

For Group C, the stem must describe the *communicative function*: "introduce new
information about an established topic" (→ は), "confirm shared understanding with
the listener" (→ ね). This is good pedagogy — it tests understanding of function,
not just form.

### Per-tier strategy

**Tier 1 (multiple choice)** works for nearly everything. The choices disambiguate —
even は vs が works because the student picks from options. The existing generic
generation prompt is sufficient. No per-topic prompt fields needed for tier 1 beyond
the existing `summary`/`subUses`/`cautions`.

**Tier 2 (fill-in-the-blank / cloze)** needs `generationSteps` — a per-topic chain
of thought that tells Haiku how to construct the sentence and identify the answer
substrings in one call (Approach C grammar-outward, customized per topic). See the
"Tier 2 future work" section below.

**Tier 3 (free production)** for Group A topics works with a neutral stem. For Group B
topics, the right approach is to accept valid alternatives and coach the student toward
the target form: "Nice sentence — now rewrite it using し to emphasize that each reason
independently supports your conclusion." This needs a per-topic `gradingGuidance` field
that tells the grader what to accept, what to redirect, and how to coach. For Group C
topics, the stem itself needs per-topic `stemGuidance` describing the communicative
function to target. See the "Tier 3 future work" section below.

### Immediate work: ship tier 1

Tier 1 already works with the generic prompt + `summary`/`subUses`/`cautions`. No new
per-topic fields are needed. The immediate task is getting grammar quizzes live with
tier 1 for all topics in `grammar-equivalences.json`.

### Work breakdown (tier 1 — now)

- [ ] Verify tier 1 generation works for all 12 current grammar topics via TestHarness
- [ ] Ship grammar quizzes with tier 1 production + recognition
- [ ] As new grammar topics are added via `cluster-grammar-topics`, tier 1 works out of
      the box with no additional per-topic fields

---

## Tier 2 future work: `generationSteps`

Deferred until tier 1 is live and we have real usage data. This section preserves the
design work from the earlier Approach D discussion.

### `generationSteps` field format

An **array of strings** in `grammar-equivalences.json`, each element one numbered step.
The app injects them into the tier-2 user turn as `Step 2`, `Step 3`, etc. (Step 1 is
always the English stem, supplied by the app).

Example value:
```json
"generationSteps": [
  "Choose a verb: Pick a verb that fits the scenario.",
  "Conjugate: Write the causative form (e.g. 走る→走らせた). Record ONLY the inflectional suffix (e.g. らせた, not 走らせた) — this is the answer.",
  "Build sentence: Write a natural Japanese sentence containing the full conjugated verb. Every answer substring must appear verbatim in the sentence."
]
```

The "avoid 食べる, 飲む, 泳ぐ" instruction is **not** in `generationSteps` — it
already lives in the system prompt's `quirkyNote` and applies to all topics uniformly.

### Core principle: commit the answer before writing the sentence

The grammar-outward approach (Approach C) is the underlying principle. The chain of
thought must:

1. Decide the grammar form (and any variable elements) explicitly, **before**
   the full sentence is written.
2. Record the answer substring(s) at the point of decision.
3. Then build the sentence around those committed substrings.

This means Haiku never has to "extract" an answer from a finished sentence — it
declared the answer while writing and must use it verbatim.

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

### Validation

Every answer in `choices[0]` must appear as a verbatim substring of `sentence`. The app
finds and blanks each one left-to-right. Same validation as today — only the generation
path changes.

### `choices` schema change (tier 2 production)

Today the generation call returns `"choices": [[""]]` (placeholder) and a second
`refineAnswerExtraction` call fills in the real answer substrings. With `generationSteps`,
the generation call returns the answers directly: `"choices": [["し", "し"]]`.

Not a breaking change: `GrammarMultipleChoiceQuestion` already handles populated
`choices[0]` (that's how it looks after refinement today), tier-1 is unaffected, and
there is no persistent cache.

### `refineAnswerExtraction` and `disambiguateGaps`

`refineAnswerExtraction` is eliminated — the per-topic chain of thought produces correct
answer substrings by construction. No fallback needed (no one is using grammar quizzes).

`disambiguateGaps` is still needed — when the same answer substring (e.g. "し") appears
in the sentence both as a grammar slot and as unrelated text, the app needs positional
disambiguation. This is orthogonal to the generation approach.

### Tier 2 work breakdown (future)

- [ ] Draft `generationSteps` for all grammar topics in `grammar-equivalences.json`
- [ ] Add `generationSteps: [String]` field to `GrammarQuizItem` model, wire from DB/JSON
- [ ] Update `questionRequest(for:)` tier-2 production: inject numbered steps, populate `choices`
- [ ] Update `runGenerationLoop`: remove `refineAnswerExtraction`; keep `disambiguateGaps`
- [ ] Run TestHarness `--live --tier 2` for all topics, 3 runs each
- [ ] Reliability threshold: ≥ 33/36 runs pass validation. Revise any topic failing 2+ of 3.
- [ ] Delete `refineAnswerExtraction`
- [ ] Update `--dump-prompts` to show per-topic generation steps

---

## Tier 3 future work: `gradingGuidance` and `stemGuidance`

Tier 3 could ship before tier 2 — it needs less machinery. For Group A topics (English
uniquely determines the grammar), tier 3 works today with the existing generic grading
prompt and no new per-topic fields. The fields below are refinements for Group B/C topics
and can be added incrementally.

### `gradingGuidance` (for Group B topics)

Tells the tier-3 grader/coach what to accept, what to redirect, and how to coach.
For Group B topics where the student might produce a valid alternative form:

Example for し〜し:
```json
"gradingGuidance": "Accept し, て-form listing, or たり as structurally correct. If the student used て-form or たり, score 0.5 and ask them to rewrite using し, explaining that し emphasizes independent reasons while て implies sequence and たり implies non-exhaustive sampling."
```

Example for おかげで:
```json
"gradingGuidance": "Accept おかげで or せいで as grammatically correct. If the student used せいで for a positive outcome, score 0.5 and explain that おかげで carries gratitude/positive attribution while せいで implies blame."
```

The coach accepts the student's valid work, scores partially, and uses the rewrite
request as a teaching moment for the *nuance* between similar forms — which is the
actual learning goal for Group B topics.

### `stemGuidance` (for Group C topics)

Tells the LLM how to write the English stem so it targets the grammar's communicative
function. For Group C topics where English cannot distinguish the grammar form:

Example for は (topic marker):
```json
"stemGuidance": "Frame the scenario so the speaker is commenting on an already-established topic — e.g. 'Your friend asks about the weather. Tell them about today's weather.' The English should make clear what the topic of conversation is."
```

Example for ね (confirmation particle):
```json
"stemGuidance": "Frame the scenario so the speaker is confirming shared understanding or seeking agreement with the listener — e.g. 'You and your friend are both looking at a beautiful sunset. Comment on it expecting agreement.'"
```

### Tier 3 work breakdown (future)

- [ ] Draft `gradingGuidance` for Group B topics
- [ ] Draft `stemGuidance` for Group C topics
- [ ] Add fields to `GrammarQuizItem` model
- [ ] Wire `gradingGuidance` into tier-3 coaching system prompt
- [ ] Wire `stemGuidance` into tier-3 stem generation prompt
- [ ] Test with representative topics from each group

---

## Drafting `generationSteps` (notes for `cluster-grammar-topics` skill update)

These notes are for when we implement tier 2. Preserved here for future reference.

This guidance must work for any grammar topic that will eventually enter the
system, not just the current 12. The full corpus spans basic N5 particles through
complex N1 frames: single particles (な prohibitive, しか), auxiliary verbs
(なおす, たがる), comparison expressions (にもまして, のように), compound
postpositions (に照らして, にかかわらず), aspectual frames (ところだった, ように
なる), double negatives (ないでもない), idiomatic compounds (をいいことに,
どころではない), adverbs that carry no blank at all (どうせ), and more. No
fixed category list covers this range — the skill should reason from first
principles for each topic.

### Where it fits in the skill

Add a new **Step 6: Add generationSteps** immediately after Step 5 (Enrich
descriptions). It runs only when entries are missing the `generationSteps` field.
Gate it with a check:

```bash
node -e "const g=require('./grammar/grammar-equivalences.json'); \
  g.filter(e=>!e.generationSteps).forEach(e=>console.log(e.topics[0]));"
```

If all entries already have the field, report "all generationSteps present" and
skip. Otherwise generate and write steps for the missing entries.

### Designing steps for a new topic: three questions

For each topic, answer these questions in order:

**Q1: What is the answer — the thing the student must produce?**

The answer is whatever gets blanked in the cloze question. It is a verbatim
substring of the Japanese sentence. Be precise:

- Is it the grammar particle/expression itself (し, ながら, にもまして)?
- Is it an inflected form derived from a verb or adjective the sentence must
  contain (potential form, adverb form, causative suffix)?
- Is it a frame that attaches to a verb (てならない, ことになっている,
  を余儀なくさせる)?
- Are there multiple answer slots, and do they vary phonologically (たり/だり)
  or conjugate (closing する)?

**Q2: What is the minimum scope that tests the grammar point?**

The scope determines what exactly is recorded as the answer string. Lean toward
the smallest string that still tests the grammar form, not surrounding vocabulary.
Consider:

- Fixed particle that never changes form (し, ながら, に照らして): the particle/
  expression itself, exactly as it always appears.
- Inflectional suffix that attaches to different stems (causative, passive,
  て-form): suffix only or full-form depends on whether the stem matters
  pedagogically (see below).
- Multi-word frame where the entire phrase is the grammar point
  (ことになっている, どころではない): the whole frame, because partial blanking
  makes the question trivially easy.
- Conjugating element within a frame (closing する in たり-たりする, tense of
  ことになっている): decide before writing and record the conjugated form.

**Full form vs. suffix-only for inflectional grammar:**
There is a trade-off. Suffix-only (e.g. `らせた` for causative) is more robust:
if Haiku writes a polite sentence (`走らせます`) but commits the plain form, the
suffix still appears verbatim. Full-form (e.g. `書ける` for potential) is better
when recognising the complete word is itself part of the learning goal, or when
the suffix alone would be too short to be unambiguous in the sentence. Use
`summary` and `cautions` for the topic to guide this choice — they already
describe what the learner needs to master.

**Q3: How many steps does committing the answer require?**

Some topics need one commitment step (the frame is fixed, just pick a verb and
write it down). Some need two or more (pick verbs, conjugate each slot, decide
the closing form). Scale the step count to the actual complexity of the topic:

- Simple fixed expression or particle: 1 commitment step + 1 sentence step.
- Single conjugation or frame choice: 1 choice step + 1 commitment step +
  1 sentence step.
- Multi-slot or hybrid: 1 choice step + 1 commitment step per variable element
  + 1 sentence step.

Avoid padding: don't add steps that don't produce a decision or a recorded answer.

### Step writing conventions

- Each step string is one or two sentences. It will be rendered as a numbered
  line (e.g. "Step 3 — ...") in the user-turn prompt, so keep it self-contained.
- The commitment step must include a concrete example (e.g. `走る→走らせる`),
  taken from the topic's `subUses` or written freshly — never copied verbatim
  from any reference page.
- The final step is always the sentence-building step and must include: "Every
  answer substring must appear verbatim in the sentence."
- Use plain form by default for verb-based topics. If a topic's primary use
  is in polite register, note this explicitly.
- Do **not** include the "avoid 食べる, 飲む, 泳ぐ" instruction — it lives in
  the system prompt's `quirkyNote` and applies universally.
- Do **not** mention `choices`, JSON, or any output format — those come from
  the surrounding prompt template.

### Topics where the answer scope is non-obvious

Some common patterns that need careful thought:

**Standalone adverbs and discourse markers** (どうせ, まず, せっかく, etc.):
These words don't conjugate and don't attach to a verb stem. The answer is the
word itself. The commitment step is trivial — the word is always the same —
so the step should say: "Answer: The answer is '[word]'. Record it." The
interesting work is in building a sentence where the word's nuance is used
correctly.

**Compound postpositions** (に照らして, にかかわらず, にもまして, を余儀なく
させる, etc.): The answer is the full compound expression. These don't vary
phonologically, so there is no commitment ambiguity. The commitment step should
record the exact surface form that will appear in the sentence, including any
particle at the front (に) and any closing element (して, ず). If the expression
has a conjugating tail (に照らすと vs に照らして), the step must commit to which
variant before writing.

**Discontinuous frames** (ば〜ほど, かは〜によって違う, さえ〜ば, たとえ〜ても):
The grammar wraps around intervening content. The `generationSteps` must produce
both halves as separate answer entries. E.g. for ば〜ほど: commit to ["ば", "ほど"]
as two answers, then build the sentence with both appearing verbatim. The app's
left-to-right blanking handles the positional separation.

**Two-variant contrasts** (たらいい vs といい, でできる vs からできる): The topic
teaches two related forms. The step should explicitly pick one variant per
sentence — not try to use both in the same sentence. Record the chosen variant as
the answer.

**Double negatives and softened expressions** (ないでもない, なくもない): The
answer is the fixed expression. The student must produce it whole — partial
blanking (e.g. blanking only ない) would test something different. One commitment
step, record the full expression.

**Auxiliary verbs** (なおす, だす, 続ける, etc.): These attach to the conjunctive
form (連用形) or て-form depending on the auxiliary. The answer scope question: test
the auxiliary alone, or the full compound? Prefer the auxiliary alone — it's the
grammar point. Commitment step: choose a main verb, write the conjunctive form,
then append the auxiliary. Record only the auxiliary (e.g. なおした) as the answer.
But check the topic's `cautions` — if the main verb's conjugation pattern is the
pedagogical point, adjust scope accordingly.

### Writing back

Use the same `--write` mechanism as Step 5:

```bash
node .claude/scripts/enrich-grammar-descriptions.mjs --write < /tmp/descriptions.json
```

The `--write` script merges fields, so existing `summary`/`subUses`/`cautions`
are preserved.

### Self-check before writing

After drafting all `generationSteps` arrays, verify:

1. Every array's final step says "Every answer substring must appear verbatim in
   the sentence."
2. No step mentions `choices`, JSON, or output format.
3. Each commitment step includes a concrete example (X→Y form).
4. Multi-slot or hybrid topics have a separate commitment step for each variable
   element — no element is silently merged or dropped.
5. The answer scope is consistent with what the topic's `cautions` say the
   learner must master.
