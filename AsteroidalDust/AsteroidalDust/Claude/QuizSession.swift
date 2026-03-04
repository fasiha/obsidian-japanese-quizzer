// QuizSession.swift
// Observable session that orchestrates one quiz item at a time:
//   1. generateQuestion → Claude produces a question (may call lookup_jmdict)
//   2. submitAnswer    → Claude grades it, app records the review
//   3. nextQuestion    → advance or finish

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
        case generating
        case awaitingAnswer
        case grading
        case showingResult
        case noItems
        case finished
        case error(String)
    }

    // MARK: - State

    var phase: Phase = .idle
    var items: [QuizItem] = []
    var currentIndex: Int = 0
    var currentQuestion: String = ""
    var gradeExplanation: String = ""
    var currentScore: Double = 0
    var userAnswer: String = ""

    var currentItem: QuizItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    var progress: String { "\(currentIndex + 1) / \(items.count)" }
    var isQuizActive: Bool {
        switch phase {
        case .awaitingAnswer, .grading, .showingResult, .generating: return true
        default: return false
        }
    }
    var statusMessage: String = "Loading items…"

    // MARK: - Dependencies

    private let client: AnthropicClient
    private let toolHandler: ToolHandler
    private let db: QuizDB
    private var conversation: [AnthropicMessage] = []

    init(client: AnthropicClient, toolHandler: ToolHandler, db: QuizDB) {
        self.client      = client
        self.toolHandler = toolHandler
        self.db          = db
    }

    // MARK: - Public API

    func start() {
        phase = .loadingItems
        Task { await loadItems() }
    }

    func submitAnswer() {
        let answer = userAnswer
        userAnswer = ""
        Task { await grade(answer: answer) }
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
        Task { try? await db.clearSession() }
        items = []
        currentIndex = 0
        conversation = []
        currentQuestion = ""
        gradeExplanation = ""
        userAnswer = ""
        start()
    }

    // MARK: - Private: load items

    private func loadItems() async {
        print("[QuizSession] loadItems: building quiz context")
        do {
            statusMessage = "Loading items…"
            let candidates = try await QuizContext.build(db: db, jmdict: toolHandler.jmdict)
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

        print("[QuizSession] generating question for \(item.wordText) (id:\(item.wordId)) facet:\(item.facet)")

        let system = systemPrompt(for: item)
        let initMsg = AnthropicMessage(role: "user", content: [.text(questionRequest(for: item))])

        do {
            let (question, msgs) = try await client.send(
                messages: [initMsg],
                system: system,
                tools: [.lookupJmdict],
                maxTokens: 1024,
                toolHandler: makeToolHandler()
            )
            conversation = msgs
            currentQuestion = question
            print("[QuizSession] question generated (\(question.count) chars), awaiting answer")
            phase = .awaitingAnswer
        } catch {
            print("[QuizSession] generateQuestion error: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Private: grade answer

    private func grade(answer: String) async {
        guard let item = currentItem else { return }
        phase = .grading

        print("[QuizSession] grading answer for \(item.wordText) facet:\(item.facet), answer='\(answer)'")

        var msgs = conversation
        msgs.append(AnthropicMessage(role: "user", content: [.text(gradeRequest(answer: answer, item: item))]))

        do {
            let (response, _) = try await client.send(
                messages: msgs,
                system: systemPrompt(for: item),
                // No tools needed for grading — Claude already has JMdict info from generation turn.
                maxTokens: 512
            )
            let score = parseScore(from: response)
            currentScore = score
            gradeExplanation = response
            print("[QuizSession] score=\(score) explanation='\(response.prefix(100))'")
            try await recordReview(item: item, score: score, notes: extractNotes(from: response))
            phase = .showingResult
        } catch {
            print("[QuizSession] grade error: \(error)")
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Private: record review

    private func recordReview(item: QuizItem, score: Double, notes: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        var review = Review(
            reviewer: deviceName(),
            timestamp: now,
            wordType: item.wordType,
            wordId: item.wordId,
            wordText: item.wordText,
            score: score,
            quizType: item.facet,
            notes: notes.isEmpty ? nil : notes
        )
        try await db.insert(review: &review)

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

        let elapsed = max(
            (ISO8601DateFormatter().date(from: lastReview).map { Date().timeIntervalSince($0) } ?? 0) / 3600,
            1e-6
        )
        let newModel = try updateRecall(oldModel, successes: score, total: 1, tnow: elapsed)
        let record = EbisuRecord(
            wordType: item.wordType, wordId: item.wordId, quizType: item.facet,
            alpha: newModel.alpha, beta: newModel.beta, t: newModel.t,
            lastReview: now
        )
        try await db.upsert(record: record)

        // Log model event.
        let now2 = ISO8601DateFormatter().string(from: Date())
        var event = ModelEvent(
            timestamp: now2, wordType: item.wordType, wordId: item.wordId,
            quizType: item.facet, event: "reviewed,\(String(format: "%.2f", score))"
        )
        try await db.log(event: &event)
        try await db.removeFromSession(wordId: item.wordId)
    }

    // MARK: - Private: tool handler

    private func makeToolHandler() -> AnthropicClient.ToolHandler {
        let th = toolHandler
        return { name, input in
            try await th.handle(toolName: name, input: input)
        }
    }

    // MARK: - Private: prompt helpers

    private func systemPrompt(for item: QuizItem) -> String {
        let facetRule: String
        switch item.facet {
        case "reading-to-meaning":
            facetRule = "Show kana ONLY (never kanji). Ask for English meaning."
        case "meaning-to-reading":
            facetRule = "Show English ONLY (never Japanese). Ask for kana reading."
        case "kanji-to-reading":
            facetRule = "Show kanji ONLY (never kana). Ask for kana reading."
        case "meaning-reading-to-kanji":
            facetRule = "Show English + kana ONLY. Ask for kanji form via A/B/C/D options."
        default:
            facetRule = "Follow standard quiz-purity rules for this facet."
        }
        return """
        Current word: \(item.wordText)  [JMDict id: \(item.wordId)]
        Facet to quiz: \(item.facet) — \(facetRule)
        CRITICAL: Never leak the answer form into the question stem.
        \(item.hasKanji ? "{kanji-ok} — all four facets apply" : "{no-kanji} — only reading-to-meaning and meaning-to-reading")

        You may call lookup_jmdict to get accurate dictionary info.
        """
    }

    private func questionRequest(for item: QuizItem) -> String {
        let mode: String
        switch item.status {
        case .reviewed(_, let isFree):
            mode = isFree ? "free answer" : "multiple choice (A–D)"
        case .newFacet:
            mode = "multiple choice (A–D)"
        case .newWord:
            return """
            This is a new word for me: \(item.wordText) (id: \(item.wordId)).
            Please introduce it: give the reading, meaning, any memorable connections,
            and then ask me to confirm whether it's completely new or faintly familiar,
            so you know what halflife to use. Don't quiz yet — just introduce.
            """
        }
        return "Generate ONE \(mode) question for the \(item.facet) facet. Show only the question — no preamble."
    }

    private func gradeRequest(answer: String, item: QuizItem) -> String {
        """
        My answer: \(answer)

        Grade this answer for the \(item.facet) facet of \(item.wordText).
        Briefly explain what was right or wrong (1–2 sentences).
        End your response with exactly: SCORE: X.X  (where X.X is 0.0 to 1.0)
        """
    }

    // MARK: - Private: parsing

    private func parseScore(from text: String) -> Double {
        let pattern = #/SCORE:\s*([\d.]+)/#
        if let match = text.firstMatch(of: pattern),
           let score = Double(match.1) {
            return min(max(score, 0), 1)
        }
        return 0.5   // neutral fallback
    }

    private func extractNotes(from text: String) -> String {
        // Remove the SCORE line; use the remaining explanation as notes.
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
