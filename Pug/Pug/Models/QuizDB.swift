// QuizDB.swift
// GRDB-backed quiz database. Schema mirrors init-quiz-db.mjs (SCHEMA_VERSION 1)
// with the additional vocab_enrollment table from App.md.

import GRDB
import Foundation

// MARK: - Database records

struct Review: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "reviews"
    var id: Int64?
    var reviewer: String
    var timestamp: String   // ISO 8601 UTC
    var wordType: String
    var wordId: String
    var wordText: String
    var score: Double       // 0.0–1.0
    var quizType: String
    var notes: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, reviewer, timestamp
        case wordType = "word_type"
        case wordId = "word_id"
        case wordText = "word_text"
        case score
        case quizType = "quiz_type"
        case notes
    }
}

struct EbisuRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String { "\(wordType):\(wordId):\(quizType)" }
    static let databaseTableName = "ebisu_models"
    var wordType: String
    var wordId: String
    var quizType: String
    var alpha: Double
    var beta: Double
    var t: Double           // halflife in hours
    var lastReview: String  // ISO 8601 UTC

    var model: EbisuModel { EbisuModel(alpha: alpha, beta: beta, t: t) }

    enum CodingKeys: String, CodingKey {
        case wordType = "word_type"
        case wordId = "word_id"
        case quizType = "quiz_type"
        case alpha, beta, t
        case lastReview = "last_review"
    }
}

struct ModelEvent: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "model_events"
    var id: Int64?
    var timestamp: String   // ISO 8601 UTC
    var wordType: String
    var wordId: String
    var quizType: String
    var event: String       // e.g. "learned,24" | "rescaled,79.2,120" | "archived,a,b,t,reason"

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case wordType = "word_type"
        case wordId = "word_id"
        case quizType = "quiz_type"
        case event
    }
}

/// A mnemonic note for a word (jmdict entry) or a single kanji character.
/// Keyed by (word_type, word_id) — no quiz_type, since one mnemonic covers all facets.
struct Mnemonic: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mnemonics"
    var wordType: String    // "jmdict" or "kanji"
    var wordId: String      // JMDict entry ID or single kanji character
    var mnemonic: String
    var updatedAt: String   // ISO 8601 UTC

    enum CodingKeys: String, CodingKey {
        case wordType = "word_type"
        case wordId = "word_id"
        case mnemonic
        case updatedAt = "updated_at"
    }
}

/// One row per API call — lightweight telemetry for token cost analysis.
struct ApiEvent: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "api_events"
    var id: Int64?
    var timestamp: String
    var eventType: String           // item_selection | question_gen | question_validation | quiz_chat | word_explore
    var wordId: String?
    var quizType: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var chatTurn: Int?
    var model: String?
    var selectedIds: String?        // JSON array
    var selectedRanks: String?      // JSON array
    var validationResult: String?   // pass | fail
    var generationAttempt: Int?
    var toolsCalled: String?        // JSON array of tool names
    var apiTurns: Int?              // number of API round-trips inside send()

    // v8 additions
    var firstTurnInputTokens: Int?  // input tokens on first round-trip (system + tool schemas + messages)
    var questionChars: Int?         // character length of extracted question (question_gen only)
    var questionFormat: String?     // 'multiple_choice' | 'free_answer' (question_gen only)
    var prefetch: Int?              // 0=foreground generation, 1=background prefetch (question_gen only)
    var candidateCount: Int?        // number of candidates sent to LLM (item_selection only)
    var hasMnemonic: Int?           // 0/1 whether mnemonic block was injected (quiz_chat only)
    var score: Double?              // graded score 0.0–1.0 if this turn emitted SCORE: (quiz_chat only)
    var preRecall: Double?          // Ebisu predicted recall probability at quiz time (question_gen, quiz_chat)

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case eventType = "event_type"
        case wordId = "word_id"
        case quizType = "quiz_type"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case chatTurn = "chat_turn"
        case model
        case selectedIds = "selected_ids"
        case selectedRanks = "selected_ranks"
        case validationResult = "validation_result"
        case generationAttempt = "generation_attempt"
        case toolsCalled = "tools_called"
        case apiTurns = "api_turns"
        case firstTurnInputTokens = "first_turn_input_tokens"
        case questionChars = "question_chars"
        case questionFormat = "question_format"
        case prefetch
        case candidateCount = "candidate_count"
        case hasMnemonic = "has_mnemonic"
        case score
        case preRecall = "pre_recall"
    }
}

/// User's commitment to study a specific furigana form of a word.
/// One row per (word_type, word_id). The furigana field stores the JmdictFurigana
/// JSON array for the chosen written form; kanjiChars is a JSON array of kanji
/// characters the user is committing to learn (e.g. ["入","込"]).
struct WordCommitment: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "word_commitment"
    var wordType: String
    var wordId: String
    var furigana: String            // JmdictFurigana JSON array for the chosen form
    var kanjiChars: String?         // JSON array of kanji chars, e.g. ["入","込"]

    enum CodingKeys: String, CodingKey {
        case wordType = "word_type"
        case wordId = "word_id"
        case furigana
        case kanjiChars = "kanji_chars"
    }
}

/// A facet the user has marked as "known" (no longer quizzed).
/// Stores a JSON backup of the ebisu model at the time of marking known,
/// so it can be restored if the user changes their mind.
struct LearnedFacet: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "learned"
    var wordType: String
    var wordId: String
    var quizType: String
    var learnedAt: String           // ISO 8601 UTC
    var ebisuBackup: String?        // JSON snapshot of EbisuRecord at time of marking known

    enum CodingKeys: String, CodingKey {
        case wordType = "word_type"
        case wordId = "word_id"
        case quizType = "quiz_type"
        case learnedAt = "learned_at"
        case ebisuBackup = "ebisu_backup"
    }
}

/// Derived state for a single facet — not stored in DB.
enum FacetState: String, Sendable {
    case unknown    // not in ebisu_models or learned
    case learning   // has ebisu_models row
    case known      // has learned row
}

// MARK: - Database manager

final class QuizDB: Sendable {
    let pool: DatabasePool

    private init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Setup

    /// Open (or create) quiz.sqlite in the app's Documents directory.
    /// Open (or create) a QuizDB at an explicit file path. Used by the CLI test harness.
    static func open(path: String) throws -> QuizDB {
        let pool = try DatabasePool(path: path)
        let db = QuizDB(pool: pool)
        try db.runMigrations()
        return db
    }

    static func makeDefault() throws -> QuizDB {
        let docsURL = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dbURL = docsURL.appendingPathComponent("quiz.sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        let db = QuizDB(pool: pool)
        try db.runMigrations()
        try db.reconcileEnrollment()
        return db
    }

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "reviews", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("reviewer", .text).notNull()
                t.column("timestamp", .text).notNull()
                t.column("word_type", .text).notNull()
                t.column("word_id", .text).notNull()
                t.column("word_text", .text).notNull()
                t.column("score", .double).notNull()
                t.column("quiz_type", .text).notNull()
                t.column("notes", .text)
            }
            try db.create(table: "ebisu_models", ifNotExists: true) { t in
                t.column("word_type", .text).notNull()
                t.column("word_id", .text).notNull()
                t.column("quiz_type", .text).notNull()
                t.column("alpha", .double).notNull()
                t.column("beta", .double).notNull()
                t.column("t", .double).notNull()
                t.column("last_review", .text).notNull()
                t.primaryKey(["word_type", "word_id", "quiz_type"])
            }
            try db.create(table: "model_events", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .text).notNull()
                t.column("word_type", .text).notNull()
                t.column("word_id", .text).notNull()
                t.column("quiz_type", .text).notNull()
                t.column("event", .text).notNull()
            }
            try db.create(table: "vocab_enrollment", ifNotExists: true) { t in
                t.column("word_type", .text).notNull()
                t.column("word_id", .text).notNull()
                t.column("status", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.primaryKey(["word_type", "word_id"])
                t.check(sql: "status IN ('pending', 'enrolled', 'known')")
            }
            // Mirror the Node.js schema version for reference (GRDB uses its own migration table)
            try db.execute(sql: "PRAGMA user_version = 1")
        }
        migrator.registerMigration("v2") { db in
            // quiz_session: persisted queue of word IDs for the current quiz sitting.
            // position defines quiz order; items are removed one by one as they are graded.
            try db.create(table: "quiz_session", ifNotExists: true) { t in
                t.column("position", .integer).notNull().primaryKey()
                t.column("word_id", .text).notNull().unique()
            }
        }
        migrator.registerMigration("v3") { db in
            // Part A: Recreate vocab_enrollment.
            // - Status values: 'enrolled' → 'learning'; 'pending' rows dropped; 'known' kept.
            // - CHECK updated to only allow 'learning' and 'known'.
            // - New column: kanji_ok INTEGER NOT NULL DEFAULT 0.
            try db.execute(sql: """
                CREATE TABLE vocab_enrollment_new (
                    word_type  TEXT NOT NULL,
                    word_id    TEXT NOT NULL,
                    status     TEXT NOT NULL CHECK(status IN ('learning','known')),
                    kanji_ok   INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (word_type, word_id)
                )
                """)
            try db.execute(sql: """
                INSERT INTO vocab_enrollment_new (word_type, word_id, status, kanji_ok, updated_at)
                SELECT word_type, word_id,
                       CASE status WHEN 'enrolled' THEN 'learning' ELSE status END,
                       0,
                       updated_at
                FROM vocab_enrollment
                WHERE status IN ('enrolled', 'known')
                """)
            try db.execute(sql: "DROP TABLE vocab_enrollment")
            try db.execute(sql: "ALTER TABLE vocab_enrollment_new RENAME TO vocab_enrollment")

            // Set kanji_ok=1 for words that already have kanji facets in ebisu_models.
            try db.execute(sql: """
                UPDATE vocab_enrollment
                SET kanji_ok = 1
                WHERE word_id IN (
                    SELECT DISTINCT word_id FROM ebisu_models
                    WHERE quiz_type IN ('kanji-to-reading', 'meaning-reading-to-kanji')
                )
                """)

            // Part B: Backfill partial Ebisu facets.
            // For each word already in ebisu_models, ensure it has a full set of facets
            // (2 for no-kanji words, 4 for kanji-ok words). Missing facets get a default
            // model with timestamp = oldest existing facet for that word.
            let kanjiOkFacets = ["kanji-to-reading", "reading-to-meaning",
                                  "meaning-to-reading", "meaning-reading-to-kanji"]
            let noKanjiFacets = ["reading-to-meaning", "meaning-to-reading"]
            let kanjiFacetSet = Set(["kanji-to-reading", "meaning-reading-to-kanji"])

            let rows = try Row.fetchAll(db, sql: """
                SELECT word_type, word_id, quiz_type, last_review
                FROM ebisu_models
                ORDER BY last_review ASC
                """)

            // Group rows by word, tracking which facets exist and the oldest timestamp.
            var byWord: [String: (wordType: String, wordId: String, facets: Set<String>, oldest: String)] = [:]
            for row in rows {
                guard let wt  = row["word_type"]   as? String,
                      let wid = row["word_id"]     as? String,
                      let qt  = row["quiz_type"]   as? String,
                      let lr  = row["last_review"] as? String else { continue }
                let key = "\(wt)\0\(wid)"
                if var entry = byWord[key] {
                    entry.facets.insert(qt)
                    byWord[key] = entry     // oldest already set (rows sorted ASC)
                } else {
                    byWord[key] = (wt, wid, [qt], lr)
                }
            }

            let model = defaultModel(halflife: 24)
            for (_, info) in byWord {
                let hasKanji = !info.facets.isDisjoint(with: kanjiFacetSet)
                let required = hasKanji ? kanjiOkFacets : noKanjiFacets
                for facet in required {
                    guard !info.facets.contains(facet) else { continue }
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO ebisu_models
                            (word_type, word_id, quiz_type, alpha, beta, t, last_review)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [info.wordType, info.wordId, facet,
                                         model.alpha, model.beta, model.t, info.oldest])
                }
            }
        }
        migrator.registerMigration("v4") { db in
            try db.create(table: "mnemonics", ifNotExists: true) { t in
                t.column("word_type", .text).notNull()  // "jmdict" or "kanji"
                t.column("word_id", .text).notNull()    // JMDict ID or kanji character
                t.column("mnemonic", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.primaryKey(["word_type", "word_id"])
            }
        }
        migrator.registerMigration("v5") { db in
            // New table: word_commitment — user's chosen furigana form per word.
            try db.create(table: "word_commitment") { t in
                t.column("word_type", .text).notNull()
                t.column("word_id", .text).notNull()
                t.column("furigana", .text).notNull()       // JmdictFurigana JSON array
                t.column("kanji_chars", .text)               // JSON array e.g. ["入","込"]
                t.primaryKey(["word_type", "word_id"])
            }

            // New table: learned — per-facet "I already know this" with ebisu backup.
            try db.create(table: "learned") { t in
                t.column("word_type", .text).notNull()
                t.column("word_id", .text).notNull()
                t.column("quiz_type", .text).notNull()
                t.column("learned_at", .text).notNull()      // ISO 8601 UTC
                t.column("ebisu_backup", .text)               // JSON snapshot of ebisu model
                t.primaryKey(["word_type", "word_id", "quiz_type"])
            }

            // Migrate vocab_enrollment → word_commitment + learned.
            // 'learning' rows: create word_commitment (furigana placeholder until vocab sync).
            //   Ebisu models are already in ebisu_models — no change needed.
            // 'known' rows: create word_commitment + learned rows for all facets.
            let now = ISO8601DateFormatter().string(from: Date())

            let rows = try Row.fetchAll(db, sql: """
                SELECT word_type, word_id, status, kanji_ok FROM vocab_enrollment
                """)

            for row in rows {
                guard let wt = row["word_type"] as? String,
                      let wid = row["word_id"] as? String,
                      let status = row["status"] as? String else { continue }
                let kanjiOk = (row["kanji_ok"] as? Int64 ?? 0) != 0

                // Create word_commitment with placeholder furigana (will be resolved on
                // next vocab sync when the app loads vocab.json with writtenForms data).
                try db.execute(sql: """
                    INSERT OR IGNORE INTO word_commitment (word_type, word_id, furigana, kanji_chars)
                    VALUES (?, ?, '[]', NULL)
                    """, arguments: [wt, wid])

                if status == "known" {
                    // Create learned rows for all facets this word had.
                    let readingFacets = ["reading-to-meaning", "meaning-to-reading"]
                    let kanjiFacets = ["kanji-to-reading", "meaning-reading-to-kanji"]
                    let facets = kanjiOk ? readingFacets + kanjiFacets : readingFacets

                    for facet in facets {
                        // Check if there's an archived model in model_events we can use as backup
                        let archived = try Row.fetchOne(db, sql: """
                            SELECT event FROM model_events
                            WHERE word_type=? AND word_id=? AND quiz_type=? AND event LIKE 'archived,%'
                            ORDER BY timestamp DESC LIMIT 1
                            """, arguments: [wt, wid, facet])
                        let backup = archived?["event"] as? String

                        try db.execute(sql: """
                            INSERT OR IGNORE INTO learned (word_type, word_id, quiz_type, learned_at, ebisu_backup)
                            VALUES (?, ?, ?, ?, ?)
                            """, arguments: [wt, wid, facet, now, backup])
                    }
                }
            }

            try db.drop(table: "vocab_enrollment")
        }
        migrator.registerMigration("v6") { db in
            try db.create(table: "api_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .text).notNull()
                t.column("event_type", .text).notNull()
                t.column("word_id", .text)
                t.column("quiz_type", .text)
                t.column("input_tokens", .integer)
                t.column("output_tokens", .integer)
                t.column("chat_turn", .integer)
                t.column("model", .text)
                t.column("selected_ids", .text)
                t.column("selected_ranks", .text)
                t.column("validation_result", .text)
                t.column("generation_attempt", .integer)
                t.column("tools_called", .text)
            }
        }
        migrator.registerMigration("v7") { db in
            try db.alter(table: "api_events") { t in
                t.add(column: "api_turns", .integer)
            }
        }
        migrator.registerMigration("v8") { db in
            try db.alter(table: "api_events") { t in
                t.add(column: "first_turn_input_tokens", .integer)
                t.add(column: "question_chars", .integer)
                t.add(column: "question_format", .text)
                t.add(column: "prefetch", .integer)
                t.add(column: "candidate_count", .integer)
                t.add(column: "has_mnemonic", .integer)
                t.add(column: "score", .double)
                t.add(column: "pre_recall", .double)
            }
        }
        migrator.registerMigration("v9") { db in
            // grammar_enrollment: tracks which grammar topics the user has enrolled for study.
            // Reuses ebisu_models and reviews tables (word_type='grammar') for scheduling.
            try db.create(table: "grammar_enrollment", ifNotExists: true) { t in
                t.column("topic_id", .text).notNull().primaryKey()   // full prefixed ID e.g. "genki:potential-verbs"
                t.column("status", .text).notNull()
                t.column("enrolled_at", .text).notNull()
                t.check(sql: "status IN ('learning', 'known')")
            }
        }
        try migrator.migrate(pool)
    }

    /// Ensure every word with ebisu_models rows has a word_commitment row.
    /// Runs on every launch so that words added via the Node.js quiz skill are automatically
    /// tracked in the iOS app. INSERT OR IGNORE preserves existing rows.
    private func reconcileEnrollment() throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO word_commitment (word_type, word_id, furigana, kanji_chars)
                SELECT DISTINCT word_type, word_id, '[]', NULL
                FROM ebisu_models
                """)
        }
    }

    // MARK: - Reviews

    func insert(review: Review) async throws {
        try await pool.write { db in var r = review; try r.insert(db) }
    }

    func reviewCount(wordType: String, wordId: String, quizType: String) async throws -> Int {
        try await pool.read { db in
            try Review
                .filter(Column("word_type") == wordType && Column("word_id") == wordId && Column("quiz_type") == quizType)
                .fetchCount(db)
        }
    }

    // MARK: - Ebisu models

    func upsert(record: EbisuRecord) async throws {
        try await pool.write { db in try record.save(db) }
    }

    func ebisuRecords(wordType: String, wordId: String) async throws -> [EbisuRecord] {
        try await pool.read { db in
            try EbisuRecord
                .filter(Column("word_type") == wordType && Column("word_id") == wordId)
                .fetchAll(db)
        }
    }

    func ebisuRecord(wordType: String, wordId: String, quizType: String) async throws -> EbisuRecord? {
        try await pool.read { db in
            try EbisuRecord
                .filter(Column("word_type") == wordType)
                .filter(Column("word_id") == wordId)
                .filter(Column("quiz_type") == quizType)
                .fetchOne(db)
        }
    }

    /// All learning words' Ebisu models, for quiz context ranking.
    func enrolledEbisuRecords() async throws -> [EbisuRecord] {
        try await pool.read { db in
            // "Learning" = has ebisu_models rows (actively being quizzed)
            try EbisuRecord.fetchAll(db)
        }
    }

    // MARK: - Word commitment

    func commitment(wordType: String, wordId: String) async throws -> WordCommitment? {
        try await pool.read { db in
            try WordCommitment
                .filter(Column("word_type") == wordType && Column("word_id") == wordId)
                .fetchOne(db)
        }
    }

    /// All word_commitment rows as a [wordId: WordCommitment] dict.
    func allCommitments() async throws -> [String: WordCommitment] {
        try await pool.read { db in
            let rows = try WordCommitment.fetchAll(db)
            return Dictionary(rows.map { ($0.wordId, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Upsert a word commitment (user chose a furigana form to study).
    func setCommitment(wordType: String, wordId: String, furigana: String, kanjiChars: String? = nil) async throws {
        let record = WordCommitment(wordType: wordType, wordId: wordId, furigana: furigana, kanjiChars: kanjiChars)
        try await pool.write { db in try record.save(db) }
        print("[QuizDB] setCommitment \(wordId) kanji=\(kanjiChars ?? "nil")")
    }

    /// Remove a word's commitment and all associated ebisu_models and learned rows.
    func clearCommitment(wordType: String, wordId: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM word_commitment WHERE word_type=? AND word_id=?",
                           arguments: [wordType, wordId])
            try db.execute(sql: "DELETE FROM ebisu_models WHERE word_type=? AND word_id=?",
                           arguments: [wordType, wordId])
            try db.execute(sql: "DELETE FROM learned WHERE word_type=? AND word_id=?",
                           arguments: [wordType, wordId])
        }
        print("[QuizDB] clearCommitment \(wordId)")
    }

    // MARK: - Facet state transitions

    /// Derive the state of each facet for a word.
    func facetStates(wordType: String, wordId: String) async throws -> [String: FacetState] {
        try await pool.read { db in
            var states: [String: FacetState] = [:]
            let ebisuRows = try EbisuRecord
                .filter(Column("word_type") == wordType && Column("word_id") == wordId)
                .fetchAll(db)
            for row in ebisuRows { states[row.quizType] = .learning }
            let learnedRows = try LearnedFacet
                .filter(Column("word_type") == wordType && Column("word_id") == wordId)
                .fetchAll(db)
            for row in learnedRows { states[row.quizType] = .known }
            return states
        }
    }

    /// Transition a facet to "learning": create ebisu model (or restore from learned backup).
    func setFacetLearning(wordType: String, wordId: String, quizType: String, halflife: Double = 24) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await pool.write { db in
            // Check if already learning
            let existing = try EbisuRecord
                .filter(Column("word_type") == wordType && Column("word_id") == wordId &&
                        Column("quiz_type") == quizType)
                .fetchOne(db)
            if existing != nil { return }

            // Check if in learned — restore backup
            let learnedRow = try LearnedFacet
                .filter(Column("word_type") == wordType && Column("word_id") == wordId &&
                        Column("quiz_type") == quizType)
                .fetchOne(db)

            let model: EbisuModel
            let lastReview: String
            if let backup = learnedRow?.ebisuBackup,
               let data = backup.data(using: .utf8),
               let restored = try? JSONDecoder().decode(EbisuRecord.self, from: data) {
                model = restored.model
                lastReview = restored.lastReview
            } else {
                model = defaultModel(halflife: halflife)
                lastReview = now
            }

            let record = EbisuRecord(wordType: wordType, wordId: wordId, quizType: quizType,
                                     alpha: model.alpha, beta: model.beta, t: model.t,
                                     lastReview: lastReview)
            try record.save(db)
            var event = ModelEvent(timestamp: now, wordType: wordType, wordId: wordId,
                                   quizType: quizType, event: "learned,\(halflife)")
            try event.insert(db)

            // Remove from learned if it was there
            if learnedRow != nil {
                try db.execute(sql: "DELETE FROM learned WHERE word_type=? AND word_id=? AND quiz_type=?",
                               arguments: [wordType, wordId, quizType])
            }
        }
        print("[QuizDB] setFacetLearning \(wordId) \(quizType)")
    }

    /// Transition a facet to "known": backup ebisu model to learned, delete from ebisu_models.
    func setFacetKnown(wordType: String, wordId: String, quizType: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await pool.write { db in
            // Snapshot the ebisu model as JSON backup
            let ebisuRow = try EbisuRecord
                .filter(Column("word_type") == wordType && Column("word_id") == wordId &&
                        Column("quiz_type") == quizType)
                .fetchOne(db)
            var backup: String? = nil
            if let ebisuRow {
                let data = try JSONEncoder().encode(ebisuRow)
                backup = String(data: data, encoding: .utf8)
            }

            // Insert into learned
            let learned = LearnedFacet(wordType: wordType, wordId: wordId, quizType: quizType,
                                       learnedAt: now, ebisuBackup: backup)
            try learned.save(db)

            // Delete from ebisu_models
            try db.execute(sql: "DELETE FROM ebisu_models WHERE word_type=? AND word_id=? AND quiz_type=?",
                           arguments: [wordType, wordId, quizType])

            // Archive to model_events
            if let ebisuRow {
                var event = ModelEvent(
                    timestamp: now, wordType: wordType, wordId: wordId,
                    quizType: quizType,
                    event: "archived,\(ebisuRow.alpha),\(ebisuRow.beta),\(ebisuRow.t),known")
                try event.insert(db)
            }
        }
        print("[QuizDB] setFacetKnown \(wordId) \(quizType)")
    }

    /// Transition a facet to "unknown": delete from both ebisu_models and learned.
    func setFacetUnknown(wordType: String, wordId: String, quizType: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await pool.write { db in
            // Archive ebisu model if it exists
            if let ebisuRow = try EbisuRecord
                .filter(Column("word_type") == wordType && Column("word_id") == wordId &&
                        Column("quiz_type") == quizType)
                .fetchOne(db) {
                var event = ModelEvent(
                    timestamp: now, wordType: wordType, wordId: wordId,
                    quizType: quizType,
                    event: "archived,\(ebisuRow.alpha),\(ebisuRow.beta),\(ebisuRow.t),unlearned")
                try event.insert(db)
            }
            try db.execute(sql: "DELETE FROM ebisu_models WHERE word_type=? AND word_id=? AND quiz_type=?",
                           arguments: [wordType, wordId, quizType])
            try db.execute(sql: "DELETE FROM learned WHERE word_type=? AND word_id=? AND quiz_type=?",
                           arguments: [wordType, wordId, quizType])
        }
        print("[QuizDB] setFacetUnknown \(wordId) \(quizType)")
    }

    // MARK: - Batch learning helpers

    /// Set reading facets to learning (reading-to-meaning + meaning-to-reading).
    func setReadingLearning(wordType: String, wordId: String, halflife: Double = 24) async throws {
        try await setFacetLearning(wordType: wordType, wordId: wordId, quizType: "reading-to-meaning", halflife: halflife)
        try await setFacetLearning(wordType: wordType, wordId: wordId, quizType: "meaning-to-reading", halflife: halflife)
    }

    /// Set kanji facets to learning (kanji-to-reading + meaning-reading-to-kanji).
    func setKanjiLearning(wordType: String, wordId: String, halflife: Double = 24) async throws {
        try await setFacetLearning(wordType: wordType, wordId: wordId, quizType: "kanji-to-reading", halflife: halflife)
        try await setFacetLearning(wordType: wordType, wordId: wordId, quizType: "meaning-reading-to-kanji", halflife: halflife)
    }

    /// Set reading facets to known.
    func setReadingKnown(wordType: String, wordId: String) async throws {
        try await setFacetKnown(wordType: wordType, wordId: wordId, quizType: "reading-to-meaning")
        try await setFacetKnown(wordType: wordType, wordId: wordId, quizType: "meaning-to-reading")
    }

    /// Set kanji facets to known.
    func setKanjiKnown(wordType: String, wordId: String) async throws {
        try await setFacetKnown(wordType: wordType, wordId: wordId, quizType: "kanji-to-reading")
        try await setFacetKnown(wordType: wordType, wordId: wordId, quizType: "meaning-reading-to-kanji")
    }

    /// Set reading facets to unknown.
    func setReadingUnknown(wordType: String, wordId: String) async throws {
        try await setFacetUnknown(wordType: wordType, wordId: wordId, quizType: "reading-to-meaning")
        try await setFacetUnknown(wordType: wordType, wordId: wordId, quizType: "meaning-to-reading")
    }

    /// Set kanji facets to unknown.
    func setKanjiUnknown(wordType: String, wordId: String) async throws {
        try await setFacetUnknown(wordType: wordType, wordId: wordId, quizType: "kanji-to-reading")
        try await setFacetUnknown(wordType: wordType, wordId: wordId, quizType: "meaning-reading-to-kanji")
    }

    // MARK: - Model events

    func log(event: ModelEvent) async throws {
        try await pool.write { db in var e = event; try e.insert(db) }
    }

    // MARK: - Quiz session

    /// Return the ordered word IDs of the saved session, or empty if none.
    func sessionWordIds() async throws -> [String] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT word_id FROM quiz_session ORDER BY position ASC")
            return rows.compactMap { $0["word_id"] as? String }
        }
    }

    /// Overwrite the saved session with a new ordered list of word IDs.
    func saveSession(wordIds: [String]) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM quiz_session")
            for (position, wordId) in wordIds.enumerated() {
                try db.execute(sql: "INSERT INTO quiz_session (position, word_id) VALUES (?, ?)",
                               arguments: [position, wordId])
            }
        }
        print("[QuizDB] session saved: \(wordIds.count) item(s)")
    }

    /// Remove one word from the saved session (call after grading each item).
    func removeFromSession(wordId: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM quiz_session WHERE word_id = ?", arguments: [wordId])
        }
    }

    /// Delete the entire session (call when the quiz sitting is finished or discarded).
    func clearSession() async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM quiz_session")
        }
        print("[QuizDB] session cleared")
    }

    // MARK: - Mnemonics

    /// Fetch a single mnemonic by (wordType, wordId), or nil if none exists.
    func mnemonic(wordType: String, wordId: String) async throws -> Mnemonic? {
        try await pool.read { db in
            try Mnemonic
                .filter(Column("word_type") == wordType && Column("word_id") == wordId)
                .fetchOne(db)
        }
    }

    /// Fetch all mnemonics whose word_id is in the given set (for batch lookups, e.g. kanji in a word).
    func mnemonics(wordType: String, wordIds: [String]) async throws -> [Mnemonic] {
        guard !wordIds.isEmpty else { return [] }
        return try await pool.read { db in
            try Mnemonic
                .filter(Column("word_type") == wordType && wordIds.contains(Column("word_id")))
                .fetchAll(db)
        }
    }

    /// Upsert a mnemonic. Overwrites any existing row for the same (wordType, wordId).
    func setMnemonic(wordType: String, wordId: String, text: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let record = Mnemonic(wordType: wordType, wordId: wordId, mnemonic: text, updatedAt: now)
        try await pool.write { db in try record.save(db) }
        print("[QuizDB] setMnemonic \(wordType)/\(wordId) (\(text.prefix(40))…)")
    }

    // MARK: - API events (telemetry)

    func log(apiEvent: ApiEvent) async throws {
        try await pool.write { db in var e = apiEvent; try e.insert(db) }
    }

    // MARK: - Learned facets

    /// All learned facet rows as a ["\(wordId):\(quizType)": LearnedFacet] dict.
    func allLearnedFacets() async throws -> [String: LearnedFacet] {
        try await pool.read { db in
            let rows = try LearnedFacet.fetchAll(db)
            return Dictionary(rows.map { ("\($0.wordId):\($0.quizType)", $0) },
                              uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - WAL management

    /// Checkpoint the WAL into the main DB file so the exported .sqlite is self-contained.
    func checkpointWAL() async throws {
        _ = try await pool.writeWithoutTransaction { db in try db.checkpoint(.full) }
    }
}

enum QuizDBError: Error, LocalizedError {
    case jmdictBundleNotFound
    var errorDescription: String? {
        "jmdict.sqlite not found in app bundle — add it to the Resources group in Xcode"
    }
}
