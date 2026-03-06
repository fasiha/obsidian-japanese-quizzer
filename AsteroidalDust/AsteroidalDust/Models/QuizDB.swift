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

/// Word learning status. Only `.learning` and `.known` are stored in the DB.
/// `.notYetLearned` is a Swift-only fallback for words absent from vocab_enrollment.
/// NEVER persist a VocabEnrollment with status = .notYetLearned.
enum EnrollmentStatus: String, Codable, Sendable {
    case notYetLearned  // UI only; absence from DB; rawValue never written to DB
    case learning = "learning"
    case known = "known"
}

struct VocabEnrollment: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "vocab_enrollment"
    var wordType: String
    var wordId: String
    var status: EnrollmentStatus    // only .learning or .known are valid to persist
    var kanjiOk: Bool               // true → user committed to kanji facets
    var updatedAt: String           // ISO 8601 UTC

    enum CodingKeys: String, CodingKey {
        case wordType = "word_type"
        case wordId = "word_id"
        case status
        case kanjiOk = "kanji_ok"
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

    /// Copy kanjidic2.sqlite from the app bundle to Documents on first launch.
    /// Returns the destination URL, or nil if the bundle resource is absent.
    @discardableResult
    static func copyKanjidicIfNeeded() throws -> URL? {
        let docsURL = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dest = docsURL.appendingPathComponent("kanjidic2.sqlite")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return dest }
        guard let src = Bundle.main.url(forResource: "kanjidic2", withExtension: "sqlite") else {
            return nil  // optional resource — tool will gracefully report unavailable
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
        try migrator.migrate(pool)
    }

    /// Ensure every word with ebisu_models rows has a vocab_enrollment row (status = 'learning').
    /// Runs on every launch so that words added via the Node.js quiz skill are automatically
    /// treated as learning in the iOS app. INSERT OR IGNORE preserves existing rows.
    private func reconcileEnrollment() throws {
        try pool.write { db in
            // Infer kanji_ok from existing facets for any auto-reconciled rows.
            try db.execute(sql: """
                INSERT OR IGNORE INTO vocab_enrollment (word_type, word_id, status, kanji_ok, updated_at)
                SELECT DISTINCT e.word_type, e.word_id, 'learning',
                    CASE WHEN EXISTS (
                        SELECT 1 FROM ebisu_models k
                        WHERE k.word_type = e.word_type AND k.word_id = e.word_id
                          AND k.quiz_type IN ('kanji-to-reading', 'meaning-reading-to-kanji')
                    ) THEN 1 ELSE 0 END,
                    datetime('now')
                FROM ebisu_models e
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

    /// All learning words' Ebisu models, for quiz context ranking.
    func enrolledEbisuRecords() async throws -> [EbisuRecord] {
        try await pool.read { db in
            let learningIds = try VocabEnrollment
                .filter(Column("status") == "learning")
                .select(Column("word_id"), as: String.self)
                .fetchAll(db)
            return try EbisuRecord
                .filter(learningIds.contains(Column("word_id")))
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
        return row?.status ?? .notYetLearned
    }

    /// All enrollment rows as a [wordId: VocabEnrollment] dict.
    /// Words absent from the table have status .notYetLearned (not in this dict).
    func allEnrollments() async throws -> [String: VocabEnrollment] {
        try await pool.read { db in
            let rows = try VocabEnrollment.fetchAll(db)
            return Dictionary(rows.map { ($0.wordId, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - Learning flow (new word → commit to learn)

    /// Atomically mark a word as learning and create any missing Ebisu facets.
    /// Safe to call on already-learning words (updates kanjiOk and adds missing facets).
    func setLearning(
        wordType: String,
        wordId: String,
        wordText: String,
        kanjiOk: Bool,
        halflife: Double = 24
    ) async throws {
        let facets: [String] = kanjiOk
            ? ["kanji-to-reading", "reading-to-meaning", "meaning-to-reading", "meaning-reading-to-kanji"]
            : ["reading-to-meaning", "meaning-to-reading"]
        let now = ISO8601DateFormatter().string(from: Date())
        let model = defaultModel(halflife: halflife)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO vocab_enrollment (word_type, word_id, status, kanji_ok, updated_at)
                VALUES (?, ?, 'learning', ?, ?)
                ON CONFLICT(word_type, word_id) DO UPDATE
                    SET status = 'learning', kanji_ok = excluded.kanji_ok, updated_at = excluded.updated_at
                """, arguments: [wordType, wordId, kanjiOk ? 1 : 0, now])
            for facet in facets {
                let exists = try EbisuRecord
                    .filter(Column("word_type") == wordType && Column("word_id") == wordId &&
                            Column("quiz_type") == facet)
                    .fetchOne(db) != nil
                guard !exists else { continue }
                let record = EbisuRecord(wordType: wordType, wordId: wordId, quizType: facet,
                                         alpha: model.alpha, beta: model.beta, t: model.t,
                                         lastReview: now)
                try record.save(db)
                var event = ModelEvent(timestamp: now, wordType: wordType, wordId: wordId,
                                       quizType: facet, event: "learned,\(halflife)")
                try event.insert(db)
            }
        }
        print("[QuizDB] setLearning \(wordText) (\(wordId)) kanjiOk=\(kanjiOk)")
    }

    /// Archive all Ebisu models for a word to model_events, then delete them and
    /// update (or remove) the vocab_enrollment row.
    ///
    /// - reason: "unlearned" → deletes the enrollment row entirely (word goes back to
    ///   "not yet learned"). "known" → sets status = 'known'.
    func archiveAndRemove(wordType: String, wordId: String, reason: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await pool.write { db in
            let records = try EbisuRecord
                .filter(Column("word_type") == wordType && Column("word_id") == wordId)
                .fetchAll(db)
            for record in records {
                var event = ModelEvent(
                    timestamp: now, wordType: record.wordType, wordId: record.wordId,
                    quizType: record.quizType,
                    event: "archived,\(record.alpha),\(record.beta),\(record.t),\(reason)")
                try event.insert(db)
            }
            try db.execute(sql: "DELETE FROM ebisu_models WHERE word_type=? AND word_id=?",
                           arguments: [wordType, wordId])
            if reason == "unlearned" {
                try db.execute(sql: "DELETE FROM vocab_enrollment WHERE word_type=? AND word_id=?",
                               arguments: [wordType, wordId])
            } else {
                try db.execute(sql: """
                    UPDATE vocab_enrollment SET status='known', updated_at=?
                    WHERE word_type=? AND word_id=?
                    """, arguments: [now, wordType, wordId])
            }
        }
        print("[QuizDB] archiveAndRemove \(wordId) reason=\(reason)")
    }

    /// Remove a word's enrollment row (e.g. undo-known → back to "not yet learned").
    /// No Ebisu models exist at this point — they were archived to model_events when the word
    /// was marked known, so that event already serves as the audit trail.
    func removeEnrollment(wordType: String, wordId: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM vocab_enrollment WHERE word_type=? AND word_id=?",
                           arguments: [wordType, wordId])
        }
        print("[QuizDB] removeEnrollment \(wordId)")
    }

    /// Toggle kanji commitment for a learning word.
    ///
    /// - kanjiOk = false → true: creates the 2 missing kanji facets with a fresh default model.
    /// - kanjiOk = true → false: archives and deletes the 2 kanji facets; updates kanji_ok = 0.
    func toggleKanji(wordType: String, wordId: String, wordText: String, halflife: Double = 24) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let kanjiFacets = ["kanji-to-reading", "meaning-reading-to-kanji"]
        try await pool.write { db in
            let row = try Row.fetchOne(db,
                sql: "SELECT kanji_ok FROM vocab_enrollment WHERE word_type=? AND word_id=?",
                arguments: [wordType, wordId])
            let currentKanjiOk = (row?["kanji_ok"] as? Int64 ?? 0) != 0

            if currentKanjiOk {
                // Remove kanji facets: archive to model_events then delete.
                for facet in kanjiFacets {
                    if let record = try EbisuRecord
                        .filter(Column("word_type") == wordType && Column("word_id") == wordId &&
                                Column("quiz_type") == facet)
                        .fetchOne(db) {
                        var event = ModelEvent(
                            timestamp: now, wordType: record.wordType, wordId: record.wordId,
                            quizType: record.quizType,
                            event: "archived,\(record.alpha),\(record.beta),\(record.t),kanji-removed")
                        try event.insert(db)
                        try db.execute(sql: """
                            DELETE FROM ebisu_models WHERE word_type=? AND word_id=? AND quiz_type=?
                            """, arguments: [wordType, wordId, facet])
                    }
                }
                try db.execute(sql: """
                    UPDATE vocab_enrollment SET kanji_ok=0, updated_at=? WHERE word_type=? AND word_id=?
                    """, arguments: [now, wordType, wordId])
            } else {
                // Add kanji facets with a fresh default model.
                let model = defaultModel(halflife: halflife)
                for facet in kanjiFacets {
                    let exists = try EbisuRecord
                        .filter(Column("word_type") == wordType && Column("word_id") == wordId &&
                                Column("quiz_type") == facet)
                        .fetchOne(db) != nil
                    guard !exists else { continue }
                    let record = EbisuRecord(wordType: wordType, wordId: wordId, quizType: facet,
                                             alpha: model.alpha, beta: model.beta, t: model.t,
                                             lastReview: now)
                    try record.save(db)
                    var event = ModelEvent(timestamp: now, wordType: wordType, wordId: wordId,
                                           quizType: facet, event: "learned,\(halflife)")
                    try event.insert(db)
                }
                try db.execute(sql: """
                    UPDATE vocab_enrollment SET kanji_ok=1, updated_at=? WHERE word_type=? AND word_id=?
                    """, arguments: [now, wordType, wordId])
            }
        }
        print("[QuizDB] toggleKanji \(wordText) (\(wordId))")
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

    // MARK: - Enrollment queries (legacy — still used by VocabCorpus and QuizContext)

    /// Introduce a word's Ebisu facets. Prefer setLearning() for new call sites.
    /// Skips any facet that already has a model (idempotent).
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
                    .filter(Column("word_type") == wordType && Column("word_id") == wordId &&
                            Column("quiz_type") == facet)
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
