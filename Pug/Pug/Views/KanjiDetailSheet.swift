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
    @Environment(\.dismiss) private var dismiss

    @State private var sponsorWords: [VocabItem] = []
    @State private var wordForDetail: VocabItem? = nil
    @State private var isKanjiEnrolled = false

    var body: some View {
        NavigationStack {
            List {
                kanjiHeaderSection
                if !sponsorWords.isEmpty {
                    sponsorWordsSection
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
        .task { await loadSponsorWords() }
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
        Section("Enrolled words using this kanji") {
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

    // MARK: - Data loading

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
