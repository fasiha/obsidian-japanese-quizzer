# llm-review — Japanese vocabulary and grammar review with Claude

A [home-cooked app](https://www.robinsloan.com/notes/home-cooked-app/) for my family
to learn Japanese from reading passages we study together. Stories live as Markdown
files in an Obsidian vault; a SwiftUI iOS app (Pug) quizzes each family member
individually using Claude as a conversational tutor.

The quiz experience is **not** a flashcard deck. Each question is an open-ended chat
with Claude — you can stop mid-question and ask "how does this kanji relate to 怒る?"
or "give me a mnemonic," and Claude engages fully before circling back. The corpus is
shared but every family member has their own learning state (spaced repetition via
[Ebisu](https://github.com/fasiha/ebisu), ported to Swift).

**Why share this repo?** To share the kanji, vocabulary, and grammar resources that can be
combined to build opinionated Japanese learning tools. Tools that could use LLMs both *in*
the tool itself and to *build* the tool.

---

## Setup

### 0. Clone this repo
```bash
git clone https://github.com/fasiha/obsidian-japanese-quizzer.git
cd obsidian-japanese-quizzer
```

### 1. Install dependencies

```bash
npm install
```

### 2. Build jmdict.sqlite

Download these files into the project root:
- `jmdict-eng-*.json` (~50 MB) from [jmdict-simplified releases](https://github.com/scriptin/jmdict-simplified/releases)
- `JmdictFurigana.json` from [JmdictFurigana releases](https://github.com/Doublevil/JmdictFurigana/releases)

```bash
# Build the base database
node .claude/scripts/check-vocab.mjs

# Add furigana data (idempotent — safe to re-run)
node .claude/scripts/add-furigana-to-jmdict.mjs
```

### 3. Build kanjidic2.sqlite

Download these files into the project root from [jmdict-simplified releases](https://github.com/scriptin/jmdict-simplified/releases):
- `kanjidic2-en-*.json` (~15 MB)
- `kradfile-*.json` (~500 KB)

```bash
node .claude/scripts/get-kanji-info.mjs 日
```

### 4. Copy databases and data to the iOS app

```bash
cp jmdict.sqlite Pug/Pug/Resources/jmdict.sqlite
cp kanjidic2.sqlite Pug/Pug/Resources/kanjidic2.sqlite
cp wanikani/wanikani-kanji-graph.json Pug/Pug/Resources/
cp wanikani/wanikani-extra-radicals.json Pug/Pug/Resources/
```

Both `.sqlite` files must use DELETE journal mode (the build scripts set this
automatically). The source JSON files are gitignored and can be deleted after
building.

### Data sources

The LLM component of this app is heavily constrained by real, verifiable data sources
authored by experts. Claude generates quiz questions and grades answers, but it does
so within the bounds of these databases — not from its own training data.

| Source | What it provides | Origin |
|---|---|---|
| [JMDict](http://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project) | ~200k Japanese–English dictionary entries | Jim Breen's EDRDG project; we use [jmdict-simplified](https://github.com/scriptin/jmdict-simplified) JSON |
| [JmdictFurigana](https://github.com/Doublevil/JmdictFurigana) | Character-level ruby spans for JMDict words | Doublevil's project; handles irregular readings like 日本→にほん |
| [KANJIDIC2](http://www.edrdg.org/wiki/index.php/KANJIDIC_Project) | Per-kanji readings, meanings, stroke counts, JLPT/grade levels | EDRDG; we use jmdict-simplified's JSON export |
| [kradfile](http://www.edrdg.org/krad/kradinf.html) | Kanji → radical decomposition | EDRDG; used for kanji breakdowns in quiz chat |
| [WaniKani](https://www.wanikani.com/) | Kanji → component mappings with mnemonic-friendly names | Community-extracted data in `wanikani/` |
| [Genki](https://genki3.japantimes.co.jp/en/) | ~123 grammar topics | Scraped from [St. Olaf's Genki index](https://wp.stolaf.edu/japanese/grammar-index/) via `grammar/stolaf-genki-website.js` |
| [Bunpro](https://bunpro.jp/) | ~943 grammar topics with JLPT levels | Scraped from bunpro.jp via `grammar/bunpro-website.js` |
| [DBJG](https://www.amazon.com/dp/4789004546) (*A Dictionary of Basic Japanese Grammar*) | ~370 grammar topics | Manually typed from the book's index |
| [sljfaq.org](https://www.sljfaq.org/afaq/jitadoushi.html) | 154 linguist-curated transitive/intransitive verb pairs | Merged into `all-transitive-pairs.json` candidate pool |
| [Anki shared deck](https://ankiweb.net/shared/info/92409330) | Additional transitive/intransitive pairs | Merged into `all-transitive-pairs.json` candidate pool; Opus downselected to ~56 core pairs in `transitive-pairs.json` |

---

## Quiz formats

The app has two quiz domains: **vocabulary** and **grammar**. (Both use
[Ebisu](https://github.com/fasiha/ebisu) spaced repetition to predict recall, but Ebisu
can easily be replaced by any other probabilistic system.)

### Vocabulary quizzes

Four facets, each testing a different direction of recall:

| Facet | Prompt shows | Student produces |
|---|---|---|
| reading-to-meaning | kana reading | English meaning |
| meaning-to-reading | English meaning | kana reading |
| kanji-to-reading | word with kanji shown | kana reading |
| meaning-reading-to-kanji | English + kana | kanji written form |

The last two facets only appear for words where the user has committed to learning
specific kanji characters. Users choose a furigana form (e.g. 入り込む vs 這入り込む)
and optionally which kanji to learn — partial commitment is supported (e.g. learning
only 前 in 前例 means the quiz shows 前れい).

**Question format progression:** All facets start as multiple choice (4 options, app-
scored instantly). After 3+ reviews and halflife of 48+ hours, the facet graduates to
free-answer (student types, and if they just typed the answer, the app grades locally, but
if they typed more than just the answer, Claude grades, with a Bayesian confidence score
0.0–1.0). Exception: meaning-reading-to-kanji is always multiple choice.

**Conversational grading:** After each answer, the conversation continues freely. Claude
has access to JMDict lookups, KANJIDIC2 and Wanikani kanji breakdowns, the student's full
enrolled word list, and mnemonic notes. You can ask tangent questions about any word
before moving to the next item.

### Grammar quizzes

Two facets, drawn from three curated sources:

| Facet | Prompt shows | Student produces |
|---|---|---|
| production | English context sentence | Japanese using target grammar |
| recognition | Japanese sentence | English meaning |

**Data sources:** Genki (~123 topics), Bunpro (~943 topics), DBJG (~370 topics). Topics
covering the same grammar point across sources are clustered into equivalence groups (see
[grammar-equivalences.json](grammar/grammar-equivalences.json) and
[cluster-grammar-topics.md](.claude/commands/cluster-grammar-topics.md)). Reviewing one
topic in a group propagates the score to all siblings.

Currently all grammar quizzes are multiple choice. Each question targets a different
sub-use of the grammar point to ensure diversity across reviews.

### Transitive-intransitive pair drills

A dedicated quiz format for drilling verb pairs like 壊す/壊れる and 開ける/開く. The
student sees both directions on one card — agency cues like "I ___ it" and "it ___ed"
— and must produce both the transitive and intransitive forms.

The ~56 core pairs in [transitive-pairs.json](transitive-intransitive/transitive-pairs.json)
were hand-selected by Opus from a larger pool of ~230 candidates (kept in
[all-transitive-pairs.json](transitive-intransitive/all-transitive-pairs.json)) for
being common, pedagogically useful, and unambiguously transitive/intransitive in
practice. The candidate pool itself was assembled from
[sljfaq.org](https://www.sljfaq.org/afaq/jitadoushi.html) and an
[Anki shared deck](https://ankiweb.net/shared/info/92409330), then filtered and enriched
with JMDict IDs and drill sentences. The larger archive remains available for adding
pairs that feel important in context.

---

## Content authoring

Start writing a Markdown file in this directory. (I keep it in Obsidian and author
content there, but you don't need to.)

### Writing a reading passage

Add `llm-review: true` frontmatter so the publishing scripts pick up the file. Then
annotate your content with `<details><summary>___</summary></details>` tags. The
publishing process recognizes two summary labels:

- **Vocab** — a bulleted list of vocabulary words, matched against JMDict
- **Grammar** — a bulleted list of grammar topic IDs from the databases in `grammar/`

Other `<summary>` sections (like Translation) are ignored by the tooling.

```markdown
---
llm-review: true
---

すしが作れます
<details><summary>Translation</summary>can make sushi</details>
<details><summary>Vocab</summary>
- すし
</details>
<details><summary>Grammar</summary>- genki:potential-verbs</details>

体中をぶあついオーバーとえりまきでつつんだ男が、旅館にやってきました。
<details><summary>Vocab</summary>
- 体中
- ぶあつい
- えりまき
- つつむ
- 気味 きみ
- やってくる
</details>
<details><summary>Translation</summary>
He was shrouded head-to-toe in a heavy overcoat and scarf…
</details>
```

**Vocab bullet format** — each bullet is a vocab entry. Write all Japanese forms first
(before any English), space-separated:

| Example | Meaning |
|---|---|
| `- 体中` | kanji only |
| `- ぶあつい` | kana only |
| `- 舞う まう` | kanji then kana — both must match one JMDict entry |
| `- ありったけ as many as possible` | kana then English notes (non-Japanese is ignored) |
| `- 強盗 ごうとう robber` | add kana to disambiguate when multiple entries match |

English text after the first Latin-alphabet token is for your reference only — scripts
ignore it.

**Grammar bullet format** — each bullet is a source-prefixed topic ID (e.g.
`genki:potential-verbs`, `bunpro:られる-Potential`, `dbjg:rareru2`, from the TSV files in [`grammar/`](./grammar/)).

### Validating content

```bash
# Fast — run the Node script directly (outputs JSON report of problems)
node .claude/scripts/check-vocab.mjs

# With LLM assistance — Claude reports problems with line links and suggested fixes
/check-vocab
```

The script checks every vocab bullet against JMDict and reports unrecognised forms
(0 matches) and ambiguous forms (2+ matches). For most issues, the fix is obvious
from the output. Use the `/check-vocab` Claude skill when you want help resolving
ambiguities.

For **grammar topic IDs**, run:

```bash
node .claude/scripts/check-grammar.mjs
```

This validates every grammar bullet in your Markdown files against the three databases
(Genki, Bunpro, DBJG) and reports unknown or misspelled topic IDs, analogous to
`check-vocab.mjs` for vocabulary. To browse available topic IDs, look at the TSV files in
`grammar/`.

After adding new grammar topic IDs to your Markdown files, run
```bash
node prepare-publish.mjs
```
to compile them into `grammar.json`.

The above script may ask you to run the `/cluster-grammar-topics` skill in Claude code:
this assigns gramar topics to equivalence groups and generate quiz descriptions.

---

## Publishing pipeline

Content goes from Obsidian Markdown to the iOS app in two steps:

```bash
# 1. Validate + compile vocab.json and grammar.json
node prepare-publish.mjs

# 2. Push to GitHub secret Gist
GIST_ID=<your-gist-id> node publish.mjs
# or: node publish.mjs <gist-id>
```

`prepare-publish.mjs` does:
1. Finds all Markdown files with `llm-review: true` frontmatter
2. Runs check-vocab validation (blocks on failures)
3. Extracts vocab data, enriches with JmdictFurigana written forms → writes `vocab.json`
4. Extracts grammar bullets → writes `grammar.json`

`publish.mjs` pushes the output files to a GitHub secret Gist via git over SSH. The
app fetches from the Gist's raw URL on startup.

**One-time Gist setup:** Create a secret Gist at gist.github.com, note the Gist ID.
Ensure github.com is in `~/.ssh/known_hosts`.

---

## App distribution

Distributed to family via TestFlight (external beta). Each build expires after 90
days — bump the build number and upload a new one periodically.

**Setup deep link:** `japanquiz://setup?key=sk-ant-...&vocabUrl=https://...`

Generate it with:

```bash
node make-setup-link.mjs           # reads .env, prints URL
node make-setup-link.mjs | xargs xcrun simctl openurl booted  # test in simulator
```

Distributed via iMessage or AirDrop. Set a monthly usage cap in the Anthropic console
to mitigate key exposure.

---

## Architecture overview

```
┌──────────────────────────────────────────────┐
│  SwiftUI app (iOS)                           │
│                                              │
│  ┌─────────────┐   ┌──────────────┐          │
│  │ quiz.sqlite │   │ jmdict.sqlite│          │
│  │ (GRDB.swift)│   │  (bundled)   │          │
│  └──────┬──────┘   └──────┬───────┘          │
│         │                 │                  │
│         └────────┬────────┘                  │
│                  │                           │
│           ┌──────▼───────┐                   │
│           │ Claude API   │                   │
│           │ (URLSession) │                   │
│           │ + tool use   │                   │
│           └──────────────┘                   │
└──────────────────────────────────────────────┘
         ▲                            ▲
         │ periodic sync              │ one-time setup
         │ (vocab.json,               │
         │  grammar.json)             │
  ┌──────┴──────┐             ┌───────┴────────┐
  │ hosted URL  │             │  setup link    │
  │ (Gist/S3)   │             │ japanquiz://.. │
  └─────────────┘             └────────────────┘
         ▲
  ┌──────┴──────┐
  │ publish.mjs │  (run locally)
  └─────────────┘
         ▲
  ┌──────┴──────────────────┐
  │ Obsidian Markdown files │
  │ + prepare-publish.mjs   │
  └─────────────────────────┘
```

---

## Script catalog

### Database building

| Script | Purpose |
|---|---|
| `.claude/scripts/check-vocab.mjs` | Builds `jmdict.sqlite` (side effect of validation run) |
| `.claude/scripts/add-furigana-to-jmdict.mjs` | Adds JmdictFurigana data to `jmdict.sqlite` |
| `.claude/scripts/get-kanji-info.mjs` | Builds/updates `kanjidic2.sqlite` from KANJIDIC2 + kradfile JSON |
| `grammar/generate-all-topics.mjs` | Reads three grammar TSV files → writes `grammar/all-topics.json` |

### Content validation

| Script | Purpose |
|---|---|
| `.claude/scripts/check-vocab.mjs` | Validates vocab bullets against JMDict, outputs JSON report |
| `.claude/scripts/check-grammar.mjs` | Validates grammar bullets against Genki/Bunpro/DBJG databases |
| `wanikani/wanikani-extra-radicals-validation.mjs` | Checks consistency between WaniKani data and kanjidic2 |

### Publishing

| Script | Purpose |
|---|---|
| `prepare-publish.mjs` | Validates content, compiles `vocab.json` and `grammar.json` |
| `publish.mjs` | Pushes compiled JSON to GitHub secret Gist via SSH |
| `make-setup-link.mjs` | Reads `.env`, prints the `japanquiz://setup?...` deep link |

### Grammar data curation

| Script | Purpose |
|---|---|
| `.claude/scripts/add-grammar-equivalence.mjs` | Merges/splits equivalence groups in `grammar-equivalences.json` |
| `.claude/scripts/enrich-grammar-descriptions.mjs` | Data helper for grammar description enrichment |
| `.claude/scripts/find-new-grammar-topics.mjs` | Reports grammar topics not yet in equivalence groups |
| `grammar/slugify-dbjg.mjs` | Converts `grammar-dbjg.md` into TSV format |
| `grammar/bunpro-website.js` | Browser scraper: Bunpro grammar points → TSV |
| `grammar/stolaf-genki-website.js` | Browser scraper: St. Olaf Genki grammar → TSV |

### Transitive-intransitive pairs

| Script | Purpose |
|---|---|
| `.claude/scripts/generate-pair-drills.mjs` | Generates drill sentences for verb pairs via Claude API |

### Quiz CLI (legacy, still functional)

| Script | Purpose |
|---|---|
| `.claude/scripts/init-quiz-db.mjs` | Creates/migrates `quiz.sqlite` schema |
| `.claude/scripts/get-quiz-context.mjs` | Ranks quizzable items by Ebisu recall urgency |
| `.claude/scripts/write-quiz-session.mjs` | Creates a quiz session queue from context |
| `.claude/scripts/read-quiz-session.mjs` | Reads current session file |
| `.claude/scripts/clear-quiz-session.mjs` | Deletes session file after quiz ends |
| `.claude/scripts/record-review.mjs` | Records a review and updates Ebisu model |
| `.claude/scripts/introduce-word.mjs` | Initializes Ebisu models for a new word |
| `.claude/scripts/rescale-halflife.mjs` | Adjusts halflife without recording a review |
| `.claude/scripts/get-word-history.mjs` | Full review history + Ebisu models for one word |

### Utilities

| Script | Purpose |
|---|---|
| `.claude/scripts/shared.mjs` | Shared constants, DB helpers, parsing utilities |
| `.claude/scripts/telemetry-report.mjs` | Prints API usage report from `api_events` table |
| `lookup.mjs` | Interactive JMDict lookup by word or ID |

---

## Claude skills

| Skill | Description |
|---|---|
| `/check-vocab` | Validate all vocab bullets against JMDict |
| `/annotate-vocab` | Annotate a Japanese sentence with vocabulary for N4-level learners |
| `/cluster-grammar-topics` | Find new grammar topics and cluster into equivalence groups |
| `/quiz` | CLI spaced-repetition quiz (legacy — iOS app is the primary interface) |

---

## Curated data files

These files took significant effort to build and may be useful for other Japanese
learning projects:

| File | Description |
|---|---|
| [grammar-equivalences.json](grammar/grammar-equivalences.json) | ~300 equivalence groups clustering grammar topics across Genki, Bunpro, and DBJG. Each group has a `summary`, `subUses`, and `cautions` list. |
| [grammar-bunpro.tsv](grammar/grammar-bunpro.tsv) | ~943 Bunpro grammar topics (ID, title, JLPT level, meaning). Scraped from [bunpro.jp](https://bunpro.jp/grammar_points) — re-run with `grammar/bunpro-website.js` in the browser console to update. |
| [grammar-stolaf-genki.tsv](grammar/grammar-stolaf-genki.tsv) | ~123 Genki grammar topics. Scraped from [St. Olaf's Genki grammar index](https://wp.stolaf.edu/japanese/grammar-index/) — re-run with `grammar/stolaf-genki-website.js` in the browser console to update. |
| [grammar-dbjg.tsv](grammar/grammar-dbjg.tsv) | ~370 DBJG grammar topics. Manually typed from the book's index (*A Dictionary of Basic Japanese Grammar*, Makino & Tsutsui). |
| [transitive-pairs.json](transitive-intransitive/transitive-pairs.json) | ~56 core transitive/intransitive verb pairs selected for frequency and pedagogical value, with JMDict IDs and drill sentences |
| [all-transitive-pairs.json](transitive-intransitive/all-transitive-pairs.json) | ~230 candidate pairs (superset of the above) assembled from sljfaq.org and an Anki deck, retained as an archive |
| [wanikani-kanji-graph.json](wanikani/wanikani-kanji-graph.json) | Kanji → WaniKani component character mappings |
| [wanikani-extra-radicals.json](wanikani/wanikani-extra-radicals.json) | Informal descriptions for WaniKani components not in KANJIDIC2 |

---

## See also

- [CLAUDE.md](CLAUDE.md) — detailed architecture notes for Claude (iOS quiz facets, grammar tiers, tool schemas)
- [TESTING.md](TESTING.md) — TestHarness build instructions and modes
