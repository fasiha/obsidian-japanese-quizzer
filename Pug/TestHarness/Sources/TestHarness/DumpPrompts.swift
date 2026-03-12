// DumpPrompts.swift
// Dumps all system prompts + user messages for every quiz path, for a given word.
// No API calls — output is meant to be piped to an LLM for sanity-checking.
//
// Usage: TestHarness <word_id> --dump-prompts

import Foundation
import GRDB

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
        let modeLabel = mode == "multiple-choice-generation" ? "multiple choice generation" : "free-text grading"
        return "\(facet)\(commitLabel) / \(modeLabel)"
    }
}

@MainActor func dumpPrompts(entry: EntryData, wordId: String, jmdict: any DatabaseReader) {
    let wordText = entry.kanji.first ?? entry.kana.first ?? wordId
    let hasKanji = !entry.kanji.isEmpty

    // Detect kanji characters in the written form
    let kanjiChars: [String] = (entry.kanji.first ?? "").unicodeScalars
        .filter { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) ||
                  ($0.value >= 0x3400 && $0.value <= 0x4DBF) ||
                  ($0.value >= 0xF900 && $0.value <= 0xFAFF) }
        .map { String($0) }

    let hasMultipleKanji = kanjiChars.count >= 2

    // Build partial template: first kanji committed, rest replaced with "〇"
    // (We don't have real furigana data, so we simulate with a placeholder)
    let partialTemplate: String?
    if hasMultipleKanji, let written = entry.kanji.first {
        let firstKanji = kanjiChars[0]
        var template = ""
        var foundFirst = false
        for scalar in written.unicodeScalars {
            let s = String(scalar)
            if kanjiChars.contains(s) {
                if !foundFirst && s == firstKanji {
                    template += s
                    foundFirst = true
                } else {
                    template += "〇"
                }
            } else {
                template += s
            }
        }
        partialTemplate = template
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
    print("# Kana:     \(entry.kana.joined(separator: ", "))")
    print("# Kanji:    \(entry.kanji.isEmpty ? "(none)" : entry.kanji.joined(separator: ", "))")
    print("# Meanings: \(entry.meanings.prefix(5).joined(separator: "; "))")
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

        let item = QuizItem(
            wordType: "jmdict",
            wordId: wordId,
            wordText: wordText,
            writtenTexts: entry.kanji,
            kanaTexts: entry.kana,
            hasKanji: hasKanji,
            facet: path.facet,
            status: .reviewed(recall: 0.5, isFree: path.isFreeAnswer, halflife: path.isFreeAnswer ? 72.0 : 24.0),
            meanings: Array(entry.meanings.prefix(5)),
            committedKanji: path.committedKanji,
            partialKanjiTemplate: path.partialKanjiTemplate
        )

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
                sampleAnswer = entry.meanings.first ?? "some meaning"
            case "meaning-to-reading", "kanji-to-reading":
                sampleAnswer = entry.kana.first ?? "かな"
            default:
                sampleAnswer = entry.kanji.first ?? wordText
            }
            userMsg = """
            [App-generated stem shown to student]: \(stem)
            [Student's answer]: \(sampleAnswer)

            (In the real app, the opening chat turn sends: stem + "\\n\\nStudent's answer: " + answer)
            """
        }

        print("═══════════════════════════════════════════════════")
        print("PATH \(i + 1)/\(paths.count): \(path.label)")
        print("  facet: \(path.facet)  mode: \(path.mode)  commitment: \(path.commitment)")
        if let committed = path.committedKanji {
            print("  committed kanji: \(committed.joined(separator: "、"))")
        }
        if let template = path.partialKanjiTemplate {
            print("  partial template: \(template)")
        }
        print("═══════════════════════════════════════════════════")
        print("")
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
