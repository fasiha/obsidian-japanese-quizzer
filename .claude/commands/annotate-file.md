---
description: Annotate a range of Japanese sentences in an existing work database with vocabulary from JMDict, recording which sense(s) apply in context
---

Annotate Japanese sentences in an existing work database, and for each JMDict word record which sense(s) best fit the sentence context.

Arguments (`$ARGUMENTS`): three space-separated values — work database path, start sentence ID, end sentence ID (both inclusive).

Example: `/tmp/JustBecause-annotations-1716480000000.db 0 49`

The database has a `sentences` table with columns: `id, text, furigana, morphemes, hits, annotations`.

## Step 1 — Orient yourself

Show the last three sentences that already have annotations, for tonal context:
```bash
sqlite3 <work.db> ".mode json" "SELECT id, text FROM sentences WHERE annotations != '[]' ORDER BY id DESC LIMIT 3"
```

Then count how many sentences in your range still need annotation:
```bash
sqlite3 <work.db> "SELECT COUNT(*) FROM sentences WHERE id BETWEEN <from_id> AND <to_id> AND annotations = '[]'"
```

If this is zero, you have no work to do. Stop.

## Step 2 — Fetch and annotate

Fetch the unannotated sentences in your range:
```bash
sqlite3 <work.db> ".mode json" "SELECT id, text, furigana, hits FROM sentences WHERE id BETWEEN <from_id> AND <to_id> AND annotations = '[]' ORDER BY id"
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

### 2c — Determine sense indices

The `meanings` field in each hit lists all JMDict senses, numbered from (1). These are **1-indexed in display** but must be stored as **0-based integers**.

For each JMDict entry you decide to annotate, read all its senses and select the one(s) that best match how the word is used in this sentence. Most words have one applicable sense. Use multiple indices only when the sentence is genuinely ambiguous or metaphorical and two senses both apply.

Example: 食べる has senses (1) to eat; (2) to live on (earnings). In a sentence about eating yams, `sense_indices` is `[0]`.

### 2d — Write annotations into the database

Each annotation is a JSON object with three fields:

- `form` — the display string (same format as before):
  - Found in JMDict with kanji: `"{kana reading} {kanji form}"`
  - Kana-only word: `"{kana}"`
- `wordId` — the JMDict entry ID string from the `hits` array
- `sense_indices` — array of 0-based integers identifying which sense(s) apply

For words **not in JMDict** or **proper nouns**, keep using the old bare-string format (the harness handles both):
- Not in JMDict: `"Not in JMDict: {word as it appears in text} — {concise meaning in context}"`
- Proper noun: `"Proper noun: {word} — {MeCab reading} — {English: place, person, or just a name}"`

Write all annotations for a sentence at once using `json()`:
```bash
sqlite3 <work.db> "UPDATE sentences SET annotations = json('[{\"form\":\"いきおい 勢い\",\"wordId\":\"1234567\",\"sense_indices\":[0]},{\"form\":\"せなか 背中\",\"wordId\":\"1234568\",\"sense_indices\":[0]}]') WHERE id = 9"
```

Or insert one object at a time:
```bash
sqlite3 <work.db> "UPDATE sentences SET annotations = json_insert(annotations, '\$[#]', json('{\"form\":\"いきおい 勢い\",\"wordId\":\"1234567\",\"sense_indices\":[0]}')) WHERE id = 9"
```

Do **not** include English meanings for JMDict words.
Do **not** annotate grammar (て-form, たら, ので, etc.) — vocabulary only.
If a sentence has no content words, leave `annotations` as `[]` (the default).

## Step 3 — Report

Report how many sentences you annotated out of how many were in your range.
