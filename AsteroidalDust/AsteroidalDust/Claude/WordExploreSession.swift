// WordExploreSession.swift
// Lightweight Claude chat session for exploring a single word in WordDetailSheet.
// No grading, no Ebisu updates — pure free-form conversation about the word.
// The lookup_jmdict tool is available so Claude can cite dictionary-accurate details.

import Foundation

@Observable @MainActor
final class WordExploreSession {

    // MARK: - State

    var messages: [(isUser: Bool, text: String)] = []
    var input: String = ""
    var isSending: Bool = false

    // MARK: - Dependencies

    private let client: AnthropicClient
    private let toolHandler: ToolHandler
    private let item: VocabItem
    private var conversation: [AnthropicMessage] = []

    // MARK: - Init

    init(client: AnthropicClient, toolHandler: ToolHandler, item: VocabItem) {
        self.client      = client
        self.toolHandler = toolHandler
        self.item        = item
    }

    // MARK: - Public API

    func send() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSending else { return }
        input = ""
        isSending = true
        messages.append((isUser: true, text: text))
        Task { await doTurn(text) }
    }

    // MARK: - Private

    private func doTurn(_ text: String) async {
        conversation.append(AnthropicMessage(role: "user", content: [.text(text)]))
        do {
            let th = toolHandler
            let (response, updatedConversation) = try await client.send(
                messages: conversation,
                system: systemPrompt,
                tools: [.lookupJmdict],
                maxTokens: 1024,
                toolHandler: { name, input in try await th.handle(toolName: name, input: input) }
            )
            conversation = updatedConversation
            messages.append((isUser: false, text: response))
        } catch {
            messages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        isSending = false
    }

    private var systemPrompt: String {
        let writtenPart = item.writtenTexts.isEmpty
            ? "" : "Written forms: \(item.writtenTexts.joined(separator: ", ")). "
        let kanaStr    = item.kanaTexts.joined(separator: ", ")
        let meaningStr = item.meanings.prefix(5).joined(separator: "; ")
        return """
        You are a friendly Japanese tutor helping a learner explore one word in detail.

        Word: \(item.wordText)
        \(writtenPart)Readings: \(kanaStr)
        Meanings: \(meaningStr)

        Answer questions about this word's readings, meanings, kanji breakdown, etymology,
        mnemonics, and connections to other Japanese words. Be concise and conversational.
        Call lookup_jmdict for dictionary-accurate details when needed.
        Do NOT quiz the learner or assign scores — this is a free exploration session.
        """
    }
}
