// HistoryView.swift
// Shows recent quiz reviews as a list. Tapping a row opens ReviewDetailSheet
// so the student can revisit the question and chat with Haiku about it.

import SwiftUI
import GRDB

/// Thin wrapper so Review can be used with sheet(item:).
struct IdentifiableReview: Identifiable {
    let id: Int
    let review: Review
}

struct HistoryView: View {
    let db: QuizDB
    let client: AnthropicClient

    @State private var reviews: [Review] = []
    @State private var isLoading = true
    @State private var selectedReview: IdentifiableReview? = nil

    private static let isoParser: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if reviews.isEmpty {
                    ContentUnavailableView(
                        "No reviews yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Quiz items you complete will appear here.")
                    )
                } else {
                    List(Array(reviews.enumerated()), id: \.offset) { index, review in
                        ReviewRowContainer(
                            review: review,
                            formatter: Self.localFormatter,
                            isoParser: Self.isoParser,
                            chatDB: client.chatDB
                        ) {
                            selectedReview = IdentifiableReview(id: index, review: review)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .sheet(item: $selectedReview) { wrapper in
                ReviewDetailSheet(review: wrapper.review, client: client, db: db)
            }
        }
    }

    private func load() async {
        isLoading = true
        reviews = (try? await db.recentReviews(limit: 200)) ?? []
        isLoading = false
    }
}

// MARK: - Row container (review summary + collapsible chat)

private struct ReviewRowContainer: View {
    let review: Review
    let formatter: DateFormatter
    let isoParser: ISO8601DateFormatter
    let chatDB: ChatDB?
    let onTap: () -> Void

    @State private var isExpanded = false
    @State private var turns: [ChatTurn] = []
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                ReviewRow(review: review, formatter: formatter, isoParser: isoParser)
            }
            .buttonStyle(.plain)

            if let chatDB {
                QuizChatDisclosure(
                    review: review,
                    chatDB: chatDB,
                    isExpanded: $isExpanded,
                    turns: $turns,
                    didLoad: $didLoad
                )
            }
        }
    }
}

// MARK: - Collapsible chat disclosure

private struct QuizChatDisclosure: View {
    let review: Review
    let chatDB: ChatDB
    @Binding var isExpanded: Bool
    @Binding var turns: [ChatTurn]
    @Binding var didLoad: Bool

    /// Exact context tag for this review's chat turns.
    /// Grammar reviews with a session ID use the per-attempt grammarQuiz context.
    /// Legacy grammar reviews without a session ID fall back to the topic-level grammarDetail context.
    /// Vocab reviews without a session ID (pre-UUID legacy) return nil.
    private var contextTag: String? {
        if review.wordType == "grammar" {
            if let sessionId = review.sessionId {
                return ChatContext.grammarQuiz(topicId: review.wordId, facet: review.quizType, sessionId: sessionId).tag
            }
            return ChatContext.grammarDetail(topicId: review.wordId).tag
        }
        guard let sessionId = review.sessionId else { return nil }
        return ChatContext.vocabQuiz(wordId: review.wordId, facet: review.quizType, sessionId: sessionId).tag
    }

    var body: some View {
        Group {
            if contextTag == nil || (didLoad && turns.isEmpty) {
                EmptyView()
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                        ChatBubble(turn: turn)
                    }
                } label: {
                    Label(
                        didLoad ? "\(turns.count) message\(turns.count == 1 ? "" : "s")" : "Chat",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .task {
                    guard !didLoad, let tag = contextTag else { return }
                    turns = await chatDB.organicTurns(context: tag)
                    didLoad = true
                }
            }
        }
    }
}

// MARK: - Chat bubble (shared)

struct ChatBubble: View {
    let turn: ChatTurn

    private var isUser: Bool { turn.role == "user" }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 40) }
            SelectableText(turn.content)
                .font(.callout)
                .padding(10)
                .background(
                    isUser
                        ? Color.accentColor.opacity(0.15)
                        : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Row

private struct ReviewRow: View {
    let review: Review
    let formatter: DateFormatter
    let isoParser: ISO8601DateFormatter

    private var formattedTimestamp: String {
        guard let date = isoParser.date(from: review.timestamp) else { return review.timestamp }
        return formatter.string(from: date)
    }

    /// Short label: for jmdict show the word text; for grammar show the topic ID.
    private var label: String {
        review.wordType == "jmdict" ? review.wordText : review.wordId
    }

    var body: some View {
        HStack(spacing: 12) {
            // Score dot
            Circle()
                .fill(scoreColor(review.score))
                .frame(width: 10, height: 10)

            // Label
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body)
                Text(review.quizType.replacingOccurrences(of: "-", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Timestamp
            Text(formattedTimestamp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 0.8...: return .green
        case 0.5...: return .orange
        default:     return .red
        }
    }
}
