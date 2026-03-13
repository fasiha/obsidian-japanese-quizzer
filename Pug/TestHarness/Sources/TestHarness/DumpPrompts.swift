// DumpPrompts.swift
// Dumps all system prompts + user messages for every quiz path, for a given word.
// With --dump-prompts: no API calls — output is meant to be piped to an LLM for sanity-checking.
// With --live: sends each prompt to Haiku and prints the response.
//
// Requires JmdictFurigana.json in the project root (or walked up from cwd).
// Download from: https://github.com/Doublevil/JmdictFurigana/releases
//
// Usage: TestHarness <word_id> --dump-prompts
//        TestHarness <word_id> --live

import Foundation
import GRDB

// MARK: - JmdictFurigana loading

/// One entry from JmdictFurigana.json.
struct JmdictFuriganaEntry: Codable {
    let text: String
    let reading: String
    let furigana: [FuriganaPart]
}

struct FuriganaPart: Codable {
    let ruby: String
    let rt: String?
}

/// Load JmdictFurigana.json and build a lookup keyed by written form (text).
/// Returns [text: [JmdictFuriganaEntry]] since one text can have multiple readings.
func loadJmdictFurigana(path: String) -> [String: [JmdictFuriganaEntry]] {
    guard let data = FileManager.default.contents(atPath: path) else {
        fputs("Error: cannot read JmdictFurigana.json at \(path)\n", stderr)
        exit(1)
    }
    // Strip BOM if present
    let cleanData: Data
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
        cleanData = data.dropFirst(3)
    } else {
        cleanData = data
    }
    guard let entries = try? JSONDecoder().decode([JmdictFuriganaEntry].self, from: cleanData) else {
        fputs("Error: cannot parse JmdictFurigana.json\n", stderr)
        exit(1)
    }
    var lookup: [String: [JmdictFuriganaEntry]] = [:]
    for entry in entries {
        lookup[entry.text, default: []].append(entry)
    }
    return lookup
}

/// Look up furigana for a specific written form + reading combination.
func lookupFurigana(text: String, reading: String, furiganaMap: [String: [JmdictFuriganaEntry]]) -> [FuriganaPart]? {
    guard let entries = furiganaMap[text] else { return nil }
    return entries.first(where: { $0.reading == reading })?.furigana
}

/// Build a partial-kanji template from furigana data, exactly matching the iOS app's logic.
/// Committed kanji stay as-is; uncommitted kanji are replaced with their kana readings (rt).
func buildPartialTemplate(furigana: [FuriganaPart], committedKanji: Set<String>) -> String {
    var template = ""
    for part in furigana {
        if let rt = part.rt, !committedKanji.contains(part.ruby) {
            // Uncommitted kanji → replace with kana reading
            template += rt
        } else {
            // Committed kanji, kana-only segment, or no rt → keep as-is
            template += part.ruby
        }
    }
    return template
}

// MARK: - Path types

/// All paths that can occur for a given word, depending on facet, mode, and kanji commitment.
struct PromptPath {
    let facet: String
    let mode: String           // "multiple-choice-generation" or "free-grading"
    let commitment: String     // "none", "full", "partial"
    let committedKanji: [String]?
    let partialKanjiTemplate: String?

    var isFreeAnswer: Bool { mode == "free-grading" }

    var label: String {
        let commitLabel = commitment == "none" ? "" : " \(commitment.uppercased()) commitment"
        let modeLabel: String
        switch mode {
        case "multiple-choice-generation": modeLabel = "multiple choice generation"
        case "free-grading":               modeLabel = "free-text grading"
        case "free-grading-wrong":         modeLabel = "free-text grading (wrong answer)"
        case "free-meaning-demonstrated":  modeLabel = "free-text MEANING_DEMONSTRATED"
        default:                           modeLabel = mode
        }
        return "\(facet)\(commitLabel) / \(modeLabel)"
    }
}

/// Build the list of prompt paths for a given word's kanji structure.
/// Uses real JmdictFurigana data for partial templates (matching iOS app behavior).
func buildPaths(entry: QuizContext.JmdictEntry, furiganaMap: [String: [JmdictFuriganaEntry]]) -> (paths: [PromptPath], kanjiChars: [String], partialTemplate: String?) {
    let hasKanji = !entry.writtenTexts.isEmpty
    let written = entry.writtenTexts.first ?? ""
    let reading = entry.kanaTexts.first ?? ""

    // Detect kanji characters in the written form
    let kanjiChars: [String] = written.unicodeScalars
        .filter { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) ||
                  ($0.value >= 0x3400 && $0.value <= 0x4DBF) ||
                  ($0.value >= 0xF900 && $0.value <= 0xFAFF) }
        .map { String($0) }

    let hasMultipleKanji = kanjiChars.count >= 2

    // Build partial template using real furigana data
    let partialTemplate: String?
    if hasMultipleKanji {
        guard let furigana = lookupFurigana(text: written, reading: reading, furiganaMap: furiganaMap) else {
            fputs("Error: no JmdictFurigana entry for text='\(written)' reading='\(reading)'\n", stderr)
            fputs("The JmdictFurigana.json file may be outdated or the word may not have furigana data.\n", stderr)
            exit(1)
        }
        // Partial commitment: first kanji committed, rest uncommitted
        let committedSet = Set([kanjiChars[0]])
        let template = buildPartialTemplate(furigana: furigana, committedKanji: committedSet)
        // Only set if there's actually something different (uncommitted kanji were replaced)
        let allKanjiSet = Set(kanjiChars)
        if !allKanjiSet.subtracting(committedSet).isEmpty {
            partialTemplate = template
        } else {
            partialTemplate = nil
        }
    } else {
        partialTemplate = nil
    }

    // --- Three dimensions: facet × mode × commitment ---
    let allFacets = ["reading-to-meaning", "meaning-to-reading", "kanji-to-reading", "meaning-reading-to-kanji"]
    let allModes = ["multiple-choice-generation", "free-grading"]
    let allCommitments: [(label: String, kanji: [String]?, template: String?)]
    if hasKanji {
        var commitments: [(String, [String]?, String?)] = [
            ("none", nil, nil),
            ("full", kanjiChars, nil),
        ]
        if hasMultipleKanji, let tmpl = partialTemplate {
            commitments.append(("partial", [kanjiChars[0]], tmpl))
        }
        allCommitments = commitments
    } else {
        allCommitments = [("none", nil, nil)]
    }

    var paths: [PromptPath] = []
    for facet in allFacets {
        for mode in allModes {
            for (commitLabel, commitKanji, commitTemplate) in allCommitments {
                // Skip rules:
                // 1. kanji-to-reading/meaning-reading-to-kanji require kanji commitment (not "none")
                let isKanjiFacet = facet == "kanji-to-reading" || facet == "meaning-reading-to-kanji"
                if isKanjiFacet && commitLabel == "none" { continue }

                // 2. reading-to-meaning/meaning-to-reading don't use kanji commitment
                let isKanaFacet = facet == "reading-to-meaning" || facet == "meaning-to-reading"
                if isKanaFacet && commitLabel != "none" { continue }

                // 3. meaning-reading-to-kanji is always multiple choice (no free-grading)
                if facet == "meaning-reading-to-kanji" && mode == "free-grading" { continue }

                paths.append(PromptPath(
                    facet: facet, mode: mode, commitment: commitLabel,
                    committedKanji: commitKanji, partialKanjiTemplate: commitTemplate))
            }
        }
    }

    return (paths, kanjiChars, partialTemplate)
}

/// Build a QuizItem for a given path.
func buildQuizItem(entry: QuizContext.JmdictEntry, wordId: String, path: PromptPath) -> QuizItem {
    let wordText = entry.writtenTexts.first ?? entry.kanaTexts.first ?? wordId
    let hasKanji = !entry.writtenTexts.isEmpty
    return QuizItem(
        wordType: "jmdict",
        wordId: wordId,
        wordText: wordText,
        writtenTexts: entry.writtenTexts,
        kanaTexts: entry.kanaTexts,
        hasKanji: hasKanji,
        facet: path.facet,
        status: .reviewed(recall: 0.5, isFree: path.isFreeAnswer, halflife: path.isFreeAnswer ? 72.0 : 24.0),
        senseExtras: Array(entry.senseExtras.prefix(5)),
        committedKanji: path.committedKanji,
        partialKanjiTemplate: path.partialKanjiTemplate
    )
}

/// Print the path header banner.
func printPathHeader(index: Int, total: Int, path: PromptPath) {
    print("═══════════════════════════════════════════════════")
    print("PATH \(index + 1)/\(total): \(path.label)")
    print("  facet: \(path.facet)  mode: \(path.mode)  commitment: \(path.commitment)")
    if let committed = path.committedKanji {
        print("  committed kanji: \(committed.joined(separator: "、"))")
    }
    if let template = path.partialKanjiTemplate {
        print("  partial template: \(template)")
    }
    print("═══════════════════════════════════════════════════")
    print("")
}

// MARK: - Dump mode (no API calls)

@MainActor func dumpPrompts(entry: QuizContext.JmdictEntry, wordId: String, jmdict: any DatabaseReader,
                             furiganaMap: [String: [JmdictFuriganaEntry]]) {
    let wordText = entry.writtenTexts.first ?? entry.kanaTexts.first ?? wordId
    let (paths, kanjiChars, _) = buildPaths(entry: entry, furiganaMap: furiganaMap)

    // Create a dummy session (no API calls needed)
    let client = AnthropicClient(apiKey: "dummy", model: "dummy")
    let tmpPath = NSTemporaryDirectory() + "dump-prompts-\(ProcessInfo.processInfo.processIdentifier).sqlite"
    let fallbackDB = try! QuizDB.open(path: tmpPath)
    let toolHandler = ToolHandler(jmdict: jmdict, kanjidic: nil,
                                  wanikani: WanikaniData(kanjiToComponents: [:], extraDescriptions: [:]),
                                  quizDB: fallbackDB)
    let prefs = UserPreferences()
    let session = QuizSession(client: client, toolHandler: toolHandler, db: fallbackDB, preferences: prefs)

    // Header
    print("# Prompt Dump for word: \(wordText) (id: \(wordId))")
    print("# Kana:     \(entry.kanaTexts.joined(separator: ", "))")
    print("# Kanji:    \(entry.writtenTexts.isEmpty ? "(none)" : entry.writtenTexts.joined(separator: ", "))")
    print("# Meanings: \(entry.senseExtras.flatMap(\.glosses).prefix(5).joined(separator: "; "))")
    print("# Kanji chars: \(kanjiChars.isEmpty ? "(none)" : kanjiChars.joined(separator: ", "))")
    print("# Paths to dump: \(paths.count)")
    print("")
    print("# Review each path below. For each, check:")
    print("# 1. Does the system prompt correctly describe the facet being tested?")
    print("# 2. Does the user message match the mode (multiple choice generation vs free-text grading)?")
    print("# 3. Is the correct answer clearly specified where needed?")
    print("# 4. Are distractor instructions appropriate for the facet and tools available?")
    print("# 5. Is there any answer leakage in the stem/question?")
    print("# 6. Are there any unnecessary or contradictory instructions?")
    print("")

    for (i, path) in paths.enumerated() {
        let isGenerating = path.mode == "multiple-choice-generation"
        let item = buildQuizItem(entry: entry, wordId: wordId, path: path)

        let system = session.systemPrompt(for: item, isGenerating: isGenerating,
                                           preRecall: 0.5, preHalflife: 24.0)

        let userMsg: String
        if isGenerating {
            userMsg = session.questionRequest(for: item)
        } else {
            // For free-text grading, show the stem + a sample student answer
            let stem = session.freeAnswerStem(for: item)
            let sampleAnswer: String
            switch path.facet {
            case "reading-to-meaning":
                sampleAnswer = entry.senseExtras.first?.glosses.first ?? "some meaning"
            case "meaning-to-reading", "kanji-to-reading":
                sampleAnswer = entry.kanaTexts.first ?? "かな"
            default:
                sampleAnswer = entry.writtenTexts.first ?? (entry.kanaTexts.first ?? wordId)
            }
            userMsg = """
            [App-generated stem shown to student]: \(stem)
            [Student's answer]: \(sampleAnswer)

            (In the real app, the opening chat turn sends: stem + "\\n\\nStudent's answer: " + answer)
            """
        }

        printPathHeader(index: i, total: paths.count, path: path)

        print("── SYSTEM PROMPT ──")
        print(system)
        print("")
        print("── USER MESSAGE ──")
        print(userMsg)
        print("")
    }

    // Clean up temp DB
    try? FileManager.default.removeItem(atPath: tmpPath)
}

// MARK: - Live mode (sends prompts to Haiku)

@MainActor func livePrompts(entry: QuizContext.JmdictEntry, wordId: String, apiKey: String, model: String,
                             jmdict: any DatabaseReader, kanjidicPath: String?,
                             quizDB: QuizDB?,
                             furiganaMap: [String: [JmdictFuriganaEntry]],
                             repeatCount: Int = 1,
                             genOnly: Bool = false,
                             onlyFacet: String? = nil) async {
    let wordText = entry.writtenTexts.first ?? entry.kanaTexts.first ?? wordId
    let (allPaths, kanjiChars, _) = buildPaths(entry: entry, furiganaMap: furiganaMap)
    let paths: [PromptPath]
    if let facet = onlyFacet {
        paths = allPaths.filter { $0.facet == facet }
        if paths.isEmpty {
            fputs("Error: no paths found for facet '\(facet)'. Valid facets: reading-to-meaning, meaning-to-reading, kanji-to-reading, meaning-reading-to-kanji\n", stderr)
            exit(1)
        }
    } else {
        paths = allPaths
    }

    // Open kanjidic if available (needed for kanji-to-reading/meaning-reading-to-kanji tool calls)
    let kanjidicDB: DatabaseQueue?
    if let path = kanjidicPath {
        kanjidicDB = try? DatabaseQueue(path: path)
    } else {
        kanjidicDB = nil
    }

    let client = AnthropicClient(apiKey: apiKey, model: model)
    let tmpPath = NSTemporaryDirectory() + "live-prompts-\(ProcessInfo.processInfo.processIdentifier).sqlite"
    let fallbackDB = try! QuizDB.open(path: tmpPath)
    let db = quizDB ?? fallbackDB
    let toolHandler = ToolHandler(jmdict: jmdict, kanjidic: kanjidicDB,
                                  wanikani: WanikaniData(kanjiToComponents: [:], extraDescriptions: [:]),
                                  quizDB: db)
    let prefs = UserPreferences()
    let session = QuizSession(client: client, toolHandler: toolHandler, db: db, preferences: prefs)
    session.allCandidates = []

    // Header
    print("# Live Prompt Test for word: \(wordText) (id: \(wordId))")
    print("# Model:    \(model)")
    print("# Kana:     \(entry.kanaTexts.joined(separator: ", "))")
    print("# Kanji:    \(entry.writtenTexts.isEmpty ? "(none)" : entry.writtenTexts.joined(separator: ", "))")
    print("# Meanings: \(entry.senseExtras.flatMap(\.glosses).prefix(5).joined(separator: "; "))")
    print("# Kanji chars: \(kanjiChars.isEmpty ? "(none)" : kanjiChars.joined(separator: ", "))")
    print("# Kanjidic: \(kanjidicDB != nil ? "loaded" : "NOT FOUND — kanji-to-reading/meaning-reading-to-kanji tool calls will fail")")
    print("# Paths to test: \(paths.count)")
    print("")

    var passCount = 0
    var failCount = 0
    var results: [(path: PromptPath, passed: Bool, issue: String?)] = []

    for (i, path) in paths.enumerated() {
        // --gen-only: skip all free-grading paths
        if genOnly && path.mode != "multiple-choice-generation" { continue }

        let item = buildQuizItem(entry: entry, wordId: wordId, path: path)

        printPathHeader(index: i, total: paths.count, path: path)

        let effectiveRepeats = path.mode == "multiple-choice-generation" ? repeatCount : 1

        let start = Date()
        do {
            if path.mode == "multiple-choice-generation" {
                for rep in 1...effectiveRepeats {
                if effectiveRepeats > 1 { print("── RUN \(rep)/\(effectiveRepeats) ──") }
                // Generation: use the same flow as generateQuestionForTesting
                let (question, mc, conversation) = try await session.generateQuestionForTesting(item: item)
                let elapsed = Date().timeIntervalSince(start)
                let turns = conversation.count / 2 + 1

                print("── RESPONSE ──")
                print(question)
                print("")
                print("api_turns: \(turns)   elapsed: \(String(format: "%.1fs", elapsed))   messages: \(conversation.count)")

                // Validate: check for answer leakage and correct structure
                var issues: [String] = []
                if mc == nil {
                    issues.append("FAIL: could not parse multiple-choice JSON")
                } else {
                    let mc = mc!
                    // Check stem doesn't leak answer
                    let stemLower = mc.stem.lowercased()
                    switch path.facet {
                    case "reading-to-meaning":
                        // Stem should show kana only, not kanji or English meaning
                        for meaning in entry.senseExtras.flatMap(\.glosses).prefix(3) {
                            if stemLower.contains(meaning.lowercased()) {
                                issues.append("LEAK: stem contains meaning '\(meaning)'")
                            }
                        }
                        for kanji in entry.writtenTexts {
                            if mc.stem.contains(kanji) {
                                issues.append("LEAK: stem contains kanji '\(kanji)'")
                            }
                        }
                    case "meaning-to-reading":
                        // Stem should show English only, not kana reading
                        for kana in entry.kanaTexts {
                            if mc.stem.contains(kana) {
                                issues.append("LEAK: stem contains kana '\(kana)'")
                            }
                        }
                    case "kanji-to-reading":
                        // Stem should show kanji only, not kana
                        for kana in entry.kanaTexts {
                            if mc.stem.contains(kana) {
                                issues.append("LEAK: stem contains kana reading '\(kana)'")
                            }
                        }
                    case "meaning-reading-to-kanji":
                        // Stem should show English + kana, never kanji
                        for kanji in entry.writtenTexts {
                            if mc.stem.contains(kanji) {
                                issues.append("LEAK: stem contains kanji '\(kanji)'")
                            }
                        }
                    default: break
                    }

                    // Check correct answer is actually correct
                    let correct = mc.choices[mc.correctIndex]
                    switch path.facet {
                    case "reading-to-meaning":
                        // correct should be an English meaning — hard to auto-validate fully
                        break
                    case "meaning-to-reading":
                        if !entry.kanaTexts.contains(correct) {
                            issues.append("WARN: correct choice '\(correct)' not in entry kana \(entry.kanaTexts)")
                        }
                    case "kanji-to-reading":
                        if !entry.kanaTexts.contains(correct) {
                            issues.append("WARN: correct choice '\(correct)' not in entry kana \(entry.kanaTexts)")
                        }
                    case "meaning-reading-to-kanji":
                        // For full commitment, correct choice is the written form (e.g. 前例).
                        // For partial commitment, Haiku may show the full template (前れい)
                        // OR just the individual kanji that fills the blank (例).
                        // Both are valid UX — accept either.
                        let written = entry.writtenTexts.first ?? ""
                        if let template = path.partialKanjiTemplate {
                            // Extract the uncommitted kanji (those replaced by kana in the template)
                            let committedSet = Set(path.committedKanji ?? [])
                            let allKanji = written.unicodeScalars
                                .filter { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) ||
                                          ($0.value >= 0x3400 && $0.value <= 0x4DBF) ||
                                          ($0.value >= 0xF900 && $0.value <= 0xFAFF) }
                                .map { String($0) }
                            let uncommitted = allKanji.filter { !committedSet.contains($0) }
                            let validAnswers = [template, written] + uncommitted
                            if !validAnswers.contains(correct) {
                                issues.append("WARN: correct choice '\(correct)' not in valid answers \(validAnswers)")
                            }
                        } else {
                            if correct != written {
                                issues.append("WARN: correct choice '\(correct)' != expected '\(written)'")
                            }
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
                } // end for rep

            } else {
                // Free-text grading: send a correct answer and check for SCORE
                let stem = session.freeAnswerStem(for: item)
                let sampleAnswer: String
                switch path.facet {
                case "reading-to-meaning":
                    sampleAnswer = entry.senseExtras.first?.glosses.first ?? "some meaning"
                case "meaning-to-reading", "kanji-to-reading":
                    sampleAnswer = entry.kanaTexts.first ?? "かな"
                default:
                    sampleAnswer = entry.writtenTexts.first ?? (entry.kanaTexts.first ?? wordId)
                }

                let response = try await session.gradeAnswerForTesting(item: item, stem: stem, answer: sampleAnswer)
                let elapsed = Date().timeIntervalSince(start)

                print("── RESPONSE ──")
                print(response)
                print("")
                print("elapsed: \(String(format: "%.1fs", elapsed))")

                // Validate: check for SCORE token
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

                // Check for A/B/C/D references (should not appear in free-grading)
                let abcdPattern = #/\b[ABCD]\)|option [ABCD]/#
                if response.firstMatch(of: abcdPattern) != nil {
                    issues.append("FAIL: response references A/B/C/D options in free-answer mode")
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

                // Extra test: wrong answer — should score low (≤0.3)
                let wrongAnswer: String
                switch path.facet {
                case "reading-to-meaning":
                    wrongAnswer = "butterfly"  // unrelated English meaning
                case "meaning-to-reading", "kanji-to-reading":
                    wrongAnswer = "ぬるぽ"  // nonsense kana
                default:
                    wrongAnswer = "猫猫猫"  // unrelated kanji
                }

                print("")
                print("── WRONG ANSWER TEST ──")
                print("Student answer: \(wrongAnswer)")
                let wrongStart = Date()
                let wrongResponse = try await session.gradeAnswerForTesting(item: item, stem: stem, answer: wrongAnswer)
                let wrongElapsed = Date().timeIntervalSince(wrongStart)
                print(wrongResponse)
                print("elapsed: \(String(format: "%.1fs", wrongElapsed))")

                var wrongIssues: [String] = []
                if let match = wrongResponse.firstMatch(of: scorePattern) {
                    let score = Double(match.1) ?? -1
                    if score > 0.3 {
                        wrongIssues.append("WARN: wrong answer scored \(score) (expected ≤0.3)")
                    }
                    print("Parsed SCORE: \(score)")
                } else {
                    wrongIssues.append("FAIL: no SCORE token found in wrong-answer response")
                }

                let wrongPassed = wrongIssues.isEmpty
                if wrongPassed {
                    print("✅ PASS (wrong answer scored low)")
                    passCount += 1
                } else {
                    for issue in wrongIssues { print("❌ \(issue)") }
                    failCount += 1
                }
                results.append((path: PromptPath(facet: path.facet, mode: "free-grading-wrong",
                                                  commitment: path.commitment,
                                                  committedKanji: path.committedKanji,
                                                  partialKanjiTemplate: path.partialKanjiTemplate),
                                 passed: wrongPassed, issue: wrongIssues.first))

                // Extra test for kanji-to-reading: answer with reading + meaning to elicit MEANING_DEMONSTRATED
                if path.facet == "kanji-to-reading" {
                    let meanings = entry.senseExtras.flatMap(\.glosses).prefix(3).joined(separator: "; ")
                    let kana = entry.kanaTexts.first ?? "?"
                    let meaningAnswer = "\(kana) — it means \(meanings)"

                    print("")
                    print("── MEANING_DEMONSTRATED TEST ──")
                    print("Student answer: \(meaningAnswer)")
                    let mdStart = Date()
                    let mdResponse = try await session.gradeAnswerForTesting(item: item, stem: stem, answer: meaningAnswer)
                    let mdElapsed = Date().timeIntervalSince(mdStart)
                    print(mdResponse)
                    print("elapsed: \(String(format: "%.1fs", mdElapsed))")

                    var mdIssues: [String] = []
                    // Should still have a high SCORE (correct reading given)
                    if let match = mdResponse.firstMatch(of: scorePattern) {
                        let score = Double(match.1) ?? -1
                        if score < 0.8 {
                            mdIssues.append("WARN: correct answer + meaning scored only \(score) (expected ≥0.8)")
                        }
                        print("Parsed SCORE: \(score)")
                    } else {
                        mdIssues.append("FAIL: no SCORE token found")
                    }
                    // Should contain MEANING_DEMONSTRATED token
                    if !mdResponse.contains("MEANING_DEMONSTRATED") {
                        mdIssues.append("FAIL: MEANING_DEMONSTRATED token not found")
                    }

                    let mdPassed = mdIssues.isEmpty
                    if mdPassed {
                        print("✅ PASS (MEANING_DEMONSTRATED emitted)")
                        passCount += 1
                    } else {
                        for issue in mdIssues { print("❌ \(issue)") }
                        failCount += 1
                    }
                    results.append((path: PromptPath(facet: path.facet, mode: "free-meaning-demonstrated",
                                                      commitment: path.commitment,
                                                      committedKanji: path.committedKanji,
                                                      partialKanjiTemplate: path.partialKanjiTemplate),
                                     passed: mdPassed, issue: mdIssues.first))
                }
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
    print("SUMMARY: \(passCount) passed, \(failCount) failed out of \(results.count) checks (\(paths.count) base paths)")
    print("═══════════════════════════════════════════════════")
    for (i, r) in results.enumerated() {
        let mark = r.passed ? "✅" : "❌"
        let detail = r.issue.map { " — \($0)" } ?? ""
        print("  \(mark) \(i + 1). \(r.path.label)\(detail)")
    }
    print("")

    // Clean up temp DB
    try? FileManager.default.removeItem(atPath: tmpPath)
}
