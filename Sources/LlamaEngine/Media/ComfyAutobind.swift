import Foundation

extension ComfyWorkflowTemplate {
    /// Node types treated as the sampler (the anchor auto-bind reasons from), in priority order.
    static let samplerTypes = ["KSampler", "KSamplerAdvanced"]
    /// Candidate model-filename input names on a loader node, in priority order.
    static let modelInputNames = ["ckpt_name", "unet_name", "model_name"]

    /// Builds a template from an API-format workflow by *auto-detecting* the standard txt2img
    /// bindings — so importing a workflow exported from ComfyUI (Save → API Format) generally "just
    /// works" without hand-mapping. It anchors on the sampler node and follows its links: the
    /// `positive`/`negative` conditioning inputs locate the prompt encoders, `latent_image` the size
    /// node, and `model` the checkpoint/UNet loader; the sampler's own scalars give seed/steps/cfg/
    /// sampler/scheduler/denoise. Only inputs that actually exist are bound; anything it can't infer
    /// is simply left unbound (the workflow's authored value stands). Non-standard graphs may bind
    /// partially — a host can let the user adjust afterward.
    public static func autobound(name: String, workflowJSON: Data) -> ComfyWorkflowTemplate {
        ComfyWorkflowTemplate(name: name, workflowJSON: workflowJSON,
                              parameters: detectedParameters(in: workflowJSON))
    }

    /// Auto-binds a workflow and returns it only if it's a usable **text-to-image** pipeline
    /// (a prompt, a model, and a sampler seed were detected); otherwise `nil`. This is the gate a
    /// host uses to accept a workflow — non-txt2img graphs (face swap, upscale, editing) are rejected.
    public static func textToImage(name: String, workflowJSON: Data) -> ComfyWorkflowTemplate? {
        let template = autobound(name: name, workflowJSON: workflowJSON)
        return template.isTextToImage ? template : nil
    }

    /// The bindings auto-detected from an API-format workflow. Pure/testable; returns `[]` when there
    /// is no recognizable sampler to anchor on.
    static func detectedParameters(in workflowJSON: Data) -> [ComfyParameter] {
        guard let root = try? JSONSerialization.jsonObject(with: workflowJSON) as? [String: Any] else {
            return []
        }
        func node(_ id: String) -> [String: Any]? { root[id] as? [String: Any] }
        func classType(_ id: String) -> String? { node(id)?["class_type"] as? String }
        func inputs(_ id: String) -> [String: Any] { node(id)?["inputs"] as? [String: Any] ?? [:] }
        /// The source node id of a `[nodeID, slot]` graph link on `id.input`, else `nil`.
        func linkedNode(_ id: String, _ input: String) -> String? {
            guard let link = inputs(id)[input] as? [Any], link.count == 2,
                  let source = link.first as? String else { return nil }
            return source
        }
        /// The model-filename input on a loader node (`ckpt_name`/`unet_name`/…), else `nil`.
        func modelFileInput(_ id: String) -> String? {
            let ins = inputs(id)
            return modelInputNames.first { ins[$0] != nil }
        }
        /// Walks the `model` chain from `start` through any model-patch nodes (ModelSampling*,
        /// LoraLoader, …) to the loader that actually names a file. Loaders don't have a `model`
        /// input, so the walk terminates there; the `visited` guard stops cycles.
        func resolveModelLoader(from start: String?) -> (node: String, input: String)? {
            var current = start
            var visited = Set<String>()
            while let id = current, visited.insert(id).inserted {
                if let input = modelFileInput(id) { return (id, input) }
                current = linkedNode(id, "model")
            }
            return nil
        }

        // Anchor on the sampler (first matching type, deterministic by sorted id).
        guard let sampler = root.keys.sorted().first(where: { samplerTypes.contains(classType($0) ?? "") })
        else { return [] }
        let samplerInputs = inputs(sampler)

        var params: [ComfyParameter] = []
        /// Binds a role only when the target node actually declares that input.
        func bind(_ key: ComfyParameterKey, _ nodeID: String, _ input: String, _ type: ComfyParameterType) {
            guard inputs(nodeID)[input] != nil else { return }
            params.append(ComfyParameter(key: key, nodeID: nodeID, input: input, type: type))
        }

        // Sampler scalars. KSamplerAdvanced names its seed `noise_seed`.
        bind(.seed, sampler, samplerInputs["noise_seed"] != nil ? "noise_seed" : "seed", .int)
        bind(.steps, sampler, "steps", .int)
        bind(.cfg, sampler, "cfg", .double)
        bind(.sampler, sampler, "sampler_name", .string)
        bind(.scheduler, sampler, "scheduler", .string)
        bind(.denoise, sampler, "denoise", .double)

        // Prompts: follow the sampler's conditioning links to the encoder's `text` input.
        if let positive = linkedNode(sampler, "positive") { bind(.prompt, positive, "text", .string) }
        if let negative = linkedNode(sampler, "negative") { bind(.negativePrompt, negative, "text", .string) }

        // Size: the latent node the sampler draws from.
        if let latent = linkedNode(sampler, "latent_image") {
            bind(.width, latent, "width", .int)
            bind(.height, latent, "height", .int)
        }

        // Model: walk from the sampler's `model` input through any model-patch nodes
        // (ModelSamplingAuraFlow, LoraLoader, …) to the loader that names a checkpoint/UNet.
        if let loader = resolveModelLoader(from: linkedNode(sampler, "model")) {
            bind(.model, loader.node, loader.input, .string)
        }

        return params
    }
}
