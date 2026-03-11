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

    /// Called after a `set_mnemonic` tool call succeeds, so the parent view can refresh.
    var onMnemonicSaved: (() -> Void)?

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
            let prompt = await systemPromptWithMnemonics()
            let chatTurnNumber = conversation.filter { $0.role == "user" }.count
            let (response, updatedConversation, meta) = try await client.send(
                messages: conversation,
                system: prompt,
                tools: [.lookupJmdict, .lookupKanjidic, .getVocabContext, .getMnemonic, .setMnemonic],
                maxTokens: 1024,
                toolHandler: { name, input in
                    if name == "get_vocab_context" { return await MainActor.run { self.vocabContextJSON() } }
                    let result = try await th.handle(toolName: name, input: input)
                    if name == "set_mnemonic" { await MainActor.run { self.onMnemonicSaved?() } }
                    return result
                }
            )
            conversation = updatedConversation
            // Log telemetry
            if let db = toolHandler.quizDB {
                let toolsJSON = meta.toolsCalled.isEmpty ? nil :
                    (try? JSONSerialization.data(withJSONObject: meta.toolsCalled)).flatMap { String(data: $0, encoding: .utf8) }
                try? await db.log(apiEvent: ApiEvent(
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    eventType: "word_explore",
                    wordId: item.id, inputTokens: meta.totalInputTokens,
                    outputTokens: meta.totalOutputTokens, chatTurn: chatTurnNumber,
                    model: client.model, toolsCalled: toolsJSON, apiTurns: meta.totalTurns))
            }
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
            guard item.readingState != .unknown || item.kanjiState != .unknown else { continue }
            var entry: [String: Any] = ["text": item.wordText]
            if !item.kanaTexts.isEmpty    { entry["kana"]     = item.kanaTexts }
            if !item.writtenTexts.isEmpty { entry["written"]  = item.writtenTexts }
            if !item.meanings.isEmpty     { entry["meanings"] = Array(item.meanings.prefix(3)) }
            if item.readingState == .learning || item.kanjiState == .learning { learning.append(entry) }
            else                          { known.append(entry) }
        }
        let obj: [String: Any] = ["learning": learning, "known": known]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Build system prompt with any existing mnemonics fetched from the DB.
    private func systemPromptWithMnemonics() async -> String {
        let writtenPart = item.writtenTexts.isEmpty
            ? "" : "Written forms: \(item.writtenTexts.joined(separator: ", ")). "
        let kanaStr    = item.kanaTexts.joined(separator: ", ")
        let meaningStr = item.meanings.prefix(5).joined(separator: "; ")

        // Fetch existing mnemonics
        var mnemonicParts: [String] = []
        if let db = toolHandler.quizDB {
            if let m = try? await db.mnemonic(wordType: "jmdict", wordId: item.id) {
                mnemonicParts.append("Vocab mnemonic: \(m.mnemonic)")
            }
            let kanjiChars = item.writtenTexts.joined()
                .unicodeScalars
                .filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF ||
                          $0.value >= 0x3400 && $0.value <= 0x4DBF ||
                          $0.value >= 0xF900 && $0.value <= 0xFAFF }
                .map { String($0) }
            let uniqueKanji = Array(Set(kanjiChars))
            if !uniqueKanji.isEmpty,
               let kanjiMnemonics = try? await db.mnemonics(wordType: "kanji", wordIds: uniqueKanji),
               !kanjiMnemonics.isEmpty {
                for km in kanjiMnemonics {
                    mnemonicParts.append("Kanji mnemonic for \(km.wordId): \(km.mnemonic)")
                }
            }
        }
        let mnemonicBlock = mnemonicParts.isEmpty ? "" : """

        Mnemonics on file:
        \(mnemonicParts.joined(separator: "\n"))
        """

        return """
        Japanese tutor — free exploration (no quizzing/scoring).
        Word: \(item.wordText) (id \(item.id)). \(writtenPart)Readings: \(kanaStr). Meanings: \(meaningStr)
        \(mnemonicBlock)
        Be concise. Use lookup_jmdict for accurate details. Use get_vocab_context to relate to the learner's other words.
        set_mnemonic overwrites — always merge with existing content before saving.
        SRS context: each word has 2–4 facets with Ebisu halflives. Halflives auto-update after quizzes. Manual adjustment: tap the halflife row in the detail screen above this chat.
        """
    }
}
