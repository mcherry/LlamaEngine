import Foundation

/// Errors surfaced by the ComfyUI backend.
public enum ComfyError: LocalizedError {
    case invalidURL
    case http(Int)
    case badWorkflow(String)
    case execution(String)
    case timedOut
    case noOutput
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The ComfyUI server address isn't a valid URL."
        case .http(let code): return "The ComfyUI server returned HTTP \(code)."
        case .badWorkflow(let m): return "The workflow couldn't be prepared: \(m)"
        case .execution(let m): return "ComfyUI reported an execution error: \(m)"
        case .timedOut: return "The ComfyUI job timed out."
        case .noOutput: return "The ComfyUI job finished but produced no image."
        case .failed(let m): return m
        }
    }
}

/// A reference to a single input on a single node of a ComfyUI workflow — the address
/// where a runtime value is injected (e.g. node `"6"`, input `"text"`).
public struct ComfyNodeInput: Hashable, Sendable, Codable {
    public var nodeID: String
    public var input: String
    public init(nodeID: String, input: String) {
        self.nodeID = nodeID
        self.input = input
    }
}

/// The runtime values to inject into a workflow template before running it. Each map
/// keys a node input to the value that overrides whatever the template had there. Image
/// values are uploaded to the server first and referenced by filename (for `LoadImage`).
public struct ComfyInputs: Sendable {
    public var strings: [ComfyNodeInput: String]
    public var ints: [ComfyNodeInput: Int]
    public var doubles: [ComfyNodeInput: Double]
    public var images: [ComfyNodeInput: Data]

    public init(strings: [ComfyNodeInput: String] = [:],
                ints: [ComfyNodeInput: Int] = [:],
                doubles: [ComfyNodeInput: Double] = [:],
                images: [ComfyNodeInput: Data] = [:]) {
        self.strings = strings
        self.ints = ints
        self.doubles = doubles
        self.images = images
    }

    public mutating func set(_ value: String, node: String, input: String) {
        strings[ComfyNodeInput(nodeID: node, input: input)] = value
    }
    public mutating func set(_ value: Int, node: String, input: String) {
        ints[ComfyNodeInput(nodeID: node, input: input)] = value
    }
    public mutating func set(_ value: Double, node: String, input: String) {
        doubles[ComfyNodeInput(nodeID: node, input: input)] = value
    }
    public mutating func set(image: Data, node: String, input: String) {
        images[ComfyNodeInput(nodeID: node, input: input)] = image
    }
}

/// Talks to a ComfyUI server (`comfyanonymous/ComfyUI`). Unlike a fixed txt2img backend,
/// ComfyUI executes an arbitrary *workflow graph*, so this client runs a workflow (in the
/// server's API-format JSON) after injecting a handful of `ComfyInputs`, then polls for the
/// result and returns the rendered image bytes. Because the pipeline lives in the workflow,
/// the same client drives text-to-image, editing, face swap, upscaling — anything ComfyUI
/// can do. An `actor` so a run is safe to launch from a background task.
public actor ComfyUIClient {
    let baseURL: URL
    /// Timeout for an individual HTTP call.
    let timeout: TimeInterval
    /// Overall budget for one run, across queueing + execution + polling.
    let pollTimeout: TimeInterval

    public init?(baseURLString: String, timeout: TimeInterval = 60, pollTimeout: TimeInterval = 600) {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        self.baseURL = url
        self.timeout = timeout
        self.pollTimeout = pollTimeout
    }

    /// The server's node schema (`GET /object_info`): every node type with its inputs and,
    /// for combo inputs, the allowed values (e.g. installed checkpoints/samplers). Decode it
    /// with `ComfyObjectInfo.parse`.
    public func objectInfo() async throws -> Data {
        try await get("object_info")
    }

    /// Convenience: the allowed values of a combo input on a node type — e.g. the installed
    /// checkpoints via `options(nodeType: "CheckpointLoaderSimple", input: "ckpt_name")`.
    public func options(nodeType: String, input: String) async throws -> [String] {
        ComfyObjectInfo.parse(try await objectInfo()).comboOptions(node: nodeType, input: input) ?? []
    }

    /// Pre-flight check: fetches the server's node schema and reports whether `workflow` can
    /// run on it as-is — flagging missing custom nodes or model files (e.g. a checkpoint the
    /// template references that isn't downloaded). Read-only; nothing is queued. Use it to warn
    /// before running a template. An empty result means the workflow looks runnable.
    public func validate(workflow: Data) async throws -> [ComfyValidationIssue] {
        let info = ComfyObjectInfo.parse(try await objectInfo())
        guard !info.nodes.isEmpty else {
            throw ComfyError.failed("Couldn't read the server's node schema to validate the workflow.")
        }
        return try ComfyWorkflowValidator.validate(workflow: workflow, against: info)
    }

    /// Uploads an input image (`POST /upload/image`) and returns the filename to reference in
    /// a `LoadImage` node's `image` input (prefixed with its subfolder when present).
    public func uploadImage(_ data: Data, filename: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: try endpoint("upload/image"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: image/png\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        let (respData, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response)
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let name = obj["name"] as? String else {
            throw ComfyError.failed("The image upload didn't return a filename.")
        }
        let subfolder = obj["subfolder"] as? String ?? ""
        return subfolder.isEmpty ? name : "\(subfolder)/\(name)"
    }

    /// Runs `workflow` (API-format JSON) after applying `inputs`: uploads any image inputs,
    /// injects the values, submits to `/prompt`, polls `/history` until the job finishes,
    /// and returns the bytes of each saved output image.
    public func run(workflow: Data, inputs: ComfyInputs) async throws -> [Data] {
        var imageFilenames: [ComfyNodeInput: String] = [:]
        for (ref, data) in inputs.images {
            imageFilenames[ref] = try await uploadImage(data, filename: "llamaengine-\(UUID().uuidString).png")
        }
        let concrete = try Self.applyInputs(to: workflow,
                                            strings: inputs.strings,
                                            ints: inputs.ints,
                                            doubles: inputs.doubles,
                                            imageFilenames: imageFilenames)
        let clientID = UUID().uuidString
        let submitted = try await post("prompt", body: Self.wrapPrompt(concrete, clientID: clientID))
        guard let promptID = Self.parsePromptID(submitted) else {
            throw ComfyError.failed("The server didn't return a prompt id.")
        }

        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let history = (try? await get("history/\(promptID)")) ?? Data()
            if let message = Self.parseHistoryError(history, promptID: promptID) {
                throw ComfyError.execution(message)
            }
            let refs = Self.parseHistoryOutputs(history, promptID: promptID)
            if Self.historyIsComplete(history, promptID: promptID) {
                guard !refs.isEmpty else { throw ComfyError.noOutput }
                var images: [Data] = []
                for ref in refs where ref.type == "output" {
                    if let data = try? await fetchView(ref) { images.append(data) }
                }
                guard !images.isEmpty else { throw ComfyError.noOutput }
                return images
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ComfyError.timedOut
    }

    /// Interrupts the currently executing job (`POST /interrupt`).
    public func interrupt() async {
        _ = try? await post("interrupt", body: Data("{}".utf8))
    }

    // MARK: - Pure helpers (no network — unit-testable)

    /// One rendered output the server produced.
    struct OutputRef: Equatable {
        var filename: String
        var subfolder: String
        var type: String
    }

    /// Applies value overrides to a workflow template, returning a new concrete workflow.
    /// The workflow is a node dictionary (`{ "6": { "inputs": { ... }, "class_type": ... } }`);
    /// each override replaces `node.inputs[input]`. Unknown node ids are skipped.
    static func applyInputs(to workflow: Data,
                            strings: [ComfyNodeInput: String] = [:],
                            ints: [ComfyNodeInput: Int] = [:],
                            doubles: [ComfyNodeInput: Double] = [:],
                            imageFilenames: [ComfyNodeInput: String] = [:]) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: workflow) as? [String: Any] else {
            throw ComfyError.badWorkflow("expected an API-format node dictionary")
        }
        func set(_ ref: ComfyNodeInput, _ value: Any) {
            guard var node = root[ref.nodeID] as? [String: Any] else { return }
            var nodeInputs = node["inputs"] as? [String: Any] ?? [:]
            nodeInputs[ref.input] = value
            node["inputs"] = nodeInputs
            root[ref.nodeID] = node
        }
        for (k, v) in strings { set(k, v) }
        for (k, v) in ints { set(k, v) }
        for (k, v) in doubles { set(k, v) }
        for (k, v) in imageFilenames { set(k, v) }
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Wraps a concrete workflow into the `/prompt` request body.
    static func wrapPrompt(_ workflow: Data, clientID: String) throws -> Data {
        let obj = try JSONSerialization.jsonObject(with: workflow)
        return try JSONSerialization.data(withJSONObject: ["prompt": obj, "client_id": clientID])
    }

    /// The `prompt_id` from a `/prompt` response, or `nil`.
    static func parsePromptID(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["prompt_id"] as? String
    }

    /// The saved-image references from a `/history/{id}` payload.
    static func parseHistoryOutputs(_ data: Data, promptID: String) -> [OutputRef] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[promptID] as? [String: Any],
              let outputs = entry["outputs"] as? [String: Any] else { return [] }
        var refs: [OutputRef] = []
        for (_, node) in outputs {
            guard let nodeDict = node as? [String: Any] else { continue }
            for key in ["images", "gifs"] {
                guard let arr = nodeDict[key] as? [[String: Any]] else { continue }
                for image in arr {
                    guard let filename = image["filename"] as? String else { continue }
                    refs.append(OutputRef(filename: filename,
                                          subfolder: image["subfolder"] as? String ?? "",
                                          type: image["type"] as? String ?? "output"))
                }
            }
        }
        return refs
    }

    /// Whether the job for `promptID` has finished (its history entry has a completed status).
    static func historyIsComplete(_ data: Data, promptID: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[promptID] as? [String: Any] else { return false }
        if let status = entry["status"] as? [String: Any] {
            if let completed = status["completed"] as? Bool { return completed }
            if let str = status["status_str"] as? String { return str == "success" || str == "error" }
        }
        return entry["outputs"] != nil
    }

    /// An execution error message from a `/history/{id}` payload, if the job failed.
    static func parseHistoryError(_ data: Data, promptID: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[promptID] as? [String: Any],
              let status = entry["status"] as? [String: Any],
              (status["status_str"] as? String) == "error" else { return nil }
        if let messages = status["messages"] as? [[Any]] {
            for message in messages where (message.first as? String) == "execution_error" {
                if let info = message.dropFirst().first as? [String: Any],
                   let text = info["exception_message"] as? String { return text }
            }
        }
        return "The workflow failed to execute."
    }

    // MARK: - Networking

    private func endpoint(_ path: String) throws -> URL {
        baseURL.appending(path: path)
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: try endpoint(path))
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response)
        return data
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response)
        return data
    }

    private func fetchView(_ ref: OutputRef) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appending(path: "view"),
                                             resolvingAgainstBaseURL: false) else {
            throw ComfyError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "filename", value: ref.filename),
            URLQueryItem(name: "subfolder", value: ref.subfolder),
            URLQueryItem(name: "type", value: ref.type),
        ]
        guard let url = components.url else { throw ComfyError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response)
        return data
    }

    static func checkHTTP(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ComfyError.http(http.statusCode)
        }
    }
}

extension ComfyUIClient {
    /// Discovers **text-to-image** workflows on the server, ready to import with no manual export.
    /// Reads `/history` — which stores executed workflows in API format already — dedupes repeat runs
    /// newest-first, and keeps only those auto-bind recognizes as txt2img (a prompt + model + seed),
    /// so face-swap / upscale / editing runs are filtered out. Returns them as bound templates.
    public func serverWorkflows() async -> [ComfyWorkflowTemplate] {
        guard let data = try? await getURL(path: "history",
                                           query: [URLQueryItem(name: "max_items", value: "100")]) else {
            return []
        }
        return Self.parseHistory(data, limit: 25).compactMap {
            ComfyWorkflowTemplate.textToImage(name: $0.name, workflowJSON: $0.apiWorkflow)
        }
    }

    // MARK: - Pure history parsing (testable)

    /// Parses a `/history` payload into deduped, newest-first API-format workflows (label + JSON).
    static func parseHistory(_ data: Data, limit: Int) -> [(name: String, apiWorkflow: Data)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var entries: [(time: Double, id: String, workflow: [String: Any])] = []
        for (promptID, value) in root {
            guard let entry = value as? [String: Any],
                  let prompt = entry["prompt"] as? [Any], prompt.count >= 3,
                  let workflow = prompt[2] as? [String: Any], !workflow.isEmpty else { continue }
            let extra = prompt.count >= 4 ? prompt[3] as? [String: Any] : nil
            let time = (extra?["create_time"] as? Double) ?? 0
            entries.append((time, promptID, workflow))
        }
        entries.sort { $0.time > $1.time }   // newest first
        var out: [(name: String, apiWorkflow: Data)] = []
        var seen = Set<String>()
        for entry in entries {
            guard seen.insert(workflowSignature(entry.workflow)).inserted,
                  let data = try? JSONSerialization.data(withJSONObject: entry.workflow) else { continue }
            let name = saveImageLabel(entry.workflow) ?? "Run \(entry.id.prefix(8))"
            out.append((name, data))
            if out.count >= limit { break }
        }
        return out
    }

    /// The `filename_prefix` of a SaveImage node — a friendly label for a workflow — if present.
    static func saveImageLabel(_ workflow: [String: Any]) -> String? {
        for (_, node) in workflow {
            guard let node = node as? [String: Any],
                  (node["class_type"] as? String)?.contains("SaveImage") == true,
                  let inputs = node["inputs"] as? [String: Any],
                  let prefix = inputs["filename_prefix"] as? String, !prefix.isEmpty else { continue }
            return prefix
        }
        return nil
    }

    /// A structural signature (sorted class types + save label) used to dedupe repeat runs.
    static func workflowSignature(_ workflow: [String: Any]) -> String {
        let types = workflow.values
            .compactMap { ($0 as? [String: Any])?["class_type"] as? String }
            .sorted()
        return types.joined(separator: ",") + "|" + (saveImageLabel(workflow) ?? "")
    }

    // MARK: - Networking

    /// GET with query items (the private `get` treats `?` as a literal path character).
    func getURL(path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appending(path: path),
                                             resolvingAgainstBaseURL: false) else {
            throw ComfyError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ComfyError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response)
        return data
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
