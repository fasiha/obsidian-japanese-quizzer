// BrowserToolbarMenu.swift
// Shared ··· toolbar menu used by VocabBrowserView and GrammarBrowserView.

import SwiftUI

struct BrowserToolbarMenu: View {
    @Binding var showSettings: Bool
    let db: QuizDB?                 // nil = no Debug info item
    let lastSyncedAt: String?       // ISO 8601 prefix shown as "Last synced: YYYY-MM-DD"
    let onRedownload: () -> Void

    @State private var showDebug = false

    var body: some View {
        Menu {
            Button("Settings") { showSettings = true }
            Divider()
            Button("Re-download") { onRedownload() }
            if let at = lastSyncedAt {
                Text("Last synced: \(at.prefix(10))")
            }
            if db != nil {
                Button("Debug info") { showDebug = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .sheet(isPresented: $showDebug) {
            if let db { DebugSheet(db: db) }
        }
    }
}
