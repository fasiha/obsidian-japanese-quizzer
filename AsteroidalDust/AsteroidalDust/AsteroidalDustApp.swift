//
//  AsteroidalDustApp.swift
//  AsteroidalDust

import SwiftUI
import GRDB

@main
struct AsteroidalDustApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// Initialises the DB, quiz session, and vocab corpus, then hands off to HomeView.
/// Falls back to an error screen if the DB can't be opened.
struct AppRootView: View {
    @State private var session: QuizSession? = nil
    @State private var corpus = VocabCorpus()
    @State private var db: QuizDB? = nil
    @State private var jmdict: (any DatabaseReader)? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        Group {
            if let session, let db, let jmdict {
                HomeView(session: session, corpus: corpus, db: db, jmdict: jmdict)
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
            let quizDB      = try QuizDB.makeDefault()
            let toolHandler = try ToolHandler.makeDefault()
            // API key: set ANTHROPIC_API_KEY in Xcode scheme for dev.
            // Production: key stored in Keychain via japanquiz://setup deep link (Phase 1 TODO).
            let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
            let model  = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-haiku-4-5-20251001"
            print("[Setup] Using model: \(model)")
            let client = AnthropicClient(apiKey: apiKey, model: model)

            // Publish state so HomeView can render as soon as session is ready,
            // while corpus.load() continues in the background.
            db      = quizDB
            jmdict  = toolHandler.jmdict
            session = QuizSession(client: client, toolHandler: toolHandler, db: quizDB)

            // Load vocab corpus (uses cache; downloads silently if no cache and VOCAB_URL is set).
            await corpus.load(db: quizDB, jmdict: toolHandler.jmdict)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
