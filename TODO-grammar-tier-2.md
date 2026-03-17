# Tier 2 production: alternative extraction architectures

Three candidate approaches to the blank-extraction problem for tier 2 production
fill-in-the-blank questions. Each is a self-contained design; run parallel experiments
to compare.

Background: see `TODO-grammar.md` §"Tier 2 answer extraction: two-pass architecture
and grammar classification (2026-03-17)" for the full problem statement and test results
that motivate these alternatives.

---

## Approach A — Two-field generation

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

## Approach C — Grammar-outward generation

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
