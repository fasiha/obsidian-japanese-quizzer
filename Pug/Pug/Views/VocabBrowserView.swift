// VocabBrowserView.swift
// Filterable list of vocab words with per-word triage actions.
//
// Row tap: opens WordDetailSheet for full detail + actions.
// Swipe actions (shortcuts for common actions without opening the sheet):
//   Not yet learned: "Learn" (green) | "Know it" (blue)
//   Learning:        "Know it" (blue) | "Undo" (orange)
//   Known:           "Undo" (orange)
//
// Toolbar:
//   Leading: filter picker (Not yet learned / Learning / Learned / All)
//   Trailing: ··· menu (Re-download vocab, Debug info)

import SwiftUI
import GRDB

struct VocabBrowserView: View {
    let corpus: VocabCorpus
    let db: QuizDB
    let jmdict: any DatabaseReader
    let session: QuizSession

    @State private var filter: EnrollmentStatus? = .notYetLearned  // nil = all
    @State private var selectedItem: VocabItem? = nil
    @State private var showDebug = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var mnemonicMap: [String: String] = [:]  // wordId -> mnemonic text

    private var filteredItems: [VocabItem] {
        let f = filter
        let statusFiltered = corpus.items.filter { f == nil || $0.status == f! }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return statusFiltered }
        return statusFiltered.filter { item in
            item.writtenTexts.contains { $0.localizedCaseInsensitiveContains(q) }
            || item.kanaTexts.contains { $0.localizedCaseInsensitiveContains(q) }
            || item.meanings.contains { $0.localizedCaseInsensitiveContains(q) }
            || mnemonicMap[item.id]?.localizedCaseInsensitiveContains(q) == true
        }
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
                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
                    }
                } else {
                    wordList
                }
            }
            .navigationTitle("Vocab")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { filterPicker }
                ToolbarItem(placement: .navigationBarTrailing) { debugMenu }
            }
            .searchable(text: $searchText, prompt: "Search kanji, reading, meaning…")
            .sheet(item: $selectedItem) { item in
                WordDetailSheet(item: item, corpus: corpus, db: db, session: session)
            }
            .sheet(isPresented: $showDebug) { DebugSheet(session: session) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task {
                if let rows = try? await db.mnemonics(wordType: "jmdict",
                                                      wordIds: corpus.items.map(\.id)) {
                    mnemonicMap = Dictionary(uniqueKeysWithValues: rows.map { ($0.wordId, $0.mnemonic) })
                }
            }
        }
    }

    // MARK: - Word list

    private var wordList: some View {
        List(filteredItems) { item in
            Button { selectedItem = item } label: {
                VocabRowView(item: item)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                swipeButtons(for: item)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func swipeButtons(for item: VocabItem) -> some View {
        switch item.status {
        case .notYetLearned:
            Button {
                selectedItem = item   // open sheet so user can make kanji choice
            } label: {
                Label("Learn", systemImage: "plus.circle.fill")
            }
            .tint(.green)
            Button {
                Task { await corpus.markKnown(wordId: item.id, db: db) }
            } label: {
                Label("Know it", systemImage: "checkmark.circle")
            }
            .tint(.blue)

        case .learning:
            Button {
                Task { await corpus.markKnown(wordId: item.id, db: db) }
            } label: {
                Label("Know it", systemImage: "checkmark.circle")
            }
            .tint(.blue)
            Button(role: .destructive) {
                Task { await corpus.stopLearning(wordId: item.id, db: db) }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .tint(.orange)

        case .known:
            Button {
                Task { await corpus.undoKnown(wordId: item.id, db: db) }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .tint(.orange)
        }
    }

    // MARK: - Toolbar items

    private var filterPicker: some View {
        Menu {
            Button {
                filter = .notYetLearned
            } label: {
                Label(filter == .notYetLearned ? "Not yet learned ✓" : "Not yet learned",
                      systemImage: "tray.and.arrow.down")
            }
            Button {
                filter = .learning
            } label: {
                Label(filter == .learning ? "Learning ✓" : "Learning",
                      systemImage: "checkmark.circle.fill")
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
            Button("Settings") { showSettings = true }
            Divider()
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
        case .notYetLearned: return "Not yet learned"
        case .learning:      return "Learning"
        case .known:         return "Learned"
        case nil:            return "All"
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .notYetLearned: return "All words triaged!"
        case .learning:      return "No words in progress"
        case .known:         return "No learned words yet"
        case nil:            return "No vocab loaded"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .notYetLearned: return "checkmark.seal"
        case .learning:      return "tray"
        case .known:         return "eye.slash"
        case nil:            return "books.vertical"
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
        .contentShape(Rectangle())  // make entire row tappable
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .learning:
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
        case .notYetLearned:
            EmptyView()
        }
    }
}
