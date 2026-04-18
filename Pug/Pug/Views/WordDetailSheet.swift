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

/// Where the user navigated from when opening WordDetailSheet.
/// Used to scope sense highlighting to the specific document or line the student was reading,
/// rather than showing the corpus-wide union of all senses.
enum WordDetailOrigin {
    /// Opened from VocabBrowserView: highlight senses used across the whole document.
    case document(title: String)
    /// Opened from DocumentReaderView: highlight senses used on this specific line.
    case reference(title: String, line: Int)
}

struct WordDetailSheet: View {
    let initialItem: VocabItem
    let db: QuizDB
    let client: AnthropicClient
    let toolHandler: ToolHandler?
    let jmdict: any DatabaseReader
    /// Navigation origin: used to scope sense highlighting to the document or line the student
    /// was reading when they opened this sheet. Nil means no specific origin is known.
    var origin: WordDetailOrigin? = nil

    @Environment(VocabCorpus.self) private var corpus
    @Environment(TransitivePairCorpus.self) private var pairCorpus
    @Environment(GrammarStore.self) private var grammarStore
    @Environment(CorpusStore.self) private var corpusStore

    /// Live item looked up from corpus — updates reactively when corpus.items changes.
    /// Falls back to the initial snapshot if the item disappears (e.g. during re-download).
    private var item: VocabItem {
        corpus.items.first { $0.id == initialItem.id } ?? initialItem
    }

    /// Sense indices relevant to where the student navigated from.
    /// Used to highlight which senses are present in the student's current reading context,
    /// independently of which senses they have committed to learning overall.
    private var originSenseIndices: [Int] {
        switch origin {
        case .reference(let title, let line):
            return item.references[title]?
                .first(where: { $0.line == line })?.llmSense?.senseIndices ?? []
        case .document(let title):
            let refs = item.references[title] ?? []
            return Array(Set(refs.compactMap(\.llmSense).flatMap(\.senseIndices))).sorted()
        case .none:
            // No specific navigation origin: fall back to the corpus-wide union so that
            // words with corpus coverage show their attested senses at full brightness.
            // Words with no corpus occurrences at all will have an empty list here too,
            // which correctly dims everything (there is nothing to highlight).
            return item.corpusSenseIndices
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var readerTarget: ReaderTarget? = nil
    @State private var pairDetailItem: TransitivePairItem? = nil
    @State private var isWorking = false
    @State private var explore: WordExploreSession? = nil
    @State private var vocabMnemonic: String? = nil
    @State private var kanjiMnemonics: [(kanji: String, text: String)] = []
    @State private var ebisuModels: [EbisuRecord] = []
    @State private var ebisuReviewCounts: [String: Int] = [:]
    @State private var rescaleTarget: RescaleTarget? = nil

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
                    db: db,
                    client: client,
                    toolHandler: toolHandler,
                    jmdict: jmdict,
                    scrollToLine: target.lineNumber
                )
            }
            .sheet(item: $rescaleTarget) { target in
                RescaleSheet(currentHalflife: target.record.t, reviewCount: target.reviewCount) { hours in
                    Task { await doRescale(record: target.record, hours: hours) }
                }
            }
            .sheet(item: $pairDetailItem) { pairItem in
                TransitivePairDetailSheet(initialItem: pairItem, pairCorpus: pairCorpus,
                                          db: db, jmdict: jmdict,
                                          client: client, toolHandler: toolHandler)
            }
        }
    }

    // MARK: - Word info (always visible)

    private var wordInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Large ruby heading: first written form's furigana, or plain kana
            wordHeading

            // Secondary kana readings, deduplicated across hiragana/katakana variants.
            // Only shown when there is more than one distinct phonetic reading.
            let primaryKana = preferredKanaForm(
                senseExtras: item.senseExtras,
                activeSenseIndices: item.corpusSenseIndices,
                kanaTexts: item.kanaTexts
            ) ?? item.kanaTexts.first
            let secondaryReadings: [String] = {
                var seen: Set<String> = primaryKana.map { [toHiragana($0)] } ?? []
                var result: [String] = []
                for kana in item.kanaTexts {
                    let normalized = toHiragana(kana)
                    if !seen.contains(normalized) {
                        seen.insert(normalized)
                        result.append(kana)
                    }
                }
                return result
            }()
            if !secondaryReadings.isEmpty {
                Text("Also: \(secondaryReadings.joined(separator: ", "))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            senseExtrasSection

            if !item.sources.isEmpty {
                Text(item.sources.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let pairItem = pairCorpus.items.first(where: {
                $0.pair.intransitive.jmdictId == item.id ||
                $0.pair.transitive.jmdictId == item.id
            }) {
                let isIntransitive = pairItem.pair.intransitive.jmdictId == item.id
                let intr = pairItem.pair.intransitive.kanji.first ?? pairItem.pair.intransitive.kana
                let tr   = pairItem.pair.transitive.kanji.first  ?? pairItem.pair.transitive.kana
                infoGroup(heading: isIntransitive ? "Intransitive Verb" : "Transitive Verb") {
                    Button {
                        pairDetailItem = pairItem
                    } label: {
                        Label("\(intr) (intransitive) ↔ \(tr) (transitive)", systemImage: "arrow.left.arrow.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
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
                                        let strippedContext = stripUnsupportedHtmlTags(context)
                                        if let entry = corpusStore.entries.first(where: { $0.title == source }) {
                                            Button {
                                                readerTarget = ReaderTarget(entry: entry, lineNumber: ref.line)
                                            } label: {
                                                SentenceFuriganaView(htmlRuby: strippedContext)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .buttonStyle(.plain)
                                        } else {
                                            SentenceFuriganaView(htmlRuby: strippedContext)
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
        let preferred = preferredWrittenForm(
            senseExtras: item.senseExtras,
            activeSenseIndices: item.corpusSenseIndices,
            writtenForms: item.writtenForms
        )
        let preferredKana = preferredKanaForm(
            senseExtras: item.senseExtras,
            activeSenseIndices: item.corpusSenseIndices,
            kanaTexts: item.kanaTexts
        )
        if item.isKanaOnly {
            // Pure kana — no ruby needed; use the preferred kana form as a plain heading
            Text(preferredKana ?? item.kanaTexts.first ?? item.wordText)
                .font(.largeTitle)
        } else if let form = preferred ?? item.writtenForms.first?.forms.first {
            headingFurigana(form.furigana)
                .textSelection(.disabled)
        } else {
            Text(preferredKana ?? item.kanaTexts.first ?? item.wordText)
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

    /// Per-sense display using the shared JMDictSenseListView.
    /// When the word is in `.learning` state, senses are interactive: the student can tap to
    /// add or remove senses from their enrolled set.
    /// When `.known`, senses are read-only (no checkboxes, just opacity dimming).
    private var senseExtrasSection: some View {
        let isCommitted = item.readingState == .learning
        return JMDictSenseListView(
            senseExtras: item.senseExtras,
            originSenseIndices: originSenseIndices,
            committedSenseIndices: isCommitted ? item.committedSensesForDisplay(totalSenseCount: item.senseExtras.count) : nil,
            writtenTexts: item.writtenTexts,
            kanaTexts: item.kanaTexts,
            onToggleSense: isCommitted ? { index in
                Task { await toggleCommittedSense(index: index) }
            } : nil
        )
    }

    /// Toggle a single sense index in the student's committed set.
    private func toggleCommittedSense(index: Int) async {
        var current = item.committedSensesForDisplay(totalSenseCount: item.senseExtras.count)
        if let pos = current.firstIndex(of: index) {
            current.remove(at: pos)
        } else {
            current.append(index)
            current.sort()
        }
        await corpus.setCommittedSenseIndices(wordId: item.id, senseIndices: current, db: db)
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

            if shouldShowQuickHalflifeChips {
                quickHalflifeChipsSection
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
                    rescaleTarget = RescaleTarget(record: record, reviewCount: ebisuReviewCounts[record.id])
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

    private var shouldShowQuickHalflifeChips: Bool {
        guard !ebisuModels.isEmpty else { return false }
        return ebisuModels.contains { (ebisuReviewCounts[$0.id] ?? 0) == 0 }
    }

    private var quickHalflifeChipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set initial halflife")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(spacing: 8) {
                ForEach([2.0, 4.0, 8.0, 12.0, 16.0], id: \.self) { hours in
                    Button("\(Int(hours))h") {
                        Task { await setAllFacetHalflives(hours: hours) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func setAllFacetHalflives(hours: Double) async {
        for record in ebisuModels {
            await doRescale(record: record, hours: hours)
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
        guard let form = preferredWrittenForm(
            senseExtras: item.senseExtras,
            activeSenseIndices: item.corpusSenseIndices,
            writtenForms: item.writtenForms
        ) ?? item.writtenForms.flatMap(\.forms).first else { return }
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
        // Capture origin senses before the async task so they are seeded into the commitment.
        let seeds = originSenseIndices.isEmpty ? nil : originSenseIndices
        Task {
            await corpus.setReadingState(state, wordId: item.id, db: db, senseIndicesToSeed: seeds)
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
            var counts: [String: Int] = [:]
            for record in records {
                counts[record.id] = (try? await quizDB.reviewCount(
                    wordType: record.wordType, wordId: record.wordId, quizType: record.quizType)) ?? 0
            }
            ebisuReviewCounts = counts
        }
    }

    private func doRescale(record: EbisuRecord, hours: Double) async {
        guard hours > 0, let quizDB = toolHandler?.quizDB else { return }
        do {
            guard let current = try await quizDB.ebisuRecord(
                wordType: record.wordType, wordId: record.wordId, quizType: record.quizType) else { return }
            let newModel = try rescaleHalflife(current.model, targetHalflife: hours)
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

struct FlowLayout: Layout {
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

/// Map each hiragana character to its vowel (あいうえお).
/// Used to resolve chōonpu (ー) to a concrete kana when deduplicating readings.
private let hiraganaVowel: [Character: Character] = [
    // a-vowel
    "あ":"あ","ぁ":"あ","か":"あ","が":"あ","さ":"あ","ざ":"あ","た":"あ","だ":"あ",
    "な":"あ","は":"あ","ば":"あ","ぱ":"あ","ま":"あ","や":"あ","ゃ":"あ","ら":"あ","わ":"あ","ゎ":"あ",
    // i-vowel
    "い":"い","ぃ":"い","き":"い","ぎ":"い","し":"い","じ":"い","ち":"い","ぢ":"い",
    "に":"い","ひ":"い","び":"い","ぴ":"い","み":"い","り":"い","ゐ":"い",
    // u-vowel
    "う":"う","ぅ":"う","く":"う","ぐ":"う","す":"う","ず":"う","つ":"う","づ":"う",
    "ぬ":"う","ふ":"う","ぶ":"う","ぷ":"う","む":"う","ゆ":"う","ゅ":"う","る":"う","ゔ":"う",
    // e-vowel
    "え":"え","ぇ":"え","け":"え","げ":"え","せ":"え","ぜ":"え","て":"え","で":"え",
    "ね":"え","へ":"え","べ":"え","ぺ":"え","め":"え","れ":"え","ゑ":"え",
    // o-row: chōonpu after an o-sound is written う in modern Japanese orthography (とうきょう not とおきょお)
    "お":"う","ぉ":"う","こ":"う","ご":"う","そ":"う","ぞ":"う","と":"う","ど":"う",
    "の":"う","ほ":"う","ぼ":"う","ぽ":"う","も":"う","よ":"う","ょ":"う","ろ":"う","を":"う",
]

/// Convert a string to hiragana for phonetic deduplication of kana readings.
/// Two passes:
///   1. Full-width katakana (ア–ン range) → hiragana by subtracting 0x60.
///   2. Chōonpu (ー, U+30FC) → the vowel of the preceding hiragana character,
///      e.g. ヒューヒュー → ひゅうひゅう (ゅ is a u-vowel, so ー → う).
///      Chōonpu with no resolvable preceding vowel is dropped.
private func toHiragana(_ text: String) -> String {
    // Pass 1: katakana → hiragana
    var pass1 = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if scalar.value >= 0x30A1 && scalar.value <= 0x30F6,
           let h = Unicode.Scalar(scalar.value - 0x60) {
            pass1.append(h)
        } else {
            pass1.append(scalar)
        }
    }
    let hiragana = String(pass1)

    // Pass 2: resolve chōonpu
    let chouonpu: Character = "ー"
    var result: [Character] = []
    for ch in hiragana {
        if ch == chouonpu {
            if let prev = result.last, let vowel = hiraganaVowel[prev] {
                result.append(vowel)
            } else {
                result.append(ch)  // no resolvable vowel — keep chōonpu as-is
            }
        } else {
            result.append(ch)
        }
    }
    return String(result)
}

// SelectableText lives in SelectableText.swift
