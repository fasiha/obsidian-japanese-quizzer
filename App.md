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
  word_type  TEXT NOT NULL,   -- 'jmdict', 'kanji', or 'grammar'
  word_id    TEXT NOT NULL,   -- JMDict entry ID, kanji character, or prefixed topic ID
  mnemonic   TEXT NOT NULL,
  updated_at TEXT NOT NULL,   -- ISO 8601 UTC
  PRIMARY KEY (word_type, word_id)
);
```

- `word_type='jmdict'` — mnemonic for a vocabulary word (same ID as `vocab_enrollment`)
- `word_type='kanji'` — mnemonic for a single kanji character (the character itself is the `word_id`)
- `word_type='grammar'` — mnemonic for a grammar topic (prefixed topic ID, e.g. `genki:potential-verbs`); stored once and mirrored to all equivalence-group siblings automatically
- Kanji mnemonics don't require enrollment or Ebisu models — they're pure reference data

**Claude integration:**
- `get_mnemonic` / `set_mnemonic` tools available in both quiz chat and word explore sessions
- During quiz: mnemonic is **not** shown during question generation (avoid priming); injected
  into the system prompt **after the user's first reply** so Claude can reference it in feedback
- During word exploration: mnemonics shown from the start; Claude can save new ones
- `WordDetailSheet` displays existing vocab + relevant kanji mnemonics in the info section
- Claude understands the vocab/kanji distinction and will offer to save either type when
  appropriate — e.g. "Would you like a separate kanji mnemonic emphasising the water+easy
  composition, or expand the existing vocab mnemonic?" You can also ask explicitly: "save a
  kanji mnemonic for 込" vs "save a mnemonic for this word"

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
- **Model**: defaults to `claude-haiku-4-5-20251001` for dev (fast, cheap). Override via `ANTHROPIC_MODEL` env var in the Xcode scheme, or the Settings screen. Switch to `claude-sonnet-4-6` for production TestFlight builds.
- **Tools available during a quiz item** (`Claude/ToolHandler.swift`):
  - `lookup_jmdict` — query local `jmdict.sqlite` for dictionary-accurate readings and
    meanings. Called during question generation or when the student asks about a word's
    readings/meanings. Accepts a `words: [String]` array and does one SQLite round-trip for
    all words. Used only for kanji-to-reading and meaning-reading-to-kanji facets (the other
    two facets have Claude write distractors directly from its own knowledge).
  - `lookup_kanjidic` — query local `kanjidic2.sqlite` augmented with WaniKani component
    data for per-kanji breakdown: stroke count, JLPT level, school grade, on/kun readings,
    English meanings, kradfile radical labels, and a `wanikani_components` array (each entry
    has `char` + either `meaning` from KANJIDIC2 or `description` from WaniKani's informal
    component glossary). Input is any string — non-kanji characters are skipped.
  - `get_vocab_context` — returns the student's full enrolled word list with recall
    probabilities. Called when the student's message is about a different word they're
    studying, or when knowing their broader learning context would help.
  - `get_mnemonic` / `set_mnemonic` — retrieve or save mnemonic notes for vocab words or
    individual kanji characters. Available in both quiz chat and word exploration.
- **Ebisu state in system prompt**: `systemPrompt(for:item)` emits
  `Current memory state: recall=X.XX, halflife=Xh` for the word being quizzed — targeted,
  zero extra tokens in the vocab list, always available without a tool call.

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
  - Conversation continues freely after the opening turn. "Next Question →" appears once
    graded; "Skip →" is always available. Each item starts with a clean context.
- **Item selection** (`QuizSession.selectItems`): synchronous, no LLM call. Takes the top
  10 candidates from `QuizContext.build`'s urgency-sorted list and picks 3–5 randomly via
  `shuffled().prefix(count)`. Constants in `QuizContext.swift`: `selectionPoolSize = 10`,
  `minItemsPerQuiz = 3`, `maxItemsPerQuiz = 5`.
- **Full entry data in system prompt**: All four facets include an
  `[Entry ref — never copy verbatim into question stem: written=X kana=Y meanings=Z ...]`
  block so Claude never needs to look up the target word itself. Tools are then used only
  for distractor verification.
- **No-tool generation for reading-to-meaning and meaning-to-reading**: These facets produce
  English and kana distractors respectively — Claude has native knowledge of both.
  `generationTools(for:)` returns `[]` for these facets; distractors are written directly.
  Kanji-to-reading and meaning-reading-to-kanji still use `lookup_kanjidic` / `lookup_jmdict`.
- **Question validation**: Removed as dead code (2026-03-11). Was broken for all facet types.
  Free-answer stems are now built app-side; multiple choice generation is direct JSON.

### Grammar quiz UI refinements

- **Cloze template header** (`GrammarQuizView.swift`, `GrammarQuizSession.swift`):
  When all four production-facet choices share a meaningful common prefix and/or suffix
  (≥ 4 characters combined), the view extracts those shared frames and displays a single
  template line above the choices — e.g. `彼女は毎日___ています。` — while each choice
  button shows only its unique core (e.g. `…勉強し…`). This removes visual noise and
  makes the grammatical difference between options immediately scannable.
  The template is computed by `choiceClozeTemplate()` on `GrammarMultipleChoiceQuestion`;
  falls back to full-sentence buttons when choices are too diverse.

- **Audio playback** (`GrammarAudioPlayer`, `GrammarQuizView.swift`):
  A "Play audio / Stop audio" button above the uncertainty row speaks the Japanese
  sentences aloud using `AVSpeechSynthesizer` at 85 % of the default rate.
  - **Production facet**: plays all four choice sentences in sequence with a 0.8 s gap.
    Choice A speaks the full sentence (giving the listener the complete frame once).
    Choices B–D speak a trimmed snippet — the differing core plus up to 5 characters of
    context from each side — so the listener hears the grammatical contrast without
    sitting through the repeated prefix and suffix each time.
    Context trimming uses `kanjiSafeTail` / `kanjiSafeHead` helpers that extend the
    cut point outward if it falls mid-kanji-compound, so kanji words are never bisected.
  - **Recognition facet**: speaks only the Japanese stem (one sentence).
  - Tap once → play; tap again → stop; tap a third time → play from the beginning.
  - Audio stops automatically when the phase changes (question answered, next question
    loaded) or when the quiz sheet is dismissed.

### Setup / distribution
- **Setup deep link**: `japanquiz://setup?key=sk-ant-...&vocabUrl=https://...`
  - Registered custom URL scheme in Info.plist
  - Handled with SwiftUI's `.onOpenURL`
  - Key saved to Keychain, URL saved to UserDefaults
  - Distributed via iMessage or AirDrop to family — never needs to be public
  - Mitigation for key exposure: set a monthly usage cap in Anthropic console
- **Info.plist**: `GENERATE_INFOPLIST_FILE = NO`; `INFOPLIST_FILE = Pug/Info.plist` in build
  settings. Contains all required bundle keys plus `CFBundleURLTypes` for the `japanquiz`
  scheme. Must NOT be in Copy Bundle Resources build phase (Xcode processes it via INFOPLIST_FILE).
- For dev: set `ANTHROPIC_API_KEY` and `VOCAB_URL` in Xcode scheme's Run → Environment Variables.
- `make-setup-link.mjs` — reads `.env` and prints the encoded `japanquiz://setup?...` URL.
  Test in simulator: `node make-setup-link.mjs | xargs xcrun simctl openurl booted`

### Publishing pipeline (Obsidian → hosted)

Publish step runs locally (`node prepare-publish.mjs && node publish.mjs <gist-id>`) and produces **two outputs
per story**, served from the same host:

```
stories/
  bunsho-dokkai-3/
    vocab.json      ← structured vocab data
    story.html      ← rendered prose for story reader (Phase 2+)
    assets/         ← images referenced in the Markdown (Phase 2+)
```

**`vocab.json`** — extracted from `<details><summary>Vocab</summary>` blocks:

`title` / `sources` values are the Markdown file's path relative to the project root, with the `.md` suffix stripped (e.g. `"genki-app/L13"`, `"Bunsho Dokkai 3"`). No `title:` frontmatter key is needed or used.

```json
{
  "generatedAt": "2026-03-04T00:00:00Z",
  "stories": [{ "title": "genki-app/L13" }],
  "words": [{
    "id": "1234567",
    "sources": ["genki-app/L13"],
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

Pipeline steps:
1. Find Markdown files with `llm-review: true` in frontmatter (no `title:` key needed)
2. Run check-vocab validation (inline in `prepare-publish.mjs`) — block on failures
3. Extract `vocab.json` from `<details>` blocks, enrich with JmdictFurigana `writtenForms` → write to project root (`prepare-publish.mjs`)
4. Push `vocab.json` to GitHub secret Gist via `git` over SSH (`publish.mjs`)
5. Convert Markdown → `story.html` with vocab span injection; copy/upload images (Phase 2+)

**Hosting — GitHub secret Gist**: free, opaque URL, binary via git push. Flat namespace
(all files across all stories share one directory) — use prefixed filenames to avoid
collisions. Raw URL format:
```
https://gist.githubusercontent.com/{user}/{gist_id}/raw/{filename}
```
The publish script rewrites `<img src>` to this pattern. Migrate to Cloudflare R2 if
namespace becomes messy (S3-compatible, free tier, per-story prefixes).

---

## Open questions / future

### Multi-user
Each device has its own `quiz.sqlite`. The `reviewer` column in `reviews` should be set
to something meaningful (device name? user-entered name?). Currently defaults to OS username.
Each family member gets independent Ebisu models (local DB per device). No cross-device sync
planned for MVP.

### Kanji info — preparing bundled databases

#### kanjidic2.sqlite

```sh
# 1. Download source files from https://github.com/scriptin/jmdict-simplified/releases
#    and place in the project root:
#      kanjidic2-en-*.json   (KANJIDIC2 data)
#      kradfile-*.json       (radical decomposition)

# 2. Build/update kanjidic2.sqlite (creates it on first run; migrates radicals on subsequent runs)
#    The script sets DELETE journal mode automatically.
node .claude/scripts/get-kanji-info.mjs 日  # any kanji — triggers build/migration, then exits

# 3. Copy into the Xcode Resources folder
cp kanjidic2.sqlite Pug/Pug/Resources/kanjidic2.sqlite

# 4. Copy WaniKani JSON files (re-run whenever wanikani/ source files are updated)
cp wanikani/wanikani-kanji-graph.json Pug/Pug/Resources/
cp wanikani/wanikani-extra-radicals.json Pug/Pug/Resources/
```

`lookup_kanjidic` tool output: JSON array, one entry per kanji — `literal`, `radicals`
(kradfile labels), `strokes`, `jlpt`, `grade`, `on`, `kun`, `meanings`, and
`wanikani_components` (array of `{char, meaning}` or `{char, description}` objects).

#### jmdict.sqlite

```sh
# 1. Download jmdict-eng-*.json from https://github.com/scriptin/jmdict-simplified/releases
#    and place in the project root.

# 2. Build jmdict.sqlite (DELETE journal mode set automatically by openJmdictDb())
node .claude/scripts/check-vocab.mjs   # any script using openJmdictDb() works

# 3. Copy into the Xcode Resources folder
cp jmdict.sqlite Pug/Pug/Resources/jmdict.sqlite
```

---

## File layout

```
Pug/                          ← Xcode project root
  Pug.xcodeproj/
  Pug/                        ← app source
    PugApp.swift              ← @main entry point
    App/
      SetupHandler.swift                 ✓ deep link + Keychain
    Models/
      QuizDB.swift                       ✓ GRDB setup, migrations
      EbisuModel.swift                   ✓ predictRecall / updateRecall (635 tests)
      QuizContext.swift                  ✓ get-quiz-context logic (enrolled words only)
      VocabCorpus.swift                  ✓ corpus state: manifest → JMdict-enriched items → enrollment
      VocabSync.swift                    ✓ URL resolution (UserDefaults / VOCAB_URL env) + cache
      UserPreferences.swift              ✓ UserDefaults-backed @Observable quiz style etc.
    Claude/
      AnthropicClient.swift              ✓ URLSession wrapper, tool-use loop
      ToolHandler.swift                  ✓ lookup_jmdict + lookup_kanjidic + mnemonic tools
      QuizSession.swift                  ✓ session orchestration, grading, Ebisu update
      WordExploreSession.swift           ✓ free-form Claude chat for a single word
    Views/
      HomeView.swift                     ✓ TabView root: Vocab + Quiz tabs
      VocabBrowserView.swift             ✓ filterable word list, swipe triage, search; grouped by source path (file tree DisclosureGroups) when search is inactive
      WordDetailSheet.swift              ✓ ruby heading, furigana picker, reading/kanji pickers, Claude chat
      QuizView.swift                     ✓ quiz UI (phase state machine)
      SettingsView.swift                 ✓ quiz style (varied/intensive), model picker
    Resources/
      jmdict.sqlite                      ✓ bundled (DELETE journal mode required)
      kanjidic2.sqlite                   ✓ bundled (DELETE journal mode required)
      wanikani-kanji-graph.json          ✓ kanji → WaniKani component chars
      wanikani-extra-radicals.json       ✓ descriptions for non-kanjidic2 components
  PugTests/                   ← Swift Testing unit tests
  PugUITests/                 ← XCTest UI tests
  TestHarness/                ← CLI test harness (Swift Package, separate from Xcode project)
    Package.swift
    Sources/TestHarness/
      main.swift              ← looks up word by ID, builds QuizItem, runs generation/grading
      DumpPrompts.swift       ← --dump-prompts mode: triple-loop over facet × mode × commitment
      (other files symlinked from Pug/Pug/ source)
```

See [TESTING.md](TESTING.md) for TestHarness build instructions, modes, and reference word IDs.

---

## Token cost decisions

The app calls the Claude API frequently — question generation and every chat turn. Key
architectural decisions made to keep token costs low:

- **No question validation call** — removed as dead code. Free-answer stems build app-side;
  multiple choice generation is direct JSON.
- **Batch `lookup_jmdict`** — tool accepts `words: [String]` and does one SQLite round-trip
  for all words. System prompt instructs Claude to batch all candidates into one call.
- **Full entry data in system prompt** — all four facets include a `[Entry ref — never copy
  verbatim: written=X kana=Y meanings=Z ...]` block. Claude has no reason to look up the
  target word itself; tools are used only for distractor verification.
- **No-tool generation for reading-to-meaning and meaning-to-reading** — distractors are
  plain English phrases or kana readings; Claude writes them from its own knowledge.
  ~80% token reduction for these two facets (1 API turn, ~275 input tokens vs ~1,500).
- **Algorithmic item selection** — `selectItems` is a synchronous function, no LLM call.
  Shuffles the top 10 urgency-sorted candidates and picks 3–5. Prior LLM selection consumed
  ~3,400 input tokens per session (42% of all input tokens) and behaved like a noisy sort.

### Future token reduction ideas
- Compress system prompts: remove ✅/❌ examples (replaced by terse bullets), strip "Tools
  available" block (Claude already sees tool schemas), shorten partial-kanji rules.
- Trim tool schemas per call phase: generation needs only lookup tools; chat needs all 5.
- Sliding window on conversation history: tail matters (median item finishes at turn 4–5;
  outliers hit turn 7 with 13k–18k tokens).

---

## Telemetry: `api_events` table (v6–v8 migrations)

One row per API call. Event types:
- `question_gen` — multiple choice generation (free-answer items emit no event; stems are app-side)
- `quiz_chat` — one row per Claude turn post-answer; turn 1 = grading turn for free-answer
- `word_explore` — open-ended word exploration chat from WordDetailSheet
- `item_selection` — removed (selection is now algorithmic)
- `question_validation` — removed

### Schema

```sql
-- v6 core
id INTEGER PRIMARY KEY AUTOINCREMENT
timestamp TEXT NOT NULL            -- ISO 8601 UTC
event_type TEXT NOT NULL
word_id TEXT                       -- JMDict ID (null for word_explore)
quiz_type TEXT                     -- facet
input_tokens INTEGER               -- total input tokens across all API turns in send()
output_tokens INTEGER
chat_turn INTEGER                  -- 1-based turn within item (quiz_chat only)
model TEXT
tools_called TEXT                  -- JSON array of tool names

-- v7
api_turns INTEGER                  -- number of API round-trips inside send()

-- v8
first_turn_input_tokens INTEGER    -- input tokens on first round-trip (system + tool schemas + messages)
question_chars INTEGER             -- character length of extracted question (question_gen)
question_format TEXT               -- 'multiple_choice'|'free_answer'
prefetch INTEGER                   -- 0=foreground, 1=background prefetch (question_gen)
has_mnemonic INTEGER               -- 0/1 mnemonic block injected (quiz_chat)
score REAL                         -- graded score 0.0–1.0 if turn emitted SCORE: (quiz_chat)
pre_recall REAL                    -- Ebisu predicted recall at quiz time
```

Telemetry report: `.claude/scripts/telemetry-report.mjs [hours]` (default 12h).
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
