// CorpusSync.swift
// Downloads corpus.json from the configured URL and caches it to Documents/corpus.json.
//
// URL resolution: derives the corpus URL from the vocab URL (substituting corpus.json for
// vocab.json), since both files are published to the same GitHub repo by publish.mjs. Falls back
// to a CORPUS_URL environment variable for overrides or standalone testing.

import Foundation

// MARK: - Codable types matching corpus.json

/// One document entry as stored in corpus.json.
/// Counts are pre-computed server-side by prepare-publish.mjs.
struct CorpusEntry: Codable, Hashable {
    let title: String           // e.g. "Genki 1/L11" or "nhk-easy"
    let markdown: String        // full Markdown source of the document
    let vocabCount: Int         // number of vocab annotations in this document
    let grammarCount: Int       // number of grammar annotations in this document
}

/// Wrapper object for corpus.json (introduced when image support was added).
/// The `images` key is absent in older cached files — treated as empty.
struct CorpusManifest: Codable {
    let images: [CorpusImageEntry]?
    let entries: [CorpusEntry]
}

/// One image that was published alongside the corpus, at its repo-relative path.
struct CorpusImageEntry: Codable {
    let repoPath: String    // e.g. "doc-name/1-usagi.jpg"
    let localPath: String   // absolute local path at publish time (not used by iOS)
}

/// Navigation target for deep-linking from a detail sheet into DocumentReaderView.
/// Carries the corpus entry to open and the line number to scroll to.
struct ReaderTarget: Identifiable, Hashable {
    let entry: CorpusEntry
    let lineNumber: Int
    var id: String { "\(entry.title):\(lineNumber)" }
}

// MARK: - Sync helpers

enum CorpusSync {
    private static let cacheFilename = "corpus.json"

    /// Resolve the corpus download URL.
    /// Priority:
    ///   1. Derive from vocab URL (replace "vocab.json" with "corpus.json")
    ///   2. CORPUS_URL environment variable
    static func resolvedURL() -> URL? { derivedURL(replacing: "corpus.json", fallbackEnvVar: "CORPUS_URL") }

    /// Download corpus.json from the resolved URL, decode it, and cache to Documents.
    /// Throws `CorpusSyncError.noURLConfigured` if no URL can be derived.
    @discardableResult
    static func download() async throws -> [CorpusEntry] {
        return try await downloadManifest().entries
    }

    /// Download corpus.json and return the full manifest (entries + images).
    @discardableResult
    static func downloadManifest() async throws -> CorpusManifest {
        guard let url = resolvedURL() else {
            throw CorpusSyncError.noURLConfigured
        }
        let (data, response) = try await URLSession.shared.data(for: authenticatedRequest(for: url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CorpusSyncError.httpError(http.statusCode)
        }
        let manifest = try decodeManifest(from: data)
        let cacheURL = try cacheFileURL()
        try data.write(to: cacheURL)
        print("[CorpusSync] synced \(manifest.entries.count) document(s), \(manifest.images?.count ?? 0) image(s) → \(cacheURL.lastPathComponent)")
        return manifest
    }

    /// Load the cached corpus.json from Documents (empty array if not yet downloaded).
    static func cached() -> [CorpusEntry] {
        return cachedManifest().entries
    }

    /// Load the cached corpus.json as a full manifest.
    static func cachedManifest() -> CorpusManifest {
        guard let url = try? cacheFileURL(),
              let data = try? Data(contentsOf: url)
        else { return CorpusManifest(images: nil, entries: []) }
        return (try? decodeManifest(from: data)) ?? CorpusManifest(images: nil, entries: [])
    }

    /// Decode corpus manifest from data, accepting both the new wrapper format
    /// `{ "images": […], "entries": […] }` and the legacy bare-array format `[…]`.
    private static func decodeManifest(from data: Data) throws -> CorpusManifest {
        if let manifest = try? JSONDecoder().decode(CorpusManifest.self, from: data) {
            return manifest
        }
        let entries = try JSONDecoder().decode([CorpusEntry].self, from: data)
        return CorpusManifest(images: nil, entries: entries)
    }

    private static func cacheFileURL() throws -> URL { try documentsURL(filename: cacheFilename) }
}

// MARK: - Errors

enum CorpusSyncError: Error, LocalizedError {
    case noURLConfigured
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noURLConfigured:
            return "No corpus URL could be derived. Ensure vocab URL is configured (japanquiz://setup deep link or VOCAB_URL environment variable) or set CORPUS_URL explicitly."
        case .httpError(let code):
            return "Corpus download failed: HTTP \(code)"
        }
    }
}
