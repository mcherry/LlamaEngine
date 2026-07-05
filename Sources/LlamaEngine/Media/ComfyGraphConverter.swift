import Foundation

/// Converts a ComfyUI **UI/graph** workflow (the editor's `nodes` + `links` format) into the
/// **API format** that `POST /prompt` accepts (a flat `{ id: { class_type, inputs } }` dictionary).
/// This lets a host import workflows saved on the server or shipped as templates without the user
/// exporting them by hand.
///
/// It uses the server schema (`ComfyObjectInfo`) to map each node's positional `widgets_values`
/// back to named inputs — including the `control_after_generate` value that trails a seed — and
/// resolves links for connection inputs. Muted/bypassed and pure-UI nodes (Note/Reroute) are
/// dropped. It deliberately does **not** attempt subgraph expansion: a graph that uses subgraphs
/// (or nodes the server doesn't know) throws `.unsupportedNodes`, and the caller should suggest
/// pulling the already-expanded workflow from `/history` instead.
public enum ComfyGraphConverter {

    public enum ConvertError: LocalizedError, Equatable {
        /// The payload isn't a UI graph (no `nodes` array) — perhaps it's already API format.
        case notGraphFormat
        /// The graph uses subgraphs or nodes the server doesn't know; it can't be converted headlessly.
        case unsupportedNodes([String])

        public var errorDescription: String? {
            switch self {
            case .notGraphFormat:
                return "This doesn't look like a ComfyUI graph workflow."
            case .unsupportedNodes(let types):
                let list = types.prefix(3).joined(separator: ", ")
                return "This workflow uses parts that can't be imported directly (\(list)). "
                    + "Run it once in ComfyUI, then import it from the server's history."
            }
        }
    }

    /// Pure-UI node types that carry no execution and are dropped during conversion.
    static let uiOnlyTypes: Set<String> = ["Note", "MarkdownNote", "Reroute", "PrimitiveNode"]
    /// The `control_after_generate` values that trail a seed widget in `widgets_values`.
    static let controlKeywords: Set<String> = ["fixed", "increment", "decrement", "randomize"]

    /// Converts a UI-format workflow to API format against `objectInfo`. Throws `.notGraphFormat`
    /// if it isn't a graph, or `.unsupportedNodes` if it needs subgraph expansion / unknown nodes.
    public static func toAPIFormat(_ uiWorkflow: Data, objectInfo: ComfyObjectInfo) throws -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: uiWorkflow) as? [String: Any],
              let nodes = root["nodes"] as? [[String: Any]] else {
            throw ConvertError.notGraphFormat
        }

        // Links are `[linkId, fromNode, fromSlot, toNode, toSlot, type]`; index the source by id.
        var sourceByLink: [Int: [Any]] = [:]   // linkId → [nodeIDString, slotInt]
        if let links = root["links"] as? [[Any]] {
            for link in links where link.count >= 3 {
                guard let id = intValue(link[0]), let from = idString(link[1]) else { continue }
                sourceByLink[id] = [from, intValue(link[2]) ?? 0]
            }
        }

        var api: [String: Any] = [:]
        var unsupported: Set<String> = []
        for node in nodes {
            guard let type = node["type"] as? String else { continue }
            if let mode = intValue(node["mode"]), mode == 2 || mode == 4 { continue }  // muted / bypassed
            if uiOnlyTypes.contains(type) { continue }
            guard let id = idString(node["id"]) else { continue }
            // Unknown type = a subgraph (UUID) or a custom node the server lacks → can't convert.
            guard objectInfo.nodes[type] != nil else { unsupported.insert(type); continue }

            var inputs: [String: Any] = [:]
            var connected: Set<String> = []
            if let nodeInputs = node["inputs"] as? [[String: Any]] {
                for input in nodeInputs {
                    guard let name = input["name"] as? String,
                          let linkID = intValue(input["link"]),
                          let source = sourceByLink[linkID] else { continue }
                    inputs[name] = source
                    connected.insert(name)
                }
            }

            // Positional widget values → named widget inputs (in declared order, minus connected ones).
            let specs = objectInfo.inputs(of: type)
            let widgetNames = objectInfo.orderedInputNames(of: type)
                .filter { (specs[$0]?.isWidget ?? false) && !connected.contains($0) }
            if let values = node["widgets_values"] as? [Any] {
                var vi = 0
                for name in widgetNames where vi < values.count {
                    inputs[name] = values[vi]
                    vi += 1
                    // A seed widget is followed by its control_after_generate value — skip it.
                    if (name == "seed" || name == "noise_seed"), vi < values.count,
                       let keyword = values[vi] as? String, controlKeywords.contains(keyword) {
                        vi += 1
                    }
                }
            }

            api[id] = ["class_type": type, "inputs": inputs]
        }

        guard unsupported.isEmpty else { throw ConvertError.unsupportedNodes(unsupported.sorted()) }
        guard !api.isEmpty else { throw ConvertError.notGraphFormat }
        return try JSONSerialization.data(withJSONObject: api)
    }

    // MARK: - Helpers

    static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    /// A node id as the string API format uses. UI ids are integers; accept strings too.
    static func idString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let i = intValue(value) { return String(i) }
        return nil
    }
}
