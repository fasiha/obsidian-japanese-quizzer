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
    /// Incremented after each turn so WordDetailSheet can reload mnemonics via .onChange.
    var turnCount: Int = 0

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
                tools: [.lookupJmdict, .lookupKanjidic, .getMnemonic, .setMnemonic],
                maxTokens: 1024,
                toolHandler: { @Sendable name, input in
                    return try await th.handle(toolName: name, input: input)
                },
                chatContext: .wordExplore(wordId: item.id),
                templateId: nil
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
            turnCount += 1
        } catch {
            messages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
        }
        isSending = false
    }

    /// Build system prompt with any existing mnemonics fetched from the DB.
    private func systemPromptWithMnemonics() async -> String {
        let writtenPart = item.writtenTexts.isEmpty
            ? "" : "Written forms: \(item.writtenTexts.joined(separator: ", ")). "
        let kanaStr    = item.kanaTexts.joined(separator: ", ")
        let meaningStr = item.senseExtras.flatMap(\.glosses).prefix(5).joined(separator: "; ")

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
        Be concise. Use lookup_jmdict for accurate details.
        set_mnemonic overwrites — always merge with existing content before saving.
        SRS context: each word has 2–4 facets with Ebisu halflives. Halflives auto-update after quizzes. Manual adjustment: tap the halflife row in the detail screen above this chat.
        """
    }
}
