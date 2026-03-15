// GrammarDumpPrompts.swift
// Dumps all system prompts + user messages for every grammar quiz path (no API calls).
// With --live: sends each prompt to Haiku and validates responses.
//
// Grammar paths (Phase 1A — tier 1 only):
//   production  / multiple-choice-generation
//   recognition / multiple-choice-generation
//   production  / free-grading   (Phase 1B preview — validates SCORE token)
//   recognition / free-grading   (Phase 1B preview — validates SCORE token)
//
// Usage: TestHarness --grammar <topic_id> --dump-prompts
//        TestHarness --grammar <topic_id> --live

import Foundation
import GRDB

// MARK: - Helpers

/// Returns true if the string contains any hiragana, katakana, or kanji characters.
func containsJapanese(_ s: String) -> Bool {
    s.unicodeScalars.contains { scalar in
        let v = scalar.value
        return (v >= 0x3040 && v <= 0x309F)     // hiragana
            || (v >= 0x30A0 && v <= 0x30FF)     // katakana
            || (v >= 0x4E00 && v <= 0x9FFF)     // kanji (CJK Unified Ideographs)
    }
}

// MARK: - Grammar prompt paths

struct GrammarPromptPath {
    let facet: String   // "production" | "recognition"
    let mode: String    // "multiple-choice-generation" | "free-grading"

    var isFreeAnswer: Bool { mode == "free-grading" }

    var label: String {
        let modeLabel = mode == "multiple-choice-generation"
            ? "multiple choice generation"
            : "free-text grading"
        return "\(facet) / \(modeLabel)"
    }
}

/// All grammar paths. Phase 1A only uses the multiple-choice-generation rows;
/// free-grading paths are included as Phase 1B previews.
let allGrammarPaths: [GrammarPromptPath] = [
    GrammarPromptPath(facet: "production",   mode: "multiple-choice-generation"),
    GrammarPromptPath(facet: "recognition",  mode: "multiple-choice-generation"),
    GrammarPromptPath(facet: "production",   mode: "free-grading"),
    GrammarPromptPath(facet: "recognition",  mode: "free-grading"),
]

/// Build a GrammarQuizItem for a given topic and path.
func buildGrammarQuizItem(topic: GrammarTopic, path: GrammarPromptPath,
                           scaffolding: [GrammarScaffoldEntry] = []) -> GrammarQuizItem {
    return GrammarQuizItem(
        topicId:             topic.prefixedId,
        titleEn:             topic.titleEn,
        titleJp:             topic.titleJp,
        level:               topic.level,
        href:                topic.href,
        source:              topic.source,
        equivalenceGroupIds: topic.equivalenceGroup ?? [],
        facet:               path.facet,
        status:              .reviewed(recall: 0.42, isFree: path.isFreeAnswer, halflife: path.isFreeAnswer ? 72.0 : 24.0),
        scaffoldingTopics:   scaffolding
    )
}

/// Print the grammar path header banner.
func printGrammarPathHeader(index: Int, total: Int, path: GrammarPromptPath) {
    print("═══════════════════════════════════════════════════")
    print("PATH \(index + 1)/\(total): \(path.label)")
    print("  facet: \(path.facet)  mode: \(path.mode)")
    print("═══════════════════════════════════════════════════")
    print("")
}

// MARK: - Load grammar.json

/// Load grammar.json by walking up from cwd (same pattern as findFile in main.swift).
func loadGrammarManifest(findFile: (String) -> String?) -> GrammarManifest? {
    guard let path = findFile("grammar.json") else { return nil }
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(GrammarManifest.self, from: data)
}

// MARK: - Dump mode (no API calls)

@MainActor func dumpGrammarPrompts(topic: GrammarTopic, quizDB: QuizDB) {
    let client = AnthropicClient(apiKey: "dummy", model: "dummy")
    let session = GrammarQuizSession(client: client, db: quizDB)

    let paths = allGrammarPaths
    print("# Grammar Prompt Dump for topic: \(topic.prefixedId) — \(topic.titleEn)")
    print("# Level:  \(topic.level)")
    if let jp = topic.titleJp { print("# Title (JP): \(jp)") }
    if let href = topic.href   { print("# Reference:  \(href)") }
    print("# Paths to dump: \(paths.count)")
    print("")
    print("# Review each path below. For each, check:")
    print("# 1. Does the system prompt correctly describe the facet?")
    print("# 2. Does the user message match the mode (multiple choice generation vs free-text grading)?")
    print("# 3. Production: does the English stem NOT reveal the grammar structure?")
    print("# 4. Recognition: does the Japanese stem use the target grammar naturally?")
    print("# 5. Are distractor instructions appropriate?")
    print("# 6. Is the scaffolding section correctly populated?")
    print("")

    for (i, path) in paths.enumerated() {
        let item   = buildGrammarQuizItem(topic: topic, path: path)
        let system = session.systemPrompt(for: item, isGenerating: path.mode == "multiple-choice-generation",
                                          preRecall: 0.42, preHalflife: 24.0)
        let userMsg: String
        if path.mode == "multiple-choice-generation" {
            userMsg = session.questionRequest(for: item)
        } else {
            let stem = session.freeAnswerStem(for: item)
            let sampleAnswer: String
            switch path.facet {
            case "production":   sampleAnswer = "彼は日本語を話すことができます。"
            case "recognition":  sampleAnswer = "This sentence uses the potential form to say 'can do'."
            default:             sampleAnswer = "sample answer"
            }
            userMsg = """
            [App-generated stem shown to student]: \(stem)
            [Student's answer]: \(sampleAnswer)
            """
        }

        printGrammarPathHeader(index: i, total: paths.count, path: path)
        print("── SYSTEM PROMPT ──")
        print(system)
        print("")
        print("── USER MESSAGE ──")
        print(userMsg)
        print("")
    }
}

// MARK: - Live mode (sends prompts to Haiku)

@MainActor func liveGrammarPrompts(topic: GrammarTopic, apiKey: String, model: String,
                                    quizDB: QuizDB,
                                    repeatCount: Int = 1,
                                    genOnly: Bool = false,
                                    onlyFacet: String? = nil) async {
    let allPaths: [GrammarPromptPath]
    if let facet = onlyFacet {
        allPaths = allGrammarPaths.filter { $0.facet == facet }
        if allPaths.isEmpty {
            fputs("Error: no grammar paths found for facet '\(facet)'. Valid facets: production, recognition\n", stderr)
            exit(1)
        }
    } else {
        allPaths = allGrammarPaths
    }

    let client  = AnthropicClient(apiKey: apiKey, model: model)
    let session = GrammarQuizSession(client: client, db: quizDB)

    print("# Live Grammar Prompt Test for topic: \(topic.prefixedId) — \(topic.titleEn)")
    print("# Model:  \(model)")
    print("# Level:  \(topic.level)")
    if let jp = topic.titleJp { print("# Title (JP): \(jp)") }
    print("# Paths to test: \(allPaths.count)")
    print("")

    var passCount = 0
    var failCount = 0
    var results: [(path: GrammarPromptPath, passed: Bool, issue: String?)] = []

    for (i, path) in allPaths.enumerated() {
        if genOnly && path.mode != "multiple-choice-generation" { continue }

        let item = buildGrammarQuizItem(topic: topic, path: path)
        printGrammarPathHeader(index: i, total: allPaths.count, path: path)

        let effectiveRepeats = path.mode == "multiple-choice-generation" ? repeatCount : 1
        let start = Date()

        do {
            if path.mode == "multiple-choice-generation" {
                for rep in 1...effectiveRepeats {
                    if effectiveRepeats > 1 { print("── RUN \(rep)/\(effectiveRepeats) ──") }

                    let (question, mc, conversation) = try await session.generateQuestionForTesting(item: item)
                    let elapsed = Date().timeIntervalSince(start)
                    let turns = conversation.count / 2 + 1

                    print("── RESPONSE ──")
                    print(question)
                    print("")
                    print("api_turns: \(turns)   elapsed: \(String(format: "%.1fs", elapsed))   messages: \(conversation.count)")

                    var issues: [String] = []
                    if mc == nil {
                        issues.append("FAIL: could not parse multiple-choice JSON")
                    } else {
                        let mc = mc!
                        let stemLower = mc.stem.lowercased()

                        switch path.facet {
                        case "production":
                            // Stem should be English only — flag if it contains Japanese characters.
                            if containsJapanese(mc.stem) {
                                issues.append("LEAK: production stem contains Japanese characters")
                            }
                            _ = stemLower   // suppress unused warning
                        case "recognition":
                            // Stem should be Japanese — flag if it contains no Japanese characters.
                            if !containsJapanese(mc.stem) {
                                issues.append("FAIL: recognition stem contains no Japanese characters")
                            }
                        default: break
                        }
                    }

                    let passed = issues.isEmpty
                    if passed {
                        print("✅ PASS")
                        passCount += 1
                    } else {
                        for issue in issues { print("❌ \(issue)") }
                        failCount += 1
                    }
                    results.append((path: path, passed: passed, issue: issues.first))
                }

            } else {
                // Free-text grading (Phase 1B preview).
                let stem = session.freeAnswerStem(for: item)
                let sampleAnswer: String
                switch path.facet {
                case "production":   sampleAnswer = "彼は日本語を話すことができます。"
                case "recognition":  sampleAnswer = "This uses the potential form to express ability."
                default:             sampleAnswer = "sample answer"
                }

                let response = try await session.gradeAnswerForTesting(item: item, stem: stem, answer: sampleAnswer)
                let elapsed = Date().timeIntervalSince(start)

                print("── RESPONSE ──")
                print(response)
                print("")
                print("elapsed: \(String(format: "%.1fs", elapsed))")

                var issues: [String] = []
                let scorePattern = #/SCORE:\s*([\d.]+)/#
                if let match = response.firstMatch(of: scorePattern) {
                    let score = Double(match.1) ?? -1
                    if score < 0.8 {
                        issues.append("WARN: correct answer scored only \(score) (expected ≥0.8)")
                    }
                    print("Parsed SCORE: \(score)")
                } else {
                    issues.append("FAIL: no SCORE token found in response")
                }

                let passed = issues.isEmpty
                if passed {
                    print("✅ PASS")
                    passCount += 1
                } else {
                    for issue in issues { print("❌ \(issue)") }
                    failCount += 1
                }
                results.append((path: path, passed: passed, issue: issues.first))
            }

        } catch {
            print("── ERROR ──")
            print("\(error)")
            failCount += 1
            results.append((path: path, passed: false, issue: "ERROR: \(error)"))
        }
        print("")
    }

    // Summary
    print("═══════════════════════════════════════════════════")
    print("SUMMARY: \(passCount) passed, \(failCount) failed out of \(results.count) checks (\(allPaths.count) base paths)")
    print("═══════════════════════════════════════════════════")
    for (i, r) in results.enumerated() {
        let mark   = r.passed ? "✅" : "❌"
        let detail = r.issue.map { " — \($0)" } ?? ""
        print("  \(mark) \(i + 1). \(r.path.label)\(detail)")
    }
    print("")
}
