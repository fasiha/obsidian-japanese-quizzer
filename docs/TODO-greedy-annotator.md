# Greedy multi-morpheme compound detector

## Problem

MeCab tokenizes conservatively. JMdict contains many entries that span multiple
MeCab morphemes — compound verbs, noun-verb phrases with embedded particles,
adverbial compounds, etc. The annotate-file skill currently relies on Sonnet to
notice these by scanning adjacent morphemes, but it misses cases because the
LLM doesn't know which longer strings are actually in JMdict.

## What was built

### `mecab-with-hints.mjs`

Replaces the bare `mecab` call in the annotate-file skill. Runs MeCab, then for
each content-word token appends a `[compound_extensions: reading:N kanji:M]`
field showing how many JMdict entries start with that morpheme's reading/kanji
and are longer than it. Particles and auxiliaries get no hint (they don't anchor
compounds). Non-zero kanji count is the most useful signal.

### Multi-anchor lookup in `lookup.mjs`

New `X*Y` and `X*Y*Z` syntax: `node lookup.mjs 'あし*とめ'` constructs an FTS5
phrase query `^"あ し" "と め"` against the kanas and kanjis tables. Sequential
order is enforced — `とめ*あし` returns nothing. Lets the LLM search precisely
without wading through dozens of `足*` prefix hits.

### Skill update (`annotate-file.md`)

Step 2a now calls `mecab-with-hints.mjs`. Step 2b instructs the LLM to use
`X*Y` lookups for tokens with non-zero compound hints.

## Test results (Haiku subagent on `test-compounds.md`)

Haiku correctly found **いきおいよく** and **足を止める** using the new
multi-anchor syntax (`いきおい*よく`, `あし*を*とめる` both appeared in the
lookup log). **おなかがへる** and **思うがままに** were missed — Haiku looked up
`おなか` individually and never tried `おなか*へ`.

### Root cause of misses

The compound hints ARE present in the MeCab output, but Haiku isn't consistently
using them to decide which pairs to try. It relies on Japanese intuition to guess
which tokens to combine, rather than mechanically using the hint signal. The
instruction "consider running" is too weak.

### Lookup log from test run
```
いきおい*よく     ✓ (found 勢いよく)
あし*を*とめる    ✓ (found 足を止める)
ぽーん*と         ✗ (と is a particle, not a compound anchor)
へ*なる           ✗ (no such compound)
いき*づらい       ? (息苦しい-adjacent, probably a miss)
あき*へ           ✗ (no such compound)
```

## Next steps / open questions

- **Strengthen the skill instruction**: instead of "consider running X*Y for
  non-zero hints", make it more directive — e.g. "for every content token with
  kanji hint ≥ 1, run `{token}*{next_content_token}` and inspect the results".
  Risk: this could generate many spurious lookups for common kanji like 足 (209
  extensions).

- **Threshold**: only prompt multi-anchor lookup when kanji count ≥ some
  threshold (e.g. ≥ 2)? Needs more data.

- **Haiku vs Sonnet**: Haiku may be too weak to reliably act on hints. The
  full annotate-file skill uses Sonnet; worth testing whether Sonnet does better
  at exploiting the hint signal without additional instruction changes.

- Combine filter-for-annotation.mjs and recombine-annotations.mjs to simplify the harness.

- `mecab-with-hints.mjs` could exhaustively construct every 2-content-morpheme or 3-content-morpeheme FTS search and for non-zero hits, telegraph the longer hit in its output or, stronger than simply "telegraphing", actually put the dictionary hit in its output.

## Corpus test cases

These are real sentences from this corpus where the correct annotation required
noticing a multi-morpheme JMdict entry that MeCab split apart.

### 1. いきおいよく (勢いよく) — adverb compound ✓ found by Haiku

Source: `Bunsho-Dokkai-1nen/Story 3 Shippo.md` line 17

```
それから、ぼくの せなかを、いきおいよく ぽーんと だたいた。
```

MeCab splits: `いきおい` + `よく` (both adverbs)
JMdict has: reading `いきおいよく`, written `勢いよく` / `勢い良く`
Hint output: `いきおい [compound_extensions: reading:5 kanji:5]`

### 2. おなかがへる (お腹が減る) — verb phrase with embedded particle ✗ missed

Source: `Bunsho-Dokkai-1nen/Story 1 Kirikabu 1.md` line 121

```
あきには おなかが へって なりませんので、こう いって たのみました。
```

MeCab splits: `おなか` + `が` (particle) + `へる`
JMdict has: reading `おなかがへる`, written `お腹が減る`
Hint output: `おなか [compound_extensions: reading:9]`
Haiku looked up `おなか` individually; never tried `おなか*へ`.

### 3. 足を止める — verb phrase with を ✓ found by Haiku

Source: `Music/PETZ-Go-ft-OZworld.md` line 197

```
足を止めても過去には戻れない
```

MeCab splits: `足` + `を` (particle) + `止め` (inflected)
JMdict has: reading `あしをとめる`, written `足を止める`
Hint output: `足 [compound_extensions: reading:209 kanji:199]`
Haiku ran `あし*を*とめる` → correct result.

### 4. 思うがままに — verb phrase with embedded particles ✗ missed

Source: `Music/PETZ-Go-ft-OZworld.md` line 138

```
たまに息しづらくて思うがままに
```

MeCab splits: `思う` + `が` + `まま` + `に`
JMdict has: `おもうがまま` (written 思うがまま), also `ままに` as separate entry.
Haiku annotated `おもう` and `まま` individually; never tried a spanning lookup.
