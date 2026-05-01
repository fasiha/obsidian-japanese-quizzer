// KanjiTopUsageSync.swift
// Downloads kanji-top-usage.json from the configured URL and caches it to
// Documents/kanji-top-usage.json.
//
// URL resolution: derives the URL from the vocab URL (substituting
// kanji-top-usage.json for vocab.json), since both files are published to the
// same location by publish.mjs.

import Foundation

// MARK: - Codable types matching kanji-top-usage.json

struct KanjiTopUsageManifest: Codable {
    let generatedAt: String
    /// Keys are single kanji characters; values describe BCCWJ frequency data for that kanji.
    let kanji: [String: KanjiTopUsageEntry]
}

struct KanjiTopUsageEntry: Codable {
    /// Total number of BCCWJ long-unit-word rows whose written form contains this kanji
    /// (i.e., the full count without any LIMIT). Used for "showing N of M" pagination labels.
    let totalMatches: Int
    /// Top words by BCCWJ frequency, sorted by pmw descending. Up to 50 entries.
    let words: [KanjiTopUsageWord]
}

struct KanjiTopUsageWord: Codable {
    /// JMDict entry ID when a match was found; nil when no JMDict entry matched this BCCWJ row.
    let id: String?
    /// Written form from BCCWJ. Present only when id is nil (no JMDict match).
    let kanji: String?
    /// Kana reading from BCCWJ. Present only when id is nil (no JMDict match).
    let reading: String?
    /// Occurrences per million words in the BCCWJ long-unit-word corpus.
    let pmw: Double
}

// MARK: - Sync helpers

enum KanjiTopUsageSync {
    private static let cacheFilename = "kanji-top-usage.json"

    static func resolvedURL() -> URL? { derivedURL(replacing: "kanji-top-usage.json") }

    /// Download kanji-top-usage.json from the resolved URL, decode it, and cache to Documents.
    @discardableResult
    static func sync() async throws -> KanjiTopUsageManifest {
        guard let url = resolvedURL() else {
            throw KanjiTopUsageSyncError.noURLConfigured
        }
        let (data, response) = try await URLSession.shared.data(for: authenticatedRequest(for: url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KanjiTopUsageSyncError.httpError(http.statusCode)
        }
        let manifest = try JSONDecoder().decode(KanjiTopUsageManifest.self, from: data)
        let cacheURL = try cacheFileURL()
        try data.write(to: cacheURL)
        print("[KanjiTopUsageSync] synced \(manifest.kanji.count) kanji entries → \(cacheURL.lastPathComponent)")
        return manifest
    }

    /// Load the cached kanji-top-usage.json from Documents (nil if not yet downloaded).
    static func cached() -> KanjiTopUsageManifest? {
        guard let url = try? cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(KanjiTopUsageManifest.self, from: data)
        else { return nil }
        return manifest
    }

    private static func cacheFileURL() throws -> URL { try documentsURL(filename: cacheFilename) }
}

// MARK: - Errors

enum KanjiTopUsageSyncError: Error, LocalizedError {
    case noURLConfigured
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noURLConfigured:
            return "No vocab URL configured (needed to derive kanji-top-usage.json URL)."
        case .httpError(let code):
            return "Kanji top-usage download failed: HTTP \(code)"
        }
    }
}
