# Grammar databases

Grammar points are catalogued in TSV files, one per source. Each row describes a
single grammar point with these fields:

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Short typable slug (used in Markdown `<details>` bullets) |
| `href` | yes | Canonical URL for the grammar point |
| `option` | yes | Level indicator (JLPT level for Bunpro; "Genki I"/"Genki II" for Genki) |
| `title-en` | yes | English description |
| `title-jp` | no | Japanese snippet (Bunpro only) |

## Current databases

### Bunpro — `grammar-bunpro.tsv` (~943 entries)

- **Source:** https://bunpro.jp/grammar_points
- **Extraction script:** `bunpro-website.js` (paste into browser console on that page)
- **`option` values:** `jlptN5` → `jlptN1` (easy → hard), or `jlptNT` (unclassified)
- **Both** `title-jp` and `title-en` are present

Example rows:

| id | option | title-jp | title-en |
|----|--------|----------|----------|
| `だ` | jlptN5 | だ | To be, Is |
| `は` | jlptN5 | は | As for… (Highlights sentence topic) |

### St. Olaf Genki — `grammar-stolaf-genki.tsv` (~123 entries)

- **Source:** https://wp.stolaf.edu/japanese/grammar-index/genki-i-ii-grammar-index/
- **Extraction script:** `stolaf-genki-website.js` (paste into browser console on that page)
- **`option` values:** `Genki I` or `Genki II`
- **Only** `title-en` is present (no `title-jp`)

Example rows:

| id | option | title-en |
|----|--------|----------|
| `adjectives` | Genki I | Adjectives |
| `ageru-kureru-morau` | Genki II | ageru, kureru, morau |

### DBJG — `grammar-dbjg.tsv` (~370 entries)

- **Source:** *A Dictionary of Basic Japanese Grammar*, Makino & Tsutsui
- **Extraction:** Manually typed from the book's index
- **`option` values:** empty (book does not assign JLPT levels)
- **Only** `title-en` is present (no `title-jp`)
- **Aliases:** Some entries have a non-empty `alias-of` column pointing to a canonical entry. Only canonical entries belong in equivalence groups — alias entries should be ignored during clustering.

Example rows:

| id | title-en |
|----|----------|
| `te-iru` | te iru |
| `nara` | nara |

### Kanshudo — `kanshudo-grammar.tsv` (~1300 entries)

- **Source:** https://www.kanshudo.com/grammar/overview
- **Extraction script:** `kanshudo-website.js` (paste into browser console on that page)
- **`level` values:** `Useful1` through `Useful6` (usage/vocabulary notes), `Essential` (core grammar), or blank
- **Columns:** `id`, `href`, `level`, `title`, `gloss` — no `title-jp`, no `alias-of`
- **Key format:** English slugs with underscores, e.g. `passive_voice`, `te_form`
- **Note:** The ~743 "Useful1–6" entries are usage/vocabulary notes rather than pure grammar topics; they are included in the database but may not always be the best match for grammar annotations. Prefer Bunpro, DBJG, or Genki for standard grammar points; use Kanshudo when it covers something the other databases lack.

Example rows:

| id | level | title |
|----|-------|-------|
| `passive_voice` | Essential | Passive voice |
| `te_form` | Essential | Te-form |

### IMABI — `grammar-imabi.tsv` (small, hand-curated)

- **Source:** https://imabi.org — ~445 lessons by Seth Coonrod (linguistics and East Asian Studies, UT Austin 2015), edited by Taylor V. Edwards
- **Extraction:** Hand-curated; URLs maintained manually by the user
- **`level` values:** `Classical`, `Intermediate III`, etc. (lesson difficulty labels from the site)
- **Columns:** `id`, `href`, `level`, `title` — no `title-jp`, no `alias-of`, no `gloss`
- **Key format:** English slugs with hyphens, e.g. `bound-particles`, `the-auxiliary-verb-～ず-i`
- **Coverage:** Classical Japanese grammar (classical adjective conjugation, bound particles, classical auxiliary verbs), fine-grained particle analysis, phonology, and word formation — territory not covered by the other four databases
- **Note:** Only a small number of hand-selected topics are enrolled; the full IMABI site (~445 lessons) is not scraped. The site is mid-remodel (as of early 2026) with some lessons numbered `???課` and possibly shifting URL slugs. The user adds entries selectively. See `TODO-new-grammar-db.md` for the full enrollment checklist when the remodel settles.
- **When to prefer IMABI:** Use for classical constructions (classical particles, classical auxiliary verbs) and advanced topics not well described in Bunpro, DBJG, or Kanshudo. Even if a topic is not yet in the TSV, fetch the relevant IMABI lesson URL as a reference when writing `summary`/`subUses`/`cautions`.

Example rows:

| id | level | title |
|----|-------|-------|
| `bound-particles` | Classical | Bound Particles |
| `the-auxiliary-verb-～ず-i` | Intermediate III | The Auxiliary Verb ～ず (I) |

## Reference sources (not enrolled as databases)

These sources are not scraped into TSV files and have no topic IDs, but are
valuable reference material for the `enrich-grammar-descriptions.mjs --gather`
step and for resolving ambiguous clustering decisions.

## Planned Markdown usage

Users will annotate content with a `<details><summary>Grammar</summary>` block,
listing grammar points covered by that passage. The bullet format is TBD, but perhaps something like:

```markdown
<details><summary>Grammar</summary>
- bunpro は
- adjectives
</details>
```
