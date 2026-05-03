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
// Grammar mode flags:
//   --grammar <topic_id>
//     → switch to grammar quiz mode; all flags below apply only in grammar mode
//   --last-sub-use-index <N>
//     → simulate the sub_use_index stored in the most recent review for this topic+facet.
//       The generation system prompt will direct Haiku to target sub-use index (N+1) mod count.
//       This mirrors iOS behavior where GrammarQuizSession reads quiz_data from the DB.
//
// Reads ANTHROPIC_API_KEY from .env in the project root (two levels up from Pug/).

import Foundation
import GRDB

// MARK: - Setup

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: TestHarness <word_id> [facet] [--grade \"ans1\" \"ans2\" ...]\n", stderr)
    fputs("       TestHarness <word_id> kanji-to-reading --committed-kanji 前,例\n", stderr)
    fputs("       TestHarness <word_id> meaning-reading-to-kanji --committed-kanji 前,例\n", stderr)
    fputs("       TestHarness <word_id> meaning-reading-to-kanji --committed-kanji 前\n", stderr)
    fputs("       TestHarness <word_id> meaning-reading-to-kanji --committed-kanji 閉,籠 --committed-written-form 閉じ籠もる\n", stderr)
    fputs("       TestHarness <word_id> --dump-prompts\n", stderr)
    fputs("       TestHarness --counter-hints > /tmp/counter-hints.html\n", stderr)
    fputs("       TestHarness <word_id> --live [--repeat N] [--gen-only] [--facet <facet>]\n", stderr)
    fputs("       TestHarness --grammar <topic_id> --dump-prompts [--extra-grammar id1,id2] [--last-sub-use-index N]\n", stderr)
    fputs("       TestHarness --grammar <topic_id> --live [--repeat N] [--gen-only] [--facet <facet>] [--tier 2,3] [--extra-grammar id1,id2] [--last-sub-use-index N]\n", stderr)
    fputs("       TestHarness --grammar <topic_id> [facet] [--extra-grammar id1,id2] [--last-sub-use-index N]\n", stderr)
    exit(1)
}

// MARK: - Grammar mode detection

let isGrammarMode: Bool
let grammarTopicId: String?
if let gIdx = args.firstIndex(of: "--grammar"), gIdx + 1 < args.count {
    isGrammarMode  = true
    grammarTopicId = args[gIdx + 1]
} else {
    isGrammarMode  = false
    grammarTopicId = nil
}

let isDumpMode = args.contains("--dump-prompts")
let isLiveMode = args.contains("--live")
let isGenOnly  = args.contains("--gen-only")   // skip free-grading paths in --live mode
let isTestDisambiguation = args.contains("--test-disambiguation")
let isCounterHints = args.contains("--counter-hints")

// --fuzz <area>: run randomized / property-based fuzz tests (no API calls).
// Areas: jmdict, furigana, fillin
// Dispatched after jmdict.sqlite is opened; exits before any word-ID lookup.
let isFuzzMode = args.contains("--fuzz")
let fuzzArea: String?
if isFuzzMode, let fi = args.firstIndex(of: "--fuzz"), fi + 1 < args.count,
   !args[fi + 1].hasPrefix("--") {
    fuzzArea = args[fi + 1]
} else {
    fuzzArea = nil
}

// --facet <name>: restrict --live mode to a single facet (omit to run all facets)
let liveOnlyFacet: String?
if let facetIdx = args.firstIndex(of: "--facet"), facetIdx + 1 < args.count {
    liveOnlyFacet = args[facetIdx + 1]
} else {
    liveOnlyFacet = nil
}
// In grammar mode args[1] is "--grammar", not a word ID; use empty string as placeholder.
let wordId = isGrammarMode ? "" : args[1]

// --extra-grammar topic1,topic2: comma-separated topic IDs that simulate grammar the student knows well.
// These are injected into production tier-3 and recognition tier-2 prompts as extra grammar context,
// which ask Haiku to weave those known patterns into the generated sentence.
// Parsed later (after manifest is loaded) in grammar mode.
let extraGrammarArg: String?
if let sIdx = args.firstIndex(of: "--extra-grammar"), sIdx + 1 < args.count {
    extraGrammarArg = args[sIdx + 1]
} else {
    extraGrammarArg = nil
}

// --extra-grammar-mode all|sample|none
//   all    — include descriptions for all extra grammar topics (default)
//   sample — randomly pick 3 from the list and include their descriptions
//   none   — pass no extra grammar topics at all (baseline; ignores --extra-grammar)
// Purpose: lets us compare prompt verbosity vs. Haiku sentence quality.
enum ExtraGrammarMode { case all, sample, none }
let extraGrammarMode: ExtraGrammarMode
if let mIdx = args.firstIndex(of: "--extra-grammar-mode"), mIdx + 1 < args.count {
    switch args[mIdx + 1] {
    case "all":    extraGrammarMode = .all
    case "sample": extraGrammarMode = .sample
    case "none":   extraGrammarMode = .none
    default:
        fputs("Error: --extra-grammar-mode must be all, sample, or none\n", stderr)
        exit(1)
    }
} else {
    extraGrammarMode = .all
}

// --last-sub-use-index N: simulate the sub_use_index from the most recent grammar review.
// The next quiz will target sub-use (N+1) mod subUses.count, mirroring iOS behavior.
let lastSubUseIndexArg: Int?
if let sIdx = args.firstIndex(of: "--last-sub-use-index"), sIdx + 1 < args.count,
   let n = Int(args[sIdx + 1]) {
    lastSubUseIndexArg = n
} else {
    lastSubUseIndexArg = nil
}

// --tier 2 or --tier 2,3: restrict grammar --live/--dump-prompts to specific tiers
let onlyTiers: Set<Int>?
if let tierIdx = args.firstIndex(of: "--tier"), tierIdx + 1 < args.count {
    let parts = args[tierIdx + 1].components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard !parts.isEmpty else {
        fputs("Error: --tier requires comma-separated integers, e.g. --tier 2 or --tier 2,3\n", stderr)
        exit(1)
    }
    onlyTiers = Set(parts)
} else {
    onlyTiers = nil
}

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

// --committed-kanji 前,例 : comma-separated kanji characters the user has committed to learning.
// Provide all kanji in the word for full commitment; a strict subset for partial commitment.
// Required when using --facet kanji-to-reading or --facet meaning-reading-to-kanji in
// generate/grade mode (those facets need commitment data to build the quiz prompt).
let committedKanjiArg: [String]?
if let ckIdx = args.firstIndex(of: "--committed-kanji"), ckIdx + 1 < args.count {
    committedKanjiArg = args[ckIdx + 1]
        .components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
} else {
    committedKanjiArg = nil
}

// --committed-written-form 閉じ籠もる : the specific orthographic form the user enrolled.
// Optional. When omitted, defaults to entry.writtenTexts.first (the first JMDict kanji form).
// Needed when the committed form is not the first JMDict written form — for example, a word
// with many alternate orthographies (閉じこもる, 閉じ籠もる, …) where the student chose a
// non-default form. Also used as the furigana lookup key when building partial templates.
let committedWrittenFormArg: String?
if let cwIdx = args.firstIndex(of: "--committed-written-form"), cwIdx + 1 < args.count {
    committedWrittenFormArg = args[cwIdx + 1]
} else {
    committedWrittenFormArg = nil
}

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
} else {
    apiKey = env["ANTHROPIC_API_KEY"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    guard !apiKey.isEmpty else {
        fputs("Error: ANTHROPIC_API_KEY not found in .env or environment\n", stderr)
        exit(1)
    }
}

// MARK: - Open jmdict.sqlite (and shared file-finder)

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

// MARK: - Disambiguation test mode (exits before jmdict is needed)

if isTestDisambiguation {
    let model  = env["ANTHROPIC_MODEL"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-haiku-4-5-20251001"
    let client = AnthropicClient(apiKey: apiKey, model: model)
    await testDisambiguation(client: client)
    exit(0)
}

// MARK: - Counter hints HTML dump (--counter-hints, no API calls)

if isCounterHints {
    guard let countersPath = findFile("Counters/counters.json"),
          let data = try? Data(contentsOf: URL(fileURLWithPath: countersPath)),
          let counters = try? JSONDecoder().decode([Counter].self, from: data) else {
        fputs("Error: could not load Counters/counters.json\n", stderr)
        exit(1)
    }

    var html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Counter hints preview</title>
    <style>
      body { font-family: sans-serif; font-size: 14px; padding: 1em; }
      table { border-collapse: collapse; width: 100%; }
      th, td { border: 1px solid #ccc; padding: 6px 10px; vertical-align: top; }
      th { background: #f0f0f0; }
      .teal { color: teal; }
      .category { color: #888; font-size: 12px; }
    </style>
    </head>
    <body>
    <h1>Counter hints preview</h1>
    <table>
    <thead>
      <tr>
        <th>Counter</th>
        <th>What it counts</th>
        <th>Rendaku hint</th>
        <th>4 / 7 / 9 hint</th>
        <th>Quiz numbers</th>
      </tr>
    </thead>
    <tbody>
    """

    for c in counters {
        let kanji = c.kanji.replacingOccurrences(of: "&", with: "&amp;")
        let reading = c.reading
        let whatItCounts = c.whatItCounts.replacingOccurrences(of: "&", with: "&amp;")
        let rendaku = c.rendakuHint.replacingOccurrences(of: "&", with: "&amp;")
        let classical = c.classicalNumberHint.replacingOccurrences(of: "&", with: "&amp;")
        let quizNums = c.quizNumbers.joined(separator: ", ")
        html += """
          <tr>
            <td><strong>\(kanji)</strong> (\(reading))<br><span class="category">\(c.category)</span></td>
            <td>\(whatItCounts)</td>
            <td class="teal">\(rendaku)</td>
            <td class="teal">\(classical)</td>
            <td>\(quizNums)</td>
          </tr>
        """
    }

    html += """
    </tbody>
    </table>
    </body>
    </html>
    """

    print(html)
    exit(0)
}

// MARK: - Grammar mode dispatch (exits before jmdict is needed)

if isGrammarMode {
    guard let topicId = grammarTopicId, !topicId.isEmpty else {
        fputs("Error: --grammar requires a topic ID, e.g. --grammar genki:potential-verbs\n", stderr)
        exit(1)
    }

    guard let manifest = loadGrammarManifest(findFile: findFile) else {
        fputs("Error: grammar/all-topics.json not found — run: node grammar/generate-all-topics.mjs\n", stderr)
        exit(1)
    }

    guard let topic = manifest.topics[topicId] else {
        let known = manifest.topics.keys.sorted().prefix(10).joined(separator: "\n  ")
        fputs("Error: topic '\(topicId)' not found\nKnown topics (first 10):\n  \(known)\n", stderr)
        exit(1)
    }

    // Warn when description is missing or was generated without user content sentences (stub).
    if topic.summary == nil {
        fputs("Warning: topic '\(topicId)' has no description in grammar/grammar-equivalences.json.\n", stderr)
        fputs("  Quiz prompts will be less informative. Run /cluster-grammar-topics to enrich it.\n", stderr)
    } else if topic.isStub == true {
        fputs("Warning: topic '\(topicId)' description is a stub (generated without user content sentences).\n", stderr)
        fputs("  Annotate the topic in a Markdown file and re-run /cluster-grammar-topics to improve it.\n", stderr)
    }
    if topic.classicalJapanese == true {
        fputs("Warning: topic '\(topicId)' is a Classical Japanese topic (reference-only).\n", stderr)
        fputs("  Classical topics are filtered out of the quiz pool and should not reach the harness.\n", stderr)
    }

    // Resolve --extra-grammar topic1,topic2 into GrammarExtraTopic values.
    // Unknown IDs are warned about but not fatal, so the user can still test with partial lists.
    var extraGrammarTopics: [GrammarExtraTopic] = []
    if extraGrammarMode != .none, let raw = extraGrammarArg {
        let ids = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for id in ids {
            if let t = manifest.topics[id] {
                extraGrammarTopics.append(GrammarExtraTopic(topicId: t.prefixedId, titleEn: t.titleEn, summary: t.summary))
            } else {
                fputs("Warning: --extra-grammar topic '\(id)' not found — skipping\n", stderr)
            }
        }
        if extraGrammarMode == .sample && extraGrammarTopics.count > 3 {
            extraGrammarTopics = Array(extraGrammarTopics.shuffled().prefix(3))
        }
    }

    let grammarFacet = liveOnlyFacet ?? "production"
    let tmpPath   = NSTemporaryDirectory() + "testharness-grammar-\(ProcessInfo.processInfo.processIdentifier).sqlite"
    let grammarDB = try QuizDB.open(path: tmpPath)

    // Open jmdict.sqlite for vocab resolution (optional — fall back to Haiku glosses if absent).
    let grammarJmdict: (any DatabaseReader)?
    if let jmdictPath = findFile("jmdict.sqlite") {
        grammarJmdict = try? DatabaseQueue(path: jmdictPath)
    } else {
        grammarJmdict = nil
        if isLiveMode {
            fputs("[warn] jmdict.sqlite not found — vocab resolution will use Haiku glosses only\n", stderr)
        }
    }

    print("Topic:  \(topic.prefixedId) — \(topic.titleEn)")
    if let jp = topic.titleJp { print("JP:     \(jp)") }
    print("Level:  \(topic.level)")
    print("Facet:  \(grammarFacet)")
    print("")

    if !extraGrammarTopics.isEmpty {
        print("Extra grammar topics: \(extraGrammarTopics.map { $0.topicId }.joined(separator: ", "))")
        print("")
    }
    if let idx = lastSubUseIndexArg {
        print("Last sub-use index (mocked): \(idx)")
        print("")
    }

    if isDumpMode {
        dumpGrammarPrompts(topic: topic, quizDB: grammarDB,
                           extraGrammarTopics: extraGrammarTopics,
                           lastSubUseIndex: lastSubUseIndexArg,
                           onlyTiers: onlyTiers)
        try? FileManager.default.removeItem(atPath: tmpPath)
        exit(0)
    }

    if isLiveMode {
        let liveModel = env["ANTHROPIC_MODEL"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-haiku-4-5-20251001"
        await liveGrammarPrompts(topic: topic, apiKey: apiKey, model: liveModel,
                                  quizDB: grammarDB, jmdict: grammarJmdict,
                                  repeatCount: repeatCount,
                                  genOnly: isGenOnly, onlyFacet: liveOnlyFacet,
                                  onlyTiers: onlyTiers,
                                  extraGrammarTopics: extraGrammarTopics,
                                  lastSubUseIndex: lastSubUseIndexArg)
        try? FileManager.default.removeItem(atPath: tmpPath)
        exit(0)
    }

    // Default: single-item generation
    print("Generating question…\n")
    let model   = env["ANTHROPIC_MODEL"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-haiku-4-5-20251001"
    let client  = AnthropicClient(apiKey: apiKey, model: model)
    let session = GrammarQuizSession(client: client, db: grammarDB)
    session.extraGrammarTopics = extraGrammarTopics
    session.jmdict = grammarJmdict

    let item = buildGrammarQuizItem(topic: topic,
                                    path: GrammarPromptPath(facet: grammarFacet, tier: 1, mode: "multiple-choice-generation"),
                                    extraGrammarTopics: extraGrammarTopics,
                                    lastSubUseIndex: lastSubUseIndexArg)
    let start = Date()
    do {
        let (question, _, conversation) = try await session.generateQuestionForTesting(item: item)
        let elapsed = Date().timeIntervalSince(start)
        print("─────────────────────────────────")
        print(question)
        print("─────────────────────────────────")
        print("")
        print("api_turns: \(conversation.count / 2 + 1)   elapsed: \(String(format: "%.1f", elapsed))s   messages: \(conversation.count)")

        if let task = session.vocabTask {
            let vocab = await task.value
            print("")
            print("── VOCAB ASSUMED ──")
            if vocab.isEmpty {
                print("  (none)")
            } else {
                for v in vocab {
                    let source = v.jmdictWordIds.map { ids in "[JMDict:\(ids.joined(separator: ","))]" } ?? "[Haiku]"
                    let preview = String(v.gloss.prefix(60))
                    let suffix  = v.gloss.count > 60 ? "…" : ""
                    print("  \(v.word): \(preview)\(suffix)  \(source)")
                }
                let jmdictCount = vocab.filter { $0.jmdictWordIds != nil }.count
                let haikuCount  = vocab.filter { $0.jmdictWordIds == nil }.count
                print("  Resolution: \(jmdictCount) JMDict, \(haikuCount) Haiku fallback")
            }
        }
    } catch {
        fputs("Error: \(error)\n", stderr)
        try? FileManager.default.removeItem(atPath: tmpPath)
        exit(1)
    }
    try? FileManager.default.removeItem(atPath: tmpPath)
    exit(0)
}

guard let jmdictPath = findFile("jmdict.sqlite") else {
    fputs("Error: jmdict.sqlite not found (searched up from cwd)\n", stderr)
    exit(1)
}

// Open read-write so SQLite can create .shm/.wal sidecars (WAL-mode DB at project root).
// The test harness never writes to jmdict, but read-only open fails without an existing .shm.
let jmdictDB = try DatabaseQueue(path: jmdictPath)

// MARK: - Fuzz mode (needs jmdict; exits before word-ID lookup)

if isFuzzMode {
    guard let area = fuzzArea else {
        fputs("Error: --fuzz requires an area (e.g. jmdict, furigana, fillin, ebisu, partial-template, romaji, commit-progression, kanjidic2, counters, all)\n", stderr)
        exit(1)
    }
    try await runFuzz(area: area, jmdict: jmdictDB)
    exit(0)
}

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

// Furigana is needed for dump/live modes and for kanji-facet generate/grade mode when
// the user provides --committed-kanji (so partial-commitment templates can be computed).
let needsFurigana = isDumpMode || isLiveMode ||
    ((facet == "kanji-to-reading" || facet == "meaning-reading-to-kanji") && committedKanjiArg != nil)
let furiganaMap: [String: [JmdictFuriganaEntry]]
if needsFurigana {
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
    dumpPrompts(entry: entry, wordId: wordId, jmdict: jmdictDB, furiganaMap: furiganaMap,
                committedWrittenFormOverride: committedWrittenFormArg,
                committedKanjiOverride: committedKanjiArg)
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

// Build kanji commitment data from --committed-kanji when provided.
// partialKanjiTemplate is built from JmdictFurigana (already loaded above when needed).
// --committed-written-form overrides the default (entry.writtenTexts.first) so that
// alternate-orthography words (e.g. 閉じ籠もる vs. the first JMDict form 閉じこもる)
// are handled correctly for both the prompt and the furigana lookup.
let itemCommittedKanji: [String]?
let itemPartialKanjiTemplate: String?
let itemCommittedWrittenText: String?
if let committed = committedKanjiArg, !committed.isEmpty {
    itemCommittedKanji = committed
    let enrolledForm = committedWrittenFormArg ?? entry.writtenTexts.first ?? entry.kanaTexts.first
    itemCommittedWrittenText = enrolledForm
    // Build partial template if user committed only a subset of the word's kanji.
    let allKanjiInForm: [String] = (enrolledForm ?? "").unicodeScalars
        .filter { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) ||
                  ($0.value >= 0x3400 && $0.value <= 0x4DBF) ||
                  ($0.value >= 0xF900 && $0.value <= 0xFAFF) }
        .map { String($0) }
    let committedSet = Set(committed)
    let hasUncommitted = !Set(allKanjiInForm).subtracting(committedSet).isEmpty
    if hasUncommitted,
       let written = enrolledForm,
       let reading = entry.kanaTexts.first,
       let furigana = lookupFurigana(text: written, reading: reading, furiganaMap: furiganaMap) {
        itemPartialKanjiTemplate = buildPartialTemplate(furigana: furigana, committedKanji: committedSet)
    } else {
        itemPartialKanjiTemplate = nil
    }
} else {
    itemCommittedKanji = nil
    itemPartialKanjiTemplate = nil
    itemCommittedWrittenText = nil
}

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
    committedKanji: itemCommittedKanji,
    partialKanjiTemplate: itemPartialKanjiTemplate,
    committedReading: nil,
    committedWrittenText: itemCommittedWrittenText,
    committedFurigana: nil,
    siblingKanaReadings: [],
    corpusSenseIndices: [0],
    kanjiQuizData: nil
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
let toolHandler = ToolHandler(jmdict: jmdictDB, kanjidic: nil, wanikani: WanikaniData(kanjiToComponents: [:], extraDescriptions: [:]), quizDB: quizDB, chatDB: nil)
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
    if (facet == "kanji-to-reading" || facet == "meaning-reading-to-kanji") && committedKanjiArg == nil {
        fputs("Error: \(facet) requires --committed-kanji <kanji1,kanji2,...>\n", stderr)
        fputs("  Provide all kanji in the word for full commitment, or a subset for partial commitment.\n", stderr)
        fputs("  Example: --committed-kanji 前,例\n", stderr)
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
