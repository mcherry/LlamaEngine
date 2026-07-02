import Foundation

/// How Apple's on-device model picks tokens. Apple bundles into one choice what
/// Ollama splits across top-k/top-p, so the testbed exposes it as a single picker.
/// Plain Swift (no FoundationModels import) so it compiles on the macOS 15 target.
public enum AppleSamplingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Let Apple choose (the framework default).
    case automatic
    /// Always pick the most likely token — deterministic and reproducible.
    case greedy
    /// Sample from a fixed number of high-probability tokens.
    case topK
    /// Nucleus sampling: a variable set of tokens above a probability threshold.
    case topP

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .greedy: return "Greedy (deterministic)"
        case .topK: return "Top-K"
        case .topP: return "Top-P (nucleus)"
        }
    }

    /// Whether this mode accepts a seed (the random modes do; greedy/automatic don't).
    public var usesSeed: Bool {
        self == .topK || self == .topP
    }
}

/// The subset of generation controls Apple's Foundation Models exposes. A plain
/// `Sendable` value passed to `FoundationModelsBackend`. Far smaller than Ollama's
/// set: no repeat penalty, no stop sequences, no context override.
public struct AppleGenerationOptions: Sendable, Equatable {
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var samplingMode: AppleSamplingMode
    public var topK: Int?
    public var topP: Double?
    public var seed: Int?

    public init(temperature: Double? = nil,
         maximumResponseTokens: Int? = nil,
         samplingMode: AppleSamplingMode = .automatic,
         topK: Int? = nil,
         topP: Double? = nil,
         seed: Int? = nil) {
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.samplingMode = samplingMode
        self.topK = topK
        self.topP = topP
        self.seed = seed
    }

    /// True when everything is at its default (nothing overridden).
    public var isEmpty: Bool {
        temperature == nil
            && maximumResponseTokens == nil
            && samplingMode == .automatic
            && seed == nil
    }
}
