---
description: Annotate all Japanese lines in a Markdown file with vocabulary from JMDict for N5-level learners
---

Annotate every Japanese line in the file at path `$ARGUMENTS` with links to entries in the JMDict dictionary.

## Step 1 — Create the work file

```bash
node annotate-harness.mjs start "$ARGUMENTS"
```

This prints the path of a SQLite work database, e.g. `/tmp/Shippo-annotations-1716480000000.db`.

The database has a `sentences` table with columns: `id, text, furigana, morphemes, annotations`.

## Step 2 — Survey and annotate in batches

Start by counting how many sentences need annotation:
```bash
sqlite3 /tmp/work.db "SELECT COUNT(*) FROM sentences"
```

Then read the sentence texts (without the large `morphemes` blobs) to get an overview:
```bash
sqlite3 /tmp/work.db ".mode json" "SELECT id, text, furigana FROM sentences"
```

For a short file, process all sentences together. For a long file, work in batches — fetch the `morphemes` for a chunk at a time using LIMIT and OFFSET:
```bash
sqlite3 /tmp/work.db ".mode json" "SELECT id, morphemes FROM sentences LIMIT 10 OFFSET 0"
sqlite3 /tmp/work.db ".mode json" "SELECT id, morphemes FROM sentences LIMIT 10 OFFSET 10"
```

Each row's `morphemes` column is a JSON array of objects, which comes from MeCab-Unidic:
```json
[{
  "literal": "息",
  "pronunciation": "イキ",
  "pronunciationHiragana": "いき",
  "lemmaReading": "イキ",
  "lemmaReadingHiragana": "いき",
  "lemma": "息",
  "pos": "noun-common-general",
  "posJa": "名詞-普通名詞-一般",
  "inflectionType": "sahen_verb_irregular",
  "inflectionTypeJa": "サ行変格",
  "inflection": "continuative-general",
  "inflectionJa": "連用形-一般",
  "isContentWord": true,
  "compoundHint": { "reading": 5, "kanji": 5 }
}]
```

`inflectionType`, `inflection`, and their `*Ja` counterparts are omitted when not applicable. `compoundHint` is omitted when both counts are 0.

If a sentence has a non-null `furigana` field, use it to resolve ateji or unusual readings when looking up JMDict (e.g. `"furigana": "夢を運命[さだめ]と呼ぶ"` tells you 運命 is read さだめ here).

For each sentence, look up and annotate its content words, then move to the next batch.

### 2a — Identify content word lemmas

From `morphemes`, consider the entries where `isContentWord` is `true`: these are nouns, verbs, adjectives, adverbs, adjectival nouns, etc., and these are likely to have dictionary entries. Use `lemma` as the lookup form (dictionary form for verbs and adjectives). Use `lemmaReadingHiragana` when constructing kana-based searches since the dictionary lookup will normalized to hiragana.

When a morpheme has `isContentWord: true` but seems purely grammatical in context, you may skip it — but when uncertain, include it. Process and annotate morphemes in left-to-right order so the vocab list follows the sentence.

### 2b — Look up each lemma in JMDict

```bash
node lookup.mjs {lemma}
```

Classify as found, not found (try conjugated/inflected base form or prefix search `node lookup.mjs '{stem}*'`), elongated form (cite base), or mimetic/onomatopoeia (try hiragana/katakana/long-vowel/gemination variants).

Often, the dictionary will have entries that span multiple morphemes: phrases, idioms, compound words, etc., and we should aggressively search for these. The challenge is that the dictionary will often have slightly different headwords than found in text. For morphemes with a non-zero `compoundHint`, construct and run multi-anchor searches combining this morpheme's reading (`lemmaReadingHiragana` or `pronunciationHiragana`) with the readings of relevant subsequent morphemes to look for such multi-morpheme dictionary entries. Don't use kanji surfaces since JMDict is loose with kanji. Always single-quote the argument:

```bash
node lookup.mjs 'いき*づらい'
node lookup.mjs 'いきおい*よく'
# span a particle between two content words:
node lookup.mjs 'おなか*が*へ'
node lookup.mjs 'あし*を*とめ'
```

If you find a longer entry in the dictionary that fits the context, use it. Include the individual parts too if useful to an N5-level learner.

### 2c — Write annotations into the database

For each sentence, append each vocabulary entry to its `annotations` array. Each string is one of:

- Found in JMDict with kanji: `{kana reading} {kanji form}`
- Kana-only word: `{kana}`
- Not in JMDict: `Not in JMDict: {word as it appears in text} — {concise meaning in context}`
- Proper noun: `Proper noun: {word} — {MeCab reading} — {English: place, person, or just a name}`

Append entries, either one at a time or all entries for a sentence at once:
```bash
sqlite3 /tmp/work.db "UPDATE sentences SET annotations = json_insert(annotations, '\$[#]', 'いきおい 勢い') WHERE id = 9"
# or
sqlite3 /tmp/work.db "UPDATE sentences SET annotations = json('["いきおい 勢い","せなか 背中"]') WHERE id = 9"
```

Do **not** include English meanings for JMDict words.
Do **not** annotate grammar (て-form, たら, ので, etc.) — vocabulary only.
If a sentence has no content words, leave `annotations` as `[]` (the default).

## Step 3 — Report

When finished, run `node annotate-harness.mjs done <work.db>`.
