// TransitivePairDetailSheet.swift
// Detail sheet for a transitive-intransitive verb pair.
// Shows both verbs with furigana, part of speech, glosses, example sentences,
// ambiguous reason, Learn/Know/Undo controls, and a Claude chat box.

import SwiftUI
import GRDB

struct TransitivePairDetailSheet: View {
    let initialItem: TransitivePairItem
    let pairCorpus: TransitivePairCorpus
    let db: QuizDB
    let jmdict: any DatabaseReader
    let client: AnthropicClient
    let toolHandler: ToolHandler?

    @Environment(\.dismiss) private var dismiss
    @Environment(VocabCorpus.self) private var vocabCorpus

    /// Live item looked up from corpus — updates reactively when pairCorpus.items changes.
    private var item: TransitivePairItem {
        pairCorpus.items.first { $0.id == initialItem.id } ?? initialItem
    }
    @State private var readerTarget: ReaderTarget? = nil
    @State private var intransitiveSenses: [SenseExtra] = []
    @State private var transitiveSenses: [SenseExtra] = []
    @State private var ebisuModels: [EbisuRecord] = []
    @State private var ebisuReviewCounts: [String: Int] = [:]
    @State private var rescaleRecord: EbisuRecord? = nil
    @State private var mnemonics: [(label: String, text: String)] = []

    // Claude chat state
    @State private var chatMessages: [(isUser: Bool, text: String)] = []
    @State private var chatInput = ""
    @State private var isSendingChat = false
    @State private var chatConversation: [AnthropicMessage] = []


    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Compact two-column summary: verb + examples side-by-side
                    pairSummaryTable

                    // Pattern rules hint (moved below the summary table)
                    if let hint = pairPatternHint {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pattern")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.5)
                            Text(hint)
                                .font(.callout)
                                .foregroundStyle(.teal)
                        }
                    }

                    Divider()

                    // Intransitive verb (example shown in summary table above)
                    verbSection(
                        heading: "Intransitive (自動詞)",
                        member: item.pair.intransitive,
                        furigana: item.intransitiveFurigana,
                        senses: intransitiveSenses,
                        corpusSenseIndices: vocabCorpus.items.first { $0.id == item.pair.intransitive.jmdictId }?.corpusSenseIndices ?? []
                    )

                    Divider()

                    // Transitive verb (example shown in summary table above)
                    verbSection(
                        heading: "Transitive (他動詞)",
                        member: item.pair.transitive,
                        furigana: item.transitiveFurigana,
                        senses: transitiveSenses,
                        corpusSenseIndices: vocabCorpus.items.first { $0.id == item.pair.transitive.jmdictId }?.corpusSenseIndices ?? []
                    )

                    // Ambiguous reason
                    if let reason = item.pair.ambiguousReason {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ambiguity Note")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.5)
                            Text(reason)
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }

                    if !mnemonics.isEmpty {
                        Divider()
                        mnemonicsSection
                    }
                    Divider()
                    actionsSection
                    if !ebisuModels.isEmpty {
                        Divider()
                        ebisuHalflivesSection
                    }
                    Divider()
                    chatSection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Verb Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadJMDictInfo()
                await loadEbisuModels()
                await loadMnemonics()
            }
            .sheet(item: $rescaleRecord) { record in
                RescaleSheet(currentHalflife: record.t, reviewCount: ebisuReviewCounts[record.id]) { hours in
                    Task { await doRescale(record: record, hours: hours) }
                }
            }
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
        }
    }

    // MARK: - Summary table

    /// Summary table: two-column verb header, then alternating left/right drill rows.
    /// Intransitive drills are left-aligned; transitive drills are right-aligned.
    /// Drills are shown here only — not repeated in the glosses section below.
    private var pairSummaryTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Two-column verb header: intransitive left, transitive right
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("自動詞")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase).tracking(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("他動詞")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase).tracking(0.5)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow(alignment: .bottom) {
                    inlineVerb(member: item.pair.intransitive, furigana: item.intransitiveFurigana)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    inlineVerb(member: item.pair.transitive,   furigana: item.transitiveFurigana)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            // Alternating drill rows: intransitive left, transitive right
            if let drills = item.pair.drills, !drills.isEmpty {
                Divider()
                ForEach(Array(drills.enumerated()), id: \.offset) { i, drill in
                    if i > 0 { Divider().padding(.vertical, 2) }

                    // Intransitive — left-aligned
                    VStack(alignment: .leading, spacing: 2) {
                        if let html = drill.intransitive.jaFurigana {
                            SentenceFuriganaView(htmlRuby: html)
                        } else {
                            Text(drill.intransitive.ja).font(.body)
                        }
                        Text(drill.intransitive.en).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Transitive — right-aligned
                    VStack(alignment: .trailing, spacing: 2) {
                        if let html = drill.transitive.jaFurigana {
                            SentenceFuriganaView(htmlRuby: html, trailingAlignment: true)
                        } else {
                            Text(drill.transitive.ja).font(.body)
                        }
                        Text(drill.transitive.en).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Render a verb word with furigana at compact (title2) size for use in the summary table.
    @ViewBuilder
    private func inlineVerb(member: TransitivePairMember, furigana: [FuriganaSegment]?) -> some View {
        if let segs = furigana {
            HStack(spacing: 0) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                    VStack(spacing: 0) {
                        Text(seg.rt ?? " ").font(.caption2).foregroundStyle(.secondary)
                        Text(seg.ruby).font(.title2)
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                Text(" ").font(.caption2)
                Text(member.kanji.first ?? member.kana).font(.title2)
            }
        }
    }

    // MARK: - Pattern hint

    /// Returns human-readable descriptions of all transitive/intransitive patterns that
    /// apply to this pair. Multiple rules can match the same pair (e.g., 壊す/壊れる
    /// matches both the す rule and the れる rule).
    ///   1. まる/める ending → intransitive/transitive
    ///   2. す ending on transitive → always transitive
    ///   3. れる ending on intransitive (the はいる/いれる exception won't trigger this)
    private var pairPatternHint: String? {
        let intr = item.pair.intransitive.kana
        let tr   = item.pair.transitive.kana
        var hints: [String] = []

        // Rule 1: まる/める pair
        if intr.hasSuffix("まる") && tr.hasSuffix("める") {
            hints.append("まる/める pattern: \(intr) is intransitive, \(tr) is transitive.")
        }

        // Rule 2: す is always transitive
        if tr.hasSuffix("す") {
            hints.append("す ending: \(tr) is reliably transitive.")
        }

        // Rule 3: れる on the intransitive side is almost always intransitive.
        // (The only known exception, はいる/いれる, won't trigger this because
        // はいる doesn't end in れる.)
        if intr.hasSuffix("れる") {
            hints.append("れる ending: \(intr) is (almost always) intransitive.")
        }

        return hints.isEmpty ? nil : hints.joined(separator: "\n")
    }

    // MARK: - Mnemonics

    private var mnemonicsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mnemonics")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            ForEach(mnemonics, id: \.label) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(m.text)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func loadMnemonics() async {
        guard let quizDB = toolHandler?.quizDB else { return }
        var results: [(label: String, text: String)] = []
        if let m = try? await quizDB.mnemonic(wordType: "transitive-pair", wordId: item.id) {
            results.append((label: "Pair", text: m.mnemonic))
        }
        let intr = item.pair.intransitive
        let tr = item.pair.transitive
        if let m = try? await quizDB.mnemonic(wordType: "jmdict", wordId: intr.jmdictId) {
            let word = intr.kanji.first ?? intr.kana
            results.append((label: "Intransitive (\(word))", text: m.mnemonic))
        }
        if let m = try? await quizDB.mnemonic(wordType: "jmdict", wordId: tr.jmdictId) {
            let word = tr.kanji.first ?? tr.kana
            results.append((label: "Transitive (\(word))", text: m.mnemonic))
        }
        mnemonics = results
    }

    // MARK: - Claude chat

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Claude")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(Array(chatMessages.enumerated()), id: \.offset) { _, msg in
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

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this pair…", text: $chatInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(isSendingChat)
                if isSendingChat {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 6)
                } else {
                    Button {
                        sendChatMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.bottom, 2)
                }
            }
        }
    }

    private func sendChatMessage() {
        let text = chatInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSendingChat else { return }
        chatInput = ""
        chatMessages.append((isUser: true, text: text))
        isSendingChat = true
        Task { await doChat(userText: text) }
    }

    private func doChat(userText: String) async {
        let intr = item.pair.intransitive
        let tr   = item.pair.transitive
        let intrWord = intr.kanji.first ?? intr.kana
        let trWord   = tr.kanji.first ?? tr.kana

        // Fetch existing mnemonics for context
        var mnemonicParts: [String] = []
        if let db = toolHandler?.quizDB {
            if let m = try? await db.mnemonic(wordType: "transitive-pair", wordId: item.id) {
                mnemonicParts.append("Pair mnemonic: \(m.mnemonic)")
            }
            // Also check individual verb mnemonics
            for (label, member) in [("Intransitive", intr), ("Transitive", tr)] {
                if let m = try? await db.mnemonic(wordType: "jmdict", wordId: member.jmdictId) {
                    mnemonicParts.append("\(label) vocab mnemonic: \(m.mnemonic)")
                }
            }
        }
        let mnemonicBlock = mnemonicParts.isEmpty ? "" : """

        Mnemonics on file:
        \(mnemonicParts.joined(separator: "\n"))
        """

        let system = """
        Japanese tutor — free exploration (no quizzing/scoring).
        The student is looking at a transitive-intransitive verb pair:
        Intransitive (自動詞): \(intrWord) (\(intr.kana)) [JMDict \(intr.jmdictId)]
        Transitive (他動詞): \(trWord) (\(tr.kana)) [JMDict \(tr.jmdictId)]
        \(mnemonicBlock)
        Be concise. Use lookup_jmdict for accurate details.
        set_mnemonic overwrites — always merge with existing content before saving.
        """

        chatConversation.append(AnthropicMessage(role: "user", content: [.text(userText)]))

        let tools: [AnthropicTool] = toolHandler != nil
            ? [.lookupJmdict, .lookupKanjidic, .getMnemonic, .setMnemonic]
            : []
        let th = toolHandler

        do {
            let (response, updatedConversation, _) = try await client.send(
                messages: chatConversation,
                system: system,
                tools: tools,
                maxTokens: 1024,
                toolHandler: th.map { handler in
                    { @Sendable (name: String, input: [String: JSONValue]) async throws -> String in
                        return try await handler.handle(toolName: name, input: input)
                    }
                }
            )
            chatConversation = updatedConversation
            chatMessages.append((isUser: false, text: response))
        } catch {
            chatConversation.removeLast()
            chatMessages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        await loadMnemonics()   // Refresh display if Claude saved a new mnemonic.
        isSendingChat = false
    }

    // MARK: - Verb section

    @ViewBuilder
    private func verbSection(
        heading: String,
        member: TransitivePairMember,
        furigana: [FuriganaSegment]?,
        senses: [SenseExtra],
        corpusSenseIndices: [Int]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            // Furigana heading
            if let segs = furigana {
                headingFurigana(segs)
            } else {
                // Kana-only — show with empty rt row for consistent layout
                VStack(spacing: 0) {
                    Text(" ").font(.caption).foregroundStyle(.secondary)
                    Text(member.kanji.first ?? member.kana)
                        .font(.largeTitle)
                }
            }

            // Alternate kanji forms
            if member.kanji.count > 1 {
                Text("Also: \(member.kanji.dropFirst().joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Senses (shared with WordDetailSheet)
            if !senses.isEmpty {
                JMDictSenseListView(senseExtras: senses, corpusSenseIndices: corpusSenseIndices)
            }
        }
        .textSelection(.enabled)
    }

    /// Render furigana segments at heading size.
    private func headingFurigana(_ segments: [FuriganaSegment]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                VStack(spacing: 0) {
                    Text(seg.rt ?? " ").font(.caption).foregroundStyle(.secondary)
                    Text(seg.ruby).font(.largeTitle)
                }
            }
        }
    }

    // MARK: - Actions (styled like WordDetailSheet)

    @ViewBuilder
    private var actionsSection: some View {
        if item.pair.isAmbiguous {
            Text("Enrollment disabled for ambiguous pairs")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Status")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Picker("Status", selection: Binding(
                    get: { item.state },
                    set: { newState in applyState(newState) }
                )) {
                    Text("Don't know").tag(FacetState.unknown)
                    Text("Learning").tag(FacetState.learning)
                    Text("Known").tag(FacetState.known)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func applyState(_ newState: FacetState) {
        Task {
            switch newState {
            case .unknown:
                await pairCorpus.clearPair(pairId: item.id, db: db)
            case .learning:
                await pairCorpus.setPairLearning(pairId: item.id, db: db)
            case .known:
                await pairCorpus.setPairKnown(pairId: item.id, db: db)
            }
            await loadEbisuModels()
        }
    }

    // MARK: - Halflives

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
                        Text(record.quizType.replacingOccurrences(of: "-", with: " ").capitalized)
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

    private func loadEbisuModels() async {
        if let records = try? await db.ebisuRecords(wordType: "transitive-pair", wordId: item.id) {
            ebisuModels = records
            var counts: [String: Int] = [:]
            for record in records {
                counts[record.id] = (try? await db.reviewCount(
                    wordType: record.wordType, wordId: record.wordId, quizType: record.quizType)) ?? 0
            }
            ebisuReviewCounts = counts
        }
    }

    private func doRescale(record: EbisuRecord, hours: Double) async {
        guard hours > 0 else { return }
        do {
            guard let current = try await db.ebisuRecord(
                wordType: record.wordType, wordId: record.wordId, quizType: record.quizType) else { return }
            let newModel = try rescaleHalflife(current.model, targetHalflife: hours)
            let updated = EbisuRecord(
                wordType: current.wordType, wordId: current.wordId, quizType: current.quizType,
                alpha: newModel.alpha, beta: newModel.beta, t: newModel.t,
                lastReview: current.lastReview
            )
            try await db.upsert(record: updated)
            await loadEbisuModels()
        } catch {
            print("[TransitivePairDetailSheet] doRescale error: \(error)")
        }
    }

    // MARK: - JMDict lookup

    private func loadJMDictInfo() async {
        let ids = [item.pair.intransitive.jmdictId, item.pair.transitive.jmdictId]
        guard let entries = try? await QuizContext.jmdictWordData(ids: ids, jmdict: jmdict) else { return }
        intransitiveSenses = entries[item.pair.intransitive.jmdictId]?.senseExtras ?? []
        transitiveSenses = entries[item.pair.transitive.jmdictId]?.senseExtras ?? []
    }
}
