# BCCWJ frequency lookup: known gaps and workarounds

## How the lookup works

`prepare-publish.mjs` enriches each vocab word with a `bccwjFrequency` field drawn
from `bccwj.sqlite`, which is built from `BCCWJ_frequencylist_luw2_ver1_0.tsv`
(the NINJAL long-unit-word frequency list, downloaded from
https://repository.ninjal.ac.jp/records/3230).

The lookup queries `(kanji, reading)` against the `bccwj` table, trying every
written form and hiragana-normalized reading listed in JMDict for the word.

## Why some common words return null

BCCWJ uses UniDic for morphological analysis. UniDic assigns **one canonical
orthographic lemma per lexeme**, keyed on pronunciation + part-of-speech. When
multiple kanji spellings exist for the same verb (e.g. 帰る and 返る, both read
かえる), UniDic picks one spelling as the representative lemma and counts all
occurrences — regardless of how they were actually written in the source text —
under that single form.

This means that if JMDict entry A lists written forms {帰る, 還る, 歸る, 復る}
and JMDict entry B lists {返る, 反る}, and UniDic chose 返る as its canonical
form, then `bccwjFrequency` for entry A will come back null even though the word
appears thousands of times in BCCWJ.

The same pattern affects other verb clusters: 作る/造る/創る → 作る, 見る/観る →
見る, 聞く/聴く → 聞く, etc. For the current vocab list, only 帰る (JMDict
1221270) was confirmed affected; the other null-frequency words are set phrases,
adverbs, or compound expressions that simply do not appear as units in the BCCWJ
long-unit-word list.

## Workaround: bccwj-overrides.json

`bccwj-overrides.json` at the project root maps JMDict word IDs to the
`{kanji, reading}` pair that BCCWJ actually uses. `prepare-publish.mjs` checks
this file before attempting the normal lookup, so the override frequency is used
whenever a normal lookup would miss.

```json
{
  "overrides": {
    "1221270": { "kanji": "返る", "reading": "かえる" }
  }
}
```

If you add new vocab words that come back with `bccwjFrequency: null` and you
suspect a UniDic canonicalization mismatch, the diagnostic is:

```bash
# Find all null-frequency words
cat vocab.json | jq -r '.words[] | select(.bccwjFrequency == null) | .id' \
  | while read i; do node lookup.mjs $i; done

# Check what BCCWJ has under the same reading
node -e "
import('better-sqlite3').then(({default:D}) => {
  const db = new D('bccwj.sqlite', {readonly:true});
  const rows = db.prepare('SELECT kanji,reading,frequency FROM bccwj WHERE reading=? ORDER BY frequency DESC LIMIT 5').all('かえる');
  console.log(rows);
  db.close();
});
"
```

If a high-frequency row appears under a different kanji, add an entry to
`bccwj-overrides.json`.

## Words that are genuinely absent from BCCWJ

Many multi-word expressions (やってくる, もってくる, 気がする, お願いします, etc.)
and archaic or specialized spellings simply do not appear as long-unit-word lemmas
in BCCWJ. These remain `null` and that is correct — the word is not individually
tracked at that granularity in this corpus. A null frequency does not mean the
word is rare; it means BCCWJ counted it differently (e.g. as separate short-unit
words) or not at all.
