// VocabSync.swift
// Downloads vocab.json from the configured URL and caches it to Documents/vocab.json.
//
// URL resolution priority:
//   1. UserDefaults "vocabUrl" — set by the japanquiz://setup deep link
//   2. VOCAB_URL environment variable — set in Xcode scheme for dev
//      (Use the full raw Gist URL printed by publish.mjs, e.g.
//       https://gist.githubusercontent.com/<user>/<gist_id>/raw/vocab.json)

import Foundation

// MARK: - Codable types matching vocab.json

struct VocabManifest: Codable {
    let generatedAt: String
    let stories: [VocabStory]
    let words: [VocabWordEntry]
}

struct VocabStory: Codable {
    let title: String
}

struct VocabWordEntry: Codable {
    let id: String
    let sources: [String]
    let writtenForms: [WrittenFormGroup]?  // nil for old vocab.json without furigana data
}

/// One reading and its associated kanji forms (from JmdictFurigana).
struct WrittenFormGroup: Codable {
    let reading: String
    let forms: [WrittenForm]
}

/// A single kanji form with its furigana breakdown.
struct WrittenForm: Codable {
    let furigana: [FuriganaSegment]
    let text: String
}

/// One segment of a furigana breakdown: ruby text with optional reading annotation.
struct FuriganaSegment: Codable {
    let ruby: String
    let rt: String?
}

// MARK: - Sync helpers

enum VocabSync {
    static let userDefaultsKey = "vocabUrl"
    private static let cacheFilename = "vocab.json"

    /// Resolve the vocab download URL from UserDefaults (deep link) or the VOCAB_URL env var.
    static func resolvedURL() -> URL? {
        if let s = UserDefaults.standard.string(forKey: userDefaultsKey),
           !s.isEmpty, let url = URL(string: s) { return url }
        if let s = ProcessInfo.processInfo.environment["VOCAB_URL"],
           !s.isEmpty, let url = URL(string: s) { return url }
        return nil
    }

    /// Download vocab.json from the resolved URL, decode it, and cache to Documents.
    /// Throws `VocabSyncError.noURLConfigured` if no URL is available.
    @discardableResult
    static func sync() async throws -> VocabManifest {
        guard let url = resolvedURL() else {
            throw VocabSyncError.noURLConfigured
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw VocabSyncError.httpError(http.statusCode)
        }
        let manifest = try JSONDecoder().decode(VocabManifest.self, from: data)
        let cacheURL = try cacheFileURL()
        try data.write(to: cacheURL)
        print("[VocabSync] synced \(manifest.words.count) word(s) → \(cacheURL.lastPathComponent)")
        return manifest
    }

    /// Load the cached vocab.json from Documents (nil if not yet downloaded).
    static func cached() -> VocabManifest? {
        guard let url = try? cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(VocabManifest.self, from: data)
        else { return nil }
        return manifest
    }

    private static func cacheFileURL() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return docs.appendingPathComponent(cacheFilename)
    }
}

// MARK: - Errors

enum VocabSyncError: Error, LocalizedError {
    case noURLConfigured
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noURLConfigured:
            return "No vocab URL configured. Set 'vocabUrl' via the japanquiz://setup deep link, or set VOCAB_URL in the Xcode scheme."
        case .httpError(let code):
            return "Vocab download failed: HTTP \(code)"
        }
    }
}
