// DisambiguationTest.swift
// Exercises the `disambiguateGaps` function with synthetic ambiguous sentences.
// Run with: swift run TestHarness --test-disambiguation
//
// Each test case has a full Japanese sentence, a grammar topic ID, and an answer
// substring that appears more than once. We expect the LLM to pick the occurrence
// that actually demonstrates the target grammar, not an incidental one.

import Foundation

struct DisambiguationTestCase {
    let description: String       // Human-readable label
    let topicId: String           // Grammar topic ID passed to disambiguateGaps
    let sentence: String          // Full Japanese sentence
    let answers: [String]         // Correct answer substring(s) — each appears >1 time
    let expectedGapped: String    // The gapped sentence we expect after disambiguation
}

let disambiguationTestCases: [DisambiguationTestCase] = [
    // Possessive の: たかの先輩の車 has two のs, but the first の is part of the name
    // (たかの先輩 — a senpai named Takano). The grammar slot is the second の, which
    // marks possession of 車.
    DisambiguationTestCase(
        description: "Possessive の: first の is part of the name のだ先輩, second の is the grammar slot",
        topicId: "bunpro:の",
        sentence: "のだ先輩の車はとても古い。",
        answers: ["の"],
        expectedGapped: "のだ先輩___車はとても古い。"
    ),

    // Topic marker は: はい、今日は学校に行きます。 — the は in はい is a false positive;
    // the grammar slot is the second は (topic marker for 今日).
    DisambiguationTestCase(
        description: "Topic は: は inside はい is a false positive, grammar slot は marks 今日",
        topicId: "bunpro:は",
        sentence: "はい、今日は学校に行きます。",
        answers: ["は"],
        expectedGapped: "はい、今日___学校に行きます。"
    ),

    // NEGATIVE TEST — て-form chaining: 3 slots, exactly 3 てs present.
    // needsDisambiguation must return false (3 needed, 3 present), no Haiku call.
    DisambiguationTestCase(
        description: "NEGATIVE: て-form with 3 slots and exactly 3 occurrences — no disambiguation needed",
        topicId: "dbjg:-te",
        sentence: "起きて、顔を洗って、学校へ行って授業を受けた。",
        answers: ["て", "て", "て"],
        expectedGapped: "起き___、顔を洗っ___、学校へ行っ___授業を受けた。"
    ),

    // POSITIVE TEST — し listing with 3 slots but 4 しs in the sentence.
    // 少し contains an incidental し; the 3 grammar slots are the listing particles.
    // needsDisambiguation returns true (4 present, 3 needed), Haiku should pick 2,3,4.
    DisambiguationTestCase(
        description: "〜し listing: 3 grammar slots but 少し adds a 4th incidental し — Haiku picks the right 3",
        topicId: "bunpro:のは",
        sentence: "少し疲れたけど、音楽も好きだし、映画も好きだし、本も好きだし、最高の日だった。",
        answers: ["し", "し", "し"],
        expectedGapped: "少し疲れたけど、音楽も好きだ___、映画も好きだ___、本も好きだ___、最高の日だった。"
    ),
]

@MainActor
func testDisambiguation(client: AnthropicClient) async {
    print("# Disambiguation test")
    print("# Model: \(client.model)")
    print("")

    var passed = 0
    var failed = 0

    for (i, tc) in disambiguationTestCases.enumerated() {
        print("══════════════════════════════════════════════")
        print("CASE \(i + 1)/\(disambiguationTestCases.count): \(tc.description)")
        print("Sentence: \(tc.sentence)")
        print("Answers:  \(tc.answers.joined(separator: ", "))")
        print("Topic:    \(tc.topicId)")

        // Build a synthetic tier-2 GrammarMultipleChoiceQuestion
        let question = GrammarMultipleChoiceQuestion(
            stem: "(synthetic test — no English stem)",
            sentence: tc.sentence,
            choices: [tc.answers],   // tier-2 format: one entry, the correct answer
            correctIndex: 0,
            subUse: nil
        )

        let needsIt = question.needsDisambiguation
        print("needsDisambiguation: \(needsIt)")

        let resolved: GrammarMultipleChoiceQuestion
        if needsIt {
            resolved = await disambiguateGaps(question: question, topicId: tc.topicId, client: client)
            print("Resolved gap: \(resolved.resolvedGappedSentence ?? "(nil)")")
        } else {
            resolved = question
            print("Naive gap:    \(resolved.gappedSentence ?? "(nil)")")
        }

        let actual = resolved.displayGappedSentence ?? ""

        // For the negative tests (no disambiguation), verify the gap count matches answer count.
        if !needsIt {
            let gapCount = actual.components(separatedBy: grammarGapToken).count - 1
            if gapCount == tc.answers.count {
                print("PASS: \(gapCount) gap(s) as expected, no Haiku call needed")
                passed += 1
            } else {
                print("FAIL: expected \(tc.answers.count) gap(s), got \(gapCount)")
                failed += 1
            }
        } else {
            // For positive tests, verify exactly one gap was produced.
            let gapCount = actual.components(separatedBy: grammarGapToken).count - 1
            if gapCount == tc.answers.count {
                print("PASS: \(gapCount) gap(s) produced after Haiku disambiguation")
                passed += 1
            } else {
                print("FAIL: expected \(tc.answers.count) gap(s) after disambiguation, got \(gapCount) in: \(actual)")
                failed += 1
            }
        }
        print("")
    }

    print("══════════════════════════════════════════════")
    print("Results: \(passed) passed, \(failed) failed out of \(disambiguationTestCases.count) cases")
}
