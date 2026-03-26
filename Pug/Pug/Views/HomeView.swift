// HomeView.swift
// Root navigation: Vocab tab | Grammar tab | Reader tab.
// Vocab quiz is launched from the Vocab browser toolbar; grammar quiz from the Grammar browser toolbar.
// History is accessible via the ··· menu in either browser toolbar.

import SwiftUI
import GRDB

struct HomeView: View {
    let session: QuizSession
    let corpus: VocabCorpus
    let pairCorpus: TransitivePairCorpus
    let db: QuizDB
    let jmdict: any DatabaseReader
    let grammarSession: GrammarAppSession
    let grammarManifest: GrammarManifest?
    @Binding var corpusEntries: [CorpusEntry]  // document corpus for the Reader tab

    var body: some View {
        TabView {
            VocabBrowserView(corpus: corpus, pairCorpus: pairCorpus, db: db, jmdict: jmdict, session: session,
                             corpusEntries: corpusEntries, grammarManifest: grammarManifest)
                .tabItem { Label("Vocab", systemImage: "books.vertical") }

            if let manifest = grammarManifest {
                GrammarBrowserView(
                    manifest: manifest,
                    db: db,
                    grammarSession: grammarSession,
                    client: session.client,
                    toolHandler: session.toolHandler,
                    corpusEntries: corpusEntries,
                    corpus: corpus,
                    jmdict: jmdict
                )
                .tabItem { Label("Grammar", systemImage: "text.book.closed") }
            } else {
                ContentUnavailableView(
                    "Grammar not loaded",
                    systemImage: "text.book.closed",
                    description: Text("Grammar data is still syncing.")
                )
                .tabItem { Label("Grammar", systemImage: "text.book.closed") }
            }

            DocumentBrowserView(
                entries: corpusEntries,
                corpus: corpus,
                grammarManifest: grammarManifest,
                db: db,
                jmdict: jmdict,
                client: session.client,
                toolHandler: session.toolHandler
            ) {
                corpusEntries = try await CorpusSync.download()
            }
            .tabItem { Label("Reader", systemImage: "book.pages") }
        }
    }
}
