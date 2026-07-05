import Foundation
import LlamaEngine
import SwiftData

/// A saved conversation plus its per-session configuration: which model to use,
/// the context size, and the system prompt. Auto-saves via SwiftData and reappears
/// on relaunch. Deleting a session cascades to its messages.
@Model
public final class ChatSession {
    public var id: UUID = UUID()
    public var title: String = "New Session"
    /// The Ollama model name this session talks to (e.g. "qwen-14b").
    public var modelName: String = ""
    /// Per-session context window (`num_ctx`) sent with each request.
    public var contextSize: Int = 32768
    /// The system prompt sent as the leading `system` message.
    public var systemPrompt: String = ""
    public var createdAt: Date = Date.now
    /// Bumped when a turn completes, so the sidebar sorts most-recent first.
    public var updatedAt: Date = Date.now
    /// True while the title is auto-generated. Set false once the user renames it,
    /// so auto-naming stops overwriting their choice.
    public var titleIsAuto: Bool = true
    /// How attached files are fitted into the prompt. See `ContextMode`.
    public var contextModeRaw: String = ContextMode.auto.rawValue
    /// Which engine answers this session. See `BackendKind`.
    public var backendRaw: String = BackendKind.ollama.rawValue

    // Generation parameters (Ollama). Each is optional: nil means "use the server
    // default". A fixed `seed` makes output reproducible across runs.
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var repeatPenalty: Double?
    public var seed: Int?
    public var stopSequences: [String] = []

    // Apple Intelligence generation controls (reuses temperature/topK/topP/seed above).
    public var maxResponseTokens: Int?
    public var appleSamplingRaw: String = AppleSamplingMode.automatic.rawValue
    /// How to handle reasoning for thinking models (Ollama `think`). See `ReasoningMode`.
    public var reasoningRaw: String = ReasoningMode.auto.rawValue
    /// How conversation history is fitted into the window. See `HistoryMode`.
    public var historyModeRaw: String = HistoryMode.full.rawValue
    /// Cached rolling summary of older turns (for `.summarize` history mode).
    public var historySummary: String = ""
    /// `createdAt` of the newest message already folded into `historySummary`.
    public var summarizedUntil: Date?
    /// Vision model used to describe attached images before sending to the primary
    /// model (the multi-model "eyes" pipeline). Empty = no dedicated vision model;
    /// images then go natively to the primary model if it supports vision.
    public var visionModel: String = ""

    // Image generation (when `backend == .imageGeneration`). The server URL + kind are
    // app-level (Settings); these are the per-chat model and parameters.
    public var imageModel: String = ""
    public var imageSize: Int = 640
    public var imageSteps: Int = 20
    public var imageCFG: Double = 7.5
    public var imageNegativePrompt: String = ""
    public var imageSeed: Int?
    public var imageVAE: String = ""
    /// Sampling algorithm (`sampler_name`). See `ImageSampler`.
    public var imageSampler: String = "euler_a"
    /// Post-generation upscaler, or empty for none. See `ImageUpscaler`.
    public var imageUpscaler: String = ""
    /// Upscale factor (2 or 4) when an upscaler is set.
    public var imageUpscaleAmount: Int = 4
    /// Steps for the latent upscaler (only used when the latent upscaler is chosen).
    public var imageLatentUpscalerSteps: Int = 10
    /// Face-restoration model, or empty for none. See `FaceCorrection`.
    public var imageFaceCorrection: String = ""
    /// Skip the last CLIP text-encoder layer.
    public var imageClipSkip: Bool = false

    // Text-to-speech (per chat). Voices/speed are app-level (Settings).
    public var ttsEnabled: Bool = false
    public var ttsEngineRaw: String = TTSEngine.apple.rawValue
    public var ttsAutoSpeak: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    public var messages: [ChatMessage] = []

    @Relationship(deleteRule: .cascade, inverse: \Attachment.session)
    public var attachments: [Attachment] = []

    public init(title: String = "New Session",
         modelName: String = "",
         contextSize: Int = 32768,
         systemPrompt: String = "") {
        self.id = UUID()
        self.title = title
        self.modelName = modelName
        self.contextSize = contextSize
        self.systemPrompt = systemPrompt
        self.createdAt = .now
        self.updatedAt = .now
        self.titleIsAuto = true
        self.contextModeRaw = ContextMode.auto.rawValue
        self.backendRaw = BackendKind.ollama.rawValue
    }

    /// Typed accessor over `contextModeRaw`.
    public var contextMode: ContextMode {
        get { ContextMode(rawValue: contextModeRaw) ?? .auto }
        set { contextModeRaw = newValue.rawValue }
    }

    /// Typed accessor over `backendRaw`.
    public var backend: BackendKind {
        get { BackendKind(rawValue: backendRaw) ?? .ollama }
        set { backendRaw = newValue.rawValue }
    }

    /// Typed accessor over `historyModeRaw`.
    public var historyMode: HistoryMode {
        get { HistoryMode(rawValue: historyModeRaw) ?? .full }
        set { historyModeRaw = newValue.rawValue }
    }

    /// Typed accessor over `ttsEngineRaw`.
    public var ttsEngine: TTSEngine {
        get { TTSEngine(rawValue: ttsEngineRaw) ?? .apple }
        set { ttsEngineRaw = newValue.rawValue }
    }

    /// The session's sampling parameters as a plain `Sendable` value for requests.
    public var generationParameters: GenerationParameters {
        GenerationParameters(temperature: temperature,
                             topP: topP,
                             topK: topK,
                             repeatPenalty: repeatPenalty,
                             seed: seed,
                             stop: stopSequences)
    }

    /// Typed accessor over `appleSamplingRaw`.
    public var appleSamplingMode: AppleSamplingMode {
        get { AppleSamplingMode(rawValue: appleSamplingRaw) ?? .automatic }
        set { appleSamplingRaw = newValue.rawValue }
    }

    /// Typed accessor over `reasoningRaw`.
    public var reasoningMode: ReasoningMode {
        get { ReasoningMode(rawValue: reasoningRaw) ?? .auto }
        set { reasoningRaw = newValue.rawValue }
    }

    /// The session's Apple Intelligence generation controls as a `Sendable` value.
    public var appleOptions: AppleGenerationOptions {
        AppleGenerationOptions(temperature: temperature,
                               maximumResponseTokens: maxResponseTokens,
                               samplingMode: appleSamplingMode,
                               topK: topK,
                               topP: topP,
                               seed: seed)
    }

    /// Whether the session has enough configuration to send. Ollama needs a chosen
    /// model; Apple Intelligence has a single on-device model, so it's always ready.
    public var isConfigured: Bool {
        switch backend {
        case .ollama: return !modelName.isEmpty
        case .appleIntelligence: return true
        case .imageGeneration: return !imageModel.isEmpty
        }
    }

    /// Messages in chronological order for display.
    public var orderedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Attachments oldest-first, for stable context ordering and display.
    public var orderedAttachments: [Attachment] {
        attachments.sorted { $0.createdAt < $1.createdAt }
    }
}
