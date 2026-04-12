// DocumentBrowserView.swift
// Browsable list of corpus documents, mirroring the /‑delimited title hierarchy
// as nested DisclosureGroups (same pattern as VocabBrowserView).
//
// Each leaf shows the document title, vocab count, and grammar count.
// Tapping a leaf navigates to DocumentReaderView.
//
// Empty state: shown when corpus.json has not been downloaded yet;
// includes a Download button that triggers CorpusSync.

import SwiftUI
import GRDB

struct DocumentBrowserView: View {
    let db: QuizDB
    let jmdict: any DatabaseReader
    let client: AnthropicClient
    let toolHandler: ToolHandler?
    /// Called when the user initiates a sync (first-time Download or Redownload).
    /// Refreshes vocab, grammar, transitive pairs, and corpus.
    let onSync: () async -> Void

    @Environment(CorpusStore.self) private var corpusStore

    @State private var collapsedSections: Set<String> = []
    @State private var isSyncing = false

    var body: some View {
        NavigationStack {
            Group {
                if corpusStore.entries.isEmpty {
                    emptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("Reader")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Button {
                            Task {
                                isSyncing = true
                                await onSync()
                                isSyncing = false
                            }
                        } label: {
                            Label("Redownload", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "No documents loaded",
                systemImage: "book.pages",
                description: Text("Download the corpus to browse annotated documents.")
            )
            if isSyncing {
                ProgressView("Downloading…")
            } else {
                Button("Download") {
                    Task {
                        isSyncing = true
                        await onSync()
                        isSyncing = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Document list

    private var documentList: some View {
        let roots = buildCorpusTree(entries: corpusStore.entries)
        return List {
            ForEach(roots, id: \.pathKey) { node in
                CorpusSectionView(
                    node: node,
                    collapsedSections: $collapsedSections,
                    db: db,
                    jmdict: jmdict,
                    client: client,
                    toolHandler: toolHandler
                )
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Corpus tree model

/// A node in the document title path tree.
/// - directory: a path prefix (e.g. "Genki 1") containing child nodes
/// - leaf: a single corpus document (e.g. "Genki 1/L11")
indirect enum CorpusTreeNode {
    case directory(name: String, pathKey: String, children: [CorpusTreeNode])
    case leaf(entry: CorpusEntry)

    var pathKey: String {
        switch self {
        case .directory(_, let key, _): return key
        case .leaf(let entry): return entry.title
        }
    }
}

/// Build a sorted tree from a flat list of corpus entries whose titles use "/" as a hierarchy separator.
/// Entries with no "/" become root-level leaves. Entries that share a prefix become children of a
/// directory node — mirroring the algorithm used by buildSourceTree in VocabBrowserView.
func buildCorpusTree(entries: [CorpusEntry]) -> [CorpusTreeNode] {
    let entriesByTitle: [String: CorpusEntry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0) })
    let titles = entries.map(\.title).sorted()

    func buildNodes(titles: [String], prefix: String) -> [CorpusTreeNode] {
        var groups: [(key: String, titles: [String])] = []
        var seen: [String: Int] = [:]

        for title in titles {
            let remainder = prefix.isEmpty ? title : String(title.dropFirst(prefix.count + 1))
            let slashIdx = remainder.firstIndex(of: "/")
            let firstComponent = slashIdx.map { String(remainder[..<$0]) } ?? remainder
            let groupKey = prefix.isEmpty ? firstComponent : "\(prefix)/\(firstComponent)"

            if let idx = seen[groupKey] {
                groups[idx].titles.append(title)
            } else {
                seen[groupKey] = groups.count
                groups.append((key: groupKey, titles: [title]))
            }
        }

        return groups.map { group in
            if group.titles.count == 1 && group.titles[0] == group.key {
                let entry = entriesByTitle[group.key]!
                return CorpusTreeNode.leaf(entry: entry)
            } else {
                let dirName = group.key.components(separatedBy: "/").last ?? group.key
                let children = buildNodes(titles: group.titles, prefix: group.key)
                return CorpusTreeNode.directory(name: dirName, pathKey: group.key, children: children)
            }
        }
    }

    return buildNodes(titles: titles, prefix: "")
}

// MARK: - CorpusSectionView

/// Renders one node of the corpus tree as a DisclosureGroup.
/// Directories contain child CorpusSectionViews; leaves show a NavigationLink to DocumentReaderView.
struct CorpusSectionView: View {
    let node: CorpusTreeNode
    @Binding var collapsedSections: Set<String>
    let db: QuizDB
    let jmdict: any DatabaseReader
    let client: AnthropicClient
    let toolHandler: ToolHandler?

    @Environment(CorpusStore.self) private var corpusStore

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
                    CorpusSectionView(
                        node: child,
                        collapsedSections: $collapsedSections,
                        db: db,
                        jmdict: jmdict,
                        client: client,
                        toolHandler: toolHandler
                    )
                }
            } label: {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

        case .leaf(let entry):
            NavigationLink {
                DocumentReaderView(
                    entry: entry,
                    db: db,
                    client: client,
                    toolHandler: toolHandler,
                    jmdict: jmdict,
                    scrollToLine: nil
                )
            } label: {
                CorpusEntryRowView(entry: entry)
            }
        }
    }
}

// MARK: - CorpusEntryRowView

/// A single row for a corpus document: short title + vocab and grammar count badges.
struct CorpusEntryRowView: View {
    let entry: CorpusEntry

    var body: some View {
        HStack {
            Text(entry.title.components(separatedBy: "/").last ?? entry.title)
                .font(.body)
            Spacer()
            HStack(spacing: 6) {
                if entry.vocabCount > 0 {
                    countBadge(entry.vocabCount, color: .blue, label: "vocab")
                }
                if entry.grammarCount > 0 {
                    countBadge(entry.grammarCount, color: .green, label: "grammar")
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func countBadge(_ count: Int, color: Color, label: String) -> some View {
        Text("\(count)")
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .accessibilityLabel("\(count) \(label)")
    }
}
