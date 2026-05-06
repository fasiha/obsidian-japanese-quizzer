// ProblemReport.swift
// Shared type and views for student-initiated problem reporting across all quiz types.

import SwiftUI

// MARK: - Model

struct ProblemReport {
    let message: String
    let timestamp: Date

    static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm z"
        return f
    }()
}

// MARK: - Banner

/// Shown at the bottom of the screen when the app auto-skips a broken quiz or the student
/// taps "Report problem". Auto-dismisses after 8 seconds. Backed by a Binding so any
/// session type (QuizSession, GrammarAppSession, …) can drive it.
struct ProblemReportBanner: View {
    @Binding var report: ProblemReport?

    var body: some View {
        Group {
            if let r = report {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Something went wrong? Tap Share to report it.")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ShareLink(item: r.message) {
                        Text("Share")
                            .font(.subheadline.bold())
                    }
                    Button {
                        withAnimation { report = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: r.timestamp) {
                    try? await Task.sleep(for: .seconds(8))
                    withAnimation { report = nil }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: report?.timestamp)
    }
}

// MARK: - Button

/// Full-width "Report problem" button. Pass the session's reportProblem() as `action`.
/// Place below "Skip →" in every quiz phase view.
struct ReportProblemButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Label("Report problem", systemImage: "exclamationmark.bubble")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
        .frame(maxWidth: .infinity)
    }
}
