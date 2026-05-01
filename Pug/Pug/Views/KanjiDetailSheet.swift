// KanjiDetailSheet.swift
// Detail sheet for a global kanji quiz item (word_type="kanji").
// Shows the kanji's kanjidic2 data and the enrolled words that sponsor it,
// each tappable to open their WordDetailSheet.

import GRDB
import SwiftUI

struct KanjiDetailSheet: View {
    let kanji: String
    let db: QuizDB
    let client: AnthropicClient
    let toolHandler: ToolHandler?
    let jmdict: any DatabaseReader

    @Environment(VocabCorpus.self) private var corpus
    @Environment(KanjiTopUsageStore.self) private var kanjiTopUsageStore
    @Environment(\.dismiss) private var dismiss

    @State private var sponsorWords: [VocabItem] = []
    @State private var wordForDetail: VocabItem? = nil
    @State private var isKanjiEnrolled = false
    /// How many top-usage rows to show (increases by 10 on each "Show more" tap).
    @State private var topUsageDisplayCount = 10
    /// Text, reading, and all glosses (senses joined with "; ", sub-glosses with ", ") for
    /// non-corpus JMDict words in the top-usage list, keyed by JMDict entry ID.
    @State private var topUsageWordDetails: [String: (text: String, reading: String?, gloss: String?)] = [:]

    var body: some View {
        NavigationStack {
            List {
                kanjiHeaderSection
                if !sponsorWords.isEmpty {
                    sponsorWordsSection
                }
                if let entry = kanjiTopUsageStore.entry(for: kanji), !entry.words.isEmpty {
                    topUsageSection(entry: entry)
                }
            }
            .navigationTitle(kanji)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $wordForDetail) { word in
                WordDetailSheet(initialItem: word, db: db, client: client,
                                toolHandler: toolHandler, jmdict: jmdict)
            }
        }
        .task {
            await loadSponsorWords()
            await loadTopUsageWordDetails()
        }
    }

    // MARK: - Kanji header

    private var kanjiHeaderSection: some View {
        Section {
            // Read-only KanjiInfoCard: no parent-word context, enrollment managed from
            // individual WordDetailSheets reachable via the sponsor words list below.
            KanjiInfoCard(
                kanji: kanji,
                wordReading: nil,
                activeWordMeanings: [],
                kanjidicDB: toolHandler?.kanjidic,
                isWordEnrolled: false,
                isKanjiEnrolled: isKanjiEnrolled,
                otherWords: [],
                onToggleWord: {},
                onToggleKanji: {},
                onTapOtherWord: { _ in }
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - Sponsor words

    private var sponsorWordsSection: some View {
        Section("Words using this kanji") {
            ForEach(sponsorWords) { word in
                Button {
                    wordForDetail = word
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.wordText)
                                .font(.body)
                            if let reading = word.kanaTexts.first, reading != word.wordText {
                                Text(reading)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Top usage by BCCWJ frequency

    private func topUsageSection(entry: KanjiTopUsageEntry) -> some View {
        let displayed = Array(entry.words.prefix(topUsageDisplayCount))
        let pmwSum = displayed.reduce(0.0) { $0 + $1.pmw }
        return Section {
            ForEach(Array(displayed.enumerated()), id: \.offset) { _, word in
                topUsageRow(word: word, pmwSum: pmwSum)
            }
            if topUsageDisplayCount < entry.words.count {
                Button("Show more") {
                    topUsageDisplayCount = min(topUsageDisplayCount + 10, entry.words.count)
                }
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
            }
            Text("\(min(topUsageDisplayCount, entry.words.count)) of \(entry.totalMatches) words")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Top words by corpus frequency")
        }
    }

    private func topUsageRow(word: KanjiTopUsageWord, pmwSum: Double) -> some View {
        let corpusItem: VocabItem? = word.id.flatMap { id in corpus.items.first { $0.id == id } }
        let wordDetail = word.id.flatMap { topUsageWordDetails[$0] }

        let furiganaSegs: [FuriganaSegment]? = {
            let text: String?
            let reading: String?
            if let item = corpusItem {
                text = item.writtenTexts.first
                let kana = item.kanaTexts.first
                reading = kana == item.wordText ? nil : kana
            } else if let detail = wordDetail {
                text = detail.text
                reading = detail.reading
            } else {
                return nil
            }
            guard let t = text, let r = reading else { return nil }
            return lookupFurigana(text: t, reading: r, db: jmdict)
        }()

        return TopUsageRow(
            word: word,
            pmwSum: pmwSum,
            corpusItem: corpusItem,
            furiganaSegs: furiganaSegs,
            wordDetail: wordDetail,
            onTap: { item in wordForDetail = item }
        )
    }

    // MARK: - Data loading

    private func loadTopUsageWordDetails() async {
        guard let entry = kanjiTopUsageStore.entry(for: kanji) else { return }
        let corpusIds = Set(corpus.items.map { $0.id })
        let nonCorpusIds = entry.words.compactMap { $0.id }.filter { !corpusIds.contains($0) }
        guard !nonCorpusIds.isEmpty else { return }
        let details: [String: (text: String, reading: String?, gloss: String?)] = (try? await jmdict.read { db in
            var result: [String: (text: String, reading: String?, gloss: String?)] = [:]
            for id in nonCorpusIds {
                guard let json = try? String.fetchOne(db, sql: "SELECT entry_json FROM entries WHERE id = ?", arguments: [id]),
                      let data = json.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let kanjiTexts = (raw["kanji"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                let kanaTexts = (raw["kana"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                let text = kanjiTexts.first ?? kanaTexts.first ?? ""
                let reading: String? = kanjiTexts.isEmpty ? nil : kanaTexts.first
                let senses = raw["sense"] as? [[String: Any]] ?? []
                let glossJoined = senses.compactMap { sense -> String? in
                    let glosses = (sense["gloss"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                    return glosses.isEmpty ? nil : glosses.joined(separator: ", ")
                }.joined(separator: "; ")
                result[id] = (text: text, reading: reading, gloss: glossJoined.isEmpty ? nil : glossJoined)
            }
            return result
        }) ?? [:]
        topUsageWordDetails = details
    }

    private func loadSponsorWords() async {
        guard let quizDB = toolHandler?.quizDB else {
            // Fall back to words whose written form contains this kanji character.
            sponsorWords = corpus.items.filter { $0.writtenTexts.joined().contains(kanji) }
            return
        }
        let sponsorIds = (try? await quizDB.kanjiSponsors(kanjiChar: kanji, excluding: "")) ?? []
        if sponsorIds.isEmpty {
            sponsorWords = corpus.items.filter { $0.writtenTexts.joined().contains(kanji) }
            isKanjiEnrolled = false
        } else {
            sponsorWords = corpus.items.filter { sponsorIds.contains($0.id) }
            isKanjiEnrolled = true
        }
    }
}

// MARK: - TopUsageRow

/// One row in the "Top words by corpus frequency" section.
/// Extracted as a struct so computed properties don't collide with @ViewBuilder restrictions.
private struct TopUsageRow: View {
    let word: KanjiTopUsageWord
    let pmwSum: Double
    let corpusItem: VocabItem?
    /// Pre-computed furigana segmentation (nil when unavailable or not applicable).
    let furiganaSegs: [FuriganaSegment]?
    /// Text, reading, and gloss for non-corpus JMDict-matched words. Nil for corpus items and null-id rows.
    let wordDetail: (text: String, reading: String?, gloss: String?)?
    let onTap: (VocabItem) -> Void

    private var fraction: Double { pmwSum > 0 ? word.pmw / pmwSum : 0 }

    var body: some View {
        if let item = corpusItem {
            Button { onTap(item) } label: {
                rowContentView.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            rowContentView
        }
    }

    private var rowContentView: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                wordDisplayView
                    .fixedSize()
                if let gloss = glossText {
                    Text(gloss)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text(String(format: "%.1f", word.pmw))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                // Always reserve space for the chevron; hide it for non-tappable rows.
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .opacity(corpusItem != nil ? 1 : 0)
            }
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: geo.size.width * fraction, height: 3)
            }
            .frame(height: 3)
        }
    }

    private var glossText: String? {
        if let item = corpusItem {
            let joined = item.senseExtras.compactMap { sense -> String? in
                sense.glosses.isEmpty ? nil : sense.glosses.joined(separator: ", ")
            }.joined(separator: "; ")
            return joined.isEmpty ? nil : joined
        }
        return wordDetail?.gloss
    }

    @ViewBuilder
    private var wordDisplayView: some View {
        if let segs = furiganaSegs, segs.contains(where: { $0.rt != nil }) {
            SentenceFuriganaView(segments: segs, textStyle: .subheadline)
                .fontWeight(.medium)
        } else if let text = primaryDisplayText {
            Text(text)
                .font(.subheadline).fontWeight(.medium)
        }
    }

    private var primaryDisplayText: String? {
        if let item = corpusItem { return item.wordText }
        if let detail = wordDetail { return detail.text.isEmpty ? nil : detail.text }
        // null-id row: show kanji・kana from BCCWJ
        let k = word.kanji ?? ""
        let r = word.reading ?? ""
        if k.isEmpty && r.isEmpty { return nil }
        if k.isEmpty { return r }
        if r.isEmpty || k == r { return k }
        return "\(k)・\(r)"
    }
}
