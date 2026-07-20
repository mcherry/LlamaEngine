import Foundation
import LlamaEngine

/// A plain, `Codable` snapshot of a `ChatSession`'s configuration — everything that
/// affects *how* a chat runs (backend, model, system prompt, generation, history,
/// retrieval, image, and speech settings) but not its messages, title, or timestamps.
/// Used to duplicate a session's setup ("new chat like this") and to save/apply reusable
/// presets.
///
/// Every field is optional so the format tolerates future additions: a preset saved
/// before a field existed simply omits it (decodes to `nil`) instead of failing, and
/// `ChatSession.apply(_:)` then leaves that field at the session's default.
public struct SessionConfig: Codable, Sendable {
    public var backendRaw: String?
    public var modelName: String?
    public var contextSize: Int?
    public var systemPrompt: String?
    public var contextModeRaw: String?
    public var historyModeRaw: String?
    public var reasoningRaw: String?
    public var visionModel: String?

    // Generation parameters (nil is meaningful here — it means "server default").
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var repeatPenalty: Double?
    public var seed: Int?
    public var stopSequences: [String]?
    public var maxResponseTokens: Int?
    public var appleSamplingRaw: String?

    // Image generation.
    public var imageModel: String?
    public var imageSize: Int?
    public var imageSteps: Int?
    public var imageCFG: Double?
    public var imageNegativePrompt: String?
    public var imageSeed: Int?
    public var imageVAE: String?
    public var imageSampler: String?
    public var imageUpscaler: String?
    public var imageUpscaleAmount: Int?
    public var imageLatentUpscalerSteps: Int?
    public var imageFaceCorrection: String?
    public var imageClipSkip: Bool?
    public var comfyTemplateID: String?

    // Text-to-speech (per chat).
    public var ttsEnabled: Bool?
    public var ttsEngineRaw: String?
    public var ttsAutoSpeak: Bool?

    public init() {}
}

/// A named, reusable `SessionConfig`. Stored app-side as JSON (like ComfyUI templates),
/// so it stays a plain value type with no SwiftData involvement.
public struct SessionPreset: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var config: SessionConfig

    public init(id: String = UUID().uuidString, name: String, config: SessionConfig) {
        self.id = id
        self.name = name
        self.config = config
    }
}

public extension ChatSession {
    /// Captures this session's configuration as a plain value (excludes messages, title,
    /// and timestamps).
    func configSnapshot() -> SessionConfig {
        var c = SessionConfig()
        c.backendRaw = backendRaw
        c.modelName = modelName
        c.contextSize = contextSize
        c.systemPrompt = systemPrompt
        c.contextModeRaw = contextModeRaw
        c.historyModeRaw = historyModeRaw
        c.reasoningRaw = reasoningRaw
        c.visionModel = visionModel
        c.temperature = temperature
        c.topP = topP
        c.topK = topK
        c.repeatPenalty = repeatPenalty
        c.seed = seed
        c.stopSequences = stopSequences
        c.maxResponseTokens = maxResponseTokens
        c.appleSamplingRaw = appleSamplingRaw
        c.imageModel = imageModel
        c.imageSize = imageSize
        c.imageSteps = imageSteps
        c.imageCFG = imageCFG
        c.imageNegativePrompt = imageNegativePrompt
        c.imageSeed = imageSeed
        c.imageVAE = imageVAE
        c.imageSampler = imageSampler
        c.imageUpscaler = imageUpscaler
        c.imageUpscaleAmount = imageUpscaleAmount
        c.imageLatentUpscalerSteps = imageLatentUpscalerSteps
        c.imageFaceCorrection = imageFaceCorrection
        c.imageClipSkip = imageClipSkip
        c.comfyTemplateID = comfyTemplateID
        c.ttsEnabled = ttsEnabled
        c.ttsEngineRaw = ttsEngineRaw
        c.ttsAutoSpeak = ttsAutoSpeak
        return c
    }

    /// Applies a configuration onto this session. For the non-optional session properties
    /// a `nil` field is skipped (leaving the session's current value); the generation
    /// parameters — where `nil` legitimately means "server default" — are set exactly as
    /// captured.
    func apply(_ c: SessionConfig) {
        if let v = c.backendRaw { backendRaw = v }
        if let v = c.modelName { modelName = v }
        if let v = c.contextSize { contextSize = v }
        if let v = c.systemPrompt { systemPrompt = v }
        if let v = c.contextModeRaw { contextModeRaw = v }
        if let v = c.historyModeRaw { historyModeRaw = v }
        if let v = c.reasoningRaw { reasoningRaw = v }
        if let v = c.visionModel { visionModel = v }

        temperature = c.temperature
        topP = c.topP
        topK = c.topK
        repeatPenalty = c.repeatPenalty
        seed = c.seed
        if let v = c.stopSequences { stopSequences = v }
        maxResponseTokens = c.maxResponseTokens
        if let v = c.appleSamplingRaw { appleSamplingRaw = v }

        if let v = c.imageModel { imageModel = v }
        if let v = c.imageSize { imageSize = v }
        if let v = c.imageSteps { imageSteps = v }
        if let v = c.imageCFG { imageCFG = v }
        if let v = c.imageNegativePrompt { imageNegativePrompt = v }
        imageSeed = c.imageSeed
        if let v = c.imageVAE { imageVAE = v }
        if let v = c.imageSampler { imageSampler = v }
        if let v = c.imageUpscaler { imageUpscaler = v }
        if let v = c.imageUpscaleAmount { imageUpscaleAmount = v }
        if let v = c.imageLatentUpscalerSteps { imageLatentUpscalerSteps = v }
        if let v = c.imageFaceCorrection { imageFaceCorrection = v }
        if let v = c.imageClipSkip { imageClipSkip = v }
        if let v = c.comfyTemplateID { comfyTemplateID = v }

        if let v = c.ttsEnabled { ttsEnabled = v }
        if let v = c.ttsEngineRaw { ttsEngineRaw = v }
        if let v = c.ttsAutoSpeak { ttsAutoSpeak = v }
    }
}
