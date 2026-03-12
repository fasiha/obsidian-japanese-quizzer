// TestHarness/main.swift
// CLI tool to exercise question generation for a given JMDict word ID.
// Usage: TestHarness <word_id> [facet]
// Facet defaults to "reading-to-meaning". Other options:
//   meaning-to-reading, kanji-to-reading, meaning-reading-to-kanji
// Reads ANTHROPIC_API_KEY from .env in the project root (two levels up from Pug/).

import Foundation
import GRDB

// MARK: - Setup

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: TestHarness <word_id> [facet]\n", stderr)
    exit(1)
}
let wordId = args[1]
let facet  = args.count >= 3 ? args[2] : "reading-to-meaning"

// Load API key from .env (project root is four directories up from this file's build location,
// but we'll resolve relative to the working directory where the user invokes the binary).
func loadEnv() -> [String: String] {
    // Walk up from cwd to find .env
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent(".env")
        if let content = try? String(contentsOf: candidate, encoding: .utf8) {
            var env: [String: String] = [:]
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), trimmed.contains("=") else { continue }
                let parts = trimmed.components(separatedBy: "=")
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
                env[key] = val
            }
            return env
        }
        dir = dir.deletingLastPathComponent()
    }
    return [:]
}

let env = loadEnv()
let apiKey = env["ANTHROPIC_API_KEY"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
guard !apiKey.isEmpty else {
    fputs("Error: ANTHROPIC_API_KEY not found in .env or environment\n", stderr)
    exit(1)
}

// MARK: - Open jmdict.sqlite

// Walk up from cwd to find jmdict.sqlite
func findFile(_ name: String) -> String? {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

guard let jmdictPath = findFile("jmdict.sqlite") else {
    fputs("Error: jmdict.sqlite not found (searched up from cwd)\n", stderr)
    exit(1)
}

// Open read-write so SQLite can create .shm/.wal sidecars (WAL-mode DB at project root).
// The test harness never writes to jmdict, but read-only open fails without an existing .shm.
let jmdictDB = try DatabaseQueue(path: jmdictPath)

// MARK: - Look up word by entry ID

struct EntryData {
    let kanji: [String]
    let kana: [String]
    let meanings: [String]
}

func lookupEntry(id: String) throws -> EntryData? {
    try jmdictDB.read { db in
        guard let row = try Row.fetchOne(db, sql: "SELECT entry_json FROM entries WHERE id = ?", arguments: [id]),
              let jsonStr = row["entry_json"] as? String,
              let data = jsonStr.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let kanji    = (raw["kanji"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let kana     = (raw["kana"]  as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let meanings = (raw["sense"] as? [[String: Any]] ?? []).flatMap { sense -> [String] in
            (sense["gloss"] as? [[String: Any]] ?? [])
                .filter { ($0["lang"] as? String) == "eng" }
                .compactMap { $0["text"] as? String }
        }
        return EntryData(kanji: kanji, kana: kana, meanings: meanings)
    }
}

guard let entry = try lookupEntry(id: wordId) else {
    fputs("Error: word_id \(wordId) not found in jmdict.sqlite\n", stderr)
    exit(1)
}

let wordText = entry.kanji.first ?? entry.kana.first ?? wordId
let hasKanji = !entry.kanji.isEmpty

print("Word:     \(wordText)  (id: \(wordId))")
print("Kana:     \(entry.kana.joined(separator: ", "))")
print("Kanji:    \(entry.kanji.isEmpty ? "(none)" : entry.kanji.joined(separator: ", "))")
print("Meanings: \(entry.meanings.prefix(5).joined(separator: "; "))")
print("Facet:    \(facet)")
print("")

// MARK: - Build QuizItem

let item = QuizItem(
    wordType: "jmdict",
    wordId: wordId,
    wordText: wordText,
    writtenTexts: entry.kanji,
    kanaTexts: entry.kana,
    hasKanji: hasKanji,
    facet: facet,
    status: .reviewed(recall: 0.5, isFree: false, halflife: 24.0),
    meanings: Array(entry.meanings.prefix(5)),
    committedKanji: nil,
    partialKanjiTemplate: nil
)

// MARK: - Open quiz.sqlite (for telemetry logging; optional)

let quizDB: QuizDB?
if let quizPath = findFile("quiz.sqlite") {
    quizDB = try? QuizDB.open(path: quizPath)
} else {
    quizDB = nil
    print("[warn] quiz.sqlite not found — telemetry will not be recorded\n")
}

// MARK: - Run generation

let model  = env["ANTHROPIC_MODEL"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-haiku-4-5-20251001"
let client = AnthropicClient(apiKey: apiKey, model: model)
let toolHandler = ToolHandler(jmdict: jmdictDB, kanjidic: nil, wanikani: WanikaniData(kanjiToComponents: [:], extraDescriptions: [:]), quizDB: quizDB)
let prefs       = UserPreferences()
let tmpPath     = NSTemporaryDirectory() + "testharness-quiz-\(ProcessInfo.processInfo.processIdentifier).sqlite"
let fallbackDB  = try QuizDB.open(path: tmpPath)
let session     = QuizSession(client: client, toolHandler: toolHandler, db: quizDB ?? fallbackDB, preferences: prefs)

session.allCandidates = []  // no vocab context needed for generation test

print("Generating question…\n")
let start = Date()

do {
    let (question, conversation) = try await session.generateQuestionForTesting(item: item)
    let elapsed = Date().timeIntervalSince(start)
    let turns = conversation.count

    print("─────────────────────────────────")
    print(question)
    print("─────────────────────────────────")
    print("")
    print("api_turns: \(turns / 2 + 1)   elapsed: \(String(format: "%.1f", elapsed))s   messages: \(conversation.count)")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
