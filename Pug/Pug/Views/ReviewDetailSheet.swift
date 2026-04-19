// ReviewDetailSheet.swift
// Shows a past quiz review with its full question/answer context and opens a Haiku chat
// so the student can discuss the item without navigating away from the history list.
// Chat turns are stored under the same vocabQuiz context as the original quiz session,
// identified by the review's session_id UUID.

import SwiftUI

struct ReviewDetailSheet: View {
    let review: Review
    let client: AnthropicClient
    let db: QuizDB
    @Environment(\.dismiss) private var dismiss

    // Chat state
    @State private var pastTurns: [ChatTurn] = []
    @State private var newMessages: [(isUser: Bool, text: String)] = []
    @State private var conversation: [AnthropicMessage] = []
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String? = nil

    @State private var ebisuRecord: EbisuRecord? = nil
    @State private var reviewCount: Int? = nil
    @State private var showRescaleSheet = false

    private static let isoParser: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var formattedTimestamp: String {
        guard let date = Self.isoParser.date(from: review.timestamp) else { return review.timestamp }
        return Self.localFormatter.string(from: date)
    }

    /// The context tag for this quiz session's chat turns, or nil for pre-UUID legacy reviews.
    private var chatContext: ChatContext? {
        guard let sessionId = review.sessionId else { return nil }
        return .vocabQuiz(wordId: review.wordId, facet: review.quizType, sessionId: sessionId)
    }

    private var systemPrompt: String {
        let notesBlock = review.notes.map { "Quiz context:\n\($0)" } ?? "No detailed quiz context recorded."
        return """
        You are a Japanese language tutor. The student is reviewing a past quiz item they want to discuss.

        \(notesBlock)

        Word/topic: \(review.wordText) (\(review.wordId))
        Quiz type: \(review.quizType)
        Score: \(review.score == 1.0 ? "Correct" : review.score == 0.0 ? "Incorrect" : String(format: "%.2f", review.score))

        Help the student understand the correct answer, why the distractors were wrong, and any relevant grammar or vocabulary nuance. Be concise and direct.
        """
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Header: timestamp, type, facet badge
                    HStack {
                        Text(formattedTimestamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(review.quizType.replacingOccurrences(of: "-", with: " "))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }

                    // Score indicator
                    HStack(spacing: 8) {
                        Circle()
                            .fill(scoreColor(review.score))
                            .frame(width: 14, height: 14)
                        Text(scoreLabel(review.score))
                            .font(.headline)
                        Spacer()
                        Text(review.wordText)
                            .font(.title3.bold())
                    }

                    // Notes block (full question + choices)
                    if let notes = review.notes {
                        SelectableText(notes)
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }

                    Divider()

                    // Past turns from the quiz session and any prior review discussions
                    if !pastTurns.isEmpty {
                        ForEach(Array(pastTurns.enumerated()), id: \.offset) { _, turn in
                            ChatBubble(turn: turn)
                        }
                    }

                    // New messages sent in this sheet opening
                    ForEach(Array(newMessages.enumerated()), id: \.offset) { _, msg in
                        HStack(alignment: .top) {
                            if msg.isUser { Spacer(minLength: 40) }
                            SelectableText(msg.text)
                                .padding(10)
                                .background(
                                    msg.isUser
                                        ? Color.accentColor.opacity(0.15)
                                        : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                            if !msg.isUser { Spacer(minLength: 40) }
                        }
                    }

                    if let err = errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    // Input row (only when we have a session to continue)
                    if chatContext != nil {
                        HStack(alignment: .bottom, spacing: 8) {
                            TextField("Ask about this quiz item…", text: $input, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...5)
                                .disabled(isSending)

                            if isSending {
                                ProgressView().controlSize(.small).padding(.bottom, 6)
                            } else {
                                Button { send() } label: {
                                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                                }
                                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                                .padding(.bottom, 2)
                            }
                        }
                    } else {
                        Text("Chat not available for reviews recorded before session tracking.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadPastTurns() }
            .task { await loadEbisuRecord() }
            .sheet(isPresented: $showRescaleSheet) {
                RescaleSheet(currentHalflife: ebisuRecord?.t ?? 24, reviewCount: reviewCount) { hours in
                    Task { await doRescale(hours: hours) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if ebisuRecord != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Adjust…") { showRescaleSheet = true }
                    }
                }
            }
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSending, let ctx = chatContext else { return }
        input = ""
        isSending = true
        errorMessage = nil
        newMessages.append((isUser: true, text: text))
        conversation.append(AnthropicMessage(role: "user", content: [.text(text)]))

        Task {
            do {
                let (reply, updatedConversation, _) = try await client.send(
                    messages: conversation,
                    system: systemPrompt,
                    maxTokens: 1024,
                    chatContext: ctx,
                    templateId: nil
                )
                conversation = updatedConversation
                newMessages.append((isUser: false, text: reply))
            } catch {
                errorMessage = error.localizedDescription
                if newMessages.last?.isUser == true { newMessages.removeLast() }
                if conversation.last?.role == "user" { conversation.removeLast() }
            }
            isSending = false
        }
    }

    private func loadPastTurns() async {
        guard let chatDB = client.chatDB, let ctx = chatContext else { return }
        pastTurns = await chatDB.organicTurns(context: ctx.tag)
    }

    private func loadEbisuRecord() async {
        ebisuRecord = try? await db.ebisuRecord(
            wordType: review.wordType, wordId: review.wordId, quizType: review.quizType)
        reviewCount = try? await db.reviewCount(
            wordType: review.wordType, wordId: review.wordId, quizType: review.quizType)
    }

    private func doRescale(hours: Double) async {
        guard hours > 0, let current = ebisuRecord else { return }
        do {
            let newModel = try rescaleHalflife(current.model, targetHalflife: hours)
            let updated = EbisuRecord(
                wordType: current.wordType, wordId: current.wordId, quizType: current.quizType,
                alpha: newModel.alpha, beta: newModel.beta, t: newModel.t,
                lastReview: current.lastReview
            )
            try await db.upsert(record: updated)
            ebisuRecord = updated
        } catch {
            print("[ReviewDetailSheet] doRescale error: \(error)")
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 0.8...: return .green
        case 0.5...: return .orange
        default:     return .red
        }
    }

    private func scoreLabel(_ score: Double) -> String {
        switch score {
        case 0.9...: return "Correct"
        case 0.5...: return "Partial"
        default:     return "Incorrect"
        }
    }
}
