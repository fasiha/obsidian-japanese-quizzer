// WordDetailSheet.swift
// Unified word detail / learning-commitment sheet.
//
// Shown in two situations:
//   1. Tapping any row in VocabBrowserView (detail mode)
//   2. Swiping "Learn" on a not-yet-learned word (also detail mode — same view)
//
// The word-info section (kanji forms, readings, meanings) is always visible and scrollable.
// The action section varies by the word's current status.
// A Claude chat section at the bottom lets the user explore the word before committing.
//
// Future additions for learning words: review history (reviews.notes).

import SwiftUI
import GRDB

struct WordDetailSheet: View {
    let initialItem: VocabItem
    let corpus: VocabCorpus
    let db: QuizDB
    let client: AnthropicClient
    let toolHandler: ToolHandler?
    let jmdict: any DatabaseReader
    let corpusEntries: [CorpusEntry]
    let grammarManifest: GrammarManifest?

    /// Live item looked up from corpus — updates reactively when corpus.items changes.
    /// Falls back to the initial snapshot if the item disappears (e.g. during re-download).
    private var item: VocabItem {
        corpus.items.first { $0.id == initialItem.id } ?? initialItem
    }

    @Environment(\.dismiss) private var dismiss
    @State private var readerTarget: ReaderTarget? = nil
    @State private var isWorking = false
    @State private var explore: WordExploreSession? = nil
    @State private var vocabMnemonic: String? = nil
    @State private var kanjiMnemonics: [(kanji: String, text: String)] = []
    @State private var ebisuModels: [EbisuRecord] = []
    @State private var rescaleRecord: EbisuRecord? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    wordInfoSection
                    Divider()
                    actionsSection
                    Divider()
                    exploreChatSection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .disabled(isWorking)
            .overlay {
                if isWorking { ProgressView() }
            }
            .onAppear {
                if let th = toolHandler {
                    explore = WordExploreSession(client: client, toolHandler: th, item: item, corpus: corpus)
                }
                Task { await loadMnemonics() }
                Task { await loadEbisuModels() }
                Task { await autoCommitFirstForm() }
            }
            .onChange(of: explore?.turnCount) { Task { await loadMnemonics() } }
            .navigationDestination(item: $readerTarget) { target in
                DocumentReaderView(
                    entry: target.entry,
                    allEntries: corpusEntries,
                    corpus: corpus,
                    grammarManifest: grammarManifest,
                    db: db,
                    client: client,
                    toolHandler: toolHandler,
                    jmdict: jmdict,
                    scrollToLine: target.lineNumber
                )
            }
            .sheet(item: $rescaleRecord) { record in
                RescaleSheet(currentHalflife: record.t) { hours in
                    Task { await doRescale(record: record, hours: hours) }
                }
            }
        }
    }

    // MARK: - Word info (always visible)

    private var wordInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Large ruby heading: first written form's furigana, or plain kana
            wordHeading

            senseExtrasSection

            if !item.sources.isEmpty {
                Text(item.sources.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !item.references.isEmpty {
                infoGroup(heading: "Usage Examples", hint: "tap to open in reader") {
                    ForEach(item.references.keys.sorted(), id: \.self) { source in
                        if let refs = item.references[source] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(refs.indices, id: \.self) { i in
                                    let ref = refs[i]
                                    if let context = ref.context {
                                        if let entry = corpusEntries.first(where: { $0.title == source }) {
                                            Button {
                                                readerTarget = ReaderTarget(entry: entry, lineNumber: ref.line)
                                            } label: {
                                                SentenceFuriganaView(htmlRuby: context)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .buttonStyle(.plain)
                                        } else {
                                            SentenceFuriganaView(htmlRuby: context)
                                        }
                                    }
                                    if let narration = ref.narration {
                                        Text(narration)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if vocabMnemonic != nil || !kanjiMnemonics.isEmpty {
                infoGroup(heading: "Mnemonics") {
                    if let vm = vocabMnemonic {
                        Text(vm)
                    }
                    ForEach(kanjiMnemonics, id: \.kanji) { km in
                        Text("\(km.kanji): \(km.text)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Large ruby furigana heading from the first written form, or plain kana for kana-only words.
    @ViewBuilder
    private var wordHeading: some View {
        if item.isKanaOnly {
            // Pure kana — no ruby needed; use the first kana form as a plain heading
            Text(item.writtenForms.first?.forms.first?.furigana.map(\.ruby).joined()
                 ?? item.kanaTexts.first ?? item.wordText)
                .font(.largeTitle)
        } else if let group = item.writtenForms.first, let form = group.forms.first {
            headingFurigana(form.furigana)
                .textSelection(.disabled)
        } else {
            Text(item.kanaTexts.first ?? item.wordText)
                .font(.largeTitle)
        }
    }

    /// Render furigana segments at heading size.
    private func headingFurigana(_ segments: [FuriganaSegment]) -> some View {
        let baseText = segments.map(\.ruby).joined()
        return HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                if let rt = seg.rt {
                    VStack(spacing: 0) {
                        Text(rt).font(.caption).foregroundStyle(.secondary)
                        Text(seg.ruby).font(.largeTitle)
                    }
                } else {
                    Text(seg.ruby).font(.largeTitle)
                        .padding(.top, 16) // align with kanji that have rt above
                }
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = baseText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    /// Per-sense display: each sense's glosses followed immediately by its own metadata.
    /// This keeps usage notes, cross-references, and tags tied to the definition they apply to.
    ///
    /// When the word has enrolled senses (from llm_sense.sense_indices), the list is wrapped
    /// in a labeled group and non-enrolled senses are dimmed to show the student which senses
    /// the quiz is using.
    @ViewBuilder
    private var senseExtrasSection: some View {
        // Part of speech is shared across senses (JMDict convention: repeated on each sense,
        // but effectively describes the word). Deduplicate and show once at the top.
        let allPos = Array(NSOrderedSet(array: item.senseExtras.flatMap(\.partOfSpeech))) as? [String] ?? []
        if !allPos.isEmpty {
            Text(allPos.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        let enrolled = item.enrolledSenseIndices
        let useLabel = !enrolled.isEmpty

        let senseList = ForEach(Array(item.senseExtras.enumerated()), id: \.offset) { index, sense in
            VStack(alignment: .leading, spacing: 2) {
                // Glosses for this sense
                ForEach(sense.glosses, id: \.self) { gloss in
                    Text("• \(gloss)")
                }

                // Metadata that applies only to this sense
                if !sense.metadataIsEmpty {
                    let tags = (sense.misc + sense.field + sense.dialect).joined(separator: ", ")
                    Group {
                        if !tags.isEmpty {
                            Text(tags).italic()
                        }
                        ForEach(sense.info, id: \.self) { note in
                            Text(note).italic()
                        }
                        if !sense.related.isEmpty {
                            Text("Related: \(SenseExtra.formatXrefs(sense.related))")
                        }
                        if !sense.antonym.isEmpty {
                            Text("Antonym: \(SenseExtra.formatXrefs(sense.antonym))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .opacity(useLabel && !enrolled.contains(index) ? 0.4 : 1.0)
        }

        if useLabel {
            infoGroup(heading: "Senses used in quizzes") {
                senseList
            }
        } else {
            senseList
        }
    }

    @ViewBuilder
    private func infoGroup<Content: View>(heading: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(heading)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                if let hint {
                    Spacer()
                    Label(hint, systemImage: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }

    // MARK: - Actions (furigana picker + reading/kanji state controls)

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if item.isKanaOnly {
                // Kana-only words: show variants informally, then reading control immediately
                if item.writtenForms.flatMap(\.forms).count > 1 {
                    kanaVariantsSection
                }
                readingStateControl
            } else {
                // Words with kanji: always show the reading control.
                // If there are multiple forms, show the furigana picker above it so
                // the user can change their committed form at any time.
                // Auto-commit to the first form happens in onAppear.
                let allForms = item.writtenForms.flatMap(\.forms)
                if allForms.count > 1 && !item.writtenForms.isEmpty {
                    furiganaPickerSection
                }
                readingStateControl
            }

            // Kanji state control (only if word has kanji and reading is not unknown)
            if item.hasKanjiOptions && item.readingState != .unknown {
                kanjiStateControl
            }

            // Kanji character picker (only when kanji = learning)
            if item.kanjiState == .learning {
                kanjiCharPicker
            }

            if !ebisuModels.isEmpty {
                ebisuHalflivesSection
            }

            Divider()

            // Quick actions
            Button {
                markAllKnown()
            } label: {
                Label("I know this word", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)

            if item.readingState != .unknown || item.kanjiState != .unknown {
                Button(role: .destructive) {
                    clearAll()
                } label: {
                    Label("Reset (forget all)", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Kana variants (informational, no selection)

    private var kanaVariantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spellings")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            FlowLayout(spacing: 12) {
                ForEach(item.writtenForms.flatMap(\.forms), id: \.text) { form in
                    Text(form.furigana.map(\.ruby).joined())
                        .font(.title3)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: - Furigana picker

    @ViewBuilder
    private var furiganaPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Written form")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(item.writtenForms, id: \.reading) { group in
                ForEach(group.forms, id: \.text) { form in
                    let isSelected = isCommittedForm(form)
                    Button {
                        selectForm(form)
                    } label: {
                        HStack {
                            furiganaText(form.furigana)
                            Spacer()
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(isSelected ? .green : .secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .opacity(item.commitment != nil && !isSelected ? 0.4 : 1.0)
                }
            }
            // Kana-only readings (no kanji forms)
            ForEach(item.writtenForms.filter { $0.forms.isEmpty }, id: \.reading) { group in
                HStack {
                    Text(group.reading).font(.title3)
                    Spacer()
                    Image(systemName: item.commitment != nil ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(item.commitment != nil ? .green : .secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Reading state control

    private var readingStateControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reading")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Picker("Reading", selection: Binding(
                get: { item.readingState },
                set: { newState in setReadingState(newState) }
            )) {
                Text("Don't know").tag(FacetState.unknown)
                Text("Learning").tag(FacetState.learning)
                Text("Known").tag(FacetState.known)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Kanji state control

    private var kanjiStateControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kanji")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Picker("Kanji", selection: Binding(
                get: { item.kanjiState },
                set: { newState in setKanjiState(newState) }
            )) {
                Text("Don't know").tag(FacetState.unknown)
                Text("Learning").tag(FacetState.learning)
                // Known only available if reading is known
                if item.readingState == .known {
                    Text("Known").tag(FacetState.known)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Kanji character picker

    private var kanjiCharPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kanji to learn")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            let allKanji = extractKanjiFromCommitment()
            FlowLayout(spacing: 8) {
                ForEach(allKanji, id: \.self) { kanji in
                    let selected = selectedKanjiChars.contains(kanji)
                    let isLastSelected = selected && selectedKanjiChars.count == 1
                    Button {
                        toggleKanjiChar(kanji)
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

    // MARK: - Ebisu halflives table

    private var ebisuHalflivesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Halflives")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(ebisuModels) { record in
                Button {
                    rescaleRecord = record
                } label: {
                    HStack {
                        Text(facetDisplayName(record.quizType))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(formatDuration(record.t))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func facetDisplayName(_ quizType: String) -> String {
        switch quizType {
        case "reading-to-meaning":      return "Reading → Meaning"
        case "meaning-to-reading":      return "Meaning → Reading"
        case "kanji-to-reading":        return "Kanji → Reading"
        case "meaning-reading-to-kanji": return "Meaning+Reading → Kanji"
        default: return quizType
        }
    }

    // MARK: - Claude explore chat

    private var exploreChatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask Claude")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            if let explore {
                // Chat bubbles
                ForEach(Array(explore.messages.enumerated()), id: \.offset) { _, msg in
                    HStack(alignment: .top) {
                        if msg.isUser { Spacer(minLength: 40) }
                        SelectableText(msg.text)
                            .padding(10)
                            .background(
                                msg.isUser
                                    ? Color.accentColor.opacity(0.15)
                                    : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        if !msg.isUser { Spacer(minLength: 40) }
                    }
                }

                // Input row
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask about readings, kanji, mnemonics…",
                              text: Binding(
                                get: { explore.input },
                                set: { explore.input = $0 }
                              ),
                              axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(explore.isSending)

                    if explore.isSending {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.bottom, 6)
                    } else {
                        Button {
                            explore.send()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(explore.input.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.bottom, 2)
                    }
                }
            }
        }
    }

    // MARK: - Action implementations

    private var selectedKanjiChars: Set<String> {
        guard let json = item.commitment?.kanjiChars,
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(arr)
    }

    private func isCommittedForm(_ form: WrittenForm) -> Bool {
        guard let json = item.commitment?.furigana,
              let data = json.data(using: .utf8),
              let committed = try? JSONDecoder().decode([FuriganaSegment].self, from: data)
        else { return false }
        // Compare by matching ruby/rt pairs
        guard committed.count == form.furigana.count else { return false }
        return zip(committed, form.furigana).allSatisfy { $0.ruby == $1.ruby && $0.rt == $1.rt }
    }

    /// Silently commits the first available written form on first open,
    /// so the user can immediately start learning reading and kanji without
    /// having to pick a form first. The user can change the committed form
    /// later via the written form picker.
    private func autoCommitFirstForm() async {
        guard item.commitment == nil else { return }
        guard let form = item.writtenForms.flatMap(\.forms).first else { return }
        if let data = try? JSONEncoder().encode(form.furigana),
           let json = String(data: data, encoding: .utf8) {
            await corpus.setCommittedFurigana(wordId: item.id, furiganaJSON: json, db: db)
        }
    }

    private func selectForm(_ form: WrittenForm) {
        isWorking = true
        Task {
            if let data = try? JSONEncoder().encode(form.furigana),
               let json = String(data: data, encoding: .utf8) {
                await corpus.setCommittedFurigana(wordId: item.id, furiganaJSON: json, db: db)
            }
            // If kanji is being learned, reset kanji_chars to all kanji in the new form
            // so we don't inherit stale chars from the previously committed form.
            if item.kanjiState == .learning {
                let newKanji = form.furigana.extractKanji()
                await corpus.setKanjiState(.learning, wordId: item.id, kanjiChars: newKanji, db: db)
                await loadEbisuModels()
            }
            isWorking = false
        }
    }

    private func setReadingState(_ state: FacetState) {
        isWorking = true
        Task {
            await corpus.setReadingState(state, wordId: item.id, db: db)
            await loadEbisuModels()
            isWorking = false
        }
    }

    private func setKanjiState(_ state: FacetState) {
        isWorking = true
        Task {
            let chars = state == .learning
                ? (selectedKanjiChars.isEmpty ? extractKanjiFromCommitment() : Array(selectedKanjiChars))
                : nil
            await corpus.setKanjiState(state, wordId: item.id, kanjiChars: chars, db: db)
            await loadEbisuModels()
            isWorking = false
        }
    }

    private func toggleKanjiChar(_ kanji: String) {
        var current = selectedKanjiChars
        if current.contains(kanji) { current.remove(kanji) } else { current.insert(kanji) }
        isWorking = true
        Task {
            await corpus.setKanjiState(.learning, wordId: item.id,
                                        kanjiChars: Array(current), db: db)
            await loadEbisuModels()
            isWorking = false
        }
    }

    private func extractKanjiFromCommitment() -> [String] {
        guard let json = item.commitment?.furigana,
              let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([FuriganaSegment].self, from: data)
        else { return [] }
        return segments.extractKanji()
    }

    private func markAllKnown() {
        isWorking = true
        Task {
            await corpus.markAllKnown(wordId: item.id, db: db)
            isWorking = false
            dismiss()
        }
    }

    private func clearAll() {
        isWorking = true
        Task {
            await corpus.clearAll(wordId: item.id, db: db)
            isWorking = false
            dismiss()
        }
    }

    private func loadEbisuModels() async {
        guard let quizDB = toolHandler?.quizDB else { return }
        if let records = try? await quizDB.ebisuRecords(wordType: "jmdict", wordId: item.id) {
            let order = ["reading-to-meaning", "meaning-to-reading", "kanji-to-reading", "meaning-reading-to-kanji"]
            ebisuModels = records.sorted {
                (order.firstIndex(of: $0.quizType) ?? 99) < (order.firstIndex(of: $1.quizType) ?? 99)
            }
        }
    }

    // TODO: near-duplicate of QuizSession.rescaleCurrentFacet — consider extracting to QuizDB
    private func doRescale(record: EbisuRecord, hours: Double) async {
        guard hours > 0, let quizDB = toolHandler?.quizDB else { return }
        do {
            guard let current = try await quizDB.ebisuRecord(
                wordType: record.wordType, wordId: record.wordId, quizType: record.quizType) else { return }
            let scale = hours / current.t
            let newModel = try rescaleHalflife(current.model, scale: scale)
            let updated = EbisuRecord(
                wordType: current.wordType, wordId: current.wordId, quizType: current.quizType,
                alpha: newModel.alpha, beta: newModel.beta, t: newModel.t,
                lastReview: current.lastReview
            )
            try await quizDB.upsert(record: updated)
            let event = ModelEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                wordType: current.wordType, wordId: current.wordId, quizType: current.quizType,
                event: "rescaled,\(current.t),\(newModel.t)"
            )
            try await quizDB.log(event: event)
            await loadEbisuModels()
        } catch {
            print("[WordDetailSheet] doRescale error: \(error)")
        }
    }

    private func loadMnemonics() async {
        guard let quizDB = toolHandler?.quizDB else { return }
        if let m = try? await quizDB.mnemonic(wordType: "jmdict", wordId: item.id) {
            vocabMnemonic = m.mnemonic
        }
        let kanjiChars = item.writtenTexts.joined()
            .unicodeScalars
            .filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF ||
                      $0.value >= 0x3400 && $0.value <= 0x4DBF ||
                      $0.value >= 0xF900 && $0.value <= 0xFAFF }
            .map { String($0) }
        let uniqueKanji = Array(Set(kanjiChars))
        if !uniqueKanji.isEmpty,
           let kms = try? await quizDB.mnemonics(wordType: "kanji", wordIds: uniqueKanji) {
            kanjiMnemonics = kms.map { (kanji: $0.wordId, text: $0.mnemonic) }
        }
    }

    /// Render furigana segments as Text with ruby-style annotation.
    private func furiganaText(_ segments: [FuriganaSegment]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                if let rt = seg.rt {
                    VStack(spacing: 0) {
                        Text(rt).font(.caption2).foregroundStyle(.secondary)
                        Text(seg.ruby).font(.title2)
                    }
                } else {
                    Text(seg.ruby).font(.title2)
                        .padding(.top, 14) // align with kanji that have rt above
                }
            }
        }
    }
}

// MARK: - FlowLayout (for kanji character picker)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// SelectableText lives in SelectableText.swift
