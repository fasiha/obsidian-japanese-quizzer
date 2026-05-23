---
description: Annotate all Japanese lines in a Markdown file with vocabulary from JMDict for N5-level learners
---

Annotate every Japanese line in the file at path `$ARGUMENTS` with links to entries in the JMDict dictionary.

## Step 1 — Create the work file

```bash
node annotate-harness.mjs start "$ARGUMENTS"
```

This prints the path of a JSON work file, e.g. `/tmp/Shippo-annotations-1716480000000.json`.

Read that file. It contains:
```json
{
  "sourceFile": "/abs/path/to/file.md",
  "sentences": [
    {
      "id": 5,
      "text": "stripped of ruby tags",
      "furigana": "base[reading]…",
      "morphemes": [
        {
          "literal": "息",
          "pronunciation": "イキ",
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
        }
      ],
      "annotations": []
    }
  ]
}
```

`inflectionType`, `inflection`, and their `*Ja` counterparts are omitted when not applicable. `compoundHint` is omitted when both counts are 0.

If the original line contained ruby annotations, a `furigana` field is present with readings inlined (e.g. `"furigana": "夢を運命[さだめ]と呼ぶ"`). Use it to resolve ateji or unusual readings when looking up JMDict.

## Step 2 — Annotate each sentence

For each sentence in `sentences`, we want a list of entries in JMDict.

### 2a — Identify content word lemmas

From `morphemes`, consider the entries where `isContentWord` is `true`: these are nouns, verbs, adjectives, adverbs, adjectival nouns, etc., and these are likely to have dictionary entries. Use `lemma` as the lookup form (dictionary form for verbs and adjectives). Use `lemmaReadingHiragana` when constructing kana-based searches since the dictionary lookup will normalized to hiragana.

When a morpheme has `isContentWord: true` but seems purely grammatical in context, you may skip it — but when uncertain, include it.

### 2b — Look up each lemma in JMDict

```bash
node lookup.mjs {lemma}
```

Classify as found, not found (try conjugated/inflected base form or prefix search `node lookup.mjs '{stem}*'`), elongated form (cite base), or mimetic/onomatopoeia (try hiragana/katakana/long-vowel/gemination variants).

For morphemes with a non-zero `compoundHint`, construct and run multi-anchor searches combining this morpheme's `lemmaReadingHiragana` with the `lemmaReadingHiragana` of relevant subsequent morphemes. Never use kanji surfaces. Always single-quote the argument:

```bash
node lookup.mjs 'いき*づらい'
node lookup.mjs 'いきおい*よく'
# span a particle between two content words:
node lookup.mjs 'おなか*が*へ'
node lookup.mjs 'あし*を*とめ'
```

This finds dictionary entries spanning multiple morphemes. If a longer compound fits the context, use it. Include the individual parts too if useful to an N5-level learner.

### 2c — Write annotations into the work file

For each sentence, set its `annotations` array in the work file. Each string is one of:

- Found in JMDict with kanji: `{kana reading} {kanji form}`
- Kana-only word: `{kana}`
- Not in JMDict: `Not in JMDict: {word as it appears in text} — {concise meaning in context}`
- Proper noun: `Proper noun: {word} — {MeCab reading} — {English: place, person, or just a name}`

Do **not** include English meanings for JMDict words.
Do **not** annotate grammar (て-form, たら, ので, etc.) — vocabulary only.
If a sentence has no content words, leave `annotations` as `[]`.

After completing each sentence (or a batch of sentences), write the updated JSON back to the work file.

## Step 3 — Report

When finished, run `node annotate-harness.mjs done <work-file>`.
