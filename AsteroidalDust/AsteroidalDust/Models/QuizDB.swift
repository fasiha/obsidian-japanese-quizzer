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

struct EbisuRecord: Codable, FetchableRecord, PersistableRecord {
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
    var event: String       // e.g. "learned,24" | "rescaled,79.2,120"

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case wordType = "word_type"
        case wordId = "word_id"
        case quizType = "quiz_type"
        case event
    }
}

enum EnrollmentStatus: String, Codable, Sendable {
    case pending, enrolled, known
}

struct VocabEnrollment: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "vocab_enrollment"
    var wordType: String
    var wordId: String
    var status: EnrollmentStatus
    var updatedAt: String   // ISO 8601 UTC

    enum CodingKeys: String, CodingKey {
        case wordType = "word_type"
        case wordId = "word_id"
        case status
        case updatedAt = "updated_at"
    }
}

// MARK: - Database manager

final class QuizDB: Sendable {
    let pool: DatabasePool

    private init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Setup

    /// Open (or create) quiz.sqlite in the app's Documents directory.
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

    /// Copy jmdict.sqlite from the app bundle to Documents on first launch.
    /// Returns the destination URL. Safe to call on every launch.
    ///
    /// IMPORTANT: jmdict.sqlite must be in DELETE journal mode (not WAL) before bundling.
    /// Run `sqlite3 jmdict.sqlite "PRAGMA journal_mode=DELETE;"` after regenerating it,
    /// otherwise ToolHandler's read-only DatabaseQueue will crash looking for a missing .wal file.
    @discardableResult
    static func copyJMdictIfNeeded() throws -> URL {
        let docsURL = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dest = docsURL.appendingPathComponent("jmdict.sqlite")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return dest }
        guard let src = Bundle.main.url(forResource: "jmdict", withExtension: "sqlite") else {
            throw QuizDBError.jmdictBundleNotFound
        }
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
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
        try migrator.migrate(pool)
    }

    /// Ensure every word with ebisu_models rows has a vocab_enrollment row.
    /// Runs on every launch so that words added via the Node.js quiz skill
    /// (desktop sync) are automatically treated as enrolled in the iOS app.
    /// INSERT OR IGNORE preserves any existing 'known' or 'enrolled' status.
    private func reconcileEnrollment() throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO vocab_enrollment (word_type, word_id, status, updated_at)
                SELECT DISTINCT word_type, word_id, 'enrolled', datetime('now')
                FROM ebisu_models
                """)
        }
    }

    // MARK: - Reviews

    func insert(review: Review) async throws {
        try await pool.write { db in var r = review; try r.insert(db) }
    }

    // MARK: - Ebisu models

    func upsert(record: EbisuRecord) async throws {
        try await pool.write { db in try record.save(db) }
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

    /// All enrolled words' Ebisu models, for quiz context ranking.
    func enrolledEbisuRecords() async throws -> [EbisuRecord] {
        try await pool.read { db in
            let enrolledIds = try VocabEnrollment
                .filter(Column("status") == "enrolled")
                .select(Column("word_id"), as: String.self)
                .fetchAll(db)
            return try EbisuRecord
                .filter(enrolledIds.contains(Column("word_id")))
                .fetchAll(db)
        }
    }

    // MARK: - Vocabulary enrollment

    func enrollment(wordType: String, wordId: String) async throws -> EnrollmentStatus {
        let row = try await pool.read { db in
            try VocabEnrollment
                .filter(Column("word_type") == wordType && Column("word_id") == wordId)
                .fetchOne(db)
        }
        return row?.status ?? .pending
    }

    func setEnrollment(wordType: String, wordId: String, status: EnrollmentStatus) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let record = VocabEnrollment(wordType: wordType, wordId: wordId, status: status, updatedAt: now)
        try await pool.write { db in try record.save(db) }
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

    // MARK: - Word introduction (enrollment → Ebisu bootstrap)

    /// Create default Ebisu models for a newly enrolled word.
    ///
    /// Facets created:
    /// - `hasKanji = false`: reading-to-meaning, meaning-to-reading
    /// - `hasKanji = true`: + kanji-to-reading, meaning-reading-to-kanji
    ///
    /// Skips any facet that already has an Ebisu model (idempotent).
    /// Also logs a `ModelEvent` with event "learned,\(halflife)" for each new facet.
    func introduceWord(
        wordType: String,
        wordId: String,
        wordText: String,
        hasKanji: Bool,
        halflife: Double = 24
    ) async throws {
        let facets: [String] = hasKanji
            ? ["kanji-to-reading", "reading-to-meaning", "meaning-to-reading", "meaning-reading-to-kanji"]
            : ["reading-to-meaning", "meaning-to-reading"]
        let now = ISO8601DateFormatter().string(from: Date())
        let model = defaultModel(halflife: halflife)
        try await pool.write { db in
            for facet in facets {
                let existing = try EbisuRecord
                    .filter(Column("word_type") == wordType)
                    .filter(Column("word_id") == wordId)
                    .filter(Column("quiz_type") == facet)
                    .fetchOne(db)
                guard existing == nil else { continue }
                let record = EbisuRecord(
                    wordType: wordType, wordId: wordId, quizType: facet,
                    alpha: model.alpha, beta: model.beta, t: model.t, lastReview: now)
                try record.save(db)
                var event = ModelEvent(
                    timestamp: now, wordType: wordType, wordId: wordId,
                    quizType: facet, event: "learned,\(halflife)")
                try event.insert(db)
            }
        }
        print("[QuizDB] introduced \(wordText) (\(wordId)) with \(facets.count) facet(s)")
    }

    // MARK: - Enrollment queries

    /// All enrollment rows as a [wordId: status] dict. Words not in vocab_enrollment are pending.
    func allEnrollments() async throws -> [String: EnrollmentStatus] {
        try await pool.read { db in
            let rows = try VocabEnrollment.fetchAll(db)
            return Dictionary(rows.map { ($0.wordId, $0.status) }, uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - WAL management

    /// Checkpoint the WAL into the main DB file so the exported .sqlite is self-contained.
    func checkpointWAL() async throws {
        _ = try await pool.writeWithoutTransaction { db in try db.checkpoint(.full) }
    }

    /// Delete the entire session (call when the quiz sitting is finished or discarded).
    func clearSession() async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM quiz_session")
        }
        print("[QuizDB] session cleared")
    }
}

enum QuizDBError: Error, LocalizedError {
    case jmdictBundleNotFound
    var errorDescription: String? {
        "jmdict.sqlite not found in app bundle — add it to the Resources group in Xcode"
    }
}
