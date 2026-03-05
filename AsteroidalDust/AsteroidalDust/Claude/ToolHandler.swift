// ToolHandler.swift
// Implements the lookup_jmdict tool: queries jmdict.sqlite by kanji or kana form
// and returns the entry's kanji forms, kana forms, and English meanings as JSON.

import GRDB
import Foundation

// MARK: - Tool definition (passed to AnthropicClient)

extension AnthropicTool {
    static let lookupJmdict = AnthropicTool(
        name: "lookup_jmdict",
        description: "Look up a Japanese word (kanji or kana) in JMDict. Returns the entry's id, kanji forms, kana forms, and English meanings.",
        inputSchema: [
            "type": .string("object"),
            "properties": .object([
                "word": .object([
                    "type": .string("string"),
                    "description": .string("The Japanese word to look up, in kanji or kana form.")
                ])
            ]),
            "required": .array([.string("word")])
        ]
    )

    static let getVocabContext = AnthropicTool(
        name: "get_vocab_context",
        description: "Get the student's full enrolled vocabulary list with recall probabilities and facet urgency. Call this when the student asks about another word they might be studying, or when knowing their broader learning context would help answer their question.",
        inputSchema: [
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([])
        ]
    )
}

// MARK: - Handler

/// Handles tool calls from AnthropicClient, currently just lookup_jmdict.
struct ToolHandler: Sendable {
    /// DatabaseReader opened on jmdict.sqlite (the copy in Documents).
    /// Stored as DatabaseQueue to avoid WAL-mode sidecar files on a read-only DB.
    let jmdict: any DatabaseReader

    /// Open jmdict.sqlite from the Documents directory (where QuizDB copies it).
    /// Uses DatabaseQueue (not Pool) so GRDB doesn't force WAL mode on a read-only DB.
    static func makeDefault() throws -> ToolHandler {
        let docsURL = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dbURL = docsURL.appendingPathComponent("jmdict.sqlite")
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        return ToolHandler(jmdict: queue)
    }

    /// Route a tool call. Returns the result string (JSON on success, error JSON on failure).
    func handle(toolName: String, input: [String: JSONValue]) async throws -> String {
        switch toolName {
        case "lookup_jmdict":
            guard let word = input["word"]?.stringValue, !word.isEmpty else {
                return #"{"error":"missing or empty 'word' parameter"}"#
            }
            return (try? await lookupJmdict(word: word)) ?? #"{"error":"lookup failed"}"#
        default:
            return "{\"error\":\"unknown tool: \(toolName)\"}"
        }
    }

    // MARK: - Private

    private func lookupJmdict(word: String) async throws -> String {
        let entryJSON: String? = try await jmdict.read { db in
            // The `raws` table has (text, entry_id) for exact kanji/kana matches.
            let row = try Row.fetchOne(db,
                sql: "SELECT entry_id FROM raws WHERE text = ? LIMIT 1",
                arguments: [word])
            guard let entryId = row?["entry_id"] as? String else { return nil }
            return try String.fetchOne(db,
                sql: "SELECT entry_json FROM entries WHERE id = ? LIMIT 1",
                arguments: [entryId])
        }

        guard let json = entryJSON,
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "{\"error\":\"word not found: \(word)\"}"
        }

        // Extract just the useful fields for Claude: id, kanji forms, kana forms, meanings.
        let id = raw["id"] as? String ?? ""

        let kanjiForms = (raw["kanji"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }

        let kanaForms = (raw["kana"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }

        let meanings = (raw["sense"] as? [[String: Any]] ?? [])
            .flatMap { sense -> [String] in
                (sense["gloss"] as? [[String: Any]] ?? [])
                    .filter { ($0["lang"] as? String) == "eng" }
                    .compactMap { $0["text"] as? String }
            }

        let result: [String: Any] = [
            "id": id,
            "kanji": kanjiForms,
            "kana": kanaForms,
            "meanings": meanings
        ]
        let resultData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        return String(data: resultData, encoding: .utf8) ?? "{}"
    }
}
