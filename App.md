# iOS App — Architecture & Decisions

A SwiftUI iOS app for family distribution via TestFlight. Inspired by the
[home-cooked app](https://www.robinsloan.com/notes/home-cooked-app/) philosophy — small,
personal, doesn't need to scale.

**This is not just a port of the Claude Code skill — and it is not just another flashcard app.**

The two things this app is trying to be:

### 1. Shared corpus, individual learning paths

- The Claude Code skill's vocab is *author-curated* — words the author personally doesn't
  know. It works for one reader but is too sparse for a family audience.
- The app's corpus is *comprehensively annotated* — every word a beginner–intermediate
  reader might not know, added by the `/enrich-vocab` skill (see `TODO.md`). Users are
  then readers who independently decide what to do with each word.
- **Per-user enrollment**: each word has independent **reading** and **kanji** facet
  states (unknown / learning / known). Users commit to a specific furigana form and
  optionally select which kanji characters to learn. Only `learning` facets appear in
  quizzes.

### 2. Conversational learning with a frontier model

The `/quiz` Claude Code skill had a quality that a normal flashcard app can't replicate:
you could stop mid-question and ask "wait, how does this kanji relate to 怒る?" or "give
me a mnemonic for this reading" or wander off into a question about a completely different
word — and Claude would engage fully, then circle back and re-ask the original question.
That *feel* of talking to someone who knows a lot and is genuinely trying to help you
understand, not just drill you, is what this app is trying to preserve on iOS.

The quiz conversation is therefore **open-ended by design**:
- Each quiz item is a running chat, not a forced submit-then-grade two-step.
- The student can answer, ask about the current word, or ask about any word in their
  corpus — at any point before or after grading.
- Claude grades organically when it detects a clear answer (`SCORE: X.X`), then keeps
  chatting if the student has more questions.
- Claude has access to `get_vocab_context` — the student's full enrolled word list with
  recall probabilities — so when a tangent question is about another enrolled word, Claude
  can situate the answer in what that person is actually learning and will see again.
- Each quiz item starts with a clean context (no cross-item memory), but within an item
  the conversation is unconstrained.

This makes the app a *shared corpus, individual learning paths* system whose quiz
experience aims to feel like a knowledgeable tutor rather than a flashcard deck.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────┐
│  SwiftUI app (iOS)                                  │
│                                                     │
│  ┌─────────────┐   ┌──────────────┐   ┌─────────┐  │
│  │ quiz.sqlite │   │ jmdict.sqlite│   │ Markdown│  │
│  │ (GRDB.swift)│   │  (bundled)   │   │ (synced)│  │
│  └──────┬──────┘   └──────┬───────┘   └────┬────┘  │
│         │                 │                │        │
│         └─────────────────┴────────────────┘        │
│                           │                         │
│                    ┌──────▼───────┐                 │
│                    │ Claude API   │                 │
│                    │ (URLSession) │                 │
│                    │ + tool use   │                 │
│                    └──────────────┘                 │
└─────────────────────────────────────────────────────┘
         ▲                               ▲
         │ periodic sync                 │ one-time setup
         │                               │
  ┌──────┴──────┐                ┌───────┴────────┐
  │ hosted URL  │                │  setup link    │
  │ (Gist/S3)   │                │ japanquiz://.. │
  └─────────────┘                └────────────────┘
         ▲
  ┌──────┴──────┐
  │ publish.mjs │  (run locally from Obsidian)
  │ check-vocab │
  └─────────────┘
```

---

## Decisions made

### Platform
- **SwiftUI** — native iOS feel for family audience
- **TestFlight external beta** — invite a few specific Apple IDs; each build expires after 90 days so upload a new build (bump build number only) every ~3 months to keep it alive
- **Storage**: GRDB.swift (not SwiftData/Core Data) — existing schema, precise SQL needed for Ebisu queries
- **Testing**: Swift Testing for unit tests + XCTest for UI tests (standard hybrid; Swift Testing can't do UI tests yet). Write unit tests for Ebisu math port and quiz context logic; skip UI tests for MVP.

### Data
- **JMdict**: bundle `jmdict.sqlite` directly in the app (already built by existing Node.js tooling). Large but fine for TestFlight. Update manually when scriptin releases a new version.
  - Before bundling, ensure DELETE journal mode: `sqlite3 jmdict.sqlite "PRAGMA journal_mode=DELETE;"`. Stored in `Resources/`; opened directly from the bundle by `ToolHandler` (no Documents copy needed).
- **Quiz DB**: `quiz.sqlite` created on first launch, local to each device. GRDB.swift for access. Extends the Node.js schema with a `vocab_enrollment` table (see below).
- **Vocab content**: `vocab.json` synced from a hosted GitHub Gist URL. App fetches on startup; cached to `Documents/vocab.json`. See Publishing pipeline below.

#### Word commitment & facet state (app-only tables in quiz.sqlite)

The user's learning state for each word is tracked across two tables, with facet state
**derived** from presence in `ebisu_models` (learning) or `learned` (known) — no
redundant status columns.

```sql
-- User's commitment to study a specific furigana form of a word.
CREATE TABLE word_commitment (
  word_type   TEXT NOT NULL,        -- 'jmdict'
  word_id     TEXT NOT NULL,        -- JMDict entry ID
  furigana    TEXT NOT NULL,        -- JmdictFurigana JSON array for the chosen form
  kanji_chars TEXT,                 -- JSON array of kanji chars to learn, e.g. ["入","込"]
  PRIMARY KEY (word_type, word_id)
);

-- Per-facet "I already know this" with ebisu backup for restoration.
CREATE TABLE learned (
  word_type    TEXT NOT NULL,
  word_id      TEXT NOT NULL,
  quiz_type    TEXT NOT NULL,       -- e.g. "reading-to-meaning"
  learned_at   TEXT NOT NULL,       -- ISO 8601 UTC
  ebisu_backup TEXT,                -- JSON snapshot of EbisuRecord at time of marking known
  PRIMARY KEY (word_type, word_id, quiz_type)
);
```

**Facet state derivation** (not stored — computed from the two tables above):
- **unknown** — not in `ebisu_models` or `learned`
- **learning** — has `ebisu_models` row (actively quizzed via Ebisu)
- **known** — has `learned` row (ebisu model archived as JSON backup; restorable)

Each word has independent **reading** state (from `reading-to-meaning` + `meaning-to-reading`
facets) and **kanji** state (from `kanji-to-reading` + `meaning-reading-to-kanji` facets).
Constraint: kanji state ≤ reading state (no Heisig-style kanji-without-reading).

**`word_commitment`**: created when the user first interacts with a word. The `furigana`
field stores the JmdictFurigana JSON for the chosen written form (e.g. 入り込む vs 這入り込む).
The `kanji_chars` field records which specific kanji the user is learning to write.

**Kana-only words** (`VocabItem.isKanaOnly`): when every furigana segment across all written
forms lacks an `rt` field, the word has only orthographic kana variants (e.g. そっと / そうっと
/ そおっと / そーっと). The furigana picker is skipped — the reading state control is shown
immediately, and commitment is created automatically (with `furigana="[]"`) on first interaction.
`WordDetailSheet` shows a "SPELLINGS" section with all variants (when >1), and renders the
heading as plain text (no ruby layout). Mixed words — where some readings have kanji forms and
others are kana-only — are treated as kanji words and show the full picker.

**Vocab browser filters** use OR semantics: a word appears in "Learning" if ANY facet is
learning, in "Known" if ANY facet is known, and in "Not yet learning" if ANY facet is unknown.

**Migration history**: v3 added `kanji_ok`; v5 replaced `vocab_enrollment` with
`word_commitment` + `learned` (migrating existing data, using `'[]'` placeholder for furigana
until the next vocab sync provides `writtenForms` data).

#### `mnemonics` table (v4 migration)

Free-form mnemonic notes for vocab words or individual kanji characters. Keyed by
`(word_type, word_id)` — intentionally excludes `quiz_type` because one mnemonic typically
covers all facets.

```sql
CREATE TABLE mnemonics (
  word_type  TEXT NOT NULL,   -- 'jmdict' or 'kanji'
  word_id    TEXT NOT NULL,   -- JMDict entry ID or kanji character
  mnemonic   TEXT NOT NULL,
  updated_at TEXT NOT NULL,   -- ISO 8601 UTC
  PRIMARY KEY (word_type, word_id)
);
```

- `word_type='jmdict'` — mnemonic for a vocabulary word (same ID as `vocab_enrollment`)
- `word_type='kanji'` — mnemonic for a single kanji character (the character itself is the `word_id`)
- Kanji mnemonics don't require enrollment or Ebisu models — they're pure reference data

**Claude integration:**
- `get_mnemonic` / `set_mnemonic` tools available in both quiz chat and word explore sessions
- During quiz: mnemonic is **not** shown during question generation (avoid priming); injected
  into the system prompt **after the user's first reply** so Claude can reference it in feedback
- During word exploration: mnemonics shown from the start; Claude can save new ones
- `WordDetailSheet` displays existing vocab + relevant kanji mnemonics in the info section

#### Kanji knowledge (future, separate table)

"I know this kanji" is a *cross-word* assertion — knowing 怒 from 怒る should affect
furigana display and quiz behavior in 怒鳴る, 怒号, etc. This is orthogonal to word
enrollment and belongs in its own table:

```sql
-- NOT YET BUILT — noted here to avoid painting the schema into a corner
CREATE TABLE kanji_knowledge (
  kanji        TEXT NOT NULL,   -- ruby span: 1 char (e.g. '木') or multi-char for jukujikun (e.g. '今日')
  reading      TEXT NOT NULL,   -- kana reading e.g. 'き', 'もく', 'きょう'
  reading_type TEXT,            -- 'kunyomi' | 'onyomi' (informational, nullable)
  status       TEXT NOT NULL    -- 'known' | 'learning'
    CHECK(status IN ('known', 'learning')),
  updated_at   TEXT NOT NULL,
  PRIMARY KEY (kanji, reading)
);
```

`kanji` is the ruby *span* — usually one character, but multi-character for irregular/
jukujikun readings (e.g. `今日→きょう`, `日本→にほん`). Status is per **(span, reading)**,
not per kanji. `reading_type` is optional metadata; it doesn't affect the logic.

Furigana suppression: suppress a `<rt>` tag when its `(span, reading)` pair has `status =
'known'` in this table. This works uniformly for regular and irregular readings.

#### JmdictFurigana — source of ruby spans

The [JmdictFurigana](https://github.com/Doublevil/JmdictFurigana) project publishes a JSON
file mapping JMdict words to character-level ruby spans, with irregular readings handled
correctly. Example: 日本気象協会 →

```html
<ruby>日本<rt>にほん</rt></ruby><ruby>気<rt>き</rt></ruby><ruby>象<rt>しょう</rt></ruby><ruby>協<rt>きょう</rt></ruby><ruby>会<rt>かい</rt></ruby>
```

日本 is treated as one atomic span (irregular compound), not split as 日→に, 本→ほん.

**Integration point: publish/check-vocab step (Node.js), not the app.** Vocab entries get
pre-annotated ruby markup at publish time; the app renders it and checks spans against
`kanji_knowledge`. This means:
- The hard problem of kanji boundary detection is solved once, offline, not on-device
- The app's furigana suppression is a simple span-matching lookup
- `(kanji, reading)` rows in `kanji_knowledge` come directly from JmdictFurigana spans

### Claude integration

**Principle: give the LLM only what it needs, on demand.** The system prompt for each
quiz item is minimal (word, facet rule, quiz purity rule). Broader context — the enrolled
word list, dictionary entries — is available as tools that Claude calls when it actually
needs them. This keeps the default token cost low while letting Claude reach for more when
the conversation warrants it.

- **Direct API calls** from the app — no edge worker proxy. Simpler; no server to maintain.
- **API key**: stored in iOS Keychain. Distributed to family via setup deep link (see below).
- **Model**: defaults to `claude-haiku-4-5-20251001` for dev (fast, cheap). Override via `ANTHROPIC_MODEL` env var in the Xcode scheme, or the Settings screen. Switch to `claude-sonnet-4-6` for production TestFlight builds. Add a model picker to the Settings screen so it's runtime-configurable without a rebuild.
- **Tools available during a quiz item** (`Claude/ToolHandler.swift`):
  - `lookup_jmdict` — query local `jmdict.sqlite` for dictionary-accurate readings and
    meanings. Claude calls this during question generation or when the student asks about
    a word's readings/meanings.
  - `lookup_kanjidic` — query local `kanjidic2.sqlite` augmented with WaniKani component
    data for per-kanji breakdown: stroke count, JLPT level, school grade, on/kun readings,
    English meanings, kradfile radical labels, and a `wanikani_components` array (each entry
    has `char` + either `meaning` from KANJIDIC2 or `description` from WaniKani's informal
    component glossary). Input is any string — non-kanji characters are skipped. Claude calls
    this when the student asks about a kanji's composition, readings, or mnemonics.
  - `get_vocab_context` — returns the student's full enrolled word list with recall
    probabilities (same format as the pre-selection context lines). Claude calls this when
    the student's message is about a different word they're studying, or when knowing
    their broader learning context would help — e.g. "yes, that kanji also appears in
    怒鳴る, which you'll see soon at recall 0.18."
  - `get_mnemonic` — retrieve a saved mnemonic note for a vocab word (`word_type="jmdict"`)
    or single kanji character (`word_type="kanji"`). Available during quiz chat and word
    exploration.
  - `set_mnemonic` — save or update a mnemonic note. Claude calls this when the student
    crafts or accepts a mnemonic during conversation. Available during quiz chat and word
    exploration.
- **Ebisu state for the current quiz item**: Claude should be able to answer "how well do I
  know this word?" or "is this word well-established?" without an extra tool call. Three
  options were considered:
  1. *Add halflife to every context line* — doubles numeric density in the 50-item vocab list
     that Claude already gets via `get_vocab_context`; confuses weaker models with numbers they
     don't need for most questions.
  2. *Standalone on-demand tool `get_flashcard_strength(word_type, word_id, facet)`* — lazy,
     but requires Claude to know to reach for it, adds a round-trip, and the question is common
     enough that it shouldn't need a tool call.
  3. *Add recall + halflife to the current item's system prompt* — targeted, zero extra tokens in
     the vocab list, always available for the one word that's actually being discussed.
  **Decision: option 3** ✓ — `systemPrompt(for:item)` emits `Current memory state: recall=X.XX, halflife=Xh` for the word currently being quizzed.

- **Quiz conversation model** (`Claude/QuizSession.swift`):
  - Phases: `generating` → `awaitingTap` or `awaitingText` → `chatting` → (next item).
  - **Multiple choice items** (`isFreeAnswer == false`): Claude generates a JSON blob
    `{stem, choices[4], correct_index}` — no markdown formatting, no A/B/C/D in the
    response. App renders four native `Button`s. Student taps → app scores instantly
    (1.0 correct / 0.0 wrong), calls `recordReview()`, starts prefetch, fires
    `doOpeningChatTurn` to Claude (telling it the result). Claude discusses without
    needing to emit `SCORE`.
  - **Free-answer items** (`isFreeAnswer == true`): App builds the question stem locally
    from `item.meanings` / `item.kanaTexts` etc. — **no LLM call during generation**.
    Student types a free-text answer and submits. App fires `doOpeningChatTurn` with
    `shouldParseScore: true`; Claude grades, emits `SCORE: X.X`, and discusses.
  - **Score semantics** — `SCORE` is a Bayesian confidence value fed directly into
    Ebisu's noisy-Bernoulli `updateRecall(model, score, 1, elapsed)`. It is **not**
    percentage-correct; it means: *"how confident am I that this observation reflects
    whether the student actually remembers the word?"*
    - `1.0` — strong evidence they remember (correct answer)
    - `0.8–0.9` — good evidence they remember (right answer with minor slip: kana typo,
      imprecise but semantically correct paraphrase)
    - `0.5` — no evidence either way; halflife unchanged (also used for passive updates)
    - `0.1–0.3` — good evidence they don't remember (wrong but in the right domain)
    - `0.0` — strong evidence they don't remember (completely wrong)
    - Multiple choice uses only `1.0` / `0.0` (binary, app-scored). Free-answer uses the full range
      (Claude-scored). The grading system prompt explains this semantics to Claude explicitly.
  - `isFreeAnswer` per facet (from `QuizContext.swift`):
    | Facet | Multiple choice | Free-answer |
    |---|---|---|
    | `reading-to-meaning` | reviews < 3 or halflife < 48h | reviews ≥ 3 and halflife ≥ 48h |
    | `meaning-to-reading` | same threshold | same threshold |
    | `kanji-to-reading` | same threshold | same threshold |
    | `meaning-reading-to-kanji` | **always** | never |
  - Thresholds (tunable constants in `QuizContext.swift`):
    - `freeAnswerMinReviews = 3` — must have reviewed the facet at least 3 times
    - `freeAnswerMinHalflife = 48.0` hours — word must be stable ≥ 2 days
    - Gate condition: `reviewCount >= freeAnswerMinReviews && halflife >= freeAnswerMinHalflife`
  - Conversation continues freely after the opening turn. "Next Question →" appears once
    graded; "Skip →" is always available.
  - Each item starts with a clean context (`conversation = []`). No cross-item memory.
- **Two-call question validation** — bypassed for multiple choice (app-side scoring makes leak
  validation moot); still nominally active for free-answer but disabled via
  `QuizSession.skipValidation = true` (was broken for all facet types). The
  `validateQuestion(_:for:)` infrastructure and `api_events` logging are preserved.
  The `---QUIZ---` sentinel and `extractQuestion(from:)` are only used by the free-answer
  path now.
- **`{kanji-ok}` / `{no-kanji}` label clarity** (TODO): these tags currently reflect
  whether the user has added a `[kanji]` marker to the vocab bullet, meaning they've
  committed to learning to read/write that word's kanji. The quiz context line and system
  prompt could make this intent more explicit (e.g. `{committed-to-kanji}` /
  `{reading-only}`) to reduce potential model confusion with the separate `written:` vs
  `reading:` form labels in the context line.

### Setup / distribution
- **Setup deep link**: `japanquiz://setup?key=sk-ant-...&vocabUrl=https://...`
  - Registered custom URL scheme in Info.plist
  - Handled with SwiftUI's `.onOpenURL`
  - Key saved to Keychain, URL saved to UserDefaults
  - Distributed via iMessage or AirDrop to family — never needs to be public
  - Mitigation for key exposure: set a monthly usage cap in Anthropic console

### Publishing pipeline (Obsidian → hosted)

Publish step runs locally (`node prepare-publish.mjs && node publish.mjs <gist-id>`) and produces **two outputs
per story**, served from the same host:

```
stories/
  bunsho-dokkai-3/
    vocab.json      ← structured vocab data (Phase 0+)
    story.html      ← rendered prose for story reader (Phase 2+)
    assets/         ← images referenced in the Markdown (Phase 2+)
```

**`vocab.json`** — extracted from `<details><summary>Vocab</summary>` blocks:
```json
{
  "generatedAt": "2026-03-04T00:00:00Z",
  "stories": [{ "title": "分章読解3" }],
  "words": [{
    "id": "1234567",
    "sources": ["分章読解3"],
    "writtenForms": [{
      "reading": "はいりこむ",
      "forms": [{ "furigana": [{"ruby":"入","rt":"はい"},{"ruby":"り"},{"ruby":"込","rt":"こ"},{"ruby":"む"}], "text": "入り込む" }]
    }]
  }]
}
```
`meanings` and display forms are derived from the bundled `jmdict.sqlite`. The
publish-time data that can't be derived is: which JMDict IDs are in the corpus, which
stories they come from, and the **furigana breakdown** (from JmdictFurigana, with
`appliesToKanji` filtering and lesser-kanji variant collapsing via `isFuriganaParent`).
Used by: vocab browser, enrollment, furigana form picker. Rendered with pure SwiftUI.

**`story.html`** — full Markdown converted to HTML (pandoc or Node.js `marked`):
- Raw HTML tags (`<ruby>`, `<details>`) passed through unchanged
- Vocab words wrapped: `<span data-jmdict-id="1234567">怒鳴る</span>` for tap detection
- Images: all image files are within the `llm-review` directory; `src` attributes
  rewritten to hosted raw URLs
- Rendered in `WKWebView` with injected CSS; tap handler calls back to Swift via
  `WKUserContentController` for enrollment/quiz actions

**Claude context**: for quiz generation, pass the raw Markdown text (not the HTML) as
system prompt context — it's compact and Claude handles it well.

Pipeline steps:
1. Find Markdown files with `llm-review: true` **and** `title:` in frontmatter — block if any `title` is missing ✓
2. Run check-vocab validation (inline in `prepare-publish.mjs`) — block on failures ✓
3. Extract `vocab.json` from `<details>` blocks, enrich with JmdictFurigana `writtenForms` → write to project root ✓ (`prepare-publish.mjs`)
4. Push `vocab.json` to GitHub secret Gist via `git` over SSH ✓ (`publish.mjs`)
5. Convert Markdown → `story.html` with vocab span injection; copy/upload images (Phase 2+)

**Still needed before first run**: add `title:` to the YAML frontmatter of each enrolled Markdown file.

Vocab in the published files is *comprehensive* (all words a learner might not know),
not just the author's personal unknowns — this is the authoring job of the
`/enrich-vocab` skill (see `TODO.md`)

---

## Open questions

### Hosting
**GitHub secret Gist is viable**: Gist supports binary files pushed via git (clone
the Gist repo, commit the PNG, push). The Gist web renderer uses an incorrect URL so
images don't display inline in the browser, but the raw URL works correctly:
```
https://gist.githubusercontent.com/{user}/{gist_id}/raw/{filename}
```
The publish script rewrites `<img src>` to this raw URL pattern. One constraint: Gist is
a flat namespace (no subdirectories), so all files across all stories share the same
directory — use prefixed filenames (`nhk-easy-sakura.jpg`) to avoid collisions.

- **GitHub secret Gist**: free, no account beyond GitHub, opaque URL, binary via git.
  Flat namespace is the only constraint; manageable for a small family corpus.
- **Cloudflare R2**: S3-compatible, free tier (10 GB, no egress fees), per-story
  prefixes, cleaner structure. Better if the corpus grows or you want tidy URLs.
- **Lean**: start with Gist (zero new accounts); migrate to R2 if namespace becomes messy.

### Multi-user
Each device has its own `quiz.sqlite`. The `reviewer` column in `reviews` should be set
to something meaningful (device name? user-entered name?). Currently defaults to OS username.

- Does each family member get independent Ebisu models? (Yes, local DB per device.)
- Do we want to sync progress across devices for the same person? (Probably not for MVP.)

### Kanji info
`get-kanji-info.mjs` queries kanjidic2 and WaniKani data. The iOS app bundles `kanjidic2.sqlite`
plus two WaniKani JSON files and exposes a `lookup_kanjidic` tool to Claude (available in both
quiz chat and word-explore chat):
- Input: any string — non-kanji characters are ignored; e.g. `怒鳴る` → info for 怒 and 鳴
- Output: JSON array, one entry per kanji:
  - `literal`, `radicals` (kradfile labels), `strokes`, `jlpt` (N-string), `grade`, `on`, `kun`, `meanings`
  - `wanikani_components` (if available): array of `{char, meaning}` or `{char, description}` objects —
    `meaning` comes from KANJIDIC2 if the component is a standard kanji; `description` from
    `wanikani-extra-radicals.json` for informal components (katakana shapes, IDS sequences, etc.)
- Radical data (kradfile) is baked into `kanjidic2.sqlite` at build time as a `radicals TEXT` column (JSON array)
  - `get-kanji-info.mjs` populates it during the initial build; existing DBs are migrated on next run
  - iOS tool reads it directly — no separate kradfile bundle needed
- Bundled in `Resources/kanjidic2.sqlite` (DELETE journal mode, same requirement as jmdict.sqlite)
- WaniKani JSON files bundled as `Resources/wanikani-kanji-graph.json` and `Resources/wanikani-extra-radicals.json`
  - Source files live in `wanikani/` in the project root; copy to `Pug/Pug/Resources/` when updated
  - Loaded at `ToolHandler` init via `WanikaniData.load()`; gracefully empty if files absent
- Copied to Documents on first launch by `QuizDB.copyKanjidicIfNeeded()` (called in `setup()`)
- ToolHandler opens kanjidic2 read-only as a `DatabaseQueue`; stored as optional so a missing file degrades gracefully

#### Preparing kanjidic2.sqlite for a build

Before building the iOS app (or after updating the source data), run once from the project root:

```sh
# 1. Download source files from https://github.com/scriptin/jmdict-simplified/releases
#    and place in the project root:
#      kanjidic2-en-*.json   (KANJIDIC2 data)
#      kradfile-*.json       (radical decomposition)

# 2. Build/update kanjidic2.sqlite (creates it on first run; migrates radicals on subsequent runs)
#    The script sets DELETE journal mode automatically — no extra sqlite3 step needed.
node .claude/scripts/get-kanji-info.mjs 日  # any kanji — triggers build/migration, then exits

# 3. Copy into the Xcode Resources folder
cp kanjidic2.sqlite Pug/Pug/Resources/kanjidic2.sqlite

# 4. Copy WaniKani JSON files (re-run whenever wanikani/ source files are updated)
cp wanikani/wanikani-kanji-graph.json Pug/Pug/Resources/
cp wanikani/wanikani-extra-radicals.json Pug/Pug/Resources/
```

#### Preparing jmdict.sqlite for a build

```sh
# 1. Download jmdict-eng-*.json from https://github.com/scriptin/jmdict-simplified/releases
#    and place in the project root.

# 2. Build jmdict.sqlite (DELETE journal mode set automatically by openJmdictDb())
node .claude/scripts/check-vocab.mjs   # any script using openJmdictDb() works

# 3. Copy into the Xcode Resources folder
cp jmdict.sqlite Pug/Pug/Resources/jmdict.sqlite
```

---

## Phases / TODO

### Phase 0 — Vocab browser (enrollment UX) ✓ complete
*The first thing a new user does. Without this, there's nothing to quiz.*

- [x] Vocab sync: `Models/VocabSync.swift` downloads `vocab.json` (with `writtenForms` furigana
      data) from `vocabUrl` (UserDefaults, set by setup deep link) or `VOCAB_URL` env var.
      Caches to `Documents/vocab.json`.
- [x] Vocab browser UI: `Views/VocabBrowserView.swift` — filterable word list with OR-based
      filter picker (Not yet learning / Learning / Learned / All). Status badges show aggregate
      facet state. Swipe actions vary by state. Search across kanji, kana, meanings, and mnemonics.
- [x] Word detail sheet: `Views/WordDetailSheet.swift` — ruby furigana heading, meanings,
      furigana form picker (choose which written form to study; skipped for kana-only words),
      independent reading/kanji segmented pickers, kanji character toggle grid (FlowLayout),
      Claude explore chat. Kana-only words (`isKanaOnly`) show a plain "SPELLINGS" section
      instead of a picker and expose the reading control immediately.
      All state changes go through `VocabCorpus` → `QuizDB` and update reactively.
- [x] `word_commitment` + `learned` tables (v5 migration) — replaces `vocab_enrollment`
- [x] Facet state derived from `ebisu_models` (learning) and `learned` (known) tables
- [x] Backward compatibility: words with `ebisu_models` rows but no `word_commitment` row
      (introduced via Node.js quiz) get a commitment row on launch (`reconcileEnrollment`).
- [x] Navigation: `Views/HomeView.swift` — `TabView` with Vocab (books icon) and Quiz tabs.
- [x] Onboarding: `AppRootView` shows `ContentUnavailableView("Setup Required")` if API key or
      vocab URL not yet configured — disappears automatically after setup link is tapped

### Phase 1 — MVP (quiz works end to end) ✓ complete
- [x] Xcode project setup (SwiftUI, iOS 17+, bundle ID) — project is `Pug/`
- [x] Add GRDB.swift via Swift Package Manager (v7+; fixed pbxproj to link product to app target)
- [x] Copy quiz DB schema from `init-quiz-db.mjs`; create on first launch — `Models/QuizDB.swift`
- [x] Bundle `jmdict.sqlite` as app resource; copy to Documents on first launch — `QuizDB.copyJMdictIfNeeded()` (still need to drag file into Xcode Resources)
- [x] Anthropic API client — thin URLSession wrapper around `/v1/messages` — `Claude/AnthropicClient.swift`
- [x] Port Ebisu math (`predictRecall`, `updateRecall`, `defaultModel`, `rescaleHalflife`) to Swift — `Models/EbisuModel.swift`; **635 unit tests passing** (reference test.json + stress tests + smoke tests)
- [x] Tool use handler — `lookup_jmdict(word:)` → query `raws`+`entries` tables → return JSON — `Claude/ToolHandler.swift`
  - Uses `DatabaseQueue` (not Pool) + `readonly: true` to avoid WAL sidecar files on a read-only DB
  - `jmdict.sqlite` **must be in DELETE journal mode** before bundling — run `sqlite3 jmdict.sqlite "PRAGMA journal_mode=DELETE;"` after regenerating; stored in `Resources/`
- [x] Port `get-quiz-context` logic to Swift — `Models/QuizContext.swift`
  - Infers `hasKanji` from which facets exist in `ebisu_models`
  - Word text sourced from most recent `reviews.word_text` row per word, or JMdict
- [x] Quiz UI — `Views/QuizView.swift`; phase state machine per item:
  - `idle/loadingItems/generating` → loading spinner
  - `awaitingTap(MultipleChoiceQuestion)` → stem bubble + 4 native tap buttons (multiple choice)
  - `awaitingText(stem)` → stem bubble + text field + submit (free-answer)
  - `chatting` → chat bubble thread, send input, score badge, Skip/Next button
  - All text is selectable via `SelectableText` (UIViewRepresentable wrapping UITextView)
- [x] Record review (write to quiz.sqlite after each answer) — in `Claude/QuizSession.swift`
  - Multiple choice: app scores immediately on tap (`tapChoice`), no SCORE token from Claude
  - Free-answer: Claude grades with `SCORE: X.X`; `doOpeningChatTurn(shouldParseScore:true)` handles it
  - `QuizSession` is `@Observable @MainActor`; conversation grows within a single item, resets per item
  - Three tools available during chat: `lookup_jmdict` + `lookup_kanjidic` + `get_vocab_context`
  - `get_vocab_context` result pre-computed at handler creation time (snapshot of enrolled list)
- [x] LLM pre-selection call — `QuizSession.selectItems(candidates:)` sends all enrolled words as
  context lines (one per word, JS-skill format) and asks Claude to pick 3–5 varied items; falls
  back to top-N by recall if LLM returns < 3 valid IDs or errors
- [x] Session persistence — `quiz_session` table (migration "v2"); resumes on relaunch; cleared
  item-by-item as each answer is graded; `refreshSession()` + "New Session" toolbar button
- [x] Setup deep link handler (Keychain + UserDefaults) — `App/SetupHandler.swift`
  - URL scheme `japanquiz://` registered via manual `Pug/Info.plist`
    - `GENERATE_INFOPLIST_FILE = NO`; `INFOPLIST_FILE = Pug/Info.plist` in build settings
    - Info.plist contains all required bundle keys (`CFBundleIdentifier` etc. via `$(VAR)` references)
      plus `CFBundleURLTypes` for the `japanquiz` scheme
    - Info.plist must NOT be in Copy Bundle Resources build phase (Xcode processes it via INFOPLIST_FILE)
  - `AppRootView` handles `.onOpenURL`, calls `SetupHandler.handle(url:)`, then re-initialises via `setupID` state flip (`.task(id: setupID)`)
  - API key stored in Keychain (`kSecClassGenericPassword`, service `me.aldebrn.Pug`); `SetupHandler.resolvedApiKey()` falls back to `ANTHROPIC_API_KEY` env var for dev
  - For dev: set `ANTHROPIC_API_KEY` and `VOCAB_URL` in Xcode scheme's Run → Environment Variables
  - `VOCAB_URL` = full raw Gist URL printed by `publish.mjs` on success
    (e.g. `https://gist.githubusercontent.com/<user>/<gist_id>/raw/vocab.json`)
  - `make-setup-link.mjs` — reads `.env` and prints the encoded `japanquiz://setup?...` URL
  - Test in simulator: `node make-setup-link.mjs | xargs xcrun simctl openurl booted`
- [x] Vocab sync + corpus — `Models/VocabSync.swift` + `Models/VocabCorpus.swift`
      (moved to Phase 0; listed here because it was originally a Phase 1 TODO)

### Maybe someday
- [ ] Bake variety rules into Swift (instead of LLM pre-selection): algorithmic pass over urgency-sorted items — cap at 2 items per facet type, at most 1–2 new words, ensure at least 2 different facets if available. Zero latency, zero tokens. Revisit if LLM pre-selection proves too slow/costly.
- [ ] Pre-filter context for large corpora: when enrolled word count reaches hundreds, send all new
  items plus the top 20–50 most-urgent reviewed items to the LLM pre-selection call rather than
  the full list. Avoids token bloat while keeping the most important candidates visible.

### Phase 2 — Polish
- [ ] Handle `stop_reason: "max_tokens"` in `AnthropicClient` — detect truncated responses and
  either show a user-facing warning or automatically re-prompt to continue. Affects
  `WordExploreSession` (kanji/word explanations) and quiz grading turns.
- [x] Two-call question validation (generate → validate before showing; + `---QUIZ---` sentinel to strip preamble)
- [x] Teaching / introduction flow for new words — `WordDetailSheet` (tap row or swipe Learn
      in VocabBrowserView; furigana form picker → reading/kanji segmented pickers → kanji
      character toggles; all facets initialized atomically via batch helpers).
- [x] Halflife rescaling UI ("too easy" / "too hard" buttons)
- [ ] Session summary screen
- [ ] Mnemonic and etymology sidebars during quiz
- [x] Publish pipeline scripts (`prepare-publish.mjs` + `publish.mjs`) — vocab.json to Gist via SSH git push
- [x] Settings screen (quiz style: varied/intensive) — `Views/SettingsView.swift`; `Models/UserPreferences.swift` (UserDefaults-backed `@Observable`); accessible via ··· menu in Vocab tab
  - Varied: after grading, passively update sibling facets the student was naturally exposed to (non-kanji facet → other non-kanji facet; kanji facet → all other facets). Score 0.5, advances `last_review` timestamp to suppress repetition.
  - Intensive: only the quizzed facet is updated.
- [ ] Settings screen: API key, vocab URL, reviewer name, model picker (Phase 2 remaining items)
- [ ] Context-based questions for ambiguous kana: bare kana like め is ambiguous (目/芽/め-suffix).
  For suffixes, particles, or kana that match multiple common words, allow Claude to use a short
  example sentence as the question stem instead of bare kana (e.g. "In 馬鹿め！, what does め
  express?" rather than "What does め mean?"). Requires softening the rigid "Show ONLY kana"
  rule for reading-to-meaning and letting Claude call lookup_jmdict to detect ambiguity/POS.
  Accumulate real examples before tuning the prompt.
- [x] Search the vocab list (kanji, kana, English, mnemonics)
- [x] Add Wanikani kanji↔radicals map to augment KRADFILE/Kanjidic2. https://github.com/fasiha/ebieki/blob/master/wanikani-kanji-graph.json

### Phase 3 — Future
- [ ] Grammar points and sentence translation quiz types
- [x] Kanjidic2 bundle (`kanjidic2.sqlite`) + `lookup_kanjidic` tool — stroke/JLPT/grade/on/kun/meanings
- [ ] Source sentence display on first encounter
- [ ] `kanji_knowledge` table: let users assert kanji they know during enrollment triage;
      use to suppress furigana for known kanji in reading display across all words
- [ ] Persist chat about words.

---

## File layout

```
Pug/                          ← Xcode project root (already created)
  Pug.xcodeproj/
  Pug/                        ← app source
    PugApp.swift              ← @main entry point (generated)
    ContentView.swift                    ← replace with real nav structure
    Assets.xcassets/
    App/
      SetupHandler.swift                 ✓ deep link + Keychain
    Models/
      QuizDB.swift                       ✓ GRDB setup, migrations (incl. vocab_enrollment)
      EbisuModel.swift                   ✓ predictRecall / updateRecall (635 tests)
      QuizContext.swift                  ✓ get-quiz-context logic (enrolled words only)
      VocabCorpus.swift                  ✓ corpus state: manifest → JMdict-enriched items → enrollment
      VocabSync.swift                    ✓ URL resolution (UserDefaults / VOCAB_URL env) + cache
    Claude/
      AnthropicClient.swift              ✓ URLSession wrapper, tool-use loop
      ToolHandler.swift                  ✓ lookup_jmdict + lookup_kanjidic tool use (DatabaseQueue, readonly)
      QuizSession.swift                  ✓ session orchestration, grading, Ebisu update
      WordExploreSession.swift           ✓ free-form Claude chat for a single word (in WordDetailSheet)
    Views/
      HomeView.swift                     ✓ TabView root: Vocab + Quiz tabs
      VocabBrowserView.swift             ✓ filterable word list, swipe triage, search, OR-based filters
      WordDetailSheet.swift              ✓ ruby heading, furigana form picker, reading/kanji pickers, Claude chat
      QuizView.swift                     ✓ quiz UI (phase state machine)
      SettingsView.swift                 ✓ quiz style (varied/intensive), model picker
    Resources/
      jmdict.sqlite                      ✓ bundled (DELETE journal mode — see ToolHandler note)
      kanjidic2.sqlite                   ✓ bundled (DELETE journal mode same requirement)
      wanikani-kanji-graph.json          ✓ bundled (kanji → WaniKani component chars)
      wanikani-extra-radicals.json       ✓ bundled (descriptions for non-kanjidic2 components)
  PugTests/                   ← Swift Testing unit tests (generated)
    PugTests.swift
  PugUITests/                 ← XCTest UI tests (generated)
    PugUITests.swift
  TestHarness/                ← CLI test harness (Swift Package, separate from Xcode project)
    Package.swift             ← declares executable target; depends on GRDB via SPM
    Sources/TestHarness/
      main.swift              ← entry point: looks up word by ID, builds QuizItem, runs generation/grading
      DumpPrompts.swift       ← --dump-prompts mode: triple-loop over facet × mode × commitment
      AnthropicClient.swift   ← symlink → ../Pug/Claude/AnthropicClient.swift
      QuizSession.swift       ← symlink → ../Pug/Claude/QuizSession.swift
      ToolHandler.swift       ← symlink → ../Pug/Claude/ToolHandler.swift
      QuizDB.swift            ← symlink → ../Pug/Models/QuizDB.swift
      QuizContext.swift       ← symlink → ../Pug/Models/QuizContext.swift
      EbisuModel.swift        ← symlink → ../Pug/Models/EbisuModel.swift
      UserPreferences.swift   ← symlink → ../Pug/Models/UserPreferences.swift
```

### Test harness (`TestHarness/`)

See [TESTING.md](TESTING.md) for full build instructions, modes, reference word IDs, and required data files.

---

## Token cost reduction

The app calls the Claude API frequently: item selection, question generation, question
validation, and every chat turn. Each call resends the full system prompt + tool schemas +
conversation history. This section collects ideas for reducing input token burn, ranked
roughly by expected impact. The `api_events` telemetry table (v6 migration) provided
data to validate these estimates before committing to implementation.

### 1. Drop the validation call — **DONE** (validator removed)

The validator was broken for all facet types and was causing 100% false-fail retries.
Originally disabled 2026-03-10 via `skipValidation = true`; the `validateQuestion` method,
`skipValidation` flag, and all free-answer generation code (`extractQuestion`, `---QUIZ---`
sentinel) were fully removed 2026-03-11 as dead code (generation loop is now multiple-choice-only;
free-answer stems are built app-side). The generation prompt was tightened instead (correct
answer explicitly anchored for `kanji-to-reading`). See `TODO-validator-bugfix.md`.
If a local string-contains check is added later it can gate re-enabling a validator.

### 2. Batch `lookup_jmdict` calls — **DONE** (2026-03-11)

**Problem**: `question_gen` was averaging 10–11 `lookup_jmdict` calls per meaning-to-reading question,
each a separate API round-trip, driving `api_turns` to 4–5 and total input tokens to
5k–7k per question.

**Root causes fixed**:
- The `distractor` instruction in `sharedCore` was sent for **all** formats including
  free-answer, causing spurious lookups even when there are no distractors. Fixed by
  making `distractorLine` conditional on `isGenerating && !item.isFreeAnswer`.
- `isFreeAnswer` logic was duplicated in 3 places. Centralized into `QuizItem.isFreeAnswer`
  in `QuizContext.swift`.
- `lookup_jmdict` accepted a single word. Changed to accept `words: [String]` array;
  handler does one SQLite round-trip (`JOIN` + `GROUP BY e.id` + `GROUP_CONCAT`) for all
  words. System prompt updated: "batch all candidates into one call."
- Telemetry: batch size encoded in `tools_called` as `"lookup_jmdict:N"`.

**Result**: `question_gen` now typically 2 API turns (one reasoning turn + one batched
lookup), down from 3–5. Overhead dropped from ~3,500 to ~1,600 avg tokens per generation.

### 3. Inject full entry data into generation prompt — **DONE** (2026-03-11)

**Problem**: For `reading-to-meaning`, the system prompt withheld the kanji form to avoid
leaking the answer. Claude then looked up the *kana* reading (e.g. じじょう) to find the
entry — but kana readings are non-unique in JMDict. The first hit was often a rare
homophone (じじょう → 耳茸 "ear polyp"), forcing a second lookup with the kanji form.
This added 1–2 extra API turns on affected words, causing outliers with 9 api_turns.

**Fix**: All four facets now include a `[Entry ref — never copy verbatim into question
stem: written=X kana=Y meanings=Z]` block in the wordLine. Claude has the complete entry
data and zero reason to look up the target word — the tool is then used only for
distractor verification. The "never copy verbatim" instruction is sufficient to prevent
the entry ref from leaking into question stems.

**Result**: Affected words dropped from 5–9 api_turns to 2. All four facets now
consistently complete in 2 turns (one batched distractor lookup). Validated with the
CLI test harness across all four facets.

### 5. No-tool generation for reading-to-meaning and meaning-to-reading — **DONE** (2026-03-11)

**Insight**: For reading-to-meaning, the A/B/C/D options are plain English phrases.
For meaning-to-reading, they are kana readings. Claude needs no database to generate
either — it has native knowledge of Japanese vocabulary semantics and phonology.
The `lookup_jmdict` calls for distractors were pure overhead.

**Fix**: `generationTools(for:)` returns `[]` for reading-to-meaning and meaning-to-reading. The `distractorLine`
in `systemPrompt` is now facet-specific:
- reading-to-meaning: "write 3 wrong English meanings directly — no lookup needed. Same semantic field,
  bare phrases only."
- meaning-to-reading: "write 3 wrong kana readings directly — no lookup needed. Similar rhythm/mora."
- kanji-to-reading / meaning-reading-to-kanji: unchanged (`lookup_kanjidic` / `lookup_jmdict` respectively).

**Result**: reading-to-meaning and meaning-to-reading drop from 2 api_turns (~1,500 tokens) to **1 api_turn
(~275 input tokens)**. ~80% token reduction for the two most common facets.
Distractor quality on Haiku matches or exceeds the JMDict-lookup approach — e.g.
きりかぶ got "firewood / sawdust / wood chip", which is more instructive than
JMDict-sourced alternatives. Validated across 4 words × 2 facets on Haiku.

### 7. Algorithmic item selection — **DONE** (2026-03-12)

**Problem**: The LLM selection call sent all candidates (~120 chars each × N words) for
Claude to pick 3–5, consuming ~3,400 input tokens per session — the single largest token
cost (42% of all input tokens as of 2026-03-12 telemetry).

**Telemetry finding**: Despite diversity guidelines in the prompt, Claude always picked
rank 0 and clustered within the top ~13 ranks. It was effectively just sorting by urgency
with mild randomness — nothing that needs an LLM.

**Fix**: `selectItems` in `QuizSession.swift` is now a pure synchronous function. It takes
the top 10 candidates from `QuizContext.build`'s already-sorted list (lowest recall first,
one facet per word — collapsing already done in `build`) and randomly picks 3–5 via
`shuffled().prefix(count)`. Zero API calls, zero latency.

**Constants** in `QuizContext.swift`: `selectionPoolSize = 10`, `minItemsPerQuiz = 3`,
`maxItemsPerQuiz = 5`.

### 8. Compress system prompts

The system prompt is ~1500–2000 tokens per call. Main bloat:
- Facet-specific rules include full ✅/❌ examples (~200 chars each). Haiku follows terse
  bullet points fine — examples could be removed or shortened to one-liners.
- The "Tools available" block redescribes tools already defined in the tool schemas.
  Redundant — Claude sees tool descriptions from the schema. Can be removed entirely.
- Partial-kanji-commitment rules (~700 chars with worked examples) could be compressed
  to a template + one example.
- WordExploreSession's 20-line Ebisu explanation could be 2 sentences.
- SCORE/NOTES rules could be a compact template.

### 9. Trim tool schemas per call phase

Tool definitions are sent on every API call. Not all tools are needed in every phase:
- **Generation call**: only `lookup_jmdict` + `lookup_kanjidic` (already correct).
- **Validation call**: zero tools needed (just PASS/FAIL text).
- **Chat turns**: all 5 tools. But `set_mnemonic` has a long description (~200 chars)
  explaining the merge-before-overwrite rule — this could be shortened.

This is a smaller win than the others (~100–200 tokens saved per call).

### 10. Sliding window on conversation history

Chat turns accumulate unbounded within an item. Turn 5 resends turns 1–4. For most items
this is 2–3 turns, but curious students can go longer.
- Keep system prompt + first turn (question) + last 2–3 turns.
- Or summarize earlier turns into a single message.
- **Telemetry finding** (2026-03-11): median item finishes at turn 4–5; two outlier items
  hit turn 7 (13k–18k tokens). Sliding window helps the tail, not the median.

---

## Telemetry: `_api_events_` table (v6–v8 migrations)

Lightweight analytics to inform token cost optimization decisions. One row per API call.

### Event types and what they contain

**`question_gen`** — one row per multiple choice generation attempt (free-answer items now build their stem app-side and emit **no** `question_gen` event). A single call to `client.send()` with:
- System prompt: `sharedCore` only (word metadata + facet rule + distractor guidance). No SCORE/NOTES rules.
- Response format: raw JSON `{stem, choices[4], correct_index}` — no markdown, no `---QUIZ---` sentinel.
- Tools: `lookup_jmdict` + `lookup_kanjidic` for kanji/meaning-reading-to-kanji facets; none for reading-to-meaning or meaning-to-reading (distractors are constructed without lookup). Tool round-trips are still the main cost driver for kanji facets.

**`quiz_chat`** — one row per Claude turn during the post-answer conversation. Turn 1 is always `doOpeningChatTurn` (app-constructed result message); subsequent turns are student follow-ups. A single call to `client.send()` with:
- System prompt: `sharedCore` + chat extension. For multiple choice: no SCORE/NOTES rules ("scoring is app-side"). For free-answer: SCORE/NOTES rules active. Both include MEANING_DEMONSTRATED (kanji-to-reading), set_mnemonic warning, optional mnemonic block.
- Tools: all 5 (`lookup_jmdict`, `lookup_kanjidic`, `get_vocab_context`, `get_mnemonic`, `set_mnemonic`).
- Messages: full conversation history. Accumulates across turns.
- The **grading turn** for free-answer is `quiz_chat` row 1 (where Claude emits `SCORE: X.X`). Multiple choice has no grading turn — `score` in row 1 will be null from Claude's perspective (app scored it).

**`item_selection`** — one LLM call per session start (unless a saved session is resumed). Sends the full candidate list (~120 chars/candidate × N words). `selected_ranks` logs which positions the LLM picked for post-hoc analysis of whether algorithmic selection would match.

**`question_validation`** — currently disabled (`skipValidation = true`). Was a cheap second-pass call (no tools, maxTokens=10) that checked whether the generated question leaked the answer.

**`word_explore`** — open-ended word exploration chat from WordDetailSheet. Not yet fully instrumented.

### question_gen vs quiz_chat token cost

With app-side question construction for free-answer items, `question_gen` events are now **multiple choice only**. For kanji facets, tool round-trips (kanjidic lookups for distractors) still dominate cost. For `reading-to-meaning` and `meaning-to-reading` multiple choice, Claude writes distractors directly with no tool calls, making those `question_gen` events much cheaper. `first_turn_input_tokens` (v8) isolates fixed system/tool overhead from the tool-call payload.

### Schema has grown via ALTER TABLE migrations; current columns:

```sql
-- v6 core
id INTEGER PRIMARY KEY AUTOINCREMENT
timestamp TEXT NOT NULL            -- ISO 8601 UTC
event_type TEXT NOT NULL           -- 'item_selection'|'question_gen'|'question_validation'|'quiz_chat'|'word_explore'
word_id TEXT                       -- JMDict ID (null for item_selection)
quiz_type TEXT                     -- facet (null for item_selection / word_explore)
input_tokens INTEGER               -- total input tokens across all API turns in send()
output_tokens INTEGER              -- total output tokens
chat_turn INTEGER                  -- 1-based turn within item (quiz_chat only)
model TEXT
selected_ids TEXT                  -- JSON array (item_selection)
selected_ranks TEXT                -- JSON array of 0-based recall ranks (item_selection)
validation_result TEXT             -- 'pass'|'fail' (question_validation)
generation_attempt INTEGER         -- 1 or 2 (question_gen)
tools_called TEXT                  -- JSON array of tool names

-- v7
api_turns INTEGER                  -- number of API round-trips inside send()

-- v8
first_turn_input_tokens INTEGER    -- input tokens on first round-trip only (system + tool schemas + messages); isolates overhead from conversation payload
question_chars INTEGER             -- character length of extracted question (question_gen)
question_format TEXT               -- 'multiple_choice'|'free_answer' (question_gen)
prefetch INTEGER                   -- 0=foreground generation, 1=background prefetch (question_gen)
candidate_count INTEGER            -- candidates sent to LLM (item_selection)
has_mnemonic INTEGER               -- 0/1 mnemonic block injected (quiz_chat)
score REAL                         -- graded score 0.0–1.0 if turn emitted SCORE: (quiz_chat)
pre_recall REAL                    -- Ebisu predicted recall at quiz time (question_gen, quiz_chat)
```

Key queries this enables:
- **Overhead vs payload**: `SELECT AVG(first_turn_input_tokens), AVG(input_tokens) FROM api_events GROUP BY event_type`
- **Validation rejection rate**: `SELECT validation_result, COUNT(*) FROM api_events WHERE event_type='question_validation' GROUP BY validation_result`
- **LLM selection vs urgency**: compare `selected_ranks` to `[0,1,2,3,4]` — how often does LLM just pick the top-N?
- **Chat depth**: `SELECT MAX(chat_turn) FROM api_events WHERE event_type='quiz_chat' GROUP BY word_id, timestamp`
- **Token cost by event type**: `SELECT event_type, SUM(input_tokens), SUM(output_tokens) FROM api_events GROUP BY event_type`
- **Does difficulty drive chat length?**: join `pre_recall` on `quiz_chat` rows with `MAX(chat_turn)` per item
- **Prefetch waste rate**: `SELECT prefetch, COUNT(*) FROM api_events WHERE event_type='question_gen' GROUP BY prefetch`
- **Format vs score correlation**: `SELECT question_format, AVG(score) FROM api_events WHERE event_type='quiz_chat' AND score IS NOT NULL`
- **Tool call cost in question_gen**: `SELECT api_turns, AVG(input_tokens), COUNT(*) FROM api_events WHERE event_type='question_gen' GROUP BY api_turns` — items with api_turns≥3 are expensive; if most distractor lookups could be pre-computed, big savings

### Telemetry report script

`.claude/scripts/telemetry-report.mjs [hours]` (default 12h) — prints a structured markdown-style report to stdout covering all sections above. Run after a quiz session to audit the above questions without SQL.

```
node .claude/scripts/telemetry-report.mjs 12
node .claude/scripts/telemetry-report.mjs 999   # all-time
```

---

## Reference

- Existing quiz logic: `.claude/commands/quiz.md`
- DB schema: `CLAUDE.md` and `.claude/scripts/init-quiz-db.mjs`
- Ebisu JS implementation: `node_modules/ebisu-js/`
- JMdict tool: `github:scriptin/jmdict-simplified`
- Ruby span source: `github:Doublevil/JmdictFurigana`
- GRDB.swift: `github.com/groue/GRDB.swift`
- Anthropic API: `docs.anthropic.com/en/api`
