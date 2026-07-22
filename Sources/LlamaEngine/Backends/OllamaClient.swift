import Foundation

/// Errors surfaced by the Ollama networking layer.
public enum OllamaError: LocalizedError {
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

/// The minimal capability the chat UI needs: stream a reply for a request. Both the
/// Ollama client and the Apple Foundation Models backend conform, so the view model
/// and views are backend-agnostic.
public protocol ChatStreaming: Sendable {
    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error>
}

/// The embedding capability the retrieval (RAG) pipeline needs. Kept separate from
/// `ChatStreaming` because not every chat backend can embed (Apple's on-device model
/// can't), but every *server* backend used for retrieval does.
public protocol EmbeddingBackend: Sendable {
    /// Batch-embeds `input` strings, returning one vector per input, in order.
    func embed(model: String, input: [String]) async throws -> [[Float]]
}

/// Abstraction over a full remote model server. Refines `ChatStreaming` and adds the
/// server-only capabilities (model list, version, trained context length) that Apple's
/// on-device model lacks. Both `OllamaClient` and `LlamaServerClient` conform.
public protocol LLMBackend: ChatStreaming {
    func version() async throws -> String
    func models() async throws -> [OllamaModel]
    /// The model's maximum trained context length, or `nil` if the server doesn't
    /// report it, so the app can cap its planning window to what the model supports.
    func modelContextLength(_ name: String) async throws -> Int?
    /// The model's capability tags (e.g. `["completion", "vision", "thinking"]`), or an
    /// empty array when the backend can't introspect them. Lets the UI show only the
    /// controls a model actually supports (e.g. hide reasoning for non-thinking models).
    func modelCapabilities(_ name: String) async throws -> [String]
}

public extension LLMBackend {
    /// Default: capabilities unknown. Backends that can't report per-model capabilities
    /// (e.g. llama.cpp) return empty, and callers treat empty as "unknown" rather than
    /// "unsupported".
    func modelCapabilities(_ name: String) async throws -> [String] { [] }
}

/// A complete remote server backend: chat streaming, model listing, context-length
/// lookup, *and* embeddings. This is the abstraction the conversation controller and
/// the RAG layer thread through, so document/web retrieval works identically whether
/// the session talks to Ollama or a llama.cpp server.
public protocol ServerBackend: LLMBackend, EmbeddingBackend {}

/// Talks to an Ollama server. A small `Sendable` value with no shared mutable
/// state, so it is safe to pass across actor boundaries.
public struct OllamaClient: Sendable, ServerBackend {
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

    public func version() async throws -> String {
        let data = try await get("api/version")
        return try JSONDecoder().decode(VersionResponse.self, from: data).version
    }

    public func models() async throws -> [OllamaModel] {
        let data = try await get("api/tags")
        return try JSONDecoder().decode(TagsResponse.self, from: data).models
    }

    /// The model's maximum trained context length from `POST /api/show`
    /// (`model_info.<arch>.context_length`), or `nil` if the server doesn't report it.
    /// Lets the app cap `num_ctx` to what the model actually supports instead of
    /// allocating an oversized KV cache or degrading past the trained window.
    public func modelContextLength(_ name: String) async throws -> Int? {
        var request = URLRequest(url: baseURL.appending(path: "api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": name])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OllamaError.http(http.statusCode)
        }
        return Self.parseContextLength(data)
    }

    /// The model's capability tags from `POST /api/show` (`capabilities` array, e.g.
    /// `["completion", "vision", "thinking"]`), or an empty array if the server doesn't
    /// report them. Lets the app tailor per-model controls (e.g. reasoning).
    public func modelCapabilities(_ name: String) async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": name])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OllamaError.http(http.statusCode)
        }
        return Self.parseCapabilities(data)
    }

    /// Models currently loaded in memory (`GET /api/ps`).
    public func runningModels() async throws -> [RunningModel] {
        let data = try await get("api/ps")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PsResponse.self, from: data).models
            .map { RunningModel(name: $0.name, sizeVRAM: $0.sizeVram) }
    }

    /// Deletes a model from the server (`DELETE /api/delete`).
    public func deleteModel(_ name: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "api/delete"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": name])
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OllamaError.http(http.statusCode)
        }
    }

    /// Pulls a model, streaming progress updates (`POST /api/pull`, JSONL).
    public func pullModel(_ name: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "api/pull"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 3600
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(["model": name])

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw OllamaError.http(http.statusCode)
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
                        let parsed = try decoder.decode(PullLine.self, from: data)
                        if let error = parsed.error { throw OllamaError.server(error) }
                        continuation.yield(PullProgress(status: parsed.status ?? "",
                                                        completed: parsed.completed,
                                                        total: parsed.total))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Batch-embeds `input` strings via `/api/embed`. Returns one vector per input,
    /// in order. Used by the retrieval (RAG) context strategy.
    public func embed(model: String, input: [String]) async throws -> [[Float]] {
        guard !input.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appending(path: "api/embed"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbedRequestBody(model: model, input: input))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OllamaError.http(http.statusCode)
        }
        let vectors = try JSONDecoder().decode(EmbedResponse.self, from: data).embeddings
        guard vectors.count == input.count else {
            throw OllamaError.server("Embedding count mismatch (\(vectors.count) for \(input.count) inputs).")
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
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let chunk = try Self.parseLine(line) {
                            continuation.yield(chunk)
                            if chunk.done { break }
                        }
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
            throw OllamaError.http(http.statusCode)
        }
        return data
    }

    private func makeChatRequest(_ request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Self.encodeChatBody(request)
        return urlRequest
    }

    /// Encodes a chat request into its JSON wire body. Pure and static so the exact
    /// payload (snake_cased keys, unset options omitted, seed for reproducibility) can
    /// be unit-tested without a server.
    public static func encodeChatBody(_ request: ChatRequest) throws -> Data {
        let p = request.parameters
        let body = ChatRequestBody(
            model: request.model,
            messages: request.messages,
            stream: request.stream,
            think: request.think,
            keepAlive: request.keepAlive,
            tools: request.tools.isEmpty ? nil : request.tools.map(ToolWireEnvelope.init),
            options: .init(numCtx: request.contextSize,
                           numPredict: request.numPredict,
                           temperature: p.temperature,
                           topP: p.topP,
                           topK: p.topK,
                           repeatPenalty: p.repeatPenalty,
                           seed: p.seed,
                           stop: p.stop.isEmpty ? nil : p.stop)
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(body)
    }

    /// Drains the body of a failed response to recover Ollama's `{"error": ...}`
    /// message, falling back to the HTTP status code.
    private static func readError(from bytes: URLSession.AsyncBytes, status: Int) async -> OllamaError {
        var body = ""
        do {
            for try await line in bytes.lines { body += line }
        } catch {
            // Ignore; fall back to the status code below.
        }
        if let data = body.data(using: .utf8),
           let object = try? JSONDecoder().decode([String: String].self, from: data),
           let message = object["error"], !message.isEmpty {
            return .server(message)
        }
        return .http(status)
    }

    /// Extracts the model's trained context length from an `/api/show` payload by
    /// finding the `model_info` entry whose key ends in `.context_length` (e.g.
    /// `qwen3.context_length`). Pure and static so it can be unit-tested.
    public static func parseContextLength(_ data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["model_info"] as? [String: Any] else { return nil }
        for (key, value) in info where key.hasSuffix(".context_length") {
            if let n = value as? Int, n > 0 { return n }
            if let d = value as? Double, d > 0 { return Int(d) }
            if let s = value as? String, let n = Int(s), n > 0 { return n }
        }
        return nil
    }

    /// Extracts the model's capability tags from an `/api/show` payload (the top-level
    /// `capabilities` array), lowercased. Empty when absent. Pure/static for testing.
    public static func parseCapabilities(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caps = root["capabilities"] as? [String] else { return [] }
        return caps.map { $0.lowercased() }
    }

    /// Decodes one line of the streamed JSONL response into a `ChatChunk`.
    /// Returns `nil` for blank lines and throws `OllamaError.server` for error
    /// payloads. Pure and synchronous so it can be unit-tested without a server.
    public static func parseLine(_ line: String) throws -> ChatChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parsed = try decoder.decode(StreamLine.self, from: data)

        if let error = parsed.error {
            throw OllamaError.server(error)
        }
        let toolCallDeltas = trimmed.contains("tool_calls") ? parseToolCalls(data) : []
        return ChatChunk(
            contentDelta: parsed.message?.content ?? "",
            done: parsed.done ?? false,
            promptTokens: parsed.promptEvalCount,
            evalTokens: parsed.evalCount,
            evalDurationNanos: parsed.evalDuration,
            thinkingDelta: parsed.message?.thinking ?? "",
            doneReason: parsed.doneReason,
            toolCallDeltas: toolCallDeltas
        )
    }

    /// Extracts streamed tool calls from an Ollama `/api/chat` line. Ollama delivers each
    /// call complete with `arguments` as a JSON object, so this re-serializes the arguments
    /// to a compact string with verbatim keys (unaffected by the decoder's snake_case
    /// strategy) for `ToolCallAssembler` to normalize alongside llama.cpp's fragments.
    /// Pure and static so it can be unit-tested without a server.
    static func parseToolCalls(_ data: Data) -> [ToolCallDelta] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let calls = message["tool_calls"] as? [[String: Any]] else { return [] }
        return calls.enumerated().compactMap { index, call in
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            var argumentsFragment = ""
            if let args = function["arguments"], JSONSerialization.isValidJSONObject(args),
               let argData = try? JSONSerialization.data(withJSONObject: args),
               let argString = String(data: argData, encoding: .utf8) {
                argumentsFragment = argString
            }
            return ToolCallDelta(index: index, id: call["id"] as? String,
                                 name: name, argumentsFragment: argumentsFragment)
        }
    }
}

// MARK: - Wire formats

private struct ChatRequestBody: Encodable {
    let model: String
    let messages: [ChatTurn]
    let stream: Bool
    /// Omitted when `nil` (synthesized `Encodable` skips nil optionals).
    let think: Bool?
    /// How long to keep the model loaded (`keep_alive`). Omitted when `nil`.
    let keepAlive: String?
    /// Tool definitions in the OpenAI `{type,function}` envelope. Omitted when `nil`.
    let tools: [ToolWireEnvelope]?
    let options: Options

    struct Options: Encodable {
        let numCtx: Int
        let numPredict: Int?
        var temperature: Double?
        var topP: Double?
        var topK: Int?
        var repeatPenalty: Double?
        var seed: Int?
        var stop: [String]?
    }
}

private struct EmbedRequestBody: Encodable {
    let model: String
    let input: [String]
}

private struct EmbedResponse: Decodable {
    let embeddings: [[Float]]
}

private struct PullLine: Decodable {
    let status: String?
    let completed: Int?
    let total: Int?
    let error: String?
}

private struct StreamLine: Decodable {
    let message: Message?
    let done: Bool?
    let doneReason: String?
    let error: String?
    let promptEvalCount: Int?
    let evalCount: Int?
    let evalDuration: Int?

    struct Message: Decodable {
        let content: String?
        let thinking: String?
    }
}
