# llm-review — Japanese vocabulary review with Claude

An Obsidian vault + Claude Code workflow for learning Japanese vocabulary from
textbook reading passages. Stories are kept as Markdown files; Claude checks your
vocab lists against JMDict and runs spaced-repetition quizzes.

---

## User guide

### Authoring a reading

Write your reading passage as plain Markdown. Wrap translations in a
`<details><summary>Translation</summary>…</details>` block and new vocabulary in
a `<details><summary>Vocab</summary>` block:

```markdown
体中をぶあついオーバーとえりまきでつつんだ男が、旅館にやってきました。
<details><summary>Vocab</summary>
- 体中
- ぶあつい
- えりまき
- つつむ つつむ
- 気味 きみ
- やってくる
</details>
<details><summary>Translation</summary>
He was shrouded head-to-toe in a heavy overcoat and scarf…
</details>
```

**Bullet format rules** — each bullet is a vocab entry. Write all its Japanese
forms first (before any English), space-separated:

| Example | Meaning |
|---|---|
| `- 体中` | kanji only |
| `- ぶあつい` | kana only |
| `- 舞う まう` | kanji form then kana reading — both must point to the same JMDict entry |
| `- ありったけ as many as possible` | kana then English gloss (English is ignored by scripts) |
| `- ごうとう robber` | ambiguous — prefer `- 強盗 ごうとう robber` to pin the entry |

The leading Japanese tokens are what the scripts use. English notes after the
first Latin-alphabet token are preserved for your own reference and ignored by
the tooling.

---

### `/check-vocab` — validate your vocab lists

```
/check-vocab
```

Runs `.claude/scripts/check-vocab.mjs` against every Markdown file in the vault
(excluding `node_modules` and `.claude`). Each bullet's leading Japanese tokens
are looked up with `findExact` in JMDict and the results are intersected. A bullet
is **valid** only when all tokens narrow down to exactly one JMDict entry.

Claude reports any bullet that has **0 matches** (unrecognised form) or **2+
matches** (ambiguous), links to the exact line in the file, and suggests a fix.

Common problems and fixes:

| Problem | Cause | Fix |
|---|---|---|
| 0 matches — `入りこも` | Conjugated form, not in JMDict | Use dictionary form: `入り込む` |
| 0 matches — `事じょう` | Mixed kanji+kana mid-word | Use full kanji `事情` or full kana `じじょう` |
| 2+ matches — `気味` | Multiple JMDict entries share that form | Add reading to disambiguate: `気味 きみ` |
| 2+ matches — `市場` | Different readings, different meanings | `市場 いちば` (market) or `市場 しじょう` (financial market) |

Claude will **not** edit your Markdown files — it only suggests corrections.

---

### `/quiz` — spaced-repetition quiz

```
/quiz
```

Claude runs a session-based, one-question-at-a-time quiz:

1. **`get-quiz-context.mjs`** — scans all opted-in Markdown files and outputs one
   compact line per quizzable vocab entry, merged with its all-time review history:
   ```
   1398530  体中, からだじゅう all over the body (#1398530) [never reviewed]
   1584060  包む, つつむ to wrap; to pack (#1584060) [5d ago, avg 0.80, 2 reviews]
   ```
   Only entries with exactly one JMDict match are included (broken bullets are
   skipped automatically).

2. Claude picks 5–10 words, prioritising never-reviewed words, then words with
   long gaps or low average scores, and writes a **session file** via
   `write-quiz-session.mjs`.

3. Claude asks **one question per message** (kanji → reading, kanji+reading →
   meaning, or meaning → kanji/kana multiple-choice). It waits for your answer,
   grades it (0.0–1.0), records the result via `record-review.mjs`, and asks the
   next question.

4. After the last question, the session file is cleared and Claude gives a brief
   summary of the session.

If the quiz is interrupted mid-session, Claude can resume from where it left off
by reading the session file on the next `/quiz` invocation.

The `--reviewer` flag on `record-review.mjs` defaults to your OS username. Passing
it explicitly is not yet wired up to the `/quiz` skill — see Future work below.

---

## Setup

```bash
# 1. Install dependencies
npm install

# 2. Download a JMDict-Simplified JSON release and place it here, then:
#    (skip if jmdict.sqlite already exists)
node -e "import('jmdict-simplified-node').then(m => m.setup('jmdict.sqlite', 'jmdict-eng-3.6.2.json'))"

# 3. Create the quiz database (safe to re-run)
node .claude/scripts/init-quiz-db.mjs
```

---

## Project layout

```
llm-review/
├── *.md                        reading passages (Obsidian notes)
├── jmdict.sqlite               JMDict search database
├── quiz.sqlite                 quiz review history
├── package.json
├── remove-vocab.js             utility: strips Vocab blocks for clean reading
└── .claude/
    ├── commands/
    │   ├── check-vocab.md      /check-vocab skill prompt
    │   └── quiz.md             /quiz skill prompt
    └── scripts/
        ├── shared.mjs          shared constants, DB helpers, parsing utilities
        ├── check-vocab.mjs     checks vocab against JMDict, outputs JSON report
        ├── get-quiz-context.mjs  compact vocab+history output for quiz selection
        ├── write-quiz-session.mjs  writes a quiz session plan file
        ├── read-quiz-session.mjs   reads session file, exits 1 if none
        ├── clear-quiz-session.mjs  deletes session file after quiz ends
        ├── init-quiz-db.mjs    creates quiz.sqlite schema (run once)
        └── record-review.mjs   inserts one review row into quiz.sqlite
```

---

## Implementation notes

### Vocab parsing

All scripts use the same approach to extract vocab bullets:

1. Scan the file content with a regex for `<details>` blocks whose inner content
   contains `<summary>Vocab</summary>`.
2. Split the inner block by newline and collect lines that start with `-`.
3. From each bullet, take the leading space-separated tokens that contain at
   least one Japanese character (hiragana U+3040–309F, katakana U+30A0–30FF,
   or kanji U+4E00–9FFF / U+3400–4DBF / U+F900–FAFF). Stop at the first
   purely Latin token.

Line numbers (used by `check-vocab.mjs`) are derived by counting newlines before
the start of each `<details>` block's inner content, then adding the line offset
within that block.

### JMDict lookup

`findExact(db, text)` (from `jmdict-simplified-node`) returns every JMDict `Word`
where any kanji form *or* any kana form exactly equals `text`. For a bullet with
multiple Japanese tokens (e.g. `舞う まう`), the script calls `findExact` on each
token separately and intersects the result ID sets. The bullet is valid iff the
intersection contains exactly one entry.

### Quiz database schema

```sql
CREATE TABLE reviews (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  reviewer    TEXT    NOT NULL,
  timestamp   TEXT    NOT NULL,   -- ISO 8601 UTC
  word_type   TEXT    NOT NULL,   -- 'jmdict'; 'grammar' planned
  word_id     TEXT    NOT NULL,   -- JMDict entry ID
  word_text   TEXT    NOT NULL,   -- display text from the bullet
  score       REAL    NOT NULL,   -- 0.0 (wrong) to 1.0 (perfect)
  notes       TEXT                -- Claude's notes on the review attempt
);
```

### Design principle

Claude never writes directly to Markdown files or to SQLite. It only:
- **Reads** script output (JSON on stdout)
- **Writes** by calling scripts with explicit arguments

This keeps the data pipeline auditable and prevents hallucinated writes.

---

## Future work

- Grammar points (Bunpro / Genki / DBJG) as a second `word_type`
- `--reviewer` flag in the `/quiz` skill via `$ARGUMENTS`
- Obsidian plugin to render `<details type="translation">` on hover
- "Find all sentences that use this kanji" — cross-reference index
