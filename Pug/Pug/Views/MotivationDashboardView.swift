// MotivationDashboardView.swift
// Compact analytics strip shown at the top of each browser tab.
// Scrolls away with the list so it never permanently occupies screen space.
//
// Displays six stats in a 3-row × 2-column layout (vocab left, grammar right):
//   Row 1: Lowest predicted recall
//   Row 2: Active quiz answers this week vs last week
//   Row 3: Words/topics newly enrolled this week vs last week
//
// Refreshes on first appear and whenever `refreshID` changes (bumped by the
// parent after a quiz session ends).

import SwiftUI

struct MotivationDashboardView: View {
    let db: QuizDB
    /// Increment this from the parent to trigger a data refresh (e.g. after quiz dismissal).
    let refreshID: Int

    @State private var snapshot: QuizDB.AnalyticsSnapshot? = nil
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.75)
                    Spacer()
                }
                .frame(height: 44)
            } else if let s = snapshot {
                dashboardGrid(s)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .task(id: refreshID) { await load() }
    }

    // MARK: - Grid

    private func dashboardGrid(_ s: QuizDB.AnalyticsSnapshot) -> some View {
        VStack(spacing: 0) {
            // Column headers
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text("Vocab")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("Grammar")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            dashboardRow(
                label: "Weakest recall",
                vocabText: recallText(s.vocabLowestRecall),
                vocabColor: recallColor(s.vocabLowestRecall),
                grammarText: recallText(s.grammarLowestRecall),
                grammarColor: recallColor(s.grammarLowestRecall)
            )

            dashboardRow(
                label: "Quizzes this week",
                vocabText: weekText(thisWeek: s.vocabReviewsThisWeek, lastWeek: s.vocabReviewsLastWeek),
                vocabColor: weekColor(thisWeek: s.vocabReviewsThisWeek, lastWeek: s.vocabReviewsLastWeek),
                grammarText: weekText(thisWeek: s.grammarReviewsThisWeek, lastWeek: s.grammarReviewsLastWeek),
                grammarColor: weekColor(thisWeek: s.grammarReviewsThisWeek, lastWeek: s.grammarReviewsLastWeek)
            )

            dashboardRow(
                label: "Learned this week",
                vocabText: weekText(thisWeek: s.vocabLearnedThisWeek, lastWeek: s.vocabLearnedLastWeek),
                vocabColor: weekColor(thisWeek: s.vocabLearnedThisWeek, lastWeek: s.vocabLearnedLastWeek),
                grammarText: weekText(thisWeek: s.grammarEnrolledThisWeek, lastWeek: s.grammarEnrolledLastWeek),
                grammarColor: weekColor(thisWeek: s.grammarEnrolledThisWeek, lastWeek: s.grammarEnrolledLastWeek)
            )
        }
    }

    private func dashboardRow(
        label: String,
        vocabText: String, vocabColor: Color,
        grammarText: String, grammarColor: Color
    ) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(vocabText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(vocabColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(grammarText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(grammarColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Formatters

    private func recallText(_ recall: Double?) -> String {
        guard let r = recall else { return "—" }
        return "\(Int((r * 100).rounded()))%"
    }

    private func recallColor(_ recall: Double?) -> Color {
        guard let r = recall else { return .secondary }
        if r < 0.05 { return .red }
        if r < 0.25 { return .orange }
        return .green
    }

    /// Format "this week" count with an up/down/equals indicator vs last week.
    /// Example: "12 ↑(8)" or "3 ↓(5)" or "4 =(4)".
    private func weekText(thisWeek: Int, lastWeek: Int) -> String {
        let arrow: String
        if thisWeek > lastWeek      { arrow = "↑" }
        else if thisWeek < lastWeek { arrow = "↓" }
        else                        { arrow = "=" }
        return "\(thisWeek) \(arrow)(\(lastWeek))"
    }

    private func weekColor(thisWeek: Int, lastWeek: Int) -> Color {
        if thisWeek > lastWeek      { return .green }
        // if thisWeek < lastWeek      { return .orange }
        return .primary
    }

    // MARK: - Data loading

    private func load() async {
        isLoading = snapshot == nil   // spinner only on first load; silent refresh afterwards
        do {
            snapshot = try await db.analyticsSnapshot()
        } catch {
            print("[MotivationDashboardView] load failed: \(error)")
        }
        isLoading = false
    }
}
