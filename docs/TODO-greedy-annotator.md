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
  `id, text, furigana, morphemes, hits, annotations`.

  - `morphemes`: MeCab output as JSON (bilingual POS/inflection, `isContentWord`
    flag, `lemmaReadingHiragana`, `pronunciationHiragana`). Available for
    reference but the LLM does not need to iterate it directly.
  - `hits`: pre-computed flat array of JMdict entries found in the sentence,
    sorted start-ascending then end-descending (longest span first at each
    position). Each entry: `{ start, end, wordId, forms, meanings }`.

- `done <work.db>` — reads `annotations` from the database and writes
  `<basename>.annotated.<timestamp>.md` next to the source file. Can be called
  with partial annotations.

The LLM lives entirely in the SQLite database, updating `annotations` via
`sqlite3` UPDATE commands. It never reads or writes Markdown directly.

### Exhaustive hit pre-computation in `start`

The search strategy is derived from `enumerateDictionaryHits` in
[curtiz-japanese-nlp/annotate.ts](https://github.com/fasiha/curtiz-japanese-nlp/blob/master/annotate.ts).
The Curtiz function iterates every (startIdx, endIdx) span up to 5 morphemes,
and for each span generates all combinations of per-morpheme reading and kanji
alternatives using a cartesian-product (`forkingPaths`) approach, then runs
prefix searches (`readingBeginning`, `kanjiBeginning`) against jmdict-simplified.
Our harness ports this logic to raw SQL against `jmdict.sqlite`.

For every morpheme position, the harness runs:

1. **Single-morpheme exact lookup** (content words only) — `raws` table exact
   match on `literal`, `lemma`, `pronunciationHiragana`, `lemmaReadingHiragana`.
   Equivalent to curtiz's fallback character-by-character search, but using
   exact match since the lemma from UniDic is already the dictionary form.

2. **Multi-morpheme prefix search** (spans of 2–5 morphemes) — FTS5 queries
   against `kanas` and `kanjis` tables using three strategies, all implemented
   as `^"c h a r a c t e r - t o k e n i z e d"` FTS5 phrase queries:

   - **Full-span reading**: cartesian product of `[pronunciationHiragana,
     lemmaReadingHiragana]` per morpheme (equivalent to curtiz's `searchReading`
     via `forkingPaths`). Particles use their literal orthographic form (は stays
     は, not わ) to avoid spurious prefix matches from phonetic renderings.
   - **Full-span kanji**: cartesian product of `[literal, lemma]` per morpheme,
     filtered to kanji-containing strings (equivalent to curtiz's `searchKanji`).
   - **Particle-stripped reading**: same as full-span reading but with particle
     morphemes removed from the span before taking the cartesian product. This
     is an addition beyond curtiz — it catches entries like おなかがへる from
     the span [おなか, が, へる] because おなかへる is a prefix of おなかがへる.
     Curtiz relies on the full concatenated span matching (which also works when
     the particle is included), but our FTS5 prefix approach needs the stripped
     variant to handle cases where the particle is absent in some dictionary
     headwords.

Results are deduplicated per (start, wordId) — same word at two different
positions is kept for both — and sorted start-ascending, end-descending. The
LLM selects coverage without running any searches itself.

### Multi-anchor lookup in `lookup.mjs`

`X*Y` and `X*Y*Z` syntax still available as a fallback for edge cases
(MeCab misparse, unusual readings, mimetics). Not used in normal annotation flow.

### Character-by-character fallback (curtiz only — not ported)

[Curtiz](https://github.com/fasiha/curtiz-japanese-nlp/blob/master/annotate.ts)'s `enumerateDictionaryHits` has a fallback that fires when a morpheme
yields zero results from all span searches: it uses `allSubstrings` to search
every possible substring of the morpheme's reading and kanji. This was added
(commit 33874bd, 2022-08-13) for **尻尾切り** — a case where UniDic segments
a compound into a single morpheme that doesn't exist in JMDict whole, requiring
substring search to find the components 尻尾 and 切り separately.

This is the inverse of the multi-morpheme problem (one MeCab token too large
for the dictionary, vs. multiple tokens that are one dictionary entry). It is
**not ported** to `annotate-harness.mjs`. When Sonnet encounters a morpheme
with no `hits`, it can recognize from language knowledge that the token needs
splitting and call `lookup.mjs` for the components — which is exactly the
edge case the skill prompt's `lookup.mjs` fallback instruction covers.

## Test results

### Haiku (old harness, per-line MeCab calls)

✓ いきおいよく, ✓ 足を止める — found  
✗ おなかがへる, ✗ 思うがままに — missed (never tried multi-anchor lookups)

### Sonnet (intermediate harness, compoundHint-guided manual search)

✓ いきおいよく (`いきおい*よく`)  
✓ 足を止める (`あし*を*とめ`)  
✓ 思うがまま (`おもう*が*まま`) — previously missed by Haiku  
✗ おなかがへる — still missed; Sonnet looked up おなか and 減る individually

Root cause: `compoundHint` on おなか had only `reading:9` (no kanji count).
The weaker signal meant Sonnet didn't prioritize a multi-anchor search. The
broader issue was that the morpheme-first prompt caused the LLM to annotate
each morpheme individually before ever considering compound candidates.

### Sonnet (current harness, pre-computed `hits` array)

✓ いきおいよく — found (start:6 end:10)  
✓ 足を止める — found (start:0 end:3)  
✓ 思うがまま — found (start:5 end:8) — was missed in intermediate harness  
✓ おなかがへる — found (start:3 end:6) — persistent miss now resolved  

Zero `lookup.mjs` calls. All four compounds annotated correctly.

## What fixed the persistent misses

The root cause was architectural, not a signal strength problem. Presenting
morphemes as the primary unit of work caused the LLM to iterate through them
sequentially and annotate each individually. Compound candidates were an
afterthought buried in the same blob.

The fix: replace morpheme-first iteration with coverage selection from a
pre-computed `hits` array sorted longest-span-first. The LLM now encounters
お腹が減る (span=3) *before* お腹 (span=1) at the same position, and naturally
picks the longer match when it fits the context.

## Corpus test cases

### 1. いきおいよく (勢いよく) — adverb compound ✓ found by all

```
それから、ぼくの せなかを、いきおいよく ぽーんと だたいた。
```
MeCab splits: `いきおい` + `よく`

### 2. おなかがへる (お腹が減る) — noun+particle+verb phrase ✓ now found

```
あきには おなかが へって なりませんので、こう いって たのみました。
```
MeCab splits: `おなか` + `が` + `へる`; particle-stripped search `おなかへる`
matches prefix of `おなかがへる`.

### 3. 足を止める — verb phrase with を ✓ found by all

```
足を止めても過去には戻れない
```
MeCab splits: `足` + `を` + `止め`

### 4. 思うがまま — verb phrase with embedded particles ✓ now found reliably

```
たまに息しづらくて思うがままに
```
MeCab splits: `思う` + `が` + `まま` + `に`
