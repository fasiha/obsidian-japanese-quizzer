// PlantView.swift
// UI for the "Learn" (planting) flow.
//
// Phase mapping:
//   idle / loading  → spinner
//   introducing     → IntroduceCardView (word heading, senses, kanji toggle, action buttons)
//   awaitingTap     → app-side multiple-choice drill
//   tapFeedback     → correct/incorrect result with "Continue" button
//   allDone         → completion screen
//   noNewWords      → "all caught up" screen
//   error           → error screen
//
// The view is presented as a sheet from VocabBrowserView.

import SwiftUI
import GRDB

struct PlantView: View {
    @Bindable var session: PlantingSession
    let jmdict: any DatabaseReader
    let client: AnthropicClient
    let toolHandler: ToolHandler

    @State private var selectedWordForDetail: VocabItemSelection? = nil

    // The last path component of the document title, used as the navigation title.
    private var shortTitle: String {
        session.documentTitle.components(separatedBy: "/").last ?? session.documentTitle
    }

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle, .loading:
                    loadingView
                case .introducing:
                    if let word = session.currentIntroWord {
                        introduceCardView(word: word)
                    } else {
                        loadingView
                    }
                case .awaitingTap(let mc):
                    drillView(mc: mc)
                case .tapFeedback(let correct, let explanation):
                    feedbackView(correct: correct, explanation: explanation)
                case .allDone:
                    allDoneView
                case .noNewWords:
                    noNewWordsView
                case .error(let msg):
                    errorView(msg)
                }
            }
            .navigationTitle("Learn: \(shortTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedWordForDetail) { selection in
                WordDetailSheet(
                    initialItem: selection.item,
                    db: session.db,
                    client: client,
                    toolHandler: toolHandler,
                    jmdict: jmdict,
                    origin: selection.origin
                )
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Introduce card

    private func introduceCardView(word: VocabItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Progress indicator
                let planted = session.totalToPlant - session.remainingWords.count
                let current = planted + session.batchIntroducedCount + 1
                Text("Word \(current) of \(session.totalToPlant)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Word heading
                VStack(alignment: .leading, spacing: 6) {
                    let displayKana = word.commitment?.committedReading ?? word.kanaTexts.first
                    Text(word.wordText)
                        .font(.largeTitle)
                        .bold()
                    if let kana = displayKana, kana != word.wordText {
                        Text(kana)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Document-scoped senses
                let docSenses = documentScopedSenses(word: word)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(docSenses.enumerated()), id: \.offset) { _, sense in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sense.glosses.joined(separator: "; "))
                                if !sense.partOfSpeech.isEmpty {
                                    Text(sense.partOfSpeech.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                // Sentences from this document that use the word
                let docRefs = word.references[session.documentTitle] ?? []
                let contexts = docRefs.compactMap(\.context)
                if !contexts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In this document")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        ForEach(contexts.indices, id: \.self) { i in
                            SentenceFuriganaView(htmlRuby: stripUnsupportedHtmlTags(contexts[i]))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Divider()

                // Kanji toggle (only when the word has real kanji forms)
                if !word.writtenTexts.isEmpty && !word.isKanaOnly {
                    Toggle(isOn: $session.currentIntroKanjiEnabled) {
                        Label("Learn the kanji spelling too", systemImage: "character.book.closed")
                    }
                    .toggleStyle(.switch)
                    .onChange(of: session.currentIntroKanjiEnabled) { _, enabled in
                        if enabled && session.currentIntroSelectedKanji.isEmpty {
                            // Default: select all kanji in the first written form.
                            let allKanji = introKanjiChars(for: word)
                            session.currentIntroSelectedKanji = Set(allKanji)
                        }
                    }

                    if session.currentIntroKanjiEnabled {
                        kanjiCharPicker(for: word)
                    }
                }

                Divider()

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        selectedWordForDetail = VocabItemSelection(
                            item: word,
                            origin: .document(title: session.documentTitle)
                        )
                    } label: {
                        Label("Explore word", systemImage: "sparkles")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Skip") { session.tapSkip() }
                        .buttonStyle(.bordered)
                        .tint(.secondary)

                    Button("Known") { session.tapKnown() }
                        .buttonStyle(.bordered)
                        .tint(.green)

                    Button("Got it  →") { session.tapGotIt() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    // MARK: - Drill (app-side multiple choice)
    //
    // Visual grammar mirrors QuizView.awaitingTapView (QuizView.swift).
    // Differences that are intentional:
    //   • No uncertainty buttons ("Don't know? / No idea / Inkling") — during planting
    //     the user is still learning, so there is no SRS halflife to hedge against.
    //   • No "Skip →" button — skipping happens on the introduce card, not the drill.
    //   • Progress counter shows "N of M introduced" rather than the SRS queue fraction.

    private func drillView(mc: PlantingMultipleChoice) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Facet badge + progress
                HStack {
                    let planted = session.totalToPlant - session.remainingWords.count
                    let current = planted + session.batchIntroducedCount
                    Text("\(current) of \(session.totalToPlant) introduced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    facetBadge(mc.item.facet)
                }

                // Question stem — boxed background matches QuizView.awaitingTapView.
                Text(mc.stem)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                // Choice buttons — letter badge style matches QuizView.awaitingTapView.
                let letters = ["A", "B", "C", "D"]
                VStack(spacing: 10) {
                    ForEach(Array(mc.choices.enumerated()), id: \.offset) { i, choice in
                        Button {
                            session.tapChoice(i)
                        } label: {
                            HStack(spacing: 12) {
                                Text(letters[i])
                                    .font(.headline)
                                    .frame(width: 28, height: 28)
                                    .background(.tint.opacity(0.15), in: Circle())
                                    .foregroundStyle(.tint)
                                Text(choice)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Tap feedback

    private func feedbackView(correct: Bool, explanation: String) -> some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(correct ? Color.green : Color.red)

            Text(explanation)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Continue") { session.continueAfterFeedback() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Done screens

    private var allDoneView: some View {
        ContentUnavailableView {
            Label("All words planted!", systemImage: "leaf.fill")
        } description: {
            Text("All \(session.totalToPlant) words from \"\(shortTitle)\" are now in your SRS review queue.")
        }
    }

    private var noNewWordsView: some View {
        ContentUnavailableView {
            Label("All caught up!", systemImage: "checkmark.circle.fill")
        } description: {
            Text("Every word in \"\(shortTitle)\" is already in your learning queue.")
        }
    }

    private func errorView(_ msg: String) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(msg)
        }
    }

    // MARK: - Helpers

    /// Senses relevant to this document: union of LLM-inferred sense indices across all
    /// references for the current document title.  Falls back to the first three senses.
    private func documentScopedSenses(word: VocabItem) -> [SenseExtra] {
        let refs = word.references[session.documentTitle] ?? []
        let indices = Array(Set(refs.compactMap(\.llmSense).flatMap(\.senseIndices))).sorted()
        if indices.isEmpty {
            return Array(word.senseExtras.prefix(3))
        }
        return indices.compactMap { i in i < word.senseExtras.count ? word.senseExtras[i] : nil }
    }

    /// All individual kanji characters found in the first written form of a word.
    private func introKanjiChars(for word: VocabItem) -> [String] {
        guard let firstForm = word.writtenForms.flatMap(\.forms).first else { return [] }
        return firstForm.furigana.extractKanji()
    }

    /// Tappable kanji character picker, mirroring the kanji char picker in WordDetailSheet.
    @ViewBuilder
    private func kanjiCharPicker(for word: VocabItem) -> some View {
        let allKanji = introKanjiChars(for: word)
        if !allKanji.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kanji to learn")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                FlowLayout(spacing: 8) {
                    ForEach(allKanji, id: \.self) { kanji in
                        let selected = session.currentIntroSelectedKanji.contains(kanji)
                        let isLastSelected = selected && session.currentIntroSelectedKanji.count == 1
                        Button {
                            var chars = session.currentIntroSelectedKanji
                            if chars.contains(kanji) { chars.remove(kanji) } else { chars.insert(kanji) }
                            session.currentIntroSelectedKanji = chars
                        } label: {
                            Text(kanji)
                                .font(.title2)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selected ? Color.green.opacity(0.2) : Color(.secondarySystemBackground))
                                .foregroundStyle(selected ? .green : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selected ? Color.green : Color.clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isLastSelected)
                    }
                }
            }
        }
    }

    /// Capsule badge showing the facet name — matches facetBadge in QuizView.swift.
    private func facetBadge(_ facet: String) -> some View {
        Text(facet.replacingOccurrences(of: "-", with: " "))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}
