---
description: Annotate all Japanese lines in a Markdown file with vocabulary from JMDict for N4-level learners
---

Annotate every Japanese line in the file at path `$ARGUMENTS` with vocabulary bullet points.

## Step 1 — Filter the file

```bash
node filter-for-annotation.mjs "$ARGUMENTS"
```

This outputs a JSON array of unique Japanese lines that need annotation:

```json
[{ "id": 5, "text": "日本語の文章です。" }, ...]
```

`id` is the line index in the original file. `text` has ruby tags already stripped.
If the original line contained ruby annotations, a `furigana` field is also present with readings inlined (e.g. `"furigana": "夢を運命[さだめ]と呼ぶ"` for `夢を<ruby>運命<rt>さだめ</rt></ruby>と呼ぶ`). Use `furigana` to resolve ateji or unusual readings when looking up JMDict — the bracketed reading shows exactly which kanji the author assigned an unexpected reading to.
Duplicates, YAML frontmatter, blank lines, section headers in brackets, and purely English/romanized lines are already excluded.

## Step 2 — Annotate each item

For each item in the JSON array, annotate the `text` field using the full `annotate-vocab` procedure:

### 2a — Run MeCab with compound hints

```bash
node mecab-with-hints.mjs "{text}"
```

Collect all **content word lemmas**: nouns, verbs (dictionary form), adjectives (dictionary form), adverbs, adjectival nouns, etc. Skip morphemes like particles, auxiliary verbs, punctuation, proper nouns, pure grammar morphemes, and 無い.

Include counter nouns (MeCab tags 名詞-普通名詞-助数詞可能 and 名詞-助数詞) — words like 度 (たび), 本 (ほん), 枚 (まい) carry real lexical meaning. For any word with a borderline POS classification (e.g., 連体詞, unusual noun subtypes), include it. When uncertain whether to include a word (e.g., it has an unusual MeCab classification), include it. If it has semantic content and isn't purely grammatical, include it.

Content-word lines include a `[compound_extensions: reading:N kanji:M]` hint — the count of JMdict entries that begin with this morpheme's reading and kanji, respectively, and are longer than it. (Omitted kanji count means 0.) Non-zero counts can be used to guess whether the dictionary contains an entry that includes this morpeheme and the ones that follow (e.g., idiomatic usage).

### 2b — Look up each lemma in JMDict

```bash
node lookup.mjs {lemma}
```

Classify as found, not found (try conjugated/inflected base form or prefix search `node lookup.mjs '{stem}*'`), elongated form (cite base), or mimetic/onomatopoeia (try hiragana/katakana/long-vowel/gemination variants).

For morphemes with a non-zero compound hint, consider constructing and running multi-anchor searches combining this morpheme's **kana reading** with the kana reading of relevant subsequent content tokens. Always use kana readings (field 3 in the MeCab output), never kanji surfaces — JMdict entries are not always representationally exhaustive, so a kanji+kana mix may miss entries stored differently. Always single-quote the argument to prevent the shell from glob-expanding `*`:

```bash
node lookup.mjs 'いき*づらい'
node lookup.mjs 'いきおい*よく'
# three anchors span a particle between two content words:
node lookup.mjs 'おなか*が*へ'
node lookup.mjs 'あし*を*とめ'
```

This finds dictionary entries spanning multiple morphemes (phrases, idioms, compound words) that are often much more informative than the individual parts. The dictionary will often include particles between content words, so a two-anchor search can surface a three-token entry. If a longer compound entry fits the context, be sure to use it. Include its individual parts if they are useful to an N5-level learner.

## Step 3 — Write annotation JSON and recombine

Write a JSON file to `/tmp/annotations.json` in this format:

```json
[
  { "id": 5, "entries": ["- たび 度", "- はな 花"] },
  { "id": 8, "entries": ["- Not in JMDict: ホゲ — some contextual meaning"] }
]
```

Each `id` must match the `id` from Step 1. Each string in `entries` follows one of these formats:

For words **found in JMDict** with kanji:
```
- {kana reading} {kanji form}
```
For kana-only words:
```
- {kana}
```
For words **not in JMDict**:
```
- Not in JMDict: {word as it appears in text} — {concise meaning in context}
```
For proper nouns like names, places:
```
- Proper noun: {word as it appears in text} — {MeCab-proposed reading} — {in English, your guess about whether this is a famous place (example: "Uji, suburb of Kyoto"), a famous person ("Fukuzawa Yukichi, famous author"), or just some person or place's name}
```

Do **not** include English meanings for JMDict words.
Do **not** annotate grammar (て-form, たら, ので, etc.) — vocabulary only.
If a line has no content words at all, include `{ "id": N, "entries": [] }` — the recombine script will skip the vocab block for empty entries.

Then run:

```bash
node recombine-annotations.mjs "$ARGUMENTS" /tmp/annotations.json
```

## Step 4 — Report

Print the one-line summary output by `recombine-annotations.mjs`.
