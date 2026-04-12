// TransitivePairSync.swift
// Downloads transitive-pairs.json from the configured URL and caches it to
// Documents/transitive-pairs.json.
//
// URL resolution: derives the URL from the vocab URL (substituting
// transitive-pairs.json for vocab.json), since both files are published to the
// same Gist by publish.mjs.

import Foundation

// MARK: - Codable types matching transitive-pairs.json

struct TransitivePairDrillEntry: Codable {
    let en: String
    let ja: String
    let jaFurigana: String?
}

struct TransitivePairDrill: Codable {
    let intransitive: TransitivePairDrillEntry
    let transitive: TransitivePairDrillEntry
}

struct TransitivePairMember: Codable {
    let kana: String
    let jmdictId: String
    let kanji: [String]
}

struct TransitivePairExamples: Codable {
    let intransitive: String?
    let transitive: String?
}

struct TransitivePair: Codable, Identifiable {
    let intransitive: TransitivePairMember
    let transitive: TransitivePairMember
    let examples: TransitivePairExamples
    let ambiguousReason: String?
    let drills: [TransitivePairDrill]?

    var id: String { "\(intransitive.jmdictId)-\(transitive.jmdictId)" }
    var isAmbiguous: Bool { ambiguousReason != nil }
}

// MARK: - Sync helpers

enum TransitivePairSync {
    private static let cacheFilename = "transitive-pairs.json"

    /// Resolve the download URL by substituting "transitive-pairs.json" for "vocab.json" in the
    /// vocab URL.
    static func resolvedURL() -> URL? { derivedURL(replacing: "transitive-pairs.json") }

    /// Download transitive-pairs.json from the resolved URL, decode it, and cache to Documents.
    @discardableResult
    static func sync() async throws -> [TransitivePair] {
        guard let url = resolvedURL() else {
            throw TransitivePairSyncError.noURLConfigured
        }
        let (data, response) = try await URLSession.shared.data(for: authenticatedRequest(for: url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TransitivePairSyncError.httpError(http.statusCode)
        }
        let pairs = try JSONDecoder().decode([TransitivePair].self, from: data)
        let cacheURL = try cacheFileURL()
        try data.write(to: cacheURL)
        print("[TransitivePairSync] synced \(pairs.count) pair(s) → \(cacheURL.lastPathComponent)")
        return pairs
    }

    /// Load the cached transitive-pairs.json from Documents (nil if not yet downloaded).
    static func cached() -> [TransitivePair]? {
        guard let url = try? cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let pairs = try? JSONDecoder().decode([TransitivePair].self, from: data)
        else { return nil }
        return pairs
    }

    private static func cacheFileURL() throws -> URL { try documentsURL(filename: cacheFilename) }
}

// MARK: - Errors

enum TransitivePairSyncError: Error, LocalizedError {
    case noURLConfigured
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noURLConfigured:
            return "No transitive-pairs URL could be derived. Ensure vocab URL is configured."
        case .httpError(let code):
            return "Transitive-pairs download failed: HTTP \(code)"
        }
    }
}
