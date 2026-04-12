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
    @State private var clipPlayer = ClipPlayer()
    @State private var session: QuizSession? = nil
    @State private var plantingSession: PlantingSession? = nil
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
            if let session, let plantingSession, let grammarSession, let db, let jmdict {
                let isConfigured = !SetupHandler.resolvedApiKey().isEmpty
                                && VocabSync.resolvedURL() != nil
                if isConfigured {
                    HomeView(session: session, plantingSession: plantingSession,
                             pairCorpus: pairCorpus, db: db, jmdict: jmdict,
                             grammarSession: grammarSession,
                             onSync: { await redownloadAll() })
                        .environment(preferences)
                        .environment(corpus)
                        .environment(pairCorpus)
                        .environment(grammarStore)
                        .environment(corpusStore)
                        .environment(clipPlayer)
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
            } else if url.isFileURL {
                copyIncomingFileToDocuments(url)
            }
        }
        .alert("Setup Complete", isPresented: $showSetupAlert) {
            Button("OK") { }
        } message: {
            Text("API key and vocab URL saved. Re-initialising…")
        }
    }

    /// Copies a file delivered via the share sheet into Pug's Documents folder.
    /// iOS grants temporary access to the incoming URL; we must start/stop security-scoped
    /// access and copy the file before the grant expires.
    private func copyIncomingFileToDocuments(_ url: URL) {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else {
            print("[PugApp] Could not resolve Documents folder")
            return
        }
        let destination = docs.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            print("[PugApp] Copied incoming file to Documents: \(url.lastPathComponent)")
        } catch {
            print("[PugApp] Failed to copy incoming file: \(error)")
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
            db              = quizDB
            jmdict          = toolHandler.jmdict
            session         = QuizSession(client: client, toolHandler: toolHandler, db: quizDB,
                                          preferences: preferences)
            plantingSession = PlantingSession(db: quizDB)
            grammarSession  = GrammarAppSession(client: client, db: quizDB, toolHandler: toolHandler,
                                               jmdict: toolHandler.jmdict)

            // Load vocab corpus, pair corpus, grammar manifest, and corpus entries concurrently.
            async let grammarLoad = loadGrammarManifest()
            async let corpusLoad = loadCorpusEntries()
            async let pairLoad: () = pairCorpus.load(db: quizDB, jmdict: toolHandler.jmdict)
            await corpus.load(db: quizDB, jmdict: toolHandler.jmdict)
            await pairLoad
            session!.pairCorpus = pairCorpus
            grammarStore.manifest = await grammarLoad
            let corpusManifest = await corpusLoad
            corpusStore.apply(manifest: corpusManifest)
            corpusStore.baseURL = VocabSync.resolvedURL().map { $0.deletingLastPathComponent() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Launch loaders (cache-first; network only when cache is absent)

    /// Load grammar manifest: use the on-disk cache when present; download only on first launch.
    private func loadGrammarManifest() async -> GrammarManifest? {
        let manifest = GrammarSync.cached()
        let equivalences = GrammarSync.cachedEquivalences()

        // Both cached — skip the network entirely on launch.
        if var m = manifest, let eq = equivalences {
            GrammarSync.mergeDescriptions(into: &m, from: eq)
            return m
        }

        // Cache absent or incomplete — fetch from network.
        return await forceDownloadGrammar()
    }

    /// Load corpus entries: use the on-disk cache when present; download only on first launch.
    private func loadCorpusEntries() async -> CorpusManifest {
        let cached = CorpusSync.cachedManifest()
        guard cached.entries.isEmpty else { return cached }

        if CorpusSync.resolvedURL() != nil {
            do {
                let manifest = try await CorpusSync.downloadManifest()
                print("[Setup] corpus fetched: \(manifest.entries.count) document(s), \(manifest.images?.count ?? 0) image(s)")
                return manifest
            } catch {
                print("[Setup] corpus sync failed (no cache available): \(error)")
            }
        }
        return cached
    }

    // MARK: - Redownload (force-fetches everything, ignoring the on-disk cache)

    /// Force-download all remote data and update every store. Called by the Redownload button.
    func redownloadAll() async {
        guard let db, let jmdict else { return }
        // Run vocab, pairs, grammar, and corpus downloads concurrently.
        async let vocabReload: () = corpus.load(db: db, jmdict: jmdict, download: true)
        async let pairsReload: () = pairCorpus.load(db: db, jmdict: jmdict, download: true)
        async let grammarReload = forceDownloadGrammar()
        async let corpusReload: () = forceDownloadCorpus()
        await vocabReload
        await pairsReload
        if let m = await grammarReload { grammarStore.manifest = m }
        await corpusReload
    }

    /// Force-download grammar manifest and equivalences, merge them, and return the result.
    private func forceDownloadGrammar() async -> GrammarManifest? {
        var manifest = GrammarSync.cached()
        var equivalences = GrammarSync.cachedEquivalences()

        if GrammarSync.resolvedURL() != nil {
            do {
                manifest = try await GrammarSync.sync()
                print("[Sync] grammar manifest fetched: \(manifest?.topics.count ?? 0) topic(s)")
            } catch {
                print("[Sync] grammar sync failed: \(error)")
            }
        }
        if GrammarSync.equivalencesURL() != nil {
            do {
                equivalences = try await GrammarSync.syncEquivalences()
                print("[Sync] grammar equivalences fetched: \(equivalences?.count ?? 0) group(s)")
            } catch {
                print("[Sync] grammar equivalences sync failed: \(error)")
            }
        }

        if var m = manifest, let eq = equivalences {
            GrammarSync.mergeDescriptions(into: &m, from: eq)
            return m
        }
        return manifest
    }

    /// Force-download corpus manifest and apply it to corpusStore.
    private func forceDownloadCorpus() async {
        guard CorpusSync.resolvedURL() != nil else { return }
        do {
            let manifest = try await CorpusSync.downloadManifest()
            corpusStore.apply(manifest: manifest)
            print("[Sync] corpus fetched: \(manifest.entries.count) document(s), \(manifest.images?.count ?? 0) image(s)")
        } catch {
            print("[Sync] corpus sync failed: \(error)")
        }
    }
}
