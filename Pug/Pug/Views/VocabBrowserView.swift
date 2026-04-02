// VocabBrowserView.swift
// Filterable list of vocab words with per-word triage actions.
//
// Row tap: opens WordDetailSheet for full detail + actions.
// Swipe actions (shortcuts for common actions without opening the sheet):
//   Not yet learned: "Learn word" (green) | "Learn kanji" (purple, only if word has kanji forms)
//   Learning / Known: no swipe — use WordDetailSheet for deliberate changes
//
// Toolbar:
//   Leading: filter picker (Not yet learned / Learning / Learned / All)
//   Trailing: ··· menu (Re-download vocab, Debug info)

import SwiftUI
import GRDB

struct VocabBrowserView: View {
    let pairCorpus: TransitivePairCorpus
    let db: QuizDB
    let jmdict: any DatabaseReader
    let session: QuizSession

    @Environment(VocabCorpus.self) private var corpus
    @Environment(GrammarStore.self) private var grammarStore
    @Environment(CorpusStore.self) private var corpusStore

    @State private var filter: VocabFilter? = .notYetLearning  // nil = all
    @State private var selectedItem: VocabItem? = nil
    @State private var selectedPair: TransitivePairItem? = nil

    @State private var showQuiz = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var mnemonicMap: [String: String] = [:]  // wordId -> mnemonic text
    @State private var collapsedSections: Set<String> = []  // path keys of collapsed nodes

    private var filteredItems: [VocabItem] {
        let f = filter
        let statusFiltered = corpus.items.filter { f == nil || $0.matches(filter: f!) }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return statusFiltered }
        return statusFiltered.filter { item in
            item.writtenTexts.contains { $0.localizedCaseInsensitiveContains(q) }
            || item.kanaTexts.contains { $0.localizedCaseInsensitiveContains(q) }
            || item.senseExtras.flatMap(\.glosses).contains { $0.localizedCaseInsensitiveContains(q) }
            || mnemonicMap[item.id]?.localizedCaseInsensitiveContains(q) == true
        }
    }

    private var filteredPairs: [TransitivePairItem] {
        let f = filter
        let statusFiltered = pairCorpus.items.filter { f == nil || $0.matches(filter: f!) }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return statusFiltered }
        return statusFiltered.filter { item in
            let p = item.pair
            return p.intransitive.kana.localizedCaseInsensitiveContains(q)
                || p.transitive.kana.localizedCaseInsensitiveContains(q)
                || p.intransitive.kanji.contains { $0.localizedCaseInsensitiveContains(q) }
                || p.transitive.kanji.contains { $0.localizedCaseInsensitiveContains(q) }
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
                } else if filteredItems.isEmpty && filteredPairs.isEmpty {
                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
                    }
                } else if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    groupedWordList
                } else {
                    wordList
                }
            }
            .navigationTitle("Vocab")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { filterPicker }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        Button { startQuiz(filter: .all) } label: {
                            Label("Quiz", systemImage: "brain.head.profile")
                        }
                        .contextMenu {
                            Button("Quiz all") { startQuiz(filter: .all) }
                            Button("Quiz vocab only") { startQuiz(filter: .vocabOnly) }
                            Button("Quiz transitive pairs only") { startQuiz(filter: .pairsOnly) }
                        }
                        BrowserToolbarMenu(
                            showSettings: $showSettings,
                            db: db,
                            client: session.client,
                            lastSyncedAt: corpus.lastSyncedAt,
                            onRedownload: { Task { await corpus.redownload(db: db, jmdict: jmdict); await pairCorpus.redownload(db: db, jmdict: jmdict); _ = try? await CorpusSync.download() } }
                        )
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search kanji, reading, meaning…")
            .sheet(item: $selectedItem) { item in
                WordDetailSheet(initialItem: item, db: db,
                                client: session.client, toolHandler: session.toolHandler, jmdict: jmdict)
            }
            .sheet(item: $selectedPair) { pair in
                TransitivePairDetailSheet(initialItem: pair, pairCorpus: pairCorpus, db: db, jmdict: jmdict,
                                          client: session.client, toolHandler: session.toolHandler)
            }

            .sheet(isPresented: $showSettings) { SettingsView(db: db) }
            .navigationDestination(isPresented: $showQuiz) {
                QuizView(session: session, pairCorpus: pairCorpus, jmdict: jmdict)
            }
            .task {
                if let rows = try? await db.mnemonics(wordType: "jmdict",
                                                      wordIds: corpus.items.map(\.id)) {
                    mnemonicMap = Dictionary(uniqueKeysWithValues: rows.map { ($0.wordId, $0.mnemonic) })
                }
            }
        }
    }

    // MARK: - Quiz launch

    private func startQuiz(filter: QuizSession.QuizFilter) {
        session.quizFilter = filter
        showQuiz = true
    }

    // MARK: - Word list (flat — used when search is active)

    private var wordList: some View {
        let pairs = filteredPairs
        return List {
            ForEach(pairs) { pairItem in
                Button { selectedPair = pairItem } label: {
                    TransitivePairRowView(item: pairItem)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    pairSwipeButtons(for: pairItem)
                }
            }
            ForEach(filteredItems) { item in
                Button { selectedItem = item } label: {
                    VocabRowView(item: item)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    swipeButtons(for: item)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Grouped word list (tree of DisclosureGroups — used when search is inactive)

    /// Alphabetically sorted list of source titles that have at least one word in filteredItems.
    private var activeSources: [String] {
        Array(Set(filteredItems.flatMap(\.sources))).sorted()
    }

    // Note: buildSourceTree recomputes on every redraw. Fine for current corpus sizes
    // (~hundreds of words). If filter/collapse interactions feel janky with a larger
    // corpus, cache `sourceTree` as a stored property updated via .onChange(of: filteredItems).
    private var groupedWordList: some View {
        let roots = buildSourceTree(sources: activeSources, items: filteredItems)
        let pairs = filteredPairs
        return List {
            if !pairs.isEmpty {
                pairsSection(pairs: pairs)
            }
            ForEach(roots, id: \.pathKey) { node in
                SourceSectionView(
                    node: node,
                    collapsedSections: $collapsedSections,
                    selectedItem: $selectedItem
                ) { item in
                    swipeButtons(for: item)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Transitive pairs section

    @ViewBuilder
    private func pairsSection(pairs: [TransitivePairItem]) -> some View {
        let isExpanded = Binding(
            get: { !collapsedSections.contains("__transitive-pairs__") },
            set: { expanded in
                if expanded { collapsedSections.remove("__transitive-pairs__") }
                else { collapsedSections.insert("__transitive-pairs__") }
            }
        )
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(pairs) { pairItem in
                Button { selectedPair = pairItem } label: {
                    TransitivePairRowView(item: pairItem)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    pairSwipeButtons(for: pairItem)
                }
            }
        } label: {
            Text("Transitive-Intransitive Pairs")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    @ViewBuilder
    private func pairSwipeButtons(for item: TransitivePairItem) -> some View {
        if !item.pair.isAmbiguous && item.state == .unknown {
            Button {
                Task { await pairCorpus.setPairLearning(pairId: item.id, db: db) }
            } label: {
                Label("Learn", systemImage: "plus.circle.fill")
            }
            .tint(.green)
        }
    }

    @ViewBuilder
    private func swipeButtons(for item: VocabItem) -> some View {
        // Only show swipe actions for fully unknown words.
        // Learning / known words require deliberate action via WordDetailSheet.
        if item.readingState == .unknown && item.kanjiState == .unknown {
            // "Learn word" is declared first so it appears closest to the swipe edge.
            Button {
                Task { await corpus.setReadingState(.learning, wordId: item.id, db: db) }
            } label: {
                Label("Learn word", systemImage: "plus.circle.fill")
            }
            .tint(.green)
            // "Learn kanji" only makes sense when the word has actual kanji forms.
            let firstForm = preferredWrittenForm(
                senseExtras: item.senseExtras,
                activeSenseIndices: item.corpusSenseIndices,
                writtenForms: item.writtenForms
            ) ?? item.writtenForms.flatMap(\.forms).first
            if !item.isKanaOnly, let form = firstForm, !form.furigana.extractKanji().isEmpty {
                Button {
                    Task {
                        // setReadingState ensures commitment (furigana) exists first.
                        await corpus.setReadingState(.learning, wordId: item.id, db: db)
                        await corpus.setKanjiState(.learning, wordId: item.id,
                                                   kanjiChars: form.furigana.extractKanji(), db: db)
                    }
                } label: {
                    Label("Learn kanji", systemImage: "character.book.closed.fill")
                }
                .tint(.purple)
            }
        }
    }

    // MARK: - Toolbar items

    private var filterPicker: some View {
        Menu {
            Button {
                filter = .notYetLearning
            } label: {
                Label(filter == .notYetLearning ? "Not yet learning ✓" : "Not yet learning",
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

    // MARK: - Helpers

    private var filterLabel: String {
        switch filter {
        case .notYetLearning: return "Not yet learning"
        case .learning:       return "Learning"
        case .known:          return "Learned"
        case nil:             return "All"
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .notYetLearning: return "All words triaged!"
        case .learning:       return "No words in progress"
        case .known:          return "No learned words yet"
        case nil:             return "No vocab loaded"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .notYetLearning: return "checkmark.seal"
        case .learning:       return "tray"
        case .known:          return "eye.slash"
        case nil:             return "books.vertical"
        }
    }
}

// MARK: - Source tree model

/// A node in the source path tree.
/// - directory: a path prefix (e.g. "genki-app") containing child nodes
/// - leaf: a single source title (e.g. "genki-app/L13") with its vocab words
indirect enum SourceTreeNode {
    case directory(name: String, pathKey: String, children: [SourceTreeNode])
    case leaf(title: String, pathKey: String, items: [VocabItem])

    var pathKey: String {
        switch self {
        case .directory(_, let key, _): return key
        case .leaf(_, let key, _): return key
        }
    }
}

/// Build a sorted tree from a list of source title paths and a flat item list.
/// Paths are split on "/": everything before the last "/" is a directory prefix.
/// Sources with no "/" become root-level leaves.
/// Directory nodes are injected when two or more sibling titles share a prefix.
func buildSourceTree(sources: [String], items: [VocabItem]) -> [SourceTreeNode] {
    // Map each source title to the items that list it.
    let itemsBySource: [String: [VocabItem]] = {
        var dict: [String: [VocabItem]] = [:]
        for source in sources { dict[source] = [] }
        for item in items {
            for source in item.sources where dict[source] != nil {
                dict[source]!.append(item)
            }
        }
        return dict
    }()

    // Recursively build nodes for sources that share the given prefix.
    // `prefix` is the directory path so far (e.g. "genki-app"), or "" for root.
    func buildNodes(sources: [String], prefix: String) -> [SourceTreeNode] {
        // Group sources by their next path component after the prefix.
        // e.g. prefix="" and sources=["genki-app/L00","genki-app/L01","Bunsho Dokkai 3"]
        // → groups: ["genki-app": ["genki-app/L00","genki-app/L01"], "Bunsho Dokkai 3": ["Bunsho Dokkai 3"]]
        var groups: [(key: String, sources: [String])] = []
        var seen: [String: Int] = [:]  // first-component -> index in groups

        for source in sources {
            let remainder = prefix.isEmpty ? source : String(source.dropFirst(prefix.count + 1))
            let slashIdx = remainder.firstIndex(of: "/")
            let firstComponent = slashIdx.map { String(remainder[..<$0]) } ?? remainder
            let groupKey = prefix.isEmpty ? firstComponent : "\(prefix)/\(firstComponent)"

            if let idx = seen[groupKey] {
                groups[idx].sources.append(source)
            } else {
                seen[groupKey] = groups.count
                groups.append((key: groupKey, sources: [source]))
            }
        }

        // Each group becomes either a leaf (1 source, path == key) or a directory.
        return groups.map { group in
            if group.sources.count == 1 && group.sources[0] == group.key {
                // Leaf: exactly one source maps to this key directly.
                let title = group.key
                let words = itemsBySource[title] ?? []
                return SourceTreeNode.leaf(title: title, pathKey: title, items: words)
            } else {
                // Directory: multiple sources share this path prefix.
                let dirName = group.key.components(separatedBy: "/").last ?? group.key
                let children = buildNodes(sources: group.sources, prefix: group.key)
                return SourceTreeNode.directory(name: dirName, pathKey: group.key, children: children)
            }
        }
    }

    return buildNodes(sources: sources, prefix: "")
}

// MARK: - SourceSectionView

/// Renders one node of the source tree: a DisclosureGroup for directories and
/// leaf sections, each containing word rows with swipe actions.
struct SourceSectionView<SwipeContent: View>: View {
    let node: SourceTreeNode
    @Binding var collapsedSections: Set<String>
    @Binding var selectedItem: VocabItem?
    @ViewBuilder let swipeButtons: (VocabItem) -> SwipeContent

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(node.pathKey) },
            set: { expanded in
                if expanded { collapsedSections.remove(node.pathKey) }
                else { collapsedSections.insert(node.pathKey) }
            }
        )
    }

    @ViewBuilder var body: some View {
        switch node {
        case .directory(let name, _, let children):
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children, id: \.pathKey) { child in
                    SourceSectionView(
                        node: child,
                        collapsedSections: $collapsedSections,
                        selectedItem: $selectedItem,
                        swipeButtons: swipeButtons
                    )
                }
            } label: {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

        case .leaf(let title, _, let items):
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(items) { item in
                    Button { selectedItem = item } label: {
                        VocabRowView(item: item)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        swipeButtons(item)
                    }
                }
            } label: {
                // Show only the last path component as the section header.
                Text(title.components(separatedBy: "/").last ?? title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
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
                // Prefer the committed reading (from furigana) over kanaTexts.first so that
                // a word like 焚き木 shows たきぎ rather than the JMDict-default まき.
                let displayKana = item.commitment?.committedReading ?? item.kanaTexts.first
                if let kana = displayKana, kana != item.wordText {
                    Text(kana)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            let corpusSenseGlosses: [String] = item.corpusSenseIndices.isEmpty
                ? (item.senseExtras.first?.glosses.first.map { [$0] } ?? [])
                : item.corpusSenseIndices.compactMap { $0 < item.senseExtras.count ? item.senseExtras[$0].glosses.first : nil }
            if !corpusSenseGlosses.isEmpty {
                Text(corpusSenseGlosses.joined(separator: "; "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
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
        if item.readingState == .learning || item.kanjiState == .learning {
            Text("Learning")
                .font(.caption2).fontWeight(.medium)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else if item.readingState == .known || item.kanjiState == .known {
            Text("Learned")
                .font(.caption2).fontWeight(.medium)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
        }
    }
}

// MARK: - TransitivePairRowView

struct TransitivePairRowView: View {
    let item: TransitivePairItem
    @ScaledMetric(relativeTo: .headline) private var furiganaSize: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline) {
                pairFuriganaRow
                Spacer()
                statusBadge
            }
            if item.pair.isAmbiguous {
                Text("Ambiguous")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var pairFuriganaRow: some View {
        HStack(spacing: 0) {
            memberFurigana(item.intransitiveFurigana, member: item.pair.intransitive)
            // Empty rt-height spacer above arrow to align with furigana text
            VStack(spacing: 0) {
                Text(" ").font(.system(size: furiganaSize))
                Text(" ↔ ").font(.headline)
            }
            memberFurigana(item.transitiveFurigana, member: item.pair.transitive)
        }
    }

    @ViewBuilder
    private func memberFurigana(_ segments: [FuriganaSegment]?, member: TransitivePairMember) -> some View {
        if let segs = segments {
            HStack(spacing: 0) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                    VStack(spacing: 0) {
                        Text(seg.rt ?? " ").font(.system(size: furiganaSize)).foregroundStyle(.secondary)
                        Text(seg.ruby).font(.headline)
                    }
                }
            }
        } else {
            // Kana-only fallback — add empty rt row for vertical alignment
            VStack(spacing: 0) {
                Text(" ").font(.system(size: furiganaSize))
                Text(member.kanji.first ?? member.kana)
                    .font(.headline)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.state == .learning {
            Text("Learning")
                .font(.caption2).fontWeight(.medium)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else if item.state == .known {
            Text("Learned")
                .font(.caption2).fontWeight(.medium)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
        }
    }
}
