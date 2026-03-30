# Adding a new grammar database

This is the standing checklist for enrolling any new grammar source.
Kanshudo was enrolled using this checklist (2026-03-30) — it serves as the
worked example when a fifth database arrives.

## Files that need changes (for any new source)

For each item, the Kanshudo change is noted in parentheses as a concrete example.

### 1. `.claude/scripts/shared.mjs` — `loadGrammarDatabases()`

The central registry. Each source gets a `loadTsv(...)` call with its
column layout. Add a new call here with the correct column indices for the
new TSV's schema. This is what makes topic IDs like `newsource:topic`
resolvable across all scripts.

- **Kanshudo columns:** `id, href, level, title, gloss` — no separate
  `title-jp` column and no `alias-of` column, so no opts needed beyond the
  defaults (`titleEnCol: 3` maps to the `title` column).
- **Template:** `loadTsv(path.join(GRAMMAR_DIR, "newsource-grammar.tsv"), "newsource");`
- If the source has a Japanese title column, add `titleJpCol: N`.
- If the source has an alias column, add `aliasOfCol: N`.

### 2. `.claude/commands/cluster-grammar-topics.md` — Step 3

Lists all TSV files for the LLM to grep when searching for cross-database
matches. Add the new TSV and document:
- Its column layout
- The key format (romaji? Japanese script? English slugs?)

- **Kanshudo:** added as "English slugs with underscores, e.g. `passive_voice`"

### 3. `.claude/commands/annotate-grammar.md` — TSV table + grep command

The skill lists each database's columns and includes a literal `grep`
command over all TSV files. Update both the table and the grep line.
Also update the "Select one best match" paragraph to mention the new source
and when to prefer it.

- **Kanshudo:** added as last column in table; added to grep command; noted
  as fallback when other databases lack coverage.

### 4. `grammar/generate-all-topics.mjs`

Generates `grammar/all-topics.json` (used by TestHarness to load any topic
without running prepare-publish first). Add a `parseTSV(...)` loop and a
matching entry in the `sources` map.

- **Kanshudo:** `titleEn` maps to `row.title`; `level` maps to `row.level`.
  Column names may differ from the standard `title-en`/`option` names used
  by the other three sources.

### 5. `README.md` — grammar data-files table (~line 452)

Lists each TSV with a description and scraping instructions. Add a row with:
- Approximate entry count
- Source URL
- Extraction script name

### 6. `grammar/Grammar.md`

Documents each source's schema with example rows. Add a section covering:
- Source URL and extraction script
- `level`/`option` value meanings
- Which columns are present (`title-jp`? `alias-of`? `gloss`?)
- Key format (romaji, Japanese script, English slugs)
- Any caveats (e.g. Kanshudo's Useful1–6 entries are usage notes, not grammar)

---

## Pre-enrollment vetting checklist

Before doing any of the above, verify:

- [ ] Topic IDs are stable across re-scrapes (slugs haven't changed between
  scrapes and are unlikely to be renumbered)
- [ ] Coverage is complementary — spot-check whether the new source overlaps
  heavily with existing ones, or covers genuinely different ground
- [ ] The `title` field is usable as a search key in `annotate-grammar` grep
  workflow (even mixed-script titles work as long as they're greppable)
- [ ] Any "category" or "meta" entries that are not individual grammar points
  are identified (e.g. Kanshudo's Useful1–6 are usage/vocabulary notes) —
  note them in Grammar.md so annotators know when to prefer other sources
- [ ] Grammar page content is fetchable for
  `enrich-grammar-descriptions.mjs --gather` (the `href` column should
  contain full URLs)

## iOS side — no changes needed

`propagateGrammarEbisu` (GrammarQuizContext.swift) already handles new
siblings added to an existing equivalence group: the first time the user
reviews any topic in a cluster, all siblings (including newly added ones
from the new source) automatically receive an `ebisu_models` row via
`INSERT OR REPLACE` and a `grammar_enrollment` row via `INSERT OR IGNORE`.
No Swift changes are required when enrolling a new grammar database.
