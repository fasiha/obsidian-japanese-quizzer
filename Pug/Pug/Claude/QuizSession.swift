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

    enum Phase: Equatable {
        case idle
        case loadingItems
        case generating        // Claude generating the initial question
        case chatting          // open conversation: question live, student may answer or ask anything
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
    var gradedScore: Double? = nil     // nil until Claude grades in this item
    var preQuizRecall: Double? = nil   // recall probability at the start of this item (nil for new words)
    var preQuizHalflife: Double? = nil // halflife (hours) at the start of this item (nil for new words)
    var gradedHalflife: Double? = nil  // updated halflife after recordReview; nil until graded

    var currentItem: QuizItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    var progress: String { "\(currentIndex + 1) / \(items.count)" }
    var isQuizActive: Bool {
        switch phase {
        case .generating, .chatting: return true
        default: return false
        }
    }
    var statusMessage: String = "Loading items…"

    // MARK: - Dependencies

    let client: AnthropicClient
    let toolHandler: ToolHandler
    private let db: QuizDB
    private var conversation: [AnthropicMessage] = []
    var allCandidates: [QuizItem] = []   // full enrolled list, for get_vocab_context tool

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

    init(client: AnthropicClient, toolHandler: ToolHandler, db: QuizDB) {
        self.client      = client
        self.toolHandler = toolHandler
        self.db          = db
    }

    // MARK: - Public API

    func start() {
        items = []
        currentIndex = 0
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

    func refreshSession() {
        // Reset UI state synchronously so the view updates immediately.
        items = []
        currentIndex = 0
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
            let (response, _) = try await client.send(
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

    // MARK: - Private: generate question

    private func generateQuestion() async {
        guard let item = currentItem else { phase = .finished; return }
        phase = .generating
        conversation = []
        chatMessages = []
        chatInput = ""
        isSendingChat = false
        gradedScore = nil
        gradedHalflife = nil
        if case .reviewed(let recall, _, let halflife) = item.status {
            preQuizRecall   = recall
            preQuizHalflife = halflife
        } else {
            preQuizRecall   = nil
            preQuizHalflife = nil
        }

        print("[QuizSession] generating question for \(item.wordText) (id:\(item.wordId)) facet:\(item.facet)")

        let system = systemPrompt(for: item, isGenerating: true)
        let initMsg = AnthropicMessage(role: "user", content: [.text(questionRequest(for: item))])

        do {
            var finalQuestion = ""
            var finalMsgs: [AnthropicMessage] = []

            for attempt in 1...2 {
                let (raw, msgs) = try await client.send(
                    messages: [initMsg],
                    system: system,
                    tools: [.lookupJmdict, .lookupKanjidic],
                    maxTokens: 1024,
                    toolHandler: makeToolHandler()
                )
                finalMsgs = msgs

                // Step 1: strip everything before ---QUIZ--- (preamble leak defence).
                if let extracted = extractQuestion(from: raw) {
                    finalQuestion = extracted
                } else {
                    print("[QuizSession] attempt \(attempt): ---QUIZ--- marker missing, using raw response")
                    finalQuestion = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // Step 2: independent validation pass — fresh context, checks for answer leakage.
                let passed = await validateQuestion(finalQuestion, for: item)
                if passed {
                    print("[QuizSession] attempt \(attempt): validation PASS")
                    break
                }
                if attempt < 2 {
                    print("[QuizSession] attempt \(attempt): validation FAIL, retrying generation")
                } else {
                    print("[QuizSession] attempt \(attempt): validation FAIL on final attempt, showing anyway")
                }
            }

            conversation = finalMsgs
            currentQuestion = finalQuestion
            chatMessages = [(isUser: false, text: finalQuestion)]
            print("[QuizSession] question ready (\(finalQuestion.count) chars):\n\(finalQuestion)")
            phase = .chatting
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
            answerValues = item.writtenTexts.joined(separator: ", ")
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
            let (response, _) = try await client.send(
                messages: [AnthropicMessage(role: "user", content: [.text(prompt)])],
                maxTokens: 10
            )
            let verdict = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return verdict.hasPrefix("PASS")
        } catch {
            print("[QuizSession] validateQuestion error: \(error) — assuming PASS")
            return true  // Don't block the quiz on a network error.
        }
    }

    // MARK: - Private: open chat turn

    private func doChatTurn(_ text: String) async {
        guard let item = currentItem else { isSendingChat = false; return }
        chatMessages.append((isUser: true, text: text))
        conversation.append(AnthropicMessage(role: "user", content: [.text(text)]))
        do {
            let (response, updatedMsgs) = try await client.send(
                messages: conversation,
                system: systemPrompt(for: item),
                tools: [.lookupJmdict, .lookupKanjidic, .getVocabContext],
                maxTokens: 1024,
                toolHandler: makeToolHandler()
            )
            conversation = updatedMsgs
            chatMessages.append((isUser: false, text: response))
            print("[QuizSession] chat response (\(response.count) chars):\n\(response)")
            // Auto-detect grading: first SCORE: in this item records the review.
            if gradedScore == nil, let score = parseScore(from: response) {
                gradedScore = score
                print("[QuizSession] graded: score=\(score)")
                try? await recordReview(item: item, score: score, notes: extractNotes(from: response))
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
        try await db.removeFromSession(wordId: item.wordId)
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

    private func systemPrompt(for item: QuizItem, isGenerating: Bool = false) -> String {
        let facetRule: String
        let wordLine: String
        let englishHint = item.meanings.prefix(3).isEmpty
            ? ""
            : " — English: \(item.meanings.prefix(3).joined(separator: "; "))"
        let readingsHint = item.kanaTexts.isEmpty
            ? "" : " — kana reading(s): \(item.kanaTexts.joined(separator: ", "))"
        let writtenHint = item.writtenTexts.isEmpty
            ? "" : " — written form(s): \(item.writtenTexts.joined(separator: ", "))"

        switch item.facet {
        case "reading-to-meaning":
            facetRule = """
            Show kana ONLY (never kanji). Ask for English meaning.
            ❌ "What does 木陰 (こかげ) mean?"  ✅ "What does こかげ mean?"
            """
            let kana = item.kanaTexts.first ?? "unknown"
            wordLine = """
            Word to quiz: kana reading is \(kana)\(englishHint). \
            Show ONLY \(kana) in your question — never show any written/kanji form. \
            Call lookup_jmdict if you need full dictionary details for distractors or context.
            """
        case "meaning-to-reading":
            facetRule = """
            Show English ONLY (never any Japanese). Ask for kana reading.
            ❌ "What is the reading of 木陰 (shade of a tree)?"  ✅ "Give the reading: shade of a tree; bower."
            """
            wordLine = """
            Word to quiz: JMDict id \(item.wordId)\(englishHint)\(readingsHint). \
            The correct answer MUST be one of the listed kana reading(s). \
            Show ONLY the English meaning in your question stem — never show any Japanese characters. \
            Call lookup_jmdict if you need full dictionary details for distractors or context.
            """
        case "kanji-to-reading":
            facetRule = """
            Show kanji ONLY (never kana). Ask for kana reading.
            ❌ "What is the reading of 木陰 (こかげ)?"  ✅ "What is the reading of 木陰?"
            """
            wordLine = """
            Word to quiz: written form is \(item.wordText)\(readingsHint). \
            Show ONLY \(item.wordText) in your question — never show kana. \
            The correct answer MUST be one of the listed kana reading(s). \
            Call lookup_jmdict if you need full dictionary details for distractors or context.
            """
        case "meaning-reading-to-kanji":
            facetRule = """
            Show English + kana ONLY (never the kanji form). Ask for kanji via A/B/C/D options.
            ❌ "怒鳴る (どなる) — to shout. Which is correct?"
            ✅ "To shout in anger; どなる — which written form?" with options A) 怒鳴る  B) 怒り鳴る  C) 叫鳴る  D) 怒叫る
            """
            let kana = item.kanaTexts.first ?? "unknown"
            wordLine = """
            Word to quiz: JMDict id \(item.wordId)\(englishHint). \
            Kana reading to show in question stem: \(kana). \
            Correct written/kanji form (show ONLY as an answer option, NEVER in the stem)\(writtenHint). \
            Call lookup_jmdict to generate plausible wrong written-form distractors.
            """
        default:
            facetRule = "Follow standard quiz-purity rules for this facet."
            wordLine = "Current word: \(item.wordText)  [JMDict id: \(item.wordId)]"
        }
        let ebisuLine: String
        if let preRecall = preQuizRecall, let preHl = preQuizHalflife {
            if let postHl = gradedHalflife {
                ebisuLine = "Memory state: recall=\(String(format: "%.2f", preRecall)), halflife=\(String(format: "%.0f", preHl))h → halflife updated to \(String(format: "%.0f", postHl))h after this review"
            } else {
                ebisuLine = "Memory state before this review: recall=\(String(format: "%.2f", preRecall)), halflife=\(String(format: "%.0f", preHl))h"
            }
        } else {
            ebisuLine = "Memory state: new word (no review history yet)"
        }
        let universe = vocabUniverse(excluding: item.wordId)
        let sharedCore = """
        You are quizzing a Japanese learner.
        \(wordLine)
        \(ebisuLine)
        Facet: \(item.facet) — \(facetRule)
        CRITICAL: Never leak the answer form into the question stem.
        Pre-question check: before outputting your question, silently verify — is the answer form \
        (kanji / kana / meaning, depending on facet) visible anywhere in the question stem? \
        If yes, rewrite the stem before showing it.
        \(item.hasKanji ? "{kanji-ok} — all four facets apply" : "{no-kanji} — only reading-to-meaning and meaning-to-reading")

        \(universe)
        """
        if isGenerating {
            return sharedCore + """

        Tools available:
        - lookup_jmdict: dictionary-accurate readings and meanings for any word
        """
        } else {
            return sharedCore + """

        This is an open conversation. The student may:
        - Answer the quiz question → grade it and end your response with: SCORE: X.X
        - Ask about the current word → answer, then wait for the quiz answer
        - Ask about unrelated words or topics → answer freely; call get_vocab_context if knowing
          their full learning context would help situate your answer
        - Mix the above → address their question first, then re-ask or wait for the quiz answer

        SCORE rules:
        - Include SCORE: X.X (0.0–1.0) ONLY when grading a clear answer to the quiz question.
        - Do NOT include SCORE: when answering tangent questions or if no answer was given yet.
        - Once SCORE is given, keep chatting if the student has follow-up questions.

        Tools available:
        - lookup_jmdict: dictionary-accurate readings and meanings for any word
        - get_vocab_context: the student's full enrolled word list with recall probabilities
        """
        }
    }

    /// Compact vocab universe for distractor selection: display text + first meaning,
    /// excluding the word currently being quizzed to avoid confusion.
    private func vocabUniverse(excluding wordId: String) -> String {
        let others = allCandidates.filter { $0.wordId != wordId }
        guard !others.isEmpty else { return "" }
        let entries = others.map { item -> String in
            let meaning = item.meanings.first ?? ""
            return meaning.isEmpty ? item.wordText : "\(item.wordText) — \(meaning)"
        }.joined(separator: "; ")
        return "Vocabulary universe (prefer these as distractors — call lookup_jmdict for readings/details): \(entries)"
    }

    private func questionRequest(for item: QuizItem) -> String {
        let mode: String
        switch item.status {
        case .reviewed(_, let isFree, _):
            // meaning-reading-to-kanji is always multiple choice even when isFree — the kanji
            // form must only ever appear as an answer option, never in a free-answer prompt.
            mode = (isFree && item.facet != "meaning-reading-to-kanji") ? "free answer" : "multiple choice (A–D)"
        }
        return """
        Generate ONE \(mode) question for the \(item.facet) facet.
        Output format: write the sentinel `---QUIZ---` on its own line, then immediately the question. \
        Nothing before the sentinel — no reasoning, no preamble. \
        Any notes or working may go after the question if needed.
        """
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

    private func extractNotes(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("SCORE:") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: " ")
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
