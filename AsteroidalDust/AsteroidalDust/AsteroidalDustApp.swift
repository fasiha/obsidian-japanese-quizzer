//
//  AsteroidalDustApp.swift
//  AsteroidalDust

import SwiftUI

@main
struct AsteroidalDustApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// Initialises the DB and quiz session, then hands off to QuizView.
/// Falls back to an error screen if the DB can't be opened.
struct AppRootView: View {
    @State private var session: QuizSession? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        Group {
            if let session {
                QuizView(session: session)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Startup error")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                ProgressView("Starting up…")
            }
        }
        .task { await setup() }
    }

    private func setup() async {
        do {
            try QuizDB.copyJMdictIfNeeded()
            let db          = try QuizDB.makeDefault()
            let toolHandler = try ToolHandler.makeDefault()
            // API key placeholder — will be set via setup deep link (Phase 1).
            // For dev, set ANTHROPIC_API_KEY in the scheme environment variables.
            let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
            let model  = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-haiku-4-5-20251001"
            print("[Setup] Using model: \(model)")
            let client = AnthropicClient(apiKey: apiKey, model: model)
            session = QuizSession(client: client, toolHandler: toolHandler, db: db)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
