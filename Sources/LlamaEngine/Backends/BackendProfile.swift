import Foundation

/// A data-driven description of what a backend can do, so the UI can be *generated*
/// from capabilities instead of hardcoding `if backend == .ollama` throughout the app.
/// Adding a new backend means adding its client and its profile — the settings and
/// session screens adapt automatically, and never show a control the backend can't use.
public struct BackendProfile: Sendable, Equatable {
    public var kind: BackendKind

    /// Needs a server URL to connect (a remote HTTP backend).
    public var needsServerURL: Bool
    /// Offers a list of selectable models (shows a model picker).
    public var listsModels: Bool
    /// The user chooses the model from a list (Ollama). `false` when the server dictates
    /// a single loaded model (llama.cpp), which the app auto-selects and shows read-only.
    public var modelSelectable: Bool
    /// The app controls the context-window size (e.g. Ollama's `num_ctx`). `false` when
    /// the window is fixed by the server launch flags or the on-device model, in which
    /// case the app discovers it rather than letting the user set it.
    public var contextWindowAdjustable: Bool
    /// Accepts the standard sampling parameters (temperature, top-p/-k, repeat penalty,
    /// seed, stop) that the app exposes. Apple's on-device model has its own separate
    /// option set, so it's `false` here.
    public var supportsSampling: Bool
    /// Can toggle/adjust reasoning ("thinking") on capable models.
    public var supportsReasoning: Bool
    /// Can retrieve over attachments and web sources via embeddings (RAG).
    public var supportsRetrieval: Bool
    /// Can accept image input (vision), natively or via a preprocessor model.
    public var supportsVision: Bool
    /// Supports keeping the model resident between turns (Ollama's `keep_alive`).
    public var supportsKeepAlive: Bool
    /// Supports pulling, listing, and deleting models on the server.
    public var supportsModelManagement: Bool
    /// Produces images instead of streamed text (an image-generation backend).
    public var producesImages: Bool
    /// Runs entirely on-device, with no server to configure.
    public var isOnDevice: Bool
    /// An optional add-on that must be enabled (a Feature toggle) before it appears as a
    /// selectable backend.
    public var isOptionalFeature: Bool

    public init(kind: BackendKind,
                needsServerURL: Bool,
                listsModels: Bool,
                modelSelectable: Bool,
                contextWindowAdjustable: Bool,
                supportsSampling: Bool,
                supportsReasoning: Bool,
                supportsRetrieval: Bool,
                supportsVision: Bool,
                supportsKeepAlive: Bool,
                supportsModelManagement: Bool,
                producesImages: Bool,
                isOnDevice: Bool,
                isOptionalFeature: Bool) {
        self.kind = kind
        self.needsServerURL = needsServerURL
        self.listsModels = listsModels
        self.modelSelectable = modelSelectable
        self.contextWindowAdjustable = contextWindowAdjustable
        self.supportsSampling = supportsSampling
        self.supportsReasoning = supportsReasoning
        self.supportsRetrieval = supportsRetrieval
        self.supportsVision = supportsVision
        self.supportsKeepAlive = supportsKeepAlive
        self.supportsModelManagement = supportsModelManagement
        self.producesImages = producesImages
        self.isOnDevice = isOnDevice
        self.isOptionalFeature = isOptionalFeature
    }

    /// A text/LLM chat backend (as opposed to an image generator).
    public var isChatBackend: Bool { !producesImages }
}

public extension BackendKind {
    /// The capability profile for this backend. The single source of truth the UI reads
    /// to decide which controls to show.
    var profile: BackendProfile {
        switch self {
        case .ollama:
            return BackendProfile(
                kind: .ollama,
                needsServerURL: true, listsModels: true, modelSelectable: true, contextWindowAdjustable: true,
                supportsSampling: true, supportsReasoning: true, supportsRetrieval: true,
                supportsVision: true, supportsKeepAlive: true, supportsModelManagement: true,
                producesImages: false, isOnDevice: false, isOptionalFeature: false)
        case .llamaServer:
            // A llama.cpp server serves one model at a context window fixed at launch, so
            // model management, keep-alive, and an adjustable window don't apply.
            return BackendProfile(
                kind: .llamaServer,
                needsServerURL: true, listsModels: true, modelSelectable: false, contextWindowAdjustable: false,
                supportsSampling: true, supportsReasoning: true, supportsRetrieval: true,
                supportsVision: false, supportsKeepAlive: false, supportsModelManagement: false,
                producesImages: false, isOnDevice: false, isOptionalFeature: false)
        case .appleIntelligence:
            // On-device: no server, single model, its own generation options.
            return BackendProfile(
                kind: .appleIntelligence,
                needsServerURL: false, listsModels: false, modelSelectable: false, contextWindowAdjustable: false,
                supportsSampling: false, supportsReasoning: false, supportsRetrieval: true,
                supportsVision: false, supportsKeepAlive: false, supportsModelManagement: false,
                producesImages: false, isOnDevice: true, isOptionalFeature: false)
        case .imageGeneration:
            return BackendProfile(
                kind: .imageGeneration,
                needsServerURL: true, listsModels: true, modelSelectable: false, contextWindowAdjustable: false,
                supportsSampling: false, supportsReasoning: false, supportsRetrieval: false,
                supportsVision: false, supportsKeepAlive: false, supportsModelManagement: false,
                producesImages: true, isOnDevice: false, isOptionalFeature: true)
        }
    }
}
