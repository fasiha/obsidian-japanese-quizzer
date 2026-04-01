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

### 2a — Run MeCab

```bash
echo "{text}" | mecab
```

Collect all **content word lemmas**: nouns, verbs (dictionary form), adjectives (dictionary form), adverbs, adjectival nouns, etc. Skip morphemes like particles, auxiliary verbs, punctuation, proper nouns, pure grammar morphemes, and 無い.

Include counter nouns (MeCab tags 名詞-普通名詞-助数詞可能 and 名詞-助数詞) — words like 度 (たび), 本 (ほん), 枚 (まい) carry real lexical meaning. For any word with a borderline POS classification (e.g., 連体詞, unusual noun subtypes), include it. When uncertain whether to include a word (e.g., it has an unusual MeCab classification), include it. If it has semantic content and isn't purely grammatical, include it.

### 2b — Look up each lemma in JMDict

```bash
node lookup.mjs {lemma}
```

Classify as found, not found (try conjugated/inflected base form or prefix search `node lookup.mjs '{stem}*'`), elongated form (cite base), or mimetic/onomatopoeia (try hiragana/katakana/long-vowel/gemination variants).

### 2c — Check for multi-morpheme compounds

After processing individual lemmas, scan for adjacent morphemes that form compound verbs, compound nouns, or particle compounds (e.g. ままに, ために, として). Look up the concatenation:

```bash
node lookup.mjs {combined}
```

If found, use the compound entry and drop its individual parts.

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
