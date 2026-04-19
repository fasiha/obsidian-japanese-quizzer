// SettingsView.swift
// User-configurable quiz preferences.

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var db: QuizDB? = nil
    @Environment(UserPreferences.self) private var preferences
    @State private var shareURL: URL? = nil
    @State private var showFolderPicker = false
    @State private var audioFolderURL: URL? = nil

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

                Section {
                    Picker("Session length", selection: $prefs.sessionLength) {
                        ForEach(SessionLength.allCases) { length in
                            Text(length.label).tag(length)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Session length")
                } footer: {
                    Text(preferences.sessionLength.description)
                }

                Section {
                    Picker("Distractor source", selection: $prefs.distractorSource) {
                        ForEach(DistractorSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Reading-to-meaning wrong answers")
                } footer: {
                    Text(preferences.distractorSource.description)
                }

                Section {
                    if let folderURL = audioFolderURL {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folderURL.lastPathComponent)
                                .font(.body)
                            Text(folderURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Button("Change folder…") { showFolderPicker = true }
                        Button("Remove folder", role: .destructive) {
                            @Bindable var prefs = preferences
                            prefs.audioFolderBookmark = nil
                            audioFolderURL = nil
                        }
                    } else {
                        Button("Choose audio folder…") { showFolderPicker = true }
                    }
                } header: {
                    Text("Audio files")
                } footer: {
                    Text("Point Pug at your Obsidian vault (or any folder) to play timed audio clips while reading lyrics. Audio files can also be added directly via the Files app.")
                }
                .fileImporter(
                    isPresented: $showFolderPicker,
                    allowedContentTypes: [.folder]
                ) { result in
                    guard case .success(let url) = result else { return }
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let bookmark = try? url.bookmarkData(options: .minimalBookmark) {
                        @Bindable var prefs = preferences
                        prefs.audioFolderBookmark = bookmark
                        audioFolderURL = url
                    }
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
            if let bookmark = preferences.audioFolderBookmark {
                var stale = false
                audioFolderURL = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                                          relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            guard let db else { return }
            try? await db.checkpointWAL()
            shareURL = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("quiz.sqlite")
        }
    }
}
