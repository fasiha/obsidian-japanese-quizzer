// HomeView.swift
// Root navigation: Vocab tab | Grammar tab | Quiz tab.

import SwiftUI
import GRDB

struct HomeView: View {
    let session: QuizSession
    let corpus: VocabCorpus
    let db: QuizDB
    let jmdict: any DatabaseReader
    let grammarSession: GrammarAppSession
    let grammarManifest: GrammarManifest?

    var body: some View {
        TabView {
            VocabBrowserView(corpus: corpus, db: db, jmdict: jmdict, session: session)
                .tabItem { Label("Vocab", systemImage: "books.vertical") }

            if let manifest = grammarManifest {
                GrammarBrowserView(
                    manifest: manifest,
                    db: db,
                    grammarSession: grammarSession,
                    client: session.client
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

            QuizView(session: session)
                .tabItem { Label("Quiz", systemImage: "brain.head.profile") }
        }
    }
}
