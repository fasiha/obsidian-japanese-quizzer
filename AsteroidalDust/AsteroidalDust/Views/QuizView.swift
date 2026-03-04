// QuizView.swift
// Basic quiz UI: generates questions via Claude, accepts user answers, shows grades.

import SwiftUI

struct QuizView: View {
    @State var session: QuizSession

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle:
                    startButton
                case .loadingItems, .generating:
                    loadingView
                case .awaitingAnswer:
                    answerView
                case .grading:
                    gradingView
                case .showingResult:
                    resultView
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
                if session.isQuizActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Session") { session.refreshSession() }
                    }
                }
            }
        }
    }

    // MARK: - Start

    private var startButton: some View {
        VStack(spacing: 16) {
            Button("Start Quiz") { session.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(session.phase == .loadingItems ? session.statusMessage : "Generating question…")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Awaiting answer

    private var answerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let item = session.currentItem {
                    Text(session.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    facetBadge(item.facet)
                }

                // Question card
                Text(session.currentQuestion)
                    .font(.body)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                // Answer input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your answer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Type your answer…", text: $session.userAnswer, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                        .submitLabel(.done)
                }

                Button("Submit") {
                    session.submitAnswer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.userAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    // MARK: - Grading

    private var gradingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Grading…")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Result

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let item = session.currentItem {
                    Text(session.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    facetBadge(item.facet)
                }

                // Score display
                HStack(spacing: 8) {
                    scoreIndicator(session.currentScore)
                    Text(scoreLabel(session.currentScore))
                        .font(.headline)
                }

                // Grade explanation
                Text(session.gradeExplanation)
                    .font(.body)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                Button(session.currentIndex + 1 < session.items.count ? "Next Question →" : "Finish") {
                    session.nextQuestion()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
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
