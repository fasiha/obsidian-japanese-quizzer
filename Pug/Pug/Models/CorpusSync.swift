// CorpusSync.swift
// Downloads corpus.json from the configured URL and caches it to Documents/corpus.json.
//
// URL resolution: derives the corpus URL from the vocab URL (substituting corpus.json for
// vocab.json), since both files are published to the same Gist by publish.mjs. Falls back to
// a CORPUS_URL environment variable for overrides or standalone testing.

import Foundation

// MARK: - Codable type matching corpus.json

/// One document entry as stored in corpus.json.
/// Counts are pre-computed server-side by prepare-publish.mjs.
struct CorpusEntry: Codable {
    let title: String           // e.g. "Genki 1/L11" or "nhk-easy"
    let markdown: String        // full Markdown source of the document
    let vocabCount: Int         // number of vocab annotations in this document
    let grammarCount: Int       // number of grammar annotations in this document
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
        guard let url = resolvedURL() else {
            throw CorpusSyncError.noURLConfigured
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CorpusSyncError.httpError(http.statusCode)
        }
        let entries = try JSONDecoder().decode([CorpusEntry].self, from: data)
        let cacheURL = try cacheFileURL()
        try data.write(to: cacheURL)
        print("[CorpusSync] synced \(entries.count) document(s) → \(cacheURL.lastPathComponent)")
        return entries
    }

    /// Load the cached corpus.json from Documents (empty array if not yet downloaded).
    static func cached() -> [CorpusEntry] {
        guard let url = try? cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([CorpusEntry].self, from: data)
        else { return [] }
        return entries
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
