import Foundation

/// A model offered by an image-generation server, for the Settings picker.
public struct ImageModel: Identifiable, Hashable, Sendable {
    /// Stable identifier the server expects (e.g. `"sd-v1-5"`).
    public let id: String
    /// Human-facing name (often the same as `id`).
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A single image request: the resolved prompt plus the parameters chosen in Settings.
public struct ImageRequest: Sendable {
    public var prompt: String
    public var negativePrompt: String
    public var model: String
    public var steps: Int
    public var width: Int
    public var height: Int
    /// Prompt-adherence strength (Stable Diffusion CFG/guidance). Higher = stronger style adherence.
    public var cfgScale: Double
    /// VAE model name to apply, or empty for the model's built-in VAE.
    public var vae: String
    /// Fixed seed for reproducibility, or `nil` for a fresh random one each time.
    public var seed: Int?

    public init(prompt: String, negativePrompt: String, model: String, steps: Int,
                width: Int, height: Int, cfgScale: Double, vae: String, seed: Int?) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.model = model
        self.steps = steps
        self.width = width
        self.height = height
        self.cfgScale = cfgScale
        self.vae = vae
        self.seed = seed
    }
}

/// A snapshot of the parameters that produced a generated image, stored on the
/// assistant message for the turn inspector and for "Regenerate". Codable so it can be
/// persisted compactly on `ChatMessage` (see `ChatMessage.imageGenInfo`).
public struct ImageGenInfo: Codable, Sendable {
    public var prompt: String
    public var negativePrompt: String
    public var model: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var cfgScale: Double
    public var vae: String
    public var seed: Int?

    public init(prompt: String, negativePrompt: String, model: String, width: Int, height: Int,
         steps: Int, cfgScale: Double, vae: String, seed: Int?) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.model = model
        self.width = width
        self.height = height
        self.steps = steps
        self.cfgScale = cfgScale
        self.vae = vae
        self.seed = seed
    }

    /// Captures the parameters of a request that was sent.
    public init(_ request: ImageRequest) {
        prompt = request.prompt
        negativePrompt = request.negativePrompt
        model = request.model
        width = request.width
        height = request.height
        steps = request.steps
        cfgScale = request.cfgScale
        vae = request.vae
        seed = request.seed
    }

    /// `"WIDTHxHEIGHT"`, for display.
    public var sizeLabel: String { "\(width)x\(height)" }
}

/// Errors surfaced by the image-generation layer.
public enum ImageGenError: LocalizedError {
    case invalidURL
    case http(Int)
    case noModelSelected
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The image server address isn't a valid URL."
        case .http(let code): return "The image server returned HTTP \(code)."
        case .noModelSelected: return "Pick an image model in Settings first."
        case .failed(let message): return message
        }
    }
}

/// A local image-generation backend. New servers are added by writing another conforming type and
/// an `ImageBackendKind` case — there is no user-facing way to register backends. `listModels()`
/// powers the Settings Test + model picker; `generate()` returns the rendered image bytes.
public protocol ImageProvider: Sendable {
    func listModels() async throws -> [ImageModel]
    func listVAEs() async throws -> [ImageModel]
    func generate(_ request: ImageRequest) async throws -> Data
}

extension ImageProvider {
    /// Backends without separate VAEs report none.
    public func listVAEs() async throws -> [ImageModel] { [] }
}

/// Gating + config helpers for the optional image-generation feature.
public enum ImageGen {
    /// The single gate every "Generate" affordance checks: enabled, with a non-empty server URL.
    /// (Generation additionally needs a selected model; that's reported as a clear error at call time.)
    public static func isConfigured(enabled: Bool, serverURL: String) -> Bool {
        enabled && !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Parses a `"WIDTHxHEIGHT"` size string (e.g. `"768x512"`) used by the image-size pickers.
public enum ImageDimensions {
    /// Two positive integers separated by `x` (case-insensitive), else `nil`.
    public static func parse(_ raw: String) -> (width: Int, height: Int)? {
        let parts = raw.split(whereSeparator: { $0 == "x" || $0 == "X" })
        guard parts.count == 2,
              let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0 else { return nil }
        return (w, h)
    }
}
