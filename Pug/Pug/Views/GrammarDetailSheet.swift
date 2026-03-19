// GrammarDetailSheet.swift
// Detail sheet for a grammar topic: shows cross-reference header, descriptions,
// enrollment toggle, and a Claude chat box.
//
// Header: one row per source in the equivalence group (badge + optional JP title + link).
// Descriptions: summary, sub-uses, cautions (from grammar-equivalences.json).
// Actions: enroll/unenroll, Claude chat.

import SwiftUI

struct GrammarDetailSheet: View {
    let topic: GrammarTopic
    let manifest: GrammarManifest
    let db: QuizDB
    let client: AnthropicClient
    let isEnrolled: Bool
    /// Called when enrollment changes; receives the new enrolled state.
    let onEnrollmentChange: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var enrolled: Bool
    @State private var isTogglingEnrollment = false
    @State private var isTryingItOut = false

    // Claude chat (reuses WordExploreSession pattern for simplicity).
    @State private var chatMessages: [(isUser: Bool, text: String)] = []
    @State private var chatInput = ""
    @State private var isSendingChat = false

    init(topic: GrammarTopic, manifest: GrammarManifest, db: QuizDB, client: AnthropicClient,
         isEnrolled: Bool, onEnrollmentChange: @escaping (Bool) -> Void) {
        self.topic = topic
        self.manifest = manifest
        self.db = db
        self.client = client
        self.isEnrolled = isEnrolled
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
                    VStack(alignment: .leading, spacing: 8) {
                        enrollmentSection
                        chatSection
                    }
                }
                .padding()
            }
            .navigationTitle(topic.titleEn)
            .navigationBarTitleDisplayMode(.inline)
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
            if enrolled {
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
            }
        }
    }

    // MARK: - Claude chat

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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

        var messages: [AnthropicMessage] = chatMessages.dropLast().map { msg in
            AnthropicMessage(role: msg.isUser ? "user" : "assistant",
                             content: [.text(msg.text)])
        }
        messages.append(AnthropicMessage(role: "user", content: [.text(userText)]))

        do {
            let (response, _, _) = try await client.send(
                messages: messages,
                system: system,
                tools: [],
                maxTokens: 512,
                toolHandler: nil
            )
            chatMessages.append((isUser: false, text: response))
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
