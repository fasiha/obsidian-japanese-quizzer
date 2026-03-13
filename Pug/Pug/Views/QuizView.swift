// QuizView.swift
// Basic quiz UI: generates questions via Claude, accepts user answers, shows grades.

import SwiftUI
import UIKit

struct QuizView: View {
    @State var session: QuizSession
    @State private var showDebug = false
    @State private var showRescaleSheet = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle, .loadingItems, .generating:
                    loadingView
                case .awaitingTap(let multipleChoice):
                    awaitingTapView(multipleChoice: multipleChoice)
                case .awaitingText(let stem):
                    awaitingTextView(stem: stem)
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
            .navigationTitle("Quiz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Settings") { showSettings = true }
                        if session.canStartNewSession {
                            Button("New Session") { session.refreshSession() }
                        }
                        Button("Debug info") { showDebug = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task {
                switch session.phase {
                case .idle, .noItems: session.start()
                default: break
                }
            }
            .sheet(isPresented: $showDebug) {
                DebugSheet(session: session)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showRescaleSheet) {
                RescaleSheet(currentHalflife: session.gradedHalflife ?? 24) { hours in
                    Task { await session.rescaleCurrentFacet(hours: hours) }
                }
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(session.phase == .generating ? "Generating question…" : session.statusMessage)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Awaiting tap (multiple choice buttons)

    private func awaitingTapView(multipleChoice: QuizSession.MultipleChoiceQuestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Progress + facet badge
                if let item = session.currentItem {
                    HStack {
                        Text(session.progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        facetBadge(item.facet)
                    }
                }

                // Question stem
                SelectableText(multipleChoice.stem)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                // Choice buttons
                let letters = ["A", "B", "C", "D"]
                VStack(spacing: 10) {
                    ForEach(0..<multipleChoice.choices.count, id: \.self) { i in
                        Button {
                            session.tapChoice(i)
                        } label: {
                            HStack(spacing: 12) {
                                Text(letters[i])
                                    .font(.headline)
                                    .frame(width: 28, height: 28)
                                    .background(.tint.opacity(0.15), in: Circle())
                                    .foregroundStyle(.tint)
                                Text(multipleChoice.choices[i])
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Uncertainty row: unlock button first to prevent misclicks,
                // then "No idea" (score 0.0) and "Inkling" (score 0.25).
                HStack(spacing: 8) {
                    Button("Don't know?") { session.uncertaintyUnlocked = !session.uncertaintyUnlocked }
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

                // Skip
                Button("Skip →") { session.nextQuestion() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    // MARK: - Awaiting text (free-answer input)

    private func awaitingTextView(stem: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Progress + facet badge
                if let item = session.currentItem {
                    HStack {
                        Text(session.progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        facetBadge(item.facet)
                    }
                }

                // Question stem
                SelectableText(stem)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                // Answer input
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Your answer…", text: $session.chatInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button {
                        session.submitFreeAnswer()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(session.chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Button("Skip →") { session.nextQuestion() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    // MARK: - Chatting (open conversation per quiz item)

    private var chattingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Progress + facet badge
                if let item = session.currentItem {
                    HStack {
                        Text(session.progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        facetBadge(item.facet)
                    }
                }

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

                // Input
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

                // Advance button: Skip (no grade yet) or Rescale + Next Question (graded)
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
            "No words to quiz",
            systemImage: "books.vertical",
            description: Text("Enroll some words in the vocab browser first.")
        )
    }

    private var finishedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Session complete!")
                .font(.title2.bold())
            Button("Start another session") {
                session.start()
            }
            .buttonStyle(.bordered)
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
            Button("Retry") { session.start() }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Helpers

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

// MARK: - Debug sheet

struct DebugSheet: View {
    let session: QuizSession
    @State private var shareURL: URL? = nil

    var body: some View {
        NavigationStack {
            List {
                Section("Quiz context (\(session.allCandidates.count) words, lowest recall first)") {
                    Text(session.contextText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("Export") {
                    if let url = shareURL {
                        ShareLink(item: url) {
                            Label("Share quiz.sqlite via AirDrop / Files", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Label("Preparing database…", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await session.loadCandidatesIfNeeded()
            shareURL = await session.checkpointAndDBURL()
        }
    }
}

// MARK: - Rescale sheet

let durationFormatter: DateComponentsFormatter = {
    let f = DateComponentsFormatter()
    f.unitsStyle = .full
    f.allowedUnits = [.year, .month, .weekOfMonth, .day, .hour]
    f.maximumUnitCount = 2
    return f
}()

func formatDuration(_ hours: Double) -> String {
    durationFormatter.string(from: hours * 3600) ?? "—"
}

struct RescaleSheet: View {
    let currentHalflife: Double
    let onSet: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var targetHours: Double

    init(currentHalflife: Double, onSet: @escaping (Double) -> Void) {
        self.currentHalflife = currentHalflife
        self.onSet = onSet
        self._targetHours = State(initialValue: currentHalflife)
    }

    private var scaleBinding: Binding<Double> {
        Binding(
            get: { targetHours / currentHalflife },
            set: { targetHours = $0 * currentHalflife }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current halflife", value: formatDuration(currentHalflife))
                }
                Section("New halflife") {
                    LabeledContent("Hours") {
                        TextField("Hours", value: $targetHours, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Scale ×") {
                        TextField("Scale", value: scaleBinding, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    LabeledContent("Final halflife", value: formatDuration(targetHours))
                        .font(.headline)
                }
            }
            .navigationTitle("Adjust halflife")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { onSet(targetHours); dismiss() }
                        .disabled(targetHours <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// SelectableText lives in SelectableText.swift
