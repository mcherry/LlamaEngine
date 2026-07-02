import Foundation
import LlamaEngine
import SwiftData

/// A single turn in a conversation: a user prompt, an assistant reply, or the
/// (usually hidden) system prompt. Token counts are optional and come from
/// Ollama's final streamed payload, for a future stats affordance.
@Model
public final class ChatMessage {
    public var id: UUID = UUID()
    /// Backing storage for `role`. See the `role` computed property.
    public var roleRaw: String = Role.user.rawValue
    public var content: String = ""
    /// Reasoning text from thinking models (deepseek-r1, qwen3, …), shown in a
    /// collapsible section. Empty for non-thinking models and non-assistant turns.
    public var thinking: String = ""
    public var createdAt: Date = Date.now
    public var promptTokens: Int?
    public var evalTokens: Int?
    /// Generation time for this reply, in nanoseconds (Ollama's `eval_duration`).
    /// Used with `evalTokens` to show tokens/second.
    public var evalDurationNanos: Int?
    /// Wall-clock time this reply took to generate, in seconds. Set when streaming
    /// finishes (any backend). `nil` while still generating or for non-assistant turns.
    public var generationSeconds: Double?
    /// Time to the first streamed token, in seconds (TTFT) — a key latency metric.
    public var firstTokenSeconds: Double?
    /// Pretty-printed JSON of the exact request that produced this reply, for the
    /// request inspector. `nil` for user turns.
    public var requestPayload: String?
    /// Encoded `[RetrievedChunkInfo]` when retrieval ran for this turn, for the
    /// retrieval inspector. `nil`/empty otherwise.
    public var retrievalData: Data?
    /// This turn's embedding (packed `[Float]`), computed lazily when the session uses
    /// the "retrieve relevant turns" history mode. `nil` until embedded.
    public var embeddingData: Data?
    /// Human-readable note describing what conversation-history management did for this
    /// turn (mode + action, e.g. the summary text). `nil` when history wasn't managed.
    public var historyNote: String?
    /// Encoded `[RetrievedChunkInfo]` for earlier turns pulled in by history retrieval.
    public var historyRetrievalData: Data?
    /// What the vision step produced for this turn: which model saw the image(s) and
    /// the description it generated (preprocessor pipeline), or a note that the image
    /// went natively to the primary model. `nil` when no image was involved.
    public var visionNote: String?
    /// True when the model stopped because it hit the context window (`done_reason:
    /// length`) rather than finishing — i.e. the reply was cut off. Drives an inline
    /// "reply cut off" notice. Always false for non-Ollama backends and user turns.
    public var wasTruncated: Bool = false
    /// PNG bytes of an image generated for this assistant turn (the image-generation
    /// backend). `nil` for text replies and user turns.
    public var generatedImageData: Data?
    /// Encoded `ImageGenInfo` (prompt + parameters) for a generated image, for the turn
    /// inspector and "Regenerate". `nil` for text replies and user turns.
    public var imageGenData: Data?

    /// Inverse side of `ChatSession.messages`.
    public var session: ChatSession?

    /// Typed accessor over `roleRaw`.
    public var role: Role {
        get { Role(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    /// Typed view over `embeddingData`.
    public var embedding: [Float]? {
        get { embeddingData.map(Vector.unpack) }
        set { embeddingData = newValue.map(Vector.pack) }
    }

    /// Decoded retrieval details for the inspector.
    public var retrievedChunks: [RetrievedChunkInfo] {
        guard let retrievalData else { return [] }
        return (try? JSONDecoder().decode([RetrievedChunkInfo].self, from: retrievalData)) ?? []
    }

    /// Decoded earlier-turn retrieval details for the inspector.
    public var historyRetrievedChunks: [RetrievedChunkInfo] {
        guard let historyRetrievalData else { return [] }
        return (try? JSONDecoder().decode([RetrievedChunkInfo].self, from: historyRetrievalData)) ?? []
    }

    /// Typed view over `imageGenData`: the prompt + parameters of a generated image.
    public var imageGenInfo: ImageGenInfo? {
        get { imageGenData.flatMap { try? JSONDecoder().decode(ImageGenInfo.self, from: $0) } }
        set { imageGenData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// Whether this message has any inspector data to show.
    public var hasInspectorData: Bool {
        requestPayload != nil || !retrievedChunks.isEmpty || firstTokenSeconds != nil
            || historyNote != nil || visionNote != nil || imageGenData != nil
    }

    /// Time-to-first-token as a compact label, e.g. "0.4s".
    public var firstTokenLabel: String? {
        guard let firstTokenSeconds, firstTokenSeconds >= 0 else { return nil }
        return String(format: "%.1fs", firstTokenSeconds)
    }

    /// Generation speed in tokens per second, when timing stats are available.
    public var tokensPerSecond: Double? {
        guard let evalTokens, let evalDurationNanos, evalDurationNanos > 0 else { return nil }
        return Double(evalTokens) / (Double(evalDurationNanos) / 1_000_000_000)
    }

    /// Compact human-readable generation time, e.g. "0.8s", "30s", or "1m 5s".
    public var generationDurationLabel: String? {
        guard let generationSeconds, generationSeconds > 0 else { return nil }
        if generationSeconds < 1 {
            return String(format: "%.1fs", generationSeconds)
        }
        let total = Int(generationSeconds.rounded())
        if total < 60 {
            return "\(total)s"
        }
        return "\(total / 60)m \(total % 60)s"
    }

    public init(role: Role, content: String, createdAt: Date = .now) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = createdAt
    }
}
