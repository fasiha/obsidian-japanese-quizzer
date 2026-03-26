// DocumentReaderView.swift
// Line-by-line Markdown reader for a single corpus document.
//
// Each physical Markdown line is its own render unit (via MarkdownLineView / Markdownosaur).
// Lines that have vocab or grammar annotations show a collapsed DisclosureGroup below them;
// tapping a chip opens the corresponding detail sheet.
//
// Parsing rules (applied once at view load time):
//   - YAML frontmatter (opening --- through closing ---) is skipped entirely.
//   - Single-line <details>…</details> lines are discarded.
//   - Multi-line <details> blocks (opening tag through </details>) are discarded.
//   - All other lines are renderable, keyed by their original 1-based line number.
//
// Inverted annotation maps are built from VocabCorpus and GrammarManifest:
//   vocabMap:   lineNumber → [wordId]      (words annotated on that line in this document)
//   grammarMap: lineNumber → [prefixedId]  (grammar topics annotated on that line)

import SwiftUI
import Markdown
import Markdownosaur

struct DocumentReaderView: View {
    let entry: CorpusEntry
    let corpus: VocabCorpus
    let grammarManifest: GrammarManifest?
    let db: QuizDB
    let session: QuizSession

    @State private var selectedWord: VocabItem? = nil
    @State private var selectedTopic: IdentifiableGrammarTopic? = nil
    @State private var expandedLines: Set<Int> = []
    @State private var enrolledTopicIds: Set<String> = []
    // Parsed once on appear to avoid re-parsing on every render.
    @State private var renderedLines: [(lineNumber: Int, text: String)] = []
    @State private var vocabMap: [Int: [String]] = [:]
    @State private var grammarMap: [Int: [String]] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(renderedLines, id: \.lineNumber) { line in
                    lineView(line)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(entry.title.components(separatedBy: "/").last ?? entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedWord) { item in
            WordDetailSheet(initialItem: item, corpus: corpus, db: db, session: session)
        }
        .sheet(item: $selectedTopic) { wrapper in
            if let manifest = grammarManifest {
                GrammarDetailSheet(
                    topic: wrapper.topic,
                    manifest: manifest,
                    db: db,
                    client: session.client,
                    toolHandler: session.toolHandler,
                    isEnrolled: enrolledTopicIds.contains(wrapper.topic.prefixedId)
                ) { nowEnrolled in
                    let allIds = [wrapper.topic.prefixedId] + (wrapper.topic.equivalenceGroup ?? [])
                    for id in allIds {
                        if nowEnrolled { enrolledTopicIds.insert(id) }
                        else { enrolledTopicIds.remove(id) }
                    }
                }
            }
        }
        .task {
            renderedLines = parseLines(entry.markdown)
            vocabMap = buildVocabMap()
            grammarMap = buildGrammarMap()
            if let records = try? await db.enrolledGrammarRecords() {
                enrolledTopicIds = Set(records.map(\.wordId))
            }
        }
    }

    // MARK: - Line view

    @ViewBuilder
    private func lineView(_ line: (lineNumber: Int, text: String)) -> some View {
        let vocabIds = vocabMap[line.lineNumber] ?? []
        let grammarIds = grammarMap[line.lineNumber] ?? []
        let hasAnnotations = !vocabIds.isEmpty || !grammarIds.isEmpty

        VStack(alignment: .leading, spacing: 2) {
            MarkdownLineView(text: line.text)
                .padding(.vertical, 4)

            if hasAnnotations {
                let isExpanded = Binding(
                    get: { expandedLines.contains(line.lineNumber) },
                    set: { open in
                        if open { expandedLines.insert(line.lineNumber) }
                        else { expandedLines.remove(line.lineNumber) }
                    }
                )
                DisclosureGroup(isExpanded: isExpanded) {
                    annotationPanel(vocabIds: vocabIds, grammarIds: grammarIds)
                        .padding(.top, 4)
                } label: {
                    annotationSummaryLabel(vocabCount: vocabIds.count, grammarCount: grammarIds.count)
                }
                .padding(.bottom, 6)
            }
        }
        Divider()
            .opacity(hasAnnotations ? 0 : 0.3)
    }

    // MARK: - Annotation panel

    @ViewBuilder
    private func annotationPanel(vocabIds: [String], grammarIds: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(vocabIds, id: \.self) { wordId in
                if let item = corpus.items.first(where: { $0.id == wordId }) {
                    vocabChip(item)
                }
            }
            if let manifest = grammarManifest {
                ForEach(grammarIds, id: \.self) { topicId in
                    if let topic = manifest.topics[topicId] {
                        grammarChip(topic)
                    }
                }
            }
        }
    }

    private func vocabChip(_ item: VocabItem) -> some View {
        Button {
            selectedWord = item
        } label: {
            HStack(spacing: 6) {
                Text(item.wordText)
                    .font(.subheadline).fontWeight(.medium)
                if let gloss = item.senseExtras.first?.glosses.first {
                    Text(gloss)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func grammarChip(_ topic: GrammarTopic) -> some View {
        Button {
            if grammarManifest != nil {
                selectedTopic = IdentifiableGrammarTopic(topic: topic)
            }
        } label: {
            HStack(spacing: 6) {
                Text(topic.titleEn)
                    .font(.subheadline).fontWeight(.medium)
                if let summary = topic.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Small label shown in the DisclosureGroup header before it is expanded.
    private func annotationSummaryLabel(vocabCount: Int, grammarCount: Int) -> some View {
        HStack(spacing: 6) {
            if vocabCount > 0 {
                Label("\(vocabCount) vocab", systemImage: "books.vertical")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            if grammarCount > 0 {
                Label("\(grammarCount) grammar", systemImage: "text.book.closed")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Inverted annotation maps

    /// Maps each 1-based line number to the word IDs annotated on that line in this document.
    private func buildVocabMap() -> [Int: [String]] {
        var map: [Int: [String]] = [:]
        for item in corpus.items {
            guard let refs = item.references[entry.title] else { continue }
            for ref in refs {
                map[ref.line, default: []].append(item.id)
            }
        }
        return map
    }

    /// Maps each 1-based line number to the grammar topic prefixed IDs annotated on that line.
    private func buildGrammarMap() -> [Int: [String]] {
        guard let manifest = grammarManifest else { return [:] }
        var map: [Int: [String]] = [:]
        for (_, topic) in manifest.topics {
            guard let refs = topic.references?[entry.title] else { continue }
            for ref in refs {
                map[ref.line, default: []].append(topic.prefixedId)
            }
        }
        return map
    }
}

// MARK: - Line parser

/// Parses document markdown into renderable lines with their original 1-based line numbers.
/// Skips YAML frontmatter and all <details> blocks (single-line and multi-line).
func parseLines(_ markdown: String) -> [(lineNumber: Int, text: String)] {
    let lines = markdown.components(separatedBy: "\n")
    var result: [(lineNumber: Int, text: String)] = []
    var inFrontmatter = false
    var inDetails = false

    for (index, line) in lines.enumerated() {
        let lineNumber = index + 1
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // YAML frontmatter: skip from opening --- through closing ---
        if lineNumber == 1 && trimmed == "---" {
            inFrontmatter = true
            continue
        }
        if inFrontmatter {
            if trimmed == "---" { inFrontmatter = false }
            continue
        }

        // Single-line <details>…</details>
        if trimmed.hasPrefix("<details>") && trimmed.hasSuffix("</details>") {
            continue
        }

        // Multi-line <details> block: discard through closing </details>
        if trimmed.hasPrefix("<details>") {
            inDetails = true
            continue
        }
        if inDetails {
            if trimmed == "</details>" { inDetails = false }
            continue
        }

        result.append((lineNumber: lineNumber, text: line))
    }
    return result
}

// MARK: - IdentifiableGrammarTopic

/// Wraps GrammarTopic with Identifiable conformance for use with .sheet(item:).
struct IdentifiableGrammarTopic: Identifiable {
    let topic: GrammarTopic
    var id: String { topic.prefixedId }
}

// MARK: - MarkdownLineView

/// Renders a single Markdown line as an AttributedString using Markdownosaur.
/// Empty lines render as a small spacer to preserve paragraph rhythm.
struct MarkdownLineView: View {
    let text: String

    @ScaledMetric(relativeTo: .body) private var emptyLineHeight: CGFloat = 8

    var body: some View {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer().frame(height: emptyLineHeight)
        } else if let attributed = rendered {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Fallback: plain text when Markdownosaur conversion fails
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rendered: AttributedString? {
        var parser = Markdownosaur()
        let document = Document(parsing: text)
        let nsAttr = parser.attributedString(from: document)
        return try? AttributedString(nsAttr, including: \.uiKit)
    }
}
