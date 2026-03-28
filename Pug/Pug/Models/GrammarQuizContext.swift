// GrammarQuizContext.swift
// Ranks enrolled grammar topics by Ebisu recall probability (lowest = most urgent).
// Parallel to QuizContext.swift for vocabulary.
//
// Grammar topics use word_type = 'grammar' in the shared ebisu_models and reviews tables.
// Two facets per topic: 'production' and 'recognition'.
// Scaffolding topics are the subset the student knows well — used in system prompts
// to calibrate difficulty of generated example sentences.

import GRDB
import Foundation

extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Extra topic entry

/// A grammar topic the student already knows well, used to calibrate quiz difficulty.
/// Claude incorporates these patterns into generated example sentences.
struct GrammarExtraTopic {
    let topicId: String     // full prefixed ID, e.g. "bunpro:causative"
    let titleEn: String     // English title, e.g. "To make/let/have"
    let summary: String?    // one-paragraph description from grammar-equivalences.json (optional)
}

// MARK: - Grammar quiz item

/// One grammar topic + facet pair for a quiz session.
struct GrammarQuizItem: Identifiable {
    let id = UUID()
    let topicId: String             // full prefixed ID, e.g. "genki:potential-verbs"
    let titleEn: String             // English title
    let titleJp: String?            // Japanese title (Bunpro only)
    let level: String               // e.g. "Genki II", "jlptN4"
    let href: String?               // URL to external reference
    let source: String              // "genki" | "bunpro" | "dbjg"
    let equivalenceGroupIds: [String]   // other prefixed IDs in the same equivalence group
    let facet: String               // "production" | "recognition"
    let status: QuizStatus
    /// Grammar topics the student knows well — injected into the system prompt for difficulty scaling.
    let extraGrammarTopics: [GrammarExtraTopic]
    /// Quiz format tier.
    /// Production: 1 = multiple choice, 2 = fill-in-the-blank (typed, string-match graded),
    ///             3 = free text (LLM graded with SCORE).
    /// Recognition: 1 = multiple choice, 2 = free text (LLM graded with SCORE).
    let tier: Int

    // Description fields from grammar-equivalences.json (nil when not yet synced or unavailable).
    let summary: String?
    let subUses: [String]?
    let cautions: [String]?
    let isStub: Bool?
    /// Recent review notes for this topic+facet (from reviews.notes). Used by generation
    /// prompts to avoid repeating the same sub-use across consecutive quiz sessions.
    let recentNotes: [String]

    var recall: Double {
        switch status { case .reviewed(let r, _, _): return r }
    }

    /// True when the item uses LLM-scored free-text grading (SCORE token).
    /// Production tier 3 and recognition tier 2 and above.
    var isFreeAnswer: Bool {
        switch facet {
        case "production":  return tier >= 3
        default:            return tier >= 2
        }
    }
}

// MARK: - Context builder

struct GrammarQuizContext {
    static let grammarFacets = ["production", "recognition"]

    /// Tier-2 thresholds (production fill-in-the-blank; recognition free text). DISABLED FOR NOW.
    static let tier2MinReviews  = 33333333
    static let tier2MinHalflife = 72.0      // hours

    /// Tier-3 threshold (production free text only). Higher bar because open production is harder. DISABLED FOR NOW.
    static let tier3MinReviews  = 66666666
    static let tier3MinHalflife = 120.0     // hours

    // Backward-compatible alias used by existing code outside this file.
    static var freeAnswerMinReviews:  Int    { tier2MinReviews }
    static var freeAnswerMinHalflife: Double { tier2MinHalflife }

    /// Number of top-urgency candidates to sample from when building a session.
    static let selectionPoolSize = 10
    static let minItemsPerQuiz = 3
    static let maxItemsPerQuiz = 5

    /// Build a ranked list of GrammarQuizItems from the DB and grammar manifest.
    ///
    /// Only topics with active ebisu_models rows (word_type='grammar') are included.
    /// Items are sorted by ascending recall probability (most urgent first).
    static func build(db: QuizDB, manifest: GrammarManifest) async throws -> [GrammarQuizItem] {
        let records   = try await db.enrolledGrammarRecords()
        let counts    = try await db.grammarReviewCounts()
        let allNotes  = try await db.grammarAllRecentNotes()
        let now       = Date()

        // Group records by topic ID, tracking facets.
        var byTopic: [String: [EbisuRecord]] = [:]
        for r in records {
            byTopic[r.wordId, default: []].append(r)
        }

        // Extra grammar scaffolding is disabled for Haiku — testing showed it never uses the
        // list and the prompt bloat (2× tokens) provides no benefit. Re-enable if generation
        // model is upgraded to Sonnet or above (see TODO-grammar.md 2026-03-16 note).
        let extraGrammarTopics: [GrammarExtraTopic] = []

        // Build quiz items — one per topic+facet pair.
        var items: [GrammarQuizItem] = []
        for (topicId, facetRecords) in byTopic {
            guard let topic = manifest.topics[topicId] else {
                print("[GrammarQuizContext] topic \(topicId) in ebisu_models but not in manifest — skipping")
                continue
            }

            for r in facetRecords {
                guard grammarFacets.contains(r.quizType) else { continue }

                guard let lastDate = parseISO8601(r.lastReview) else { continue }
                let elapsed = now.timeIntervalSince(lastDate) / 3600.0
                let recall  = predictRecall(r.model, tnow: elapsed, exact: true)

                let reviewCount = counts["\(topicId):\(r.quizType)"] ?? 0

                // Compute tier based on facet, review count, and halflife.
                // Production: 1 → 2 (fill-in-the-blank) → 3 (free text).
                // Recognition: 1 → 2 (free text).
                let tier: Int
                if r.quizType == "production"
                    && reviewCount >= tier3MinReviews
                    && r.t >= tier3MinHalflife {
                    tier = 3
                } else if reviewCount >= tier2MinReviews && r.t >= tier2MinHalflife {
                    tier = 2
                } else {
                    tier = 1
                }

                let isFree = tier >= 2  // used only to satisfy QuizStatus shape; isFreeAnswer is tier-based
                let equivalenceGroupIds = topic.equivalenceGroup ?? []
                let recentNotes = allNotes["\(topicId):\(r.quizType)"] ?? []

                items.append(GrammarQuizItem(
                    topicId:             topicId,
                    titleEn:             topic.titleEn,
                    titleJp:             topic.titleJp,
                    level:               topic.level,
                    href:                topic.href,
                    source:              topic.source,
                    equivalenceGroupIds: equivalenceGroupIds,
                    facet:               r.quizType,
                    status:              .reviewed(recall: recall, isFree: isFree, halflife: r.t),
                    extraGrammarTopics:  extraGrammarTopics,
                    tier:                tier,
                    summary:             topic.summary,
                    subUses:             topic.subUses,
                    cautions:            topic.cautions,
                    isStub:              topic.isStub,
                    recentNotes:         recentNotes
                ))
            }
        }

        let sorted = items.sorted { $0.recall < $1.recall }
        return collapseEquivalenceGroups(sorted)
    }

    /// Collapse items so that only one representative per (equivalenceGroupKey, facet) appears.
    /// Items are already sorted by ascending recall; we keep the first (most urgent) representative.
    /// Topics with no equivalence group use their own topicId as the key.
    /// NOTE: facets are intentionally NOT collapsed across each other — quizzing recognition
    /// does not prime production (or vice versa), so both facets of a group can appear in one session.
    private static func collapseEquivalenceGroups(_ items: [GrammarQuizItem]) -> [GrammarQuizItem] {
        var seen = Set<String>()
        var result: [GrammarQuizItem] = []
        for item in items {
            // Canonical key = lexicographically first ID in the equivalence group (or self).
            let groupKey = ([item.topicId] + item.equivalenceGroupIds).sorted().first ?? item.topicId
            let key = "\(groupKey):\(item.facet)"
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }
}

// MARK: - QuizDB extensions for grammar

extension QuizDB {
    /// All ebisu_models rows with word_type = 'grammar'.
    func enrolledGrammarRecords() async throws -> [EbisuRecord] {
        try await pool.read { db in
            try EbisuRecord
                .filter(Column("word_type") == "grammar")
                .fetchAll(db)
        }
    }

    /// Review counts keyed by "topicId:facet" for grammar word_type.
    func grammarReviewCounts() async throws -> [String: Int] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT word_id, quiz_type, COUNT(*) as cnt
                FROM reviews
                WHERE word_type = 'grammar'
                GROUP BY word_id, quiz_type
                """)
            var result: [String: Int] = [:]
            for row in rows {
                guard let wid = row["word_id"] as? String,
                      let qt  = row["quiz_type"] as? String,
                      let cnt = row["cnt"] as? Int64 else { continue }
                result["\(wid):\(qt)"] = Int(cnt)
            }
            return result
        }
    }

    /// Recent review notes for all grammar topics and facets, keyed by "topicId:facet".
    /// Returns up to `limit` notes per key, ordered most-recent first.
    /// Used by GrammarQuizContext.build() to populate GrammarQuizItem.recentNotes.
    func grammarAllRecentNotes(limit: Int = 3) async throws -> [String: [String]] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT word_id, quiz_type, notes FROM reviews
                WHERE word_type = 'grammar'
                  AND notes IS NOT NULL AND notes != ''
                ORDER BY word_id, quiz_type, timestamp DESC
                """)
            var result: [String: [String]] = [:]
            for row in rows {
                guard let wid  = row["word_id"]  as? String,
                      let qt   = row["quiz_type"] as? String,
                      let note = row["notes"]     as? String else { continue }
                let key = "\(wid):\(qt)"
                if result[key, default: []].count < limit {
                    result[key, default: []].append(note)
                }
            }
            return result
        }
    }

    /// Enroll a grammar topic and all its equivalence-group siblings for study.
    /// Creates ebisu_models rows for every topic ID × both facets. Uses INSERT OR IGNORE
    /// so re-enrolling an already-enrolled topic is a no-op (preserves existing models).
    func enrollGrammarTopic(topicId: String, equivalenceGroupIds: [String] = [],
                            halflife: Double = 24) async throws {
        let now    = ISO8601DateFormatter().string(from: Date())
        let model  = defaultModel(halflife: halflife)
        // Enroll the tapped topic and every sibling in its equivalence group.
        let allIds = ([topicId] + equivalenceGroupIds).removingDuplicates()
        let facets = GrammarQuizContext.grammarFacets   // capture before entering Sendable closure
        try await pool.write { db in
            for id in allIds {
                for facet in facets {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO ebisu_models
                            (word_type, word_id, quiz_type, alpha, beta, t, last_review)
                        VALUES ('grammar', ?, ?, ?, ?, ?, ?)
                        """, arguments: [id, facet, model.alpha, model.beta, model.t, now])
                }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO grammar_enrollment (topic_id, status, enrolled_at)
                    VALUES (?, 'learning', ?)
                    """, arguments: [id, now])
            }
        }
        print("[QuizDB] enrolled grammar topic(s): \(allIds.joined(separator: ", "))")
    }

    /// Unenroll a grammar topic and all its equivalence-group siblings.
    /// Deletes ebisu_models and grammar_enrollment rows for all topic IDs.
    func unenrollGrammarTopic(topicId: String, equivalenceGroupIds: [String] = []) async throws {
        let allIds = ([topicId] + equivalenceGroupIds).removingDuplicates()
        try await pool.write { db in
            for id in allIds {
                try db.execute(sql: "DELETE FROM ebisu_models WHERE word_type='grammar' AND word_id=?",
                               arguments: [id])
                try db.execute(sql: "DELETE FROM grammar_enrollment WHERE topic_id=?",
                               arguments: [id])
            }
        }
        print("[QuizDB] unenrolled grammar topic(s): \(allIds.joined(separator: ", "))")
    }

    /// After recording a review for `topicId`, copy the updated Ebisu model to all
    /// equivalence-group siblings. Inserts rows for siblings that don't have one yet
    /// (e.g. a new grammar source added to an existing equivalence group), so the
    /// scheduler sees them immediately without requiring a separate enrollment step.
    func propagateGrammarEbisu(from topicId: String, quizType: String,
                               siblingIds: [String]) async throws {
        guard !siblingIds.isEmpty else { return }
        // Fetch the freshly-updated model for the primary topic.
        guard let primary = try await ebisuRecord(wordType: "grammar", wordId: topicId,
                                                  quizType: quizType) else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try await pool.write { db in
            for sibId in siblingIds where sibId != topicId {
                // INSERT OR REPLACE so new equivalence-group members get a row automatically.
                try db.execute(sql: """
                    INSERT OR REPLACE INTO ebisu_models
                        (word_type, word_id, quiz_type, alpha, beta, t, last_review)
                    VALUES ('grammar', ?, ?, ?, ?, ?, ?)
                    """, arguments: [sibId, quizType, primary.alpha, primary.beta, primary.t, now])
                // Mirror the grammar_enrollment row so the sibling appears in the browser.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO grammar_enrollment (topic_id, status, enrolled_at)
                    VALUES (?, 'learning', ?)
                    """, arguments: [sibId, now])
            }
        }
        let updated = siblingIds.filter { $0 != topicId }
        if !updated.isEmpty {
            print("[QuizDB] propagated \(topicId)/\(quizType) model to: \(updated.joined(separator: ", "))")
        }
    }

    /// Whether a grammar topic is currently enrolled (has a grammar_enrollment row).
    func isGrammarTopicEnrolled(topicId: String) async throws -> Bool {
        try await pool.read { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM grammar_enrollment WHERE topic_id=?
                """, arguments: [topicId]) ?? 0
            return count > 0
        }
    }
}

// parseISO8601 is defined in QuizContext.swift (module-level) and reused here.
