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

## Recommendation for parallel experiments

Each approach maps cleanly to an independent implementation experiment:

- **Approach A**: modify `generateTier2Production` to emit `gapped` alongside
  `sentence`; add bracket-stripping validation; fall back to current extraction
  on validation failure.
- **Approach B**: change the JSON schema; update `QuizSession` to accept a token
  array; update `QuizView` to render token lists.
- **Approach C**: rewrite the generation chain of thought; output `answers` array;
  update the app to blank by substring search.

Compare on: extraction accuracy across grammar categories in TestHarness
`--live` mode, token cost per question, and failure/fallback rate.
