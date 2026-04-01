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
import GRDB
import Markdown
import Markdownosaur

struct DocumentReaderView: View {
    let entry: CorpusEntry
    let db: QuizDB
    let client: AnthropicClient
    let toolHandler: ToolHandler?
    let jmdict: any DatabaseReader
    let scrollToLine: Int?

    @Environment(VocabCorpus.self) private var corpus
    @Environment(GrammarStore.self) private var grammarStore
    @Environment(CorpusStore.self) private var corpusStore
    @Environment(UserPreferences.self) private var preferences
    @Environment(ClipPlayer.self) private var clipPlayer

    @State private var selectedWord: VocabItem? = nil
    @State private var selectedTopic: IdentifiableGrammarTopic? = nil
    @State private var expandedLines: Set<Int> = []
    @State private var enrolledTopicIds: Set<String> = []
    // All of the following are computed once in .task to avoid re-work on every render.
    @State private var renderedLines: [(lineNumber: Int, text: String)] = []
    @State private var vocabMap: [Int: [String]] = [:]
    @State private var grammarMap: [Int: [String]] = [:]
    @State private var chipFurigana: [String: [FuriganaSegment]] = [:]  // wordId → segments
    @State private var audioClipMap: [Int: AudioClip] = [:]             // lineNumber → clip
    @State private var audioAvailableLines: Set<Int> = []               // lines with a reachable audio file
    @State private var highlightedLine: Int? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(renderedLines, id: \.lineNumber) { line in
                        lineView(line)
                            .id(line.lineNumber)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: renderedLines.isEmpty) { _, isEmpty in
                guard !isEmpty, let target = scrollToLine else { return }
                let animate = !UIAccessibility.isReduceMotionEnabled
                if animate {
                    withAnimation(.easeInOut) { proxy.scrollTo(target, anchor: .center) }
                } else {
                    proxy.scrollTo(target, anchor: .center)
                }
                highlightedLine = target
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    highlightedLine = nil
                }
            }
        }
        .navigationTitle(entry.title.components(separatedBy: "/").last ?? entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedWord) { item in
            WordDetailSheet(initialItem: item, db: db,
                            client: client, toolHandler: toolHandler, jmdict: jmdict)
        }
        .sheet(item: $selectedTopic) { wrapper in
            if let manifest = grammarStore.manifest {
                GrammarDetailSheet(
                    topic: wrapper.topic,
                    manifest: manifest,
                    db: db,
                    client: client,
                    toolHandler: toolHandler,
                    isEnrolled: enrolledTopicIds.contains(wrapper.topic.prefixedId),
                    jmdict: jmdict
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
            chipFurigana = buildChipFurigana()
            if let records = try? await db.enrolledGrammarRecords() {
                enrolledTopicIds = Set(records.map(\.wordId))
            }
            let clips = parseAudioClips(entry.markdown)
            audioClipMap = clips
            let bookmark = preferences.audioFolderBookmark
            var available: Set<Int> = []
            for (lineNumber, clip) in clips {
                if AudioFileFinder.fileExists(for: clip.audioFile, externalFolderBookmark: bookmark) {
                    available.insert(lineNumber)
                    print("[DocumentReaderView] Audio file found: \(clip.audioFile)")
                } else {
                    print("[DocumentReaderView] Audio file NOT found: \(clip.audioFile)")
                }
            }
            audioAvailableLines = available
            print("[DocumentReaderView] \(available.count) of \(clips.count) audio files available")
        }
    }

    // MARK: - Line view

    @ViewBuilder
    private func lineView(_ line: (lineNumber: Int, text: String)) -> some View {
        let vocabIds = vocabMap[line.lineNumber] ?? []
        let grammarIds = grammarMap[line.lineNumber] ?? []
        let hasAnnotations = !vocabIds.isEmpty || !grammarIds.isEmpty

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                MarkdownLineView(text: line.text)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (highlightedLine == line.lineNumber ? Color.yellow.opacity(0.35) : Color.clear)
                            .animation(.easeOut(duration: 0.6), value: highlightedLine)
                    )

                if audioAvailableLines.contains(line.lineNumber),
                   let clip = audioClipMap[line.lineNumber] {
                    let isPlaying = clipPlayer.currentClip == clip
                    Button {
                        clipPlayer.play(clip: clip,
                                        externalFolderBookmark: preferences.audioFolderBookmark)
                    } label: {
                        Image(systemName: isPlaying ? "stop.circle" : "play.circle")
                            .imageScale(.large)
                            .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }

            if hasAnnotations {
                let isExpanded = Binding(
                    get: { expandedLines.contains(line.lineNumber) },
                    set: { open in
                        if open { expandedLines.insert(line.lineNumber) }
                        else { expandedLines.remove(line.lineNumber) }
                    }
                )
                DisclosureGroup(isExpanded: isExpanded) {
                    annotationPanel(vocabIds: vocabIds, grammarIds: grammarIds, lineNumber: line.lineNumber)
                        .padding(.top, 4)
                } label: {
                    let learningVocabCount = vocabIds.filter { id in
                        guard let item = corpus.items.first(where: { $0.id == id }) else { return false }
                        return item.readingState != .unknown || item.kanjiState != .unknown
                    }.count
                    let enrolledGrammarCount = grammarIds.filter { enrolledTopicIds.contains($0) }.count
                    annotationSummaryLabel(
                        vocabCount: vocabIds.count, learningVocabCount: learningVocabCount,
                        grammarCount: grammarIds.count, enrolledGrammarCount: enrolledGrammarCount
                    )
                }
                .padding(.bottom, 6)
            }
        }
        Divider()
            .opacity(hasAnnotations ? 0 : 0.3)
    }

    // MARK: - Annotation panel

    @ViewBuilder
    private func annotationPanel(vocabIds: [String], grammarIds: [String], lineNumber: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(vocabIds, id: \.self) { wordId in
                if let item = corpus.items.first(where: { $0.id == wordId }) {
                    vocabChip(item, lineNumber: lineNumber)
                }
            }
            if let manifest = grammarStore.manifest {
                ForEach(grammarIds, id: \.self) { topicId in
                    if let topic = manifest.topics[topicId] {
                        grammarChip(topic)
                    }
                }
            }
        }
    }

    private func vocabChip(_ item: VocabItem, lineNumber: Int) -> some View {
        // Use this line's specific sense indices if available; fall back to first sense.
        let senseIndices = item.references[entry.title]?
            .first(where: { $0.line == lineNumber })?.llmSense?.senseIndices ?? []
        let gloss: String? = {
            let firstGlosses: [String]
            if senseIndices.isEmpty {
                firstGlosses = item.senseExtras.first.map { [$0.glosses.first].compactMap { $0 } } ?? []
            } else {
                firstGlosses = senseIndices.compactMap { $0 < item.senseExtras.count ? item.senseExtras[$0].glosses.first : nil }
            }
            return firstGlosses.isEmpty ? nil : firstGlosses.joined(separator: "; ")
        }()

        return Button {
            selectedWord = item
        } label: {
            HStack(spacing: 8) {
                // Word with furigana if available, plain text otherwise.
                if let segs = chipFurigana[item.id] {
                    SentenceFuriganaView(segments: segs, textStyle: .subheadline)
                        .fontWeight(.medium)
                } else {
                    Text(item.wordText)
                        .font(.subheadline).fontWeight(.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let gloss {
                    Text(gloss)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
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
            if grammarStore.manifest != nil {
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
    private func annotationSummaryLabel(
        vocabCount: Int, learningVocabCount: Int,
        grammarCount: Int, enrolledGrammarCount: Int
    ) -> some View {
        HStack(spacing: 6) {
            if vocabCount > 0 {
                Label("\(learningVocabCount) of \(vocabCount) vocab", systemImage: "books.vertical")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            if grammarCount > 0 {
                Label("\(enrolledGrammarCount) of \(grammarCount) grammar", systemImage: "text.book.closed")
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

    /// Looks up furigana segments for each vocab word that appears in this document.
    /// Uses the committed furigana from word_commitment when available, then falls back to
    /// lookupFurigana(text:reading:db:) against the jmdict.sqlite furigana table.
    /// Words with no kanji (kana-only) are excluded — no furigana needed.
    private func buildChipFurigana() -> [String: [FuriganaSegment]] {
        var map: [String: [FuriganaSegment]] = [:]
        for item in corpus.items {
            guard item.references[entry.title] != nil else { continue }
            // Kana-only words need no furigana.
            guard !item.writtenTexts.isEmpty else { continue }

            // Prefer the committed furigana form if it exists and decodes cleanly.
            if let furiganaJSON = item.commitment?.furigana,
               let data = furiganaJSON.data(using: .utf8),
               let segs = try? JSONDecoder().decode([FuriganaSegment].self, from: data),
               segs.contains(where: { $0.rt != nil }) {
                map[item.id] = segs
                continue
            }

            // Fall back to the jmdict furigana table using the first kanji form + first kana reading.
            // JMDict kana entries can be katakana (e.g. シラフ) while the furigana table stores
            // hiragana (しらふ), so normalize to hiragana before the lookup.
            if let text = item.writtenTexts.first, let reading = item.kanaTexts.first {
                // Katakana U+30A1–U+30F6 → hiragana U+3041–U+3096 (subtract 0x60).
                // JMDict kana entries may be katakana (e.g. シラフ) while the furigana table
                // stores hiragana (しらふ), so normalize before the lookup.
                var scalars = String.UnicodeScalarView()
                for scalar in reading.unicodeScalars {
                    if scalar.value >= 0x30A1 && scalar.value <= 0x30F6,
                       let h = Unicode.Scalar(scalar.value - 0x60) {
                        scalars.append(h)
                    } else {
                        scalars.append(scalar)
                    }
                }
                let hiraganaReading = String(scalars)
                if let segs = lookupFurigana(text: text, reading: hiraganaReading, db: jmdict) {
                    map[item.id] = segs
                    continue
                }
            }

            // Final fallback: furigana embedded in writtenForms (from vocab.json). Guards against
            // version skew between jmdict.sqlite and vocab.json.
            if let segs = item.writtenForms.first?.forms.first?.furigana,
               segs.contains(where: { $0.rt != nil }) {
                map[item.id] = segs
            }
        }
        return map
    }

    /// Maps each 1-based line number to the grammar topic prefixed IDs annotated on that line.
    private func buildGrammarMap() -> [Int: [String]] {
        guard let manifest = grammarStore.manifest else { return [:] }
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
            if trimmed.hasSuffix("</details>") { inDetails = false }
            continue
        }

        result.append((lineNumber: lineNumber, text: stripUnsupportedHtmlTags(line)))
    }
    return result
}

// MARK: - Audio clip parser

private let audioClipPattern: NSRegularExpression = {
    // Matches data-src="filename.m4a#t=START,END" inside any <audio> tag.
    let pattern = ##"data-src="([^"#]+?\.m4a)#t=([0-9.]+),([0-9.]+)""##
    return try! NSRegularExpression(pattern: pattern)
}()

/// Scans all lines of `markdown` for `<audio data-src="file.m4a#t=START,END" />` tags and
/// returns a map from 1-based line number to the extracted `AudioClip`.
/// Line numbers match those produced by `parseLines` for non-skipped lines.
func parseAudioClips(_ markdown: String) -> [Int: AudioClip] {
    var map: [Int: AudioClip] = [:]
    let lines = markdown.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
        let lineNumber = index + 1
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = audioClipPattern.firstMatch(in: line, range: range) else { continue }
        let file  = nsLine.substring(with: match.range(at: 1))
        let start = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
        let end   = Double(nsLine.substring(with: match.range(at: 3))) ?? 0
        map[lineNumber] = AudioClip(audioFile: file, start: start, end: end)
        print("[DocumentReaderView] Found audio clip: \(file) (\(start)–\(end)s) at line \(lineNumber)")
    }
    if map.isEmpty {
        print("[DocumentReaderView] No audio clips found in document")
    } else {
        print("[DocumentReaderView] Parsed \(map.count) audio clip(s)")
    }
    return map
}

/// Tags that are meaningful in Obsidian but have no iOS rendering support yet.
/// Strip them from line text so they don't appear as raw HTML in the reader.
let unsupportedHtmlTagPattern: NSRegularExpression = {
    // Matches self-closing tags like <audio ... /> and paired open tags like <audio ...>
    // for the blocklisted tag names.
    let pattern = #"<(audio)[^>]*/?>|</(audio)>"#
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}()

func stripUnsupportedHtmlTags(_ line: String) -> String {
    let range = NSRange(line.startIndex..., in: line)
    return unsupportedHtmlTagPattern.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - IdentifiableGrammarTopic

/// Wraps GrammarTopic with Identifiable conformance for use with .sheet(item:).
struct IdentifiableGrammarTopic: Identifiable {
    let topic: GrammarTopic
    var id: String { topic.prefixedId }
}

// MARK: - MarkdownLineView

/// Renders a single Markdown line at reader size (title3).
///
/// Lines containing HTML `<ruby>` tags are rendered via SentenceFuriganaView so
/// the furigana appears above the kanji. All other lines go through Markdownosaur
/// (which handles bold, italic, code, etc.) with fonts rebased to title3 size.
/// Empty lines render as a small spacer to preserve paragraph rhythm.
struct MarkdownLineView: View {
    let text: String

    @ScaledMetric(relativeTo: .title3) private var emptyLineHeight: CGFloat = 10

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: emptyLineHeight)
        } else if trimmed.contains("<ruby>") {
            SentenceFuriganaView(htmlRuby: trimmed, textStyle: .title3)
        } else if let attributed = rendered {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Fallback: plain text when Markdownosaur conversion fails
            Text(text)
                .font(.title3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rendered: AttributedString? {
        var parser = Markdownosaur()
        let document = Document(parsing: text)
        let nsAttr = NSMutableAttributedString(attributedString: parser.attributedString(from: document))
        // Rebase all fonts to title3 size, preserving bold/italic traits.
        // This mirrors the rebasing SelectableText does for body size.
        let target = UIFont.preferredFont(forTextStyle: .title3)
        let full = NSRange(location: 0, length: nsAttr.length)
        var updates: [(NSRange, UIFont)] = []
        nsAttr.enumerateAttribute(.font, in: full) { value, range, _ in
            let traits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let descriptor = target.fontDescriptor.withSymbolicTraits(traits) ?? target.fontDescriptor
            updates.append((range, UIFont(descriptor: descriptor, size: target.pointSize)))
        }
        for (range, font) in updates { nsAttr.addAttribute(.font, value: font, range: range) }
        nsAttr.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        return try? AttributedString(nsAttr, including: \.uiKit)
    }
}
