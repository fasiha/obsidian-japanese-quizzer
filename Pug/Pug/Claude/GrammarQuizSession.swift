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
                Facet: production (tier \(item.tier)) — student sees English context, selects or \
                types the Japanese sentence that correctly uses the target grammar.
                The English stem describes a situation or meaning; it must NOT contain Japanese \
                or reveal the exact target grammar structure.
                All four choices must be complete natural Japanese sentences. Only the correct \
                choice uses the target grammar correctly; the others use plausible but incorrect \
                grammar (wrong conjugation, wrong form, or a different grammar point). \
                Do NOT include grammatically correct alternatives that merely use a different \
                construction (e.g. ことができる as a distractor for a potential-verb question) — \
                distractors must be clearly wrong Japanese or wrong grammar form for this meaning.
                Distractors: draw on your grammar knowledge — no lookup needed. Make them feel \
                natural and close to correct so the student must truly know the target grammar \
                to distinguish them.
                """
            } else if item.tier == 3 {
                facetRule = """
                Facet tested: production (tier 3, free text) — student was shown English context \
                and wrote their own Japanese sentence using the target grammar.
                """
            } else {
                // Tier 1 multiple choice discussion or tier 2 fill-in-the-blank discussion.
                facetRule = """
                Facet tested: production (tier \(item.tier)) — student was shown English context \
                and selected/typed a Japanese sentence using the target grammar.
                """
            }
        case "recognition":
            if isGenerating {
                facetRule = """
                Facet: recognition (tier \(item.tier)) — student sees a Japanese sentence, \
                selects or writes the correct natural English translation.
                The Japanese stem must naturally contain the target grammar. It must NOT contain \
                any English.
                All four choices must be natural, idiomatic English translations of the stem. \
                Only the correct choice reflects the meaning of the target grammar; the others \
                are plausible mistranslations that would result from confusing the target grammar \
                with a related grammar point (e.g. confusing potential with obligation, causative \
                with passive, てならない with てはいけない, etc.).
                Do NOT write grammar labels or descriptions as choices — write natural English \
                sentences a fluent speaker would actually say.
                """
            } else if item.tier >= 2 {
                facetRule = """
                Facet tested: recognition (tier 2, free text) — student was shown a Japanese \
                sentence and wrote a free-text explanation of its meaning and grammar.
                """
            } else {
                facetRule = """
                Facet tested: recognition (tier 1) — student was shown a Japanese sentence and \
                chose the correct English translation.
                """
            }
        default:
            facetRule = isGenerating
                ? "Facet: \(item.facet) (tier \(item.tier)) — generate an appropriate multiple-choice question."
                : "Facet tested: \(item.facet) (tier \(item.tier))."
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
            // Tier 3 production and tier 2+ recognition: LLM grades and emits SCORE.
            // Opportunistic passive grading: also score any other enrolled grammar visible in
            // the student's response, using PASSIVE lines (one per topic, same turn as SCORE).
            return header + """

        Open conversation: student may answer, ask about this grammar point, or mix topics.
        SCORE: X.X (0.0–1.0) — emit this on the same turn you grade. Format exactly:
          SCORE: X.X — <one grading sentence>
        Never emit SCORE on a line by itself with no other prose.
        Scoring is Bayesian confidence, not percentage-correct:
        - 1.0: strong evidence they know it — correct or trivially equivalent
        - 0.8–0.9: right idea with a minor error (small conjugation slip, missing particle)
        - 0.5: ambiguous — can't tell if they know it (do NOT use 0.5 as "half credit")
        - 0.1–0.3: shows some understanding but clearly wrong for the target grammar
        - 0.0: completely wrong or off-topic
        Opportunistic passive grading: if the student's response also demonstrates knowledge of \
        OTHER grammar topics (from the scaffolding list or any topic you recognise), emit one \
        PASSIVE line per topic on the same turn, after SCORE:
          PASSIVE: <prefixed-topic-id> <score>
        Example: PASSIVE: genki:te-form 0.9
        Only emit PASSIVE for topics where you have genuine evidence (not mere presence of a form).
        NOTES: one brief sentence on the same message as SCORE.
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
            choicesDesc = "All four choices must be natural English translations of the stem sentence. Only the correct choice reflects the target grammar; the others are plausible mistranslations from confusing it with related grammar points. Do NOT use grammar labels or descriptions — write English sentences."
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

    /// Build the user request message for generating a tier-3 production stem.
    /// Tier 3 production: the LLM provides an English context only (no choices).
    /// The student then writes a full Japanese sentence.
    func tier3ProductionStemRequest(for item: GrammarQuizItem) -> String {
        return """
        Generate ONE English-language situation or sentence for the student to translate \
        into Japanese using the target grammar.
        The English must NOT contain Japanese or reveal the exact grammar structure.
        Keep it to one or two sentences. Output only the English text — no JSON, no labels.
        """
    }

    /// Build the user request message for generating a tier-2 recognition stem.
    /// Tier 2 recognition: the LLM provides a Japanese sentence only (no choices).
    /// The student then writes a free-text English explanation.
    func tier2RecognitionStemRequest(for item: GrammarQuizItem) -> String {
        return """
        Generate ONE Japanese sentence that naturally uses the target grammar.
        The sentence must NOT contain English. Output only the Japanese sentence — no JSON, \
        no labels, no furigana annotations.
        """
    }

    /// Generate a free-text stem for tier-3 production or tier-2 recognition.
    /// Returns the LLM-generated stem string and the raw conversation for caching.
    func generateFreeTextStemForTesting(item: GrammarQuizItem)
        async throws -> (stem: String, conversation: [AnthropicMessage])
    {
        let system = systemPrompt(for: item, isGenerating: true)
        let request: String
        switch item.facet {
        case "production":  request = tier3ProductionStemRequest(for: item)
        case "recognition": request = tier2RecognitionStemRequest(for: item)
        default:            request = "Generate a question stem for the \(item.facet) facet."
        }
        let initMsg = AnthropicMessage(role: "user", content: [.text(request)])
        let (raw, msgs, meta) = try await client.send(
            messages: [initMsg],
            system: system,
            tools: [],
            maxTokens: 256,
            toolHandler: nil
        )
        try? await db.log(apiEvent: ApiEvent(
            timestamp:            ISO8601DateFormatter().string(from: Date()),
            eventType:            "stem_gen",
            wordId:               item.topicId,
            quizType:             item.facet,
            inputTokens:          meta.totalInputTokens,
            outputTokens:         meta.totalOutputTokens,
            model:                client.model,
            generationAttempt:    1,
            apiTurns:             meta.totalTurns,
            firstTurnInputTokens: meta.firstTurnInputTokens,
            questionChars:        raw.count,
            questionFormat:       "free_text_stem",
            prefetch:             0
        ))
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), msgs)
    }

    /// Grade a fill-in-the-blank (tier-2 production) answer by string matching.
    /// Returns true if the student's typed answer matches the correct choice (after normalization).
    /// No LLM call — pure Swift logic.
    func gradeFillin(studentAnswer: String, correctAnswer: String) -> Bool {
        let normalize: (String) -> String = { s in
            s.trimmingCharacters(in: .whitespacesAndNewlines)
             .replacingOccurrences(of: "。", with: "")
             .replacingOccurrences(of: "、", with: "")
        }
        return normalize(studentAnswer) == normalize(correctAnswer)
    }

    // MARK: - Tier-2 fallback coaching (LLM grading when string match fails)

    /// Build the system prompt for the tier-2 production coaching conversation.
    ///
    /// This is used when the student's fill-in-the-blank answer fails string match.
    /// Haiku acts as a coaching tutor: it scores immediately when it has clear signal
    /// (correct grammar form → high score; clearly wrong/off-topic → low score), and
    /// asks a focused Socratic question when the answer is close but not quite right,
    /// waiting for the student to try again before committing a SCORE.
    ///
    /// - Parameters:
    ///   - item: the quiz item (provides topic, facet, scaffolding)
    ///   - stem: the English context shown to the student
    ///   - referenceAnswer: the correct choice from the generation call (one valid form)
    func tier2FallbackSystemPrompt(for item: GrammarQuizItem, stem: String, referenceAnswer: String) -> String {
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
        if item.scaffoldingTopics.isEmpty {
            scaffoldLine = ""
        } else {
            let list = item.scaffoldingTopics.prefix(8)
                .map { "- \($0.topicId) — \($0.titleEn)" }
                .joined(separator: "\n")
            scaffoldLine = "\nGrammar the student knows well (context only):\n\(list)"
        }

        return """
        You are coaching a Japanese learner on a fill-in-the-blank grammar exercise.
        \(topicLine)
        \(metaLine)\(scaffoldLine)

        The student was shown this English context:
          \(stem)

        One correct reference answer (there may be other valid forms):
          \(referenceAnswer)

        The student typed an answer that did not exactly match. Evaluate it as follows:

        - If their answer correctly uses the target grammar (even in a different but valid form): \
        emit SCORE immediately.
        - If their answer is close but uses the wrong construction or has a fixable error: do NOT \
        emit SCORE yet. Ask ONE focused coaching question to guide them toward the target grammar \
        form (e.g. "That means something slightly different — how would you express ability using \
        the potential verb form directly?"). Wait for their next attempt before scoring.
        - If their answer is clearly wrong, off-topic, or shows no understanding: emit SCORE \
        immediately with a brief explanation.

        SCORE format (emit on the turn you decide to grade):
          SCORE: X.X — <one grading sentence>
        Scoring scale (Bayesian confidence):
        - 1.0: correct grammar form, clear understanding
        - 0.8–0.9: right idea, very minor slip
        - 0.5: ambiguous — do NOT use as "half credit"; use coaching instead
        - 0.1–0.3: shows partial understanding but wrong for target grammar
        - 0.0: completely wrong or off-topic
        Never emit SCORE on a line by itself. After emitting SCORE, stop — do not ask follow-up \
        questions. The student will ask if they want to discuss further.
        """
    }

    /// Run the tier-2 production fallback coaching conversation.
    ///
    /// Called when the student's fill-in-the-blank answer fails string match. Haiku may
    /// ask coaching questions across multiple turns before emitting SCORE. The conversation
    /// ends as soon as SCORE appears or the turn limit is reached.
    ///
    /// - Returns: the final Haiku response text (always contains SCORE if successful) and
    ///   the full conversation for display.
    func gradeTier2FallbackForTesting(item: GrammarQuizItem, stem: String,
                                       referenceAnswer: String, studentAnswer: String,
                                       maxCoachingTurns: Int = 4)
        async throws -> (response: String, conversation: [AnthropicMessage])
    {
        let system   = tier2FallbackSystemPrompt(for: item, stem: stem, referenceAnswer: referenceAnswer)
        var messages = [AnthropicMessage(role: "user", content: [.text(studentAnswer)])]
        var lastResponse = ""

        for turn in 1...maxCoachingTurns {
            let (raw, msgs, _) = try await client.send(
                messages: messages,
                system: system,
                tools: [],
                maxTokens: 512,
                toolHandler: nil
            )
            messages    = msgs
            lastResponse = raw

            if raw.contains("SCORE:") {
                print("[GrammarQuizSession] tier-2 fallback scored on turn \(turn)")
                break
            }
            if turn == maxCoachingTurns {
                print("[GrammarQuizSession] tier-2 fallback reached max turns without SCORE")
            }
        }

        return (lastResponse, messages)
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
