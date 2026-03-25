// AnthropicClient.swift
// Thin URLSession wrapper around the Anthropic Messages API (/v1/messages).
// Handles the tool-use loop automatically: sends requests, processes tool_use
// content blocks by calling the provided handler, and loops until end_turn.

import Foundation

// MARK: - JSON value type (for tool inputs/outputs)

indirect enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                             { self = .null;   return }
        if let b = try? c.decode(Bool.self)          { self = .bool(b); return }
        if let n = try? c.decode(Double.self)        { self = .number(n); return }
        if let s = try? c.decode(String.self)        { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self)   { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON type"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Convenience: extract string value if this is a .string case.
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Message types

struct AnthropicMessage: Codable, Sendable {
    var role: String   // "user" or "assistant"
    var content: [AnthropicContentBlock]
}

enum AnthropicContentBlock: Codable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    case toolResult(toolUseId: String, content: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseId = "tool_use_id"
        case content
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id:    try c.decode(String.self, forKey: .id),
                name:  try c.decode(String.self, forKey: .name),
                input: try c.decode([String: JSONValue].self, forKey: .input))
        case "tool_result":
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content:   try c.decode(String.self, forKey: .content))
        default:
            // Gracefully skip unknown block types (e.g., thinking, image)
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
        }
    }
}

// MARK: - Tool definition

struct AnthropicTool: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: [String: JSONValue]   // JSON Schema object

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

// MARK: - Request / Response

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [AnthropicMessage]
    let system: String?
    let tools: [AnthropicTool]?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages, system, tools
    }
}

struct AnthropicResponse: Decodable, Sendable {
    let id: String
    let type: String
    let role: String
    let content: [AnthropicContentBlock]
    let stopReason: String?
    let usage: Usage

    struct Usage: Decodable, Sendable {
        let inputTokens: Int
        let outputTokens: Int
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, role, content
        case stopReason = "stop_reason"
        case usage
    }
}

// MARK: - Client

/// Thin async wrapper around POST /v1/messages.
/// Automatically handles tool-use loops: calls `toolHandler` for each tool_use
/// block and sends results back until the model reaches end_turn.
struct AnthropicClient: Sendable {
    let apiKey: String
    let modelProvider: @Sendable () -> String

    var model: String { modelProvider() }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    init(apiKey: String, model: String = "claude-sonnet-4-6") {
        self.apiKey = apiKey
        self.modelProvider = { model }
    }

    init(apiKey: String, modelProvider: @escaping @Sendable () -> String) {
        self.apiKey = apiKey
        self.modelProvider = modelProvider
    }

    /// Called for each tool_use block: (toolName, toolInput) → result string.
    typealias ToolHandler = @Sendable (String, [String: JSONValue]) async throws -> String

    /// Metadata from a completed send() call, aggregated across all tool-use turns.
    struct SendMetadata: Sendable {
        var totalInputTokens: Int = 0
        var totalOutputTokens: Int = 0
        var toolsCalled: [String] = []       // tool names invoked (may have duplicates)
        var totalTurns: Int = 0              // number of API round-trips inside send()
        var firstTurnInputTokens: Int = 0   // input tokens on the first round-trip only (system + tool schemas + messages)
    }

    /// Send a conversation and get the final text response.
    ///
    /// - Parameters:
    ///   - messages: Conversation history (mutated in-place with new turns).
    ///   - system: Optional system prompt.
    ///   - tools: Tools the model may call.
    ///   - maxTokens: Max tokens per API call.
    ///   - toolHandler: Called for each tool_use block. Required if tools are provided.
    /// - Returns: (finalText, updatedMessages, metadata)
    func send(
        messages: [AnthropicMessage],
        system: String? = nil,
        tools: [AnthropicTool] = [],
        maxTokens: Int = 2048,
        toolHandler: ToolHandler? = nil
    ) async throws -> (text: String, messages: [AnthropicMessage], metadata: SendMetadata) {
        var msgs = messages
        var turn = 0
        var accumulatedText: [String] = []
        var meta = SendMetadata()
        while true {
            turn += 1
            print("[Anthropic] turn \(turn): sending \(msgs.count) message(s), \(tools.count) tool(s), maxTokens=\(maxTokens)")
            let response = try await callAPI(
                messages: msgs,
                system: system,
                tools: tools.isEmpty ? nil : tools,
                maxTokens: maxTokens)
            meta.totalInputTokens  += response.usage.inputTokens
            meta.totalOutputTokens += response.usage.outputTokens
            if turn == 1 { meta.firstTurnInputTokens = response.usage.inputTokens }
            msgs.append(AnthropicMessage(role: "assistant", content: response.content))

            // Collect text from this turn
            let turnText = response.content.compactMap {
                if case .text(let t) = $0 { return t }
                return nil
            }.joined(separator: "\n")
            if !turnText.isEmpty { accumulatedText.append(turnText) }

            // Collect any tool_use blocks
            let toolUses: [(id: String, name: String, input: [String: JSONValue])] = response.content.compactMap {
                if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) }
                return nil
            }

            if toolUses.isEmpty || response.stopReason == "end_turn" {
                let text = accumulatedText.joined(separator: "\n\n")
                meta.totalTurns = turn
                print("[Anthropic] done after \(turn) turn(s), text length=\(text.count)")
                print("[Anthropic] final text: \(text)")
                return (text, msgs, meta)
            }

            print("[Anthropic] tool call(s): \(toolUses.map(\.name).joined(separator: ", "))")
            meta.toolsCalled += toolUses.map { use in
                if use.name == "lookup_jmdict", case .array(let w) = use.input["words"] {
                    return "lookup_jmdict:\(w.count)"
                }
                return use.name
            }
            guard let handler = toolHandler else {
                throw AnthropicError.toolCallWithoutHandler(toolUses.map(\.name))
            }
            var results: [AnthropicContentBlock] = []
            for use in toolUses {
                print("[Anthropic]   calling \(use.name) input=\(use.input)")
                let result = try await handler(use.name, use.input)
                print("[Anthropic]   result length=\(result.count) chars")
                results.append(.toolResult(toolUseId: use.id, content: result))
            }
            msgs.append(AnthropicMessage(role: "user", content: results))
        }
    }

    // MARK: - Private

    private func callAPI(
        messages: [AnthropicMessage],
        system: String?,
        tools: [AnthropicTool]?,
        maxTokens: Int
    ) async throws -> AnthropicResponse {
        let requestBody = AnthropicRequest(
            model: model,
            maxTokens: maxTokens,
            messages: messages,
            system: system,
            tools: tools)

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        let bodyData = try JSONEncoder().encode(requestBody)
        req.httpBody = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion,    forHTTPHeaderField: "anthropic-version")

        print("[Anthropic] → POST /v1/messages (\(bodyData.count) bytes, model=\(model))")
        if let sys = system { print("[Anthropic]   system: \(sys)") }
        for (i, msg) in messages.enumerated() {
            let content = msg.content.map { block -> String in
                switch block {
                case .text(let t): return "text(\(t))"
                case .toolUse(_, let name, let input): return "toolUse(\(name) \(input))"
                case .toolResult(_, let c): return "toolResult(\(c))"
                }
            }.joined(separator: "; ")
            print("[Anthropic]   msg[\(i)] \(msg.role): \(content)")
        }

        let (data, urlResponse) = try await URLSession.shared.data(for: req)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            print("[Anthropic] ← \(http.statusCode) ERROR: \(body.prefix(500))")
            throw AnthropicError.apiError(statusCode: http.statusCode, body: body)
        }
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        print("[Anthropic] ← 200 stopReason=\(response.stopReason ?? "nil") inputTokens=\(response.usage.inputTokens) outputTokens=\(response.usage.outputTokens)")
        return response
    }
}

// MARK: - Errors

enum AnthropicError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, body: String)
    case toolCallWithoutHandler([String])

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid HTTP response from Anthropic API"
        case .apiError(let code, let body):
            return "Anthropic API error \(code): \(body)"
        case .toolCallWithoutHandler(let names):
            return "Tool call(s) received with no handler: \(names.joined(separator: ", "))"
        }
    }
}
