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
    @State private var setupID = UUID()          // increment to re-run setup()
    @State private var showSetupAlert = false

    var body: some View {
        Group {
            if let session, let db, let jmdict {
                let isConfigured = !SetupHandler.resolvedApiKey().isEmpty
                                && VocabSync.resolvedURL() != nil
                if isConfigured {
                    HomeView(session: session, corpus: corpus, db: db, jmdict: jmdict)
                } else {
                    ContentUnavailableView(
                        "Setup Required",
                        systemImage: "link",
                        description: Text("Ask the app author for a setup link, then tap it to get started.")
                    )
                }
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
        .task(id: setupID) { await setup() }
        .onOpenURL { url in
            if SetupHandler.handle(url: url) {
                showSetupAlert = true
                setupID = UUID()   // re-initialise with the new key/URL
            }
        }
        .alert("Setup Complete", isPresented: $showSetupAlert) {
            Button("OK") { }
        } message: {
            Text("API key and vocab URL saved. Re-initialising…")
        }
    }

    private func setup() async {
        do {
            try QuizDB.copyJMdictIfNeeded()
            try QuizDB.copyKanjidicIfNeeded()
            let quizDB      = try QuizDB.makeDefault()
            let toolHandler = try ToolHandler.makeDefault()
            // API key: Keychain (set via japanquiz://setup deep link) or ANTHROPIC_API_KEY env var.
            let apiKey = SetupHandler.resolvedApiKey()
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
