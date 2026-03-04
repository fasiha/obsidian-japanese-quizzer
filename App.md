# iOS App — Architecture & Decisions

A SwiftUI iOS app for family distribution via TestFlight. Inspired by the
[home-cooked app](https://www.robinsloan.com/notes/home-cooked-app/) philosophy — small,
personal, doesn't need to scale.

**This is not just a port of the Claude Code skill.** The core design shift:

- The Claude Code skill's vocab is *author-curated* — words the author personally doesn't
  know. It works for one reader but is too sparse for a family audience.
- The app's corpus is *comprehensively annotated* — every word a beginner–intermediate
  reader might not know, added by the `/enrich-vocab` skill (see `TODO.md`). Users are
  then readers who independently decide what to do with each word.
- **Per-user enrollment**: each word in the corpus is in one of three states for each
  learner: `pending` (not yet decided), `enrolled` (actively learning via Ebisu),
  `known` (skipped — "I already know this"). Only `enrolled` words appear in quizzes.

This makes the app a *shared corpus, individual learning paths* system rather than a
personal vocabulary manager.

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
  - **WAL mode caveat**: `better-sqlite3` may leave `jmdict.sqlite` in WAL mode. The app opens it read-only via `DatabaseQueue`; SQLite always looks for a `.wal` file if the header says WAL mode, even on readonly connections. Before bundling, run: `sqlite3 jmdict.sqlite "PRAGMA journal_mode=DELETE;"`. Stored in `Resources/`; copied to Documents on first launch by `QuizDB.copyJMdictIfNeeded()`.
- **Quiz DB**: `quiz.sqlite` created on first launch, local to each device. GRDB.swift for access. Extends the Node.js schema with a `vocab_enrollment` table (see below).
- **Vocab content**: Markdown files synced from a hosted opaque URL. App fetches on startup (or periodically). Format TBD — see open questions below.

#### `vocab_enrollment` table (app-only extension to quiz.sqlite)

```sql
CREATE TABLE vocab_enrollment (
  word_type TEXT NOT NULL,          -- 'jmdict'
  word_id   TEXT NOT NULL,          -- JMDict entry ID
  status    TEXT NOT NULL           -- 'pending' | 'enrolled' | 'known'
    CHECK(status IN ('pending','enrolled','known')),
  updated_at TEXT NOT NULL,         -- ISO 8601 UTC
  PRIMARY KEY (word_type, word_id)
);
```

- `pending` — word exists in corpus but user hasn't decided yet (default; row may not exist)
- `enrolled` — user chose "teach me this"; Ebisu models are created and quizzes run
- `known` — user chose "I know this"; never quizzed, never shown in vocab browser again
  (unless user explicitly reviews their "known" list)

The existing `ebisu_models` table is only populated for `enrolled` words. The quiz context
query filters to `enrolled` only.

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

**Principle: give the LLM only what it needs.** Send the minimum context required for
the task — no more. This reduces token burn, latency, and hallucination risk (more
irrelevant context = more surface for the model to go off-track). Concretely: send only
the facet rule for the facet being quizzed, not a table of all facets; send only the
candidate words for pre-selection, not the full corpus; etc.

- **Direct API calls** from the app — no edge worker proxy. Simpler; no server to maintain.
- **API key**: stored in iOS Keychain. Distributed to family via setup deep link (see below).
- **Model**: defaults to `claude-haiku-4-5-20251001` for dev (fast, cheap). Override via `ANTHROPIC_MODEL` env var in the Xcode scheme, or the future Settings screen. Switch to `claude-sonnet-4-6` for production TestFlight builds. Add a model picker to the Phase 2 Settings screen so it's runtime-configurable without a rebuild.
- **Tool use for JMdict**: Claude is given a `lookup_jmdict` tool. When generating or validating questions, Claude can call it to get dictionary-accurate readings and meanings. App handles the tool call by querying local SQLite and returning the result.
- **Two-call question validation** (from `TODO.md`): generate question (call 1), validate that answer form isn't leaked into the stem (call 2, fresh context). Both happen before the question is shown.

### Setup / distribution
- **Setup deep link**: `japanquiz://setup?key=sk-ant-...&vocabUrl=https://...`
  - Registered custom URL scheme in Info.plist
  - Handled with SwiftUI's `.onOpenURL`
  - Key saved to Keychain, URL saved to UserDefaults
  - Distributed via iMessage or AirDrop to family — never needs to be public
  - Mitigation for key exposure: set a monthly usage cap in Anthropic console

### Publishing pipeline (Obsidian → hosted)

Publish step runs locally (`node publish.mjs`, to be written) and produces **two outputs
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
[{
  "id": "1234567",
  "forms": ["怒鳴る", "どなる"],
  "ruby": "<ruby>怒<rt>ど</rt></ruby><ruby>鳴<rt>な</rt></ruby>る",
  "hasKanji": true,
  "meanings": ["to shout at; to yell at"],
  "sourceSentence": "彼は怒鳴った"
}]
```
Used by: vocab browser, enrollment, quiz context. Rendered with pure SwiftUI.

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
1. Find Markdown files with `llm-review: true`
2. Run `check-vocab.mjs` — block on failures
3. Annotate vocab with JmdictFurigana ruby spans
4. Extract `vocab.json` from `<details>` blocks
5. Convert Markdown → `story.html` with vocab span injection; copy/upload images
6. Upload both outputs to host

Vocab in the published files is *comprehensive* (all words a learner might not know),
not just the author's personal unknowns — this is the authoring job of the
`/enrich-vocab` skill (see `TODO.md`)

---

## Open questions

### Content format
**Decided**: two outputs per story — `vocab.json` (SwiftUI) + `story.html` (WKWebView).
See Publishing pipeline above. iOS Markdown rendering is not viable: built-in
`AttributedString` doesn't handle `<ruby>` or `<details>`, and third-party parsers don't
either. WKWebView renders both natively. Story reader is Phase 2; vocab browser uses only
the JSON in Phase 0–1.

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

### Ebisu math in Swift
`predictRecall` and `updateRecall` are ~30 lines of Beta distribution math. Options:
- Port manually (straightforward, no dependency)
- Find a Swift stats library with Beta distribution (e.g. `swift-numerics` doesn't have it;
  would need something like `Surge` or a custom implementation)
- **Lean**: port manually. The math is self-contained.

### Kanji info
`get-kanji-info.mjs` queries kanjidic2. Options for the app:
- Bundle kanjidic2 SQLite alongside JMdict (adds size, enables accurate radical/stroke info)
- Rely on Claude's background knowledge (good enough for N3–N4 content, no extra bundle)
- **Lean**: rely on Claude for MVP; add kanjidic2 bundle later if needed.

### Session state persistence
**Decided**: persist to `quiz_session` table in `quiz.sqlite` (added in migration "v2").
Schema: `position INTEGER PK, word_id TEXT UNIQUE`. Ordering is by `position ASC`.

- `start()` checks `sessionWordIds()`. If non-empty, restores item order (recall probabilities
  recalculated fresh from DB). If empty, runs LLM pre-selection then calls `saveSession(wordIds:)`.
- `recordReview()` calls `removeFromSession(wordId:)` after each graded item.
- `nextQuestion()` calls `clearSession()` when the last item is done.
- `refreshSession()`: clears session, resets state, calls `start()` — wired to "New Session"
  toolbar button in QuizView.

---

## Phases / TODO

### Phase 0 — Vocab browser (enrollment UX)
*The first thing a new user does. Without this, there's nothing to quiz.*

- [ ] Sync Markdown → parse vocab entries from `<details>` blocks
- [ ] Vocab browser UI: stories list → word list per story, each showing word + reading + meaning + source sentence
- [ ] Per-word triage: "I know this" (→ `known`) | "Learn this" (→ `enrolled`, triggers introduction) | dismiss/later (stays `pending`)
- [ ] `vocab_enrollment` table + GRDB model
- [ ] "Known words" review list (so users can un-skip words they change their mind about)
- [ ] Onboarding: prompt new users to browse at least one story before quizzing

### Phase 1 — MVP (quiz works end to end)
- [x] Xcode project setup (SwiftUI, iOS 17+, bundle ID) — project is `AsteroidalDust/`
- [x] Add GRDB.swift via Swift Package Manager (v7+; fixed pbxproj to link product to app target)
- [x] Copy quiz DB schema from `init-quiz-db.mjs`; create on first launch — `Models/QuizDB.swift`
- [x] Bundle `jmdict.sqlite` as app resource; copy to Documents on first launch — `QuizDB.copyJMdictIfNeeded()` (still need to drag file into Xcode Resources)
- [x] Anthropic API client — thin URLSession wrapper around `/v1/messages` — `Claude/AnthropicClient.swift`
- [x] Port Ebisu math (`predictRecall`, `updateRecall`, `defaultModel`, `rescaleHalflife`) to Swift — `Models/EbisuModel.swift`; **635 unit tests passing** (reference test.json + stress tests + smoke tests)
- [x] Tool use handler — `lookup_jmdict(word:)` → query `raws`+`entries` tables → return JSON — `Claude/ToolHandler.swift`
  - Uses `DatabaseQueue` (not Pool) + `readonly: true` to avoid WAL sidecar files on a read-only DB
  - `jmdict.sqlite` **must be in DELETE journal mode** before bundling — run `sqlite3 jmdict.sqlite "PRAGMA journal_mode=DELETE;"` after regenerating; stored in `Resources/`
- [x] Port `get-quiz-context` logic to Swift — `Models/QuizContext.swift`
  - Infers `hasKanji` from which facets exist in `ebisu_models` (no `vocab.json` needed for MVP)
  - Falls back to all words in `ebisu_models` when `vocab_enrollment` is empty (dev/migration mode)
  - Word text sourced from most recent `reviews.word_text` row per word
- [x] Basic quiz UI — `Views/QuizView.swift`; phase state machine: idle → generating → awaitingAnswer → grading → showingResult → finished
- [x] Record review (write to quiz.sqlite after each answer) — in `Claude/QuizSession.swift`
  - Claude grades via `SCORE: X.X` line in response; review + Ebisu model both updated
  - `QuizSession` is `@Observable @MainActor`; two-turn conversation per item (generate → grade)
- [x] LLM pre-selection call — `QuizSession.selectItems(candidates:)` sends all enrolled words as
  context lines (one per word, JS-skill format) and asks Claude to pick 3–5 varied items; falls
  back to top-N by recall if LLM returns < 3 valid IDs or errors
- [x] Session persistence — `quiz_session` table (migration "v2"); resumes on relaunch; cleared
  item-by-item as each answer is graded; `refreshSession()` + "New Session" toolbar button
- [ ] Setup deep link handler (Keychain + UserDefaults) — `App/SetupHandler.swift`
  - For dev: set `ANTHROPIC_API_KEY` in Xcode scheme's Run → Environment Variables
- [ ] Vocab sync: fetch Markdown from hosted URL on app launch

### Maybe someday
- [ ] Bake variety rules into Swift (instead of LLM pre-selection): algorithmic pass over urgency-sorted items — cap at 2 items per facet type, at most 1–2 new words, ensure at least 2 different facets if available. Zero latency, zero tokens. Revisit if LLM pre-selection proves too slow/costly.
- [ ] Pre-filter context for large corpora: when enrolled word count reaches hundreds, send all new
  items plus the top 20–50 most-urgent reviewed items to the LLM pre-selection call rather than
  the full list. Avoids token bloat while keeping the most important candidates visible.

### Phase 2 — Polish
- [ ] Two-call question validation (generate → validate before showing)
- [ ] Teaching / introduction flow for new words
- [ ] Halflife rescaling UI ("too easy" / "too hard" buttons)
- [ ] Session summary screen
- [ ] Mnemonic and etymology sidebars during quiz
- [ ] Publish pipeline script (`publish.mjs`)
- [ ] Settings screen (API key, vocab URL, reviewer name, model picker)

### Phase 3 — Future
- [ ] Grammar points and sentence translation quiz types
- [ ] Kanjidic2 bundle for accurate radical/stroke info
- [ ] Source sentence display on first encounter (Emily's preference)
- [ ] Per-user preferences stored properly (not in a memory file)
- [ ] `kanji_knowledge` table: let users assert kanji they know during enrollment triage;
      use to suppress furigana for known kanji in reading display across all words

---

## File layout

```
AsteroidalDust/                          ← Xcode project root (already created)
  AsteroidalDust.xcodeproj/
  AsteroidalDust/                        ← app source
    AsteroidalDustApp.swift              ← @main entry point (generated)
    ContentView.swift                    ← replace with real nav structure
    Assets.xcassets/
    App/
      SetupHandler.swift                 ← deep link + Keychain (TODO)
    Models/
      QuizDB.swift                       ✓ GRDB setup, migrations (incl. vocab_enrollment)
      EbisuModel.swift                   ✓ predictRecall / updateRecall (635 tests)
      QuizContext.swift                  ✓ get-quiz-context logic (enrolled words only)
      VocabCorpus.swift                  ← parse vocab from JSON; enrollment state (TODO)
      VocabSync.swift                    ← fetch vocab.json from hosted URL (TODO)
    Claude/
      AnthropicClient.swift              ✓ URLSession wrapper, tool-use loop
      ToolHandler.swift                  ✓ lookup_jmdict tool use (DatabaseQueue, readonly)
      QuizSession.swift                  ✓ session orchestration, grading, Ebisu update
    Views/
      HomeView.swift                     ← (TODO)
      VocabBrowserView.swift             ← story list → word list → triage (TODO)
      EnrollmentCardView.swift           ← per-word: know / learn / later (TODO)
      QuizView.swift                     ✓ basic quiz UI (phase state machine)
      AnswerView.swift                   ← (TODO — currently inline in QuizView)
      SettingsView.swift                 ← (TODO)
    Resources/
      jmdict.sqlite                      ✓ bundled (DELETE journal mode — see ToolHandler note)
  AsteroidalDustTests/                   ← Swift Testing unit tests (generated)
    AsteroidalDustTests.swift
  AsteroidalDustUITests/                 ← XCTest UI tests (generated)
    AsteroidalDustUITests.swift
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
