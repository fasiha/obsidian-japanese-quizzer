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

## Reference sources (not enrolled as databases)

These sources are not scraped into TSV files and have no topic IDs, but are
valuable reference material for the `enrich-grammar-descriptions.mjs --gather`
step and for resolving ambiguous clustering decisions.

### IMABI — https://imabi.org

~445 numbered lessons by Seth Coonrod (linguistics and East Asian Studies, UT Austin
2015), edited by Taylor V. Edwards. Human-written by a deep expert; citations trace
to specific classical texts (方丈記, 枕草子, etc.) and footnotes cover historical
phonology accurately.

**Why it is not enrolled yet:** The site is mid-remodel (as of early 2026) with
some lessons numbered `???課` and at least one duplicate lesson number. URL
slugs are derived from lesson titles and may shift during the remodel. Building
a stable TSV requires waiting for the remodel to settle.

**What it covers that the enrolled databases do not:**
- Phonology and pitch accent (dedicated lessons on rendaku, vowel devoicing, etc.)
- Classical Japanese grammar: classical adjective conjugation (ク活用/シク活用),
  classical particles (とて, して, つ, しき, いで), ク語法
- Fine-grained particle analysis: separate lessons for も I–VI, eight separate
  transitive/intransitive lessons, 16+ こそあど lessons
- Word formation: reduplication across parts of speech, native and Sino-Japanese
  affixes, ～かす causative verbs, 自発動詞

**When to use it now:** Fetch the relevant IMABI lesson URL as a reference when
writing `summary`/`subUses`/`cautions` for an advanced or classical construction
that Bunpro, DBJG, and Kanshudo describe inadequately. The lesson pages include
original example sentences from classical texts that are useful for calibrating
scope and nuance.

**Future enrollment:** Once the remodel finishes and URL slugs stabilize,
IMABI is worth enrolling for Advanced/Veteran-level constructions not covered
by the existing four databases. See `TODO-new-grammar-db.md` for the checklist.

## Planned Markdown usage

Users will annotate content with a `<details><summary>Grammar</summary>` block,
listing grammar points covered by that passage. The bullet format is TBD, but perhaps something like:

```markdown
<details><summary>Grammar</summary>
- bunpro は
- adjectives
</details>
```
