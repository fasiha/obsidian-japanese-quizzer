// QuizContext.swift
// Ranks enrolled vocab words by Ebisu recall probability (lowest = most urgent).
// Mirrors the logic in get-quiz-context.mjs.
//
// For the MVP quiz, word text is sourced from the reviews table (word_text column),
// and hasKanji is inferred from which facets exist in ebisu_models.

import GRDB
import Foundation

// MARK: - Quiz item

/// The status and urgency of one word+facet pair for a quiz session.
enum QuizStatus: Equatable {
    /// Word has an Ebisu model for this facet. recall ∈ [0,1]; isFree = qualifies for free answer.
    case reviewed(recall: Double, isFree: Bool)
    /// Word has Ebisu models for other facets but not this one (e.g. [kanji] tag added later).
    case newFacet(sortRecall: Double)
    /// Word has no Ebisu models at all — full teaching approach.
    case newWord
}

struct QuizItem: Identifiable {
    let id = UUID()
    let wordType: String        // always "jmdict" for now
    let wordId: String
    let wordText: String        // single primary form (first written, or first kana if no written) — used in quiz prompts
    let writtenTexts: [String]  // non-irregular orthographic (kanji/mixed) forms — empty for kana-only words
    let kanaTexts: [String]     // non-irregular kana-only forms
    let hasKanji: Bool          // true → {kanji-ok}: all 4 facets available
    let facet: String           // the most-urgent facet to quiz
    let status: QuizStatus
    let meanings: [String]      // English meanings from jmdict (for pre-selection context lines)

    /// Sort key: reviewed/newFacet by recall ascending, newWord at the end.
    var sortKey: Double {
        switch status {
        case .reviewed(let recall, _): return recall
        case .newFacet(let r):         return r
        case .newWord:                 return Double.infinity
        }
    }
}

// MARK: - Context builder

struct QuizContext {
    static let kanjiOkFacets  = ["kanji-to-reading", "reading-to-meaning", "meaning-to-reading", "meaning-reading-to-kanji"]
    static let noKanjiFacets  = ["reading-to-meaning", "meaning-to-reading"]
    static let kanjiFacetSet  = Set(["kanji-to-reading", "meaning-reading-to-kanji"])

    static let freeAnswerMinReviews  = 3
    static let freeAnswerMinHalflife = 48.0   // hours

    /// Maximum items per quiz sitting (mirrors JS skill's 3–6 range).
    /// Note: "session" in the JS skill means a persisted queue across restarts (not yet in the app).
    static let itemsPerQuiz = 5

    /// Build a ranked list of QuizItems from the DB.
    ///
    /// Enrolled words are those with status = 'enrolled' in vocab_enrollment.
    /// Falls back to all words in ebisu_models if vocab_enrollment is empty (dev/migration mode).
    /// - Parameter jmdict: Optional jmdict DB reader used to fill in word texts missing from reviews.
    static func build(db: QuizDB, jmdict: (any DatabaseReader)? = nil) async throws -> [QuizItem] {
        let records      = try await db.enrolledEbisuRecords()
        var wordTexts    = try await db.wordTexts()
        let reviewCounts = try await db.reviewCounts()

        // Fetch word text, structured forms, and meanings from jmdict.
        var wordMeanings: [String: [String]] = [:]
        var wordForms:    [String: String]   = [:]  // "written:X  reading:Y" context-line string
        var wordWritten:  [String: [String]] = [:]  // orthographic (kanji/mixed) forms
        var wordKana:     [String: [String]] = [:]  // kana-only forms
        if let jmdict {
            let allIds = Array(Set(records.map(\.wordId)))
            let fromJmdict = try await jmdictWordData(ids: allIds, jmdict: jmdict)
            for (id, entry) in fromJmdict {
                if wordTexts[id] == nil { wordTexts[id] = entry.text }
                wordForms[id]    = formsPart(written: entry.writtenTexts, kana: entry.kanaTexts)
                wordMeanings[id] = entry.meanings
                wordWritten[id]  = entry.writtenTexts
                wordKana[id]     = entry.kanaTexts
            }
            print("[QuizContext] fetched jmdict data for \(fromJmdict.count)/\(allIds.count) word(s)")
        }

        // Group by (wordType, wordId)
        var modelsByWord: [String: [EbisuRecord]] = [:]
        for r in records {
            modelsByWord["\(r.wordType)\0\(r.wordId)", default: []].append(r)
        }

        let now = Date()
        var items: [QuizItem] = []

        for (key, wordModels) in modelsByWord {
            let parts = key.split(separator: "\0", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let wordType = String(parts[0])
            let wordId   = String(parts[1])

            // Infer hasKanji: word is {kanji-ok} if any kanji facets exist in the model.
            let hasKanji = wordModels.contains { kanjiFacetSet.contains($0.quizType) }
            let facets = hasKanji ? kanjiOkFacets : noKanjiFacets

            let wordText     = wordTexts[wordId] ?? wordId
            let displayForms = wordForms[wordId] ?? wordText

            // Compute recall for each facet that has a model.
            var recallMap: [String: (recall: Double, halflife: Double)] = [:]
            for record in wordModels {
                let elapsed = max(now.timeIntervalSince(iso8601Date(record.lastReview)), 1e-6) / 3600.0
                let recall  = predictRecall(record.model, tnow: elapsed, exact: true)
                recallMap[record.quizType] = (recall, record.t)
            }

            var unmodeledFacets: [String] = []
            var lowestRecall = Double.infinity
            var lowestFacet: String? = nil

            for facet in facets {
                if let (recall, _) = recallMap[facet] {
                    if recall < lowestRecall { lowestRecall = recall; lowestFacet = facet }
                } else {
                    unmodeledFacets.append(facet)
                }
            }

            let facet: String
            let status: QuizStatus

            if unmodeledFacets.count == facets.count {
                // No facets modeled at all — shouldn't happen for enrolled words, but handle gracefully.
                facet  = facets[0]
                status = .newWord
            } else if !unmodeledFacets.isEmpty {
                facet  = unmodeledFacets[0]
                status = .newFacet(sortRecall: lowestRecall == .infinity ? 0 : lowestRecall)
            } else {
                facet = lowestFacet!
                let (recall, halflife) = recallMap[facet]!
                let reviewCount = reviewCounts["\(wordId)\0\(facet)"] ?? 0
                let isFree = reviewCount >= freeAnswerMinReviews && halflife >= freeAnswerMinHalflife
                status = .reviewed(recall: recall, isFree: isFree)
            }

            items.append(QuizItem(
                wordType: wordType, wordId: wordId, wordText: wordText,
                writtenTexts: wordWritten[wordId] ?? [],
                kanaTexts: wordKana[wordId] ?? [],
                hasKanji: hasKanji, facet: facet, status: status,
                meanings: wordMeanings[wordId] ?? []))
        }

        items.sort { $0.sortKey < $1.sortKey }
        return items   // caller (QuizSession.selectItems) decides how many to use
    }

    private struct JmdictEntry {
        let text: String            // first written form, or first kana if no written (for quiz prompts)
        let writtenTexts: [String]  // non-irregular orthographic (kanji/mixed) forms
        let kanaTexts: [String]     // non-irregular kana-only forms
        let meanings: [String]      // English glosses from all senses
    }

    /// Build the "written:X,Y  reading:A,B" (or "reading:A,B") forms portion of a context line.
    /// "written:" = orthographic (kanji/mixed) forms; "reading:" = kana-only forms.
    /// Mirrors wordFormsPart() in shared.mjs.
    static func formsPart(written: [String], kana: [String]) -> String {
        if !written.isEmpty {
            return "written:\(written.joined(separator: ","))  reading:\(kana.joined(separator: ","))"
        }
        return "reading:\(kana.joined(separator: ","))"
    }

    /// Format a quiz-context line for LLM pre-selection, mirroring the JS skill's quiz-context.txt.
    static func contextLine(for item: QuizItem) -> String {
        let quizTag     = item.hasKanji ? "{kanji-ok}" : "{no-kanji}"
        let formStr     = formsPart(written: item.writtenTexts, kana: item.kanaTexts)
        let meaningsStr = item.meanings.prefix(3).joined(separator: "; ")
        let facetPart: String
        switch item.status {
        case .reviewed(let recall, let isFree):
            facetPart = "→\(item.facet)@\(String(format: "%.2f", recall))" + (isFree ? " free" : "")
        case .newFacet:
            facetPart = "→\(item.facet)@new"
        case .newWord:
            facetPart = "[new]"
        }
        return "\(item.wordId)  \(formStr)  \(quizTag)  \(meaningsStr)  \(facetPart)"
    }

    /// Look up canonical word text and English meanings from jmdict entries.
    private static func jmdictWordData(ids: [String], jmdict: any DatabaseReader) async throws -> [String: JmdictEntry] {
        try await jmdict.read { db in
            var result: [String: JmdictEntry] = [:]
            for id in ids {
                guard let json = try String.fetchOne(db,
                          sql: "SELECT entry_json FROM entries WHERE id = ?", arguments: [id]),
                      let data = json.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                // Filter out irregular kanji (iK) and irregular kana (ik), matching summarizeWord() in shared.mjs.
                let kanjiTexts = (raw["kanji"] as? [[String: Any]] ?? [])
                    .filter { !(($0["tags"] as? [String] ?? []).contains("iK")) }
                    .compactMap { $0["text"] as? String }
                let kanaTexts  = (raw["kana"]  as? [[String: Any]] ?? [])
                    .filter { !(($0["tags"] as? [String] ?? []).contains("ik")) }
                    .compactMap { $0["text"] as? String }
                guard let text = kanjiTexts.first ?? kanaTexts.first else { continue }
                let meanings = (raw["sense"] as? [[String: Any]] ?? []).flatMap { sense in
                    (sense["gloss"] as? [[String: Any]] ?? [])
                        .filter { ($0["lang"] as? String) == "eng" }
                        .compactMap { $0["text"] as? String }
                }
                result[id] = JmdictEntry(text: text, writtenTexts: kanjiTexts, kanaTexts: kanaTexts, meanings: meanings)
            }
            return result
        }
    }

    private static func iso8601Date(_ s: String) -> Date {
        parseISO8601(s) ?? .distantPast
    }
}

// MARK: - ISO 8601 parsing

/// Parse an ISO 8601 date, supporting both with and without fractional seconds.
/// Node.js `new Date().toISOString()` includes milliseconds (e.g. "2026-03-04T12:34:56.789Z"),
/// which iOS's default ISO8601DateFormatter cannot parse. Trying with .withFractionalSeconds
/// handles those. Returns nil (not now!) on failure so callers can treat stale records as urgent.
func parseISO8601(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions.insert(.withFractionalSeconds)
    return f.date(from: s)
}

// MARK: - QuizDB extensions for quiz context

extension QuizDB {
    /// The most recent word_text per word_id across all jmdict reviews.
    func wordTexts() async throws -> [String: String] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT word_id, word_text
                FROM reviews
                WHERE word_type = 'jmdict'
                  AND id IN (
                      SELECT MAX(id) FROM reviews
                      WHERE word_type = 'jmdict'
                      GROUP BY word_id
                  )
                """)
            return Dictionary(rows.compactMap { row -> (String, String)? in
                guard let id = row["word_id"] as? String,
                      let text = row["word_text"] as? String else { return nil }
                return (id, text)
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Review counts per "wordId\0quizType" for jmdict words.
    func reviewCounts() async throws -> [String: Int] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT word_id, quiz_type, COUNT(*) as count
                FROM reviews
                WHERE word_type = 'jmdict'
                GROUP BY word_id, quiz_type
                """)
            var result: [String: Int] = [:]
            for row in rows {
                guard let id = row["word_id"] as? String,
                      let qt = row["quiz_type"] as? String,
                      let count = row["count"] as? Int else { continue }
                result["\(id)\0\(qt)"] = count
            }
            return result
        }
    }
}
