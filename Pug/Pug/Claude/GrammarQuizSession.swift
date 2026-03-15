// GrammarQuizSession.swift
// Manages the two-turn Claude conversation for a single grammar quiz item.
// Phase 1A: tier-1 multiple choice only (both production and recognition facets).
// Phase 1B will add fill-in-the-blank (tier 2) and free-text (tier 3).
//
// Grammar quizzes always require at least one LLM call for question generation —
// unlike vocab where stems can be built locally. Claude generates the English context
// (production) or Japanese sentence (recognition) plus 4 choices.
//
// No tools are used by grammar quizzes (no JMDict, no Kanjidic lookup needed).

import Foundation

// MARK: - Multiple choice question

/// A grammar multiple-choice question returned by Claude.
struct GrammarMultipleChoiceQuestion: Equatable {
    let stem: String        // English context (production) or Japanese sentence (recognition)
    let choices: [String]   // exactly 4 options
    let correctIndex: Int   // 0–3
}

// MARK: - Session

/// Manages a single grammar quiz item's question generation and answer grading.
/// Shared between the iOS app (Phase 1B) and the CLI TestHarness (Phase 1A).
@MainActor
final class GrammarQuizSession {
    let client: AnthropicClient
    let db: QuizDB

    /// Grammar topics the student knows well — included in every system prompt for difficulty scaling.
    /// Populated by the caller from GrammarQuizContext.scaffoldingTopics before calling generate.
    var scaffoldingTopics: [GrammarScaffoldEntry] = []

    /// The most recent multiple-choice result (set by Phase 1B QuizView after student taps).
    /// Included in the post-answer chat system prompt so Claude knows whether they got it right.
    var multipleChoiceResult: String? = nil

    init(client: AnthropicClient, db: QuizDB) {
        self.client = client
        self.db     = db
    }

    // MARK: - TestHarness entry points

    /// Generate a multiple-choice question for a grammar topic.
    /// Returns the formatted question string, the parsed multiple-choice struct, and the raw conversation.
    /// Intended for CLI test harness use; bypasses the phase state machine.
    func generateQuestionForTesting(item: GrammarQuizItem)
        async throws -> (question: String, multipleChoice: GrammarMultipleChoiceQuestion?, conversation: [AnthropicMessage])
    {
        let system   = systemPrompt(for: item, isGenerating: true)
        let initMsg  = AnthropicMessage(role: "user", content: [.text(questionRequest(for: item))])
        return try await runGenerationLoop(for: item, system: system, initMsg: initMsg, label: "test")
    }

    /// Grade a free-text answer for a grammar item. Returns Claude's full response.
    /// Used by TestHarness --grade mode and will be called by Phase 1B free-text quiz UI.
    func gradeAnswerForTesting(item: GrammarQuizItem, stem: String, answer: String) async throws -> String {
        let system  = systemPrompt(for: item, isGenerating: false)
        let opening = "Question you asked me: \(stem)\nMy answer: \(answer)\nPlease grade my answer."
        let messages = [AnthropicMessage(role: "user", content: [.text(opening)])]
        let (text, _, _) = try await client.send(
            messages: messages,
            system: system,
            tools: [],
            maxTokens: 512,
            toolHandler: nil
        )
        return text
    }

    // MARK: - System prompt

    /// Build the system prompt for a grammar quiz item.
    ///
    /// - `isGenerating`: true when asking Claude to generate a question; false when Claude is grading
    ///   a free-text answer or discussing a completed multiple-choice question.
    func systemPrompt(for item: GrammarQuizItem, isGenerating: Bool,
                      preRecall: Double? = nil, preHalflife: Double? = nil,
                      postHalflife: Double? = nil) -> String {
        let ebisuLine: String
        if let r = preRecall, let h = preHalflife {
            if let ph = postHalflife {
                ebisuLine = "recall=\(String(format: "%.2f", r)) halflife=\(String(format: "%.0f", h))h→\(String(format: "%.0f", ph))h"
            } else {
                ebisuLine = "recall=\(String(format: "%.2f", r)) halflife=\(String(format: "%.0f", h))h"
            }
        } else {
            ebisuLine = "new topic"
        }

        let sourceName: String
        switch item.source {
        case "genki":   sourceName = "Genki I & II (textbook)"
        case "bunpro":  sourceName = "Bunpro (online)"
        case "dbjg":    sourceName = "Dictionary of Basic Japanese Grammar"
        default:        sourceName = item.source
        }

        var topicLine = "Target grammar: \(item.topicId) — \(item.titleEn)"
        if let jp = item.titleJp, !jp.isEmpty { topicLine += " (\(jp))" }

        var metaLine = "Level: \(item.level) | Source: \(sourceName)"
        if let href = item.href, !href.isEmpty { metaLine += " | Reference: \(href)" }

        let scaffoldLine: String
        if scaffoldingTopics.isEmpty {
            scaffoldLine = "Scaffolding: (none — student is a beginner; use very simple sentences)"
        } else {
            let list = scaffoldingTopics.prefix(8)
                .map { "- \($0.topicId) — \($0.titleEn)" }
                .joined(separator: "\n")
            scaffoldLine = "Scaffolding — grammar the student knows well (use these patterns in example sentences where natural; do not test them):\n\(list)"
        }

        let facetRule: String
        switch item.facet {
        case "production":
            if isGenerating {
                facetRule = """
                Facet: production — student sees English context, selects the Japanese sentence \
                that correctly uses the target grammar.
                The English stem describes a situation or meaning; it must NOT contain Japanese \
                or reveal the exact target grammar structure.
                All four choices must be complete natural Japanese sentences. Only the correct \
                choice uses the target grammar correctly; the others use plausible but incorrect \
                grammar (wrong conjugation, wrong form, or a different grammar point).
                Distractors: draw on your grammar knowledge — no lookup needed. Make them feel \
                natural and close to correct so the student must truly know the target grammar \
                to distinguish them.
                """
            } else {
                facetRule = """
                Facet tested: production — student was shown English context and chose a Japanese \
                sentence using the target grammar.
                """
            }
        case "recognition":
            if isGenerating {
                facetRule = """
                Facet: recognition — student sees a Japanese sentence, selects the English \
                description that correctly identifies the grammar used.
                The Japanese stem must naturally contain the target grammar. It must NOT contain \
                any English.
                All four choices must be English descriptions of grammar or meaning. Only the \
                correct choice accurately identifies the target grammar in context; the others \
                describe plausible but incorrect interpretations.
                Distractors: draw on your grammar knowledge — no lookup needed. Use descriptions \
                of related grammar points or common confusers.
                """
            } else {
                facetRule = """
                Facet tested: recognition — student was shown a Japanese sentence and identified \
                the grammar/meaning in English.
                """
            }
        default:
            facetRule = isGenerating
                ? "Facet: \(item.facet) — generate an appropriate multiple-choice question."
                : "Facet tested: \(item.facet)."
        }

        let header = """
        You are quizzing a Japanese learner on grammar.
        \(topicLine)
        \(metaLine)
        Memory: \(ebisuLine)
        \(facetRule)
        \(scaffoldLine)
        """

        if isGenerating {
            return header + "\nCRITICAL: Never reveal the answer in the question stem. Silently verify before outputting."
        } else if item.isFreeAnswer {
            return header + """

        Open conversation: student may answer, ask about this grammar point, or mix topics.
        SCORE: X.X (0.0–1.0) — emit this on the same turn you grade. Format exactly: SCORE: X.X — <one grading sentence>. Never emit SCORE on a line by itself with no other prose.
        Scoring is Bayesian confidence, not percentage-correct. Ask: "how confident am I that this answer reflects whether the student actually knows the target grammar?"
        - 1.0: strong evidence they know it — correct or trivially equivalent
        - 0.8–0.9: right idea with a minor error (small conjugation slip, missing particle)
        - 0.5: ambiguous — can't tell if they know it (do NOT use 0.5 as "half credit")
        - 0.1–0.3: shows some understanding but clearly wrong for the target grammar
        - 0.0: completely wrong or off-topic
        NOTES: one sentence on same message as SCORE.
        After grading, stop — do not ask follow-up questions. The student will ask if they want to discuss.
        """
        } else {
            let resultLine = multipleChoiceResult.map { "Multiple choice result: \($0)\n" } ?? ""
            return header + """

        \(resultLine)The student has already answered — scoring is handled by the app. Do NOT emit SCORE.
        The student may ask follow-up questions or move on without chatting. If they ask, engage naturally.
        """
        }
    }

    // MARK: - Question request (user turn for generation)

    /// Build the user message that asks Claude to generate a multiple-choice question.
    func questionRequest(for item: GrammarQuizItem) -> String {
        let choicesDesc: String
        switch item.facet {
        case "production":
            choicesDesc = "All four choices must be complete natural Japanese sentences. Only the correct choice uses the target grammar correctly."
        case "recognition":
            choicesDesc = "All four choices must be English descriptions of grammar or meaning. Only the correct choice accurately identifies the target grammar."
        default:
            choicesDesc = "Provide four answer choices. Only one is correct."
        }

        return """
        Generate ONE multiple-choice question for the \(item.facet) facet.
        Think first if helpful, then end with a ```json code block containing:
        {"stem":"<question text>","choices":["<A>","<B>","<C>","<D>"],"correct":<0-3>}
        \(choicesDesc)
        """
    }

    /// Build the app-side stem for free-text (tier 3) grammar questions.
    /// Phase 1A: grammar free-text is not yet used; this is a placeholder for Phase 1B.
    /// In Phase 1B, the stem will itself be LLM-generated and cached (unlike vocab, which
    /// can derive the stem locally from JMDict data).
    func freeAnswerStem(for item: GrammarQuizItem) -> String {
        switch item.facet {
        case "production":
            return "Write a Japanese sentence using \(item.titleEn) (\(item.topicId))."
        case "recognition":
            return "Explain the grammar used in the following sentence."
        default:
            return "Answer the question about \(item.titleEn)."
        }
    }

    // MARK: - Generation loop (mirrors QuizSession.runGenerationLoop)

    func runGenerationLoop(for item: GrammarQuizItem, system: String,
                           initMsg: AnthropicMessage, label: String)
        async throws -> (question: String, multipleChoice: GrammarMultipleChoiceQuestion?, conversation: [AnthropicMessage])
    {
        var finalQuestion       = ""
        var finalMultipleChoice: GrammarMultipleChoiceQuestion? = nil
        var finalMsgs:           [AnthropicMessage] = []

        for attempt in 1...2 {
            let (raw, msgs, meta) = try await client.send(
                messages: [initMsg],
                system: system,
                tools: [],
                maxTokens: 1024,
                toolHandler: nil
            )
            finalMsgs = msgs

            if let multipleChoice = parseMultipleChoiceJSON(raw) {
                finalMultipleChoice = multipleChoice
                let letters     = ["A", "B", "C", "D"]
                let choicesText = multipleChoice.choices.enumerated()
                    .map { "\(letters[$0])) \($1)" }
                    .joined(separator: "\n")
                finalQuestion = "\(multipleChoice.stem)\n\n\(choicesText)"
            } else {
                print("[GrammarQuizSession] \(label) attempt \(attempt): multiple choice JSON parse failed")
                finalQuestion = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }

            try? await db.log(apiEvent: ApiEvent(
                timestamp:          ISO8601DateFormatter().string(from: Date()),
                eventType:          "question_gen",
                wordId:             item.topicId,
                quizType:           item.facet,
                inputTokens:        meta.totalInputTokens,
                outputTokens:       meta.totalOutputTokens,
                model:              client.model,
                generationAttempt:  attempt,
                apiTurns:           meta.totalTurns,
                firstTurnInputTokens: meta.firstTurnInputTokens,
                questionChars:      finalQuestion.count,
                questionFormat:     "multiple_choice",
                prefetch:           label == "prefetch" ? 1 : 0
            ))

            if finalMultipleChoice != nil || attempt >= 2 { break }
            print("[GrammarQuizSession] \(label) attempt \(attempt): parse failed, retrying")
        }

        return (finalQuestion, finalMultipleChoice, finalMsgs)
    }

    // MARK: - JSON parsing helpers (mirrors QuizSession private helpers)

    func parseMultipleChoiceJSON(_ raw: String) -> GrammarMultipleChoiceQuestion? {
        var search = raw[...]
        while let fenceStart = search.range(of: "```") {
            let afterFence = search[fenceStart.upperBound...]
            let body = afterFence.drop(while: { $0 != "\n" }).dropFirst()
            if let closeRange = body.range(of: "```") {
                let candidate = String(body[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let q = decodeMultipleChoice(from: candidate) { return q }
                search = body[closeRange.upperBound...]
            } else {
                break
            }
        }
        if let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}") {
            return decodeMultipleChoice(from: String(raw[open...close]))
        }
        return nil
    }

    private func decodeMultipleChoice(from text: String) -> GrammarMultipleChoiceQuestion? {
        guard let data = text.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stem = obj["stem"] as? String,
              let choices = obj["choices"] as? [String],
              choices.count == 4,
              let correctIndex = obj["correct"] as? Int,
              (0..<4).contains(correctIndex)
        else { return nil }
        return GrammarMultipleChoiceQuestion(stem: stem, choices: choices, correctIndex: correctIndex)
    }
}
