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

/// Bundles a vocab item with the navigation origin that produced the tap,
/// so WordDetailSheet can scope sense highlighting to the browsed document.
struct VocabItemSelection: Identifiable {
    let item: VocabItem
    let origin: WordDetailOrigin?
    var id: String { item.id }
}

struct VocabBrowserView: View {
    let pairCorpus: TransitivePairCorpus
    let db: QuizDB
    let jmdict: any DatabaseReader
    let session: QuizSession
    let plantingSession: PlantingSession
    let onSync: () async -> Void

    @Environment(VocabCorpus.self) private var corpus
    @Environment(CounterCorpus.self) private var counterCorpus
    @Environment(GrammarStore.self) private var grammarStore
    @Environment(CorpusStore.self) private var corpusStore

    @State private var filter: VocabFilter? = .notYetLearning  // nil = all
    @State private var selectedItem: VocabItemSelection? = nil
    @State private var selectedPair: TransitivePairItem? = nil

    @State private var showQuiz = false
    @State private var showSettings = false
    @State private var showPlanting = false
    @State private var isSyncing = false
    @State private var searchText = ""
    @State private var mnemonicMap: [String: String] = [:]  // wordId -> mnemonic text
    @State private var collapsedSections: Set<String> = []  // path keys of collapsed nodes
    @State private var dashboardRefreshID = 0

    /// Highest counter enrollment state for a given JMDict ID.
    /// .learning if any counter for that word is learning; .known if all are known and none learning; .unknown otherwise.
    private var counterStateByJMDictId: [String: FacetState] {
        var map: [String: FacetState] = [:]
        for counterItem in counterCorpus.items {
            guard let jmdictId = counterItem.counter.jmdict?.id else { continue }
            let existing = map[jmdictId] ?? .unknown
            switch (existing, counterItem.state) {
            case (_, .learning):       map[jmdictId] = .learning
            case (.unknown, .known):   map[jmdictId] = .known
            default:                   break
            }
        }
        return map
    }

    private func itemMatchesFilter(_ item: VocabItem, filter: VocabFilter) -> Bool {
        if item.matches(filter: filter) { return true }
        // Also match when the item's counter enrollment state fits the filter.
        if let counterState = counterStateByJMDictId[item.id] {
            switch filter {
            case .notYetLearning: return counterState == .unknown
            case .learning:       return counterState == .learning
            case .known:          return counterState == .known
            }
        }
        return false
    }

    private var filteredItems: [VocabItem] {
        let f = filter
        let statusFiltered = corpus.items.filter { f == nil || itemMatchesFilter($0, filter: f!) }
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
                            Button("Quiz counters only") { startQuiz(filter: .countersOnly) }
                            Button("Quiz kanji only") { startQuiz(filter: .kanjiOnly) }
                        }
                        BrowserToolbarMenu(
                            showSettings: $showSettings,
                            db: db,
                            client: session.client,
                            lastSyncedAt: corpus.lastSyncedAt,
                            isDownloading: isSyncing,
                            onRedownload: {
                                Task {
                                    isSyncing = true
                                    await onSync()
                                    isSyncing = false
                                }
                            }
                        )
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search kanji, reading, meaning…")
            .sheet(item: $selectedItem) { selection in
                WordDetailSheet(initialItem: selection.item, db: db,
                                client: session.client, toolHandler: session.toolHandler, jmdict: jmdict,
                                origin: selection.origin)
            }
            .sheet(item: $selectedPair) { pair in
                TransitivePairDetailSheet(initialItem: pair, pairCorpus: pairCorpus, db: db, jmdict: jmdict,
                                          client: session.client, toolHandler: session.toolHandler)
            }

            .sheet(isPresented: $showSettings) { SettingsView(db: db) }
            .sheet(isPresented: $showPlanting) {
                PlantView(session: plantingSession, jmdict: jmdict,
                          client: session.client, toolHandler: session.toolHandler)
            }
            .navigationDestination(isPresented: $showQuiz) {
                QuizView(session: session, pairCorpus: pairCorpus, jmdict: jmdict)
            }
            .onChange(of: showQuiz) { _, isShowing in
                if !isShowing { dashboardRefreshID += 1 }
            }
            .onChange(of: showPlanting) { _, isShowing in
                if !isShowing { dashboardRefreshID += 1 }
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
        session.documentScope = nil
        session.quizFilter = filter
        session.phase = .idle   // ensure QuizView's .task always calls session.start()
        showQuiz = true
    }

    /// Launch a quiz restricted to words sourced from a single document.
    private func startDocumentQuiz(documentTitle: String) {
        session.documentScope = documentTitle
        session.quizFilter = .vocabOnly
        session.phase = .idle   // ensure QuizView's .task always calls session.start()
        showQuiz = true
    }

    /// Launch the planting flow for a single document.
    private func startPlanting(documentTitle: String) {
        plantingSession.start(documentTitle: documentTitle, allWords: corpus.items)
        showPlanting = true
    }

    // MARK: - Word list (flat — used when search is active)

    private var wordList: some View {
        let pairs = filteredPairs
        let counterStates = counterStateByJMDictId
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
                Button { selectedItem = VocabItemSelection(item: item, origin: nil) } label: {
                    VocabRowView(item: item, counterState: counterStates[item.id])
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    swipeButtons(for: item, documentTitle: nil)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Grouped word list (tree of DisclosureGroups — used when search is inactive)

    /// Source titles that have at least one word in filteredItems, sorted by explicit order
    /// from sourceOrders then alphabetically within each level.
    private var activeSources: [String] {
        let orders = corpus.sourceOrders
        return Array(Set(filteredItems.flatMap(\.sources)))
            .sorted { compareSourcePaths($0, $1, orders: orders) }
    }

    // Note: buildSourceTree recomputes on every redraw. Fine for current corpus sizes
    // (~hundreds of words). If filter/collapse interactions feel janky with a larger
    // corpus, cache `sourceTree` as a stored property updated via .onChange(of: filteredItems).
    private var groupedWordList: some View {
        let roots = buildSourceTree(sources: activeSources, items: filteredItems)
        let pairs = filteredPairs
        return List {
            Section {
                MotivationDashboardView(db: db, refreshID: dashboardRefreshID)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listSectionSeparator(.hidden)
            if !pairs.isEmpty {
                pairsSection(pairs: pairs)
            }
            let counterStates = counterStateByJMDictId
            ForEach(roots, id: \.pathKey) { node in
                SourceSectionView(
                    node: node,
                    collapsedSections: $collapsedSections,
                    selectedItem: $selectedItem,
                    rowContent: { item in VocabRowView(item: item, counterState: counterStates[item.id]) },
                    swipeButtons: { item, title in swipeButtons(for: item, documentTitle: title) },
                    onLearn: { title in startPlanting(documentTitle: title) },
                    onDocumentQuiz: { title in startDocumentQuiz(documentTitle: title) }
                )
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
    /// `documentTitle` is the specific document leaf the user is swiping in, or nil when
    /// swiping from the flat unfiltered list (no document context available).
    private func swipeButtons(for item: VocabItem, documentTitle: String?) -> some View {
        // Only show swipe actions for fully unknown words.
        // Learning / known words require deliberate action via WordDetailSheet.
        if item.readingState == .unknown && item.kanjiState == .unknown {
            // Resolve the preferred written form using the document-specific annotatedForms when
            // available, falling back to the item-level annotatorResolved (from the first source).
            let docResolved: ResolvedAnnotatorForms? = documentTitle.flatMap { title in
                let forms = item.references[title]?.first?.annotatedForms ?? []
                return resolveAnnotatedForms(annotatedForms: forms,
                                             writtenForms: item.writtenForms,
                                             kanaTexts: item.kanaTexts)
            }
            let resolved = docResolved ?? item.annotatorResolved
            let preferredForm = resolved?.writtenForm
                ?? preferredWrittenForm(
                    senseExtras: item.senseExtras,
                    activeSenseIndices: item.corpusSenseIndices,
                    writtenForms: item.writtenForms
                )
                ?? item.writtenForms.flatMap(\.forms).first

            // "Learn word" is declared first so it appears closest to the swipe edge.
            Button {
                Task {
                    await corpus.setReadingState(.learning, wordId: item.id, db: db,
                                                 preferredForm: resolved?.writtenForm)
                }
            } label: {
                Label("Learn word", systemImage: "plus.circle.fill")
            }
            .tint(.green)
            // "Learn kanji" only makes sense when the word has actual kanji forms.
            if !item.isKanaOnly, let form = preferredForm, !form.furigana.extractKanji().isEmpty {
                Button {
                    Task {
                        // setReadingState ensures commitment (furigana) exists first.
                        await corpus.setReadingState(.learning, wordId: item.id, db: db,
                                                     preferredForm: resolved?.writtenForm)
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

/// Compare two source paths using explicit order values where available, falling back to
/// alphabetical. Paths are compared component by component (split on "/"). At each level,
/// paths with an explicit order in `orders` sort before unordered ones; among ordered paths
/// the integer value determines the order; among unordered paths the component sorts
/// alphabetically.
///
/// Example with orders = ["Counters": 1, "Counters/Wago": 0, "Counters/Counters-Must-Know": 1]:
///   "Counters/Wago" < "Counters/Counters-Must-Know" (orders 0 < 1 within directory)
///   "Counters/Wago" < "Genki 1/L11" ("Counters" is ordered, "Genki 1" is not)
///   "Ad Hoc Vocab" < "Genki 1/L11" (both unordered; "Ad" < "Genki" alphabetically)
func compareSourcePaths(_ a: String, _ b: String, orders: [String: Int]) -> Bool {
    let aComps = a.components(separatedBy: "/")
    let bComps = b.components(separatedBy: "/")
    let depth = max(aComps.count, bComps.count)
    var aPrefix = ""
    var bPrefix = ""
    for i in 0..<depth {
        let aComp = i < aComps.count ? aComps[i] : nil
        let bComp = i < bComps.count ? bComps[i] : nil
        let aKey = aComp.map { aPrefix.isEmpty ? $0 : "\(aPrefix)/\($0)" }
        let bKey = bComp.map { bPrefix.isEmpty ? $0 : "\(bPrefix)/\($0)" }
        let aOrder = aKey.flatMap { orders[$0] }
        let bOrder = bKey.flatMap { orders[$0] }
        if let ao = aOrder, let bo = bOrder {
            if ao != bo { return ao < bo }
        } else if aOrder != nil {
            return true   // a is explicitly ordered; b is not → a comes first
        } else if bOrder != nil {
            return false  // b is explicitly ordered; a is not → b comes first
        } else {
            let as_ = aComp ?? ""
            let bs_ = bComp ?? ""
            if as_ != bs_ { return as_ < bs_ }
        }
        if let ac = aComp { aPrefix = aPrefix.isEmpty ? ac : "\(aPrefix)/\(ac)" }
        if let bc = bComp { bPrefix = bPrefix.isEmpty ? bc : "\(bPrefix)/\(bc)" }
    }
    return false
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
/// `onLearn` and `onDocumentQuiz` are optional callbacks fired from leaf section headers;
/// they receive the full document title (e.g. "genki-app/L13").
struct SourceSectionView<RowContent: View, SwipeContent: View>: View {
    let node: SourceTreeNode
    @Binding var collapsedSections: Set<String>
    @Binding var selectedItem: VocabItemSelection?
    @ViewBuilder let rowContent: (VocabItem) -> RowContent
    @ViewBuilder let swipeButtons: (VocabItem, String?) -> SwipeContent
    var onLearn: ((String) -> Void)? = nil
    var onDocumentQuiz: ((String) -> Void)? = nil

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
                        rowContent: rowContent,
                        swipeButtons: swipeButtons,
                        onLearn: onLearn,
                        onDocumentQuiz: onDocumentQuiz
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
                    Button {
                        selectedItem = VocabItemSelection(item: item, origin: .document(title: title))
                    } label: {
                        rowContent(item)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        swipeButtons(item, title)
                    }
                }
            } label: {
                // Show only the last path component as the section header,
                // with Learn and Quiz buttons when callbacks are provided.
                HStack(spacing: 8) {
                    Text(title.components(separatedBy: "/").last ?? title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    Spacer()
                    let hasUnknownWords = items.contains { $0.matches(filter: .notYetLearning) }
                    if let onLearn, hasUnknownWords {
                        Button {
                            onLearn(title)
                        } label: {
                            Label("Learn", systemImage: "leaf.fill")
                                .font(.caption)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.green)
                    }
                    if let onDocumentQuiz {
                        Button {
                            onDocumentQuiz(title)
                        } label: {
                            Label("Quiz", systemImage: "brain")
                                .font(.caption)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.blue)
                    }
                }
            }
        }
    }
}

// MARK: - VocabRowView

struct VocabRowView: View {
    let item: VocabItem
    var counterState: FacetState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.wordText)
                    .font(.headline)
                // Prefer the committed reading, then the annotator's chosen kana, then the
                // JMDict-default first kana. This ensures e.g. 薪 shows たきぎ (from the bullet)
                // rather than the JMDict-default まき when the annotator wrote "- たきぎ".
                let displayKana = item.commitment?.committedReading ?? item.annotatorResolved?.kana ?? item.kanaTexts.first
                if let kana = displayKana, kana != item.wordText {
                    Text(kana)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.hasCounterAnnotation {
                    Text("123")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
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
        let isLearning = item.readingState == .learning || item.kanjiState == .learning
            || counterState == .learning
        let isKnown = !isLearning
            && (item.readingState == .known || item.kanjiState == .known || counterState == .known)
        if isLearning {
            Text("Learning")
                .font(.caption2).fontWeight(.medium)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else if isKnown {
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
