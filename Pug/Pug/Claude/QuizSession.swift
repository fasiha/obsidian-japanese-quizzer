// QuizSession.swift
// Observable session that orchestrates one quiz item at a time.
// The conversation is open: the student can answer, ask tangent questions about
// the current word, or ask about completely different words. Claude grades when
// it detects a clear answer (SCORE: X.X).

import Foundation
#if os(iOS)
import UIKit
#endif

@Observable @MainActor
final class QuizSession {

    // MARK: - Phase

    struct MultipleChoiceQuestion: Equatable {
        let stem: String          // question text shown to student, no A/B/C/D
        let choices: [String]     // exactly 4 bare strings
        let correctIndex: Int     // 0–3
    }

    /// Which single leg of a transitive pair is being asked.
    /// nil in a PairQuestion means both legs (pair-discrimination).
    enum AskedLeg: Equatable { case transitive, intransitive }

    struct PairQuestion: Equatable {
        let intransitiveEnglish: String
        let transitiveEnglish: String
        let intransitiveKana: String
        let intransitiveKanji: [String]
        let transitiveKana: String
        let transitiveKanji: [String]
        let intransitiveJapanese: String
        let transitiveJapanese: String
        /// nil = pair-discrimination (both fields shown); non-nil = single-leg (one field shown).
        let askedLeg: AskedLeg?
    }

    enum Phase: Equatable {
        case idle
        case loadingItems
        case generating              // Claude generating multiple choice question (free-answer skips this)
        case awaitingTap(MultipleChoiceQuestion) // multiple choice rendered as buttons; waiting for student tap
        case awaitingText(String)    // free-answer: app-built stem, waiting for typed input
        case awaitingPair(PairQuestion) // pair-discrimination: two text fields, no LLM call
        case chatting                // open conversation after answer submitted
        case noItems
        case finished
        case error(String)
    }

    // MARK: - State

    var phase: Phase = .idle
    var items: [QuizItem] = []
    var currentIndex: Int = 0
    var currentQuestion: String = ""

    // Chat state (active during .chatting)
    var chatMessages: [(isUser: Bool, text: String)] = []
    var chatInput: String = ""
    var isSendingChat: Bool = false
    var gradedScore: Double? = nil          // nil until graded (app-side for multiple choice, Claude for free-answer)
    var multipleChoiceResult: String? = nil           // multiple choice only: human-readable result injected into system prompt
    var meaningBonusApplied: Bool = false  // true once MEANING_DEMONSTRATED passive update has run
    var uncertaintyUnlocked: Bool = false  // true once the "I don't know" unlock button is tapped
    var preQuizRecall: Double? = nil   // recall probability at the start of this item (nil for new words)
    var preQuizHalflife: Double? = nil // halflife (hours) at the start of this item (nil for new words)
    var gradedHalflife: Double? = nil      // updated halflife after recordReview; nil until graded

    // MARK: - Quiz filter

    enum QuizFilter {
        case all
        case vocabOnly
        case pairsOnly
        case countersOnly
    }

    var quizFilter: QuizFilter = .all

    /// When set, the quiz is restricted to words whose source list includes this document title.
    /// Reset to nil before launching a global (non-document-scoped) quiz session.
    var documentScope: String? = nil

    var pairCorpus: TransitivePairCorpus? = nil
    var counterCorpus: CounterCorpus? = nil
    var pairIntransitiveInput: String = ""
    var pairTransitiveInput: String = ""
    var lastPairQuestion: PairQuestion? = nil   // saved after grading so "Tutor me" can reference it
    /// Student's submitted answers and per-field correctness, saved alongside lastPairQuestion so
    /// the tutor prompt can reference what the student actually wrote.
    var lastPairAnswers: (intrAnswer: String, tranAnswer: String, intrCorrect: Bool, tranCorrect: Bool)? = nil
    var currentPairSystemPrompt: String? = nil  // set when pair tutor session starts; used by doChatTurn

    var counterExampleQueue: [String] = []         // shuffled countExamples for the current question; index 0 is the initial stem
    var counterAdditionalExamples: [String] = []  // examples shown after the initial one via "Another example" taps
    var counterStartingExampleIndex: Int = 0      // randomly chosen starting index into countExamples for the current question
    var lastCounterQuestion: (stem: String, facet: String, counterId: String)? = nil  // saved for tutoring
    var lastCounterAnswer: (text: String, isCorrect: Bool)? = nil  // student's answer and correctness
    var currentCounterSystemPrompt: String? = nil  // set when counter tutor session starts
    var currentCounterNumber: String? = nil        // set when counter-number-to-reading stem is built

    var currentItem: QuizItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    var progress: String { "\(currentIndex + 1) / \(items.count)" }
    var isQuizActive: Bool {
        switch phase {
        case .generating, .awaitingTap, .awaitingText, .awaitingPair, .chatting: return true
        default: return false
        }
    }
    /// True in any phase where "New Session" makes sense (not while loading).
    var canStartNewSession: Bool {
        switch phase {
        case .idle, .loadingItems: return false
        default: return true
        }
    }
    var statusMessage: String = "Loading items…"

    // MARK: - Feature flags

    /// Set to true to skip the second-pass question validator entirely.
    // MARK: - Dependencies

    let client: AnthropicClient
    let toolHandler: ToolHandler
    let preferences: UserPreferences
    let db: QuizDB
    private var conversation: [AnthropicMessage] = []
    var allCandidates: [QuizItem] = []

    // Prefetched next question: kicked off as soon as the current item is graded.
    private var prefetched: (index: Int, question: String, multipleChoice: MultipleChoiceQuestion?,
                              pairQuestion: PairQuestion?,
                              conversation: [AnthropicMessage],
                              preRecall: Double?, preHalflife: Double?,
                              counterExampleQueue: [String])? = nil
    // In-flight prefetch task, so generateQuestion() can await it instead of restarting.
    private var prefetchTask: Task<Void, Never>? = nil


    init(client: AnthropicClient, toolHandler: ToolHandler, db: QuizDB,
         preferences: UserPreferences) {
        self.client      = client
        self.toolHandler = toolHandler
        self.db          = db
        self.preferences = preferences
    }

    // MARK: - Public API

    func start() {
        items = []
        currentIndex = 0
        prefetched = nil
        prefetchTask = nil
        phase = .loadingItems
        Task { await loadItems() }
    }

    func sendChatMessage() {
        let text = chatInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSendingChat else { return }
        chatInput = ""
        isSendingChat = true
        Task { await doChatTurn(text) }
    }

    func nextQuestion() {
        currentIndex += 1
        if currentIndex >= items.count {
            Task { try? await db.clearSession() }
            phase = .finished
        } else {
            Task { await generateQuestion() }
        }
    }

    /// Called when the student taps "Another example" on a counter meaning-to-reading quiz.
    /// Appends the next example from the shuffled queue to counterAdditionalExamples,
    /// or whatItCounts once the queue is exhausted.
    func showAnotherCounterExample() {
        guard case .awaitingText(_) = phase, let item = currentItem, item.wordType == "counter",
              item.facet == "meaning-to-reading",
              let counter = counterCorpus?.items.first(where: { $0.id == item.wordId })?.counter
        else { return }

        // Queue index 0 is the initial stem; subsequent taps show indices 1, 2, then whatItCounts.
        let nextQueueIndex = counterAdditionalExamples.count + 1
        if nextQueueIndex < counterExampleQueue.count {
            counterAdditionalExamples.append(counterExampleQueue[nextQueueIndex])
        } else if counterAdditionalExamples.last != counter.whatItCounts {
            counterAdditionalExamples.append(counter.whatItCounts)
        }
    }

    /// Called when the student taps one of the multiple choice buttons.
    func tapChoice(_ index: Int) {
        guard case .awaitingTap(let multipleChoice) = phase, let item = currentItem else { return }
        let isCorrect = index == multipleChoice.correctIndex
        let score = isCorrect ? 1.0 : 0.0
        let letters = ["A", "B", "C", "D"]
        let chosenLetter = letters[index]
        let correctLetter = letters[multipleChoice.correctIndex]

        let choicesText = multipleChoice.choices.enumerated().map { "\(letters[$0])) \($1)" }.joined(separator: "\n")
        let questionBubble = "\(multipleChoice.stem)\n\n\(choicesText)"
        var wrongSuffix = ""
        if !isCorrect && item.facet == "meaning-reading-to-kanji" {
            let wrongKanji = multipleChoice.choices[index]
            if let meanings = toolHandler.kanjiMeanings(wrongKanji) {
                wrongSuffix = " (\(meanings))"
            }
        }
        let resultBubble = isCorrect
            ? "✓ \(chosenLetter)) \(multipleChoice.choices[index])"
            : "✗ Wrong: \(chosenLetter)) \(multipleChoice.choices[index])\(wrongSuffix)\n✓ Correct: \(correctLetter)) \(multipleChoice.choices[multipleChoice.correctIndex])"
        var resultSummary = "Question: \(multipleChoice.stem)\nChoices: \(choicesText)\nStudent chose \(chosenLetter)) \(multipleChoice.choices[index]) — \(isCorrect ? "Correct ✓" : "Incorrect ✗")"
        if !isCorrect {
            resultSummary += ". Correct answer: \(correctLetter)) \(multipleChoice.choices[multipleChoice.correctIndex])"
        }
        applyLocalGrade(score: score, questionBubble: questionBubble, answerBubble: resultBubble,
                        resultSummary: resultSummary, notes: resultSummary, item: item)
    }

    /// Shared local-grading path used by multiple choice (tapChoice) and exact-match free-answer.
    /// Records score, sets chat display, and prefetches next question. Does NOT fire a Claude turn —
    /// the student initiates any follow-up chat themselves.
    private func applyLocalGrade(score: Double, questionBubble: String, answerBubble: String,
                                  resultSummary: String, notes: String, item: QuizItem) {
        chatMessages = [
            (isUser: false, text: questionBubble),
            (isUser: true, text: answerBubble)
        ]
        gradedScore = score
        multipleChoiceResult = resultSummary
        phase = .chatting

        Task {
            try? await recordReview(item: item, score: score, notes: notes)
            // Prefetch next question now that grading is done
            let nextIndex = currentIndex + 1
            if nextIndex < items.count {
                let nextItem = items[nextIndex]
                prefetchTask = Task { await prefetchQuestion(for: nextIndex, item: nextItem) }
            }
        }
    }

    /// Called when the student admits uncertainty rather than picking a multiple choice option.
    /// score: 0.0 = "No idea", 0.25 = "Inkling"
    func tapUncertain(score: Double) {
        guard case .awaitingTap(let multipleChoice) = phase, let item = currentItem else { return }
        let noteText = score <= 0.05 ? "uncertainty: no idea" : "uncertainty: inkling"

        // Show question + student's admission. Use the actual message sent to Claude as the user bubble
        // so the student can see that something is in flight (especially for "Inkling", where the
        // spinner may not be immediately obvious).
        let openingMsg = score <= 0.05
            ? "I had no idea what this word means. Please explain it to me."
            : "I had a vague inkling but wasn't confident. Please explain the word and what I might have been thinking of."
        let letters = ["A", "B", "C", "D"]
        let choicesText = multipleChoice.choices.enumerated().map { "\(letters[$0])) \($1)" }.joined(separator: "\n")
        chatMessages = [
            (isUser: false, text: "\(multipleChoice.stem)\n\n\(choicesText)"),
            (isUser: true, text: openingMsg)
        ]

        gradedScore = score
        multipleChoiceResult = nil
        phase = .chatting
        isSendingChat = true

        Task {
            try? await recordReview(item: item, score: score, notes: noteText)
            let nextIndex = currentIndex + 1
            if nextIndex < items.count {
                let nextItem = items[nextIndex]
                prefetchTask = Task { await prefetchQuestion(for: nextIndex, item: nextItem) }
            }
        }

        Task { await doOpeningChatTurn(openingMsg, item: item, shouldParseScore: false) }
    }

    /// Called when the student submits the answer field(s) of a pair drill.
    /// Handles both pair-discrimination (two fields) and single-leg (one field) drills.
    func submitTransitivePairDrillAnswer() {
        guard case .awaitingPair(let q) = phase, let item = currentItem else { return }

        // Single-leg path: only one field is shown and graded.
        if let leg = q.askedLeg {
            let answer: String
            let isIntransitive: Bool
            switch leg {
            case .intransitive:
                answer = pairIntransitiveInput.trimmingCharacters(in: .whitespaces)
                isIntransitive = true
            case .transitive:
                answer = pairTransitiveInput.trimmingCharacters(in: .whitespaces)
                isIntransitive = false
            }
            guard !answer.isEmpty else { return }
            let correct: Bool
            let questionBubble: String
            if isIntransitive {
                correct = isTransitiveDrillAnswerCorrect(answer, kana: q.intransitiveKana, kanji: q.intransitiveKanji)
                questionBubble = q.intransitiveEnglish
            } else {
                correct = isTransitiveDrillAnswerCorrect(answer, kana: q.transitiveKana, kanji: q.transitiveKanji)
                questionBubble = q.transitiveEnglish
            }
            let legLabel = isIntransitive ? "intransitive" : "transitive"
            let cue = isIntransitive ? q.intransitiveEnglish : q.transitiveEnglish
            if correct {
                applyTransitiveDrillGrade(score: 1.0, questionBubble: questionBubble,
                               answerBubble: "✓ \(answer)\n\n\(q.intransitiveJapanese)\n\(q.transitiveJapanese)",
                               notes: "\(legLabel) [\(cue)]: \(answer)(correct)",
                               item: item, pairQuestion: q,
                               answers: isIntransitive ? (answer, "", true, false) : ("", answer, false, true))
            } else {
                // Slow path: answer didn't match exactly — ask LLM to grade conjugated forms.
                chatMessages = [(isUser: false, text: questionBubble)]
                isSendingChat = true
                phase = .chatting
                let intrAnswer = isIntransitive ? answer : ""
                let tranAnswer = isIntransitive ? "" : answer
                Task { await gradeTransitiveDrillWithLLM(q: q, item: item, intrAnswer: intrAnswer, tranAnswer: tranAnswer,
                                              intrMatchedByString: isIntransitive ? false : true,
                                              tranMatchedByString: isIntransitive ? true : false) }
            }
            return
        }

        // Pair-discrimination path: both fields graded.
        let intrAnswer = pairIntransitiveInput.trimmingCharacters(in: .whitespaces)
        let tranAnswer = pairTransitiveInput.trimmingCharacters(in: .whitespaces)
        guard !intrAnswer.isEmpty || !tranAnswer.isEmpty else { return }

        let intrCorrect = isTransitiveDrillAnswerCorrect(intrAnswer, kana: q.intransitiveKana, kanji: q.intransitiveKanji)
        let tranCorrect = isTransitiveDrillAnswerCorrect(tranAnswer, kana: q.transitiveKana, kanji: q.transitiveKanji)

        let questionBubble = "Intransitive: \(q.intransitiveEnglish)\nTransitive: \(q.transitiveEnglish)"

        // Fast path: both fields matched exactly — no LLM call needed.
        if intrCorrect && tranCorrect {
            applyTransitiveDrillGrade(score: 1.0, questionBubble: questionBubble,
                           answerBubble: "✓ \(intrAnswer)\n✓ \(tranAnswer)\n\n\(q.intransitiveJapanese)\n\(q.transitiveJapanese)",
                           notes: "pair: [\(q.intransitiveEnglish)] intr=\(intrAnswer)(correct) [\(q.transitiveEnglish)] tran=\(tranAnswer)(correct)",
                           item: item, pairQuestion: q,
                           answers: (intrAnswer, tranAnswer, true, true))
            return
        }

        // Slow path: at least one field failed the string match. Ask the LLM to grade,
        // since the student may have written a conjugated form of the correct verb.
        // Pre-populate the question bubble so the user sees context while the spinner runs.
        chatMessages = [(isUser: false, text: questionBubble)]
        isSendingChat = true
        phase = .chatting  // hide the input fields while we wait
        Task { await gradeTransitiveDrillWithLLM(q: q, item: item, intrAnswer: intrAnswer, tranAnswer: tranAnswer,
                                      intrMatchedByString: intrCorrect, tranMatchedByString: tranCorrect) }
    }

    /// LLM fallback grading for pair answers that failed the string match.
    /// For pair-discrimination (askedLeg == nil), grades both fields; score is 1.0/0.5/0.0.
    /// For single-leg (askedLeg non-nil), grades only the asked field; score is 1.0 or 0.0.
    private func gradeTransitiveDrillWithLLM(q: PairQuestion, item: QuizItem,
                                   intrAnswer: String, tranAnswer: String,
                                   intrMatchedByString: Bool, tranMatchedByString: Bool) async {
        let intrKanji = q.intransitiveKanji.first ?? q.intransitiveKana
        let tranKanji = q.transitiveKanji.first ?? q.transitiveKana
        let askedLeg = q.askedLeg

        // Build the prompt: for single-leg, ask the LLM to grade only the one field.
        let pairDescription = """
        - Intransitive: \(intrKanji) (\(q.intransitiveKana)) — something happens on its own (no agent)
        - Transitive: \(tranKanji) (\(q.transitiveKana)) — someone deliberately causes it (takes を)
        """
        let conjugationNote = "Accept any surface form of the correct verb: dictionary form, past tense (-た), te-form (-て), te-iru (-ています/-ている), polite form (-ます), negative (-ない), potential, causative, passive, or romaji equivalents."

        let system: String
        let userMessage: String
        switch askedLeg {
        case nil:
            system = """
            You are grading a transitive/intransitive verb pair quiz for a Japanese learner at the N4–N3 level.
            The student was shown two English cues and asked to type the dictionary form of each Japanese verb.

            The correct pair:
            \(pairDescription)

            Drill cues used:
            - Intransitive cue: "\(q.intransitiveEnglish)"
            - Transitive cue: "\(q.transitiveEnglish)"

            The quiz tests only whether the student knows which verb is transitive and which is intransitive — not conjugation accuracy. \(conjugationNote) If the student's answer is any recognizable inflection of the correct verb, it is correct.

            Respond in English only.

            Emit exactly two lines, in this order:
            SCORE_INTRANSITIVE: 1 or 0 — <one short English grading sentence>
            SCORE_TRANSITIVE: 1 or 0 — <one short English grading sentence>

            Use 1 if the student's answer is the correct verb in any form. Use 0 if it is the wrong verb or blank.
            """
            userMessage = """
            Student's intransitive answer: "\(intrAnswer)"
            Student's transitive answer: "\(tranAnswer)"
            Please grade both answers.
            """
        case .intransitive:
            system = """
            You are grading a single-leg transitive/intransitive verb quiz for a Japanese learner at the N4–N3 level.
            The student was shown one English cue and asked to type the intransitive Japanese verb.

            The correct pair (for context):
            \(pairDescription)

            Cue shown: "\(q.intransitiveEnglish)"
            Correct answer: \(intrKanji) (\(q.intransitiveKana))

            \(conjugationNote) If the student's answer is any recognizable inflection of the correct intransitive verb, it is correct.

            Respond in English only.

            Emit exactly one line:
            SCORE_INTRANSITIVE: 1 or 0 — <one short English grading sentence>

            Use 1 if correct (any conjugation), 0 if wrong or blank.
            """
            userMessage = "Student's answer: \"\(intrAnswer)\"\nPlease grade."
        case .transitive:
            system = """
            You are grading a single-leg transitive/intransitive verb quiz for a Japanese learner at the N4–N3 level.
            The student was shown one English cue and asked to type the transitive Japanese verb.

            The correct pair (for context):
            \(pairDescription)

            Cue shown: "\(q.transitiveEnglish)"
            Correct answer: \(tranKanji) (\(q.transitiveKana))

            \(conjugationNote) If the student's answer is any recognizable inflection of the correct transitive verb, it is correct.

            Respond in English only.

            Emit exactly one line:
            SCORE_TRANSITIVE: 1 or 0 — <one short English grading sentence>

            Use 1 if correct (any conjugation), 0 if wrong or blank.
            """
            userMessage = "Student's answer: \"\(tranAnswer)\"\nPlease grade."
        }

        let facetLabel = askedLeg == nil ? "pair-grade" : "single-leg-grade"
        do {
            let (response, _, _) = try await client.send(
                messages: [AnthropicMessage(role: "user", content: [.text(userMessage)])],
                system: system,
                tools: [],
                maxTokens: 256,
                toolHandler: makeToolHandler(),
                chatContext: .vocabQuiz(wordId: item.wordId, facet: facetLabel, sessionId: item.id.uuidString),
                templateId: "pair-llm-grade"
            )
            let (intrCorrect, tranCorrect) = parsePairLLMScores(from: response,
                                                                  intrMatchedByString: intrMatchedByString,
                                                                  tranMatchedByString: tranMatchedByString)
            let score: Double
            switch askedLeg {
            case nil:    score = intrCorrect && tranCorrect ? 1.0 : (intrCorrect || tranCorrect ? 0.5 : 0.0)
            case .intransitive: score = intrCorrect ? 1.0 : 0.0
            case .transitive:   score = tranCorrect ? 1.0 : 0.0
            }
            let intrKanjiDisplay = q.intransitiveKanji.first ?? q.intransitiveKana
            let tranKanjiDisplay = q.transitiveKanji.first ?? q.transitiveKana
            let questionBubble: String
            let answerBubble: String
            let notes: String
            switch askedLeg {
            case nil:
                let intrMark = intrCorrect ? "✓" : "✗"
                let tranMark = tranCorrect ? "✓" : "✗"
                let intrLine = intrCorrect ? "\(intrMark) \(intrAnswer)" : "\(intrMark) \(intrAnswer)  (correct: \(intrKanjiDisplay)/\(q.intransitiveKana))"
                let tranLine = tranCorrect ? "\(tranMark) \(tranAnswer)" : "\(tranMark) \(tranAnswer)  (correct: \(tranKanjiDisplay)/\(q.transitiveKana))"
                questionBubble = "Intransitive: \(q.intransitiveEnglish)\nTransitive: \(q.transitiveEnglish)"
                answerBubble = "\(intrLine)\n\(tranLine)\n\n\(q.intransitiveJapanese)\n\(q.transitiveJapanese)"
                notes = "pair: [\(q.intransitiveEnglish)] intr=\(intrAnswer)(\(intrCorrect ? "correct" : "wrong")) [\(q.transitiveEnglish)] tran=\(tranAnswer)(\(tranCorrect ? "correct" : "wrong")) [llm-graded]"
            case .intransitive:
                let mark = intrCorrect ? "✓" : "✗"
                let line = intrCorrect ? "\(mark) \(intrAnswer)" : "\(mark) \(intrAnswer)  (correct: \(intrKanjiDisplay)/\(q.intransitiveKana))"
                questionBubble = q.intransitiveEnglish
                answerBubble = "\(line)\n\n\(q.intransitiveJapanese)\n\(q.transitiveJapanese)"
                notes = "intransitive [\(q.intransitiveEnglish)]: \(intrAnswer)(\(intrCorrect ? "correct" : "wrong")) [llm-graded]"
            case .transitive:
                let mark = tranCorrect ? "✓" : "✗"
                let line = tranCorrect ? "\(mark) \(tranAnswer)" : "\(mark) \(tranAnswer)  (correct: \(tranKanjiDisplay)/\(q.transitiveKana))"
                questionBubble = q.transitiveEnglish
                answerBubble = "\(line)\n\n\(q.intransitiveJapanese)\n\(q.transitiveJapanese)"
                notes = "transitive [\(q.transitiveEnglish)]: \(tranAnswer)(\(tranCorrect ? "correct" : "wrong")) [llm-graded]"
            }
            applyTransitiveDrillGrade(score: score, questionBubble: questionBubble, answerBubble: answerBubble,
                           notes: notes, item: item, pairQuestion: q,
                           answers: (intrAnswer, tranAnswer, intrCorrect, tranCorrect))
        } catch {
            // On API failure, fall back to the string-match results already computed.
            let score: Double
            switch askedLeg {
            case nil:         score = intrMatchedByString && tranMatchedByString ? 1.0 : (intrMatchedByString || tranMatchedByString ? 0.5 : 0.0)
            case .intransitive: score = intrMatchedByString ? 1.0 : 0.0
            case .transitive:   score = tranMatchedByString ? 1.0 : 0.0
            }
            let intrKanjiDisplay = q.intransitiveKanji.first ?? q.intransitiveKana
            let tranKanjiDisplay = q.transitiveKanji.first ?? q.transitiveKana
            let questionBubble: String
            let answerBubble: String
            let notes: String
            switch askedLeg {
            case nil:
                let intrLine = intrMatchedByString ? "✓ \(intrAnswer)" : "✗ \(intrAnswer)  (correct: \(intrKanjiDisplay)/\(q.intransitiveKana))"
                let tranLine = tranMatchedByString ? "✓ \(tranAnswer)" : "✗ \(tranAnswer)  (correct: \(tranKanjiDisplay)/\(q.transitiveKana))"
                questionBubble = "Intransitive: \(q.intransitiveEnglish)\nTransitive: \(q.transitiveEnglish)"
                answerBubble = "\(intrLine)\n\(tranLine)\n\n\(q.intransitiveJapanese)\n\(q.transitiveJapanese)"
                notes = "pair: [\(q.intransitiveEnglish)] intr=\(intrAnswer)(\(intrMatchedByString ? "correct" : "wrong")) [\(q.transitiveEnglish)] tran=\(tranAnswer)(\(tranMatchedByString ? "correct" : "wrong")) [string-match fallback: llm error]"
            case .intransitive:
                let line = intrMatchedByString ? "✓ \(intrAnswer)" : "✗ \(intrAnswer)  (correct: \(intrKanjiDisplay)/\(q.intransitiveKana))"
                questionBubble = q.intransitiveEnglish
                answerBubble = "\(line)\n\n\(q.intransitiveJapanese)\n\(q.transitiveJapanese)"
                notes = "intransitive [\(q.intransitiveEnglish)]: \(intrAnswer)(\(intrMatchedByString ? "correct" : "wrong")) [string-match fallback: llm error]"
            case .transitive:
                let line = tranMatchedByString ? "✓ \(tranAnswer)" : "✗ \(tranAnswer)  (correct: \(tranKanjiDisplay)/\(q.transitiveKana))"
                questionBubble = q.transitiveEnglish
                answerBubble = "\(line)\n\n\(q.intransitiveJapanese)\n\(q.transitiveJapanese)"
                notes = "transitive [\(q.transitiveEnglish)]: \(tranAnswer)(\(tranMatchedByString ? "correct" : "wrong")) [string-match fallback: llm error]"
            }
            applyTransitiveDrillGrade(score: score, questionBubble: questionBubble, answerBubble: answerBubble,
                           notes: notes, item: item, pairQuestion: q,
                           answers: (intrAnswer, tranAnswer, intrMatchedByString, tranMatchedByString))
        }
        isSendingChat = false
    }

    /// Parses SCORE_INTRANSITIVE and SCORE_TRANSITIVE lines from the LLM grading response.
    /// String-match results are used as a floor: a field already correct by string match stays correct.
    private func parsePairLLMScores(from response: String,
                                     intrMatchedByString: Bool,
                                     tranMatchedByString: Bool) -> (Bool, Bool) {
        var intrCorrect = intrMatchedByString
        var tranCorrect = tranMatchedByString
        for line in response.components(separatedBy: .newlines) {
            if line.hasPrefix("SCORE_INTRANSITIVE:") {
                let value = line.dropFirst("SCORE_INTRANSITIVE:".count).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("1") { intrCorrect = true }
                else if value.hasPrefix("0") { intrCorrect = false }
            } else if line.hasPrefix("SCORE_TRANSITIVE:") {
                let value = line.dropFirst("SCORE_TRANSITIVE:".count).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("1") { tranCorrect = true }
                else if value.hasPrefix("0") { tranCorrect = false }
            }
        }
        return (intrCorrect, tranCorrect)
    }

    /// Called when the student taps "Don't know" on a pair-discrimination drill.
    func tapTransitiveDrillDontKnow() {
        guard case .awaitingPair(let q) = phase, let item = currentItem else { return }
        let intrDisplay = "\(q.intransitiveKanji.first ?? q.intransitiveKana) (\(q.intransitiveKana))"
        let tranDisplay = "\(q.transitiveKanji.first ?? q.transitiveKana) (\(q.transitiveKana))"
        let questionBubble: String
        let answerBubble: String
        let notes: String
        switch q.askedLeg {
        case nil:
            questionBubble = "Intransitive: \(q.intransitiveEnglish)\nTransitive: \(q.transitiveEnglish)"
            answerBubble = "Intransitive: \(intrDisplay)\n\(q.intransitiveJapanese)\n\nTransitive: \(tranDisplay)\n\(q.transitiveJapanese)"
            notes = "pair: [\(q.intransitiveEnglish)] [\(q.transitiveEnglish)] don't know"
        case .intransitive:
            questionBubble = q.intransitiveEnglish
            answerBubble = "\(intrDisplay)\n\(q.intransitiveJapanese)"
            notes = "intransitive [\(q.intransitiveEnglish)]: don't know"
        case .transitive:
            questionBubble = q.transitiveEnglish
            answerBubble = "\(tranDisplay)\n\(q.transitiveJapanese)"
            notes = "transitive [\(q.transitiveEnglish)]: don't know"
        }
        applyTransitiveDrillGrade(score: 0.0, questionBubble: questionBubble, answerBubble: answerBubble, notes: notes, item: item, pairQuestion: q)
    }

    /// Shared grading path for all transitive drill facets (pair-discrimination, transitive, intransitive).
    private func applyTransitiveDrillGrade(score: Double, questionBubble: String, answerBubble: String,
                                 notes: String, item: QuizItem, pairQuestion: PairQuestion? = nil,
                                 answers: (intrAnswer: String, tranAnswer: String, intrCorrect: Bool, tranCorrect: Bool)? = nil) {
        // Preserve any pre-populated question bubble already shown during the LLM slow path.
        if chatMessages.isEmpty {
            chatMessages = [(isUser: false, text: questionBubble)]
        }
        chatMessages.append((isUser: true, text: answerBubble))
        gradedScore = score
        multipleChoiceResult = nil
        lastPairQuestion = pairQuestion   // saved so pair "Tutor me" can reference the drill
        lastPairAnswers = answers          // saved so tutor prompt can reference what the student wrote
        currentPairSystemPrompt = nil     // cleared; set only when pair tutor session fires
        phase = .chatting

        Task {
            try? await recordReview(item: item, score: score, notes: notes)
            let nextIndex = currentIndex + 1
            if nextIndex < items.count {
                let nextItem = items[nextIndex]
                prefetchTask = Task { await prefetchQuestion(for: nextIndex, item: nextItem) }
            }
        }
    }

    /// Check whether a student's typed answer is correct for a pair member.
    /// Accepts: exact kana, any kanji form, or romaji that converts to the correct kana.
    private func isTransitiveDrillAnswerCorrect(_ answer: String, kana: String, kanji: [String]) -> Bool {
        let trimmed = answer.trimmingCharacters(in: .whitespaces)
        if trimmed == kana { return true }
        if kanji.contains(trimmed) { return true }
        if let converted = romajiToHiragana(trimmed.lowercased()), converted == kana { return true }
        return false
    }

    /// True when the student tapped a wrong multiple-choice answer and the tutor chat hasn't started yet.
    /// Used by the view to show a "Tutor me" button.
    var canStartTutorSession: Bool {
        gradedScore == 0.0 && multipleChoiceResult != nil && chatMessages.count <= 2 && !isSendingChat
    }

    /// Auto-fires a chat turn asking Claude to explain the wrong answer.
    func startTutorSession() {
        guard canStartTutorSession, let item = currentItem else { return }
        isSendingChat = true
        let msg = "I got this wrong and want to understand why. Please explain what the correct answer means and what I may have been confusing it with."
        chatMessages.append((isUser: true, text: msg))
        Task { await doOpeningChatTurn(msg, item: item, shouldParseScore: false) }
    }

    /// True when the student scored ≤ 0.6 on a pair drill and has not yet started a tutor chat.
    var canStartTransitiveDrillTutorSession: Bool {
        guard let score = gradedScore else { return false }
        return score <= 0.6 && lastPairQuestion != nil && currentPairSystemPrompt == nil
            && chatMessages.count <= 2 && !isSendingChat
    }

    /// True when the student got a counter question wrong and has not yet started a tutor chat.
    var canStartCounterTutorSession: Bool {
        guard let _ = gradedScore, let answer = lastCounterAnswer, lastCounterQuestion != nil else { return false }
        return !answer.isCorrect && currentCounterSystemPrompt == nil
            && chatMessages.count <= 2 && !isSendingChat
    }

    /// Builds a system prompt for the counter tutor, explaining phonetic patterns.
    private func counterTutorSystemPrompt(for item: QuizItem, counter: Counter, facet: String) -> String {
        if facet == "meaning-to-reading" {
            return """
            You are a friendly Japanese tutor helping a learner understand how counter words work.

            The counter being studied: \(counter.kanji)(\(counter.reading))
            What it counts: \(counter.whatItCounts)

            When the student describes their wrong answer, briefly explain:
            - Why this counter uses that specific reading
            - If relevant, any variant readings (rare pronunciations) and when they appear
            - A memorable phrase or example from the counter's `countExamples` list that illustrates the reading

            The learner is aiming for N4–N3 level. Keep the response concise and conversational. Respond in English.
            """
        } else {
            // counter-number-to-reading
            return """
            You are a friendly Japanese tutor helping a learner understand phonetic modifications in counter words.

            The counter being studied: \(counter.kanji)(\(counter.reading))
            Phonetic pattern: Some initial sounds change when combined with certain numbers (e.g., h→p with 1, 6, 8, 10).

            When the student describes their wrong answer, briefly explain:
            - Why the number triggers that specific phonetic change
            - The rule or pattern that governs the change (if known)
            - A memory tip or reference to DBJG phonetic types (Type A, B, C, etc.) if it helps

            The learner is aiming for N4–N3 level. Keep the response concise and conversational. Respond in English.
            """
        }
    }

    /// Builds the opening user message for a counter tutor session.
    private func counterTutorOpeningMessage(for question: (stem: String, facet: String, counterId: String), answer: (text: String, isCorrect: Bool), counter: Counter) -> String {
        let facetLabel = question.facet == "meaning-to-reading" ? "Meaning-to-reading" : "Number-to-reading"
        return """
        I got this \(facetLabel) counter question wrong.
        Question: \(question.stem)
        I answered: \(answer.text)
        Please explain why I was wrong and what the correct answer is.
        """
    }

    /// Auto-fires a tutor chat turn explaining the counter phonetic pattern.
    func startCounterTutorSession() {
        guard canStartCounterTutorSession, let question = lastCounterQuestion, let answer = lastCounterAnswer,
              let counterCorpus, let counterItem = counterCorpus.items.first(where: { $0.id == question.counterId }),
              let item = currentItem else { return }
        isSendingChat = true
        let systemPromptText = counterTutorSystemPrompt(for: item, counter: counterItem.counter, facet: question.facet)
        currentCounterSystemPrompt = systemPromptText
        let msg = counterTutorOpeningMessage(for: question, answer: answer, counter: counterItem.counter)
        chatMessages.append((isUser: true, text: msg))
        Task { await doCounterTutorOpeningTurn(msg, systemPromptText: systemPromptText, item: item) }
    }

    private func doCounterTutorOpeningTurn(_ message: String, systemPromptText: String, item: QuizItem) async {
        conversation = [AnthropicMessage(role: "user", content: [.text(message)])]
        do {
            let (response, updatedMsgs, _) = try await client.send(
                messages: conversation,
                system: systemPromptText,
                tools: [.lookupJmdict],
                maxTokens: 1024,
                toolHandler: makeToolHandler(),
                chatContext: .vocabQuiz(wordId: item.wordId, facet: "counter-tutor", sessionId: item.id.uuidString),
                templateId: nil
            )
            conversation = updatedMsgs
            let displayText = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayText.isEmpty {
                chatMessages.append((isUser: false, text: displayText))
            }
            isSendingChat = false
        } catch {
            chatMessages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
            isSendingChat = false
        }
    }

    /// Builds a system prompt for the transitive drill tutor, explaining the transitive/intransitive distinction.
    private func transitiveDrillTutorSystemPrompt(for q: PairQuestion) -> String {
        let intrKanji = q.intransitiveKanji.first ?? q.intransitiveKana
        let tranKanji = q.transitiveKanji.first ?? q.transitiveKana
        let pairContext = """
        The pair being studied:
        - Intransitive: \(intrKanji) (\(q.intransitiveKana)) — something happens on its own (no agent)
        - Transitive: \(tranKanji) (\(q.transitiveKana)) — someone deliberately causes it (takes a direct object with を)
        """
        let drillContext: String
        switch q.askedLeg {
        case nil:
            drillContext = """
            The drill used in this quiz:
            - Intransitive cue: "\(q.intransitiveEnglish)" → correct answer: \(q.intransitiveJapanese)
            - Transitive cue: "\(q.transitiveEnglish)" → correct answer: \(q.transitiveJapanese)
            """
        case .intransitive:
            drillContext = """
            The student was shown this single cue and asked for the intransitive verb:
            Cue: "\(q.intransitiveEnglish)" → correct answer: \(intrKanji) (\(q.intransitiveKana)) — \(q.intransitiveJapanese)
            """
        case .transitive:
            drillContext = """
            The student was shown this single cue and asked for the transitive verb:
            Cue: "\(q.transitiveEnglish)" → correct answer: \(tranKanji) (\(q.transitiveKana)) — \(q.transitiveJapanese)
            """
        }
        return """
        You are a friendly Japanese tutor helping a learner understand the difference between a transitive and intransitive verb pair.

        \(pairContext)

        \(drillContext)

        The student's wrong answer and the correct answer are in the first message. Briefly diagnose the failure mode (mixed up transitive/intransitive, close but wrong verb, or unrelated word), then suggest how to avoid this mistake by explaining the core distinction or giving a memory tip. You have access to lookup_jmdict if you want to verify dictionary forms or cite alternate readings. Keep the response concise and conversational. The learner is aiming for N4–N3 level. Respond in English.
        """
    }

    /// Builds the opening user message for the tutor session, referencing the student's actual answer.
    private func transitiveDrillTutorOpeningMessage(for q: PairQuestion) -> String {
        let intrKanji = q.intransitiveKanji.first ?? q.intransitiveKana
        let tranKanji = q.transitiveKanji.first ?? q.transitiveKana
        switch q.askedLeg {
        case nil:
            guard let answers = lastPairAnswers else {
                return "I tapped \"don't know\" — I had no idea. The correct pair is: intransitive \(intrKanji) (\(q.intransitiveKana)) for \"\(q.intransitiveEnglish)\", transitive \(tranKanji) (\(q.transitiveKana)) for \"\(q.transitiveEnglish)\". Please explain the distinction and how to remember which is which."
            }
            var lines: [String] = ["Here's what I answered:"]
            lines.append("- Intransitive (\(q.intransitiveEnglish)): I wrote \"\(answers.intrAnswer)\" — \(answers.intrCorrect ? "correct ✓" : "wrong ✗ (correct: \(intrKanji)/\(q.intransitiveKana))")")
            lines.append("- Transitive (\(q.transitiveEnglish)): I wrote \"\(answers.tranAnswer)\" — \(answers.tranCorrect ? "correct ✓" : "wrong ✗ (correct: \(tranKanji)/\(q.transitiveKana))")")
            lines.append("Diagnose what went wrong for the fields I got wrong, then explain the difference and how to remember which is which.")
            return lines.joined(separator: "\n")
        case .intransitive:
            guard let answers = lastPairAnswers else {
                return "I tapped \"don't know\" — I had no idea. The cue was \"\(q.intransitiveEnglish)\" and the correct intransitive verb is \(intrKanji) (\(q.intransitiveKana)). Please explain how to remember which verb is intransitive."
            }
            let answer = answers.intrAnswer.isEmpty ? "(blank)" : answers.intrAnswer
            return "The cue was \"\(q.intransitiveEnglish)\" and I wrote \"\(answer)\" but the correct intransitive verb is \(intrKanji) (\(q.intransitiveKana)). Why did I get this wrong, and how do I remember which verb is intransitive?"
        case .transitive:
            guard let answers = lastPairAnswers else {
                return "I tapped \"don't know\" — I had no idea. The cue was \"\(q.transitiveEnglish)\" and the correct transitive verb is \(tranKanji) (\(q.transitiveKana)). Please explain how to remember which verb is transitive."
            }
            let answer = answers.tranAnswer.isEmpty ? "(blank)" : answers.tranAnswer
            return "The cue was \"\(q.transitiveEnglish)\" and I wrote \"\(answer)\" but the correct transitive verb is \(tranKanji) (\(q.transitiveKana)). Why did I get this wrong, and how do I remember which verb is transitive?"
        }
    }

    /// Auto-fires a tutor chat turn explaining the transitive/intransitive distinction for pairs.
    func startTransitiveDrillTutorSession() {
        guard canStartTransitiveDrillTutorSession, let q = lastPairQuestion, let item = currentItem else { return }
        isSendingChat = true
        let systemPromptText = transitiveDrillTutorSystemPrompt(for: q)
        currentPairSystemPrompt = systemPromptText
        let msg = transitiveDrillTutorOpeningMessage(for: q)
        chatMessages.append((isUser: true, text: msg))
        Task { await doPairTutorOpeningTurn(msg, systemPromptText: systemPromptText, item: item) }
    }

    private func doPairTutorOpeningTurn(_ message: String, systemPromptText: String, item: QuizItem) async {
        conversation = [AnthropicMessage(role: "user", content: [.text(message)])]
        do {
            let (response, updatedMsgs, _) = try await client.send(
                messages: conversation,
                system: systemPromptText,
                tools: [.lookupJmdict],
                maxTokens: 1024,
                toolHandler: makeToolHandler(),
                chatContext: .vocabQuiz(wordId: item.wordId, facet: "pair-tutor", sessionId: item.id.uuidString),
                templateId: nil
            )
            conversation = updatedMsgs
            let displayText = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayText.isEmpty {
                chatMessages.append((isUser: false, text: displayText))
            }
        } catch {
            chatMessages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        isSendingChat = false
    }

    func refreshSession() {
        // Reset UI state synchronously so the view updates immediately.
        items = []
        currentIndex = 0
        prefetched = nil
        prefetchTask = nil
        conversation = []
        currentQuestion = ""
        chatMessages = []
        chatInput = ""
        isSendingChat = false
        gradedScore = nil
        phase = .loadingItems
        // Clear the DB session first, then load — serialised to avoid a race where
        // loadItems() calls sessionWordIds() before clearSession() has committed.
        Task {
            try? await db.clearSession()
            await loadItems()
        }
    }

    // MARK: - Private: load items

    private func loadItems() async {
        print("[QuizSession] loadItems: building quiz context")
        do {
            statusMessage = "Loading items…"
            let allBuilt = try await QuizContext.build(db: db, jmdict: toolHandler.jmdict, pairCorpus: pairCorpus, counterCorpus: counterCorpus)
            var candidates: [QuizItem]
            switch quizFilter {
            case .all:
                candidates = allBuilt
            case .vocabOnly:
                candidates = allBuilt.filter { $0.wordType != "transitive-pair" && $0.wordType != "counter" }
            case .pairsOnly:
                candidates = allBuilt.filter { $0.wordType == "transitive-pair" }
            case .countersOnly:
                candidates = allBuilt.filter { $0.wordType == "counter" }
            }

            // Restrict to a specific document when documentScope is set.
            if let scope = documentScope, let manifest = VocabSync.cached() {
                let scopedIds = Set(manifest.words.filter { $0.sources.contains(scope) }.map(\.id))
                candidates = candidates.filter { scopedIds.contains($0.wordId) }
            }

            allCandidates = candidates
            print("[QuizSession] loadItems: \(candidates.count) candidate(s)")
            if candidates.isEmpty { phase = .noItems; return }

            // Resume saved session if available.
            let savedIds = try await db.sessionWordIds()
            if !savedIds.isEmpty {
                print("[QuizSession] resuming saved session: \(savedIds.count) item(s) remaining")
                let byId = Dictionary(candidates.map { ($0.wordId, $0) }, uniquingKeysWith: { f, _ in f })
                items = savedIds.compactMap { byId[$0] }
            }

            // No valid session found — select a fresh set algorithmically.
            if items.isEmpty {
                items = selectItems(candidates: candidates)
                try await db.saveSession(wordIds: items.map(\.wordId))
            }

            if items.isEmpty { phase = .noItems } else { await generateQuestion() }
        } catch {
            print("[QuizSession] loadItems error: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Private: LLM item selection

    /// Algorithmically select quiz items: take the top most-urgent candidates
    /// (already sorted by ascending recall in QuizContext.build) and pick a count
    /// based on the user's session-length preference.
    private func selectItems(candidates: [QuizItem]) -> [QuizItem] {
        let pool = Array(candidates.prefix(QuizContext.selectionPoolSize))
        guard !pool.isEmpty else { return [] }
        let selected: [QuizItem]
        switch preferences.sessionLength {
        case .short:
            let weakest = pool[0]
            let rest = Array(pool.dropFirst()).shuffled()
            let extras = rest.isEmpty ? 0 : Int.random(in: min(2, rest.count)...min(4, rest.count))
            selected = (rest.prefix(extras) + [weakest]).shuffled()
        case .long:
            selected = Array(pool.prefix(10))
        }
        print("[QuizSession] selectItems: picked \(selected.count) from top-\(pool.count) of \(candidates.count) candidates")
        return selected
    }

    // MARK: - Private: free-answer stem builder

    /// Build the question stem app-side for free-answer facets (no LLM needed).
    func freeAnswerStem(for item: QuizItem) -> String {
        let kana = item.committedReading ?? item.kanaTexts.first ?? "?"
        let meanings = item.corpusSenses.flatMap(\.glosses).prefix(3).joined(separator: "; ")

        // Counter facets are handled specially.
        if item.wordType == "counter" {
            switch item.facet {
            case "meaning-to-reading":
                // Show the first entry from the pre-shuffled queue as the initial prompt.
                if let first = counterExampleQueue.first {
                    return "What counter word (読み方) counts \(first)?"
                }
                return "What is the reading of the counter \(item.wordText)?"
            case "counter-number-to-reading":
                // Will be handled specially in generateQuestion()
                return ""
            default:
                return item.wordText
            }
        }

        // Vocab facets.
        switch item.facet {
        case "meaning-to-reading":
            return meanings.isEmpty ? item.wordText : meanings
        case "kanji-to-reading":
            if let template = item.partialKanjiTemplate {
                return "What is the full reading for: \(template)"
            }
            return "What is the reading for: \(item.wordText)"
        case "reading-to-meaning":
            return "What does \(kana) mean?"
        default:
            return "What is \(item.wordText)?"
        }
    }

    /// Build the app-side stem for meaning-reading-to-kanji multiple choice.
    /// Picks a random corpus-attested sense and joins all its glosses with "; ", then appends the kana reading.
    /// Using all glosses for the chosen sense (not just the first) avoids ambiguity when a sense has multiple
    /// sub-glosses (e.g. "to seclude oneself; to shut oneself away"). Rotating the sense across quiz sessions
    /// prevents the student from pattern-matching on a single fixed English phrase.
    func meaningReadingToKanjiStem(for item: QuizItem) -> String {
        let senses = item.corpusSenses.isEmpty ? item.senseExtras : item.corpusSenses
        let gloss: String
        if senses.isEmpty {
            gloss = item.wordText
        } else {
            let sense = senses[Int.random(in: 0..<senses.count)]
            gloss = sense.glosses.joined(separator: "; ")
        }
        let kana = item.committedReading ?? item.kanaTexts.first ?? ""
        return kana.isEmpty ? gloss : "\(gloss) — \(kana)"
    }

    // MARK: - Counter question builder

    /// Build stem for counter-number-to-reading: "6 + 匹(ひき)"
    private func buildCounterNumberStem(counter: Counter) -> String {
        let numbers = ["1", "3", "6", "8", "10"]
        let number = numbers.randomElement() ?? "3"
        currentCounterNumber = number
        return "How do you say \(number) + \(counter.kanji)(\(counter.reading))?\n(\(counter.whatItCounts))"
    }

    // MARK: - Counter grading

    private func gradeCounterAnswer(text: String, stem: String, item: QuizItem) async {
        guard let counterCorpus,
              let counterItem = counterCorpus.items.first(where: { $0.id == item.wordId }) else {
            chatMessages = [(isUser: false, text: stem), (isUser: true, text: text)]
            chatMessages.append((isUser: false, text: "Error: counter not found"))
            phase = .chatting
            return
        }

        let counter = counterItem.counter
        var isCorrect = false
        var resultBubble = ""

        switch item.facet {
        case "meaning-to-reading":
            // Check if answer matches counter reading
            isCorrect = text == counter.reading
            let resultText = isCorrect
                ? "✓ \(text)"
                : "✗ Wrong: \(text)\n✓ Correct: \(counter.reading)"
            resultBubble = resultText

        case "counter-number-to-reading":
            if let pronunciations = counter.pronunciations[currentCounterNumber ?? ""] {
                let primaryAnswers = pronunciations.primary
                let rareAnswers = pronunciations.rare
                isCorrect = primaryAnswers.contains(text) || rareAnswers.contains(text)
                let otherPrimary = primaryAnswers.filter { $0 != text }
                let otherRare = rareAnswers.filter { $0 != text }
                let primaryList = primaryAnswers.joined(separator: " / ")
                let allAccepted = rareAnswers.isEmpty
                    ? primaryList
                    : "\(primaryList) (rare: \(rareAnswers.joined(separator: " / ")))"
                let alsoAccepted = otherRare.isEmpty
                    ? otherPrimary.joined(separator: " / ")
                    : "\(otherPrimary.joined(separator: " / ")) (rare: \(otherRare.joined(separator: " / ")))"
                let hasAlternates = !otherPrimary.isEmpty || !otherRare.isEmpty
                let resultText = isCorrect
                    ? (hasAlternates ? "✓ \(text)\nAlso accepted: \(alsoAccepted)" : "✓ \(text)")
                    : "✗ Wrong: \(text)\n✓ Correct: \(allAccepted)"
                resultBubble = resultText
            } else {
                resultBubble = "Error: could not find pronunciation data"
            }

        default:
            resultBubble = "Unknown counter facet"
        }

        let score = isCorrect ? 1.0 : 0.0
        let resultSummary = "Question: \(stem)\nStudent answered: \(text) — \(isCorrect ? "Correct ✓" : "Incorrect ✗")"

        // Save question and answer for tutoring (if wrong)
        lastCounterQuestion = (stem: stem, facet: item.facet, counterId: item.wordId)
        lastCounterAnswer = (text: text, isCorrect: isCorrect)

        let counterNotes: String
        let questionBubble: String
        if item.facet == "meaning-to-reading" {
            let allExampleWords = ([counterExampleQueue.first ?? ""] + counterAdditionalExamples).filter { !$0.isEmpty }
            let shownExamples = allExampleWords.joined(separator: "; ")
            counterNotes = "autograder: counter; examples shown: \(shownExamples); answer: \(text)"
            questionBubble = "What counter word (読み方) counts \(allExampleWords.joined(separator: ", "))?"
        } else {
            counterNotes = "autograder: counter; answer: \(text)"
            questionBubble = stem
        }
        applyLocalGrade(score: score, questionBubble: questionBubble, answerBubble: resultBubble,
                        resultSummary: resultSummary, notes: counterNotes, item: item)
    }

    // MARK: - Private: generate question

    private func generateQuestion() async {
        guard let item = currentItem else { phase = .finished; return }

        // If a prefetch task is in-flight for this index, wait for it to finish.
        if let task = prefetchTask {
            prefetchTask = nil
            phase = .generating
            await task.value
        }

        // Consume prefetch if one is ready for this index.
        if let pf = prefetched, pf.index == currentIndex {
            prefetched = nil
            currentQuestion = pf.question
            chatInput      = ""
            isSendingChat  = false
            gradedScore       = nil
            gradedHalflife    = nil
            counterExampleQueue = pf.counterExampleQueue
            counterAdditionalExamples = []

            meaningBonusApplied = false
            uncertaintyUnlocked = false
            preQuizRecall   = pf.preRecall
            preQuizHalflife = pf.preHalflife
            print("[QuizSession] consumed prefetch for index \(currentIndex): \(item.wordText)")
            if let pairQuestion = pf.pairQuestion {
                conversation = []
                chatMessages = []
                pairIntransitiveInput = ""
                pairTransitiveInput = ""
                phase = .awaitingPair(pairQuestion)
            } else if let multipleChoice = pf.multipleChoice {
                conversation = []
                chatMessages = []
                multipleChoiceResult = nil
                phase = .awaitingTap(multipleChoice)
            } else if item.isFreeAnswer {
                phase = .awaitingText(pf.question)
            } else {
                conversation = pf.conversation
                chatMessages = [(isUser: false, text: pf.question)]
                phase = .chatting
            }
            return
        }

        // Reset common state
        conversation = []
        chatMessages = []
        chatInput = ""
        isSendingChat = false
        counterExampleQueue = []
        counterAdditionalExamples = []
        lastCounterQuestion = nil
        lastCounterAnswer = nil
        currentCounterSystemPrompt = nil
        currentCounterNumber = nil
        gradedScore       = nil
        gradedHalflife    = nil
        multipleChoiceResult = nil
        lastPairQuestion = nil
        lastPairAnswers = nil
        currentPairSystemPrompt = nil
        meaningBonusApplied = false
        uncertaintyUnlocked = false
        if case .reviewed(let recall, _, let halflife) = item.status {
            preQuizRecall   = recall
            preQuizHalflife = halflife
        } else {
            preQuizRecall   = nil
            preQuizHalflife = nil
        }

        // Handle transitive-pair items: pick a random drill, no LLM call needed.
        if item.wordType == "transitive-pair" {
            guard let pairCorpus,
                  let pairItem = pairCorpus.items.first(where: { $0.id == item.wordId }),
                  let drills = pairItem.pair.drills, !drills.isEmpty else {
                print("[QuizSession] no drills for pair \(item.wordId), skipping")
                nextQuestion()
                return
            }
            let drill = drills.randomElement()!
            let askedLeg: AskedLeg? = item.facet == "transitive" ? .transitive
                                    : item.facet == "intransitive" ? .intransitive
                                    : nil
            let q = PairQuestion(
                intransitiveEnglish: drill.intransitive.en,
                transitiveEnglish: drill.transitive.en,
                intransitiveKana: pairItem.pair.intransitive.kana,
                intransitiveKanji: pairItem.pair.intransitive.kanji,
                transitiveKana: pairItem.pair.transitive.kana,
                transitiveKanji: pairItem.pair.transitive.kanji,
                intransitiveJapanese: drill.intransitive.ja,
                transitiveJapanese: drill.transitive.ja,
                askedLeg: askedLeg
            )
            pairIntransitiveInput = ""
            pairTransitiveInput = ""
            phase = .awaitingPair(q)
            return
        }

        // Handle counter items: deterministic, no LLM call needed.
        if item.wordType == "counter" {
            guard let counterCorpus,
                  let counterItem = counterCorpus.items.first(where: { $0.id == item.wordId }) else {
                print("[QuizSession] counter corpus not available, skipping \(item.wordId)")
                nextQuestion()
                return
            }
            switch item.facet {
            case "meaning-to-reading":
                counterExampleQueue = Array(counterItem.counter.countExamples.shuffled().prefix(3))
                let stem = freeAnswerStem(for: item)
                currentQuestion = stem
                print("[QuizSession] counter meaning-to-reading (app-side) for \(item.wordText): \(stem)")
                phase = .awaitingText(stem)
            case "counter-number-to-reading":
                let stem = buildCounterNumberStem(counter: counterItem.counter)
                currentQuestion = stem
                print("[QuizSession] counter number-to-reading (app-side) for \(item.wordText): \(stem)")
                phase = .awaitingText(stem)
            default:
                print("[QuizSession] unknown counter facet \(item.facet), skipping")
                nextQuestion()
                return
            }
            return
        }

        // Free-answer: construct stem app-side, no LLM call needed.
        if item.isFreeAnswer {
            let stem = freeAnswerStem(for: item)
            currentQuestion = stem
            print("[QuizSession] free-answer stem (app-side) for \(item.wordText): \(stem)")
            phase = .awaitingText(stem)
            return
        }

        // Documents distractor mode: build multiple-choice app-side, no LLM call needed.
        if let appSideQuestion = appSideMultipleChoice(for: item) {
            currentQuestion = appSideQuestion.stem
            print("[QuizSession] app-side multiple choice (documents) for \(item.wordText) facet:\(item.facet)")
            phase = .awaitingTap(appSideQuestion)
            return
        }

        phase = .generating
        print("[QuizSession] generating multiple choice question for \(item.wordText) (id:\(item.wordId)) facet:\(item.facet)")

        let system = systemPrompt(for: item, isGenerating: true,
                                  preRecall: preQuizRecall, preHalflife: preQuizHalflife)
        let initMsg = AnthropicMessage(role: "user", content: [.text(questionRequest(for: item))])

        do {
            let (finalQuestion, finalMultipleChoice, finalMsgs) = try await runGenerationLoop(
                for: item, system: system, initMsg: initMsg, label: "generate",
                preRecall: preQuizRecall)
            currentQuestion = finalQuestion
            print("[QuizSession] question ready (\(finalQuestion.count) chars):\n\(finalQuestion)")
            if let multipleChoice = finalMultipleChoice {
                conversation = []
                chatMessages = []
                phase = .awaitingTap(multipleChoice)
            } else {
                conversation = finalMsgs
                chatMessages = [(isUser: false, text: finalQuestion)]
                phase = .chatting
            }
        } catch {
            print("[QuizSession] generateQuestion error: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    /// Called when the student submits a free-text answer.
    func submitFreeAnswer() async {
        let text = chatInput.trimmingCharacters(in: .whitespaces)
        guard case .awaitingText(let stem) = phase, let item = currentItem, !text.isEmpty else { return }
        chatInput = ""

        // Counter quizzes are graded locally (deterministic).
        if item.wordType == "counter" {
            return await gradeCounterAnswer(text: text, stem: stem, item: item)
        }

        // For reading facets, check for an exact kana match locally before calling Claude.
        // An exact match means the student's answer (stripped of whitespace) equals either
        // the committed furigana reading or any kana form in the dictionary definition.
        // When it matches, grade immediately (score 1.0) using the same path as multiple choice.
        let isReadingFacet = item.facet == "meaning-to-reading" || item.facet == "kanji-to-reading"
        if isReadingFacet {
            let validReadings = Set(item.kanaTexts + [item.committedReading].compactMap { $0 })
            if validReadings.contains(text) {
                let resultSummary = "Question: \(stem)\nStudent answered: \(text) — Correct ✓"
                applyLocalGrade(score: 1.0, questionBubble: stem, answerBubble: text,
                                resultSummary: resultSummary, notes: "autograder: exact-match", item: item)
                return
            }
        }

        chatMessages = [
            (isUser: false, text: stem),
            (isUser: true, text: text)
        ]
        isSendingChat = true
        phase = .chatting

        let openingMsg = "Question: \(stem)\nAnswer: \(text)"

        Task { await doOpeningChatTurn(openingMsg, item: item, shouldParseScore: true) }
    }

    // MARK: - Private: shared opening chat turn (no user bubble — context already shown)

    /// Fires the first Claude turn after the student answers (multiple choice tap or free-answer submit).
    /// `shouldParseScore`: true for free-answer (Claude grades); false for multiple choice (app already scored).
    private func doOpeningChatTurn(_ message: String, item: QuizItem, shouldParseScore: Bool) async {
        conversation = [AnthropicMessage(role: "user", content: [.text(message)])]
        do {
            let mnemonicBlock = await fetchMnemonicBlock(for: item)
            let (response, updatedMsgs, meta) = try await client.send(
                messages: conversation,
                system: systemPrompt(for: item, preRecall: preQuizRecall, preHalflife: preQuizHalflife,
                                     postHalflife: gradedHalflife, mnemonicBlock: mnemonicBlock),
                tools: [.lookupJmdict, .lookupKanjidic, .getMnemonic, .setMnemonic],
                maxTokens: 1024,
                toolHandler: makeToolHandler(),
                chatContext: .vocabQuiz(wordId: item.wordId, facet: item.facet, sessionId: item.id.uuidString),
                templateId: nil
            )
            conversation = updatedMsgs
            try? await db.log(apiEvent: ApiEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                eventType: "quiz_chat",
                wordId: item.wordId, quizType: item.facet,
                inputTokens: meta.totalInputTokens, outputTokens: meta.totalOutputTokens,
                chatTurn: 1, model: client.model,
                apiTurns: meta.totalTurns,
                firstTurnInputTokens: meta.firstTurnInputTokens,
                hasMnemonic: mnemonicBlock.isEmpty ? 0 : 1,
                preRecall: preQuizRecall))
            if shouldParseScore, gradedScore == nil, let score = parseScore(from: response) {
                gradedScore = score
                try? await recordReview(item: item, score: score, notes: extractNotes(from: response))
                let nextIndex = currentIndex + 1
                if nextIndex < items.count {
                    let nextItem = items[nextIndex]
                    prefetchTask = Task { await prefetchQuestion(for: nextIndex, item: nextItem) }
                }
            }
            let displayText = strippingMetadata(from: response)
                .replacingOccurrences(of: "MEANING_DEMONSTRATED",
                                      with: "✅ Meaning knowledge noted — memory updated")
            if !displayText.isEmpty {
                chatMessages.append((isUser: false, text: displayText))
            }
            if !meaningBonusApplied && response.contains("MEANING_DEMONSTRATED") {
                meaningBonusApplied = true
                try? await applyMeaningBonus(item: item)
            }
        } catch {
            chatMessages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        isSendingChat = false
    }

    // MARK: - Private: open chat turn

    private func doChatTurn(_ text: String) async {
        guard let item = currentItem else { isSendingChat = false; return }
        chatMessages.append((isUser: true, text: text))
        conversation.append(AnthropicMessage(role: "user", content: [.text(text)]))
        do {
            // After the user's first reply, fetch and inject mnemonics into the system prompt.
            let mnemonicBlock = await fetchMnemonicBlock(for: item)
            let chatTurnNumber = conversation.filter { $0.role == "user" }.count
            // Pair tutor and counter tutor sessions use dedicated system prompts; all other facets use the vocab prompt.
            let activeSystemPrompt: String
            if let pairPrompt = currentPairSystemPrompt {
                activeSystemPrompt = pairPrompt
            } else if let counterPrompt = currentCounterSystemPrompt {
                activeSystemPrompt = counterPrompt
            } else {
                activeSystemPrompt = systemPrompt(for: item, preRecall: preQuizRecall,
                                                   preHalflife: preQuizHalflife,
                                                   postHalflife: gradedHalflife,
                                                   mnemonicBlock: mnemonicBlock)
            }
            let activeTools: [AnthropicTool] = [.lookupJmdict, .lookupKanjidic, .getMnemonic, .setMnemonic]
            let (response, updatedMsgs, meta) = try await client.send(
                messages: conversation,
                system: activeSystemPrompt,
                tools: activeTools,
                maxTokens: 1024,
                toolHandler: makeToolHandler(),
                chatContext: .vocabQuiz(wordId: item.wordId, facet: item.facet, sessionId: item.id.uuidString),
                templateId: nil
            )
            conversation = updatedMsgs
            let toolsJSON = meta.toolsCalled.isEmpty ? nil :
                (try? JSONSerialization.data(withJSONObject: meta.toolsCalled)).flatMap { String(data: $0, encoding: .utf8) }
            let chatScore = parseScore(from: response)
            try? await db.log(apiEvent: ApiEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                eventType: "quiz_chat",
                wordId: item.wordId, quizType: item.facet,
                inputTokens: meta.totalInputTokens, outputTokens: meta.totalOutputTokens,
                chatTurn: chatTurnNumber, model: client.model, toolsCalled: toolsJSON,
                apiTurns: meta.totalTurns,
                firstTurnInputTokens: meta.firstTurnInputTokens,
                hasMnemonic: mnemonicBlock.isEmpty ? 0 : 1,
                score: chatScore,
                preRecall: preQuizRecall))
            let displayText = strippingMetadata(from: response)
                .replacingOccurrences(of: "MEANING_DEMONSTRATED",
                                      with: "✅ Meaning knowledge noted — memory updated")
            if !displayText.isEmpty {
                chatMessages.append((isUser: false, text: displayText))
            }
            print("[QuizSession] chat response (\(response.count) chars):\n\(response)")
            // Auto-detect grading: first SCORE: in this item records the review.
            if gradedScore == nil, let score = parseScore(from: response) {
                gradedScore = score
                print("[QuizSession] graded: score=\(score)")
                try? await recordReview(item: item, score: score, notes: extractNotes(from: response))
                // Start prefetching the next question while the user reads feedback.
                let nextIndex = currentIndex + 1
                if nextIndex < items.count {
                    let nextItem = items[nextIndex]
                    prefetchTask = Task { await prefetchQuestion(for: nextIndex, item: nextItem) }
                }
            }
            // MEANING_DEMONSTRATED: Claude detected the student showed meaning knowledge.
            // Apply bonus passive updates for meaning facets not already covered by the passive map.
            if !meaningBonusApplied && response.contains("MEANING_DEMONSTRATED") {
                meaningBonusApplied = true
                print("[QuizSession] MEANING_DEMONSTRATED detected — applying bonus passive updates")
                try? await applyMeaningBonus(item: item)
            }
        } catch {
            chatMessages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        isSendingChat = false
    }

    // MARK: - Private: record review

    private func recordReview(item: QuizItem, score: Double, notes: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())

        // Append distractor source tag for reading-to-meaning and meaning-to-reading quizzes.
        var finalNotes = notes
        let facetUsesDocumentDistractors = (item.facet == "reading-to-meaning" || item.facet == "meaning-to-reading")
        if facetUsesDocumentDistractors && preferences.distractorSource == .documents {
            finalNotes += (notes.isEmpty ? "" : " ") + "[documents distractors]"
        }

        let review = Review(
            reviewer: deviceName(),
            timestamp: now,
            wordType: item.wordType,
            wordId: item.wordId,
            wordText: item.wordText,
            score: score,
            quizType: item.facet,
            notes: finalNotes.isEmpty ? nil : finalNotes,
            sessionId: item.id.uuidString
        )
        try await db.insert(review: review)

        // Update Ebisu model.
        let existing = try await db.ebisuRecord(
            wordType: item.wordType, wordId: item.wordId, quizType: item.facet)

        let oldModel: EbisuModel
        let lastReview: String

        if let rec = existing {
            oldModel   = rec.model
            lastReview = rec.lastReview
        } else {
            // First review for this facet — use default model with 24h halflife.
            oldModel   = defaultModel(halflife: 24)
            lastReview = now
        }

        let referenceDate = parseISO8601(lastReview) ?? .distantPast
        let elapsed = max(Date().timeIntervalSince(referenceDate) / 3600, 1e-6)
        let newModel = try updateRecall(oldModel, successes: score, total: 1, tnow: elapsed)
        gradedHalflife = newModel.t
        let record = EbisuRecord(
            wordType: item.wordType, wordId: item.wordId, quizType: item.facet,
            alpha: newModel.alpha, beta: newModel.beta, t: newModel.t,
            lastReview: now
        )
        try await db.upsert(record: record)

        // Log model event.
        let now2 = ISO8601DateFormatter().string(from: Date())
        let event = ModelEvent(
            timestamp: now2, wordType: item.wordType, wordId: item.wordId,
            quizType: item.facet, event: "reviewed,\(String(format: "%.2f", score))"
        )
        try await db.log(event: event)

        // Passive facet updates (varied mode only).
        // Rule: passively update facets whose full input set is revealed by the Q+A pair.
        //   kanji-to-reading         Q=kanji,        A=kana    → nothing (meaning unknown; kanji bonus via MEANING_DEMONSTRATED)
        //   reading-to-meaning       Q=kana,         A=meaning → meaning-to-reading (have kana+meaning)
        //   meaning-to-reading       Q=meaning,      A=kana    → reading-to-meaning (have meaning+kana)
        //   meaning-reading-to-kanji Q=meaning+kana, A=kanji   → all three (everything revealed)
        if preferences.quizStyle == .varied {
            let passiveCandidates = Self.passiveMap[item.facet] ?? []
            try await applyPassiveUpdates(item: item, facets: passiveCandidates, now: now)
        }

        try await db.removeFromSession(wordId: item.wordId)
    }

    // MARK: - Private: passive update helpers

    /// Which facets get a passive update when a given facet is actively quizzed.
    /// Logic: passively update facets whose full input set is revealed by the Q+A pair.
    private static let passiveMap: [String: [String]] = [
        // kanji-to-reading: Q=kanji, A=kana — only exercises kanji recognition + reading recall.
        // Nothing else is fully revealed; meaning-reading-to-kanji requires meaning too (see bonus below).
        "kanji-to-reading":         [],
        "reading-to-meaning":       ["meaning-to-reading"],
        "meaning-to-reading":       ["reading-to-meaning"],
        "meaning-reading-to-kanji": ["reading-to-meaning", "meaning-to-reading", "kanji-to-reading"],
        // pair-discrimination reveals both legs (student sees and answers both verbs).
        "pair-discrimination":      ["transitive", "intransitive"],
        // single-leg quizzes reveal one verb; passively update the pair model (partial evidence).
        // The other single-leg facet is NOT updated: answering a transitive quiz doesn't reveal the intransitive verb.
        "transitive":               ["pair-discrimination"],
        "intransitive":             ["pair-discrimination"],
    ]

    /// Apply passive Ebisu updates (score=0.5) for the given facets of an item.
    private func applyPassiveUpdates(item: QuizItem, facets: [String], now: String) async throws {
        for facet in facets {
            guard let rec = try await db.ebisuRecord(
                wordType: item.wordType, wordId: item.wordId, quizType: facet) else { continue }
            let refDate = parseISO8601(rec.lastReview) ?? Date(timeIntervalSinceNow: -60)
            let elapsed = max(Date().timeIntervalSince(refDate) / 3600, 1e-6)
            let updated = try updateRecall(rec.model, successes: 0.5, total: 1, tnow: elapsed)
            let updatedRec = EbisuRecord(
                wordType: item.wordType, wordId: item.wordId, quizType: facet,
                alpha: updated.alpha, beta: updated.beta, t: updated.t, lastReview: now
            )
            try await db.upsert(record: updatedRec)
            let passiveEvent = ModelEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                wordType: item.wordType, wordId: item.wordId, quizType: facet,
                event: "passive,0.5"
            )
            try await db.log(event: passiveEvent)
        }
    }

    /// Bonus passive update when Claude detects the student demonstrated meaning knowledge.
    /// Only applies to kanji-to-reading: that's the one facet where meaning is neither
    /// the input nor already covered by the passive map. For all other facets, meaning
    /// is either the quiz input (meaning-to-reading) or already passively updated.
    private func applyMeaningBonus(item: QuizItem) async throws {
        guard preferences.quizStyle == .varied,
              item.facet == "kanji-to-reading" else { return }
        let bonusFacets = ["reading-to-meaning", "meaning-to-reading", "meaning-reading-to-kanji"]
        let now = ISO8601DateFormatter().string(from: Date())
        try await applyPassiveUpdates(item: item, facets: bonusFacets, now: now)
        print("[QuizSession] meaning bonus passive: \(bonusFacets)")
    }

    // MARK: - Private: prefetch next question

    private func prefetchQuestion(for index: Int, item: QuizItem) async {
        let preRecall: Double?
        let preHalflife: Double?
        if case .reviewed(let recall, _, let halflife) = item.status {
            preRecall   = recall
            preHalflife = halflife
        } else {
            preRecall   = nil
            preHalflife = nil
        }

        // Transitive-pair: pick a random drill app-side, no LLM call needed.
        if item.wordType == "transitive-pair" {
            guard currentIndex <= index else { return }
            guard let pairCorpus,
                  let pairItem = pairCorpus.items.first(where: { $0.id == item.wordId }),
                  let drills = pairItem.pair.drills, !drills.isEmpty else {
                print("[QuizSession] prefetch: no drills for pair \(item.wordId), skipping")
                return
            }
            let drill = drills.randomElement()!
            let askedLeg: AskedLeg? = item.facet == "transitive" ? .transitive
                                    : item.facet == "intransitive" ? .intransitive
                                    : nil
            let q = PairQuestion(
                intransitiveEnglish: drill.intransitive.en,
                transitiveEnglish: drill.transitive.en,
                intransitiveKana: pairItem.pair.intransitive.kana,
                intransitiveKanji: pairItem.pair.intransitive.kanji,
                transitiveKana: pairItem.pair.transitive.kana,
                transitiveKanji: pairItem.pair.transitive.kanji,
                intransitiveJapanese: drill.intransitive.ja,
                transitiveJapanese: drill.transitive.ja,
                askedLeg: askedLeg
            )
            prefetched = (index: index, question: "", multipleChoice: nil,
                          pairQuestion: q,
                          conversation: [],
                          preRecall: preRecall, preHalflife: preHalflife,
                          counterExampleQueue: [])
            print("[QuizSession] prefetch (transitive-pair, app-side) stored for index \(index): \(item.wordText)")
            return
        }

        // Counter: build deterministic stem app-side, no LLM call needed.
        if item.wordType == "counter" {
            guard currentIndex <= index else { return }
            guard let counterCorpus,
                  let counterItem = counterCorpus.items.first(where: { $0.id == item.wordId }) else {
                print("[QuizSession] prefetch: counter not found for \(item.wordId), skipping")
                return
            }
            let stem: String
            var prefetchedExampleQueue: [String] = []
            switch item.facet {
            case "meaning-to-reading":
                // Build the example queue directly from the next item's data — do NOT read
                // counterExampleQueue here, as that belongs to the currently-displayed item.
                let examples = Array(counterItem.counter.countExamples.shuffled().prefix(3))
                prefetchedExampleQueue = examples
                if let first = examples.first {
                    stem = "What counter word (読み方) counts \(first)?"
                } else {
                    stem = "What is the reading of the counter \(counterItem.counter.kanji)(\(counterItem.counter.reading))?"
                }
            case "counter-number-to-reading":
                stem = buildCounterNumberStem(counter: counterItem.counter)
            default:
                print("[QuizSession] prefetch: unknown counter facet \(item.facet), skipping")
                return
            }
            prefetched = (index: index, question: stem, multipleChoice: nil,
                          pairQuestion: nil,
                          conversation: [],
                          preRecall: preRecall, preHalflife: preHalflife,
                          counterExampleQueue: prefetchedExampleQueue)
            print("[QuizSession] prefetch (counter, app-side) stored for index \(index): \(item.wordText)")
            return
        }

        // Free-answer: stem is app-side — instant, no network call.
        if item.isFreeAnswer {
            guard currentIndex <= index else { return }
            let stem = freeAnswerStem(for: item)
            prefetched = (index: index, question: stem, multipleChoice: nil,
                          pairQuestion: nil,
                          conversation: [],
                          preRecall: preRecall, preHalflife: preHalflife,
                          counterExampleQueue: [])
            print("[QuizSession] prefetch (free-answer, app-side) stored for index \(index): \(item.wordText)")
            return
        }

        // Documents distractor mode: build multiple-choice app-side, no LLM call needed.
        if let appSideQuestion = appSideMultipleChoice(for: item) {
            guard currentIndex <= index else { return }
            prefetched = (index: index, question: appSideQuestion.stem, multipleChoice: appSideQuestion,
                          pairQuestion: nil,
                          conversation: [],
                          preRecall: preRecall, preHalflife: preHalflife,
                          counterExampleQueue: [])
            print("[QuizSession] prefetch (app-side multiple choice, documents) stored for index \(index): \(item.wordText)")
            return
        }

        let system  = systemPrompt(for: item, isGenerating: true,
                                   preRecall: preRecall, preHalflife: preHalflife)
        let initMsg = AnthropicMessage(role: "user", content: [.text(questionRequest(for: item))])

        print("[QuizSession] prefetch multiple choice: starting for index \(index): \(item.wordText) facet:\(item.facet)")
        do {
            let (finalQuestion, finalMultipleChoice, finalMsgs) = try await runGenerationLoop(
                for: item, system: system, initMsg: initMsg, label: "prefetch",
                preRecall: preRecall)
            guard currentIndex <= index else {
                print("[QuizSession] prefetch for index \(index) is stale, discarding")
                return
            }
            prefetched = (index: index, question: finalQuestion, multipleChoice: finalMultipleChoice,
                          pairQuestion: nil,
                          conversation: finalMsgs,
                          preRecall: preRecall, preHalflife: preHalflife,
                          counterExampleQueue: [])
            print("[QuizSession] prefetch stored for index \(index): \(item.wordText)")
        } catch {
            print("[QuizSession] prefetchQuestion error for index \(index): \(error)")
        }
    }

    // MARK: - Private: generation loop

    /// Two-attempt generate+validate loop shared by generateQuestion and prefetchQuestion.
    // MARK: - Test harness entry point

    /// Generate a question for a given item and return the question text + raw conversation.
    /// Intended for CLI test harness use only; bypasses phase state machine entirely.
    func generateQuestionForTesting(item: QuizItem) async throws -> (question: String, multipleChoice: MultipleChoiceQuestion?, conversation: [AnthropicMessage]) {
        let system = systemPrompt(for: item, isGenerating: true)
        let initMsg = AnthropicMessage(role: "user", content: [.text(questionRequest(for: item))])
        return try await runGenerationLoop(for: item, system: system, initMsg: initMsg, label: "test")
    }

    /// Grade a free-text answer for a given item. Returns Claude's full response text.
    /// Intended for CLI test harness use only; bypasses phase state machine entirely.
    func gradeAnswerForTesting(item: QuizItem, stem: String, answer: String) async throws -> String {
        let system = systemPrompt(for: item)  // isGenerating=false → grading prompt
        let openingMsg = "Question you asked me: \(stem)\nMy answer: \(answer)\nPlease grade my answer."
        let messages = [AnthropicMessage(role: "user", content: [.text(openingMsg)])]
        let (response, _, _) = try await client.send(
            messages: messages,
            system: system,
            tools: [.lookupJmdict, .lookupKanjidic, .getMnemonic, .setMnemonic],
            maxTokens: 1024,
            toolHandler: makeToolHandler(),
            chatContext: .vocabQuiz(wordId: item.wordId, facet: item.facet, sessionId: item.id.uuidString),
            templateId: "vocab-llm-grade"
        )
        return response
    }

    /// Tools to use during question generation, based on facet.
    /// reading-to-meaning/meaning-to-reading/kanji-to-reading produce kana or English distractors — no lookup needed.
    /// meaning-reading-to-kanji: Haiku thinks of candidates itself, then verifies with jmdict — no kanjidic needed.
    static func generationTools(for facet: String) -> [AnthropicTool] {
        switch facet {
        case "reading-to-meaning", "meaning-to-reading":
            return []   // distractors are English or kana — Claude knows these without lookup
        case "kanji-to-reading":
            return []   // distractors are kana — Haiku knows on/kun readings without lookup
        case "meaning-reading-to-kanji":
            return []   // distractors are kanji substitutions — Haiku knows Japanese words without lookup
        default:
            return [.lookupJmdict]
        }
    }

    /// Collect candidate words from the corpus for use as reading-to-meaning and meaning-to-reading distractors.
    ///
    /// Strategy:
    ///   1. Find which documents contain the quiz word (via VocabManifest sources).
    ///   2. Collect all other word IDs that appear in those same documents.
    ///   3. If fewer than targetCount candidates, expand to documents adjacent in the
    ///      corpus story list (by index offset ±1, ±2, … until enough or list exhausted).
    ///   4. For each candidate word ID, take the first gloss of the first corpus-attested sense,
    ///      falling back to sense index 0.
    ///   5. Return up to targetCount pairs, excluding the quiz word itself and any word
    ///      whose gloss is empty.
    ///
    /// This is a synchronous, in-memory computation — no database or network calls.
    private func distractorCandidates(for item: QuizItem, targetCount: Int = 25) -> [(display: String, gloss: String, kana: String)] {
        guard let manifest = VocabSync.cached() else {
            print("[QuizSession] distractorCandidates: manifest not cached, falling back to AI distractors")
            return []
        }

        // Build a map from word ID to VocabWordEntry for fast lookup.
        var entryByID: [String: VocabWordEntry] = [:]
        for entry in manifest.words { entryByID[entry.id] = entry }

        let storyTitles = manifest.stories.map(\.title)

        // Documents containing the quiz word.
        let quizSources = Set(entryByID[item.wordId]?.sources ?? [])

        // Collect candidate word IDs from the same documents first, then expand outward.
        // Only enrolled words are useful candidates (we need their senseExtras for the gloss).
        let enrolledIDs = Set(allCandidates.map(\.wordId))
        var candidateIDs: [String] = []
        var seenIDs = Set<String>([item.wordId])

        // Helper: add enrolled word IDs from a given document title.
        func collectFrom(title: String) {
            for entry in manifest.words {
                guard enrolledIDs.contains(entry.id),
                      !seenIDs.contains(entry.id),
                      entry.sources.contains(title) else { continue }
                seenIDs.insert(entry.id)
                candidateIDs.append(entry.id)
            }
        }

        print("[QuizSession] distractorCandidates: word=\(item.wordId) sources=\(quizSources.sorted()) enrolledPool=\(enrolledIDs.count)")

        // Pass 1: documents the quiz word is in.
        for title in quizSources { collectFrom(title: title) }

        // Pass 2: expand to adjacent documents if still under target.
        if candidateIDs.count < targetCount {
            // Indices of the quiz word's source documents in the ordered story list.
            let sourceIndices = storyTitles.indices.filter { quizSources.contains(storyTitles[$0]) }
            var offset = 1
            while candidateIDs.count < targetCount && offset <= storyTitles.count {
                var added = false
                for baseIndex in sourceIndices {
                    for delta in [-offset, offset] {
                        let idx = baseIndex + delta
                        guard idx >= 0 && idx < storyTitles.count else { continue }
                        let title = storyTitles[idx]
                        guard !quizSources.contains(title) else { continue }
                        collectFrom(title: title)
                        added = true
                    }
                }
                if !added { break }
                offset += 1
            }
        }

        print("[QuizSession] distractorCandidates: \(candidateIDs.count) candidate ID(s) after document expansion")

        // Convert IDs to (display, gloss, kana) tuples using senseExtras already on each QuizItem.
        // We rely on the items loaded in the session for senseExtras, falling back to the
        // manifest's written forms for the display text.
        var result: [(display: String, gloss: String, kana: String)] = []
        for wordID in candidateIDs.prefix(targetCount * 2) {   // over-fetch to account for empties
            // Look up senseExtras from the loaded quiz items (already fetched from JMDict).
            let senseExtras: [SenseExtra]
            let corpusIndices: [Int]
            let writtenTexts: [String]
            let kanaTexts: [String]
            // Search all enrolled candidates, not just the current session's items,
            // so that words not due for review today can still serve as distractors.
            if let quizItem = allCandidates.first(where: { $0.wordId == wordID }) {
                senseExtras = quizItem.senseExtras
                corpusIndices = quizItem.corpusSenseIndices
                writtenTexts = quizItem.writtenTexts
                kanaTexts = quizItem.kanaTexts
            } else {
                // Word is in the corpus but not enrolled — we have no senseExtras for it.
                // Skip it; we only use enrolled words whose meanings we can display.
                continue
            }

            // Pick one random corpus-attested sense, then one random gloss within it.
            // Two-stage selection gives each sense equal weight regardless of gloss count.
            let activeIndex = corpusIndices.randomElement() ?? 0
            guard activeIndex < senseExtras.count else { continue }
            let gloss = senseExtras[activeIndex].glosses.randomElement() ?? ""
            guard !gloss.isEmpty else { continue }

            // Display text: first written form, or first kana if no written forms.
            let display = writtenTexts.first ?? kanaTexts.first ?? wordID

            let kana = kanaTexts.first ?? ""
            result.append((display: display, gloss: gloss, kana: kana))
            if result.count >= targetCount { break }
        }
        print("[QuizSession] distractorCandidates: returning \(result.count) usable candidate(s)\(result.isEmpty ? " — falling back to AI distractors" : "")")
        return result
    }

    func runGenerationLoop(for item: QuizItem, system: String,
                                   initMsg: AnthropicMessage, label: String,
                                   tools: [AnthropicTool]? = nil,
                                   preRecall: Double? = nil)
        async throws -> (question: String, multipleChoice: MultipleChoiceQuestion?, conversation: [AnthropicMessage])
    {
        let resolvedTools = tools ?? Self.generationTools(for: item.facet)
        var finalQuestion = ""
        var finalMultipleChoice: MultipleChoiceQuestion? = nil
        var finalMsgs: [AnthropicMessage] = []
        let isPrefetch = label == "prefetch" ? 1 : 0
        let qFormat = item.isFreeAnswer ? "free_answer" : "multiple_choice"
        for attempt in 1...2 {
            let (raw, msgs, meta) = try await client.send(
                messages: [initMsg],
                system: system,
                tools: resolvedTools,
                maxTokens: 1024,
                toolHandler: makeToolHandler(),
                chatContext: .vocabQuiz(wordId: item.wordId, facet: item.facet, sessionId: item.id.uuidString),
                templateId: "vocab-mc-\(item.facet)"
            )
            finalMsgs = msgs
            let genToolsJSON = meta.toolsCalled.isEmpty ? nil :
                (try? JSONSerialization.data(withJSONObject: meta.toolsCalled)).flatMap { String(data: $0, encoding: .utf8) }
            // Parse multiple-choice JSON (generation loop is only used for multiple choice; free-answer stems are built app-side)
            let parsedMC: MultipleChoiceQuestion?
            if item.facet == "meaning-reading-to-kanji" {
                let correctForm = item.partialKanjiTemplate ?? item.committedWrittenText ?? item.wordText
                let stem = meaningReadingToKanjiStem(for: item)
                parsedMC = parseMeaningReadingToKanjiSubstitutions(raw, correctForm: correctForm, stem: stem, forbiddenForms: Set(item.writtenTexts))
            } else {
                parsedMC = parseMultipleChoiceJSON(raw)
            }
            if let multipleChoice = parsedMC {
                finalMultipleChoice = multipleChoice
                let letters = ["A", "B", "C", "D"]
                let choicesText = multipleChoice.choices.enumerated().map { "\(letters[$0])) \($1)" }.joined(separator: "\n")
                finalQuestion = "\(multipleChoice.stem)\n\n\(choicesText)"
            } else {
                print("[QuizSession] \(label) attempt \(attempt): multiple choice JSON parse failed")
                finalQuestion = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try? await db.log(apiEvent: ApiEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                eventType: "question_gen",
                wordId: item.wordId, quizType: item.facet,
                inputTokens: meta.totalInputTokens, outputTokens: meta.totalOutputTokens,
                model: client.model, generationAttempt: attempt, toolsCalled: genToolsJSON,
                apiTurns: meta.totalTurns,
                firstTurnInputTokens: meta.firstTurnInputTokens,
                questionChars: finalQuestion.count,
                questionFormat: qFormat, prefetch: isPrefetch, preRecall: preRecall))
            // Retry if parse failed and we have attempts left
            if finalMultipleChoice != nil || attempt >= 2 { break }
            print("[QuizSession] \(label) attempt \(attempt): multiple choice parse failed, retrying")
        }
        return (finalQuestion, finalMultipleChoice, finalMsgs)
    }

    /// Returns kanji characters (CJK Unified Ideographs) from a string, preserving order, with duplicates removed.
    nonisolated static func extractKanji(from text: String) -> [String] {
        var seen = Set<String>()
        return text.unicodeScalars
            .filter { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) ||
                      ($0.value >= 0x3400 && $0.value <= 0x4DBF) ||
                      ($0.value >= 0xF900 && $0.value <= 0xFAFF) }
            .map { String($0) }
            .filter { seen.insert($0).inserted }
    }

    /// Builds a pre-populated substitution-slots string for the meaning-reading-to-kanji distractor prompt.
    /// Cycles through `kanji` to fill `count` slots, each with a "?" placeholder for the replacement.
    /// Example: kanji=["閉","籠"], count=3 → `[["閉","?"], ["籠","?"], ["閉","?"]]`
    static func substitutionSlotsString(kanji: [String], count: Int = 3) -> String {
        guard !kanji.isEmpty else { return "[]" }
        let slots = (0..<count).map { i in "[\"\(kanji[i % kanji.count])\", \"?\"]" }
        return "[\(slots.joined(separator: ", "))]"
    }

    /// Parses the meaning-reading-to-kanji substitutions response.
    /// Expects a plain JSON array of [original, replacement] pairs (no wrapper object).
    /// Applies substitutions to `correctForm` to build distractors, uses `stem` as the question stem.
    /// `forbiddenForms` seeds the deduplication set so no valid written form of the word appears as a distractor.
    private func parseMeaningReadingToKanjiSubstitutions(_ raw: String, correctForm: String, stem: String, forbiddenForms: Set<String> = []) -> MultipleChoiceQuestion? {
        // Extract the outermost [...] array from the response (may be inside a code fence).
        func extractArray() -> String? {
            var search = raw[...]
            while let fenceStart = search.range(of: "```") {
                let afterFence = search[fenceStart.upperBound...]
                let body = afterFence.drop(while: { $0 != "\n" }).dropFirst()
                if let closeRange = body.range(of: "```") {
                    let candidate = String(body[..<closeRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.hasPrefix("[") { return candidate }
                    search = body[closeRange.upperBound...]
                } else { break }
            }
            if let open = raw.firstIndex(of: "["), let close = raw.lastIndex(of: "]") {
                return String(raw[open...close])
            }
            return nil
        }
        guard let jsonText = extractArray(),
              let data = jsonText.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        // Resolve substitutions: either flat ["r1","r2","r3"] (single kanji) or pairs [["k","r"],...] (multi kanji).
        let substitutableKanji = Self.extractKanji(from: correctForm)
        var seen = forbiddenForms.union([correctForm])
        var distractors: [String] = []

        if let replacements = parsed as? [String], substitutableKanji.count == 1 {
            // Single-kanji format: flat array of replacement strings.
            let kanji = substitutableKanji[0]
            for replacement in replacements {
                guard !replacement.isEmpty else { continue }
                // replacingOccurrences replaces all instances of the kanji, which is safe:
                // Japanese dictionary headwords (single morphemes) don't have the same kanji twice.
                let distractor = correctForm.replacingOccurrences(of: kanji, with: replacement)
                guard distractor != correctForm, seen.insert(distractor).inserted else { continue }
                distractors.append(distractor)
                if distractors.count == 3 { break }
            }
        } else if let pairs = parsed as? [[String]] {
            // Multi-kanji format: array of [original, replacement] pairs.
            // Prompt asks for 4 pairs to handle cases where Haiku violates constraints (e.g., uses a forbidden
            // replacement). We take the first 3 that produce unique valid distractors. User chat.sqlite is logged
            // for monitoring how often the 4th pair is actually needed.
            guard pairs.count >= 4 else { return nil }
            for pair in pairs {
                guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { continue }
                let distractor = correctForm.replacingOccurrences(of: pair[0], with: pair[1])
                guard distractor != correctForm, seen.insert(distractor).inserted else { continue }
                distractors.append(distractor)
                if distractors.count == 3 { break }
            }
        } else { return nil }

        guard distractors.count == 3 else { return nil }

        let newCorrectIndex = Int.random(in: 0..<4)
        var choices = [correctForm] + distractors
        choices.swapAt(0, newCorrectIndex)
        return MultipleChoiceQuestion(stem: stem, choices: choices, correctIndex: newCorrectIndex)
    }

    private func parseMultipleChoiceJSON(_ raw: String) -> MultipleChoiceQuestion? {
        // Try each fenced code block in order (model may reason in earlier blocks)
        var search = raw[...]
        while let fenceStart = search.range(of: "```") {
            let afterFence = search[fenceStart.upperBound...]
            let body = afterFence.drop(while: { $0 != "\n" }).dropFirst()
            if let closeRange = body.range(of: "```") {
                let candidate = String(body[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let multipleChoice = decodeMultipleChoice(from: candidate) { return multipleChoice }
                search = body[closeRange.upperBound...]
            } else {
                break
            }
        }
        // No fence — extract outermost {...} in case there's surrounding prose
        if let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}") {
            return decodeMultipleChoice(from: String(raw[open...close]))
        }
        return nil
    }

    private func decodeMultipleChoice(from text: String) -> MultipleChoiceQuestion? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stem = obj["stem"] as? String,
              let choices = obj["choices"] as? [String],
              choices.count == 4
        else { return nil }
        // The model always places the correct answer at index 0; shuffle app-side so we
        // control randomness rather than relying on the model to track an index correctly.
        let newCorrectIndex = Int.random(in: 0..<4)
        var shuffledChoices = choices
        shuffledChoices.swapAt(0, newCorrectIndex)
        return MultipleChoiceQuestion(stem: stem, choices: shuffledChoices, correctIndex: newCorrectIndex)
    }

    // MARK: - Private: mnemonic helpers

    /// Fetch the vocab mnemonic + any relevant kanji mnemonics for the current item.
    /// Returns a formatted block for inclusion in the system prompt, or empty string if none.
    private func fetchMnemonicBlock(for item: QuizItem) async -> String {
        guard let db = toolHandler.quizDB else { return "" }
        var parts: [String] = []
        // Vocab mnemonic
        if let m = try? await db.mnemonic(wordType: "jmdict", wordId: item.wordId) {
            parts.append("Vocab mnemonic: \(m.mnemonic)")
        }
        // Kanji mnemonics — extract kanji characters from written forms
        let kanjiChars = item.writtenTexts.joined()
            .unicodeScalars
            .filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF ||
                      $0.value >= 0x3400 && $0.value <= 0x4DBF ||
                      $0.value >= 0xF900 && $0.value <= 0xFAFF }
            .map { String($0) }
        let uniqueKanji = Array(Set(kanjiChars))
        if !uniqueKanji.isEmpty,
           let kanjiMnemonics = try? await db.mnemonics(wordType: "kanji", wordIds: uniqueKanji),
           !kanjiMnemonics.isEmpty {
            for km in kanjiMnemonics {
                parts.append("Kanji mnemonic for \(km.wordId): \(km.mnemonic)")
            }
        }
        guard !parts.isEmpty else { return "" }
        return "\nMnemonics on file (use these to help the student; suggest saving new ones via set_mnemonic):\n"
            + parts.joined(separator: "\n")
    }

    // MARK: - Private: tool handler

    private func makeToolHandler() -> AnthropicClient.ToolHandler {
        let th = toolHandler
        return { name, input in
            return try await th.handle(toolName: name, input: input)
        }
    }

    // MARK: - Private: prompt helpers

    /// Build a multiple-choice question entirely in Swift from corpus candidates, no LLM call.
    /// Returns nil if there are not enough distinct candidates to form 3 distractors.
    private func appSideMultipleChoice(for item: QuizItem) -> MultipleChoiceQuestion? {
        guard preferences.distractorSource == .documents,
              item.facet == "reading-to-meaning" || item.facet == "meaning-to-reading" else { return nil }

        let candidates = distractorCandidates(for: item)

        if item.facet == "reading-to-meaning" {
            let kana = item.committedReading ?? item.kanaTexts.first ?? "?"
            let stem = "What does \(kana) mean?"
            // Two-stage: random corpus sense, then random gloss within it.
            let correctGloss = item.corpusSenses.randomElement()?.glosses.randomElement() ?? ""
            guard !correctGloss.isEmpty else { return nil }

            let distractorGlosses = candidates
                .map { $0.gloss }
                .filter { !$0.isEmpty && $0 != correctGloss }
            guard distractorGlosses.count >= 3 else { return nil }
            let picked = Array(distractorGlosses.shuffled().prefix(3))

            let correctIndex = Int.random(in: 0...3)
            var choices = picked
            choices.insert(correctGloss, at: correctIndex)
            return MultipleChoiceQuestion(stem: stem, choices: choices, correctIndex: correctIndex)

        } else { // meaning-to-reading
            let meanings = item.corpusSenses.flatMap(\.glosses).prefix(3).joined(separator: "; ")
            guard !meanings.isEmpty else { return nil }
            let stem = meanings
            let correctKana = item.committedReading ?? item.kanaTexts.first ?? ""
            guard !correctKana.isEmpty else { return nil }

            let distractorKanas = candidates
                .compactMap { $0.kana.isEmpty ? nil : $0.kana }
                .filter { $0 != correctKana }
            guard distractorKanas.count >= 3 else { return nil }
            let picked = Array(distractorKanas.shuffled().prefix(3))

            let correctIndex = Int.random(in: 0...3)
            var choices = picked
            choices.insert(correctKana, at: correctIndex)
            return MultipleChoiceQuestion(stem: stem, choices: choices, correctIndex: correctIndex)
        }
    }

    func systemPrompt(for item: QuizItem, isGenerating: Bool = false,
                              preRecall: Double? = nil, preHalflife: Double? = nil,
                              postHalflife: Double? = nil, mnemonicBlock: String = "") -> String {
        // meaning-reading-to-kanji generation only needs the word form, kana, and substitution rules.
        // The full shared-scaffold prompt (entry ref, memory, facet label) carries irrelevant noise for this task.
        if item.facet == "meaning-reading-to-kanji" && isGenerating {
            let correctForm = item.partialKanjiTemplate ?? item.committedWrittenText ?? item.wordText
            let kana = item.committedReading ?? item.kanaTexts.first ?? ""
            let substitutableKanji: [String]
            if let committed = item.committedKanji, !committed.isEmpty {
                substitutableKanji = committed
            } else {
                substitutableKanji = Self.extractKanji(from: correctForm)
            }
            let forbidden = Self.extractKanji(from: item.writtenTexts.joined()).joined(separator: ", ")
            let kanaNote = kana.isEmpty ? "" : " (\(kana))"
            if substitutableKanji.count == 1 {
                let kanji = substitutableKanji[0]
                return """
                Word: \(correctForm)\(kanaNote)
                Replace \(kanji) with 3 distinct kanji, each visually similar to or sharing a reading with \(kanji).
                Kana characters in the word are fixed — only \(kanji) is being replaced.
                Forbidden (valid written forms of this word — never use): \(forbidden).
                """
            } else {
                let slots = Self.substitutionSlotsString(kanji: substitutableKanji, count: 4)
                return """
                Word: \(correctForm)\(kanaNote)
                For each pre-filled pair below, replace the ? with a single kanji that is visually similar to or shares a reading with the original.
                Only the kanji positions listed are substituted — kana characters in the word are fixed and must appear unchanged in every option.
                Pairs: \(slots)
                Forbidden replacements (valid written forms of this word — never use): \(forbidden).
                All 4 replacements must produce distinct strings when substituted.
                """
            }
        }

        let facetRule: String
        let wordLine: String
        // Full entry data injected into every facet so Claude never needs to look up the target word.
        // Each facet then restricts what may appear in the question *stem* — separate from what Claude knows.
        let allWritten  = item.writtenTexts.isEmpty  ? "none" : item.writtenTexts.joined(separator: ", ")
        let allKana     = item.kanaTexts.isEmpty     ? "none" : item.kanaTexts.joined(separator: ", ")
        // Use only the corpus-attested senses. corpusSenses defaults to [senseExtras[0]]
        // when vocab.json has no llm_sense data — prevents testing obscure/distant senses by default.
        let corpusSenses = item.corpusSenses
        let allMeanings = corpusSenses.isEmpty ? "unknown" : corpusSenses.flatMap(\.glosses).joined(separator: "; ")

        // Aggregate sense-level metadata across all senses for context (deduplicated).
        let extras = item.senseExtras
        let posLine: String = {
            let all = Array(NSOrderedSet(array: extras.flatMap(\.partOfSpeech))) as? [String] ?? []
            return all.isEmpty ? "" : " pos=\(all.joined(separator: ","))"
        }()
        let miscLine: String = {
            let all = Array(NSOrderedSet(array: extras.flatMap(\.misc))) as? [String] ?? []
            return all.isEmpty ? "" : " misc=\(all.joined(separator: ","))"
        }()
        let infoLine: String = {
            let all = Array(NSOrderedSet(array: extras.flatMap(\.info))) as? [String] ?? []
            return all.isEmpty ? "" : " notes=\(all.joined(separator: "; "))"
        }()
        let relatedLine: String = {
            let all = extras.flatMap(\.related)
            return all.isEmpty ? "" : " related=\(SenseExtra.formatXrefs(all))"
        }()
        let antonymLine: String = {
            let all = extras.flatMap(\.antonym)
            return all.isEmpty ? "" : " antonym=\(SenseExtra.formatXrefs(all))"
        }()
        let entryRef = "[Entry ref — never copy verbatim into question stem: written=\(allWritten) kana=\(allKana) meanings=\(allMeanings)\(posLine)\(miscLine)\(infoLine)\(relatedLine)\(antonymLine)]"

        switch item.facet {
        case "reading-to-meaning":
            if isGenerating {
                let stemKana = item.committedReading ?? item.kanaTexts.first ?? "unknown"
                facetRule = "Show kana ONLY (never kanji). The kana to show in the stem is: \(stemKana). Ask for English meaning. All A/B/C/D options MUST be in English. Student is learning these enrolled senses only: \(allMeanings). Do not use other JMDict senses as the correct answer or as distractors."
                wordLine = "Word: \(entryRef)."
            } else {
                facetRule = "Facet tested: reading-to-meaning (student sees kana, answers with English meaning). Enrolled senses: \(allMeanings)."
                wordLine = "Word: \(entryRef)"
            }
        case "meaning-to-reading":
            if isGenerating {
                facetRule = "Show English meaning (enrolled senses only: \(allMeanings)). Ask for kana reading. Do not reference other JMDict senses."
                // No explicit correct-answer pin here: for kana-only words with multiple readings
                // (e.g. そっと/そうっと/そおっと/そーっと) the model seems to pick the first
                // listed kana, which is the primary reading. That's acceptable behaviour.
                wordLine = "Word: \(entryRef). Correct answer must be listed kana."
            } else {
                facetRule = "Facet tested: meaning-to-reading (student sees English, answers with kana reading)."
                wordLine = "Word: \(entryRef)"
            }
        case "kanji-to-reading":
            // When a student commits to learning the kanji form of a word, they commit to a
            // specific kanji+kana pairing stored in the word_commitment table. That pairing has
            // exactly one reading, so kanaTexts.first is always the single correct answer here —
            // unlike kana-only words, which may carry several equally valid readings.
            let ktrKana = item.kanaTexts.first ?? "unknown"
            if let template = item.partialKanjiTemplate,
               let committed = item.committedKanji {
                let committedList = committed.joined(separator: "、")
                if isGenerating {
                    facetRule = """
                    Show \(template), ask for full reading. Studying: \(committedList).
                    CORRECT ANSWER IS EXACTLY: \(ktrKana).
                    The 3 distractors substitute ONLY the reading of the committed kanji \
                    (\(committedList)); all other kana stay identical. \
                    Use alternate on/kun readings of that kanji or swap one mora — no lookup needed. \
                    Question stem must be in English.
                    """
                    wordLine = "Word: display \(template) \(entryRef). Never show full kana reading in the stem."
                } else {
                    facetRule = "Facet tested: kanji-to-reading partial (\(template), studying \(committedList), correct reading: \(ktrKana)). Weight errors on the studied kanji (\(committedList)) more heavily than errors on unstudied portions."
                    wordLine = "Word: \(entryRef)"
                }
            } else {
                if isGenerating {
                    facetRule = """
                    Show kanji ONLY (never kana). Ask for kana reading. Question stem must be in English.
                    CORRECT ANSWER IS EXACTLY: \(ktrKana).
                    """
                    wordLine = "Word: \(item.wordText) \(entryRef)."
                } else {
                    facetRule = "Facet tested: kanji-to-reading (student sees kanji, answers with kana reading)."
                    wordLine = "Word: \(entryRef)"
                }
            }
        case "meaning-reading-to-kanji":
            // Generation is handled by the early return above; this branch is coaching-only.
            if let template = item.partialKanjiTemplate,
               let committed = item.committedKanji, !committed.isEmpty {
                let committedList = committed.joined(separator: "、")
                facetRule = "Facet tested: meaning-reading-to-kanji partial (studying \(committedList), correct form: \(template)). Weight errors on the studied kanji (\(committedList)) more heavily than errors on unstudied portions."
                wordLine = "Word: \(entryRef)"
            } else {
                let enrolledForm = item.committedWrittenText ?? item.wordText
                facetRule = "Facet tested: meaning-reading-to-kanji (student sees English + kana, answers with kanji form). Correct form: \(enrolledForm)."
                wordLine = "Word: \(entryRef)"
            }
        default:
            facetRule = "Standard quiz-purity rules."
            wordLine = "Word: \(item.wordText) \(entryRef)"
        }
        let ebisuLine: String
        if let r = preRecall, let h = preHalflife {
            if let ph = postHalflife {
                ebisuLine = "recall=\(String(format: "%.2f", r)) halflife=\(String(format: "%.0f", h))h→\(String(format: "%.0f", ph))h"
            } else {
                ebisuLine = "recall=\(String(format: "%.2f", r)) halflife=\(String(format: "%.0f", h))h"
            }
        } else {
            ebisuLine = "new word"
        }
        let distractorLine: String
        if !isGenerating || item.isFreeAnswer {
            distractorLine = ""
        } else {
            switch item.facet {
            case "reading-to-meaning":
                distractorLine = "\nDistractors: write 3 wrong English meanings directly — no lookup needed. Pick meanings from the same semantic field (similar topic but clearly distinguishable). Bare phrases only, no parenthetical notes."
            case "meaning-to-reading":
                distractorLine = "\nDistractors: write 3 wrong kana readings directly — no lookup needed. Use readings of real Japanese words that are semantically related (same general topic or domain) but clearly distinguishable in meaning, or plausible non-words. Avoid synonyms: pick words such that the learner must truly know the target word to choose correctly. Prefer words of approximately the same mora length as the correct answer."
            case "kanji-to-reading":
                // Partial kanji-to-reading already has specific distractor instructions in facetRule
                if item.partialKanjiTemplate != nil {
                    distractorLine = ""
                } else {
                    distractorLine = "\nDistractors: write 3 wrong kana readings directly — no lookup needed. Use alternate on/kun readings of the kanji or swap one mora. Keep the same length and rhythm as the correct answer."
                }
            default:
                distractorLine = ""
            }
        }
        let stemLeakGuard: String
        if isGenerating && item.facet != "meaning-reading-to-kanji" {
            stemLeakGuard = "\nCRITICAL: Never leak the answer form into the question stem. Silently verify before outputting."
        } else {
            stemLeakGuard = ""
        }
        let sharedCore = """
        You are quizzing a Japanese learner.
        \(wordLine)
        Memory: \(ebisuLine)
        Facet: \(item.facet) — \(facetRule)\(stemLeakGuard)\(distractorLine)
        """
        if isGenerating {
            return sharedCore
        } else if item.isFreeAnswer {
            return sharedCore + """

        Open conversation: student may answer, ask about this/other words, or mix.
        SCORE: X.X (0.0–1.0) — emit this on the same turn you grade. Format exactly: SCORE: X.X — <one grading sentence> (use a space or dash after the number, never a sentence-ending period directly after X.X). Never emit SCORE on a line by itself with no other prose.
        Scoring is Bayesian confidence, not percentage-correct. Ask: "how confident am I that this answer reflects whether the student actually remembers the word?"
        - 1.0: strong evidence they remember — correct or trivially equivalent (extra annotation, minor formatting, or romaji transcription of the correct kana — romaji and kana are equally valid ways to express the same phonetic answer)\(item.facet == "reading-to-meaning" ? ". For words with multiple senses, demonstrating any one sense correctly is 1.0 — the student is not expected to enumerate all senses" : "")
        - 0.8–0.9: good evidence they remember — right answer with a minor slip: for kana/romaji, a missing/wrong small kana (ゅ/ょ/っ) or long-vowel marker (ー), or a plausible romaji variant (e.g. "ou" vs "ō"); for meaning, a paraphrase that captures the core concept
        - 0.5: no evidence either way — ambiguous, can't tell if they know it (do NOT use 0.5 as "half credit")
        - 0.1–0.3: good evidence they don't remember — wrong but in the right domain
        - 0.0: strong evidence they don't remember — completely wrong word or meaning
        NOTES: one sentence on same message as SCORE.
        \(item.facet == "kanji-to-reading" ? "MEANING_DEMONSTRATED: output this exact token verbatim on its own line (no punctuation, no surrounding text) ONLY if the student's answer contains an English meaning or uses the word in an English sentence (e.g. 'it means precedent', 'prior example'). Correct kana or kanji, even perfect, do NOT qualify. Only emit if the student demonstrates the meaning of the word being tested — ignore other words they mention. Do not describe the token — just output it.\n" : "")\
        Do not emit SCORE unless the student has made a genuine answer attempt in the correct form for this facet. If their message is a question, a tangential comment, or clearly not an answer attempt, engage naturally and keep waiting. If they answer in the wrong form (e.g. give an English meaning when kana reading is required), emit MEANING_DEMONSTRATED if applicable, gently redirect them to the correct form, and wait for a valid attempt — do not grade yet. Never confirm, deny, or hint at whether any sound or word they mentioned overlaps with the correct answer until SCORE is emitted.
        After grading, stop after emitting SCORE, unless the student's message was a question warranting an answer, in which case, engage with it after emitting SCORE.
        \(item.facet == "reading-to-meaning" ? "Sense coaching: after emitting SCORE, if the word has multiple senses and the student's answer covered only some of them, check whether any uncovered senses are worth a brief mention. Mention an uncovered sense only if it is (a) semantically distinct from what the student said — not just a nuance or register variant — and (b) either the mnemonic flags it as something the student is tracking, or it appears to be a commonly-used meaning based on your general knowledge (JMDict senses are roughly frequency-ordered, so earlier senses are more likely to be common). If both conditions hold, add one friendly sentence after SCORE — framed as bonus context, not a correction. If the mnemonic specifically flags a meaning, ask gently whether the student recalls it. Do not coach if the student already covered all the meaningful senses." : "")
        set_mnemonic overwrites — always merge with existing mnemonic before saving.
        \(mnemonicBlock)
        """
        } else {
            // Multiple choice: scoring is app-side. Claude only discusses when student initiates.
            let resultLine = multipleChoiceResult.map { "Multiple choice result: \($0)\n" } ?? ""
            return sharedCore + """

        \(resultLine)The student has already answered — scoring is handled by the app. Do NOT emit SCORE.
        \(item.facet == "kanji-to-reading" ? "MEANING_DEMONSTRATED: output this exact token verbatim on its own line (no punctuation, no surrounding text) ONLY if the student's answer contains an English meaning or uses the word in an English sentence (e.g. 'it means precedent', 'prior example'). Correct kana or kanji, even perfect, do NOT qualify. Only emit if the student demonstrates the meaning of the word being tested — ignore other words they mention. Do not describe the token — just output it.\n" : "")\
        The student may ask follow-up questions or move on without chatting. If they ask, engage naturally.
        set_mnemonic overwrites — always merge with existing mnemonic before saving.
        \(mnemonicBlock)
        """
        }
    }

    func questionRequest(for item: QuizItem) -> String {
        // Free-answer stems are built app-side (freeAnswerStem); only multiple-choice generation goes through the LLM.
        if item.facet == "meaning-reading-to-kanji" {
            let substitutableKanji: [String]
            if let committed = item.committedKanji, !committed.isEmpty {
                substitutableKanji = committed
            } else {
                let correctForm = item.partialKanjiTemplate ?? item.committedWrittenText ?? item.wordText
                substitutableKanji = Self.extractKanji(from: correctForm)
            }
            if substitutableKanji.count == 1 {
                return """
                Think first if helpful, then end with a ```json code block containing exactly a 3-element array of replacement kanji:
                ["replacement_1", "replacement_2", "replacement_3"]
                No other keys or wrapper — just the array.
                """
            } else {
                let examplePairs: String = (0..<4).map { i -> String in
                    let k = substitutableKanji[i % substitutableKanji.count]
                    return "[\"\(k)\", \"replacement_\(i + 1)\"]"
                }.joined(separator: ", ")
                return """
                Fill in the replacement kanji for each pre-filled pair. Think first if helpful, then end with a ```json code block containing exactly a 4-element array:
                [\(examplePairs)]
                No other keys or wrapper — just the array.
                """
            }
        }
        return """
        Generate ONE multiple-choice question for the \(item.facet) facet.
        Think first if helpful, then end with a ```json code block containing:
        {
          "stem": "the question shown to the student (no A/B/C/D options in the stem)",
          "choices": ["correct answer", "distractor 1", "distractor 2", "distractor 3"]
        }
        Always place the correct answer at index 0. The app will shuffle the choices.
        """
    }

    // MARK: - Private: parsing

    private func parseScore(from text: String) -> Double? {
        let pattern = #/SCORE:\s*(\d+(?:\.\d+)?)/#
        if let match = text.firstMatch(of: pattern),
           let score = Double(match.1) {
            return min(max(score, 0), 1)
        }
        return nil
    }

    /// Strip SCORE/NOTES sentinel lines from text shown in the chat UI.
    /// The full response is kept in `conversation` for Claude's context.
    private func strippingMetadata(from text: String) -> String {
        let sentinel = #/\*{0,2}(?:SCORE|NOTES):[^\n]*/#
        return text.replacing(sentinel, with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractNotes(from text: String) -> String {
        let pattern = #/NOTES:[*_\s]*(.+?)(?:\n|$)/#
        if let match = text.firstMatch(of: pattern) {
            return String(match.1).trimmingCharacters(in: .whitespaces)
        }
        // No NOTES: tag found — return empty so the review row stores null in the database.
        return ""
    }

    // MARK: - Private: device name

    private func deviceName() -> String {
#if os(iOS)
        return UIDevice.current.name
#else
        return ProcessInfo.processInfo.hostName
#endif
    }
}
