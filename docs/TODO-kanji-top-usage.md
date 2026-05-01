# Kanji top-usage frequency feature

## Rationale

Standard Japanese dictionary apps (including those that use JMDict) let you tap a
kanji and see every word that contains it, with readings — but they give no sense
of what is actually common. You see 見る and 見送る listed side by side with no
indication that 見る appears at 1865 occurrences per million words while 見送る
barely registers. BCCWJ frequency data fills that gap.

A learner who looks up 難 sees むずかしい and なん listed equally, but in BCCWJ
corpus data 有り難う (93 pmw) nearly matches 困難 (53 pmw) — the gratitude word
swamps both and would surprise most learners. This feature makes that visible.

The goal: for each kanji that appears in the corpus vocabulary, show the top words
by BCCWJ long-unit-word frequency that contain that kanji character. A horizontal
proportional meter (fraction of the sum of the displayed rows' pmw totals) lets
the learner see at a glance whether one word dominates (見 → 見る at 1865 pmw,
4× the next entry) or whether the kanji is spread across many equally-weighted
compounds (両 → 両親/両手/両方 all within 20 pmw of each other).

Secondary benefit: kanji with a thin long tail (勉 is essentially just 勉強,
泳 is essentially just 泳ぐ) are immediately distinguishable from kanji with rich
compound lives (上, 下, 気, 見).

## Key findings from prototype script

- `kanji-frequency-top10.mjs` (project root) produces the data from the 1532
  vocab words in the corpus, yielding 989 unique kanji characters.
- Output saved to `/tmp/kanji-frequency-top10.txt` for review.
- The BCCWJ table used is `bccwj` (long-unit-word), not `bccwj_suw_counters`.
  Long-unit-word is correct for word-level frequency; short-unit-word would
  fragment compounds into morphemes.
- Some kanji (困難, 苦痛, 不安) show duplicate rows at different pmw values.
  These are the same written form split by part of speech in BCCWJ (noun vs.
  na-adjective counted separately by UniDic). The true combined frequency is the
  sum; showing them separately is arguably informative (reveals dual grammatical
  function). The iOS UI should handle this gracefully — grouping or summing is a
  display decision, not a data decision.
- Kanji form filtering: exclude forms tagged `rK` (rare), `iK` (irregular kanji),
  `sK` (search-only), `oK` (outdated), `ateji`. Keep `io` (irregular okurigana)
  as those are real written spellings. The `uk` tag ("usually written in kana")
  is a sense-level tag, not a kanji-form tag, and is intentionally ignored here —
  the kanji are still worth displaying even for usually-kana words.
- `common` is a boolean field directly on JMDict kanji and kana entries (confirmed
  by inspecting jmdict-simplified-node output). This is used for the flagging
  check described below.
- The `furigana` table is bundled inside `jmdict.sqlite` (confirmed: table exists
  alongside `entries`, `kanas`, `kanjis`). Every word in the top-usage list can
  therefore be rendered with full furigana segmentation in the iOS UI — no
  additional data bundle needed.

## Data shape

Output file: `kanji-top-usage.json` (new, alongside `vocab.json`).

```jsonc
{
  "generatedAt": "2026-04-29T00:00:00.000Z",
  "kanji": {
    "見": {
      "totalMatches": 312,
      "words": [
        { "id": "1579430", "pmw": 1865.1 },
        { "id": "1421850", "pmw": 420.2 },
        ...
        // up to 50 entries
      ]
    },
    "難": {
      "totalMatches": 47,
      "words": [
        { "id": "1170350", "pmw": 142.6 },
        { "id": null, "kanji": "有り難う", "reading": "ありがとう", "pmw": 93.1 },
        ...
      ]
    }
  }
}
```

- `totalMatches`: total number of BCCWJ rows containing the kanji character
  (i.e., what the count would be with no LIMIT). Lets the iOS UI show "showing
  10 of 312" and page through in chunks of 10.
- `words`: up to 50 entries, sorted by `pmw` descending. The iOS UI shows 10 at
  a time with a "show more" control.
- When `id` is non-null, the iOS app fetches the written form, readings, and
  furigana from jmdict.sqlite at runtime — no display strings needed in the JSON.
  This is consistent with how vocab.json stores only IDs, never duplicating
  linguistic content that lives in jmdict.sqlite.
- When `id` is `null` (no JMDict entry matched this BCCWJ row), `kanji` and
  `reading` strings are included so the row can still be displayed. The row
  is not tappable (no WordDetailSheet to navigate to).
- The proportional meter in each row uses `pmw / sum(displayed rows' pmw)`, so
  paging to the next 10 re-normalizes to those rows' totals.

## Flagging: common JMDict words absent from BCCWJ

After collecting top-50 for a given kanji, separately scan JMDict for words that:

1. Contain this kanji as a normal (non-excluded) kanji form, AND
2. Have `common: true` on at least one kanji or kana form, AND
3. Do not appear in the top-50 list (no BCCWJ row matched them, or their pmw
   is below the 50th entry).

Print these to stdout as warnings during `prepare-publish.mjs` so a human or LLM
can review whether a UniDic canonicalization mismatch is hiding a truly frequent
word (the same issue documented in `docs/TODO-bccwj-frequency.md` for 帰る). Do
not block the build — just warn. Example output:

```
[kanji-top-usage] 見: common JMDict word 見做す (1316670) has no BCCWJ match — possible UniDic mismatch?
```

These warnings are the signal to check `bccwj-overrides.json` and add an entry
if the word is genuinely frequent under a different BCCWJ headword.

## Matching BCCWJ rows to JMDict IDs

BCCWJ rows have `(kanji, reading)` but no JMDict ID. Matching strategy:

1. For each BCCWJ row, query jmdict.sqlite for entries whose kanji forms include
   the BCCWJ kanji text and whose kana forms include the reading (after
   katakana→hiragana normalization, same as `toHiragana()` in prepare-publish.mjs).
2. If multiple JMDict entries match, prefer the one already in `vocab.json`
   (corpus word), otherwise take the first match.
3. If no match, emit `id: null`.

The `toHiragana` function already exists in prepare-publish.mjs and can be
reused directly.

## Furigana in the iOS UI

The `furigana` table in `jmdict.sqlite` maps written forms to furigana
segmentation objects (same data as JmdictFurigana.json, bundled into the SQLite
database). The iOS app already queries this table for other features. Each row
in the top-usage list can therefore be rendered with full ruby/furigana in
`KanjiDetailSheet` with no additional data bundling.

## Work plan

### Step 1 — Add `buildKanjiTopUsage` to prepare-publish.mjs

Add a function `buildKanjiTopUsage(words, jmdictById, corpusWordIds, bccwjDb)`
that:

- Extracts unique kanji characters from non-excluded kanji forms of corpus words
  (same logic as `kanji-frequency-top10.mjs`).
- For each kanji character:
  - Queries `SELECT kanji, reading, pmw FROM bccwj WHERE kanji LIKE ? ORDER BY pmw DESC LIMIT 50`
  - Also queries `SELECT count(*) FROM bccwj WHERE kanji LIKE ?` for `totalMatches`.
  - Attempts to match each row to a JMDict ID using the strategy above.
  - Checks for common JMDict words absent from the results and prints warnings.
- Returns `{ [kanjiChar]: { totalMatches, words: [...] } }`.

Call this after the final `words` array is settled (after kanji meanings analysis,
around line 1344). Write the result to `kanji-top-usage.json`. Respect `--dry-run`
(skip the write but still compute, so warnings surface in dry runs too).

### Step 2 — Wire into publish.mjs

Add `kanji-top-usage.json` to the `FILES` array in `publish.mjs` (around line 62)
so it is copied to the private GitHub repo alongside vocab.json.

### Step 3 — iOS: KanjiDetailSheet frequency list

In `KanjiDetailSheet.swift`, below the existing `KanjiInfoCard`, add a "Top words
by corpus frequency" section:

- Show 10 rows at a time with a "Show more" button (up to 50 total).
- Each row: furigana-rendered written form on the left (using the `furigana` table
  via the existing furigana query path), pmw value on the right, horizontal bar
  proportional to `pmw / sum(displayed rows' pmw)`.
- Show "N of M words" count (N = displayed so far, M = `totalMatches`) below the
  list to communicate that 50 is a cap, not the full universe.
- Tapping a row with a non-null `id` navigates to that word's `WordDetailSheet`.

### Step 4 — WordDetailSheet: caret to KanjiDetailSheet

In `WordDetailSheet`, make `KanjiInfoCard` 90% width and add a `>` chevron
button to the right. Tapping it presents `KanjiDetailSheet` for that kanji,
the same way the post-kanji-quiz "Details" button does.

## Mismatch finder script

`.claude/scripts/find-bccwj-mismatches.mjs` is a periodic review tool that
surfaces JMDict-common words whose frequency is likely hidden under a different
BCCWJ spelling (the same UniDic canonicalization problem as 帰る → 返る).

**Inputs:**
- `vocab.json` — corpus word IDs; used to extract the set of kanji characters
  to check, and to flag candidates that are also corpus words (higher priority)
- `jmdict.sqlite` — full JMDict; provides kanji forms, readings, and
  part-of-speech tags for filtering
- `bccwj.sqlite` — LUW frequency table; used for two queries per candidate:
  exact `(kanji, reading)` match check, and `reading`-only lookup to find what
  BCCWJ has under the same pronunciation
- `bccwj-overrides.json` — already-resolved entries are skipped so output only
  shows new candidates

**Noise filters applied** (candidates that pass all of these are shown):
- Part of speech is not particle, expression, conjunction, or interjection
- No `id` (idiomatic) misc tag
- Not a proper noun (`n-pr`)
- Reading does not end with a grammatical particle (に, で, と, へ, を, …) —
  catches adverbial set phrases that BCCWJ tokenizes differently
- Kanji text does not contain 〇 (circled-zero numeral spelling artifact)
- Shortest normal kanji form is ≤ 8 characters (longer = likely a phrase)

**Output:** candidates sorted by the highest pmw found in BCCWJ under the same
reading, so the most impactful mismatches appear first. For each candidate,
shows all BCCWJ rows for that reading so the reviewer can immediately see which
spelling BCCWJ uses.

**Running it with Claude:** paste the top N candidates from the output and ask
Claude to classify each as real mismatch (→ add to `bccwj-overrides.json`) or
false positive (→ explain why). Full output saved to `/tmp/bccwj-mismatches.txt`
on each run (4270 lines, 887 candidates as of 2026-04-30).

**Known false positives in current output:**
- 子【ね】, 代【よ】 — JMDict POS is `n` so the noise filter passes them, but
  the high-pmw BCCWJ hit is the sentence-final particle ね/よ (kana form), not
  a matching lexeme. Need a smarter filter: if the top BCCWJ hit is kana-only
  and the JMDict word is a noun, it's likely a homophones-not-a-match situation.

**Improvements to make:**
- Add a `"dismissed"` key to `bccwj-overrides.json` (alongside `"overrides"`)
  to permanently record JMDict IDs that have been reviewed and confirmed as
  false positives. The script already skips `overrides` keys; it should also
  skip `dismissed` keys. This prevents Claude from being asked about the same
  entry on every run.
- Tighten the ね/よ false positive: if every BCCWJ hit for the reading is
  kana-only (kanji === reading), and the JMDict entry has a kanji form, skip it.
- Consider emitting a JSON file (e.g. `bccwj-mismatches-review.json`) alongside
  the human-readable stdout, so a future Claude session can process it
  programmatically rather than parsing text.

## Open questions

- **Duplicate BCCWJ rows** (same written form, different part of speech): display
  as separate rows (preserves grammatical information) or merge by summing pmw?
  Current prototype leaves them separate. Decide when implementing Step 3.
- **bccwj.sqlite bundle size**: the file is currently server-side only. Step 1
  keeps it that way (queried at publish time, not at app runtime). No bundle size
  impact.
- **Kanji not in BCCWJ**: some rare kanji in the corpus will have zero BCCWJ
  hits. Omit them from `kanji-top-usage.json` entirely (the key simply won't
  exist), and the iOS UI should handle a missing key gracefully (show nothing or
  a "no frequency data" placeholder).
- **Proportional meter across pages**: when the user pages from rows 1–10 to
  11–20, should the bar widths re-normalize to the new page's sum, or stay
  relative to the overall top-10 sum? Re-normalizing each page is simpler and
  keeps bars visually meaningful; using a fixed reference (top-10 sum) would show
  the tail shrinking as you page, which is also informative. Decide in Step 3.
