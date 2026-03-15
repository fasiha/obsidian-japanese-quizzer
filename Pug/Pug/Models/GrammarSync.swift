// GrammarSync.swift
// Downloads grammar.json from the configured URL and caches it to Documents/grammar.json.
//
// URL resolution: derives the grammar URL from the vocab URL (substituting grammar.json for
// vocab.json), since both files are published to the same Gist by publish.mjs. Falls back to
// a GRAMMAR_URL environment variable for overrides or standalone testing.

import Foundation

// MARK: - Codable types matching grammar.json

struct GrammarManifest: Codable {
    let generatedAt: String
    let sources: [String: GrammarSourceMeta]
    let topics: [String: GrammarTopic]   // keyed by prefixed ID e.g. "genki:potential-verbs"
}

struct GrammarSourceMeta: Codable {
    let name: String
    let type: String    // "textbook", "online", "book"
}

/// One grammar topic as stored in grammar.json.
struct GrammarTopic: Codable {
    let source: String          // "genki" | "bunpro" | "dbjg"
    let id: String              // local (un-prefixed) slug, e.g. "potential-verbs"
    let titleEn: String         // English title, e.g. "Potential verbs"
    let titleJp: String?        // Japanese title (Bunpro only), e.g. "てならない"
    let level: String           // e.g. "Genki II", "jlptN4"
    let href: String?           // URL to external reference page
    let sources: [String]       // story/textbook sources this topic appears in
    let equivalenceGroup: [String]?  // other prefixed topic IDs in the same equivalence group

    /// The full source-prefixed identifier, e.g. "genki:potential-verbs".
    var prefixedId: String { "\(source):\(id)" }
}

// MARK: - Sync helpers

enum GrammarSync {
    private static let cacheFilename = "grammar.json"

    /// Resolve the grammar download URL.
    /// Priority:
    ///   1. Derive from vocab URL (replace "vocab.json" with "grammar.json")
    ///   2. GRAMMAR_URL environment variable
    static func resolvedURL() -> URL? {
        // Derive from the vocab URL if possible.
        if let vocabURLString = UserDefaults.standard.string(forKey: "vocabUrl"),
           !vocabURLString.isEmpty {
            let grammarString = vocabURLString.replacingOccurrences(of: "vocab.json", with: "grammar.json")
            if let url = URL(string: grammarString), grammarString != vocabURLString { return url }
        }
        if let vocabEnv = ProcessInfo.processInfo.environment["VOCAB_URL"], !vocabEnv.isEmpty {
            let grammarString = vocabEnv.replacingOccurrences(of: "vocab.json", with: "grammar.json")
            if let url = URL(string: grammarString), grammarString != vocabEnv { return url }
        }
        // Fallback: explicit GRAMMAR_URL override.
        if let s = ProcessInfo.processInfo.environment["GRAMMAR_URL"],
           !s.isEmpty, let url = URL(string: s) { return url }
        return nil
    }

    /// Download grammar.json from the resolved URL, decode it, and cache to Documents.
    /// Throws `GrammarSyncError.noURLConfigured` if no URL can be derived.
    @discardableResult
    static func sync() async throws -> GrammarManifest {
        guard let url = resolvedURL() else {
            throw GrammarSyncError.noURLConfigured
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GrammarSyncError.httpError(http.statusCode)
        }
        let manifest = try JSONDecoder().decode(GrammarManifest.self, from: data)
        let cacheURL = try cacheFileURL()
        try data.write(to: cacheURL)
        print("[GrammarSync] synced \(manifest.topics.count) topic(s) → \(cacheURL.lastPathComponent)")
        return manifest
    }

    /// Load the cached grammar.json from Documents (nil if not yet downloaded).
    static func cached() -> GrammarManifest? {
        guard let url = try? cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(GrammarManifest.self, from: data)
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

enum GrammarSyncError: Error, LocalizedError {
    case noURLConfigured
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noURLConfigured:
            return "No grammar URL could be derived. Ensure vocab URL is configured (japanquiz://setup deep link or VOCAB_URL environment variable) or set GRAMMAR_URL explicitly."
        case .httpError(let code):
            return "Grammar download failed: HTTP \(code)"
        }
    }
}
