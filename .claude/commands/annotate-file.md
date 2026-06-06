---
description: Annotate all Japanese lines in a Markdown file with vocabulary from JMDict for N5-level learners
---

Annotate every Japanese line in the file at path `$ARGUMENTS` with links to entries in the JMDict dictionary.

## Step 1 — Create the work file

```bash
node annotate-harness.mjs start "$ARGUMENTS"
```

This prints the path of a SQLite work database, e.g. `/tmp/Shippo-annotations-1716480000000.db`.

The database has a `sentences` table with columns: `id, text, furigana, morphemes, hits, annotations`.

## Step 2 — Survey and annotate in batches

Start by counting how many sentences need annotation:
```bash
sqlite3 /tmp/work.db "SELECT COUNT(*) FROM sentences"
```

Then read the sentence texts to get an overview:
```bash
sqlite3 /tmp/work.db ".mode json" "SELECT id, text, furigana FROM sentences"
```

For a short file, process all sentences together. For a long file, work in batches — fetch `hits` for a chunk at a time using LIMIT and OFFSET:
```bash
sqlite3 /tmp/work.db ".mode json" "SELECT id, text, furigana, hits FROM sentences LIMIT 10 OFFSET 0"
```

### 2a — Understand the hits array

Each sentence has a `hits` array — a pre-computed list of JMDict entries found in the sentence, sorted **start ascending, end descending** (longest span at each position comes first):

```json
[
  { "start": 3, "end": 6, "wordId": "1234567",
    "forms": "written:お腹が減る,お腹がへる  reading:おなかがへる",
    "meanings": "(1) to become hungry [expressions, Godan verb with 'ru' ending]" },
  { "start": 3, "end": 4, "wordId": "1234568",
    "forms": "written:お腹,お腹  reading:おなか",
    "meanings": "(1) belly; stomach [noun]" },
  ...
]
```

`start` and `end` are indices into the MeCab morpheme array (end is exclusive). An entry with `end - start > 1` spans multiple morphemes — a compound verb, idiom, or set phrase. **Prefer longer spans when they fit the sentence context.**

If `furigana` is non-null (e.g. `"夢を運命[さだめ]と呼ぶ"`), use it to resolve unusual readings when a hit's forms don't obviously match the text.

### 2b — Select vocabulary coverage

Read the `hits` array for a sentence. Work through it position by position. For each position:

1. Look at the longest-span entry first (it appears first in the array due to the sort order).
2. If it fits the sentence context, annotate it as a single vocabulary entry covering those morphemes.
3. Then also annotate any content-word components of that compound individually — an N5-level learner needs to know おなか and 減る separately to recognize お腹が減る in new contexts. Look for the component words at their respective positions in the `hits` array.
4. If the longest span doesn't fit, try shorter spans at the same start position.
5. If no hit at this position covers a content word you want to annotate, fall back to `node lookup.mjs {word}` — use this when MeCab clearly misparsed, the reading is unusual, or the word is mimetic/onomatopoeic.

**Homophones:** when two or more entries at the same position share the same reading but differ in written form or meaning (e.g. 沸く vs. 湧く, both read わく), all will appear in `hits`. Do not default to the first entry — use sentence context to pick the semantically correct one. For example, つばがわいてきた describes saliva welling up: 湧く ("to well up; to appear") fits, 沸く ("to boil; to get excited") does not. MeCab sometimes assigns the wrong lemma for a homophone, but the harness searches by reading as well as by lemma, so the correct entry is always present in `hits`.

You do not need to consult `morphemes` for most sentences — `hits` already encodes the content words and their dictionary forms. `morphemes` is available if you need POS details or to resolve a furigana ambiguity.

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
