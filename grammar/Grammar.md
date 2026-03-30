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

- **Source:** https://www.kanshudo.com/grammar/index
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

## Planned Markdown usage

Users will annotate content with a `<details><summary>Grammar</summary>` block,
listing grammar points covered by that passage. The bullet format is TBD, but perhaps something like:

```markdown
<details><summary>Grammar</summary>
- bunpro は
- adjectives
</details>
```
