// GrammarQuizView.swift
// Quiz UI for grammar items (tier 1 — always multiple choice).
// Parallel to QuizView for vocabulary; reuses the same visual helpers
// (score badge, chat thread, rescale sheet).

import SwiftUI

struct GrammarQuizView: View {
    @State var session: GrammarAppSession
    let manifest: GrammarManifest
    /// When set, an "×" close button appears in the toolbar and the finished view shows "Done"
    /// instead of "Start another session". Used by the ad-hoc drill sheet in GrammarDetailSheet.
    var onDone: (() -> Void)? = nil
    @State private var showRescaleSheet = false
    @State private var vocabExpanded = false

    var body: some View {
        Group {
            switch session.phase {
            case .idle, .loadingItems, .generating:
                loadingView
            case .awaitingTap(let question):
                awaitingTapView(question: question)
            case .chatting:
                chattingView
            case .noItems:
                noItemsView
            case .finished:
                finishedView
            case .error(let msg):
                errorView(msg)
            }
        }
        .navigationTitle("Grammar Quiz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onDone() } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if session.canStartNewSession && onDone == nil {
                    Button("New Session") { session.refreshSession(manifest: manifest) }
                }
            }
        }
        .onChange(of: session.currentItem?.topicId) { vocabExpanded = false }
        .sheet(isPresented: $showRescaleSheet) {
            RescaleSheet(
                currentHalflife: session.gradedHalflife ?? 24,
                reviewCount: session.gradedReviewCount
            ) { hours in
                Task { await session.rescaleCurrentFacet(hours: hours) }
            }
        }
        .task {
            if case .idle = session.phase { session.start(manifest: manifest) }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(session.phase == .generating ? "Generating question…" : "Loading grammar items…")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Awaiting tap

    private func awaitingTapView(question: GrammarMultipleChoiceQuestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                progressAndFacet

                // Stem (English context for production; Japanese sentence for recognition)
                stemView(question: question)

                // Collapsible vocabulary hints — disabled while fetch is in progress
                assumedVocabDisclosure

                // Choice buttons
                let letters = ["A", "B", "C", "D"]
                VStack(spacing: 10) {
                    ForEach(0..<question.choices.count, id: \.self) { i in
                        Button { session.tapChoice(i) } label: {
                            HStack(spacing: 12) {
                                Text(letters[safe: i] ?? "?")
                                    .font(.headline)
                                    .frame(width: 28, height: 28)
                                    .background(.tint.opacity(0.15), in: Circle())
                                    .foregroundStyle(.tint)
                                Text(question.choiceDisplay(i))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Uncertainty row
                HStack(spacing: 8) {
                    Button("Don't know?") {
                        session.uncertaintyUnlocked = !session.uncertaintyUnlocked
                    }
                    .buttonStyle(.bordered)
                    .tint(session.uncertaintyUnlocked ? .secondary : .orange)

                    Button("No idea") { session.tapUncertain(score: 0.0) }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(!session.uncertaintyUnlocked)

                    Button("Inkling") { session.tapUncertain(score: 0.25) }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(!session.uncertaintyUnlocked)
                }
                .frame(maxWidth: .infinity)

                Button("Skip →") { session.nextQuestion() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    /// Displays the question stem and, for production questions, the gapped sentence below it.
    private func stemView(question: GrammarMultipleChoiceQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SelectableText(question.stem)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10))

            if let item = session.currentItem, item.facet == "production",
               let gapped = question.displayGappedSentence, !gapped.isEmpty {
                SelectableText(gapped)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )
            }
        }
    }

    // MARK: - Assumed vocab disclosure

    private var assumedVocabDisclosure: some View {
        let ready = session.assumedVocab != nil
        let empty = session.assumedVocab?.isEmpty == true
        return DisclosureGroup(isExpanded: $vocabExpanded) {
            if let glosses = session.assumedVocab, !glosses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(glosses, id: \.word) { gloss in
                        HStack(alignment: .top, spacing: 8) {
                            Text(gloss.word)
                                .font(.body)
                            Text(gloss.gloss)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            Text(empty ? "Vocabulary (none)" : "Vocabulary")
                .font(.subheadline)
                .foregroundStyle(ready ? .primary : .tertiary)
        }
        .disabled(!ready || empty)
    }

    // MARK: - Chatting

    private var chattingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                progressAndFacet

                // Chat thread
                ForEach(Array(session.chatMessages.enumerated()), id: \.offset) { _, msg in
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

                // Score badge
                if let score = session.gradedScore {
                    HStack(spacing: 8) {
                        scoreIndicator(score)
                        Text(scoreLabel(score))
                            .font(.headline)
                    }
                    .padding(.top, session.chatMessages.isEmpty ? 40 : 4)
                }

                // Chat input
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        session.gradedScore == nil ? "Answer or ask anything…" : "Ask a follow-up… (optional)",
                        text: $session.chatInput,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(session.isSendingChat)

                    if session.isSendingChat {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.bottom, 6)
                    } else {
                        Button {
                            session.sendChatMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(session.chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.bottom, 2)
                    }
                }

                // Advance buttons
                let isLast = session.currentIndex + 1 >= session.items.count
                let isGraded = session.gradedScore != nil
                if isGraded {
                    HStack {
                        Button("Adjust…") { showRescaleSheet = true }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button(isLast ? "Finish" : "Next Question →") { session.nextQuestion() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("Skip →") { session.nextQuestion() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
    }

    // MARK: - End states

    private var noItemsView: some View {
        ContentUnavailableView(
            "No grammar topics to quiz",
            systemImage: "text.book.closed",
            description: Text("Enroll some grammar topics in the Grammar browser first.")
        )
    }

    private var finishedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Session complete!")
                .font(.title2.bold())
            if let onDone {
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Start another session") { session.start(manifest: manifest) }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { session.start(manifest: manifest) }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Shared helpers

    private var progressAndFacet: some View {
        HStack {
            Text(session.progress)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let item = session.currentItem {
                facetBadge(item.facet)
            }
        }
    }

    private func facetBadge(_ facet: String) -> some View {
        Text(facet)
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

// Reuse the safe subscript already defined in GrammarAppSession via a local extension here.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
