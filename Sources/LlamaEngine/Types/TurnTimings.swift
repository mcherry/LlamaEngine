import Foundation

/// Server-reported timings for one assistant turn.
///
/// llama.cpp returns a `timings` block on the final streamed chunk; this is that block in
/// typed form. It is the difference between "the agent took a while" and "the agent spent
/// 40 seconds re-prefilling a prompt the server had already cached", which is exactly the
/// distinction a tool-calling loop needs to be tuned against.
///
/// Every field is optional: Ollama and Apple Intelligence don't report timings, and llama.cpp
/// builds vary in which keys they include. Absent means absent, never zero.
public struct TurnTimings: Codable, Sendable, Equatable {

    /// Prompt tokens the server actually evaluated this turn (`prompt_n`). With prefix
    /// caching this is only the *new* part of the prompt, not its whole length.
    public var promptTokens: Int?
    /// Wall time spent prefilling (`prompt_ms`).
    public var promptMilliseconds: Double?
    /// Prefill throughput (`prompt_per_second`).
    public var promptTokensPerSecond: Double?

    /// Tokens generated (`predicted_n`).
    public var predictedTokens: Int?
    /// Wall time spent generating (`predicted_ms`).
    public var predictedMilliseconds: Double?
    /// Decode throughput (`predicted_per_second`).
    public var predictedTokensPerSecond: Double?

    /// Prompt tokens served from the server's KV cache instead of being re-evaluated
    /// (`cache_n`). Reported only by builds that expose it.
    public var cachedTokens: Int?

    public init(promptTokens: Int? = nil,
                promptMilliseconds: Double? = nil,
                promptTokensPerSecond: Double? = nil,
                predictedTokens: Int? = nil,
                predictedMilliseconds: Double? = nil,
                predictedTokensPerSecond: Double? = nil,
                cachedTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.promptMilliseconds = promptMilliseconds
        self.promptTokensPerSecond = promptTokensPerSecond
        self.predictedTokens = predictedTokens
        self.predictedMilliseconds = predictedMilliseconds
        self.predictedTokensPerSecond = predictedTokensPerSecond
        self.cachedTokens = cachedTokens
    }

    /// True when the server reported nothing at all, so callers can skip storing it.
    public var isEmpty: Bool {
        promptTokens == nil && promptMilliseconds == nil && promptTokensPerSecond == nil
            && predictedTokens == nil && predictedMilliseconds == nil
            && predictedTokensPerSecond == nil && cachedTokens == nil
    }

    /// The full prompt length: what was evaluated plus what the cache covered.
    public var totalPromptTokens: Int? {
        switch (promptTokens, cachedTokens) {
        case let (.some(evaluated), .some(cached)): return evaluated + cached
        case let (.some(evaluated), .none): return evaluated
        case let (.none, .some(cached)): return cached
        case (.none, .none): return nil
        }
    }

    /// Fraction of the prompt the server didn't have to re-evaluate, `0...1`.
    ///
    /// A tool loop that keeps its prompt prefix stable should sit near 1 after the first
    /// round; a number that collapses mid-session means something is rewriting the prefix
    /// — the measured cost of which is a full re-prefill.
    public var cacheHitRate: Double? {
        guard let cachedTokens, let total = totalPromptTokens, total > 0 else { return nil }
        return Double(cachedTokens) / Double(total)
    }
}
