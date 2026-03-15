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

        // Whether this generation call is for a free-text stem (no choices needed)
        // rather than a multiple-choice question.
        let isFreeTextStemGeneration = isGenerating && (
            (item.facet == "production"  && item.tier >= 3) ||
            (item.facet == "recognition" && item.tier >= 2)
        )

        let facetRule: String
        switch item.facet {
        case "production":
            if isGenerating && !isFreeTextStemGeneration {
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
            } else if isGenerating && isFreeTextStemGeneration {
                facetRule = """
                Facet: production (tier 3, free text) — you will generate a short English \
                sentence or situation for the student to translate into Japanese using the \
                target grammar. No choices or JSON needed — output only the English text.
                The English must NOT contain Japanese or reveal the exact target grammar structure.
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
            if isGenerating && !isFreeTextStemGeneration {
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
            } else if isGenerating && isFreeTextStemGeneration {
                facetRule = """
                Facet: recognition (tier 2, free text) — you will generate a single Japanese \
                sentence that naturally uses the target grammar. No choices or JSON needed — \
                output only the Japanese sentence.
                The sentence must NOT contain English.
                """
            } else if item.tier >= 2 {
                facetRule = """
                Facet tested: recognition (tier 2, free text) — student was shown a Japanese \
                sentence and wrote an English translation.
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
        You are quizzing an English-speaking student who is learning Japanese grammar.
        \(topicLine)
        \(metaLine)
        Memory: \(ebisuLine)
        \(facetRule)
        \(scaffoldLine)
        """

        if isGenerating {
            return header + "\nCRITICAL: Never reveal the answer in the question stem. Silently verify before outputting."
        } else if item.facet == "recognition" && item.isFreeAnswer {
            // Recognition tier 2: single-turn LLM grading of the student's English translation.
            return header + """

        Grade the student's English translation of the Japanese sentence.
        SCORE: X.X (0.0–1.0) — emit on the same turn you grade. Format exactly:
          SCORE: X.X — <one grading sentence>
        Never emit SCORE on a line by itself with no other prose.
        Scoring is Bayesian confidence, not percentage-correct:
        - 1.0: translation captures the meaning of the target grammar correctly
        - 0.8–0.9: right idea with a minor nuance missed
        - 0.5: ambiguous — can't tell if they understood the grammar (do NOT use as "half credit")
        - 0.1–0.3: translation misunderstands the target grammar
        - 0.0: completely wrong or off-topic
        Opportunistic passive grading: if the student's translation also demonstrates understanding \
        of OTHER grammar topics from the grammar topics list below, emit one PASSIVE line per topic \
        on the same turn, after SCORE:
          PASSIVE: <prefixed-topic-id> <score>
        Example: PASSIVE: genki:te-form 0.9
        Only emit PASSIVE for topics where the translation demonstrates correct understanding. \
        If the translation mishandles a non-target grammar topic, do NOT emit a PASSIVE line \
        for it — the student's attention is on the main quiz topic.
        On the same turn you emit SCORE, add one brief sentence explaining your reasoning.
        After grading, stop — do not ask follow-up questions. The student will ask if they want to discuss.
        """
        } else if item.facet == "production" && item.isFreeAnswer {
            // Production tier 3: use the dedicated coaching prompt method instead.
            // This branch should not be reached — callers should use
            // tier3ProductionGradingSystemPrompt() for production tier 3 grading.
            // Fallback: return the header with a note.
            return header + "\n(Production tier 3 grading uses the coaching prompt.)"
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
        let grammarTopicsInstruction: String
        if !item.scaffoldingTopics.isEmpty {
            grammarTopicsInstruction = """
            \nAfter the English text, on a new line write GRAMMAR_TOPICS: followed by a \
            comma-separated list of topic IDs (from the scaffolding list in the system prompt) \
            that a correct Japanese translation would naturally exercise. Omit this line if none apply.
            """
        } else {
            grammarTopicsInstruction = ""
        }
        return """
        Generate ONE English-language situation or sentence for the student to translate \
        into Japanese using the target grammar.
        The English must NOT contain Japanese or reveal the exact grammar structure.
        Keep it to one or two sentences.
        Think step by step if helpful, then write --- on its own line, followed by only \
        the English text (no labels, no JSON).\(grammarTopicsInstruction)
        """
    }

    /// Build the user request message for generating a tier-2 recognition stem.
    /// Tier 2 recognition: the LLM provides a Japanese sentence only (no choices).
    /// The student then writes a free-text English translation.
    func tier2RecognitionStemRequest(for item: GrammarQuizItem) -> String {
        let grammarTopicsInstruction: String
        if !item.scaffoldingTopics.isEmpty {
            grammarTopicsInstruction = """
            \nAfter the Japanese sentence, on a new line write GRAMMAR_TOPICS: followed by a \
            comma-separated list of topic IDs (from the scaffolding list in the system prompt) \
            that the sentence also exercises. Omit this line if none apply.
            """
        } else {
            grammarTopicsInstruction = ""
        }
        return """
        Generate ONE Japanese sentence that naturally uses the target grammar.
        The sentence must NOT contain English.
        Think step by step if helpful, then write --- on its own line, followed by only \
        the Japanese sentence (no labels, no JSON, no furigana annotations).\(grammarTopicsInstruction)
        """
    }

    /// Generate a free-text stem for tier-3 production or tier-2 recognition.
    /// Returns the LLM-generated stem string, any grammar topics the LLM identified
    /// in the sentence, and the raw conversation for caching.
    func generateFreeTextStemForTesting(item: GrammarQuizItem)
        async throws -> (stem: String, grammarTopics: [String], conversation: [AnthropicMessage])
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
        // Parse: strip reasoning before ---, extract GRAMMAR_TOPICS line if present.
        var content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dividerRange = content.range(of: "\n---\n") {
            content = String(content[dividerRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if content.hasPrefix("---\n") {
            content = String(content.dropFirst(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var grammarTopics: [String] = []
        let lines = content.components(separatedBy: .newlines)
        var stemLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("GRAMMAR_TOPICS:") {
                let topicsPart = trimmed.dropFirst("GRAMMAR_TOPICS:".count)
                    .trimmingCharacters(in: .whitespaces)
                grammarTopics = topicsPart.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else {
                stemLines.append(line)
            }
        }
        let stem = stemLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (stem, grammarTopics, msgs)
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
        You are coaching an English-speaking student on a fill-in-the-blank Japanese grammar exercise.
        \(topicLine)
        \(metaLine)\(scaffoldLine)

        The student was shown this English context:
          \(stem)

        One correct reference answer (there may be other valid forms):
          \(referenceAnswer)

        The student typed an answer that did not exactly match. The student MUST use the target \
        grammar form — not a semantically equivalent alternative construction. Evaluate as follows:

        - If their answer correctly uses the target grammar form (even with minor surface \
        differences like spacing or politeness level): emit SCORE immediately.
        - If their answer is grammatically correct Japanese but uses a DIFFERENT construction \
        (e.g. ことができる instead of the potential verb form): do NOT emit SCORE yet. \
        Acknowledge that their answer is valid Japanese, but explain that this exercise is testing \
        the target grammar form specifically. Ask them to rephrase using that form. Wait for their \
        next attempt before scoring.
        - If their answer is close but has a fixable conjugation or particle error: do NOT emit \
        SCORE yet. Ask ONE focused coaching question to guide them toward the correct form. \
        Wait for their next attempt before scoring.
        - If their answer is clearly wrong, off-topic, or shows no understanding: emit SCORE: 0.0 \
        immediately with a brief explanation.
        - If the student cannot produce the target grammar form after coaching: emit SCORE: 0.0–0.2.

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

    // MARK: - Tier-3 production coaching (LLM grading, multi-turn)

    /// Build the system prompt for tier-3 production grading.
    ///
    /// Similar to tier-2 fallback coaching: the student must use the target grammar form.
    /// If they write correct Japanese that uses a different construction, Haiku coaches them
    /// toward the target form. Haiku also points out other errors (particles, conjugation, etc.)
    /// even if they are not the quiz target.
    ///
    /// - Parameters:
    ///   - item: the quiz item (provides topic, facet, scaffolding)
    ///   - stem: the English context the student was asked to translate
    ///   - grammarTopics: topic IDs from the stem generation step (for PASSIVE grading)
    func tier3ProductionGradingSystemPrompt(for item: GrammarQuizItem, stem: String,
                                             grammarTopics: [String]) -> String {
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

        let grammarTopicsLine: String
        if grammarTopics.isEmpty {
            grammarTopicsLine = ""
        } else {
            grammarTopicsLine = "\nGrammar topics present in the prompt sentence (for passive grading):\n"
                + grammarTopics.map { "- \($0)" }.joined(separator: "\n")
        }

        return """
        You are coaching an English-speaking student on a free-text Japanese production exercise.
        \(topicLine)
        \(metaLine)\(grammarTopicsLine)

        The student was shown this English context:
          \(stem)

        The student MUST use the target grammar form — not a semantically equivalent alternative \
        construction. Evaluate as follows:

        - If their answer correctly uses the target grammar form: emit SCORE immediately. \
        Also point out any other errors in their sentence (wrong particles, conjugation mistakes, \
        unnatural phrasing) as brief coaching notes — but these do not lower the SCORE for the \
        target grammar.
        - If their answer is grammatically correct Japanese but uses a DIFFERENT construction \
        (e.g. ことができる instead of the potential verb form): do NOT emit SCORE yet. \
        Acknowledge that their answer is valid Japanese, but explain that this exercise is testing \
        the target grammar form specifically. Ask them to rephrase using that form. Also note any \
        other errors you see. Wait for their next attempt before scoring.
        - If their answer has a fixable conjugation or particle error in the target grammar: \
        do NOT emit SCORE yet. Ask ONE focused coaching question. Wait for the next attempt.
        - If their answer is clearly wrong, off-topic, or shows no understanding: emit SCORE: 0.0 \
        immediately with a brief explanation.
        - If the student cannot produce the target grammar form after coaching: emit SCORE: 0.0–0.2.

        SCORE format (emit on the turn you decide to grade):
          SCORE: X.X — <one grading sentence>
        Scoring scale (Bayesian confidence, for the target grammar only):
        - 1.0: correct target grammar form, clear understanding
        - 0.8–0.9: target grammar form used, very minor slip
        - 0.5: ambiguous — do NOT use as "half credit"; use coaching instead
        - 0.1–0.3: shows partial understanding but could not produce the target grammar form
        - 0.0: completely wrong, off-topic, or gave up

        Opportunistic passive grading: on the same turn you emit SCORE, if the student's response \
        also demonstrates knowledge of grammar topics from the list above, emit one PASSIVE line \
        per topic:
          PASSIVE: <prefixed-topic-id> <score>
        Only emit PASSIVE for topics where the student demonstrates correct usage. \
        If a non-target grammar topic is used incorrectly, do NOT emit a PASSIVE line for it — \
        the student's attention is on the main quiz topic, so errors in other grammar may reflect \
        inattention rather than lack of knowledge. Mention the error in your coaching notes, but \
        skip the PASSIVE update.

        Never emit SCORE on a line by itself. After emitting SCORE, stop — do not ask follow-up \
        questions. The student will ask if they want to discuss further.
        """
    }

    /// Run the tier-3 production grading coaching conversation.
    ///
    /// Called when the student submits a free-text Japanese translation. Haiku may
    /// ask coaching questions across multiple turns before emitting SCORE. The conversation
    /// ends as soon as SCORE appears or the turn limit is reached.
    ///
    /// - Returns: the final Haiku response text (always contains SCORE if successful) and
    ///   the full conversation for display.
    func gradeTier3ProductionForTesting(item: GrammarQuizItem, stem: String,
                                         grammarTopics: [String], studentAnswer: String,
                                         maxCoachingTurns: Int = 4)
        async throws -> (response: String, conversation: [AnthropicMessage])
    {
        let system   = tier3ProductionGradingSystemPrompt(for: item, stem: stem,
                                                           grammarTopics: grammarTopics)
        let opening  = "Question you asked me: \(stem)\nMy answer: \(studentAnswer)\nPlease grade my answer."
        var messages = [AnthropicMessage(role: "user", content: [.text(opening)])]
        var lastResponse = ""

        for turn in 1...maxCoachingTurns {
            let (raw, msgs, _) = try await client.send(
                messages: messages,
                system: system,
                tools: [],
                maxTokens: 512,
                toolHandler: nil
            )
            messages     = msgs
            lastResponse = raw

            if raw.contains("SCORE:") {
                print("[GrammarQuizSession] tier-3 production scored on turn \(turn)")
                break
            }
            if turn == maxCoachingTurns {
                print("[GrammarQuizSession] tier-3 production reached max turns without SCORE")
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
