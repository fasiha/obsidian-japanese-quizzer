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
    let references: [String: [VocabReference]]?  // nil for old vocab.json without reference data
    /// Frequency in the BCCWJ corpus (approx. 83 million words), expressed as occurrences per million words.
    /// Absent for words not matched in BCCWJ.
    let bccwjPerMillionWords: Double?

    /// Union of sense indices across all corpus occurrences, sorted and deduplicated.
    /// Empty when no reference has llm_sense data.
    var corpusSenseIndices: [Int] {
        let allRefs = references?.values.flatMap { $0 } ?? []
        return Array(Set(allRefs.compactMap(\.llmSense).flatMap(\.senseIndices))).sorted()
    }
}

/// One occurrence of a word in the source corpus, with surrounding context.
struct VocabReference: Codable {
    let line: Int
    /// Prose paragraph or bullet narration preceding the word's detail block; may contain HTML ruby tags.
    let context: String?
    /// Non-Japanese pedagogical annotation on the word's bullet line (e.g. "[kanji]").
    let narration: String?
    /// LLM-inferred sense(s) this specific occurrence embodies. Absent when not yet determined.
    let llmSense: LlmSense?
    /// Japanese tokens from the annotator's vocab bullet, in order (e.g. ["たきぎ"] or ["もと", "元", "本"]).
    /// Used to derive the preferred kanji form and reading for this occurrence.
    let annotatedForms: [String]?

    private enum CodingKeys: String, CodingKey {
        case line, context, narration
        case llmSense = "llm_sense"
        case annotatedForms = "annotated_forms"
    }
}

/// LLM-inferred sense data stored in vocab.json under the "llm_sense" key.
/// Groups all inferred fields separately from factual word data.
struct LlmSense: Codable {
    /// Zero-based indices into the JMDict sense list for the senses the student is learning.
    /// Empty array means Haiku had insufficient context; iOS app treats it the same as [0].
    let senseIndices: [Int]

    private enum CodingKeys: String, CodingKey {
        case senseIndices = "sense_indices"
    }
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
struct FuriganaSegment: Codable, Equatable {
    let ruby: String
    let rt: String?
}

extension Array where Element == FuriganaSegment {
    /// Returns the distinct kanji characters (CJK Unified Ideographs) from segments that have a
    /// reading annotation (rt != nil). Order is preserved; duplicates are removed.
    func extractKanji() -> [String] {
        var result: [String] = []
        for seg in self where seg.rt != nil {
            for ch in seg.ruby.unicodeScalars {
                if ch.value >= 0x4E00 && ch.value <= 0x9FFF ||
                   ch.value >= 0x3400 && ch.value <= 0x4DBF ||
                   ch.value >= 0xF900 && ch.value <= 0xFAFF {
                    let s = String(ch)
                    if !result.contains(s) { result.append(s) }
                }
            }
        }
        return result
    }
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
        let (data, response) = try await URLSession.shared.data(for: authenticatedRequest(for: url))
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

    private static func cacheFileURL() throws -> URL { try documentsURL(filename: cacheFilename) }
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
