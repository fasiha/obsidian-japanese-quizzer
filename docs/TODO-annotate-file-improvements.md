# TODO: annotate-file improvements

Three planned improvements, in order of implementation.

---

## Part 1 — Long-file chunking

**Goal:** allow `annotate-file` to work on novel-length files (6 000+ lines) by
processing the work database in bounded batches instead of attempting the whole
file in a single agent turn.

### Changes to `annotate-harness.mjs`

- Add an optional `--range <first-id>-<last-id>` argument to `start` so the
  caller can restrict which sentence IDs are inserted into the work database.
  This lets multiple agent invocations share a single database (SQLite WAL mode
  handles concurrent `UPDATE` writes safely).
- Alternatively — simpler to implement first — accept `--limit N` and
  `--offset M` on `start` and let the caller slice by position.
- Add `WHERE annotations = '[]'` to the `done` read path so re-runs are
  idempotent and a partially-annotated database can be continued without
  re-processing already-done sentences.

### Changes to `annotate-file.md` (the skill)

- Cap each agent pass at **15 sentences** (novels have page-long paragraphs;
  short-story files averaged ~5 lines per batch, but this ceiling keeps token
  counts predictable).
- Instruct the agent to skip rows where `annotations != '[]'` — i.e. fetch
  only unannotated sentences in each `LIMIT`/`OFFSET` block.
- Document the parallel-agent workflow: initialize one work database with
  `start`, then invoke the skill N times with non-overlapping `--range`
  arguments, then call `done` once at the end.

---

## Part 1.5 — MeCab homophone disambiguation

**Goal:** guide the LLM to pick the correct entry when MeCab assigns the wrong
lemma for a homophone pair (e.g. わく → 沸く vs. 湧く).

### Why this is not a harness bug

`buildSentenceHits` (line 449–454 of `annotate-harness.mjs`) performs
single-morpheme lookups against all of `[literal, lemma, pronunciationHiragana,
lemmaReadingHiragana]`. Even when MeCab's chosen lemma is 沸く, the hiragana
reading わく is also searched, so both 沸く and 湧く appear in `hits`. The
problem is purely one of LLM selection, not missing data.

### Change to `annotate-file.md`

Add a note to step 2b:

> **Homophones:** when two or more entries at the same position share the same
> reading but differ in written form or meaning (e.g. 沸く vs. 湧く, both read
> わく), all appear in `hits`. Do not default to the first entry. Use sentence
> context to pick the semantically correct one. For example, つばがわいてきた
> describes saliva welling up — 湧く ("to well up; to appear") fits; 沸く
> ("to boil; to get excited") does not.

---

## Part 2 — Sense classification during annotation

**Goal:** let the annotating LLM simultaneously record which JMDict sense(s)
apply to each word in context, eliminating the separate Haiku call in
`prepare-publish.mjs` and enabling `annotate-vocab-inline.mjs` to run without
a populated `vocab.json`.

### New skill: `annotate-file-with-senses.md`

A variant of `annotate-file.md` that:

1. Requires a completed work database (all `annotations` rows non-empty, or runs
   after Part 1 finishes a pass).
2. For each sentence, asks the LLM to output, per annotation entry, the
   zero-based sense index/indices from the `meanings` field in `hits` that best
   fit the sentence context.
3. Stores results in a new `sense_indices` column (JSON integer array) on the
   `sentences` table, or extends the `annotations` column format from bare
   strings to objects:
   ```json
   { "form": "いきおい 勢い", "wordId": "1234567", "sense_indices": [0] }
   ```

### Changes to `annotate-harness.mjs done`

- When sense data is present in the work database, emit a sidecar
  `<basename>.vocab-inline-data.json` alongside the annotated Markdown:
  ```json
  {
    "words": {
      "1234567": { "sense_indices": [0], "bccwjPerMillionWords": 29.4 }
    }
  }
  ```
  BCCWJ frequency is looked up from `jmdict.sqlite` at `done` time (it is
  already available there or via the BCCWJ table).

### Changes to `annotate-vocab-inline.mjs`

- Accept an optional `--inline-data <path>` argument pointing to the sidecar
  JSON produced above.
- When `vocab.json` is absent or lacks an entry, fall back to the sidecar for
  sense indices and frequency.
- This allows the full pipeline
  `annotate-file-with-senses → annotate-harness done → annotate-vocab-inline | pandoc`
  to produce a readable HTML file without ever running `prepare-publish.mjs`.
