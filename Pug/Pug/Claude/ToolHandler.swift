// ToolHandler.swift
// Implements tool calls for Claude: lookup_jmdict and lookup_kanjidic.

import GRDB
import Foundation

// MARK: - Tool definitions (passed to AnthropicClient)

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

    static let lookupKanjidic = AnthropicTool(
        name: "lookup_kanjidic",
        description: "Look up one or more kanji characters in KANJIDIC2. Returns radical components, stroke count, JLPT level, school grade, on-readings, kun-readings, and English meanings for each kanji found in the input string. Non-kanji characters are ignored.",
        inputSchema: [
            "type": .string("object"),
            "properties": .object([
                "text": .object([
                    "type": .string("string"),
                    "description": .string("A string containing one or more kanji to look up. Non-kanji characters are ignored. Example: '怒鳴る' returns info for 怒 and 鳴.")
                ])
            ]),
            "required": .array([.string("text")])
        ]
    )
}

// MARK: - Handler

/// Handles tool calls from AnthropicClient: lookup_jmdict and lookup_kanjidic.
struct ToolHandler: Sendable {
    /// DatabaseReader opened on jmdict.sqlite (from the app bundle).
    /// Stored as DatabaseQueue to avoid WAL-mode sidecar files on a read-only DB.
    let jmdict: any DatabaseReader

    /// DatabaseReader opened on kanjidic2.sqlite (from the app bundle). Nil if not available.
    let kanjidic: (any DatabaseReader)?

    /// Open jmdict.sqlite and kanjidic2.sqlite directly from the app bundle.
    /// Both are read-only and in DELETE journal mode, so no WAL sidecars are created.
    /// Uses DatabaseQueue (not Pool) so GRDB doesn't force WAL mode on read-only DBs.
    static func makeDefault() throws -> ToolHandler {
        var config = Configuration()
        config.readonly = true

        guard let jmdictURL = Bundle.main.url(forResource: "jmdict", withExtension: "sqlite") else {
            throw QuizDBError.jmdictBundleNotFound
        }
        let jmdictQueue = try DatabaseQueue(path: jmdictURL.path, configuration: config)

        let kanjidicQueue: DatabaseQueue? = Bundle.main
            .url(forResource: "kanjidic2", withExtension: "sqlite")
            .flatMap { try? DatabaseQueue(path: $0.path, configuration: config) }

        return ToolHandler(jmdict: jmdictQueue, kanjidic: kanjidicQueue)
    }

    /// Route a tool call. Returns the result string (JSON on success, error JSON on failure).
    func handle(toolName: String, input: [String: JSONValue]) async throws -> String {
        switch toolName {
        case "lookup_jmdict":
            guard let word = input["word"]?.stringValue, !word.isEmpty else {
                return #"{"error":"missing or empty 'word' parameter"}"#
            }
            return (try? await lookupJmdict(word: word)) ?? #"{"error":"lookup failed"}"#
        case "lookup_kanjidic":
            guard let text = input["text"]?.stringValue, !text.isEmpty else {
                return #"{"error":"missing or empty 'text' parameter"}"#
            }
            return await lookupKanjidic(text: text)
        default:
            return "{\"error\":\"unknown tool: \(toolName)\"}"
        }
    }

    // MARK: - Private

    private func lookupKanjidic(text: String) async -> String {
        guard let db = kanjidic else {
            return #"{"error":"kanjidic2 not available"}"#
        }
        // Extract CJK Unified Ideograph code points, deduplicated in order.
        let kanjis = text.unicodeScalars
            .filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF ||
                      $0.value >= 0x3400 && $0.value <= 0x4DBF ||
                      $0.value >= 0xF900 && $0.value <= 0xFAFF }
            .map { String($0) }
            .reduce(into: (list: [String](), seen: Set<String>())) { acc, k in
                if acc.seen.insert(k).inserted { acc.list.append(k) }
            }.list

        guard !kanjis.isEmpty else {
            return #"{"error":"no kanji characters found in input"}"#
        }

        var results: [[String: Any]] = []
        for k in kanjis {
            let result = try? db.read { db -> (Row?, [String]) in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM kanji WHERE literal = ?", arguments: [k])
                var radicalLabels: [String] = []
                if let rJSON = row?["radicals"] as? String,
                   let rads = try? JSONSerialization.jsonObject(with: Data(rJSON.utf8)) as? [String] {
                    for r in rads {
                        let rRow = try Row.fetchOne(db, sql: "SELECT meanings FROM kanji WHERE literal = ?", arguments: [r])
                        if let mJSON = rRow?["meanings"] as? String,
                           let ms = try? JSONSerialization.jsonObject(with: Data(mJSON.utf8)) as? [String],
                           let first = ms.first {
                            radicalLabels.append("\(r) (\(first))")
                        } else {
                            radicalLabels.append(r)
                        }
                    }
                }
                return (row, radicalLabels)
            }
            let row = result?.0
            let radicalLabels = result?.1 ?? []
            var entry: [String: Any] = ["literal": k]
            if let row = row {
                if let strokes = row["strokes"] as? Int64 { entry["strokes"] = strokes }
                if let grade   = row["grade"]   as? Int64 { entry["grade"]   = "G\(grade)" }
                if let jlpt    = row["jlpt"]    as? Int64 { entry["jlpt"]    = "N\(jlpt + 1)" }
                if let onJSON  = row["on_readings"]  as? String,
                   let on      = try? JSONSerialization.jsonObject(with: Data(onJSON.utf8)) as? [String] {
                    entry["on"] = on
                }
                if let kunJSON = row["kun_readings"] as? String,
                   let kun     = try? JSONSerialization.jsonObject(with: Data(kunJSON.utf8)) as? [String] {
                    entry["kun"] = kun
                }
                if let mJSON   = row["meanings"] as? String,
                   let meanings = try? JSONSerialization.jsonObject(with: Data(mJSON.utf8)) as? [String] {
                    entry["meanings"] = meanings
                }
                if !radicalLabels.isEmpty {
                    entry["radicals"] = radicalLabels
                }
            } else {
                entry["error"] = "not in kanjidic2"
            }
            results.append(entry)
        }
        let data = (try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

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
