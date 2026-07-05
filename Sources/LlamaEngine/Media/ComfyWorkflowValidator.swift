import Foundation

/// A problem found by checking a workflow against a server's `/object_info` schema — a
/// reason the workflow would fail (or behave oddly) if run on that server as-is.
public struct ComfyValidationIssue: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The node's `class_type` isn't installed on the server (a custom node is missing).
        case missingNodeType
        /// A combo input selects a value the server doesn't offer — typically a model file
        /// (checkpoint / VAE / LoRA / upscaler) that hasn't been downloaded.
        case missingModel(input: String, value: String)
        /// The node carries an input the server's schema doesn't declare (version/template
        /// drift). Advisory rather than fatal.
        case unknownInput(String)
    }

    /// The workflow node id the issue is about (e.g. `"4"`).
    public var nodeID: String
    /// The node's `class_type` (e.g. `"CheckpointLoaderSimple"`).
    public var classType: String
    public var kind: Kind

    public init(nodeID: String, classType: String, kind: Kind) {
        self.nodeID = nodeID
        self.classType = classType
        self.kind = kind
    }

    /// Whether the workflow will fail to run while this issue stands. Missing nodes and
    /// missing models are blocking; an unknown input is advisory.
    public var isBlocking: Bool {
        switch kind {
        case .missingNodeType, .missingModel: return true
        case .unknownInput: return false
        }
    }

    /// A human-readable description suitable for an alert.
    public var message: String {
        switch kind {
        case .missingNodeType:
            return "\"\(classType)\" (node \(nodeID)) isn't installed on the server — a custom node may be missing."
        case .missingModel(let input, let value):
            return "\"\(value)\" isn't available on the server (\(classType) → \(input)). The model may need to be downloaded."
        case .unknownInput(let input):
            return "\(classType) (node \(nodeID)) has an input \"\(input)\" the server doesn't recognize."
        }
    }
}

/// Checks whether a ComfyUI workflow can run on a given server by comparing it against the
/// server's node schema (`ComfyObjectInfo`). This is a read-only pre-flight — nothing is
/// queued — so a host can warn the user that a template *might* fail (e.g. its checkpoint
/// isn't downloaded) before running it.
public enum ComfyWorkflowValidator {

    /// Validates `workflow` (API-format JSON) against `info`, returning every problem found.
    /// An empty result means the workflow's nodes and model selections are all present on the
    /// server. Throws `ComfyError.badWorkflow` if the payload isn't an API-format node dict.
    public static func validate(workflow: Data, against info: ComfyObjectInfo) throws -> [ComfyValidationIssue] {
        guard let root = try? JSONSerialization.jsonObject(with: workflow) as? [String: Any] else {
            throw ComfyError.badWorkflow("expected an API-format node dictionary")
        }
        var issues: [ComfyValidationIssue] = []
        for nodeID in root.keys.sorted() {                       // sorted → deterministic output
            guard let node = root[nodeID] as? [String: Any],
                  let classType = node["class_type"] as? String else { continue }

            guard let specs = info.nodes[classType] else {
                issues.append(ComfyValidationIssue(nodeID: nodeID, classType: classType,
                                                   kind: .missingNodeType))
                continue
            }

            let inputs = node["inputs"] as? [String: Any] ?? [:]
            for inputName in inputs.keys.sorted() {
                guard let value = inputs[inputName] else { continue }
                if isConnection(value) { continue }              // a graph link, not a literal value

                guard let spec = specs[inputName] else {
                    issues.append(ComfyValidationIssue(nodeID: nodeID, classType: classType,
                                                       kind: .unknownInput(inputName)))
                    continue
                }
                // Only combo inputs have a closed allowed-set (installed files, sampler names…).
                if let options = spec.options, let selected = comboString(value),
                   !options.contains(selected) {
                    issues.append(ComfyValidationIssue(nodeID: nodeID, classType: classType,
                                                       kind: .missingModel(input: inputName, value: selected)))
                }
            }
        }
        return issues
    }

    // MARK: - Pure helpers

    /// Whether a workflow input value is a node-to-node link (`["4", 0]` = output 0 of node 4)
    /// rather than a literal value. Links are resolved by the server, so they're never checked
    /// against a combo's allowed set.
    static func isConnection(_ value: Any) -> Bool {
        guard let array = value as? [Any], array.count == 2 else { return false }
        return array[0] is String && array[1] is NSNumber
    }

    /// The literal combo selection (a string) for a value, or `nil` for numbers/bools/links —
    /// only string selections address a combo's allowed set.
    static func comboString(_ value: Any) -> String? {
        // A JSON bool decodes to NSNumber too; exclude it so `true`/`false` aren't treated as
        // a combo selection.
        if value is Bool { return nil }
        return value as? String
    }
}
