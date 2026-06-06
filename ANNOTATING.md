# Annotation pipeline guide

This document describes when to run what when annotating Japanese reading files.
It assumes you are in the project root.

---

## Annotate a short story

```bash
node annotate-harness.mjs full "Path/To/Story.md"
```

This is equivalent to:

```bash
node annotate-harness.mjs start "Path/To/Story.md"
# prints: /tmp/Story-annotations-TIMESTAMP.db

node annotate-harness.mjs work /tmp/Story-annotations-TIMESTAMP.db
# (calls /annotate-file in Claude Code for each batch)

node annotate-harness.mjs done /tmp/Story-annotations-TIMESTAMP.db
# produces the resulting files: annotated Markdown and a list of vocab in JSON
```

The result: 
1. `Story.annotated.TIMESTAMP.md` and
2. `Story.annotated.TIMESTAMP.vocab-inline-data.json`  alongside the source.

### Annotate a long novel

```bash
node annotate-harness.mjs start "Path/To/Novel.md" [--mecab-user-dictionary /path/to/user.dic]
# prints: /tmp/Novel-annotations-TIMESTAMP.db same as above

node annotate-harness.mjs work /tmp/Novel-annotations-TIMESTAMP.db \
  [--morpheme-budget 200] \
  [--max-batches 2] \
  [--dry-run]

# Resume work, process next chunk
node annotate-harness.mjs work /tmp/Novel-annotations-TIMESTAMP.db \
  [--max-batches 2]

# Finalize at any time
node annotate-harness.mjs done /tmp/Novel-annotations-TIMESTAMP.db
```

As with the short story, this will produce an annotated Markdown file and a vocab JSON file.

There is one option for `start`:
- `--mecab-user-dictionary` - pass in a custom MeCab UniDic dictionary (see `mecab-user-dict/make-proper-noun-csv.mjs`; this is useful to tell MeCab about proper nouns in your document that it might otherwise mess up)

There are several options for `work`:

- `--morpheme-budget N` — max total morphemes per LLM call (default 400), but at least one sentence will always be processed.
- `--max-batches N` — stop after N batches (N calls to LLM for N chunks of sentences), for incremental annotation.
- `--parallel` — run all batches concurrently (default: sequential).
- `--dry-run` — print the batch plan and exit without calling claude.

> Cost note: annotate-harness.mjs calls `claude -p` and will use your monthly Claude Code subscription (and contributes to 5-hour and weekly limits). It does NOT use Claude API like prepare-publish.mjs does.

## Publish all documents for iOS

1. Rename your file to remove the `.annotated.TIMESTAMP`.
2. Make sure you have the `llm-review: true` YAML frontmatter at the top.
3. Run the traditional publish scripts:

```bash
node --env-file=.env prepare-publish.mjs # --max-senses, --max-kanji-senses etc.
# Updates vocab.json etc.

node publish.mjs
# Pushes vocab.json to GitHub
```

## Render a document in HTML

```bash
node annotate-vocab-inline.mjs "Path/To/Story.annotated.TIMESTAMP.md" \
  | pandoc -s -o /tmp/preview.html && open /tmp/preview.html
```

This creates an HTML file you can read, similar to the iOS Pug app's document reader.
