// CounterSync.swift
// Downloads counters.json from the configured URL and caches it to
// Documents/counters.json.
//
// URL resolution: derives the URL from the vocab URL (substituting
// counters.json for vocab.json), since both files are published to the
// same Gist by publish.mjs.

import Foundation

// MARK: - Codable types matching counters.json

struct CounterPronunciationCell: Codable {
    let primary: [String]
    let rare: [String]
}

struct CounterJMDictRef: Codable {
    let id: String
    let senseIndex: [Int]?
}

struct Counter: Codable, Identifiable {
    let id: String
    let kanji: String
    let reading: String
    let category: String
    let whatItCounts: String
    let countExamples: [String]
    let jmdict: CounterJMDictRef?
    /// Keys: "1"–"10" and "how-many". Each maps to primary/rare pronunciation lists.
    let pronunciations: [String: CounterPronunciationCell]

    var isMustKnow: Bool {
        category == "Absolutely Must Know" || category == "Must Know"
    }
}

// MARK: - Sync helpers

enum CounterSync {
    private static let cacheFilename = "counters.json"

    /// Resolve the download URL by substituting "counters.json" for "vocab.json" in the
    /// vocab URL.
    static func resolvedURL() -> URL? { derivedURL(replacing: "counters.json") }

    /// Download counters.json from the resolved URL, decode it, and cache to Documents.
    @discardableResult
    static func sync() async throws -> [Counter] {
        guard let url = resolvedURL() else {
            throw CounterSyncError.noURLConfigured
        }
        let (data, response) = try await URLSession.shared.data(for: authenticatedRequest(for: url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CounterSyncError.httpError(http.statusCode)
        }
        let counters = try JSONDecoder().decode([Counter].self, from: data)
        let cacheURL = try cacheFileURL()
        try data.write(to: cacheURL)
        print("[CounterSync] synced \(counters.count) counter(s) → \(cacheURL.lastPathComponent)")
        return counters
    }

    /// Load the cached counters.json from Documents (nil if not yet downloaded).
    static func cached() -> [Counter]? {
        guard let url = try? cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let counters = try? JSONDecoder().decode([Counter].self, from: data)
        else { return nil }
        return counters
    }

    private static func cacheFileURL() throws -> URL { try documentsURL(filename: cacheFilename) }
}

// MARK: - Errors

enum CounterSyncError: Error, LocalizedError {
    case noURLConfigured
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noURLConfigured:
            return "No counters URL could be derived. Ensure vocab URL is configured."
        case .httpError(let code):
            return "Counters download failed: HTTP \(code)"
        }
    }
}
