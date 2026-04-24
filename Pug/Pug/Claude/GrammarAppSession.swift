// GrammarAppSession.swift
// Observable session orchestrator for grammar quizzes.
// Parallel to QuizSession for vocabulary — drives the phase state machine,
// records reviews, and propagates Ebisu updates to equivalence-group siblings.
//
// Tier 1 only (both production and recognition facets): always multiple choice,
// always LLM-generated. No free-answer path at this tier.

import Foundation
import GRDB
#if os(iOS)
import UIKit
#endif

@Observable @MainActor
final class GrammarAppSession {

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case loadingItems
        case generating             // Claude generating the multiple-choice question
        case awaitingTap(GrammarMultipleChoiceQuestion)  // waiting for student to tap a choice
        case chatting               // open conversation after tap
        case noItems
        case finished
        case error(String)
    }

    // MARK: - State

    var phase: Phase = .idle
    var items: [GrammarQuizItem] = []
    var currentIndex: Int = 0
    var chatMessages: [(isUser: Bool, text: String)] = []
    var chatInput: String = ""
    var isSendingChat: Bool = false
    var gradedScore: Double? = nil
    var gradedHalflife: Double? = nil
    var uncertaintyUnlocked: Bool = false
    var preQuizRecall: Double? = nil
    var preQuizHalflife: Double? = nil
    /// Vocabulary glosses for the current question's sentence, resolved after generation.
    /// Nil while the fetch is in progress; empty array if none were found.
    var assumedVocab: [VocabGloss]? = nil

    var currentItem: GrammarQuizItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }
    var progress: String { "\(currentIndex + 1) / \(items.count)" }
    var canStartNewSession: Bool {
        switch phase {
        case .idle, .loadingItems: return false
        default: return true
        }
    }

    // MARK: - Dependencies

    let client: AnthropicClient
    let db: QuizDB
    let toolHandler: ToolHandler?
    let jmdict: (any DatabaseReader)?
    let preferences: UserPreferences
    private var manifest: GrammarManifest?
    private let itemSession: GrammarQuizSession  // single-item LLM helper
    private var conversation: [AnthropicMessage] = []
    private var currentQuestion: GrammarMultipleChoiceQuestion? = nil

    init(client: AnthropicClient, db: QuizDB, toolHandler: ToolHandler? = nil,
         jmdict: (any DatabaseReader)? = nil, preferences: UserPreferences) {
        self.client      = client
        self.db          = db
        self.toolHandler = toolHandler
        self.jmdict      = jmdict
        self.preferences = preferences
        self.itemSession = GrammarQuizSession(client: client, db: db)
        self.itemSession.jmdict = jmdict
    }

    // MARK: - Public API

    /// Load items and start the first question. Call once on appear; call again to restart.
    func start(manifest: GrammarManifest) {
        self.manifest = manifest
        items = []
        currentIndex = 0
        phase = .loadingItems
        Task { await loadItems() }
    }

    func refreshSession(manifest: GrammarManifest) {
        self.manifest = manifest
        items = []
        currentIndex = 0
        conversation = []
        chatMessages = []
        chatInput = ""
        isSendingChat = false
        gradedScore = nil
        gradedHalflife = nil

        uncertaintyUnlocked = false
        phase = .loadingItems
        Task { await loadItems() }
    }

    /// Student tapped a multiple-choice option.
    func tapChoice(_ index: Int) {
        guard case .awaitingTap(let question) = phase, let item = currentItem else { return }
        let isCorrect = index == question.correctIndex
        let score = isCorrect ? 1.0 : 0.0
        let letters = ["A", "B", "C", "D"]
        let chosenLetter = letters[safe: index] ?? "?"
        let correctLetter = letters[safe: question.correctIndex] ?? "?"
        let choiceDisplay = question.choiceDisplay(index)
        let correctDisplay = question.choiceDisplay(question.correctIndex)

        // Build display bubbles — production shows gapped sentence + choices,
        // recognition shows Japanese sentence + choices.
        let choicesText = (0..<question.choices.count)
            .map { "\(letters[safe: $0] ?? "?"))) \(question.choiceDisplay($0))" }
            .joined(separator: "\n\n")
        let stemDisplay = buildStemDisplay(question: question, item: item)
        let questionBubble = "\(stemDisplay)\n\n\(choicesText)"
        var answerBubble = "\(chosenLetter))) \(choiceDisplay)"
        if !isCorrect {
            answerBubble += " ✗\nCorrect: \(correctLetter))) \(correctDisplay)"
        }

        var resultSummary = "Question: \(stemDisplay)\nChoices: \(choicesText)\nStudent chose \(chosenLetter))) \(choiceDisplay) — \(isCorrect ? "Correct ✓" : "Incorrect ✗")"
        if !isCorrect {
            resultSummary += ". Correct answer: \(correctLetter))) \(correctDisplay)"
        }
        if let subUse = question.subUse {
            resultSummary += "\nsub_use: \(subUse)"
        }
        itemSession.multipleChoiceResult = resultSummary

        chatMessages = [
            (isUser: false, text: questionBubble),
            (isUser: true, text: answerBubble)
        ]
        gradedScore = score
        phase = .chatting

        Task {
            try? await recordReview(item: item, score: score, notes: resultSummary)
        }
    }

    /// Student admitted uncertainty instead of tapping a choice.
    /// score: 0.0 = "No idea", 0.25 = "Inkling"
    func tapUncertain(score: Double) {
        guard case .awaitingTap(let question) = phase, let item = currentItem else { return }
        var noteText = score <= 0.05 ? "uncertainty: no idea" : "uncertainty: inkling"
        if let subUse = question.subUse {
            noteText += "\nsub_use: \(subUse)"
        }
        let letters = ["A", "B", "C", "D"]
        let choicesText = (0..<question.choices.count)
            .map { "\(letters[safe: $0] ?? "?"))) \(question.choiceDisplay($0))" }
            .joined(separator: "\n\n")
        let stemDisplay = buildStemDisplay(question: question, item: item)

        // Use the actual message sent to Claude as the user bubble so the student can see that
        // something is in flight (especially for "Inkling", where the spinner may not be obvious).
        let openingMsg = score <= 0.05
            ? "I had no idea. Please explain this grammar point to me."
            : "I had a vague sense but wasn't sure. Please explain the grammar and what I might have been thinking."
        itemSession.multipleChoiceResult = nil
        chatMessages = [
            (isUser: false, text: "\(stemDisplay)\n\n\(choicesText)"),
            (isUser: true, text: openingMsg)
        ]
        gradedScore = score
        phase = .chatting
        isSendingChat = true

        Task { try? await recordReview(item: item, score: score, notes: noteText) }
        Task { await doChatTurn(openingMsg, item: item) }
    }

    /// True when the student tapped a wrong multiple-choice answer and the tutor chat hasn't started yet.
    var canStartTutorSession: Bool {
        gradedScore == 0.0 && itemSession.multipleChoiceResult != nil && chatMessages.count <= 2 && !isSendingChat
    }

    /// Auto-fires a chat turn asking Claude to explain the wrong answer.
    func startTutorSession() {
        guard canStartTutorSession, let item = currentItem else { return }
        isSendingChat = true
        let msg = "I got this wrong and want to understand why. Please explain what the correct answer means and what I may have been confusing it with."
        chatMessages.append((isUser: true, text: msg))
        Task { await doChatTurn(msg, item: item) }
    }

    func sendChatMessage() {
        let text = chatInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSendingChat, let item = currentItem else { return }
        chatInput = ""
        Task { await doChatTurn(text, item: item) }
    }

    func nextQuestion() {
        currentIndex += 1
        if currentIndex >= items.count {
            phase = .finished
        } else {
            Task { await generateQuestion() }
        }
    }

    /// Remove all not-yet-answered items belonging to the given equivalence group.
    /// Called when the student unenrolls a topic from the detail sheet mid-session.
    /// Items already answered (index < currentIndex) are left in place so the
    /// progress counter stays consistent.
    func evictItems(topicId: String, equivalenceGroupIds: [String]) {
        let evictIds = Set([topicId] + equivalenceGroupIds)
        let splitPoint = min(currentIndex + 1, items.endIndex)
        let future = items[splitPoint...].filter { !evictIds.contains($0.topicId) }
        items = Array(items[..<splitPoint]) + future
        if currentIndex >= items.count { phase = .finished }
    }


    // MARK: - Private: load items

    private func loadItems() async {
        guard let manifest else { phase = .noItems; return }
        do {
            let candidates = try await GrammarQuizContext.build(db: db, manifest: manifest)
            print("[GrammarAppSession] \(candidates.count) candidate(s) after equivalence collapsing")
            if candidates.isEmpty { phase = .noItems; return }

            let pool = Array(candidates.prefix(GrammarQuizContext.selectionPoolSize))
            switch preferences.sessionLength {
            case .short:
                let weakest = pool[0]
                let rest = Array(pool.dropFirst()).shuffled()
                let extras = rest.isEmpty ? 0 : Int.random(in: 2...min(4, rest.count))
                items = (rest.prefix(extras) + [weakest]).shuffled()
            case .long:
                items = Array(pool.prefix(10))
            }
            print("[GrammarAppSession] selected \(items.count) item(s)")

            await generateQuestion()
        } catch {
            print("[GrammarAppSession] loadItems error: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Private: generate question

    private func generateQuestion() async {
        guard let item = currentItem else { phase = .finished; return }

        conversation = []
        chatMessages = []
        chatInput = ""
        isSendingChat = false
        gradedScore = nil
        gradedHalflife = nil

        uncertaintyUnlocked = false
        itemSession.multipleChoiceResult = nil
        currentQuestion = nil

        if case .reviewed(let recall, _, let halflife) = item.status {
            preQuizRecall   = recall
            preQuizHalflife = halflife
        } else {
            preQuizRecall   = nil
            preQuizHalflife = nil
        }

        phase = .generating
        assumedVocab = nil
        print("[GrammarAppSession] generating for \(item.topicId) facet:\(item.facet)")

        do {
            let (_, multipleChoice, _) = try await itemSession.generateQuestionForTesting(item: item)
            guard let mc = multipleChoice else {
                phase = .error("No multiple-choice question returned for \(item.topicId)")
                return
            }
            currentQuestion = mc
            phase = .awaitingTap(mc)
            // Await the vocab-assumed task that generateQuestionForTesting fired in the background.
            assumedVocab = await itemSession.vocabTask?.value ?? []
        } catch {
            print("[GrammarAppSession] generateQuestion error: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Private: chat turn

    private func doChatTurn(_ text: String, item: GrammarQuizItem) async {
        isSendingChat = true
        chatMessages.append((isUser: true, text: text))
        conversation.append(AnthropicMessage(role: "user", content: [.text(text)]))
        do {
            let mnemonicBlock = await fetchMnemonicBlock(for: item)
            let system = itemSession.systemPrompt(
                for: item, isGenerating: false,
                preRecall: preQuizRecall, preHalflife: preQuizHalflife,
                postHalflife: gradedHalflife, mnemonicBlock: mnemonicBlock)
            let tools: [AnthropicTool] = toolHandler != nil ? [.lookupJmdict, .lookupKanjidic, .getMnemonic, .setMnemonic] : []
            // Compute allIds on the main actor before entering the @Sendable closure.
            let allIds = ([item.topicId] + item.equivalenceGroupIds).removingDuplicates()
            let handler = toolHandler.map { th in
                { @Sendable (name: String, input: [String: JSONValue]) async throws -> String in
                    // For grammar mnemonics, operate across all equivalence-group siblings so
                    // a mnemonic saved on one sibling is visible when quizzing on any other.
                    if name == "set_mnemonic",
                       case .string("grammar")? = input["word_type"],
                       case .string(let wid)? = input["word_id"],
                       case .string(let text)? = input["mnemonic"] {
                        // Propagate to every sibling, using the LLM's word_id as the base
                        // but extending to all siblings (matching Ebisu propagation behaviour).
                        let targetIds = allIds.isEmpty ? [wid] : allIds
                        var primaryResult = #"{"ok":true}"#
                        for (index, id) in targetIds.enumerated() {
                            let result = try await th.handle(
                                toolName: "set_mnemonic",
                                input: ["word_type": .string("grammar"),
                                        "word_id": .string(id),
                                        "mnemonic": .string(text)])
                            if index == 0 { primaryResult = result }
                            // Continue propagating to siblings even if one fails.
                        }
                        return primaryResult
                    }
                    if name == "get_mnemonic",
                       case .string("grammar")? = input["word_type"] {
                        // Return the first sibling mnemonic found.
                        for id in allIds {
                            let result = try await th.handle(
                                toolName: "get_mnemonic",
                                input: ["word_type": .string("grammar"), "word_id": .string(id)])
                            if !result.contains("\"mnemonic\":null") && !result.contains("\"error\"") {
                                return result
                            }
                        }
                        return #"{"mnemonic":null}"#
                    }
                    return try await th.handle(toolName: name, input: input)
                }
            }
            let (response, updatedMsgs, _) = try await client.send(
                messages: conversation,
                system: system,
                tools: tools,
                maxTokens: 512,
                toolHandler: handler,
                chatContext: .grammarDetail(topicId: item.topicId),
                templateId: nil
            )
            conversation = updatedMsgs
            if !response.isEmpty {
                chatMessages.append((isUser: false, text: response))
            }
        } catch {
            chatMessages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        isSendingChat = false
    }

    // MARK: - Private: mnemonic helpers

    /// Fetch the grammar mnemonic for the current item's topic.
    private func fetchMnemonicBlock(for item: GrammarQuizItem) async -> String {
        guard let quizDB = toolHandler?.quizDB else { return "" }
        // Search the current topic and all equivalence-group siblings — any sibling may hold
        // the mnemonic (e.g. saved while quizzing on a different source's topic ID).
        let allIds = ([item.topicId] + item.equivalenceGroupIds).removingDuplicates()
        for id in allIds {
            if let m = try? await quizDB.mnemonic(wordType: "grammar", wordId: id) {
                return "Mnemonic on file (use this to help the student; suggest saving a new one via set_mnemonic):\n\(m.mnemonic)"
            }
        }
        return ""
    }

    // MARK: - Private: record review + Ebisu propagation

    private func recordReview(item: GrammarQuizItem, score: Double, notes: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let quizDataJson: String?
        if let idx = item.nextSubUseIndex {
            quizDataJson = "{\"sub_use_index\": \(idx)}"
        } else {
            quizDataJson = nil
        }
        let review = Review(
            reviewer: deviceName(),
            timestamp: now,
            wordType: "grammar",
            wordId: item.topicId,
            wordText: item.titleEn,
            score: score,
            quizType: item.facet,
            notes: notes.isEmpty ? nil : notes,
            quizData: quizDataJson
        )
        try await db.insert(review: review)

        // Update Ebisu model for the primary topic.
        let existing = try await db.ebisuRecord(
            wordType: "grammar", wordId: item.topicId, quizType: item.facet)

        let oldModel: EbisuModel
        let lastReview: String

        if let rec = existing {
            oldModel   = rec.model
            lastReview = rec.lastReview
        } else {
            oldModel   = defaultModel(halflife: 24)
            lastReview = now
        }

        let refDate = parseISO8601(lastReview) ?? .distantPast
        let elapsed = max(Date().timeIntervalSince(refDate) / 3600, 1e-6)
        let newModel = try updateRecall(oldModel, successes: score, total: 1, tnow: elapsed)
        gradedHalflife = newModel.t
        let record = EbisuRecord(
            wordType: "grammar", wordId: item.topicId, quizType: item.facet,
            alpha: newModel.alpha, beta: newModel.beta, t: newModel.t, lastReview: now
        )
        try await db.upsert(record: record)

        // Propagate updated model to equivalence-group siblings.
        let siblings = item.equivalenceGroupIds.filter { $0 != item.topicId }
        try await db.propagateGrammarEbisu(
            from: item.topicId, quizType: item.facet, siblingIds: siblings)
    }

    // MARK: - Private: display helpers

    /// Build the question bubble stem shown to the student, combining the stem with
    /// the gapped sentence for production questions.
    private func buildStemDisplay(question: GrammarMultipleChoiceQuestion,
                                  item: GrammarQuizItem) -> String {
        if item.facet == "production", let gapped = question.displayGappedSentence {
            return "\(question.stem)\n\(gapped)"
        }
        return question.stem
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func deviceName() -> String {
#if os(iOS)
    return UIDevice.current.name
#else
    return ProcessInfo.processInfo.hostName
#endif
}
