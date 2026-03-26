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

- [ ] Create `CorpusSync.swift` (in `Models/`): download `corpus.json` from the
  derived URL (replace `vocab.json` → `corpus.json`, same pattern as
  `GrammarSync`), decode into `[CorpusEntry]`, persist to a local JSON cache.
- [ ] `CorpusEntry`: `title: String`, `markdown: String`, `vocabCount: Int`,
  `grammarCount: Int`.
- [ ] Expose corpus through the app's existing state-passing pattern
  (HomeView → DocumentBrowserView).
- [ ] Hook `CorpusSync.download()` into the existing "Re-download" action in
  `BrowserToolbarMenu` (alongside the existing vocab/grammar/transitive-pairs
  re-downloads).

### Phase 3 — iOS navigation: move History, add Reader tab

- [ ] In `HomeView.swift`: remove the History `TabView` tab; add a Reader tab
  (showing `DocumentBrowserView`).
- [ ] In `BrowserToolbarMenu.swift`: add a "History" button that opens
  `HistoryView` as a sheet. Thread `client` through (`db` already present).
- [ ] Update `VocabBrowserView` and `GrammarBrowserView` call sites to pass
  `client` into `BrowserToolbarMenu`.

### Phase 4 — DocumentBrowserView

- [ ] Create `DocumentBrowserView.swift`: DisclosureGroups mirroring the
  `/`-delimited title hierarchy. Each leaf shows title + vocab/grammar counts.
  Tap to navigate to `DocumentReaderView`.
- [ ] Show a loading/empty state when `corpus.json` has not yet been fetched,
  with a "Download" button that triggers `CorpusSync`.

### Phase 5 — DocumentReaderView

- [ ] Create `DocumentReaderView.swift`: takes a `CorpusEntry` plus inverted
  annotation maps from `VocabCorpus` and `GrammarCorpus`.
- [ ] **Inverted map** (built once at load time, passed in):
  `[String: [Int: [String]]]` — `title → lineNumber → [wordId]`, and same for
  grammar topic IDs.
- [ ] **Parser**: split raw Markdown on newlines, retaining original 1-based
  line numbers. Skip YAML frontmatter (lines 1 through closing `---`). Then
  scan line by line:
  - Lines matching `<details>…</details>` (single-line) → discard.
  - Lines starting with `<details>` (multi-line) → discard through `</details>`.
  - All other lines → renderable, keyed by their original line number.
- [ ] For each renderable line, render via Markdownosaur's `AttributedString`
  API. If the inverted map has entries for that line number, show a
  `DisclosureGroup` (collapsed by default) below it:
  - **Vocab chip**: furigana form + first gloss truncated. Tapping opens
    `WordDetailSheet`.
  - **Grammar chip**: topic slug + equivalence-group summary truncated. Tapping
    opens `GrammarDetailSheet`.

### Phase 6 — Polish and docs

- [ ] Update `README.md` and `App.md` with the Reader feature description.
- [ ] Confirm `TESTING.md` needs no changes (no new quiz logic).
- [ ] Manual smoke-test: publish a fresh gist, set up on device, open Reader.

---

## Notes / constraints

- Claude never writes directly to SQLite or to the user's Markdown content.
- `Markdownosaur` is already in the project — no new dependencies needed.
- Stripping `<details>` must not affect lines that contain no annotations.
  Plain lines pass straight through to Markdownosaur unchanged.
- Partial kanji display in the reader is a nice-to-have for a later iteration.
