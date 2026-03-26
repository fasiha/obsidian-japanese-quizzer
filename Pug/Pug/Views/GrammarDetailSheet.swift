// GrammarDetailSheet.swift
// Detail sheet for a grammar topic: shows cross-reference header, descriptions,
// enrollment toggle, and a Claude chat box.
//
// Header: one row per source in the equivalence group (badge + optional JP title + link).
// Descriptions: summary, sub-uses, cautions (from grammar-equivalences.json).
// Actions: enroll/unenroll, Claude chat.

import SwiftUI
import GRDB

struct GrammarDetailSheet: View {
    let topic: GrammarTopic
    let manifest: GrammarManifest
    let db: QuizDB
    let client: AnthropicClient
    let toolHandler: ToolHandler?
    let isEnrolled: Bool
    let corpusEntries: [CorpusEntry]
    let corpus: VocabCorpus
    let jmdict: any DatabaseReader
    /// Called when enrollment changes; receives the new enrolled state.
    let onEnrollmentChange: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var readerTarget: ReaderTarget? = nil
    @State private var enrolled: Bool
    @State private var isTogglingEnrollment = false
    @State private var isTryingItOut = false

    @State private var mnemonic: String? = nil
    @State private var ebisuModels: [EbisuRecord] = []
    @State private var rescaleRecord: EbisuRecord? = nil

    // Claude chat (reuses WordExploreSession pattern for simplicity).
    @State private var chatMessages: [(isUser: Bool, text: String)] = []
    @State private var chatInput = ""
    @State private var isSendingChat = false

    init(topic: GrammarTopic, manifest: GrammarManifest, db: QuizDB, client: AnthropicClient,
         toolHandler: ToolHandler? = nil,
         isEnrolled: Bool, corpusEntries: [CorpusEntry], corpus: VocabCorpus,
         jmdict: any DatabaseReader,
         onEnrollmentChange: @escaping (Bool) -> Void) {
        self.topic = topic
        self.manifest = manifest
        self.db = db
        self.client = client
        self.toolHandler = toolHandler
        self.isEnrolled = isEnrolled
        self.corpusEntries = corpusEntries
        self.corpus = corpus
        self.jmdict = jmdict
        self.onEnrollmentChange = onEnrollmentChange
        self._enrolled = State(initialValue: isEnrolled)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    if topic.summary != nil || topic.subUses != nil || topic.cautions != nil {
                        descriptionSection
                    }
                    sourcesFooter
                    corpusContextsSection
                    if let m = mnemonic {
                        mnemonicSection(m)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        enrollmentSection
                        if !ebisuModels.isEmpty {
                            ebisuHalflivesSection
                        }
                        chatSection
                    }
                }
                .padding()
            }
            .navigationTitle(topic.titleEn)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadMnemonic()
                await loadEbisuModels()
            }
            .sheet(item: $rescaleRecord) { record in
                RescaleSheet(currentHalflife: record.t) { hours in
                    Task { await doRescale(record: record, hours: hours) }
                }
            }
            .navigationDestination(item: $readerTarget) { target in
                DocumentReaderView(
                    entry: target.entry,
                    allEntries: corpusEntries,
                    corpus: corpus,
                    grammarManifest: manifest,
                    db: db,
                    client: client,
                    toolHandler: toolHandler,
                    jmdict: jmdict,
                    scrollToLine: target.lineNumber
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    /// One row per source in the equivalence group (including this topic itself).
    /// Each row: source badge | optional JP title | link (if any).
    private var headerSection: some View {
        let siblingTopics = (topic.equivalenceGroup ?? []).compactMap { manifest.topics[$0] }
        let allTopics = [topic] + siblingTopics

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(allTopics, id: \.prefixedId) { t in
                HStack(spacing: 8) {
                    sourceBadge(t.source)
                    if let jp = t.titleJp, !jp.isEmpty {
                        Text(jp).font(.body)
                    }
                    if let href = t.href, let url = URL(string: href) {
                        Link(t.titleEn, destination: url)
                            .font(.body)
                    }
                    if topic.isStub == true && t.prefixedId == topic.prefixedId {
                        Text("stub")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = topic.summary {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overview")
                        .font(.headline)
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            if let subUses = topic.subUses, !subUses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sub-uses")
                        .font(.headline)
                    ForEach(subUses, id: \.self) { use in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            SelectableText(use)
                                .font(.body)
                        }
                    }
                }
            }

            if let cautions = topic.cautions, !cautions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cautions")
                        .font(.headline)
                    ForEach(cautions, id: \.self) { caution in
                        HStack(alignment: .top, spacing: 8) {
                            Text("⚠️")
                            SelectableText(caution)
                                .font(.body)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sources footer

    @ViewBuilder
    private var sourcesFooter: some View {
        let allSources = ([topic] + (topic.equivalenceGroup ?? []).compactMap { manifest.topics[$0] })
            .flatMap(\.sources)
            .removingDuplicates()
        if !allSources.isEmpty {
            Text(allSources.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Corpus contexts

    /// Sentences from the reading corpus where this grammar point (or any sibling in its
    /// equivalence group) appears, grouped by source title.
    @ViewBuilder
    private var corpusContextsSection: some View {
        let allRefs = ([topic] + (topic.equivalenceGroup ?? []).compactMap { manifest.topics[$0] })
            .compactMap(\.references)
            .flatMap { $0 }
            .reduce(into: [String: [VocabReference]]()) { acc, pair in
                acc[pair.key, default: []].append(contentsOf: pair.value)
            }
        if !allRefs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Corpus Contexts")
                    .font(.headline)
                ForEach(allRefs.keys.sorted(), id: \.self) { source in
                    if let refs = allRefs[source] {
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
    }

    // MARK: - Enrollment

    private var enrollmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text(enrolled ? "Currently learning" : "Not yet learning")
                    .font(.headline)
                Spacer()
                if isTogglingEnrollment {
                    ProgressView()
                } else {
                    Button(enrolled ? "Stop learning" : "Start learning") {
                        Task { await toggleEnrollment() }
                    }
                    .buttonStyle(.bordered)
                    .tint(enrolled ? .red : .accentColor)
                }
            }
        }
    }

    // MARK: - Mnemonic

    @ViewBuilder
    private func mnemonicSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mnemonic")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(text)
        }
        .textSelection(.enabled)
    }

    private func loadMnemonic() async {
        guard let quizDB = toolHandler?.quizDB else { return }
        let allIds = ([topic.prefixedId] + (topic.equivalenceGroup ?? [])).removingDuplicates()
        for id in allIds {
            if let m = try? await quizDB.mnemonic(wordType: "grammar", wordId: id) {
                mnemonic = m.mnemonic
                return
            }
        }
    }

    // MARK: - Halflives

    private var ebisuHalflivesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
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
        if let records = try? await db.ebisuRecords(wordType: "grammar", wordId: topic.prefixedId) {
            ebisuModels = records.sorted { $0.quizType < $1.quizType }
        }
    }

    private func doRescale(record: EbisuRecord, hours: Double) async {
        guard hours > 0 else { return }
        do {
            guard let current = try await db.ebisuRecord(
                wordType: record.wordType, wordId: record.wordId, quizType: record.quizType) else { return }
            let scale = hours / current.t
            let newModel = try rescaleHalflife(current.model, scale: scale)
            let updated = EbisuRecord(
                wordType: current.wordType, wordId: current.wordId, quizType: current.quizType,
                alpha: newModel.alpha, beta: newModel.beta, t: newModel.t,
                lastReview: current.lastReview
            )
            try await db.upsert(record: updated)
            await loadEbisuModels()
        } catch {
            print("[GrammarDetailSheet] doRescale error: \(error)")
        }
    }

    // MARK: - Claude chat

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("See an example")
                    .font(.headline)
                Spacer()
                if isTryingItOut {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Try it out") {
                    Task { await tryItOut() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTryingItOut)
            }

            Divider()
            Text("Ask Claude about this grammar")
                .font(.headline)

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
                TextField("Ask anything…", text: $chatInput, axis: .vertical)
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

    // MARK: - Actions

    private func toggleEnrollment() async {
        isTogglingEnrollment = true
        let groupIds = topic.equivalenceGroup ?? []
        do {
            if enrolled {
                try await db.unenrollGrammarTopic(topicId: topic.prefixedId, equivalenceGroupIds: groupIds)
                enrolled = false
            } else {
                try await db.enrollGrammarTopic(topicId: topic.prefixedId, equivalenceGroupIds: groupIds)
                enrolled = true
            }
            onEnrollmentChange(enrolled)
        } catch {
            print("[GrammarDetailSheet] enrollment toggle error: \(error)")
        }
        isTogglingEnrollment = false
    }

    private func tryItOut() async {
        guard !isTryingItOut else { return }
        isTryingItOut = true
        var system = """
        You are a Japanese grammar tutor helping a student explore the following grammar point:
        Topic: \(topic.prefixedId) — \(topic.titleEn)
        Level: \(topic.level) | Source: \(topic.source)
        """
        if let summary = topic.summary { system += "\nDescription: \(summary)" }
        if let subUses = topic.subUses, !subUses.isEmpty {
            system += "\nSub-uses:\n" + subUses.map { "- \($0)" }.joined(separator: "\n")
        }
        if let cautions = topic.cautions, !cautions.isEmpty {
            system += "\nCautions:\n" + cautions.map { "- \($0)" }.joined(separator: "\n")
        }
        let request = """
        Give me one example of \(topic.titleEn) in use.
        Write one or two English sentences describing a concrete, specific scenario — \
        something happening to a real person in a real setting. Then write the complete \
        Japanese sentence that expresses that scenario using the target grammar. \
        Keep it natural. The student may ask follow-up questions afterward.
        """
        do {
            let (response, _, _) = try await client.send(
                messages: [AnthropicMessage(role: "user", content: [.text(request)])],
                system: system,
                tools: [],
                maxTokens: 256,
                toolHandler: nil
            )
            chatMessages.append((isUser: false, text: response))
        } catch {
            chatMessages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        isTryingItOut = false
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
        var system = """
        You are a Japanese grammar tutor. The student is asking about the following grammar point:
        Topic: \(topic.prefixedId) — \(topic.titleEn)
        Level: \(topic.level) | Source: \(topic.source)
        """
        if let summary = topic.summary { system += "\nDescription: \(summary)" }
        if let subUses = topic.subUses, !subUses.isEmpty {
            system += "\nSub-uses:\n" + subUses.map { "- \($0)" }.joined(separator: "\n")
        }
        if let cautions = topic.cautions, !cautions.isEmpty {
            system += "\nCautions:\n" + cautions.map { "- \($0)" }.joined(separator: "\n")
        }
        system += "\nAnswer the student's question concisely and helpfully."
        system += "\nWhen calling get_mnemonic or set_mnemonic, use word_type='grammar' and word_id='\(topic.prefixedId)'."

        // Inject any saved mnemonic for this topic (re-fetch in case it was just saved).
        let allIds = ([topic.prefixedId] + (topic.equivalenceGroup ?? [])).removingDuplicates()
        if let quizDB = toolHandler?.quizDB {
            var freshMnemonic: String? = nil
            for id in allIds {
                if let m = try? await quizDB.mnemonic(wordType: "grammar", wordId: id) {
                    freshMnemonic = m.mnemonic
                    break
                }
            }
            if let m = freshMnemonic {
                system += "\n\nMnemonic on file: \(m)"
                system += "\nYou have get_mnemonic and set_mnemonic tools. Always call get_mnemonic before set_mnemonic so you can see what is already stored and merge new content rather than replacing it wholesale."
            } else {
                system += "\n\nNo mnemonic on file yet. You have get_mnemonic and set_mnemonic tools to read and save one if it would help the student."
            }
        }

        var messages: [AnthropicMessage] = chatMessages.dropLast().map { msg in
            AnthropicMessage(role: msg.isUser ? "user" : "assistant",
                             content: [.text(msg.text)])
        }
        messages.append(AnthropicMessage(role: "user", content: [.text(userText)]))

        let tools: [AnthropicTool] = toolHandler != nil ? [.getMnemonic, .setMnemonic] : []
        let handler = toolHandler.map { th in
            { @Sendable (name: String, input: [String: JSONValue]) async throws -> String in
                if name == "set_mnemonic",
                   case .string("grammar")? = input["word_type"],
                   case .string(let wid)? = input["word_id"],
                   case .string(let text)? = input["mnemonic"] {
                    let targetIds = allIds.isEmpty ? [wid] : allIds
                    var primaryResult = #"{"ok":true}"#
                    for (index, id) in targetIds.enumerated() {
                        let result = try await th.handle(
                            toolName: "set_mnemonic",
                            input: ["word_type": .string("grammar"),
                                    "word_id": .string(id),
                                    "mnemonic": .string(text)])
                        if index == 0 { primaryResult = result }
                    }
                    return primaryResult
                }
                if name == "get_mnemonic",
                   case .string("grammar")? = input["word_type"] {
                    for id in allIds {
                        let result = try await th.handle(
                            toolName: "get_mnemonic",
                            input: ["word_type": .string("grammar"), "word_id": .string(id)])
                        if !result.contains("\"mnemonic\":null") && !result.contains("\"error\"") {
                            return result
                        }
                    }
                    return #"{"mnemonic":null}"#
                }
                return try await th.handle(toolName: name, input: input)
            }
        }
        do {
            let (response, _, _) = try await client.send(
                messages: messages,
                system: system,
                tools: tools,
                maxTokens: 512,
                toolHandler: handler
            )
            chatMessages.append((isUser: false, text: response))
            await loadMnemonic()   // Refresh display if Claude saved a new mnemonic.
        } catch {
            chatMessages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        isSendingChat = false
    }

    // MARK: - Badges

    private func sourceBadge(_ source: String) -> some View {
        Text(source)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.12), in: Capsule())
            .foregroundStyle(.tint)
    }
}
