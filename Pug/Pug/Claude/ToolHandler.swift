// ToolHandler.swift
// Implements tool calls for Claude: lookup_jmdict and lookup_kanjidic.

import GRDB
import Foundation

// MARK: - Tool definitions (passed to AnthropicClient)

extension AnthropicTool {
    static let lookupJmdict = AnthropicTool(
        name: "lookup_jmdict",
        description: "Look up one or more Japanese words (kanji or kana) in JMDict. Returns each entry's id, kanji forms, kana forms, and English meanings. Batch all words you need into a single call.",
        inputSchema: [
            "type": .string("object"),
            "properties": .object([
                "words": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("The Japanese words to look up, each in kanji or kana form.")
                ])
            ]),
            "required": .array([.string("words")])
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

    static let getMnemonic = AnthropicTool(
        name: "get_mnemonic",
        description: "Get the mnemonic note for a vocabulary word, a single kanji character, or a grammar topic. Returns the mnemonic text, or null if none exists.",
        inputSchema: [
            "type": .string("object"),
            "properties": .object([
                "word_type": .object([
                    "type": .string("string"),
                    "description": .string("Either 'jmdict' (vocabulary word), 'kanji' (single kanji character), or 'grammar' (grammar topic).")
                ]),
                "word_id": .object([
                    "type": .string("string"),
                    "description": .string("The JMDict entry ID (for jmdict), the kanji character itself (for kanji), or the topic ID (for grammar, e.g. 'genki:potential-verbs').")
                ])
            ]),
            "required": .array([.string("word_type"), .string("word_id")])
        ]
    )

    static let setMnemonic = AnthropicTool(
        name: "set_mnemonic",
        description: "Save or update a mnemonic note for a vocabulary word, single kanji character, or grammar topic. IMPORTANT: This overwrites any existing mnemonic for the same word_type + word_id. Before calling, always check the existing mnemonic (from the system prompt or via get_mnemonic) and merge new content into it rather than replacing it wholesale. The mnemonic field should contain the complete final text you want stored.",
        inputSchema: [
            "type": .string("object"),
            "properties": .object([
                "word_type": .object([
                    "type": .string("string"),
                    "description": .string("Either 'jmdict' (vocabulary word), 'kanji' (single kanji character), or 'grammar' (grammar topic).")
                ]),
                "word_id": .object([
                    "type": .string("string"),
                    "description": .string("The JMDict entry ID (for jmdict), the kanji character itself (for kanji), or the topic ID (for grammar, e.g. 'genki:potential-verbs').")
                ]),
                "mnemonic": .object([
                    "type": .string("string"),
                    "description": .string("The mnemonic text to save.")
                ])
            ]),
            "required": .array([.string("word_type"), .string("word_id"), .string("mnemonic")])
        ]
    )

    static let lookupKanjidic = AnthropicTool(
        name: "lookup_kanjidic",
        description: "Look up one or more kanji characters in KANJIDIC2, augmented with WaniKani component breakdowns. Returns radical components (kradfile), stroke count, JLPT level, school grade, on-readings, kun-readings, English meanings, and — when available — a `wanikani_components` array listing informal kanji components (each with `char` and either `meaning` from KANJIDIC2 or `description` from WaniKani's informal component glossary). Non-kanji characters in the input are ignored.",
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

// MARK: - WaniKani data

/// Loaded from `wanikani-kanji-graph.json` and `wanikani-extra-radicals.json` in the app bundle.
struct WanikaniData: Sendable {
    /// Maps a kanji character to its informal WaniKani component characters.
    let kanjiToComponents: [String: [String]]
    /// Descriptions for component characters not found in KANJIDIC2 (e.g. katakana shapes,
    /// multi-codepoint IDS sequences).
    let extraDescriptions: [String: String]

    static func load(from bundle: Bundle = .main) -> WanikaniData {
        var kanjiToComponents: [String: [String]] = [:]
        var extraDescriptions: [String: String] = [:]

        if let url = bundle.url(forResource: "wanikani-kanji-graph", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mapping = json["kanjiToRadicals"] as? [String: [String]] {
            kanjiToComponents = mapping
        }

        if let url = bundle.url(forResource: "wanikani-extra-radicals", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            extraDescriptions = dict
        }

        return WanikaniData(kanjiToComponents: kanjiToComponents, extraDescriptions: extraDescriptions)
    }
}

// MARK: - Handler

/// Handles tool calls from AnthropicClient: lookup_jmdict, lookup_kanjidic,
/// get_mnemonic, and set_mnemonic.
struct ToolHandler: Sendable {
    /// DatabaseReader opened on jmdict.sqlite (from the app bundle).
    /// Stored as DatabaseQueue to avoid WAL-mode sidecar files on a read-only DB.
    let jmdict: any DatabaseReader

    /// DatabaseReader opened on kanjidic2.sqlite (from the app bundle). Nil if not available.
    let kanjidic: (any DatabaseReader)?

    /// WaniKani component data, loaded from bundle JSON files. Empty if files absent.
    let wanikani: WanikaniData

    /// Quiz database for mnemonic read/write. Nil if not yet initialized.
    let quizDB: QuizDB?

    /// Open jmdict.sqlite and kanjidic2.sqlite directly from the app bundle.
    /// Both are read-only and in DELETE journal mode, so no WAL sidecars are created.
    /// Uses DatabaseQueue (not Pool) so GRDB doesn't force WAL mode on read-only DBs.
    static func makeDefault(quizDB: QuizDB? = nil) throws -> ToolHandler {
        var config = Configuration()
        config.readonly = true

        guard let jmdictURL = Bundle.main.url(forResource: "jmdict", withExtension: "sqlite") else {
            throw QuizDBError.jmdictBundleNotFound
        }
        let jmdictQueue = try DatabaseQueue(path: jmdictURL.path, configuration: config)

        let kanjidicQueue: DatabaseQueue? = Bundle.main
            .url(forResource: "kanjidic2", withExtension: "sqlite")
            .flatMap { try? DatabaseQueue(path: $0.path, configuration: config) }

        let wanikani = WanikaniData.load()

        return ToolHandler(jmdict: jmdictQueue, kanjidic: kanjidicQueue, wanikani: wanikani, quizDB: quizDB)
    }

    /// Route a tool call. Returns the result string (JSON on success, error JSON on failure).
    func handle(toolName: String, input: [String: JSONValue]) async throws -> String {
        switch toolName {
        case "lookup_jmdict":
            guard case .array(let wordValues) = input["words"], !wordValues.isEmpty else {
                return #"{"error":"missing or empty 'words' parameter"}"#
            }
            let words = wordValues.compactMap { $0.stringValue }
            return (try? await lookupJmdictBatch(words: words)) ?? #"{"error":"lookup failed"}"#
        case "lookup_kanjidic":
            guard let text = input["text"]?.stringValue, !text.isEmpty else {
                return #"{"error":"missing or empty 'text' parameter"}"#
            }
            return await lookupKanjidic(text: text)
        case "get_mnemonic":
            guard let wt = input["word_type"]?.stringValue, !wt.isEmpty,
                  let wid = input["word_id"]?.stringValue, !wid.isEmpty else {
                return #"{"error":"missing word_type or word_id"}"#
            }
            return await getMnemonic(wordType: wt, wordId: wid)
        case "set_mnemonic":
            guard let wt = input["word_type"]?.stringValue, !wt.isEmpty,
                  let wid = input["word_id"]?.stringValue, !wid.isEmpty,
                  let text = input["mnemonic"]?.stringValue, !text.isEmpty else {
                return #"{"error":"missing word_type, word_id, or mnemonic"}"#
            }
            return await setMnemonic(wordType: wt, wordId: wid, text: text)
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

        // Collect all characters we'll need meanings for (radicals + WK components)
        // so we can batch-query them in a single db.read.
        var allLookupChars = Set<String>()
        for k in kanjis {
            if let components = wanikani.kanjiToComponents[k] {
                for c in components { allLookupChars.insert(c) }
            }
        }
        // We also need radical meanings, but those depend on each kanji's row data,
        // so we fetch all kanji rows + all component meanings in one read.
        let wkExtra = wanikani.extraDescriptions

        let queryResults: [(String, Row?, [String], [[String: String]])] = (try? db.read { db in
            // Pre-fetch meanings for all WK component characters in one pass.
            var meaningCache: [String: String] = [:]
            for c in allLookupChars {
                let cRow = try Row.fetchOne(db, sql: "SELECT meanings FROM kanji WHERE literal = ?", arguments: [c])
                if let mJSON = cRow?["meanings"] as? String,
                   let ms = try? JSONSerialization.jsonObject(with: Data(mJSON.utf8)) as? [String],
                   let first = ms.first {
                    meaningCache[c] = first
                }
            }

            var rows: [(String, Row?, [String], [[String: String]])] = []
            for k in kanjis {
                let row = try Row.fetchOne(db, sql: "SELECT * FROM kanji WHERE literal = ?", arguments: [k])

                // Kanjidic radical labels (kradfile-sourced).
                var radicalLabels: [String] = []
                if let rJSON = row?["radicals"] as? String,
                   let rads = try? JSONSerialization.jsonObject(with: Data(rJSON.utf8)) as? [String] {
                    for r in rads {
                        // Radical meanings might not be in meaningCache (if the radical
                        // wasn't also a WK component), so query on cache miss.
                        if let m = meaningCache[r] {
                            radicalLabels.append("\(r) (\(m))")
                        } else {
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
                }

                // WaniKani informal component breakdown.
                var wkEntries: [[String: String]] = []
                if let components = wanikani.kanjiToComponents[k] {
                    for c in components {
                        var comp: [String: String] = ["char": c]
                        if let m = meaningCache[c] {
                            comp["meaning"] = m
                        } else if let desc = wkExtra[c] {
                            comp["description"] = desc
                        }
                        wkEntries.append(comp)
                    }
                }

                rows.append((k, row, radicalLabels, wkEntries))
            }
            return rows
        }) ?? []

        var results: [[String: Any]] = []
        for (k, row, radicalLabels, wkEntries) in queryResults {
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
            if !wkEntries.isEmpty {
                entry["wanikani_components"] = wkEntries
            }
            results.append(entry)
        }
        let data = (try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func getMnemonic(wordType: String, wordId: String) async -> String {
        guard let db = quizDB else { return #"{"error":"quiz database not available"}"# }
        do {
            if let m = try await db.mnemonic(wordType: wordType, wordId: wordId) {
                let obj: [String: Any] = ["word_type": m.wordType, "word_id": m.wordId,
                                           "mnemonic": m.mnemonic, "updated_at": m.updatedAt]
                let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return #"{"mnemonic":null}"#
        } catch {
            return "{\"error\":\"\(error.localizedDescription)\"}"
        }
    }

    private func setMnemonic(wordType: String, wordId: String, text: String) async -> String {
        guard let db = quizDB else { return #"{"error":"quiz database not available"}"# }
        do {
            try await db.setMnemonic(wordType: wordType, wordId: wordId, text: text)
            return #"{"ok":true}"#
        } catch {
            return "{\"error\":\"\(error.localizedDescription)\"}"
        }
    }

    private func lookupJmdictBatch(words: [String]) async throws -> String {
        // Build a single JOIN query for all requested words.
        let placeholders = words.map { _ in "?" }.joined(separator: ",")
        // GROUP BY e.id deduplicates entries; GROUP_CONCAT collects all matching query texts
        // so every queried form maps to the same (single) result object.
        let sql = """
            SELECT GROUP_CONCAT(r.text) AS texts, e.entry_json
            FROM raws r JOIN entries e ON e.id = r.entry_id
            WHERE r.text IN (\(placeholders))
            GROUP BY e.id
        """
        let byWord: [String: String] = try await jmdict.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(words))
                .reduce(into: [:]) { dict, row in
                    guard let texts = row["texts"] as? String,
                          let json  = row["entry_json"] as? String else { return }
                    for text in texts.split(separator: ",") { dict[String(text)] = json }
                }
        }

        // Build output array in input order.
        let results: [Any] = words.map { word -> Any in
            guard let json = byWord[word],
                  let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return ["query": word, "error": "word not found"]
            }
            let kanjiForms = (raw["kanji"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let kanaForms  = (raw["kana"]  as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let meanings   = (raw["sense"] as? [[String: Any]] ?? []).flatMap { sense -> [String] in
                (sense["gloss"] as? [[String: Any]] ?? [])
                    .filter { ($0["lang"] as? String) == "eng" }
                    .compactMap { $0["text"] as? String }
            }
            return ["query": word, "id": raw["id"] as? String ?? "",
                    "kanji": kanjiForms, "kana": kanaForms, "meanings": meanings]
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
