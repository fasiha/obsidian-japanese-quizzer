// GrammarDumpPrompts.swift
// Dumps all system prompts + user messages for every grammar quiz path (no API calls).
// With --live: sends each prompt to Haiku and validates responses.
//
// Grammar paths (Phase 1A — tiers 1–3):
//   production  / tier-1 / multiple-choice-generation
//   production  / tier-2 / fill-in-the-blank (no LLM grading — string match only, validated locally)
//   production  / tier-3 / free-text-generation + free-grading (SCORE + PASSIVE)
//   recognition / tier-1 / multiple-choice-generation
//   recognition / tier-2 / free-text-generation + free-grading (SCORE + PASSIVE)
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
    let tier: Int       // 1, 2, or 3
    let mode: String    // "multiple-choice-generation" | "fillin-grading" | "free-generation" | "free-grading"

    /// True when this path uses LLM-scored free-text grading (SCORE token).
    var isFreeAnswer: Bool {
        switch facet {
        case "production":  return tier >= 3
        default:            return tier >= 2
        }
    }

    var label: String {
        switch mode {
        case "multiple-choice-generation": return "\(facet) / tier \(tier) / multiple choice generation"
        case "fillin-grading":             return "\(facet) / tier \(tier) / fill-in-the-blank grading (string match fast path)"
        case "fillin-fallback":            return "\(facet) / tier \(tier) / fill-in-the-blank fallback coaching (LLM, multi-turn)"
        case "free-generation":            return "\(facet) / tier \(tier) / free-text stem generation"
        case "free-grading":               return "\(facet) / tier \(tier) / free-text grading (SCORE)"
        default:                           return "\(facet) / tier \(tier) / \(mode)"
        }
    }
}

/// All grammar paths across tiers.
/// Production tier 2 fill-in-the-blank grading uses string match (no LLM) so it has its own
/// "fillin-grading" mode that the test harness validates locally.
let allGrammarPaths: [GrammarPromptPath] = [
    // Production — three tiers
    GrammarPromptPath(facet: "production", tier: 1, mode: "multiple-choice-generation"),
    GrammarPromptPath(facet: "production", tier: 2, mode: "multiple-choice-generation"),  // same generation as tier 1
    GrammarPromptPath(facet: "production", tier: 2, mode: "fillin-grading"),              // string match fast path, no LLM
    GrammarPromptPath(facet: "production", tier: 2, mode: "fillin-fallback"),             // coaching conversation when string match fails
    GrammarPromptPath(facet: "production", tier: 3, mode: "free-generation"),             // LLM generates English stem
    GrammarPromptPath(facet: "production", tier: 3, mode: "free-grading"),                // LLM grades with SCORE

    // Recognition — two tiers
    GrammarPromptPath(facet: "recognition", tier: 1, mode: "multiple-choice-generation"),
    GrammarPromptPath(facet: "recognition", tier: 2, mode: "free-generation"),            // LLM generates Japanese stem
    GrammarPromptPath(facet: "recognition", tier: 2, mode: "free-grading"),               // LLM grades with SCORE
]

/// Build a GrammarQuizItem for a given topic and path.
func buildGrammarQuizItem(topic: GrammarTopic, path: GrammarPromptPath,
                           scaffolding: [GrammarScaffoldEntry] = []) -> GrammarQuizItem {
    // Halflife chosen to sit above the tier-N threshold for realistic prompt content.
    let halflife: Double
    switch path.tier {
    case 3:  halflife = 144.0   // above tier-3 threshold (120 h)
    case 2:  halflife = 96.0    // above tier-2 threshold (72 h)
    default: halflife = 24.0
    }
    return GrammarQuizItem(
        topicId:             topic.prefixedId,
        titleEn:             topic.titleEn,
        titleJp:             topic.titleJp,
        level:               topic.level,
        href:                topic.href,
        source:              topic.source,
        equivalenceGroupIds: topic.equivalenceGroup ?? [],
        facet:               path.facet,
        status:              .reviewed(recall: 0.42, isFree: path.isFreeAnswer, halflife: halflife),
        scaffoldingTopics:   scaffolding,
        tier:                path.tier
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
    print("# 1. Does the system prompt correctly describe the facet and tier?")
    print("# 2. Does the user message match the mode?")
    print("# 3. Production: does the English stem NOT reveal the grammar structure?")
    print("# 4. Recognition: does the Japanese stem use the target grammar naturally?")
    print("# 5. Are distractor instructions appropriate (no alternative-correct choices)?")
    print("# 6. Is the scaffolding section correctly populated?")
    print("# 7. Free-grading paths: does the system prompt include SCORE and PASSIVE instructions?")
    print("")

    let halflife: (GrammarPromptPath) -> Double = { path in
        switch path.tier { case 3: return 144.0; case 2: return 96.0; default: return 24.0 }
    }

    for (i, path) in paths.enumerated() {
        let item = buildGrammarQuizItem(topic: topic, path: path)

        printGrammarPathHeader(index: i, total: paths.count, path: path)

        switch path.mode {
        case "multiple-choice-generation":
            let system = session.systemPrompt(for: item, isGenerating: true,
                                              preRecall: 0.42, preHalflife: halflife(path))
            print("── SYSTEM PROMPT ──")
            print(system)
            print("")
            print("── USER MESSAGE ──")
            print(session.questionRequest(for: item))

        case "fillin-grading":
            print("── NOTE ──")
            print("Fill-in-the-blank grading (tier 2 production) fast path: pure string matching in Swift.")
            print("No LLM call. The correct answer is choices[correctIndex] from the tier-1/2 generation")
            print("call. The student's typed answer is normalised (trim, strip 。/、) and compared.")
            print("If this fails, the fillin-fallback coaching path is invoked instead.")
            print("See GrammarQuizSession.gradeFillin(studentAnswer:correctAnswer:).")

        case "fillin-fallback":
            // Show the coaching system prompt with placeholder stem and reference answer.
            let placeholderStem   = "[LLM-generated English context, e.g. 'Describe that you can swim.']"
            let placeholderRef    = "[correct choice from generation, e.g. '泳げます。']"
            let system = session.tier2FallbackSystemPrompt(for: item, stem: placeholderStem,
                                                            referenceAnswer: placeholderRef)
            print("── SYSTEM PROMPT (coaching, multi-turn until SCORE) ──")
            print(system)
            print("")
            print("── TURN 1 USER MESSAGE (student's answer that failed string match) ──")
            print("[e.g. '泳ぐことができます。']")
            print("")
            print("── TURN 2+ (optional, if Haiku asks a coaching question) ──")
            print("[student's follow-up attempt, e.g. '泳げます。']")
            print("Conversation continues until Haiku emits SCORE: X.X or max turns reached.")

        case "free-generation":
            let system = session.systemPrompt(for: item, isGenerating: true,
                                              preRecall: 0.42, preHalflife: halflife(path))
            print("── SYSTEM PROMPT ──")
            print(system)
            print("")
            print("── USER MESSAGE ──")
            switch path.facet {
            case "production":  print(session.tier3ProductionStemRequest(for: item))
            case "recognition": print(session.tier2RecognitionStemRequest(for: item))
            default:            print("(unknown facet)")
            }

        case "free-grading":
            let system = session.systemPrompt(for: item, isGenerating: false,
                                              preRecall: 0.42, preHalflife: halflife(path))
            let placeholderStem: String
            let sampleAnswer: String
            switch path.facet {
            case "production":
                placeholderStem = "[LLM-generated English context, e.g. 'Describe that you can swim.']"
                sampleAnswer    = "泳ぐことができます。"
            case "recognition":
                placeholderStem = "[LLM-generated Japanese sentence, e.g. '彼女は泳げるらしい。']"
                sampleAnswer    = "It seems she can swim. The potential form (れる/られる) is used here."
            default:
                placeholderStem = "[LLM-generated stem]"
                sampleAnswer    = "sample answer"
            }
            print("── SYSTEM PROMPT ──")
            print(system)
            print("")
            print("── USER MESSAGE ──")
            print("[App-generated stem shown to student]: \(placeholderStem)")
            print("[Student's answer]: \(sampleAnswer)")

        default:
            print("(unknown mode: \(path.mode))")
        }
        print("")
    }
}

// MARK: - Live mode (sends prompts to Haiku)

/// Validate a free-grading response: check SCORE token and optionally PASSIVE lines.
/// Returns a list of issue strings (empty = pass).
func validateFreeGradingResponse(_ response: String, minScore: Double = 0.8) -> [String] {
    var issues: [String] = []
    let scorePattern = #/SCORE:\s*([\d.]+)/#
    if let match = response.firstMatch(of: scorePattern) {
        let score = Double(match.1) ?? -1
        if score < minScore {
            issues.append("WARN: correct answer scored \(score) (expected ≥\(minScore))")
        }
        print("Parsed SCORE: \(score)")
    } else {
        issues.append("FAIL: no SCORE token found in response")
    }

    // Validate any PASSIVE lines present have the right format: PASSIVE: <id> <score>
    let passivePattern = #/^PASSIVE:\s*(\S+)\s+([\d.]+)$/#
    for line in response.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("PASSIVE:") {
            if let _ = trimmed.firstMatch(of: passivePattern) {
                print("Parsed PASSIVE line: \(trimmed)")
            } else {
                issues.append("WARN: malformed PASSIVE line: \(trimmed)")
            }
        }
    }
    return issues
}

@MainActor func liveGrammarPrompts(topic: GrammarTopic, apiKey: String, model: String,
                                    quizDB: QuizDB,
                                    repeatCount: Int = 1,
                                    genOnly: Bool = false,
                                    onlyFacet: String? = nil) async {
    var allPaths: [GrammarPromptPath]
    if let facet = onlyFacet {
        allPaths = allGrammarPaths.filter { $0.facet == facet }
        if allPaths.isEmpty {
            fputs("Error: no grammar paths found for facet '\(facet)'. Valid facets: production, recognition\n", stderr)
            exit(1)
        }
    } else {
        allPaths = allGrammarPaths
    }

    // --gen-only skips grading paths (free-grading and fillin-grading).
    if genOnly {
        allPaths = allPaths.filter { $0.mode == "multiple-choice-generation" || $0.mode == "free-generation" }
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
        let item  = buildGrammarQuizItem(topic: topic, path: path)
        printGrammarPathHeader(index: i, total: allPaths.count, path: path)
        let start = Date()

        do {
            switch path.mode {

            case "multiple-choice-generation":
                let effectiveRepeats = repeatCount
                for rep in 1...effectiveRepeats {
                    if effectiveRepeats > 1 { print("── RUN \(rep)/\(effectiveRepeats) ──") }

                    let (question, mc, conversation) = try await session.generateQuestionForTesting(item: item)
                    let elapsed = Date().timeIntervalSince(start)

                    print("── RESPONSE ──")
                    print(question)
                    print("")
                    print("api_turns: \(conversation.count / 2 + 1)   elapsed: \(String(format: "%.1fs", elapsed))   messages: \(conversation.count)")

                    var issues: [String] = []
                    if mc == nil {
                        issues.append("FAIL: could not parse multiple-choice JSON")
                    } else {
                        let mc = mc!
                        switch path.facet {
                        case "production":
                            if containsJapanese(mc.stem) {
                                issues.append("LEAK: production stem contains Japanese characters")
                            }
                        case "recognition":
                            if !containsJapanese(mc.stem) {
                                issues.append("FAIL: recognition stem contains no Japanese characters")
                            }
                        default: break
                        }
                    }

                    let passed = issues.isEmpty
                    if passed { print("✅ PASS"); passCount += 1 }
                    else { for issue in issues { print("❌ \(issue)") }; failCount += 1 }
                    results.append((path: path, passed: passed, issue: issues.first))
                }

            case "fillin-grading":
                // No LLM call — generate a question, then test string-match grading.
                print("── Generating tier-1/2 question to obtain correct answer… ──")
                let genItem = buildGrammarQuizItem(topic: topic,
                    path: GrammarPromptPath(facet: path.facet, tier: 1, mode: "multiple-choice-generation"))
                let (_, mc, _) = try await session.generateQuestionForTesting(item: genItem)
                let elapsed = Date().timeIntervalSince(start)

                var issues: [String] = []
                if let mc = mc {
                    let correct = mc.choices[mc.correctIndex]
                    print("Correct answer: \(correct)")

                    // Test: exact correct answer → should match.
                    let exactMatch = session.gradeFillin(studentAnswer: correct, correctAnswer: correct)
                    if !exactMatch {
                        issues.append("FAIL: exact correct answer did not match itself")
                    } else {
                        print("String match (exact): ✅")
                    }

                    // Test: wrong answer → should not match (will trigger fallback in production).
                    let wrongChoice = mc.choices.indices.filter { $0 != mc.correctIndex }.first
                        .map { mc.choices[$0] } ?? "wrong answer"
                    let wrongMatch = session.gradeFillin(studentAnswer: wrongChoice, correctAnswer: correct)
                    if wrongMatch {
                        issues.append("WARN: wrong answer matched correct answer (may be near-duplicates)")
                    } else {
                        print("String match (wrong): ✅ correctly rejected — fallback would fire")
                    }

                    // Test: correct answer without trailing punctuation → should match (normalization).
                    let stripped = correct.replacingOccurrences(of: "。", with: "")
                                         .replacingOccurrences(of: "、", with: "")
                    let strippedMatch = session.gradeFillin(studentAnswer: stripped, correctAnswer: correct)
                    if !strippedMatch {
                        issues.append("WARN: punctuation-stripped answer did not match (normalization may be too strict)")
                    } else {
                        print("String match (stripped punctuation): ✅")
                    }
                } else {
                    issues.append("FAIL: could not generate a question to derive the correct answer")
                }
                print("elapsed: \(String(format: "%.1fs", elapsed))")

                let passed = issues.isEmpty
                if passed { print("✅ PASS"); passCount += 1 }
                else { for issue in issues { print("❌ \(issue)") }; failCount += 1 }
                results.append((path: path, passed: passed, issue: issues.first))

            case "fillin-fallback":
                // Test the coaching conversation:
                // 1. Generate a question to obtain stem + correct answer.
                // 2. Send a "related but wrong construction" answer → expect coaching or immediate low score.
                // 3. If Haiku asks a coaching question (no SCORE yet), send the correct answer → expect SCORE ≥ 0.8.
                print("── Generating question to obtain stem and correct answer… ──")
                let fbGenItem = buildGrammarQuizItem(topic: topic,
                    path: GrammarPromptPath(facet: path.facet, tier: 1, mode: "multiple-choice-generation"))
                let (_, fbMC, _) = try await session.generateQuestionForTesting(item: fbGenItem)

                var fbIssues: [String] = []
                if let fbMC = fbMC {
                    let stem    = fbMC.stem
                    let correct = fbMC.choices[fbMC.correctIndex]
                    // Use a wrong distractor as the "student's first attempt" — this always fails
                    // string match and exercises the fallback path.
                    let wrongChoice = fbMC.choices.indices.filter { $0 != fbMC.correctIndex }.first
                        .map { fbMC.choices[$0] } ?? "wrong answer"

                    print("Stem:      \(stem)")
                    print("Reference: \(correct)")
                    print("Student's first attempt (wrong distractor): \(wrongChoice)")
                    print("")

                    let (response1, conversation1) = try await session.gradeTier2FallbackForTesting(
                        item: item, stem: stem, referenceAnswer: correct,
                        studentAnswer: wrongChoice, maxCoachingTurns: 1)

                    print("── HAIKU TURN 1 ──")
                    print(response1)
                    print("")

                    if response1.contains("SCORE:") {
                        // Haiku scored immediately (e.g., clearly wrong answer).
                        let issues2 = validateFreeGradingResponse(response1, minScore: 0.0)
                        // Any SCORE is acceptable here — wrong answer should score low.
                        let scoreIssues = issues2.filter { !$0.hasPrefix("WARN: correct answer scored") }
                        fbIssues.append(contentsOf: scoreIssues)
                        print("Haiku scored immediately (expected for a wrong distractor).")
                    } else {
                        // Haiku asked a coaching question — now send the correct answer.
                        print("Haiku asked a coaching question. Sending correct answer: \(correct)")
                        print("")

                        // Append the coaching question to conversation and send the correct answer.
                        var conversation2 = conversation1
                        conversation2.append(AnthropicMessage(role: "user", content: [.text(correct)]))

                        let (response2, _) = try await session.gradeTier2FallbackForTesting(
                            item: item, stem: stem, referenceAnswer: correct,
                            studentAnswer: correct, maxCoachingTurns: 3)

                        print("── HAIKU TURN 2+ ──")
                        print(response2)
                        print("")

                        let scoreIssues = validateFreeGradingResponse(response2, minScore: 0.8)
                        fbIssues.append(contentsOf: scoreIssues)
                    }
                } else {
                    fbIssues.append("FAIL: could not generate a question to drive the coaching test")
                }

                let fbElapsed = Date().timeIntervalSince(start)
                print("elapsed: \(String(format: "%.1fs", fbElapsed))")

                let fbPassed = fbIssues.isEmpty
                if fbPassed { print("✅ PASS"); passCount += 1 }
                else { for issue in fbIssues { print("❌ \(issue)") }; failCount += 1 }
                results.append((path: path, passed: fbPassed, issue: fbIssues.first))

            case "free-generation":
                let (stem, _) = try await session.generateFreeTextStemForTesting(item: item)
                let elapsed   = Date().timeIntervalSince(start)

                print("── RESPONSE (generated stem) ──")
                print(stem)
                print("")
                print("elapsed: \(String(format: "%.1fs", elapsed))")

                var issues: [String] = []
                if stem.isEmpty {
                    issues.append("FAIL: generated stem is empty")
                } else {
                    switch path.facet {
                    case "production":
                        if containsJapanese(stem) {
                            issues.append("LEAK: tier-3 production stem contains Japanese characters")
                        }
                    case "recognition":
                        if !containsJapanese(stem) {
                            issues.append("FAIL: tier-2 recognition stem contains no Japanese characters")
                        }
                    default: break
                    }
                }

                let passed = issues.isEmpty
                if passed { print("✅ PASS"); passCount += 1 }
                else { for issue in issues { print("❌ \(issue)") }; failCount += 1 }
                results.append((path: path, passed: passed, issue: issues.first))

            case "free-grading":
                // Generate a stem first, then grade a sample correct answer.
                print("── Generating free-text stem… ──")
                let (stem, _) = try await session.generateFreeTextStemForTesting(item: item)
                print("Stem: \(stem)")
                print("")

                let sampleAnswer: String
                switch path.facet {
                case "production":   sampleAnswer = "彼は日本語を話すことができます。"
                case "recognition":  sampleAnswer = "This uses the potential form (られる/れる) to express that someone can do something."
                default:             sampleAnswer = "sample answer"
                }

                print("── Grading sample answer: \(sampleAnswer) ──")
                let response = try await session.gradeAnswerForTesting(item: item, stem: stem, answer: sampleAnswer)
                let elapsed  = Date().timeIntervalSince(start)

                print("── RESPONSE ──")
                print(response)
                print("")
                print("elapsed: \(String(format: "%.1fs", elapsed))")

                let issues = validateFreeGradingResponse(response)
                let passed = issues.isEmpty
                if passed { print("✅ PASS"); passCount += 1 }
                else { for issue in issues { print("❌ \(issue)") }; failCount += 1 }
                results.append((path: path, passed: passed, issue: issues.first))

            default:
                print("Skipping unknown mode: \(path.mode)")
                results.append((path: path, passed: true, issue: nil))
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
    print("SUMMARY: \(passCount) passed, \(failCount) failed out of \(results.count) checks")
    print("═══════════════════════════════════════════════════")
    for (i, r) in results.enumerated() {
        let mark   = r.passed ? "✅" : "❌"
        let detail = r.issue.map { " — \($0)" } ?? ""
        print("  \(mark) \(i + 1). \(r.path.label)\(detail)")
    }
    print("")
}
