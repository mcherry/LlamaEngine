import Foundation

/// An `ImageProvider` backed by ComfyUI. Wraps a `ComfyWorkflowTemplate` (typically `.textToImage`)
/// so selecting it drives generation through the same `ImageRequest` path as any other image backend —
/// the template's bindings decide where the prompt/seed/steps/size/model land in the graph, so a
/// txt2img template behaves just like a fixed txt2img server. Model listing reads the server's
/// `/object_info` combos (its installed checkpoints/UNets). Without a template the provider still lists
/// models and validates (for a Settings connection test), but `generate` reports that a template must
/// be selected. A small `Sendable` value, safe to hand to a background task.
public struct ComfyUIProvider: ImageProvider {
    let baseURLString: String
    /// The workflow this provider runs. `nil` supports connection-test / model-listing only.
    public let template: ComfyWorkflowTemplate?
    /// Timeout for an individual HTTP call.
    var timeout: TimeInterval = 60
    /// Overall budget for one generation, across queueing + execution + polling.
    var pollTimeout: TimeInterval = 600

    public init(baseURLString: String, template: ComfyWorkflowTemplate? = nil,
                timeout: TimeInterval = 60, pollTimeout: TimeInterval = 600) {
        self.baseURLString = baseURLString
        self.template = template
        self.timeout = timeout
        self.pollTimeout = pollTimeout
    }

    /// Node-type / input pairs whose `/object_info` combo lists the installed base models.
    static var modelLoaders: [(node: String, input: String)] {
        [("CheckpointLoaderSimple", "ckpt_name"), ("UNETLoader", "unet_name")]
    }

    /// The checkpoints/UNets the server has, from `/object_info`. Prefers the template's own model
    /// node when it binds one; otherwise unions the well-known loader combos.
    public func listModels() async throws -> [ImageModel] {
        let info = ComfyObjectInfo.parse(try await client().objectInfo())
        return Self.modelNames(from: info, template: template).map { ImageModel(id: $0, name: $0) }
    }

    /// The VAEs the server has (`VAELoader.vae_name`), for the optional VAE picker.
    public func listVAEs() async throws -> [ImageModel] {
        let info = ComfyObjectInfo.parse(try await client().objectInfo())
        return (info.comboOptions(node: "VAELoader", input: "vae_name") ?? []).map { ImageModel(id: $0, name: $0) }
    }

    /// Runs the template's workflow with `request` mapped onto its bindings, returning the first
    /// rendered image. A `nil` seed is resolved to a fresh random one (as Easy Diffusion does).
    public func generate(_ request: ImageRequest) async throws -> Data {
        guard let template else {
            throw ImageGenError.failed("Select a ComfyUI workflow template first.")
        }
        var resolved = request
        if resolved.seed == nil { resolved.seed = Int.random(in: 0...Int(UInt32.max)) }
        let images = try await client().run(workflow: template.workflowJSON,
                                            inputs: template.inputs(for: resolved))
        guard let first = images.first else { throw ImageGenError.failed("ComfyUI produced no image.") }
        return first
    }

    /// Pre-flight check of the template against the server (missing custom nodes / model files),
    /// read-only. Empty when there's no template or nothing's wrong. Use it to warn before running.
    public func validate() async throws -> [ComfyValidationIssue] {
        guard let template else { return [] }
        return try await client().validate(workflow: template.workflowJSON)
    }

    // MARK: - Helpers

    private func client() throws -> ComfyUIClient {
        guard let client = ComfyUIClient(baseURLString: baseURLString, timeout: timeout, pollTimeout: pollTimeout) else {
            throw ImageGenError.invalidURL
        }
        return client
    }

    /// The installed base-model names implied by a schema, deduped in a stable order. Prefers the
    /// template's bound model node; falls back to the union of the well-known loaders. Pure/testable.
    static func modelNames(from info: ComfyObjectInfo, template: ComfyWorkflowTemplate?) -> [String] {
        var names: [String] = []
        if let modelParam = template?.modelParameter,
           let classType = template?.classType(ofNode: modelParam.nodeID),
           let options = info.comboOptions(node: classType, input: modelParam.input) {
            names = options
        } else {
            for loader in modelLoaders {
                names.append(contentsOf: info.comboOptions(node: loader.node, input: loader.input) ?? [])
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
