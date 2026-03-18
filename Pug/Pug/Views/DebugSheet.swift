// DebugSheet.swift
// Share button for the quiz SQLite database. Accepts only QuizDB so it can be
// used from any browser view without needing a full QuizSession.

import SwiftUI

struct DebugSheet: View {
    let db: QuizDB
    @State private var shareURL: URL? = nil

    var body: some View {
        NavigationStack {
            List {
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
            try? await db.checkpointWAL()
            shareURL = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("quiz.sqlite")
        }
    }
}
