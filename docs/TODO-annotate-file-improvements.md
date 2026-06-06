# TODO: annotate-file improvements

Three planned improvements, in order of implementation.

---

## Part 1 — Long-file chunking (revised design)

**Goal:** allow annotation of novel-length files (6 000+ lines) by splitting
work across multiple bounded LLM calls, with a deterministic Node script as
the orchestrator rather than giving the LLM freedom to decide its own batching.

### Key design decisions (arrived at through discussion)

- **Deterministic orchestrator, not LLM-decided chunking.** An LLM given
  free rein may try to do everything in one pass or over-spawn subagents.
  A Node script computes batch boundaries from morpheme counts and calls
  `claude -p` once per batch.
- **Skill becomes range-only.** `annotate-file.md` no longer accepts a
  Markdown file path. It only accepts `"<work.db> <from_id> <to_id>"`.
  This removes all lifecycle logic from the skill — no `start`, no `done`.
  The orchestrator script owns those steps.
- **Minimum one sentence per batch.** If a single sentence exceeds the
  morpheme budget, it still gets its own batch rather than being skipped.
- **`--max-batches N`** caps execution so the user can annotate a novel in
  increments without burning tokens for chapters they may never read.
- **WAL mode** on the work database enables safe concurrent writes when
  `--parallel` is used.

### `annotate-novel.mjs` (new script, done)

```
node annotate-novel.mjs start    <file.md>  [options]   # first run
node annotate-novel.mjs continue <work.db>  [options]   # resume

Options:
  --morpheme-budget N   Max morphemes per batch (default: 400). One sentence
                        always forms at least one batch even if over budget.
  --max-batches N       Stop after N batches (omit to run all).
  --parallel            Run all batches concurrently (default: sequential).
  --dry-run             Print the plan and exit without calling claude.
  --senses              Call /annotate-file-with-senses instead of /annotate-file
                        (see Part 2).
```

1. `start`: calls `node annotate-harness.mjs start <file.md>` → gets work DB path.
   `continue`: accepts existing work DB path directly — skips MeCab re-processing.
2. Queries `SELECT id, json_array_length(morphemes) FROM sentences WHERE annotations = '[]' ORDER BY id`.
3. Greedy-bins into batches by morpheme budget (round up — never split a
   sentence across batches).
4. Applies `--max-batches` cap.
5. `--dry-run`: prints batch count, ID ranges, morpheme totals, then exits.
6. Executes batches: calls `claude -p '/annotate-file "<work.db> <from_id> <to_id>"'`
   (or `/annotate-file-with-senses` when `--senses` is set) sequentially or in parallel.
7. Calls `node annotate-harness.mjs done <work.db>` to produce the annotated
   Markdown.

### `annotate-file.md` (rewritten, done)

Arguments: `$ARGUMENTS` = `<work.db> <from_id> <to_id>` (space-separated).

Steps:
1. Show the last 3 annotated sentences for tonal context (text only; use SQL
   for annotations if needed).
2. Count remaining unannotated sentences in range.
3. Fetch `id, text, furigana, hits` for unannotated sentences in range.
4. Annotate using the existing hits-based vocabulary selection rules.
5. Write annotations to the database.
6. Report how many sentences were annotated.

No `start`, no `done` — those are the orchestrator's responsibility.

### `annotate-harness.mjs` changes (done)

- Work DB created at the start of processing and path printed to stdout
  immediately — visible to `annotate-novel.mjs` and to the user before
  MeCab/JMDict processing begins.
- Each sentence inserted in its own transaction as it is processed — Ctrl-C
  safe; whatever completed is on disk.
- Progress logged to stderr every 50 sentences.
- WAL mode enabled on the work database at creation time.
- `--mecab-user-dictionary /path/to/user.dic` flag on `start` passes `-u` to
  MeCab for custom dictionaries (proper nouns, domain vocabulary, etc.).

---

## Part 1.5 — MeCab homophone disambiguation (done)

**Goal:** guide the LLM to pick the correct entry when MeCab assigns the wrong
lemma for a homophone pair (e.g. わく → 沸く vs. 湧く).

### Why this is not a harness bug

`buildSentenceHits` (line 449–454 of `annotate-harness.mjs`) performs
single-morpheme lookups against all of `[literal, lemma, pronunciationHiragana,
lemmaReadingHiragana]`. Even when MeCab's chosen lemma is 沸く, the hiragana
reading わく is also searched, so both 沸く and 湧く appear in `hits`. The
problem is purely one of LLM selection, not missing data.

### Change to `annotate-file.md` (done)

Added to step 2b: when two or more entries at the same position share the same
reading but differ in written form or meaning, all appear in `hits`. Do not
default to the first entry — use sentence context to pick the correct one.

---

## Part 2 — Sense classification during annotation

**Goal:** let the annotating LLM simultaneously record which JMDict sense(s)
apply to each word in context, eliminating the separate Haiku call in
`prepare-publish.mjs` and enabling `annotate-vocab-inline.mjs` to run without
a populated `vocab.json`.

### New skill: `annotate-file-with-senses.md`

A variant of `annotate-file.md` with the same arguments (`<work.db> <from_id>
<to_id>`) and the same DB lifecycle (no `start`, no `done`). Invoked by
`annotate-novel.mjs --senses` instead of `/annotate-file`.

The skill does everything `/annotate-file` does, and additionally:

1. For each annotated word, selects the zero-based sense index/indices from the
   `meanings` field in `hits` that best fit the sentence context.
2. Stores annotations as objects rather than bare strings:
   ```json
   { "form": "いきおい 勢い", "wordId": "1234567", "sense_indices": [0] }
   ```

Can be run on a fresh DB (annotate + classify in one pass) or on a DB that
already has bare-string annotations (sense classification only — skip rows
where annotations are already objects).

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
  BCCWJ frequency is looked up from `jmdict.sqlite` at `done` time.

### Changes to `annotate-vocab-inline.mjs`

- Accept an optional `--inline-data <path>` argument pointing to the sidecar
  JSON produced above.
- When `vocab.json` is absent or lacks an entry, fall back to the sidecar for
  sense indices and frequency.
- This allows the full pipeline
  `annotate-novel.mjs → annotate-harness.mjs done → annotate-vocab-inline.mjs | pandoc`
  to produce a readable HTML file without ever running `prepare-publish.mjs`.
