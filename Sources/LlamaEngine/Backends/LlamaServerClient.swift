import Foundation

/// Errors surfaced by the llama.cpp server networking layer.
public enum LlamaServerError: LocalizedError {
    case invalidURL
    case http(Int)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server address isn't a valid URL."
        case .http(let code):
            return "The server returned HTTP \(code)."
        case .server(let message):
            return message
        }
    }
}

/// Talks to a llama.cpp `llama-server` over its **OpenAI-compatible** HTTP API
/// (`/v1/chat/completions`, `/v1/embeddings`, `/v1/models`). A small `Sendable` value
/// with no shared mutable state, so it's safe to pass across actor boundaries — the
/// same shape as `OllamaClient`, so the controller and RAG layer treat them alike.
///
/// The server serves a single loaded model, so `num_ctx`/`keep_alive` (Ollama request
/// knobs) don't apply — the context window and residency are fixed at server launch.
/// Reasoning models (e.g. gpt-oss / harmony) return their chain-of-thought in a
/// separate `reasoning_content` delta, which this client maps to `ChatChunk.thinkingDelta`.
public struct LlamaServerClient: Sendable, ServerBackend {
    var baseURL: URL
    var timeout: TimeInterval

    /// Fails if `baseURLString` isn't a usable URL (no scheme/host), so callers can
    /// surface a clear "check Settings" message instead of silently doing nothing.
    public init?(baseURLString: String, timeout: TimeInterval = 120) {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        self.baseURL = url
        self.timeout = timeout
    }

    // MARK: Requests

    /// Returns the server's build string from `/props` (e.g. "b10066-86a9c79f8"), used
    /// as a lightweight reachability/version check.
    public func version() async throws -> String {
        let data = try await get("props")
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let build = root["build_info"] as? String, !build.isEmpty {
            return build
        }
        return "llama.cpp"
    }

    /// Lists the loaded model(s) from `GET /v1/models`. llama.cpp serves one model, so
    /// this is normally a single entry; capabilities come from the server when present.
    public func models() async throws -> [OllamaModel] {
        let data = try await get("v1/models")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ModelsResponse.self, from: data)
        return Self.parseModels(response)
    }

    /// The loaded model's trained context length from `GET /v1/models` (`data[].meta.n_ctx`),
    /// or `nil` if unavailable. Since llama.cpp serves one model at a fixed window, the
    /// `name` argument is ignored and the first model's window is returned.
    public func modelContextLength(_ name: String) async throws -> Int? {
        let data = try await get("v1/models")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ModelsResponse.self, from: data)
        return response.data?.compactMap { $0.meta?.nCtx }.first(where: { $0 > 0 })
    }

    /// The loaded model's capabilities from `GET /props` (`chat_template_caps.supports_tools`
    /// and `modalities.vision`), as tags like `["tools", "vision"]`. Empty when the server is
    /// too old to report `chat_template_caps`, which callers treat as "unknown". `name` is
    /// ignored (the server serves one model).
    public func modelCapabilities(_ name: String) async throws -> [String] {
        let data = try await get("props")
        return Self.parseProps(data)
    }

    /// Parses `/props` into capability tags. Pure/static for testing. llama.cpp's
    /// `/v1/models` reports only `["completion"]`, so tool/vision support must come from here.
    public static func parseProps(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var caps: [String] = []
        if let templateCaps = root["chat_template_caps"] as? [String: Any],
           (templateCaps["supports_tools"] as? Bool == true) || (templateCaps["supports_tool_calls"] as? Bool == true) {
            caps.append("tools")
        }
        if let modalities = root["modalities"] as? [String: Any], modalities["vision"] as? Bool == true {
            caps.append("vision")
        }
        return caps
    }

    /// Batch-embeds `input` strings via `/v1/embeddings` (OpenAI shape). Returns one
    /// vector per input, in order. Used by the retrieval (RAG) context strategy. The
    /// server must be started with `--embeddings` and an OpenAI-compatible pooling type
    /// (`--pooling last|mean|cls`); otherwise it returns an error and retrieval falls
    /// back to summarize/truncate.
    public func embed(model: String, input: [String]) async throws -> [[Float]] {
        guard !input.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appending(path: "v1/embeddings"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbedRequestBody(input: input, model: model.isEmpty ? nil : model))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Self.decodeError(from: data, status: http.statusCode)
        }
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(EmbedResponse.self, from: data)
        let vectors = decoded.data.sorted { $0.index < $1.index }.map(\.embedding)
        guard vectors.count == input.count else {
            throw LlamaServerError.server("Embedding count mismatch (\(vectors.count) for \(input.count) inputs).")
        }
        return vectors
    }

    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeChatRequest(request)
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw await Self.readError(from: bytes, status: http.statusCode)
                    }

                    // Server-Sent Events: content/reasoning arrive as `data:` deltas; the
                    // final `usage`/`timings` and `finish_reason` arrive on later lines,
                    // then a `data: [DONE]` terminator. Accumulate the stats and emit a
                    // single terminal `done` chunk so the UI records tokens and tok/s.
                    var promptTokens: Int?
                    var completionTokens: Int?
                    var evalNanos: Int?
                    var finishReason: String?
                    var emittedDone = false

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let event = try Self.parseSSELine(line) else { continue }
                        if let value = event.promptTokens { promptTokens = value }
                        if let value = event.completionTokens { completionTokens = value }
                        if let value = event.evalDurationNanos { evalNanos = value }
                        if let value = event.finishReason { finishReason = value }
                        if event.isTerminator {
                            continuation.yield(ChatChunk(contentDelta: "", done: true,
                                                         promptTokens: promptTokens,
                                                         evalTokens: completionTokens,
                                                         evalDurationNanos: evalNanos,
                                                         doneReason: finishReason))
                            emittedDone = true
                            break
                        }
                        if !event.content.isEmpty || !event.reasoning.isEmpty || !event.toolCallDeltas.isEmpty {
                            continuation.yield(ChatChunk(contentDelta: event.content,
                                                         done: false,
                                                         thinkingDelta: event.reasoning,
                                                         toolCallDeltas: event.toolCallDeltas))
                        }
                    }
                    // Some servers close the stream without a `[DONE]` line; still emit a
                    // terminal chunk so stats land and the consumer stops cleanly.
                    if !emittedDone {
                        continuation.yield(ChatChunk(contentDelta: "", done: true,
                                                     promptTokens: promptTokens,
                                                     evalTokens: completionTokens,
                                                     evalDurationNanos: evalNanos,
                                                     doneReason: finishReason))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Tear down the URLSession stream when the consumer stops (e.g. the user
            // taps Stop), so generation actually halts on the server.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LlamaServerError.http(http.statusCode)
        }
        return data
    }

    private func makeChatRequest(_ request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Self.encodeChatBody(request)
        return urlRequest
    }

    /// Maps `think` to a gpt-oss / harmony reasoning-effort level, injected as a
    /// `Reasoning: low|medium|high` system message. `false` (title/summary/vision) asks
    /// for minimal reasoning so those internal calls stay fast; `true` asks for more;
    /// `nil` (Automatic) omits it so the model uses its default.
    public static func reasoningEffort(for think: Bool?) -> String? {
        switch think {
        case .some(false): return "low"
        case .some(true): return "high"
        case .none: return nil
        }
    }

    /// Encodes a chat request into its OpenAI-compatible JSON wire body. Always streams
    /// (`stream: true` + `include_usage`) so a single code path handles both live chat
    /// and the internal non-streaming callers, which simply concatenate the deltas.
    /// Pure and static so the exact payload can be unit-tested without a server.
    public static func encodeChatBody(_ request: ChatRequest) throws -> Data {
        var messages = request.messages.map { ChatBody.Message(role: $0.role, content: $0.content) }
        if let effort = reasoningEffort(for: request.think) {
            messages.insert(ChatBody.Message(role: Role.system.rawValue, content: "Reasoning: \(effort)"), at: 0)
        }
        let p = request.parameters
        let body = ChatBody(
            model: request.model,
            messages: messages,
            stream: true,
            maxTokens: request.numPredict,
            temperature: p.temperature,
            topP: p.topP,
            topK: p.topK,
            repeatPenalty: p.repeatPenalty,
            seed: p.seed,
            stop: p.stop.isEmpty ? nil : p.stop,
            streamOptions: .init(includeUsage: true),
            tools: request.tools.isEmpty ? nil : request.tools.map(ToolWireEnvelope.init)
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(body)
    }

    /// One parsed Server-Sent Events line. A plain `Sendable`/`Equatable` value so the
    /// SSE parsing can be unit-tested independently of the streaming loop.
    public struct StreamEvent: Sendable, Equatable {
        public var content: String = ""
        public var reasoning: String = ""
        public var finishReason: String?
        /// Raw streamed tool-call fragments, merged by `ToolCallAssembler`.
        public var toolCallDeltas: [ToolCallDelta] = []
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var evalDurationNanos: Int?
        /// True for the `data: [DONE]` terminator line.
        public var isTerminator: Bool = false
    }

    /// Parses one SSE line (`data: {json}` / `data: [DONE]`) into a `StreamEvent`.
    /// Returns `nil` for blank lines and non-`data:` fields (comments, `event:`), and
    /// throws `LlamaServerError.server` for an error payload. Pure and synchronous so
    /// it can be unit-tested without a server.
    public static func parseSSELine(_ line: String) throws -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" {
            return StreamEvent(isTerminator: true)
        }
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let chunk = try decoder.decode(CompletionChunk.self, from: data)
        if let error = chunk.error {
            throw LlamaServerError.server(error.message)
        }
        var event = StreamEvent()
        if let choice = chunk.choices?.first {
            event.content = choice.delta?.content ?? ""
            event.reasoning = choice.delta?.reasoningContent ?? ""
            event.finishReason = choice.finishReason
            event.toolCallDeltas = (choice.delta?.toolCalls ?? []).map {
                ToolCallDelta(index: $0.index, id: $0.id, name: $0.function?.name,
                              argumentsFragment: $0.function?.arguments ?? "")
            }
        }
        event.promptTokens = chunk.usage?.promptTokens ?? chunk.timings?.promptN
        event.completionTokens = chunk.usage?.completionTokens ?? chunk.timings?.predictedN
        if let ms = chunk.timings?.predictedMs {
            event.evalDurationNanos = Int(ms * 1_000_000)
        }
        return event
    }

    /// Maps a `/v1/models` response into `OllamaModel`s (name from `data[].id`, with
    /// capabilities from the parallel `models[]` array when present). Pure/testable.
    public static func parseModels(_ response: ModelsResponse) -> [OllamaModel] {
        let capsByName = Dictionary(
            (response.models ?? []).map { ($0.name, $0.capabilities) },
            uniquingKeysWith: { first, _ in first }
        )
        let entries = response.data ?? []
        if entries.isEmpty {
            // Fall back to the Ollama-style `models[]` array if `data[]` is absent.
            return (response.models ?? []).map {
                OllamaModel(name: $0.name, details: nil, size: nil, capabilities: $0.capabilities)
            }
        }
        return entries.map {
            OllamaModel(name: $0.id, details: nil, size: nil, capabilities: capsByName[$0.id] ?? nil)
        }
    }

    /// Drains a failed streaming response body to recover the OpenAI `{"error":{...}}`
    /// message, falling back to the HTTP status code.
    private static func readError(from bytes: URLSession.AsyncBytes, status: Int) async -> Error {
        var body = ""
        do {
            for try await line in bytes.lines { body += line }
        } catch {
            // Ignore; fall back to the status code below.
        }
        return decodeError(from: Data(body.utf8), status: status)
    }

    /// Extracts an OpenAI-style `{"error":{"message":...}}` from a response body.
    private static func decodeError(from data: Data, status: Int) -> Error {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return LlamaServerError.server(message)
        }
        return LlamaServerError.http(status)
    }
}

// MARK: - Wire formats

private struct ChatBody: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
    /// Omitted when `nil` (synthesized `Encodable` skips nil optionals).
    let maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var repeatPenalty: Double?
    var seed: Int?
    var stop: [String]?
    let streamOptions: StreamOptions?
    /// Tool definitions in the OpenAI `{type,function}` envelope. Omitted when `nil`.
    let tools: [ToolWireEnvelope]?

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct StreamOptions: Encodable {
        let includeUsage: Bool
    }
}

private struct EmbedRequestBody: Encodable {
    let input: [String]
    let model: String?
}

private struct EmbedResponse: Decodable {
    let data: [Entry]
    struct Entry: Decodable {
        let embedding: [Float]
        let index: Int
    }
}

/// The decoded shape of a streamed `chat.completion.chunk` (and error payloads).
struct CompletionChunk: Decodable {
    let choices: [Choice]?
    let usage: Usage?
    let timings: Timings?
    let error: ErrorBody?

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?
        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ToolCallFragment]?
            struct ToolCallFragment: Decodable {
                let index: Int
                let id: String?
                let function: Function?
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }
            }
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
    }

    struct Timings: Decodable {
        let promptN: Int?
        let predictedN: Int?
        let predictedMs: Double?
    }

    struct ErrorBody: Decodable {
        let message: String
    }
}

/// The decoded shape of `GET /v1/models` (both the OpenAI `data[]` and llama.cpp's
/// `models[]` arrays). Public so `parseModels` can be unit-tested.
public struct ModelsResponse: Decodable, Sendable {
    public let data: [DataEntry]?
    public let models: [ModelEntry]?

    public struct DataEntry: Decodable, Sendable {
        public let id: String
        public let meta: Meta?
        public struct Meta: Decodable, Sendable {
            public let nCtx: Int?
            public let nEmbd: Int?
        }
    }

    public struct ModelEntry: Decodable, Sendable {
        public let name: String
        public let capabilities: [String]?
    }
}
