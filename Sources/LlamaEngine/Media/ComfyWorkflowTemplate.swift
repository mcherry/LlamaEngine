import Foundation

/// A friendly, backend-agnostic parameter role. Binding these onto a workflow's nodes lets a host
/// drive an arbitrary ComfyUI graph from a simple form — or straight from an `ImageRequest` — without
/// knowing the graph's node ids (e.g. `.prompt` → node `"6"`, input `"text"`).
public enum ComfyParameterKey: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case prompt
    case negativePrompt
    case model
    case vae
    case seed
    case steps
    case cfg
    case sampler
    case scheduler
    case denoise
    case width
    case height

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .prompt: return "Prompt"
        case .negativePrompt: return "Negative prompt"
        case .model: return "Model"
        case .vae: return "VAE"
        case .seed: return "Seed"
        case .steps: return "Steps"
        case .cfg: return "CFG scale"
        case .sampler: return "Sampler"
        case .scheduler: return "Scheduler"
        case .denoise: return "Denoise"
        case .width: return "Width"
        case .height: return "Height"
        }
    }
}

/// The value type of a bound input, so the mapper injects it into the workflow correctly.
public enum ComfyParameterType: String, Codable, Sendable, Hashable {
    case string
    case int
    case double
    case image
}

/// Binds one friendly `ComfyParameterKey` to a specific node input in a workflow — the address a
/// runtime value lands at when the template runs.
public struct ComfyParameter: Codable, Sendable, Hashable, Identifiable {
    public var key: ComfyParameterKey
    /// The workflow node id (e.g. `"3"`).
    public var nodeID: String
    /// The input name on that node (e.g. `"seed"`).
    public var input: String
    public var type: ComfyParameterType

    /// One binding per role, so the role is a stable identity.
    public var id: ComfyParameterKey { key }

    public init(key: ComfyParameterKey, nodeID: String, input: String, type: ComfyParameterType) {
        self.key = key
        self.nodeID = nodeID
        self.input = input
        self.type = type
    }
}

/// A named ComfyUI text-to-image workflow plus the bindings that map friendly parameters onto its
/// nodes. `workflowJSON` is API-format JSON (what `POST /prompt` accepts). The bindings let a host
/// generate through the same `ImageRequest` path as any other image backend: pick the template and
/// the request's prompt/seed/steps/size/model flow onto the right nodes — so a ComfyUI txt2img
/// workflow behaves just like a fixed txt2img server.
public struct ComfyWorkflowTemplate: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// API-format workflow JSON: a node dictionary `{ "6": { "class_type": …, "inputs": {…} }, … }`.
    public var workflowJSON: Data
    /// The parameter bindings — at most one per `ComfyParameterKey`.
    public var parameters: [ComfyParameter]

    public init(id: UUID = UUID(), name: String,
                workflowJSON: Data, parameters: [ComfyParameter]) {
        self.id = id
        self.name = name
        self.workflowJSON = workflowJSON
        self.parameters = parameters
    }

    /// The binding for a parameter role, if the template declares one.
    public func parameter(_ key: ComfyParameterKey) -> ComfyParameter? {
        parameters.first { $0.key == key }
    }

    /// The binding that selects the base model/checkpoint, if any.
    public var modelParameter: ComfyParameter? { parameter(.model) }

    /// Whether this is a usable text-to-image pipeline: auto-bind found a prompt, a model, and a
    /// sampler seed. Non-txt2img graphs (face swap, upscale, editing) fail this, so a host can filter
    /// them out rather than offering something an `ImageRequest` can't drive.
    public var isTextToImage: Bool {
        parameter(.prompt) != nil && parameter(.model) != nil && parameter(.seed) != nil
    }

    /// The `class_type` of a node in `workflowJSON` — e.g. to look its input's combo up in a
    /// `ComfyObjectInfo`. `nil` if the node or JSON can't be read.
    public func classType(ofNode nodeID: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: workflowJSON) as? [String: Any],
              let node = root[nodeID] as? [String: Any] else { return nil }
        return node["class_type"] as? String
    }

    /// The value the workflow authored for a bound role (e.g. the template's own steps/cfg/model),
    /// so a host can seed its controls to the template's sensible defaults instead of clobbering them.
    /// `nil` if the role isn't bound or the value can't be read.
    public func authoredValue(_ key: ComfyParameterKey) -> Any? {
        guard let parameter = parameter(key),
              let root = try? JSONSerialization.jsonObject(with: workflowJSON) as? [String: Any],
              let node = root[parameter.nodeID] as? [String: Any],
              let inputs = node["inputs"] as? [String: Any] else { return nil }
        return inputs[parameter.input]
    }

    /// The authored integer default for a bound role (e.g. `.steps`, `.width`), else `nil`.
    public func defaultInt(_ key: ComfyParameterKey) -> Int? {
        if let value = authoredValue(key) as? Int { return value }
        if let value = authoredValue(key) as? Double { return Int(value) }
        return nil
    }

    /// The authored floating-point default for a bound role (e.g. `.cfg`, `.denoise`), else `nil`.
    public func defaultDouble(_ key: ComfyParameterKey) -> Double? {
        if let value = authoredValue(key) as? Double { return value }
        if let value = authoredValue(key) as? Int { return Double(value) }
        return nil
    }

    /// The authored string default for a bound role (e.g. `.model`, `.sampler`), else `nil`.
    public func defaultString(_ key: ComfyParameterKey) -> String? {
        authoredValue(key) as? String
    }

    /// Maps an `ImageRequest` onto this template's bound inputs, producing the overrides to inject
    /// before running. Only bound roles are set; unbound roles — and every other node input — keep
    /// the values the template authored. Empty model/VAE/sampler selections and a `nil` seed are left
    /// unset so the template's defaults (or a caller-resolved random seed) stand.
    public func inputs(for request: ImageRequest) -> ComfyInputs {
        var inputs = ComfyInputs()
        for parameter in parameters {
            let node = parameter.nodeID, input = parameter.input
            switch parameter.key {
            case .prompt:         inputs.set(request.prompt, node: node, input: input)
            case .negativePrompt: inputs.set(request.negativePrompt, node: node, input: input)
            case .model:          if !request.model.isEmpty { inputs.set(request.model, node: node, input: input) }
            case .vae:            if !request.vae.isEmpty { inputs.set(request.vae, node: node, input: input) }
            case .sampler:        if !request.sampler.isEmpty { inputs.set(request.sampler, node: node, input: input) }
            case .steps:          inputs.set(request.steps, node: node, input: input)
            case .cfg:            inputs.set(request.cfgScale, node: node, input: input)
            case .width:          inputs.set(request.width, node: node, input: input)
            case .height:         inputs.set(request.height, node: node, input: input)
            case .seed:           if let seed = request.seed { inputs.set(seed, node: node, input: input) }
            case .scheduler, .denoise:
                break  // not carried by ImageRequest; the template's authored value stands
            }
        }
        return inputs
    }
}
