//
//  PugApp.swift
//  Pug

import SwiftUI
import GRDB

@main
struct PugApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// Initialises the DB, quiz session, vocab corpus, and grammar manifest, then hands off to HomeView.
/// Falls back to an error screen if the DB can't be opened.
struct AppRootView: View {
    @State private var preferences = UserPreferences()
    @State private var session: QuizSession? = nil
    @State private var grammarSession: GrammarAppSession? = nil
    @State private var grammarStore = GrammarStore()
    @State private var corpus = VocabCorpus()
    @State private var pairCorpus = TransitivePairCorpus()
    @State private var corpusStore = CorpusStore()
    @State private var db: QuizDB? = nil
    @State private var jmdict: (any DatabaseReader)? = nil
    @State private var errorMessage: String? = nil
    @State private var setupID = UUID()          // increment to re-run setup()
    @State private var showSetupAlert = false

    var body: some View {
        Group {
            if let session, let grammarSession, let db, let jmdict {
                let isConfigured = !SetupHandler.resolvedApiKey().isEmpty
                                && VocabSync.resolvedURL() != nil
                if isConfigured {
                    HomeView(session: session, pairCorpus: pairCorpus,
                             db: db, jmdict: jmdict,
                             grammarSession: grammarSession)
                        .environment(preferences)
                        .environment(corpus)
                        .environment(grammarStore)
                        .environment(corpusStore)
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
            let quizDB      = try QuizDB.makeDefault()
            let toolHandler = try ToolHandler.makeDefault(quizDB: quizDB)
            // API key: Keychain (set via japanquiz://setup deep link) or ANTHROPIC_API_KEY env var.
            let apiKey = SetupHandler.resolvedApiKey()
            let envModel = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"]
            let client = AnthropicClient(apiKey: apiKey, modelProvider: {
                envModel ?? preferences.localModel.rawValue
            })

            // Publish core state so HomeView can render immediately.
            db             = quizDB
            jmdict         = toolHandler.jmdict
            session        = QuizSession(client: client, toolHandler: toolHandler, db: quizDB,
                                         preferences: preferences)
            grammarSession = GrammarAppSession(client: client, db: quizDB, toolHandler: toolHandler,
                                              jmdict: toolHandler.jmdict)

            // Load vocab corpus, pair corpus, grammar manifest, and corpus entries concurrently.
            async let grammarLoad = loadGrammarManifest()
            async let corpusLoad = loadCorpusEntries()
            async let pairLoad: () = pairCorpus.load(db: quizDB, jmdict: toolHandler.jmdict)
            await corpus.load(db: quizDB, jmdict: toolHandler.jmdict)
            await pairLoad
            session!.pairCorpus = pairCorpus
            grammarStore.manifest = await grammarLoad
            corpusStore.entries = await corpusLoad
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Load grammar manifest: try cached first, then attempt a background sync.
    private func loadGrammarManifest() async -> GrammarManifest? {
        // Always load equivalences from cache (may be nil on first launch).
        var manifest = GrammarSync.cached()
        var equivalences = GrammarSync.cachedEquivalences()

        // Attempt a network sync. Failures are non-fatal — cached data is still usable.
        if GrammarSync.resolvedURL() != nil {
            do {
                manifest = try await GrammarSync.sync()
                print("[Setup] grammar manifest synced: \(manifest?.topics.count ?? 0) topic(s)")
            } catch {
                print("[Setup] grammar sync failed (using cache): \(error)")
            }
        }
        if GrammarSync.equivalencesURL() != nil {
            do {
                equivalences = try await GrammarSync.syncEquivalences()
                print("[Setup] grammar equivalences synced: \(equivalences?.count ?? 0) group(s)")
            } catch {
                print("[Setup] grammar equivalences sync failed (using cache): \(error)")
            }
        }

        // Merge description fields from equivalences into manifest.
        if var m = manifest, let eq = equivalences {
            GrammarSync.mergeDescriptions(into: &m, from: eq)
            return m
        }
        return manifest
    }

    /// Load corpus entries: try cached first, then attempt a background sync.
    private func loadCorpusEntries() async -> [CorpusEntry] {
        var entries = CorpusSync.cached()

        if CorpusSync.resolvedURL() != nil {
            do {
                entries = try await CorpusSync.download()
                print("[Setup] corpus synced: \(entries.count) document(s)")
            } catch {
                print("[Setup] corpus sync failed (using cache): \(error)")
            }
        }
        return entries
    }
}
