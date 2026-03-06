// VocabBrowserView.swift
// Filterable list of vocab words with per-word triage actions.
//
// Swipe actions:
//   Leading (right-to-left): "Learn" → enrolled (green)
//   Trailing (left-to-right): "Know it" → known (blue) | "Undo" → pending (orange)
//
// Toolbar:
//   Leading: filter picker (Not yet learned / Learning / Learned / All)
//   Trailing: menu with "Re-download vocab" (debug)

import SwiftUI
import GRDB

struct VocabBrowserView: View {
    let corpus: VocabCorpus
    let db: QuizDB
    let jmdict: any DatabaseReader
    let session: QuizSession

    @State private var filter: EnrollmentStatus? = .pending  // nil = all
    @State private var showDebug = false

    private var filteredItems: [VocabItem] {
        let f = filter
        return corpus.items.filter { f == nil || $0.status == f! }
    }

    var body: some View {
        NavigationStack {
            Group {
                if corpus.isLoading {
                    ProgressView("Loading vocab…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = corpus.syncError {
                    ContentUnavailableView(
                        "Couldn't load vocab",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if corpus.items.isEmpty {
                    ContentUnavailableView(
                        "No vocab loaded",
                        systemImage: "books.vertical",
                        description: Text("Download vocab via the ··· menu or set up the app URL.")
                    )
                } else if filteredItems.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
                } else {
                    wordList
                }
            }
            .navigationTitle("Vocab")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { filterPicker }
                ToolbarItem(placement: .navigationBarTrailing) { debugMenu }
            }
            .sheet(isPresented: $showDebug) { DebugSheet(session: session) }
        }
    }

    // MARK: - Word list

    private var wordList: some View {
        List(filteredItems) { item in
            VocabRowView(item: item)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if item.status != .enrolled {
                        Button {
                            Task { await corpus.setStatus(.enrolled, for: item.id, db: db) }
                        } label: {
                            Label("Learn", systemImage: "plus.circle.fill")
                        }
                        .tint(.green)
                    }
                    if item.status != .known {
                        Button {
                            Task { await corpus.setStatus(.known, for: item.id, db: db) }
                        } label: {
                            Label("Know it", systemImage: "checkmark.circle")
                        }
                        .tint(.blue)
                    }
                    if item.status != .pending {
                        Button {
                            Task { await corpus.setStatus(.pending, for: item.id, db: db) }
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.orange)
                    }
                }
        }
        .listStyle(.plain)
    }

    // MARK: - Toolbar items

    private var filterPicker: some View {
        Menu {
            Button {
                filter = .pending
            } label: {
                Label(filter == .pending ? "Not yet learned ✓" : "Not yet learned", systemImage: "tray.and.arrow.down")
            }
            Button {
                filter = .enrolled
            } label: {
                Label(filter == .enrolled ? "Learning ✓" : "Learning", systemImage: "checkmark.circle.fill")
            }
            Button {
                filter = .known
            } label: {
                Label(filter == .known ? "Learned ✓" : "Learned", systemImage: "eye.slash")
            }
            Divider()
            Button {
                filter = nil
            } label: {
                Label(filter == nil ? "All ✓" : "All", systemImage: "list.bullet")
            }
        } label: {
            HStack(spacing: 3) {
                Text(filterLabel).font(.subheadline)
                Image(systemName: "chevron.down").imageScale(.small)
            }
        }
    }

    private var debugMenu: some View {
        Menu {
            Button("Re-download vocab") {
                Task { await corpus.redownload(db: db, jmdict: jmdict) }
            }
            if let at = corpus.lastSyncedAt {
                let display = at.prefix(10)   // "YYYY-MM-DD" from ISO 8601
                Text("Last synced: \(display)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Debug info") { showDebug = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - Helpers

    private var filterLabel: String {
        switch filter {
        case .pending:  return "Not yet learned"
        case .enrolled: return "Learning"
        case .known:    return "Learned"
        case nil:       return "All"
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .pending:  return "All words triaged!"
        case .enrolled: return "No words in progress"
        case .known:    return "No learned words yet"
        case nil:       return "No vocab loaded"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .pending:  return "checkmark.seal"
        case .enrolled: return "tray"
        case .known:    return "eye.slash"
        case nil:       return "books.vertical"
        }
    }
}

// MARK: - VocabRowView

struct VocabRowView: View {
    let item: VocabItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.wordText)
                    .font(.headline)
                if let kana = item.kanaTexts.first, kana != item.wordText {
                    Text(kana)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            if let meaning = item.meanings.first {
                Text(meaning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !item.sources.isEmpty {
                Text(item.sources.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .enrolled:
            Text("Learning")
                .font(.caption2).fontWeight(.medium)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        case .known:
            Text("Learned")
                .font(.caption2).fontWeight(.medium)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
        case .pending:
            EmptyView()
        }
    }
}
