import Foundation

/// A decoded, queryable view of ComfyUI's `/object_info` — the schema of every node type
/// the server knows about. Powers model/sampler dropdowns (combo inputs carry their allowed
/// values) and lets a host discover a node's inputs when building parameter bindings.
public struct ComfyObjectInfo: Sendable {
    /// One input on a node type.
    public struct InputSpec: Sendable, Equatable {
        /// The declared type (`"INT"`, `"STRING"`, `"MODEL"`, …) for a typed input, else `nil`.
        public var typeName: String?
        /// The allowed values for a combo input (e.g. installed checkpoint names), else `nil`.
        public var options: [String]?
        /// Whether the input is required (vs optional).
        public var required: Bool

        public init(typeName: String?, options: [String]?, required: Bool) {
            self.typeName = typeName
            self.options = options
            self.required = required
        }
    }

    /// `nodeType → (inputName → spec)`.
    public var nodes: [String: [String: InputSpec]]

    public init(nodes: [String: [String: InputSpec]]) {
        self.nodes = nodes
    }

    /// The inputs declared by a node type.
    public func inputs(of nodeType: String) -> [String: InputSpec] {
        nodes[nodeType] ?? [:]
    }

    /// The allowed values for a combo input, e.g.
    /// `comboOptions(node: "CheckpointLoaderSimple", input: "ckpt_name")`.
    public func comboOptions(node: String, input: String) -> [String]? {
        nodes[node]?[input]?.options
    }

    /// Node types the server exposes (e.g. to check a workflow's nodes are all installed).
    public var nodeTypes: [String] { Array(nodes.keys) }

    /// Decodes a raw `/object_info` payload. Tolerates a malformed body (→ empty).
    ///
    /// In the payload each input is a 2-element array `[typeOrOptions, metadata?]`: element 0
    /// is a list of strings for a combo input, or a type-name string for a typed input.
    public static func parse(_ data: Data) -> ComfyObjectInfo {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ComfyObjectInfo(nodes: [:])
        }
        var result: [String: [String: InputSpec]] = [:]
        for (nodeType, value) in root {
            guard let node = value as? [String: Any],
                  let input = node["input"] as? [String: Any] else { continue }
            var specs: [String: InputSpec] = [:]
            for (section, required) in [("required", true), ("optional", false)] {
                guard let bucket = input[section] as? [String: Any] else { continue }
                for (name, spec) in bucket {
                    guard let array = spec as? [Any], let first = array.first else { continue }
                    if let options = first as? [Any] {
                        specs[name] = InputSpec(typeName: nil,
                                                options: options.compactMap { $0 as? String },
                                                required: required)
                    } else if let typeName = first as? String {
                        specs[name] = InputSpec(typeName: typeName, options: nil, required: required)
                    }
                }
            }
            result[nodeType] = specs
        }
        return ComfyObjectInfo(nodes: result)
    }
}
