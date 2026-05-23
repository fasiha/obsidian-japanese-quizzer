# Greedy multi-morpheme compound detector

## Problem

MeCab tokenizes conservatively. JMdict contains many entries that span multiple
MeCab morphemes — compound verbs, noun-verb phrases with embedded particles,
adverbial compounds, etc. The annotate-file skill needs to find these longer
entries even though MeCab splits them.

## What was built

### `annotate-harness.mjs`

Replaces the old three-script pipeline (`filter-for-annotation.mjs`,
`mecab-with-hints.mjs`, `recombine-annotations.mjs`) with a single two-command
harness:

- `start <file.md>` — filters the Markdown, runs MeCab+UniDic on all lines at
  once, and writes a SQLite work database at `/tmp/<basename>-<timestamp>.db`.
  The `sentences` table has one row per unique Japanese line with columns:
  `id, text, furigana, morphemes, annotations`. The `morphemes` column is a
  pre-structured JSON blob (bilingual POS/inflection, `isContentWord` flag,
  `lemmaReadingHiragana`, `pronunciationHiragana`, `compoundHint`).

- `done <work.db>` — reads `annotations` from the database and writes
  `<basename>.annotated.<timestamp>.md` next to the source file. Can be called
  with partial annotations.

The LLM lives entirely in the SQLite database, updating `annotations` via
`sqlite3` UPDATE commands. It never reads or writes Markdown directly.

### Multi-anchor lookup in `lookup.mjs`

`X*Y` and `X*Y*Z` syntax: `node lookup.mjs 'あし*を*とめ'` constructs an FTS5
phrase query against the kanas and kanjis tables. Sequential order is enforced.

### Compound hints in morpheme objects

Each content-word morpheme carries a `compoundHint: { reading: N, kanji: M }`
field — the count of JMdict entries that start with this morpheme's reading/kanji
and are longer than it. Non-zero kanji count is the stronger signal.

## Test results

### Haiku (old harness, per-line MeCab calls)

✓ いきおいよく, ✓ 足を止める — found  
✗ おなかがへる, ✗ 思うがままに — missed (never tried multi-anchor lookups)

### Sonnet (new harness, SQLite work file)

✓ いきおいよく (`いきおい*よく`)  
✓ 足を止める (`あし*を*とめ`)  
✓ 思うがまま (`おもう*が*まま`) — previously missed by Haiku  
✗ おなかがへる — still missed; Sonnet looked up おなか and 減る individually

### Root cause of おなかがへる miss

The `compoundHint` on おなか has only `reading:9` (no kanji count — the lemma
`御腹` doesn't match `おなか*` prefix well in the raws table). The weaker signal
means Sonnet doesn't prioritize a multi-anchor search. The phrase is also split
across a particle (が) before the verb, which requires a three-morpheme span.

## Next steps / open questions

- **Harness-level exhaustive compound search**: in `start`, for every pair (or
  triple) of content morphemes close together in the sentence, run the FTS search
  and — if hits are found — store the results directly in the morpheme object or
  a separate `compoundCandidates` field. The LLM then doesn't need to decide
  which pairs to try; it just sees confirmed dictionary hits and picks the best
  fit. This is the highest-leverage next step.

- **Skip particles in multi-anchor instructions**: Sonnet tried `あし*を*とめ`
  (correct) but also tried spurious particle-inclusive searches. The instruction
  should clarify that particles (を、が、に、etc.) are included in the anchor
  string *only when the dictionary entry itself contains them* — i.e., try the
  particle when the preceding content word's `compoundHint` is non-zero and the
  following content word is a verb or adjective. This is tricky to specify
  without the harness doing the search itself.

- **Improve multi-morpheme phrase framing in the skill**: the current instruction
  says "aggressively search." Better framing: everyday Japanese has dozens of
  `X-が/を-verb` idioms (お腹が減る, 気が付く, 目を覚ます) and `adverb+adverb`
  compounds (勢いよく, 素早く) that children's texts use constantly. When a noun
  or adverb has a non-zero `compoundHint` and is followed by a verb, the
  idiomatic phrase is likely in JMdict and worth searching.

- **Threshold tuning**: `compoundHint.kanji ≥ 1` is the current trigger. The
  おなかがへる miss suggests reading-only hints (no kanji count) also deserve
  multi-anchor attempts. Consider lowering the bar to `reading ≥ 3` or similar.

## Corpus test cases

### 1. いきおいよく (勢いよく) — adverb compound ✓ found by both

```
それから、ぼくの せなかを、いきおいよく ぽーんと だたいた。
```
MeCab splits: `いきおい` + `よく`; compoundHint: `reading:5 kanji:5`

### 2. おなかがへる (お腹が減る) — noun+particle+verb phrase ✗ persistent miss

```
あきには おなかが へって なりませんので、こう いって たのみました。
```
MeCab splits: `おなか` + `が` + `へる`; compoundHint on おなか: `reading:9` (no kanji)  
Classic children's phrase; high prior for being in JMdict.

### 3. 足を止める — verb phrase with を ✓ found by both

```
足を止めても過去には戻れない
```
MeCab splits: `足` + `を` + `止め`; compoundHint on 足: `reading:209 kanji:199`

### 4. 思うがまま — verb phrase with embedded particles ✓ found by Sonnet, ✗ missed by Haiku

```
たまに息しづらくて思うがままに
```
MeCab splits: `思う` + `が` + `まま` + `に`; Sonnet tried `おもう*が*まま` → hit.
