// TestHarness/main.swift
// CLI tool to exercise question generation and free-answer grading for a given JMDict word ID.
//
// Modes:
//   generate (default): generates a question via Claude
//   grade:              grades one or more free-text answers via Claude
//   dump-prompts:       dumps all system prompts for every quiz path (no API calls)
//   live:               sends all prompts to Haiku and validates responses
//
// Usage:
//   TestHarness <word_id> [facet]
//     → generate mode; facet defaults to "reading-to-meaning"
//   TestHarness <word_id> [facet] --grade "answer1" "answer2" ...
//     → grade each answer against the app-side stem for the given facet
//   TestHarness <word_id> --dump-prompts
//     → dump all prompt paths for review (pipe to LLM for sanity check)
//   TestHarness <word_id> --live
//     → send all prompt paths to Haiku and validate responses
//
// Reads ANTHROPIC_API_KEY from .env in the project root (two levels up from Pug/).

import Foundation
import GRDB

// MARK: - Setup

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: TestHarness <word_id> [facet] [--grade \"ans1\" \"ans2\" ...]\n", stderr)
    fputs("       TestHarness <word_id> --dump-prompts\n", stderr)
    fputs("       TestHarness <word_id> --live [--repeat N] [--gen-only] [--facet <facet>]\n", stderr)
    exit(1)
}

let isDumpMode = args.contains("--dump-prompts")
let isLiveMode = args.contains("--live")
let isGenOnly  = args.contains("--gen-only")   // skip free-grading paths in --live mode

// --facet <name>: restrict --live mode to a single facet (omit to run all facets)
let liveOnlyFacet: String?
if let facetIdx = args.firstIndex(of: "--facet"), facetIdx + 1 < args.count {
    liveOnlyFacet = args[facetIdx + 1]
} else {
    liveOnlyFacet = nil
}
let wordId = args[1]

// --repeat N: how many times to run each generation path (default 1)
let repeatCount: Int
if let repeatIdx = args.firstIndex(of: "--repeat"), repeatIdx + 1 < args.count,
   let n = Int(args[repeatIdx + 1]), n >= 1 {
    repeatCount = n
} else {
    repeatCount = 1
}

// Parse optional facet (second positional arg, before --grade)
let facet: String
var gradeAnswers: [String] = []

if args.count >= 3 && !args[2].hasPrefix("--") {
    facet = args[2]
} else {
    facet = "reading-to-meaning"
}

// Collect --grade answers
if let gradeIdx = args.firstIndex(of: "--grade") {
    gradeAnswers = Array(args[(gradeIdx + 1)...])
}

let isGradeMode = !gradeAnswers.isEmpty

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
let apiKey: String
if isDumpMode {
    apiKey = "not-needed"  // dump-prompts makes no API calls
} else if isLiveMode {
    apiKey = env["ANTHROPIC_API_KEY"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    guard !apiKey.isEmpty else {
        fputs("Error: ANTHROPIC_API_KEY not found in .env or environment\n", stderr)
        exit(1)
    }
} else {
    apiKey = env["ANTHROPIC_API_KEY"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    guard !apiKey.isEmpty else {
        fputs("Error: ANTHROPIC_API_KEY not found in .env or environment\n", stderr)
        exit(1)
    }
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

// Reuse the canonical iOS implementation — same JSON parsing, xref extraction, and
// irregular-kanji filtering (iK/rK/ik tags) — rather than maintaining a parallel copy.
typealias EntryData = QuizContext.JmdictEntry

guard let entry = try await QuizContext.jmdictWordData(ids: [wordId], jmdict: jmdictDB)[wordId] else {
    fputs("Error: word_id \(wordId) not found in jmdict.sqlite\n", stderr)
    exit(1)
}

let wordText = entry.writtenTexts.first ?? entry.kanaTexts.first ?? wordId
let hasKanji = !entry.writtenTexts.isEmpty

// MARK: - Load JmdictFurigana.json (required for dump-prompts and live modes)

let furiganaMap: [String: [JmdictFuriganaEntry]]
if isDumpMode || isLiveMode {
    guard let furiganaPath = findFile("JmdictFurigana.json") else {
        fputs("Error: JmdictFurigana.json not found (searched up from cwd)\n", stderr)
        fputs("Download from: https://github.com/Doublevil/JmdictFurigana/releases\n", stderr)
        exit(1)
    }
    print("[info] Loading JmdictFurigana.json…")
    furiganaMap = loadJmdictFurigana(path: furiganaPath)
    print("[info] Loaded \(furiganaMap.count) entries from JmdictFurigana.json\n")
} else {
    furiganaMap = [:]
}

// MARK: - Dump prompts mode (no API calls)

if isDumpMode {
    dumpPrompts(entry: entry, wordId: wordId, jmdict: jmdictDB, furiganaMap: furiganaMap)
    exit(0)
}

// MARK: - Live prompts mode (sends all paths to Haiku)

if isLiveMode {
    let liveModel = env["ANTHROPIC_MODEL"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-haiku-4-5-20251001"
    let kanjidicPath = findFile("kanjidic2.sqlite")
    let liveQuizDB: QuizDB?
    if let quizPath = findFile("quiz.sqlite") {
        liveQuizDB = try? QuizDB.open(path: quizPath)
    } else {
        liveQuizDB = nil
    }
    await livePrompts(entry: entry, wordId: wordId, apiKey: apiKey, model: liveModel,
                      jmdict: jmdictDB, kanjidicPath: kanjidicPath, quizDB: liveQuizDB,
                      furiganaMap: furiganaMap, repeatCount: repeatCount, genOnly: isGenOnly,
                      onlyFacet: liveOnlyFacet)
    exit(0)
}

print("Word:     \(wordText)  (id: \(wordId))")
print("Kana:     \(entry.kanaTexts.joined(separator: ", "))")
print("Kanji:    \(entry.writtenTexts.isEmpty ? "(none)" : entry.writtenTexts.joined(separator: ", "))")
print("Meanings: \(entry.senseExtras.flatMap(\.glosses).prefix(5).joined(separator: "; "))")
print("Facet:    \(facet)")
print("")

// MARK: - Build QuizItem

let item = QuizItem(
    wordType: "jmdict",
    wordId: wordId,
    wordText: wordText,
    writtenTexts: entry.writtenTexts,
    kanaTexts: entry.kanaTexts,
    hasKanji: hasKanji,
    facet: facet,
    status: .reviewed(recall: 0.5, isFree: isGradeMode, halflife: 24.0),
    senseExtras: Array(entry.senseExtras.prefix(5)),
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

if isGradeMode {
    // Build the app-side stem (same logic as QuizSession.freeAnswerStem, reproduced here)
    let kana = entry.kanaTexts.first ?? "?"
    let meanings = entry.senseExtras.flatMap(\.glosses).prefix(3).joined(separator: "; ")
    let stem: String
    switch facet {
    case "meaning-to-reading":
        stem = "What is the kana reading for:\n\(meanings.isEmpty ? wordText : meanings)"
    case "reading-to-meaning":
        stem = "What does \(kana) mean?"
    case "kanji-to-reading", "meaning-reading-to-kanji":
        fputs("Error: \(facet) grading is not supported in TestHarness (always multiple choice in app)\n", stderr)
        exit(1)
    default:
        stem = "What is \(wordText)?"
    }

    print("Stem:     \(stem)\n")

    for (i, answer) in gradeAnswers.enumerated() {
        print("── Answer \(i + 1): \"\(answer)\" ──")
        let start = Date()
        do {
            let response = try await session.gradeAnswerForTesting(item: item, stem: stem, answer: answer)
            let elapsed = Date().timeIntervalSince(start)
            print(response)
            print("elapsed: \(String(format: "%.1f", elapsed))s")
        } catch {
            fputs("Error grading answer \(i + 1): \(error)\n", stderr)
        }
        print("")
    }
} else {
    if facet == "kanji-to-reading" || facet == "meaning-reading-to-kanji" {
        fputs("Error: \(facet) generation requires kanji commitment data (not yet supported in TestHarness)\n", stderr)
        exit(1)
    }
    print("Generating question…\n")
    let start = Date()

    do {
        let (question, _, conversation) = try await session.generateQuestionForTesting(item: item)
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
}
