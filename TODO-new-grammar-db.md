# Adding a new grammar database

Notes for when Kanshudo (or any other source) is formally enrolled.
The TSV file alone (`grammar/kanshudo-grammar.tsv`) is **not enough** —
everything below is hardcoded to the three existing sources.

## Files that need changes

### 1. `.claude/scripts/shared.mjs` — `loadAllGrammarTopics()`
The central registry. Each source gets a `loadTsv(...)` call with its
column layout. You must add a new call here with the correct column indices
for the new TSV's schema. This is what makes topic IDs like `kanshudo:か`
resolvable across all scripts.

The Kanshudo TSV columns are: `id, href, level, title, gloss` — there is no
separate Japanese title column (title mixes Japanese and English) and no
`alias-of` column, so the call would be simpler than Bunpro/DBJG.

### 2. `.claude/commands/cluster-grammar-topics.md` — Step 3
Lists the three TSVs by name for the LLM to grep when searching for
cross-database matches. Add the Kanshudo TSV and document its column layout
and the fact that keys can be Japanese script (unlike Genki/DBJG romaji keys).

### 3. `.claude/commands/annotate-grammar.md` — TSV table + grep command
The skill lists each database's columns and includes a literal `grep` command
over all three TSV files. Both the table and the grep line need updating.

### 4. `grammar/generate-all-topics.mjs`
Generates a combined topic list (used by… check what consumes its output).
Has three explicit `parseTSV(...)` loops. Add a fourth for Kanshudo.

### 5. `README.md`
The grammar data-files table (around line 452) lists each TSV with a
description and scraping instructions. Add a row for `kanshudo-grammar.tsv`
pointing to `grammar/kanshudo-website.js`.

### 6. `grammar/Grammar.md`
Documents each source's schema. Add a section for Kanshudo.

## Pre-enrollment vetting checklist

Before doing any of the above, verify:

- [ ] Topic IDs are stable across re-scrapes (Kanshudo slugs haven't changed
  between scrapes)
- [ ] Coverage is complementary — spot-check whether Kanshudo topics overlap
  heavily with Bunpro, or cover genuinely different ground
- [ ] The `title` field is usable as a search key despite mixing Japanese and
  English (the `annotate-grammar` grep workflow depends on this)
- [ ] The 743 "Useful1–6" entries are worth including — they may be more
  vocabulary/usage notes than grammar topics proper
- [ ] Kanshudo's grammar page content is fetchable for
  `enrich-grammar-descriptions.mjs --gather` (the `href` column already
  contains full URLs, so this should work without changes to that script)
