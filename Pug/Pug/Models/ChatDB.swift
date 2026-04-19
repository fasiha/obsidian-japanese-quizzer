// ChatDB.swift
// Persistent log of every LLM chat turn (user and assistant) in a separate chat.sqlite.
// Kept separate from quiz.sqlite because chat data has a different value profile:
// it grows faster and is disposable — losing it doesn't erase SRS history.

import Foundation
import GRDB

// MARK: - ChatContext

/// Identifies the source and subject of an LLM call for logging in chat.sqlite.
enum ChatContext: Sendable {
    /// Organic word-exploration chat in WordDetailSheet.
    case wordExplore(wordId: String)
    /// Organic discussion in TransitivePairDetailSheet.
    case transitivePairDetail(pairId: String)
    /// Organic or canned exchange in GrammarDetailSheet or GrammarAppSession.
    case grammarDetail(topicId: String)
    /// Vocabulary quiz turn (multiple-choice generation, grading, or tutor), and any subsequent
    /// ReviewDetailSheet conversation about the same quiz attempt.
    /// sessionId is QuizItem.id.uuidString, shared with the Review row in quiz.sqlite.
    case vocabQuiz(wordId: String, facet: String, sessionId: String)
    /// Grammar quiz turn (multiple-choice generation, grading, or tutor).
    case grammarQuiz(topicId: String, facet: String)
    /// Internal question-generation helpers (gap disambiguation, answer refinement, vocab gloss).
    case grammarQuizGeneration(topicId: String)

    /// The string stored in the `context` column of chat.sqlite.
    var tag: String {
        switch self {
        case .wordExplore(let id):                              return "word:\(id)"
        case .transitivePairDetail(let id):                     return "pair:\(id)"
        case .grammarDetail(let id):                            return "grammar:\(id)"
        case .vocabQuiz(let id, let facet, let sessionId):      return "quiz:\(id):\(facet):\(sessionId)"
        case .grammarQuiz(let id, let facet):                   return "quiz:\(id):\(facet)"
        case .grammarQuizGeneration(let id):                    return "quiz-gen:\(id)"
        }
    }
}

// MARK: - Record

struct ChatTurn: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "turns"

    var id: Int64?
    /// Unix epoch milliseconds.
    var ts: Int64
    /// Freeform tag: e.g. "word:1234567", "grammar:て-form", "pair:42", "review:1234567:reading-to-meaning"
    var context: String
    /// "user" or "assistant"
    var role: String
    var content: String
    /// nil = organic exchange; non-nil = canned template, e.g. "grammar-try-it-out-v1"
    var templateId: String?

    enum CodingKeys: String, CodingKey {
        case id, ts, context, role, content
        case templateId = "template_id"
    }

    enum Columns {
        static let id         = Column(CodingKeys.id)
        static let ts         = Column(CodingKeys.ts)
        static let context    = Column(CodingKeys.context)
        static let role       = Column(CodingKeys.role)
        static let content    = Column(CodingKeys.content)
        static let templateId = Column(CodingKeys.templateId)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Database

/// Write-only log of LLM chat turns stored in chat.sqlite.
final class ChatDB: Sendable {
    private let queue: DatabaseQueue

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    static func makeDefault() throws -> ChatDB {
        let docsURL = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dbURL = docsURL.appendingPathComponent("chat.sqlite")
        return try open(path: dbURL.path)
    }

    static func open(path: String) throws -> ChatDB {
        let q = try DatabaseQueue(path: path)
        let db = ChatDB(queue: q)
        try db.runMigrations()
        return db
    }

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "turns") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .integer).notNull()
                t.column("context", .text).notNull()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("template_id", .text)
            }
            try db.create(index: "turns_context", on: "turns", columns: ["context"])
        }
        try migrator.migrate(queue)
    }

    /// Fetch organic (templateId IS NULL) turns for a context tag, optionally filtered by a time window.
    /// afterMs and beforeMs are unix epoch milliseconds; pass 0 / .max to skip the bound.
    func organicTurns(context: String, afterMs: Int64 = 0, beforeMs: Int64 = .max) async -> [ChatTurn] {
        do {
            return try await queue.read { db in
                try ChatTurn
                    .filter(ChatTurn.Columns.context == context)
                    .filter(ChatTurn.Columns.templateId == nil)
                    .filter(ChatTurn.Columns.ts >= afterMs)
                    .filter(ChatTurn.Columns.ts <= beforeMs)
                    .order(ChatTurn.Columns.ts)
                    .fetchAll(db)
            }
        } catch {
            print("[ChatDB] organicTurns failed: \(error)")
            return []
        }
    }

    /// Append a single turn. Silently ignores errors so a logging failure never interrupts the UI.
    func append(context: ChatContext, role: String, content: String, templateId: String?) async {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let turn = ChatTurn(ts: ts, context: context.tag, role: role, content: content, templateId: templateId)
        print("[ChatDB] appending \(role) to \(context.tag), len=\(content.count)")
        do {
            try await queue.write { db in
                try turn.insert(db)
            }
            print("[ChatDB] appended OK")
        } catch {
            print("[ChatDB] append failed: \(error)")
        }
    }
}
