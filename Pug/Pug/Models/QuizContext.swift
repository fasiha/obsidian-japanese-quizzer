// QuizContext.swift
// Ranks learning vocab words by Ebisu recall probability (lowest = most urgent).
// Mirrors the logic in get-quiz-context.mjs.
//
// Word text is sourced from the reviews table (word_text column).
// hasKanji is inferred from whether kanji facets exist in ebisu_models.
// All learning words are guaranteed to have a complete set of Ebisu facets
// (enforced by setReadingLearning/setKanjiLearning), so no newWord/newFacet cases needed.

import GRDB
import Foundation

// MARK: - Quiz item

/// The urgency of one word+facet pair for a quiz session.
enum QuizStatus: Equatable {
    /// recall ∈ [0,1]; isFree = qualifies for free answer.
    case reviewed(recall: Double, isFree: Bool, halflife: Double)
}

struct QuizItem: Identifiable {
    let id = UUID()
    let wordType: String        // always "jmdict" for now
    let wordId: String
    let wordText: String        // single primary form (first written, or first kana if no written)
    let writtenTexts: [String]  // non-irregular orthographic (kanji/mixed) forms
    let kanaTexts: [String]     // non-irregular kana-only forms
    let hasKanji: Bool          // true → {kanji-ok}: all 4 facets available
    let facet: String           // the most-urgent facet to quiz
    let status: QuizStatus
    let meanings: [String]      // English meanings from jmdict (for pre-selection context lines)
    /// Kanji chars the user has committed to learning, decoded from word_commitment.kanji_chars.
    /// nil = no partial commitment (learn all or none). Empty array = committed but no kanji chosen.
    let committedKanji: [String]?
    /// Pre-computed template for partial-commitment kanji quizzes.
    /// Uncommitted kanji are replaced by kana readings; committed kanji stay as-is.
    /// e.g. "ふりかえ休日" for 振替休日 when only [休, 日] are committed. nil when N/A.
    let partialKanjiTemplate: String?

    var recall: Double {
        switch status { case .reviewed(let r, _, _): return r }
    }
}

// MARK: - Context builder

struct QuizContext {
    static let kanjiOkFacets  = ["kanji-to-reading", "reading-to-meaning", "meaning-to-reading", "meaning-reading-to-kanji"]
    static let noKanjiFacets  = ["reading-to-meaning", "meaning-to-reading"]
    static let kanjiFacetSet  = Set(["kanji-to-reading", "meaning-reading-to-kanji"])

    static let freeAnswerMinReviews  = 3
    static let freeAnswerMinHalflife = 48.0   // hours

    /// Maximum items per quiz sitting.
    static let itemsPerQuiz = 5

    /// Build a ranked list of QuizItems from the DB.
    ///
    /// Only words with active ebisu_models are included (= "learning" facets).
    /// hasKanji is inferred from whether kanji facets exist in ebisu_models.
    /// - Parameter jmdict: Optional jmdict DB reader used to fill in word texts and forms.
    static func build(db: QuizDB, jmdict: (any DatabaseReader)? = nil) async throws -> [QuizItem] {
        let records        = try await db.enrolledEbisuRecords()
        var wordTexts      = try await db.wordTexts()
        let reviewCounts   = try await db.reviewCounts()
        let commitments    = try await db.allCommitments()

        // Fetch word text, structured forms, and meanings from jmdict.
        var wordMeanings: [String: [String]] = [:]
        var wordWritten:  [String: [String]] = [:]
        var wordKana:     [String: [String]] = [:]
        if let jmdict {
            let allIds = Array(Set(records.map(\.wordId)))
            let fromJmdict = try await jmdictWordData(ids: allIds, jmdict: jmdict)
            for (id, entry) in fromJmdict {
                if wordTexts[id] == nil { wordTexts[id] = entry.text }
                wordMeanings[id] = entry.meanings
                wordWritten[id]  = entry.writtenTexts
                wordKana[id]     = entry.kanaTexts
            }
            print("[QuizContext] fetched jmdict data for \(fromJmdict.count)/\(allIds.count) word(s)")
        }

        // Group by (wordType, wordId).
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

            // hasKanji inferred from whether any kanji facets exist in this word's models.
            let hasKanji = wordModels.contains { kanjiFacetSet.contains($0.quizType) }
            let facets = hasKanji ? kanjiOkFacets : noKanjiFacets

            let wordText = wordTexts[wordId] ?? wordId

            // Compute recall for each facet.
            var recallMap: [String: (recall: Double, halflife: Double)] = [:]
            for record in wordModels {
                let elapsed = max(now.timeIntervalSince(iso8601Date(record.lastReview)), 1e-6) / 3600.0
                recallMap[record.quizType] = (predictRecall(record.model, tnow: elapsed, exact: true), record.t)
            }

            // Pick the most-urgent (lowest-recall) facet among the required set.
            var lowestRecall = Double.infinity
            var lowestFacet: String? = nil
            for facet in facets {
                if let (recall, _) = recallMap[facet], recall < lowestRecall {
                    lowestRecall = recall
                    lowestFacet = facet
                }
            }
            guard let facet = lowestFacet else {
                // Should not happen after v3 migration guarantees complete facets.
                assertionFailure("[QuizContext] \(wordId) has no modeled facets despite being learning")
                continue
            }

            let (recall, halflife) = recallMap[facet]!
            let reviewCount = reviewCounts["\(wordId)\0\(facet)"] ?? 0
            let isFree = reviewCount >= freeAnswerMinReviews && halflife >= freeAnswerMinHalflife
            let status = QuizStatus.reviewed(recall: recall, isFree: isFree, halflife: halflife)

            // Decode committed kanji and build partial-kanji template from furigana.
            let committedKanji: [String]?
            var partialKanjiTemplate: String? = nil
            if let commitment = commitments[wordId], let kc = commitment.kanjiChars,
               let data = kc.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                committedKanji = decoded
                // Build template from furigana: committed kanji stay, uncommitted → kana.
                if let fData = commitment.furigana.data(using: .utf8),
                   let segments = try? JSONDecoder().decode([[String: String]].self, from: fData) {
                    let committedSet = Set(decoded)
                    var template = ""
                    for seg in segments {
                        let ruby = seg["ruby"] ?? ""
                        let rt = seg["rt"]
                        if let rt, !ruby.isEmpty, !committedSet.contains(ruby) {
                            // Uncommitted kanji → replace with kana reading
                            template += rt
                        } else {
                            // Committed kanji, kana-only segment, or no rt → keep as-is
                            template += ruby
                        }
                    }
                    // Only set if there were actual uncommitted kanji replaced.
                    let allKanjiInWord = Set(
                        (wordWritten[wordId]?.first ?? "").unicodeScalars
                            .filter { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) ||
                                      ($0.value >= 0x3400 && $0.value <= 0x4DBF) ||
                                      ($0.value >= 0xF900 && $0.value <= 0xFAFF) }
                            .map { String($0) }
                    )
                    if !allKanjiInWord.subtracting(committedSet).isEmpty {
                        partialKanjiTemplate = template
                    }
                }
            } else {
                committedKanji = nil
            }

            items.append(QuizItem(
                wordType: wordType, wordId: wordId, wordText: wordText,
                writtenTexts: wordWritten[wordId] ?? [],
                kanaTexts: wordKana[wordId] ?? [],
                hasKanji: hasKanji, facet: facet, status: status,
                meanings: wordMeanings[wordId] ?? [],
                committedKanji: committedKanji,
                partialKanjiTemplate: partialKanjiTemplate))
        }

        items.sort { $0.recall < $1.recall }
        return items   // caller (QuizSession.selectItems) decides how many to use
    }

    struct JmdictEntry {
        let text: String
        let writtenTexts: [String]
        let kanaTexts: [String]
        let meanings: [String]
    }

    /// Build the "written:X,Y  reading:A,B" (or "reading:A,B") forms portion of a context line.
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
        case .reviewed(let recall, let isFree, _):
            facetPart = "→\(item.facet)@\(String(format: "%.2f", recall))" + (isFree ? " free" : "")
        }
        return "\(item.wordId)  \(formStr)  \(quizTag)  \(meaningsStr)  \(facetPart)"
    }

    /// Look up canonical word text and English meanings from jmdict entries.
    static func jmdictWordData(ids: [String], jmdict: any DatabaseReader) async throws -> [String: JmdictEntry] {
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
        parseISO8601(s) ?? Date(timeIntervalSinceNow: -60)
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
                      let count = (row["count"] as? Int64).map(Int.init) else { continue }
                result["\(id)\0\(qt)"] = count
            }
            return result
        }
    }

}
