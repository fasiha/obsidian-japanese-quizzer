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

// MARK: - Scaffold entry

/// A grammar topic the student already knows well, used to calibrate quiz difficulty.
/// Claude incorporates these patterns into generated example sentences.
struct GrammarScaffoldEntry {
    let topicId: String     // full prefixed ID, e.g. "bunpro:causative"
    let titleEn: String     // English title, e.g. "To make/let/have"
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
    let scaffoldingTopics: [GrammarScaffoldEntry]
    /// Quiz format tier.
    /// Production: 1 = multiple choice, 2 = fill-in-the-blank (typed, string-match graded),
    ///             3 = free text (LLM graded with SCORE).
    /// Recognition: 1 = multiple choice, 2 = free text (LLM graded with SCORE).
    let tier: Int

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

    /// Tier-2 thresholds (production fill-in-the-blank; recognition free text).
    static let tier2MinReviews  = 3
    static let tier2MinHalflife = 72.0      // hours

    /// Tier-3 threshold (production free text only). Higher bar because open production is harder.
    static let tier3MinReviews  = 6
    static let tier3MinHalflife = 120.0     // hours

    // Backward-compatible alias used by existing code outside this file.
    static var freeAnswerMinReviews:  Int    { tier2MinReviews }
    static var freeAnswerMinHalflife: Double { tier2MinHalflife }

    /// Halflife threshold above which a topic is considered "established" for scaffolding.
    static let scaffoldingMinHalflife = 48.0    // hours

    /// Number of top-urgency candidates to sample from when building a session.
    static let selectionPoolSize = 10
    static let minItemsPerQuiz = 3
    static let maxItemsPerQuiz = 5

    /// Build a ranked list of GrammarQuizItems from the DB and grammar manifest.
    ///
    /// Only topics with active ebisu_models rows (word_type='grammar') are included.
    /// Items are sorted by ascending recall probability (most urgent first).
    static func build(db: QuizDB, manifest: GrammarManifest) async throws -> [GrammarQuizItem] {
        let records  = try await db.enrolledGrammarRecords()
        let counts   = try await db.grammarReviewCounts()
        let now      = Date()

        // Group records by topic ID, tracking facets.
        var byTopic: [String: [EbisuRecord]] = [:]
        for r in records {
            byTopic[r.wordId, default: []].append(r)
        }

        // Identify well-established topics for the scaffolding list (high halflife, decent recall).
        var scaffoldCandidates: [(topicId: String, recall: Double)] = []
        for (topicId, facetRecords) in byTopic {
            for r in facetRecords {
                guard let lastDate = parseISO8601(r.lastReview) else { continue }
                let elapsed = now.timeIntervalSince(lastDate) / 3600.0
                let recall  = predictRecall(r.model, tnow: elapsed, exact: true)
                if r.t >= scaffoldingMinHalflife {
                    scaffoldCandidates.append((topicId, recall))
                    break   // one facet is enough to qualify the topic
                }
            }
        }
        scaffoldCandidates.sort { $0.recall > $1.recall }   // best recall first

        // Build scaffold entries from topic metadata.
        let scaffoldingTopics: [GrammarScaffoldEntry] = scaffoldCandidates.compactMap { candidate in
            guard let topic = manifest.topics[candidate.topicId] else { return nil }
            return GrammarScaffoldEntry(topicId: candidate.topicId, titleEn: topic.titleEn)
        }

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
                    scaffoldingTopics:   scaffoldingTopics,
                    tier:                tier
                ))
            }
        }

        return items.sorted { $0.recall < $1.recall }
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

    /// Enroll a grammar topic for study — creates ebisu_models rows for both facets.
    func enrollGrammarTopic(topicId: String, halflife: Double = 24) async throws {
        let now   = ISO8601DateFormatter().string(from: Date())
        let model = defaultModel(halflife: halflife)
        try await pool.write { db in
            for facet in GrammarQuizContext.grammarFacets {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO ebisu_models
                        (word_type, word_id, quiz_type, alpha, beta, t, last_review)
                    VALUES ('grammar', ?, ?, ?, ?, ?, ?)
                    """, arguments: [topicId, facet, model.alpha, model.beta, model.t, now])
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO grammar_enrollment (topic_id, status, enrolled_at)
                VALUES (?, 'learning', ?)
                """, arguments: [topicId, now])
        }
        print("[QuizDB] enrolled grammar topic \(topicId)")
    }
}

// parseISO8601 is defined in QuizContext.swift (module-level) and reused here.
