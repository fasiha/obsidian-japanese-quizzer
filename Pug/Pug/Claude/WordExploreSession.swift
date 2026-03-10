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
            let (response, updatedConversation) = try await client.send(
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
        You are a friendly Japanese tutor helping a learner explore one word in detail.

        Word: \(item.wordText) (JMDict id: \(item.id))
        \(writtenPart)Readings: \(kanaStr)
        Meanings: \(meaningStr)
        \(mnemonicBlock)
        Answer questions about this word's readings, meanings, kanji breakdown, etymology,
        mnemonics, and connections to other Japanese words. Be concise and conversational.
        Call lookup_jmdict for dictionary-accurate details when needed.
        Call get_vocab_context when knowing the learner's other studied words would help
        (e.g. "how does this compare to words I know?", or to point out related words they're already studying).
        When the learner crafts or accepts a mnemonic, save it via set_mnemonic (word_type "jmdict" for
        vocab words, "kanji" for individual kanji characters). Call get_mnemonic to check for existing
        mnemonics about other words or kanji.
        IMPORTANT: set_mnemonic overwrites the entire mnemonic. Before saving, review the existing mnemonic
        (shown above under "Mnemonics on file" or via get_mnemonic) and merge new content into it —
        never silently discard prior mnemonic text. The mnemonic you pass should be the complete final version.
        Do NOT quiz the learner or assign scores — this is a free exploration session.

        About the spaced-repetition system (for context when the learner asks):
        Each word has 2–4 flashcards (called "facets"): reading→meaning, meaning→reading,
        kanji→reading, and meaning+reading→kanji. Each flashcard has an Ebisu memory model
        with a halflife (how long until ~50% recall). Halflives are updated automatically
        after every quiz answer. If the learner wants to manually adjust a halflife (e.g.
        "I already know this really well" or "I keep forgetting this"), they must do it
        themselves: in this word's detail screen, scroll to the "Halflives" table above the
        action buttons, tap the flashcard row they want to change, and enter the new halflife.
        (This UI should be right above where they're chatting with you). You cannot adjust halflives directly.
        """
    }
}
