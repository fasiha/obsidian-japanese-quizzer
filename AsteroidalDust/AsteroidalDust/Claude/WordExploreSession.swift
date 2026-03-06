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
    private let corpus: VocabCorpus
    private var conversation: [AnthropicMessage] = []

    // MARK: - Init

    init(client: AnthropicClient, toolHandler: ToolHandler, item: VocabItem, corpus: VocabCorpus) {
        self.client      = client
        self.toolHandler = toolHandler
        self.item        = item
        self.corpus      = corpus
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
                tools: [.lookupJmdict, .getVocabContext],
                maxTokens: 1024,
                toolHandler: { [self] name, input in
                    if name == "get_vocab_context" { return await self.vocabContextJSON() }
                    return try await th.handle(toolName: name, input: input)
                }
            )
            conversation = updatedConversation
            messages.append((isUser: false, text: response))
        } catch {
            messages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        isSending = false
    }

    /// Serialize the user's enrolled vocab as JSON for the get_vocab_context tool.
    private func vocabContextJSON() -> String {
        var learning: [[String: Any]] = []
        var known:    [[String: Any]] = []
        for item in corpus.items {
            guard item.status != .notYetLearned else { continue }
            var entry: [String: Any] = ["text": item.wordText]
            if !item.kanaTexts.isEmpty    { entry["kana"]     = item.kanaTexts }
            if !item.writtenTexts.isEmpty { entry["written"]  = item.writtenTexts }
            if !item.meanings.isEmpty     { entry["meanings"] = Array(item.meanings.prefix(3)) }
            if item.status == .learning   { learning.append(entry) }
            else                          { known.append(entry) }
        }
        let obj: [String: Any] = ["learning": learning, "known": known]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
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
        Call get_vocab_context when knowing the learner's other studied words would help
        (e.g. "how does this compare to words I know?", or to point out related words they're already studying).
        Do NOT quiz the learner or assign scores — this is a free exploration session.
        """
    }
}
