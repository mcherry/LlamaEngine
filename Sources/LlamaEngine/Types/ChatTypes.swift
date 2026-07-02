import Foundation

/// Per-session control over a thinking model's reasoning (Ollama's `think` flag).
/// `auto` lets the model decide (deepseek-r1 reasons by default); `on` forces it
/// (errors on models that don't support thinking); `off` suppresses it.
public enum ReasoningMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case on
    case off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .on: return "Always on"
        case .off: return "Off"
        }
    }

    /// The `think` value to send, or `nil` to omit (model default).
    public var think: Bool? {
        switch self {
        case .auto: return nil
        case .on: return true
        case .off: return false
        }
    }
}

/// A single message in an outgoing chat request. Distinct from a persisted message
/// model: this is a plain `Sendable` value, safe to pass to a background task.
public struct ChatTurn: Codable, Sendable {
    public let role: String
    public let content: String
    /// Base64-encoded images for vision models (Ollama's `images` field). Omitted
    /// from the wire payload when empty.
    public let images: [String]

    public init(role: String, content: String, images: [String] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    enum CodingKeys: String, CodingKey { case role, content, images }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if !images.isEmpty { try c.encode(images, forKey: .images) }
    }
}

/// Sampling/generation parameters for a chat request. Every field is optional so
/// only the ones the user sets are sent (others fall back to the server default). A
/// fixed `seed` makes Ollama output reproducible — the backbone of repeatable tests.
public struct GenerationParameters: Sendable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var repeatPenalty: Double?
    public var seed: Int?
    public var stop: [String]

    public init(temperature: Double? = nil,
                topP: Double? = nil,
                topK: Int? = nil,
                repeatPenalty: Double? = nil,
                seed: Int? = nil,
                stop: [String] = []) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.seed = seed
        self.stop = stop
    }

    /// True when nothing is set, so the request carries only `num_ctx`/`num_predict`.
    public var isEmpty: Bool {
        temperature == nil && topP == nil && topK == nil
            && repeatPenalty == nil && seed == nil && stop.isEmpty
    }
}

/// Everything needed to issue one chat request. A plain `Sendable` value type.
public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [ChatTurn]
    public var contextSize: Int
    public var stream: Bool
    public var numPredict: Int?
    /// When set, toggles Ollama's reasoning. `false` asks thinking models to answer
    /// directly (used for title generation). Omitted from the request when `nil`.
    public var think: Bool?
    /// How long Ollama keeps the model loaded after this request (e.g. "30m", "-1" to
    /// keep it resident). Omitted from the request when `nil`, using the server default.
    public var keepAlive: String?
    /// Sampling parameters (temperature, seed, …). Empty by default.
    public var parameters: GenerationParameters

    public init(model: String,
                messages: [ChatTurn],
                contextSize: Int,
                stream: Bool = true,
                numPredict: Int? = nil,
                think: Bool? = nil,
                keepAlive: String? = nil,
                parameters: GenerationParameters = GenerationParameters()) {
        self.model = model
        self.messages = messages
        self.contextSize = contextSize
        self.stream = stream
        self.numPredict = numPredict
        self.think = think
        self.keepAlive = keepAlive
        self.parameters = parameters
    }
}

/// One decoded delta from the streamed chat response.
public struct ChatChunk: Sendable {
    public var contentDelta: String
    public var done: Bool
    public var promptTokens: Int?
    public var evalTokens: Int?
    public var evalDurationNanos: Int?
    /// When true, `contentDelta` is the *entire* reply so far (a cumulative snapshot)
    /// and should replace the message body rather than append. Apple's Foundation
    /// Models stream works this way; Ollama streams incremental deltas (false).
    public var isReplacement: Bool = false
    /// Incremental reasoning text from thinking models (Ollama's `message.thinking`).
    /// Accumulated separately from the answer.
    public var thinkingDelta: String = ""
    /// Ollama's reason for finishing (`done_reason`): "stop" (natural end), "length"
    /// (hit the context/token limit, so the reply was cut off), etc. nil until `done`.
    public var doneReason: String? = nil

    public init(contentDelta: String,
                done: Bool,
                promptTokens: Int? = nil,
                evalTokens: Int? = nil,
                evalDurationNanos: Int? = nil,
                isReplacement: Bool = false,
                thinkingDelta: String = "",
                doneReason: String? = nil) {
        self.contentDelta = contentDelta
        self.done = done
        self.promptTokens = promptTokens
        self.evalTokens = evalTokens
        self.evalDurationNanos = evalDurationNanos
        self.isReplacement = isReplacement
        self.thinkingDelta = thinkingDelta
        self.doneReason = doneReason
    }
}
