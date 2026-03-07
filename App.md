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
- **Per-user enrollment**: each word in the corpus is in one of three states for each
  learner: `pending` (not yet decided), `enrolled` (actively learning via Ebisu),
  `known` (skipped — "I already know this"). Only `enrolled` words appear in quizzes.

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
  - **WAL mode caveat**: `better-sqlite3` may leave `jmdict.sqlite` in WAL mode. The app opens it read-only via `DatabaseQueue`; SQLite always looks for a `.wal` file if the header says WAL mode, even on readonly connections. Before bundling, run: `sqlite3 jmdict.sqlite "PRAGMA journal_mode=DELETE;"`. Stored in `Resources/`; copied to Documents on first launch by `QuizDB.copyJMdictIfNeeded()`.
- **Quiz DB**: `quiz.sqlite` created on first launch, local to each device. GRDB.swift for access. Extends the Node.js schema with a `vocab_enrollment` table (see below).
- **Vocab content**: Markdown files synced from a hosted opaque URL. App fetches on startup (or periodically). Format TBD — see open questions below.

#### `vocab_enrollment` table (app-only extension to quiz.sqlite)

```sql
CREATE TABLE vocab_enrollment (
  word_type TEXT NOT NULL,          -- 'jmdict'
  word_id   TEXT NOT NULL,          -- JMDict entry ID
  status    TEXT NOT NULL           -- 'learning' | 'known'
    CHECK(status IN ('learning','known')),
  kanji_ok  INTEGER NOT NULL DEFAULT 0,  -- 1 = user committed to kanji facets
  updated_at TEXT NOT NULL,         -- ISO 8601 UTC
  PRIMARY KEY (word_type, word_id)
);
```

- **No row** — word exists in corpus but user hasn't decided yet ("not yet learned"). This is the
  default; absence from the table is the representation, not a stored value.
- `learning` — user committed to learning this word; Ebisu models exist and quizzes run.
  `kanji_ok=1` means all 4 facets (including kanji-to-reading and meaning-reading-to-kanji);
  `kanji_ok=0` means 2 facets only (reading-to-meaning, meaning-to-reading).
- `known` — user chose "I know this"; never quizzed. Ebisu models are archived to `model_events`
  and deleted from `ebisu_models` when this status is set.

`ebisu_models` is only populated for `learning` words. The quiz context query filters to `learning`
only. "Unlearning" a word deletes its enrollment row and archives its Ebisu models.

**Migration note (v3)**: recreated table to add `kanji_ok`, rename `enrolled`→`learning`, and drop
`pending` rows. Partial Ebisu facets were backfilled with α=β=1.25, t=24h using the oldest existing
facet's timestamp.

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
- **Model**: defaults to `claude-haiku-4-5-20251001` for dev (fast, cheap). Override via `ANTHROPIC_MODEL` env var in the Xcode scheme, or the future Settings screen. Switch to `claude-sonnet-4-6` for production TestFlight builds. Add a model picker to the Phase 2 Settings screen so it's runtime-configurable without a rebuild.
- **Tools available during a quiz item** (`Claude/ToolHandler.swift`):
  - `lookup_jmdict` — query local `jmdict.sqlite` for dictionary-accurate readings and
    meanings. Claude calls this during question generation or when the student asks about
    a word's readings/meanings.
  - `lookup_kanjidic` — query local `kanjidic2.sqlite` for per-kanji breakdown: stroke
    count, JLPT level, school grade, on/kun readings, English meanings. Input is any
    string — non-kanji characters are skipped. Claude calls this when the student asks
    about a kanji's composition, readings, or mnemonics.
  - `get_vocab_context` — returns the student's full enrolled word list with recall
    probabilities (same format as the pre-selection context lines). Claude calls this when
    the student's message is about a different word they're studying, or when knowing
    their broader learning context would help — e.g. "yes, that kanji also appears in
    怒鳴る, which you'll see soon at recall 0.18."
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
  **Decision: option 3.** `systemPrompt(for:item)` should include a line like
  `Current memory state: recall=0.73, halflife=96h` for the word currently being quizzed.
  Requires `halflife` on `QuizItem` (add to `QuizStatus.reviewed`; it's already computed in
  `QuizContext.build()` at `recallMap[quizType] = (recall, record.t)` but not propagated).
  Implemented: `QuizStatus.reviewed` now carries `halflife`; `systemPrompt(for:item)` emits
  `Current memory state: recall=X.XX, halflife=Xh` for reviewed words.

- **Quiz conversation model** (`Claude/QuizSession.swift`):
  - Phase: `generating` → `chatting` (single open phase, no forced two-step).
  - Claude generates the initial question (may call `lookup_jmdict`); shown as the first
    chat bubble. Student sends any message — answer, question, tangent.
  - Claude responds, calls tools as needed. When it detects a clear answer, it grades and
    appends `SCORE: X.X` (0.0–1.0); the app parses this to record the Ebisu review.
  - Conversation continues freely after grading. "Next Question →" appears; "Skip →" is
    always available.
  - Each item starts with a clean context (`conversation = []`). No cross-item memory.
- **Two-call question validation** ✓: generate question (call 1), then a second call
  with a fresh context window checks whether the question stem leaks the answer form.
  Both happen before the student sees the question. Up to 2 generation attempts total.
  Additionally, a `---QUIZ---` sentinel is required in the response: everything before
  the sentinel (model preamble / reasoning) is stripped, and the prompt prohibits any
  content after the question, defending against both preamble leakage and trailing notes
  that expose the correct answer. Implemented in
  `generateQuestion()` / `extractQuestion(from:)` / `validateQuestion(_:for:)`.
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
  "words": [{ "id": "1234567", "sources": ["分章読解3"] }]
}
```
`forms`, `meanings`, and `hasKanji` are intentionally omitted — all derivable from the
bundled `jmdict.sqlite` or left to per-user enrollment triage. The only publish-time
data that can't be derived is which JMDict IDs are in the corpus and which stories they
come from. Used by: vocab browser, enrollment. Rendered with pure SwiftUI.

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
3. Extract `vocab.json` from `<details>` blocks → write to project root ✓ (`prepare-publish.mjs`)
4. Push `vocab.json` to GitHub secret Gist via `git` over SSH ✓ (`publish.mjs`)
5. Annotate vocab with JmdictFurigana ruby spans (Phase 2+)
6. Convert Markdown → `story.html` with vocab span injection; copy/upload images (Phase 2+)

**Still needed before first run**: add `title:` to the YAML frontmatter of each enrolled Markdown file.

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
`get-kanji-info.mjs` queries kanjidic2. The iOS app bundles `kanjidic2.sqlite` and exposes a
`lookup_kanjidic` tool to Claude (available in both quiz chat and word-explore chat):
- Input: any string — non-kanji characters are ignored; e.g. `怒鳴る` → info for 怒 and 鳴
- Output: JSON array, one entry per kanji: `literal`, `radicals`, `strokes`, `jlpt` (N-string), `grade`, `on`, `kun`, `meanings`
- Radical data (kradfile) is baked into `kanjidic2.sqlite` at build time as a `radicals TEXT` column (JSON array)
  - `get-kanji-info.mjs` populates it during the initial build; existing DBs are migrated on next run
  - iOS tool reads it directly — no separate kradfile bundle needed
- Bundled in `Resources/kanjidic2.sqlite` (DELETE journal mode, same requirement as jmdict.sqlite)
- Copied to Documents on first launch by `QuizDB.copyKanjidicIfNeeded()` (called in `setup()`)
- ToolHandler opens it read-only as a `DatabaseQueue`; stored as optional so a missing file degrades gracefully

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
```

Same steps apply to `jmdict.sqlite` (see `README.md` for the full jmdict build procedure).

### Session state persistence
**Decided**: persist to `quiz_session` table in `quiz.sqlite` (added in migration "v2").
Schema: `position INTEGER PK, word_id TEXT UNIQUE`. Ordering is by `position ASC`.

- `start()` checks `sessionWordIds()`. If non-empty, restores item order (recall probabilities
  recalculated fresh from DB). If empty, runs LLM pre-selection then calls `saveSession(wordIds:)`.
- `recordReview()` calls `removeFromSession(wordId:)` when grading is detected (`SCORE: X.X`).
  Grading happens organically within the open chat — not at a forced submit step.
- `nextQuestion()` calls `clearSession()` when the last item is done.
- `refreshSession()`: clears session, resets state, calls `start()` — wired to "New Session"
  toolbar button in QuizView.
- The in-memory conversation (`conversation: [AnthropicMessage]`) is reset per item; it is not
  persisted. On resume, the session word order is restored but each item starts a fresh chat.

---

## Phases / TODO

### Phase 0 — Vocab browser (enrollment UX) ✓ complete
*The first thing a new user does. Without this, there's nothing to quiz.*

- [x] Vocab sync: `Models/VocabSync.swift` downloads `vocab.json` from `vocabUrl` (UserDefaults,
      set by setup deep link) or `VOCAB_URL` (Xcode env var, for dev). Caches to
      `Documents/vocab.json`; "Re-download vocab" in the ··· debug menu forces a fresh fetch.
- [x] Vocab browser UI: `Views/VocabBrowserView.swift` — filterable word list with filter picker
      (Not yet learned / Learning / Learned / All, defaults to Not yet learned). Status badges on
      each row. Swipe left for contextual actions:
      - Not yet learned: "Learn" (green) | "Learned" (blue)
      - Learning: "Learned" (blue) | "Undo" (orange → back to Not yet learned)
      - Learned: "Learn" (green) | "Undo" (orange)
- [x] `vocab_enrollment` table + GRDB model — already in v1 migration in `QuizDB.swift`
- [x] Enrollment: `VocabCorpus.setStatus(.enrolled)` calls `QuizDB.introduceWord()` which writes
      two Ebisu model rows (`reading-to-meaning`, `meaning-to-reading`) with `defaultModel(24h)`.
      Idempotent — skips facets that already exist (handles words enrolled via Node.js quiz).
- [x] Backward compatibility: words with `ebisu_models` rows but no `vocab_enrollment` row
      (introduced via Node.js quiz) are shown as "Learning" in the browser automatically.
- [x] Navigation: `Views/HomeView.swift` — `TabView` with Vocab (books icon) and Quiz tabs.
- [x] Onboarding: `AppRootView` shows `ContentUnavailableView("Setup Required")` if API key or
      vocab URL not yet configured — disappears automatically after setup link is tapped
- [ ] "Not yet learned" list shows all corpus words even after all are triaged — no "done" state

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
  - Infers `hasKanji` from which facets exist in `ebisu_models` (no `vocab.json` needed for MVP)
  - Falls back to all words in `ebisu_models` when `vocab_enrollment` is empty (dev/migration mode)
  - Word text sourced from most recent `reviews.word_text` row per word
- [x] Quiz UI — `Views/QuizView.swift`; open chat model per item: `idle → generating → chatting → finished`
  - Single `chattingView`: chat bubble thread, send input, score badge on grade, Skip/Next button
  - All text in chat is selectable via `SelectableText` (UIViewRepresentable wrapping UITextView,
    reliable long-press word selection + drag handles inside ScrollView)
- [x] Record review (write to quiz.sqlite after each answer) — in `Claude/QuizSession.swift`
  - Claude grades organically within open chat; `SCORE: X.X` anywhere in response triggers record
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
- [x] Teaching / introduction flow for new words — `WordDetailSheet` (swipe Learn or tap row
      in VocabBrowserView; kanji commitment question; all facets initialized atomically).
      `QuizStatus.newWord`/`.newFacet` removed; quiz only sees fully-initialized learning words.
- [x] Halflife rescaling UI ("too easy" / "too hard" buttons)
- [ ] Session summary screen
- [ ] Mnemonic and etymology sidebars during quiz
- [x] Publish pipeline scripts (`prepare-publish.mjs` + `publish.mjs`) — vocab.json to Gist via SSH git push
- [ ] Settings screen (API key, vocab URL, reviewer name, model picker)
- [ ] Context-based questions for ambiguous kana: bare kana like め is ambiguous (目/芽/め-suffix).
  For suffixes, particles, or kana that match multiple common words, allow Claude to use a short
  example sentence as the question stem instead of bare kana (e.g. "In 馬鹿め！, what does め
  express?" rather than "What does め mean?"). Requires softening the rigid "Show ONLY kana"
  rule for reading-to-meaning and letting Claude call lookup_jmdict to detect ambiguity/POS.
  Accumulate real examples before tuning the prompt.

### Phase 3 — Future
- [ ] Grammar points and sentence translation quiz types
- [x] Kanjidic2 bundle (`kanjidic2.sqlite`) + `lookup_kanjidic` tool — stroke/JLPT/grade/on/kun/meanings
- [ ] Source sentence display on first encounter (Emily's preference)
- [ ] Per-user preferences stored properly (not in a memory file)
- [ ] `kanji_knowledge` table: let users assert kanji they know during enrollment triage;
      use to suppress furigana for known kanji in reading display across all words

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
      SetupHandler.swift                 ← deep link + Keychain (TODO)
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
    Views/
      HomeView.swift                     ✓ TabView root: Vocab + Quiz tabs
      VocabBrowserView.swift             ✓ filterable word list, swipe triage, debug re-download
      EnrollmentCardView.swift           ← (future: dedicated per-word card view)
      QuizView.swift                     ✓ basic quiz UI (phase state machine)
      AnswerView.swift                   ← (TODO — currently inline in QuizView)
      SettingsView.swift                 ← (TODO)
    Resources/
      jmdict.sqlite                      ✓ bundled (DELETE journal mode — see ToolHandler note)
      kanjidic2.sqlite                   ✓ bundled (DELETE journal mode same requirement)
  PugTests/                   ← Swift Testing unit tests (generated)
    PugTests.swift
  PugUITests/                 ← XCTest UI tests (generated)
    PugUITests.swift
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
