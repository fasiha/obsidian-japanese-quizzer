// SettingsView.swift
// User-configurable quiz preferences.

import SwiftUI

struct SettingsView: View {
    @Environment(UserPreferences.self) private var preferences

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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
