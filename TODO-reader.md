# Reader feature work plan

## Goal

Add an in-app document reader that shows the Markdown source files the user's
vocab and grammar annotations came from, with collapsible annotation panels
inline below each annotated line.

---

## Decisions made

1. **Annotation lookup** — build an inverted map `(title, lineNumber) → [wordId]`
   and `(title, lineNumber) → [grammarTopicId]` on the iOS side from the existing
   `VocabCorpus` / `GrammarCorpus` data. Each `VocabReference` / grammar
   occurrence already carries a `line` number that now correctly points to the
   sentence line (same line as `context`). Do not parse `<details>` bullet text
   — those tags are stripped and discarded before rendering.

2. **corpus.json shape** — array of objects, counts pre-computed server-side:
   ```json
   [{ "title": "nhk-easy", "markdown": "...", "vocabCount": 9, "grammarCount": 2 }, ...]
   ```

3. **History navigation** — move to a sheet in the `···` menu, same pattern as
   Settings and Debug Info. No tab for it.

4. **`<details>` blocks** — all stripped and discarded before rendering,
   regardless of type (Vocab, Grammar, Translation). Annotations come from the
   inverted map, not from parsing `<details>` content.

5. **Document browser layout** — DisclosureGroups mirroring the `/`-delimited
   title hierarchy (e.g. `Genki 1 > L11, L12, ...`), same approach as
   VocabBrowserView.

6. **Markdown renderer** — use Markdownosaur as-is. Images and other
   unsupported elements simply won't render; that is fine for this corpus.

7. **Re-download** — the existing "Re-download" button in the Vocab and Grammar
   `···` menus will also trigger `CorpusSync`. One tap refreshes everything.

8. **Line-by-line rendering** — each physical Markdown line is its own render
   unit passed to Markdownosaur. No paragraph grouping needed: sentences are
   already one line each in this corpus.

9. **YAML frontmatter** — skip lines from the opening `---` through the closing
   `---` before rendering.

---

## Corpus Markdown format (reference)

`<details>` blocks follow their sentence line immediately. One sentence can have
multiple blocks. Single-line and multi-line variants both exist:

```
Japanese sentence line       ← render this; its line number keys the inverted map
<details><summary>Vocab</summary>
- 予報
</details>
<details><summary>Grammar</summary>- genki:kotoga-aru</details>
<details><summary>Translation</summary>
English text
</details>
```

All `<details>` content is discarded. The `reference.line` in `vocab.json` /
`grammar.json` now points to the sentence line, not the bullet inside `<details>`.

---

## Progress

### ✅ Phase 1 — Server side: bundle corpus.json

- Fixed `extractVocabBullets` in `prepare-publish.mjs`: `line` now points to
  the sentence line (same line as `context`), not the bullet inside `<details>`.
- Fixed grammar occurrences in `prepare-publish.mjs`: same fix, using
  `extractContextBefore`'s returned line number. `shared.mjs` unchanged.
- `extractContextBefore` now returns `{ text, line }` instead of just text.
- Added `corpus.json` generation at end of `prepare-publish.mjs`.
- Added `corpus.json` to `publish.mjs` copy list and `git add`.
- `stories` array in `vocab.json` unchanged (content field stripped before
  serialisation; only used internally for corpus.json generation).
- Result: 13 corpus entries, ~44 KB total markdown, vocab/grammar counts correct.

---

## Remaining tasks

### Phase 2 — iOS data model: CorpusSync

- [x] Create `CorpusSync.swift` (in `Models/`): download `corpus.json` from the
  derived URL (replace `vocab.json` → `corpus.json`, same pattern as
  `GrammarSync`), decode into `[CorpusEntry]`, persist to a local JSON cache.
- [x] `CorpusEntry`: `title: String`, `markdown: String`, `vocabCount: Int`,
  `grammarCount: Int`.
- [x] Expose corpus through the app's existing state-passing pattern
  (HomeView → DocumentBrowserView).
- [x] Hook `CorpusSync.download()` into the existing "Re-download" action in
  `BrowserToolbarMenu` (alongside the existing vocab/grammar/transitive-pairs
  re-downloads).

### Phase 3 — iOS navigation: move History, add Reader tab

- [x] In `HomeView.swift`: remove the History `TabView` tab; add a Reader tab
  (showing `DocumentBrowserView`).
- [x] In `BrowserToolbarMenu.swift`: add a "History" button that opens
  `HistoryView` as a sheet. Thread `client` through (`db` already present).
- [x] Update `VocabBrowserView` and `GrammarBrowserView` call sites to pass
  `client` into `BrowserToolbarMenu`.

### Phase 4 — DocumentBrowserView

- [x] Create `DocumentBrowserView.swift`: DisclosureGroups mirroring the
  `/`-delimited title hierarchy. Each leaf shows title + vocab/grammar counts.
  Tap to navigate to `DocumentReaderView`.
- [x] Show a loading/empty state when `corpus.json` has not yet been fetched,
  with a "Download" button that triggers `CorpusSync`.
- [x] Changed `HomeView.corpusEntries` from `let` to `@Binding` so the Download
  button can update the root state; updated `AppRootView` to pass `$corpusEntries`.
- [x] Added `DocumentReaderView` stub (Phase 5 placeholder).

### Phase 5 — DocumentReaderView

- [x] Create `DocumentReaderView.swift`: takes a `CorpusEntry` plus corpus/
  manifest/db/session; inverted maps are built once on appear.
- [x] **Inverted map**: `[Int: [String]]` per document — `lineNumber → [wordId]`
  and `lineNumber → [prefixedId]`. Built from `VocabItem.references[title]` and
  `GrammarTopic.references?[title]`.
- [x] **Parser** (`parseLines(_:)`): splits on newlines, retains 1-based line
  numbers, skips YAML frontmatter and `<details>` blocks (both single-line and
  multi-line forms).
- [x] **MarkdownLineView**: renders each line via `Markdownosaur` →
  `NSAttributedString` → `AttributedString(_, including: \.uiKit)` → SwiftUI
  `Text`. Empty lines render as a scaled spacer.
- [x] **DisclosureGroup per annotated line** (collapsed by default): vocab chips
  (blue, word + first gloss, opens `WordDetailSheet`) and grammar chips (green,
  titleEn + summary, opens `GrammarDetailSheet`).
- [x] Updated `DocumentBrowserView` to thread `corpus`, `grammarManifest`, `db`,
  `session` through to `DocumentReaderView`.
- [x] Updated `HomeView` to pass those params to `DocumentBrowserView`.

### Phase 6 — Polish and docs

- [x] Updated `README.md`: added "Document reader" section under Quiz formats,
  updated publish pipeline to mention `corpus.json`, updated architecture diagram.
- [x] `App.md` no longer exists; no action needed.
- [x] `TESTING.md` needs no changes (Reader has no new quiz logic).
- [x] Manual smoke-test passed (user confirmed).

### Phase 7 — Deep-link from detail sheets into the reader

**Goal:** corpus-context entries in `WordDetailSheet`, `GrammarDetailSheet`, and
`TransitivePairDetailSheet` become tappable links that open `DocumentReaderView`
scrolled to (and briefly highlighting) the relevant line.

#### Sub-tasks

- [x] **Thread `corpusEntries` and `grammarManifest` into detail sheets.**
  - `WordDetailSheet` already has `corpus` and `session`; add
    `corpusEntries: [CorpusEntry]` and `grammarManifest: GrammarManifest?`.
  - `GrammarDetailSheet` already has `client`; add `corpusEntries`,
    `corpus: VocabCorpus`, and `grammarManifest`.
  - `TransitivePairDetailSheet` already has `client`; add `corpusEntries`,
    `corpus: VocabCorpus`, and `grammarManifest`.
  - Update every call-site that constructs these sheets
    (`DocumentReaderView`, quiz views, anywhere else) to pass the new params.

- [x] **Add navigation destination inside each sheet's `NavigationStack`.**
  Each sheet already wraps its content in a `NavigationStack`. Add a
  `.navigationDestination(item:)` for a `ReaderTarget` value type:
  ```swift
  struct ReaderTarget: Identifiable {
      let entry: CorpusEntry
      let lineNumber: Int
      var id: String { "\(entry.title):\(lineNumber)" }
  }
  ```
  When a corpus-context row is tapped, set `@State var readerTarget: ReaderTarget?`
  and the destination pushes `DocumentReaderView(entry:..., scrollToLine:lineNumber, ...)`.

- [x] **Add `scrollToLine: Int?` parameter to `DocumentReaderView`.**
  On `.onAppear`, if `scrollToLine` is set, use `ScrollViewReader` to call
  `proxy.scrollTo(lineNumber, anchor: .center)`. Wrap in
  `withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut)`
  to respect the reduce-motion accessibility setting.

- [x] **Highlight the target line briefly.**
  Add `@State private var highlightedLine: Int? = nil` to `DocumentReaderView`.
  After scrolling, set `highlightedLine = scrollToLine`, then clear it after
  1.5 s with `Task { try? await Task.sleep(for: .seconds(1.5)); highlightedLine = nil }`.
  In `lineView`, apply `.background(highlightedLine == line.lineNumber ? Color.yellow.opacity(0.35) : Color.clear)`
  with `.animation(.easeOut(duration: 0.6), value: highlightedLine)` so the
  flash fades rather than snapping off. The highlight does not animate *on*
  (it appears instantly) and fades out — this is perceptible but not motion-heavy,
  so no special reduced-motion guard is needed for the fade itself.

- [x] **Make corpus-context rows tappable in each sheet.**
  Replace the plain `SentenceFuriganaView` / `Text` display with a `Button`
  whose action sets `readerTarget`. Keep the existing visual style; add a subtle
  chevron or underline only if it reads naturally (do not over-decorate).

- [x] **Update call-sites** (`DocumentReaderView` already opens `WordDetailSheet`
  and `GrammarDetailSheet` — pass the new params through). Check all other
  places these sheets are presented (quiz result views, vocab/grammar browser
  detail taps) and thread the params there too.

- [ ] **Smoke-test all three sheets** (word, grammar, transitive pair): tap a
  corpus-context entry, confirm the reader opens at the right line with the
  highlight, confirm it works from both the Reader tab and quiz views.

---

## Notes / constraints

- Claude never writes directly to SQLite or to the user's Markdown content.
- `Markdownosaur` is already in the project — no new dependencies needed.
- Stripping `<details>` must not affect lines that contain no annotations.
  Plain lines pass straight through to Markdownosaur unchanged.
- Partial kanji display in the reader is a nice-to-have for a later iteration.
