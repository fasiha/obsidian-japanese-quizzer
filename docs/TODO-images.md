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

## Remaining: image rendering

### Step 1 — `prepare-publish.mjs`: collect image references

In the corpus-building loop, scan each story's raw Markdown for image references:

```js
/!\[([^\]]*)\]\(([^)]+)\)/g
```

For each match whose URL is a relative path (does not start with `http`):

1. Resolve the absolute local path relative to the story file's directory.
2. The repo-relative destination path mirrors the story's subdirectory (e.g. `example-1/1-usagi.jpg`).
3. Leave the image reference in the Markdown source **unchanged** — the iOS app resolves the URL at render time.

Change `corpus.json` from a bare array to a wrapper object with an `images` key:

```json
{
  "images": [
    {
      "repoPath": "example-doc/1-usagi.jpg",
      "localPath": "/absolute/path/to/example-doc/1-usagi.jpg"
    }
  ],
  "entries": [ … ]
}
```

### Step 2 — `CorpusSync.swift` + `CorpusStore.swift`: decode new shape

`CorpusSync` currently decodes `corpus.json` as `[CorpusEntry]`. Change to a wrapper:

```swift
struct CorpusManifest: Codable {
    let images: [ImageEntry]?   // nil in old corpus.json — ignored safely
    let entries: [CorpusEntry]
}

struct ImageEntry: Codable {
    let repoPath: String
}
```

`CorpusStore` gains `var baseURL: URL?` — derived from `VocabSync.resolvedURL()` by dropping `vocab.json`. Any view resolves an image as `baseURL?.appendingPathComponent(repoPath)`.

### Step 3 — `MarkdownLineView` + new `ImageLineView`

Add a branch in `MarkdownLineView` before the Markdownosaur fallthrough:

```swift
} else if trimmed.hasPrefix("![") {
    ImageLineView(text: trimmed)
}
```

`ImageLineView` extracts the path from `![alt](path)`, reads `baseURL` from `@Environment(CorpusStore.self)`, and renders with `AsyncImage(urlRequest:)` (iOS 15+) using `authenticatedRequest(for:)`:

```swift
AsyncImage(urlRequest: authenticatedRequest(for: resolvedURL)) { phase in
    switch phase {
    case .success(let image):
        image.resizable().scaledToFit().frame(maxWidth: .infinity)
    case .failure:
        Label("Image unavailable", systemImage: "photo")
    case .empty:
        ProgressView()
    @unknown default:
        EmptyView()
    }
}
```

### Step 4 — end-to-end test

Add `![](1-usagi.jpg)` to Story 1, run `prepare-publish.mjs` + `publish.mjs`, sync in simulator, verify image appears inline.

## Out of scope

- Disk-caching images beyond iOS URLSession's built-in cache.
- Images in grammar detail sheets (`SelectableText` uses Markdownosaur directly — a separate effort).
- Image resizing or compression at publish time.
