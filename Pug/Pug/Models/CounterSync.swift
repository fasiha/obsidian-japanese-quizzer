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

    /// One-line description of how 1/6/8/10 mutate this counter's initial consonant.
    /// Always returns a non-empty string so WordDetailSheet can show it unconditionally.
    ///
    /// 8 and 10 are special: for most consonant classes they accept both a fully-mutated
    /// form (はっ+X, じっ+X / じゅっ+X) AND the unmutated form (はち+X). The exception
    /// is p-initial counters, where 8 only produces はっ+p (no はちぱ). The pronunciation
    /// data already encodes this — we show all primaries for 8 so the dual form is visible.
    var rendakuHint: String {
        guard let first = reading.first else { return "No consonant mutation" }
        // h-row (は行), f (ふ), and p-row (ぱ行): initial consonant changes to p
        let hRow: Set<Character> = ["は","ひ","ふ","へ","ほ","ぱ","ぴ","ぷ","ぺ","ぽ"]
        // k-row (か行): initial consonant doubles (gemination)
        let kRow: Set<Character> = ["か","き","く","け","こ"]
        // s/sh-row (さ行) and t/ch-row (た行): initial consonant doubles with 1 only
        let stRow: Set<Character> = ["さ","し","す","せ","そ","た","ち","つ","て","と"]

        let ex1  = pronunciations["1"]?.primary.first ?? ""
        let ex6  = pronunciations["6"]?.primary.first ?? ""
        // Show all primaries for 8: most consonant classes have two valid forms
        // (はっ+X or はち+X), but p-initial counters only have はっ+p.
        let ex8  = pronunciations["8"]?.primary.joined(separator: " or ") ?? ""
        let ex10 = pronunciations["10"]?.primary.joined(separator: " or ") ?? ""

        if hRow.contains(first) {
            // p-initial: 8 only has はっ+p (one form). For other h-row: 8 has two forms.
            let isPRow: Set<Character> = ["ぱ","ぴ","ぷ","ぺ","ぽ"]
            let eightNote = isPRow.contains(first) ? "8:\(ex8) only" : "8:\(ex8)"
            var hint = "Consonant mutation →p with 1, 6, 8, 10 — 1:\(ex1) / 6:\(ex6) / \(eightNote) / 10:\(ex10)"
            // For some h/f-initial counters (e.g. 分), 4 also optionally mutates (よんぷん or よんふん).
            // This is counter-specific, so detect it from the data.
            if let cell4 = pronunciations["4"], cell4.primary.count > 1 {
                hint += " · also 4:\(cell4.primary.joined(separator: " or "))"
            }
            return hint
        }
        if kRow.contains(first) {
            return "Consonant doubling with 1, 6, 8, 10 — 1:\(ex1) / 6:\(ex6) / 8:\(ex8) / 10:\(ex10)"
        }
        if stRow.contains(first) {
            return "Consonant doubling with 1 only — 1:\(ex1)"
        }
        // w-initial (わ): mutation わ→ば can appear with some numbers; behavior varies by counter.
        // Detect from data: show any number where the primary has multiple forms.
        if first == "わ" {
            let mutatingKeys = ["3", "4", "10"].compactMap { key -> String? in
                guard let cell = pronunciations[key], cell.primary.count > 1 else { return nil }
                return "\(key):\(cell.primary.joined(separator: " or "))"
            }
            if mutatingKeys.isEmpty {
                return "No consonant mutation (1, 6, 8, 10 use standard readings)"
            }
            return "Partial わ→ば mutation — \(mutatingKeys.joined(separator: " / "))"
        }
        return "No consonant mutation (1, 6, 8, 10 use standard readings)"
    }

    /// One-line note about which form of 4, 7, and 9 this counter takes.
    /// One-line note about which form of 4, 7, and 9 this counter takes.
    /// Always returns a non-empty string. Prefixed with a bucket label:
    ///   "Modern"           — all three primaries are よん/なな/きゅう, no rare forms
    ///   "Mostly modern"    — primaries are modern but at least one has rare forms
    ///   "Classical+Modern" — at least one primary is classical (し/よ(non-よん)/しち/く)
    var classicalNumberHint: String {
        func primaryStr(_ key: String) -> String {
            pronunciations[key]?.primary.joined(separator: "/") ?? "?"
        }
        func hasRare(_ key: String) -> Bool {
            !(pronunciations[key]?.rare.isEmpty ?? true)
        }
        func isClassical4() -> Bool {
            guard let p = pronunciations["4"]?.primary.first else { return false }
            return p.hasPrefix("し") || (p.hasPrefix("よ") && !p.hasPrefix("よん"))
        }
        func isClassical7() -> Bool {
            pronunciations["7"]?.primary.first?.hasPrefix("しち") == true
        }
        func isClassical9() -> Bool {
            pronunciations["9"]?.primary.first?.hasPrefix("く") == true
        }

        let detail = "4: \(primaryStr("4")) · 7: \(primaryStr("7")) · 9: \(primaryStr("9"))"
        let anyClassical = isClassical4() || isClassical7() || isClassical9()
        let anyRare = hasRare("4") || hasRare("7") || hasRare("9")

        let label: String
        if anyClassical {
            label = "Classical+Modern"
        } else if anyRare {
            label = "Mostly modern"
        } else {
            label = "Modern"
        }
        return "\(label) (\(detail))"
    }

    /// Numbers that are non-obvious to quiz for this counter (rendaku set plus classical
    /// alternates for 4, 7, 9).
    var quizNumbers: [String] {
        var base = ["1", "3", "4", "6", "7", "8", "10"]
        if pronunciations["9"]?.primary.first?.hasPrefix("く") == true {
            base.append("9")
        }
        return base
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
