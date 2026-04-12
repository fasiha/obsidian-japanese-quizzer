# Image support in corpus documents

Goal: authors embed images in their Markdown files (e.g. `![](1-usagi.jpg)`), and those images appear inline in the iOS document reader alongside the text.

## Architecture: private GitHub repo + PAT

Publishing moved from GitHub Gist to a dedicated private repo (`fasiha/pug-files`). Files sit at their natural paths; images will too. Access uses a fine-grained GitHub PAT scoped to that one repo with Contents: read-only permission — more secure than the old secret Gist URL because it can be revoked without changing the repo URL.

Raw file URLs use `raw.githubusercontent.com`:
```
https://raw.githubusercontent.com/fasiha/pug-files/main/vocab.json
https://raw.githubusercontent.com/fasiha/pug-files/main/Bunsho-Dokkai-1nen/1-usagi.jpg
```

Every iOS fetch adds one header:
```
Authorization: Bearer <PAT>
```

The PAT is delivered via `japanquiz://setup` as a new `token` parameter, stored in Keychain alongside the Anthropic API key.

## Done

- **`publish.mjs`** — replaced Gist clone-and-push dance with a persistent checkout of `pug-files` (path from `PUBLISH_REPO_PATH` in `.env`, default `../pug-files`). Copies JSON files and will copy images once `corpus.json` gains the `images` key. Does `git add -A / commit / push`.
- **`make-setup-link.mjs`** — reads `VOCAB_URL_PAT` from `.env`, adds it as a `token` query parameter. Warns (does not error) if absent.
- **`SetupHandler.swift`** — parses `token` from deep link, saves to Keychain under `"vocab-url-pat"`. Keychain helpers refactored to take an `account` parameter. Exposes `resolvedVocabPAT() -> String?` (Keychain first, then `VOCAB_URL_PAT` env var).
- **`SyncHelpers.swift`** — new `authenticatedRequest(for:)` that adds the `Authorization` header when a PAT is configured; no-op if not (safe for local dev or public repos).
- **`VocabSync`**, **`CorpusSync`**, **`GrammarSync`** (×2), **`TransitivePairSync`** — all use `authenticatedRequest(for:)`.
- **`.env`** — `VOCAB_URL` updated to `https://raw.githubusercontent.com/fasiha/pug-files/main/vocab.json`, `VOCAB_URL_PAT` and `PUBLISH_REPO_PATH` added.
- Tested end-to-end in simulator: new setup deep link accepted, sync pulled latest files from private repo successfully.
- **`prepare-publish.mjs`** — corpus-building loop scans each story's Markdown for image references (`/!\[([^\]]*)\]\(([^)]+)\)/g`). Relative paths are resolved to absolute local paths; repo-relative destination paths mirror the story subdirectory. `corpus.json` changed from a bare array to a wrapper object: `{ "images": [...], "entries": [...] }`. Each image entry has `repoPath` (e.g. `"Bunsho-Dokkai-1nen/1-usagi.jpg"`) and `localPath`.
- **`CorpusSync.swift`** — `CorpusManifest` made public; `decodeManifest(from:)` accepts both new wrapper format and legacy bare-array format. New `downloadManifest()` and `cachedManifest()` return the full manifest. `CorpusImageEntry` struct exposed publicly.
- **`CorpusStore.swift`** — gains `var images: [CorpusImageEntry]` populated on sync.
- **`PugApp.swift`** and **`HomeView.swift`** — updated to call `downloadManifest()` / `cachedManifest()` and populate both `corpusStore.entries` and `corpusStore.images`.
- **`DocumentReaderView.swift`** — `MarkdownLineView` branches on lines starting with `![` and renders them via `ImageLineView`. `ImageLineView` extracts the filename from the Markdown line, looks it up in `corpusStore.images` to get the full `repoPath`, resolves against `baseURL`, and fetches with `authenticatedRequest(for:)` via a manual `URLSession` task (SwiftUI's `AsyncImage` does not accept a `URLRequest`). Image renders resizable and full-width; shows a spinner while loading and a "Image unavailable" label on failure.
- End-to-end tested in simulator: image appears inline in document reader.

## Out of scope

- Disk-caching images beyond iOS URLSession's built-in cache.
- Images in grammar detail sheets (`SelectableText` uses Markdownosaur directly — a separate effort).
- Image resizing or compression at publish time.
