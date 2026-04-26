// PostAnswerChatView.swift
// Shared post-answer chat UI used by both QuizView (vocabulary quiz) and PlantView (planting drills).
//
// Shows:
//   • Progress label + facet badge header
//   • Chat thread: question bubble (left) and answer bubble (right), then any follow-up turns
//   • Score badge with optional "Tutor me" button
//   • Chat input field for optional follow-up questions
//   • "Details…" button (optional) + advance button (Next Question / Continue / Finish)

import SwiftUI

struct PostAnswerChatView: View {
    let messages: [(isUser: Bool, text: String)]
    @Binding var chatInput: String
    let isSending: Bool
    let gradedScore: Double?
    let facet: String
    let progressLabel: String
    let advanceLabel: String
    let onSend: () -> Void
    let onAdvance: () -> Void
    /// Nil = hide "Details…" button.
    let onShowDetails: (() -> Void)?
    /// Nil = hide "Tutor me" button.
    let tutorMeAction: (() -> Void)?

    @FocusState private var isChatFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Progress + facet badge
                HStack {
                    Text(progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    facetBadge(facet)
                }

                // Chat thread
                ForEach(Array(messages.enumerated()), id: \.offset) { _, msg in
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

                // Score badge + optional "Tutor me" button
                if let score = gradedScore {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            scoreIndicator(score)
                            Text(scoreLabel(score))
                                .font(.headline)
                        }
                        if let action = tutorMeAction {
                            Spacer()
                            Button("Tutor me") { action() }
                                .buttonStyle(.bordered)
                                .tint(.blue)
                        }
                    }
                    .padding(.top, messages.isEmpty ? 40 : 4)
                }

                // Chat input
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        gradedScore == nil ? "Answer or ask anything…" : "Ask a follow-up… (optional)",
                        text: $chatInput,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(isSending)
                    .focused($isChatFocused)

                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.bottom, 6)
                    } else {
                        Button {
                            onSend()
                            isChatFocused = false
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.bottom, 2)
                    }
                }

                // Advance row: optional "Details…" on the left, advance button on the right
                HStack {
                    if let details = onShowDetails {
                        Button("Details…") { details() }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                    Button(advanceLabel) { onAdvance() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: onShowDetails == nil ? .infinity : nil)
                }
            }
            .padding()
        }
    }

    // MARK: - Helpers (duplicated from QuizView; keep in sync if the style changes)

    private func facetBadge(_ facet: String) -> some View {
        Text(facet.replacingOccurrences(of: "-", with: " "))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }

    private func scoreIndicator(_ score: Double) -> some View {
        Circle()
            .fill(scoreColor(score))
            .frame(width: 16, height: 16)
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
        case 0.9...: return "Excellent"
        case 0.75...: return "Good"
        case 0.5...: return "Partial"
        default:     return "Incorrect"
        }
    }
}
