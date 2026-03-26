// BrowserToolbarMenu.swift
// Shared ··· toolbar menu used by VocabBrowserView and GrammarBrowserView.

import SwiftUI

struct BrowserToolbarMenu: View {
    @Binding var showSettings: Bool
    let db: QuizDB?                 // nil = no History item
    let client: AnthropicClient
    let lastSyncedAt: String?       // ISO 8601 prefix shown as "Last synced: YYYY-MM-DD"
    let onRedownload: () -> Void

    @State private var showHistory = false

    var body: some View {
        Menu {
            Button("Settings") { showSettings = true }
            if db != nil {
                Button("History") { showHistory = true }
            }
            Divider()
            Button("Re-download") { onRedownload() }
            if let at = lastSyncedAt {
                Text("Last synced: \(at.prefix(10))")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .sheet(isPresented: $showHistory) {
            if let db { HistoryView(db: db, client: client) }
        }
    }
}
