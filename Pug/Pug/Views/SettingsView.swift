// SettingsView.swift
// User-configurable quiz preferences.

import SwiftUI

struct SettingsView: View {
    var db: QuizDB? = nil
    @Environment(UserPreferences.self) private var preferences
    @State private var shareURL: URL? = nil

    var body: some View {
        @Bindable var prefs = preferences
        NavigationStack {
            Form {
                Section {
                    Picker("Quiz style", selection: $prefs.quizStyle) {
                        ForEach(QuizStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Quiz style")
                } footer: {
                    Text(preferences.quizStyle.description)
                }

                Section {
                    Picker("AI model", selection: $prefs.localModel) {
                        ForEach(LocalModel.allCases) { model in
                            Text(model.label).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("AI model")
                } footer: {
                    Text(preferences.localModel.description)
                }

                if db != nil {
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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            guard let db else { return }
            try? await db.checkpointWAL()
            shareURL = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("quiz.sqlite")
        }
    }
}
