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

## Planned Markdown usage

Users will annotate content with a `<details><summary>Grammar</summary>` block,
listing grammar points covered by that passage. The bullet format is TBD, but perhaps something like:

```markdown
<details><summary>Grammar</summary>
- bunpro は
- adjectives
</details>
```
