// HomeView.swift
// Root navigation: Vocab browser tab + Quiz tab.

import SwiftUI
import GRDB

struct HomeView: View {
    let session: QuizSession
    let corpus: VocabCorpus
    let db: QuizDB
    let jmdict: any DatabaseReader

    var body: some View {
        TabView {
            VocabBrowserView(corpus: corpus, db: db, jmdict: jmdict)
                .tabItem { Label("Vocab", systemImage: "books.vertical") }
            QuizView(session: session)
                .tabItem { Label("Quiz", systemImage: "brain.head.profile") }
        }
    }
}
