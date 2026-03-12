// QuizSession.swift
// Observable session that orchestrates one quiz item at a time.
// The conversation is open: the student can answer, ask tangent questions about
// the current word, or ask about completely different words. Claude grades when
// it detects a clear answer (SCORE: X.X) and can call get_vocab_context to
// situate tangent answers in what the student is learning.

import Foundation
#if os(iOS)
import UIKit
#endif

@Observable @MainActor
final class QuizSession {

    // MARK: - Phase

    struct MCQQuestion: Equatable {
        let stem: String          // question text shown to student, no A/B/C/D
        let choices: [String]     // exactly 4 bare strings
        let correctIndex: Int     // 0–3
    }

    enum Phase: Equatable {
        case idle
        case loadingItems
        case generating              // Claude generating MCQ (free-answer skips this)
        case awaitingTap(MCQQuestion) // MCQ rendered as buttons; waiting for student tap
        case awaitingText(String)    // free-answer: app-built stem, waiting for typed input
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
    var gradedScore: Double? = nil          // nil until graded (app-side for MCQ, Claude for free-answer)
    var mcqResult: String? = nil           // MCQ-only: human-readable result injected into system prompt
    var meaningBonusApplied: Bool = false  // true once MEANING_DEMONSTRATED passive update has run
    var preQuizRecall: Double? = nil   // recall probability at the start of this item (nil for new words)
    var preQuizHalflife: Double? = nil // halflife (hours) at the start of this item (nil for new words)
    var gradedHalflife: Double? = nil  // updated halflife after recordReview; nil until graded

    var currentItem: QuizItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    var progress: String { "\(currentIndex + 1) / \(items.count)" }
    var isQuizActive: Bool {
        switch phase {
        case .generating, .awaitingTap, .awaitingText, .chatting: return true
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
    /// Validation is currently broken for all facet types (see TODO-validator-bugfix.md)
    /// and the cost of false-fail retries outweighs any benefit until the validator is reworked.
    static let skipValidation = true

    // MARK: - Dependencies

    let client: AnthropicClient
    let toolHandler: ToolHandler
    let preferences: UserPreferences
    private let db: QuizDB
    private var conversation: [AnthropicMessage] = []
    var allCandidates: [QuizItem] = []   // full enrolled list, for get_vocab_context tool

    // Prefetched next question: kicked off as soon as the current item is graded.
    private var prefetched: (index: Int, question: String, mcq: MCQQuestion?,
                              conversation: [AnthropicMessage],
                              preRecall: Double?, preHalflife: Double?)? = nil
    // In-flight prefetch task, so generateQuestion() can await it instead of restarting.
    private var prefetchTask: Task<Void, Never>? = nil

    /// Human-readable ranked context (same format sent to LLM), for debug display.
    var contextText: String {
        guard !allCandidates.isEmpty else { return "No candidates loaded." }
        return allCandidates.map { QuizContext.contextLine(for: $0) }.joined(separator: "\n")
    }

    /// Populate allCandidates without starting a quiz (e.g. for the debug sheet).
    func loadCandidatesIfNeeded() async {
        guard allCandidates.isEmpty else { return }
        guard let candidates = try? await QuizContext.build(db: db, jmdict: toolHandler.jmdict) else { return }
        allCandidates = candidates
    }

    /// Checkpoint the WAL and return the quiz DB file URL for sharing.
    func checkpointAndDBURL() async -> URL? {
        try? await db.checkpointWAL()
        return try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("quiz.sqlite")
    }

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

    /// Called when the student taps one of the MCQ buttons.
    func tapChoice(_ index: Int) {
        guard case .awaitingTap(let mcq) = phase, let item = currentItem else { return }
        let isCorrect = index == mcq.correctIndex
        let score = isCorrect ? 1.0 : 0.0
        let letters = ["A", "B", "C", "D"]
        let chosenLetter = letters[index]
        let correctLetter = letters[mcq.correctIndex]

        // Build the chat display: show question then student's selection
        let choicesText = mcq.choices.enumerated().map { "\(letters[$0])) \($1)" }.joined(separator: "\n")
        let questionBubble = "\(mcq.stem)\n\n\(choicesText)"
        let resultBubble = "\(chosenLetter)) \(mcq.choices[index])"
        chatMessages = [
            (isUser: false, text: questionBubble),
            (isUser: true, text: resultBubble)
        ]

        gradedScore = score
        // Store full MCQ context for system prompt (student may ask about any of the choices)
        var resultSummary = "Question: \(mcq.stem)\nChoices: \(choicesText)\nStudent chose \(chosenLetter)) \(mcq.choices[index]) — \(isCorrect ? "Correct ✓" : "Incorrect ✗")"
        if !isCorrect {
            resultSummary += ". Correct answer: \(correctLetter)) \(mcq.choices[mcq.correctIndex])"
        }
        mcqResult = resultSummary
        phase = .chatting

        Task {
            try? await recordReview(item: item, score: score,
                                    notes: "MCQ: chose \(chosenLetter) (\(isCorrect ? "correct" : "incorrect"))")
            // Prefetch next question now that grading is done
            let nextIndex = currentIndex + 1
            if nextIndex < items.count {
                let nextItem = items[nextIndex]
                prefetchTask = Task { await prefetchQuestion(for: nextIndex, item: nextItem) }
            }
        }
    }

    // TODO: near-duplicate of WordDetailSheet.doRescale — consider extracting to QuizDB
    func rescaleCurrentFacet(hours: Double) async {
        guard let item = currentItem, hours > 0 else { return }
        do {
            guard let rec = try await db.ebisuRecord(
                wordType: item.wordType, wordId: item.wordId, quizType: item.facet) else { return }
            let scale = hours / rec.t
            let newModel = try rescaleHalflife(rec.model, scale: scale)
            gradedHalflife = newModel.t
            let updated = EbisuRecord(
                wordType: item.wordType, wordId: item.wordId, quizType: item.facet,
                alpha: newModel.alpha, beta: newModel.beta, t: newModel.t,
                lastReview: rec.lastReview
            )
            try await db.upsert(record: updated)
            let event = ModelEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                wordType: item.wordType, wordId: item.wordId, quizType: item.facet,
                event: "rescaled,\(rec.t),\(newModel.t)"
            )
            try await db.log(event: event)
            print("[QuizSession] rescaled \(item.wordId)/\(item.facet) \(rec.t)h → \(newModel.t)h")
        } catch {
            print("[QuizSession] rescaleCurrentFacet error: \(error)")
        }
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
            let candidates = try await QuizContext.build(db: db, jmdict: toolHandler.jmdict)
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

            // No valid session found — ask LLM to select a fresh set.
            if items.isEmpty {
                statusMessage = "Selecting quiz items…"
                items = await selectItems(candidates: candidates)
                try await db.saveSession(wordIds: items.map(\.wordId))
            }

            if items.isEmpty { phase = .noItems } else { await generateQuestion() }
        } catch {
            print("[QuizSession] loadItems error: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Private: LLM item selection

    private func selectItems(candidates: [QuizItem]) async -> [QuizItem] {
        let contextBlock = candidates.map { QuizContext.contextLine(for: $0) }.joined(separator: "\n")
        let prompt = """
        You are assembling a Japanese vocabulary quiz session. \
        Select 3–5 items from the candidates below.
        Guidelines:
        - Favour items with lower recall scores (more forgotten), but don't pick mechanically — \
        aim for a varied, motivating session.
        - Include at most 1–2 new/teaching items ([new] or →facet@new).
        - Vary the facet types (kanji-to-reading, reading-to-meaning, etc.) across the session.
        - Avoid placing semantically similar words consecutively.

        Candidates (sorted by urgency — lowest recall first; [new] items at the end):
        \(contextBlock)

        Reply with ONLY the selected JMDict IDs, one per line, in quiz order. No commentary.
        """
        print("[QuizSession] selectItems: \(candidates.count) candidates → LLM")
        do {
            let (response, _, meta) = try await client.send(
                messages: [AnthropicMessage(role: "user", content: [.text(prompt)])],
                maxTokens: 100
            )
            print("[QuizSession] selectItems response: '\(response.prefix(200))'")
            let validIds = Set(candidates.map(\.wordId))
            let orderedIds = response
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { validIds.contains($0) }
            let byId = Dictionary(candidates.map { ($0.wordId, $0) }, uniquingKeysWith: { f, _ in f })
            let selected = orderedIds.compactMap { byId[$0] }
            // Log telemetry: which recall-ranks did the LLM pick?
            let ranks = orderedIds.compactMap { id in candidates.firstIndex { $0.wordId == id } }
            let ranksJSON = (try? JSONSerialization.data(withJSONObject: ranks)).flatMap { String(data: $0, encoding: .utf8) }
            let idsJSON = (try? JSONSerialization.data(withJSONObject: orderedIds)).flatMap { String(data: $0, encoding: .utf8) }
            try? await db.log(apiEvent: ApiEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                eventType: "item_selection",
                inputTokens: meta.totalInputTokens, outputTokens: meta.totalOutputTokens,
                model: client.model, selectedIds: idsJSON, selectedRanks: ranksJSON,
                apiTurns: meta.totalTurns,
                firstTurnInputTokens: meta.firstTurnInputTokens,
                candidateCount: candidates.count))
            if selected.count >= 3 {
                print("[QuizSession] selectItems: \(selected.count) item(s) selected by LLM")
                return selected
            }
            print("[QuizSession] selectItems: only \(selected.count) valid ID(s) from LLM, falling back to top-N")
        } catch {
            print("[QuizSession] selectItems error: \(error), falling back to top-N")
        }
        return Array(candidates.prefix(QuizContext.itemsPerQuiz))
    }

    // MARK: - Private: free-answer stem builder

    /// Build the question stem app-side for free-answer facets (no LLM needed).
    private func freeAnswerStem(for item: QuizItem) -> String {
        let kana = item.kanaTexts.first ?? "?"
        let meanings = item.meanings.prefix(3).joined(separator: "; ")
        switch item.facet {
        case "meaning-to-reading":
            return "What is the kana reading for:\n\(meanings.isEmpty ? item.wordText : meanings)"
        case "kanji-to-reading":
            if let template = item.partialKanjiTemplate {
                return "What is the full kana reading for: \(template)"
            }
            return "What is the kana reading for: \(item.wordText)"
        case "reading-to-meaning":
            return "What does \(kana) mean?"
        default:
            return "What is \(item.wordText)?"
        }
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
            gradedScore    = nil
            gradedHalflife = nil
            meaningBonusApplied = false
            preQuizRecall   = pf.preRecall
            preQuizHalflife = pf.preHalflife
            print("[QuizSession] consumed prefetch for index \(currentIndex): \(item.wordText)")
            if let mcq = pf.mcq {
                phase = .awaitingTap(mcq)
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
        gradedScore = nil
        gradedHalflife = nil
        mcqResult = nil
        meaningBonusApplied = false
        if case .reviewed(let recall, _, let halflife) = item.status {
            preQuizRecall   = recall
            preQuizHalflife = halflife
        } else {
            preQuizRecall   = nil
            preQuizHalflife = nil
        }

        // Free-answer: construct stem app-side, no LLM call needed.
        if item.isFreeAnswer {
            let stem = freeAnswerStem(for: item)
            currentQuestion = stem
            print("[QuizSession] free-answer stem (app-side) for \(item.wordText): \(stem)")
            phase = .awaitingText(stem)
            return
        }

        phase = .generating
        print("[QuizSession] generating MCQ for \(item.wordText) (id:\(item.wordId)) facet:\(item.facet)")

        let system = systemPrompt(for: item, isGenerating: true,
                                  preRecall: preQuizRecall, preHalflife: preQuizHalflife)
        let initMsg = AnthropicMessage(role: "user", content: [.text(questionRequest(for: item))])

        do {
            let (finalQuestion, finalMCQ, finalMsgs) = try await runGenerationLoop(
                for: item, system: system, initMsg: initMsg, label: "generate",
                preRecall: preQuizRecall)
            currentQuestion = finalQuestion
            print("[QuizSession] question ready (\(finalQuestion.count) chars):\n\(finalQuestion)")
            if let mcq = finalMCQ {
                conversation = []
                chatMessages = []
                phase = .awaitingTap(mcq)
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

    /// Returns the text after the first `---QUIZ---` sentinel, trimmed.
    /// Returns nil if the sentinel is absent.
    private func extractQuestion(from response: String) -> String? {
        guard let range = response.range(of: "---QUIZ---") else { return nil }
        let after = response[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return after.isEmpty ? nil : after
    }

    /// Second-pass validation: a fresh Claude call (no quiz context) checks whether
    /// the generated question leaks the answer form into the question stem.
    /// Returns true (PASS) if the question is clean or if the check itself errors.
    private func validateQuestion(_ question: String, for item: QuizItem) async -> Bool {
        let answerFormDesc: String
        let answerValues: String
        switch item.facet {
        case "reading-to-meaning":
            answerFormDesc = "English meaning"
            answerValues = item.meanings.prefix(5).joined(separator: "; ")
        case "meaning-to-reading":
            answerFormDesc = "kana reading"
            answerValues = item.kanaTexts.joined(separator: ", ")
        case "kanji-to-reading":
            answerFormDesc = "kana reading"
            answerValues = item.kanaTexts.joined(separator: ", ")
        case "meaning-reading-to-kanji":
            answerFormDesc = "written/kanji form"
            if let template = item.partialKanjiTemplate {
                answerValues = template
            } else {
                answerValues = item.writtenTexts.joined(separator: ", ")
            }
        default:
            return true  // Unknown facet — skip validation.
        }
        guard !answerValues.isEmpty else { return true }

        let prompt = """
        You are a quiz quality checker. A Japanese vocabulary quiz question was generated.
        The answer form that must NOT appear in the question stem: \(answerFormDesc)
        Correct answer value(s): \(answerValues)

        Note: for multiple-choice questions the answer MAY appear in the A/B/C/D options — \
        only the question STEM (the sentence or phrase before the options) must be clean.

        Question to check:
        \(question)

        Reply with exactly one word: PASS if the stem is clean, FAIL if the stem leaks the answer.
        """
        do {
            let (response, _, meta) = try await client.send(
                messages: [AnthropicMessage(role: "user", content: [.text(prompt)])],
                maxTokens: 10
            )
            let verdict = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let passed = verdict.hasPrefix("PASS")
            try? await db.log(apiEvent: ApiEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                eventType: "question_validation",
                wordId: item.wordId, quizType: item.facet,
                inputTokens: meta.totalInputTokens, outputTokens: meta.totalOutputTokens,
                model: client.model, validationResult: passed ? "pass" : "fail"))
            return passed
        } catch {
            print("[QuizSession] validateQuestion error: \(error) — assuming PASS")
            return true  // Don't block the quiz on a network error.
        }
    }

    /// Called when the student submits a free-text answer.
    func submitFreeAnswer() {
        let text = chatInput.trimmingCharacters(in: .whitespaces)
        guard case .awaitingText(let stem) = phase, let item = currentItem, !text.isEmpty else { return }
        chatInput = ""

        chatMessages = [
            (isUser: false, text: stem),
            (isUser: true, text: text)
        ]
        isSendingChat = true
        phase = .chatting

        let openingMsg = "Question you asked me: \(stem)\nMy answer: \(text)\nPlease grade my answer."

        Task { await doOpeningChatTurn(openingMsg, item: item, shouldParseScore: true) }
    }

    // MARK: - Private: shared opening chat turn (no user bubble — context already shown)

    /// Fires the first Claude turn after the student answers (MCQ tap or free-answer submit).
    /// `shouldParseScore`: true for free-answer (Claude grades); false for MCQ (app already scored).
    private func doOpeningChatTurn(_ message: String, item: QuizItem, shouldParseScore: Bool) async {
        conversation = [AnthropicMessage(role: "user", content: [.text(message)])]
        do {
            let mnemonicBlock = await fetchMnemonicBlock(for: item)
            let (response, updatedMsgs, meta) = try await client.send(
                messages: conversation,
                system: systemPrompt(for: item, preRecall: preQuizRecall, preHalflife: preQuizHalflife,
                                     postHalflife: gradedHalflife, mnemonicBlock: mnemonicBlock),
                tools: [.lookupJmdict, .lookupKanjidic, .getVocabContext, .getMnemonic, .setMnemonic],
                maxTokens: 1024,
                toolHandler: makeToolHandler()
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
            let (response, updatedMsgs, meta) = try await client.send(
                messages: conversation,
                system: systemPrompt(for: item, preRecall: preQuizRecall, preHalflife: preQuizHalflife,
                                     postHalflife: gradedHalflife, mnemonicBlock: mnemonicBlock),
                tools: [.lookupJmdict, .lookupKanjidic, .getVocabContext, .getMnemonic, .setMnemonic],
                maxTokens: 1024,
                toolHandler: makeToolHandler()
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
        let review = Review(
            reviewer: deviceName(),
            timestamp: now,
            wordType: item.wordType,
            wordId: item.wordId,
            wordText: item.wordText,
            score: score,
            quizType: item.facet,
            notes: notes.isEmpty ? nil : notes
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

        // Free-answer: stem is app-side — instant, no network call.
        if item.isFreeAnswer {
            guard currentIndex <= index else { return }
            let stem = freeAnswerStem(for: item)
            prefetched = (index: index, question: stem, mcq: nil,
                          conversation: [],
                          preRecall: preRecall, preHalflife: preHalflife)
            print("[QuizSession] prefetch (free-answer, app-side) stored for index \(index): \(item.wordText)")
            return
        }

        let system  = systemPrompt(for: item, isGenerating: true,
                                   preRecall: preRecall, preHalflife: preHalflife)
        let initMsg = AnthropicMessage(role: "user", content: [.text(questionRequest(for: item))])

        print("[QuizSession] prefetch MCQ: starting for index \(index): \(item.wordText) facet:\(item.facet)")
        do {
            let (finalQuestion, finalMCQ, finalMsgs) = try await runGenerationLoop(
                for: item, system: system, initMsg: initMsg, label: "prefetch",
                preRecall: preRecall)
            guard currentIndex <= index else {
                print("[QuizSession] prefetch for index \(index) is stale, discarding")
                return
            }
            prefetched = (index: index, question: finalQuestion, mcq: finalMCQ,
                          conversation: finalMsgs,
                          preRecall: preRecall, preHalflife: preHalflife)
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
    func generateQuestionForTesting(item: QuizItem) async throws -> (question: String, mcq: MCQQuestion?, conversation: [AnthropicMessage]) {
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
            tools: [.lookupJmdict, .lookupKanjidic, .getVocabContext, .getMnemonic, .setMnemonic],
            maxTokens: 1024,
            toolHandler: makeToolHandler()
        )
        return response
    }

    /// Tools to use during question generation, based on facet.
    /// rtm/mtr options are pure English or pure kana — Claude needs no JMDict lookup.
    /// ktr uses kanjidic for alternate readings. mrk may need both for visually similar kanji.
    static func generationTools(for facet: String) -> [AnthropicTool] {
        switch facet {
        case "reading-to-meaning", "meaning-to-reading":
            return []   // distractors are English or kana — Claude knows these without lookup
        case "kanji-to-reading":
            return [.lookupKanjidic]
        default:    // meaning-reading-to-kanji and unknown
            return [.lookupJmdict, .lookupKanjidic]
        }
    }

    func runGenerationLoop(for item: QuizItem, system: String,
                                   initMsg: AnthropicMessage, label: String,
                                   tools: [AnthropicTool]? = nil,
                                   preRecall: Double? = nil)
        async throws -> (question: String, mcq: MCQQuestion?, conversation: [AnthropicMessage])
    {
        let resolvedTools = tools ?? Self.generationTools(for: item.facet)
        var finalQuestion = ""
        var finalMCQ: MCQQuestion? = nil
        var finalMsgs: [AnthropicMessage] = []
        let isPrefetch = label == "prefetch" ? 1 : 0
        let qFormat = item.isFreeAnswer ? "free_answer" : "multiple_choice"
        for attempt in 1...2 {
            let (raw, msgs, meta) = try await client.send(
                messages: [initMsg],
                system: system,
                tools: resolvedTools,
                maxTokens: 1024,
                toolHandler: makeToolHandler()
            )
            finalMsgs = msgs
            let genToolsJSON = meta.toolsCalled.isEmpty ? nil :
                (try? JSONSerialization.data(withJSONObject: meta.toolsCalled)).flatMap { String(data: $0, encoding: .utf8) }
            if !item.isFreeAnswer {
                // MCQ: parse JSON response
                if let mcq = parseMCQJSON(raw) {
                    finalMCQ = mcq
                    let letters = ["A", "B", "C", "D"]
                    let choicesText = mcq.choices.enumerated().map { "\(letters[$0])) \($1)" }.joined(separator: "\n")
                    finalQuestion = "\(mcq.stem)\n\n\(choicesText)"
                } else {
                    print("[QuizSession] \(label) attempt \(attempt): MCQ JSON parse failed, using raw")
                    finalQuestion = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                // Free-answer: extract after ---QUIZ--- sentinel
                if let extracted = extractQuestion(from: raw) {
                    finalQuestion = extracted
                } else {
                    print("[QuizSession] \(label) attempt \(attempt): ---QUIZ--- marker missing, using raw response")
                    finalQuestion = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                }
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
            if Self.skipValidation || !item.isFreeAnswer {
                break  // MCQ: app-side scoring means no leak validation needed
            }
            let passed = await validateQuestion(finalQuestion, for: item)
            if passed {
                print("[QuizSession] \(label) attempt \(attempt): validation PASS")
                break
            }
            if attempt < 2 {
                print("[QuizSession] \(label) attempt \(attempt): validation FAIL, retrying")
            } else {
                print("[QuizSession] \(label) attempt \(attempt): validation FAIL on final attempt, using anyway")
            }
        }
        return (finalQuestion, finalMCQ, finalMsgs)
    }

    private func parseMCQJSON(_ raw: String) -> MCQQuestion? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip optional ```json...``` or ```...``` fence
        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: .newlines)
            text = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stem = obj["stem"] as? String,
              let choices = obj["choices"] as? [String],
              choices.count == 4,
              let correctIndex = obj["correct_index"] as? Int,
              (0..<4).contains(correctIndex)
        else { return nil }
        return MCQQuestion(stem: stem, choices: choices, correctIndex: correctIndex)
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
        let vocabContext = buildVocabContextResult()
        return { name, input in
            if name == "get_vocab_context" { return vocabContext }
            return try await th.handle(toolName: name, input: input)
        }
    }

    private func buildVocabContextResult() -> String {
        guard !allCandidates.isEmpty else { return "No enrolled words found." }
        let lines = allCandidates.map { QuizContext.contextLine(for: $0) }
        return "Enrolled vocabulary (\(allCandidates.count) words, sorted by urgency — lowest recall first):\n"
            + lines.joined(separator: "\n")
    }

    // MARK: - Private: prompt helpers

    func systemPrompt(for item: QuizItem, isGenerating: Bool = false,
                              preRecall: Double? = nil, preHalflife: Double? = nil,
                              postHalflife: Double? = nil, mnemonicBlock: String = "") -> String {
        let facetRule: String
        let wordLine: String
        let englishHint = item.meanings.prefix(3).isEmpty
            ? ""
            : " — English: \(item.meanings.prefix(3).joined(separator: "; "))"
        let writtenHint = item.writtenTexts.isEmpty
            ? "" : " — written: \(item.writtenTexts.joined(separator: ", "))"

        // Full entry data injected into every facet so Claude never needs to look up the target word.
        // Each facet then restricts what may appear in the question *stem* — separate from what Claude knows.
        let allWritten  = item.writtenTexts.isEmpty  ? "none" : item.writtenTexts.joined(separator: ", ")
        let allKana     = item.kanaTexts.isEmpty     ? "none" : item.kanaTexts.joined(separator: ", ")
        let allMeanings = item.meanings.isEmpty      ? "unknown" : item.meanings.joined(separator: "; ")
        let entryRef    = "[Word data: written=\(allWritten) kana=\(allKana) meanings=\(allMeanings)]"

        switch item.facet {
        case "reading-to-meaning":
            let kana = item.kanaTexts.first ?? "unknown"
            if isGenerating {
                facetRule = "Show kana ONLY (never kanji). Ask for English meaning. The student is an English speaker learning Japanese — all A/B/C/D options MUST be in English, never Japanese."
                wordLine = "Word: kana \(kana) \(entryRef). Show ONLY \(kana) — never any kanji in the stem."
            } else {
                facetRule = "Facet tested: reading-to-meaning (student sees kana, answers with English meaning)."
                wordLine = "Word: \(entryRef)"
            }
        case "meaning-to-reading":
            if isGenerating {
                facetRule = "Show English ONLY (never Japanese). Ask for kana reading."
                wordLine = "Word: \(entryRef)\(englishHint). Correct answer must be listed kana. Show ONLY English — never Japanese in the stem."
            } else {
                facetRule = "Facet tested: meaning-to-reading (student sees English, answers with kana reading)."
                wordLine = "Word: \(entryRef)"
            }
        case "kanji-to-reading":
            if let template = item.partialKanjiTemplate,
               let committed = item.committedKanji, !committed.isEmpty {
                let committedList = committed.joined(separator: "、")
                let kana = item.kanaTexts.first ?? "unknown"
                if isGenerating {
                    facetRule = """
                    Show \(template), ask for full reading. Studying: \(committedList).
                    CORRECT ANSWER IS EXACTLY: \(kana). This is non-negotiable — do NOT derive the answer \
                    from kanjidic; use it only to build the 3 wrong options.
                    A/B/C/D: exactly one option must be \(kana) (the correct answer). \
                    The 3 distractors substitute ONLY the committed kanji (\(committedList)) with alternate \
                    kanjidic readings; all other kana in the word stay identical.
                    """
                    wordLine = "Word: display \(template) \(entryRef). Never show full kana reading in the stem."
                } else {
                    facetRule = "Facet tested: kanji-to-reading partial (\(template), studying \(committedList), correct reading: \(kana))."
                    wordLine = "Word: \(entryRef)"
                }
            } else {
                if isGenerating {
                    facetRule = "Show kanji ONLY (never kana). Ask for kana reading."
                    wordLine = "Word: \(item.wordText) \(entryRef). Show ONLY \(item.wordText) — never kana in the stem."
                } else {
                    facetRule = "Facet tested: kanji-to-reading (student sees kanji, answers with kana reading)."
                    wordLine = "Word: \(entryRef)"
                }
            }
        case "meaning-reading-to-kanji":
            let kana = item.kanaTexts.first ?? "unknown"
            if let template = item.partialKanjiTemplate,
               let committed = item.committedKanji, !committed.isEmpty {
                let committedList = committed.joined(separator: "、")
                if isGenerating {
                    facetRule = """
                    Show English + kana ONLY (never kanji). A/B/C/D kanji options.
                    Partial commitment: studying \(committedList). Correct template: \(template).
                    Distractors: swap ONLY committed kanji with visually similar wrong kanji (use lookup_kanjidic). Keep rest identical.
                    """
                    wordLine = "Word: \(entryRef). Stem kana: \(kana). Correct option: \(template) — NEVER in stem."
                } else {
                    facetRule = "Facet tested: meaning-reading-to-kanji partial (studying \(committedList), correct form: \(template))."
                    wordLine = "Word: \(entryRef)"
                }
            } else {
                if isGenerating {
                    facetRule = "Show English + kana ONLY (never kanji). A/B/C/D kanji options."
                    wordLine = "Word: \(entryRef). Stem kana: \(kana). Correct form (option only, NEVER in stem)\(writtenHint)."
                } else {
                    facetRule = "Facet tested: meaning-reading-to-kanji (student sees English + kana, answers with kanji form)."
                    wordLine = "Word: \(entryRef)"
                }
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
                distractorLine = "\nDistractors: write 3 wrong kana readings directly — no lookup needed. Pick readings that sound plausibly similar (shared mora, similar rhythm)."
            default:
                distractorLine = "\nDistractors: use lookup_jmdict to verify — batch all candidates into one call. Prefer confusable items (similar meaning/sound/kanji)."
            }
        }
        let stemLeakGuard = isGenerating ? "\nCRITICAL: Never leak the answer form into the question stem. Silently verify before outputting." : ""
        let sharedCore = """
        You are quizzing a Japanese learner.
        \(wordLine)
        Memory: \(ebisuLine)
        Facet: \(item.facet) — \(facetRule)\(stemLeakGuard)
        \(item.hasKanji ? "{kanji-ok}" : "{no-kanji}")\(distractorLine)
        """
        if isGenerating {
            return sharedCore
        } else if item.isFreeAnswer {
            return sharedCore + """

        Open conversation: student may answer, ask about this/other words, or mix.
        SCORE: X.X (0.0–1.0) — you MUST emit this on the same turn you grade. Always include a grading sentence alongside it; never emit SCORE on a line by itself with no other prose.
        Scoring is Bayesian confidence, not percentage-correct. Ask: "how confident am I that this answer reflects whether the student actually remembers the word?"
        - 1.0: strong evidence they remember — correct or trivially equivalent (extra annotation, minor formatting)
        - 0.8–0.9: good evidence they remember — right answer with a minor slip: for kana, a missing/wrong small kana (ゅ/ょ/っ) or long-vowel marker (ー); for meaning, a paraphrase that captures the core concept
        - 0.5: no evidence either way — ambiguous, can't tell if they know it (do NOT use 0.5 as "half credit")
        - 0.1–0.3: good evidence they don't remember — wrong but in the right domain
        - 0.0: strong evidence they don't remember — completely wrong word or meaning
        NOTES: one sentence on same message as SCORE. Spell out words, never reference A/B/C/D letters.
        After grading, stop — do not ask follow-up questions. The student will ask if they want to discuss further.
        set_mnemonic overwrites — always merge with existing mnemonic before saving.
        \(mnemonicBlock)
        """
        } else {
            // MCQ: scoring is app-side. Claude only discusses when student initiates.
            let resultLine = mcqResult.map { "MCQ result: \($0)\n" } ?? ""
            return sharedCore + """

        \(resultLine)The student has already answered — scoring is handled by the app. Do NOT emit SCORE.
        \(item.facet == "kanji-to-reading" ? "MEANING_DEMONSTRATED: output this exact token verbatim on its own line (no punctuation, no surrounding text) if the student clearly shows meaning knowledge via translation or usage. Not for tangent words. Do not describe the token — just output it.\n" : "")\
        The student may ask follow-up questions or move on without chatting. If they ask, engage naturally.
        set_mnemonic overwrites — always merge with existing mnemonic before saving.
        \(mnemonicBlock)
        """
        }
    }

    func questionRequest(for item: QuizItem) -> String {
        if item.isFreeAnswer {
            return """
            Generate ONE free-answer question for the \(item.facet) facet.
            Output format: optionally reason first, then write the sentinel `---QUIZ---` on its own line, \
            then immediately the question. Nothing after the question — stop as soon as it is complete.
            """
        } else {
            return """
            Generate ONE multiple-choice question for the \(item.facet) facet.
            Return ONLY a JSON object — no commentary, no markdown fences, no ---QUIZ--- sentinel:
            {
              "stem": "the question shown to the student (no A/B/C/D options in the stem)",
              "choices": ["option 0", "option 1", "option 2", "option 3"],
              "correct_index": N
            }
            The correct answer must be at position N (0-indexed). Shuffle so correct is not always first.
            """
        }
    }

    // MARK: - Private: parsing

    private func parseScore(from text: String) -> Double? {
        let pattern = #/SCORE:\s*([\d.]+)/#
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
        // Fallback: strip SCORE/NOTES lines and join remaining non-empty lines.
        return text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("SCORE:") && !$0.hasPrefix("NOTES:") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
