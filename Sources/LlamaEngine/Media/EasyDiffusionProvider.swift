import Foundation

/// Talks to an Easy Diffusion server (cmdr2's `stable-diffusion-ui`). A small `Sendable` value, so
/// it's safe to hand to a background task. Listing models powers the Settings picker; image
/// generation is the render→poll flow.
struct EasyDiffusionProvider: ImageProvider {
    let baseURLString: String
    /// Timeout for an individual HTTP call (render POST, model list, one stream poll).
    var timeout: TimeInterval = 60
    /// Overall budget for a generation, across queueing + rendering + polling.
    var pollTimeout: TimeInterval = 300

    init(baseURLString: String) {
        self.baseURLString = baseURLString
    }

    /// Stable-diffusion models the server has, via `GET /get/models` (filtered to the
    /// `stable-diffusion` tag — VAEs, upscalers, etc. are excluded).
    func listModels() async throws -> [ImageModel] {
        Self.decodeModels(try await get("get/models"), tag: "stable-diffusion")
    }

    /// VAE models the server has, for the optional VAE picker.
    func listVAEs() async throws -> [ImageModel] {
        Self.decodeModels(try await get("get/models"), tag: "vae")
    }

    /// Pure decode of the `/get/models` payload, kept separate so it's unit-testable without a
    /// server. Returns only entries carrying `tag`; tolerates a malformed body (→ `[]`).
    static func decodeModels(_ data: Data, tag: String = "stable-diffusion") -> [ImageModel] {
        guard let root = try? JSONDecoder().decode(ModelsResponse.self, from: data) else { return [] }
        return root.models
            .filter { $0.tags.contains(tag) }
            .map { ImageModel(id: $0.model, name: $0.name ?? $0.model) }
    }

    /// Renders an image: POST `/render`, then poll `/image/stream/{task}` until the image arrives or
    /// the task fails. Easy Diffusion **requires** a model name; an empty one is reported clearly.
    func generate(_ request: ImageRequest) async throws -> Data {
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ImageGenError.noModelSelected }

        let body = RenderBody(
            prompt: request.prompt,
            negative_prompt: request.negativePrompt,
            seed: request.seed ?? Int.random(in: 0...Int(UInt32.max)),
            width: request.width,
            height: request.height,
            num_outputs: 1,
            num_inference_steps: max(1, request.steps),
            guidance_scale: request.cfgScale,
            sampler_name: "euler_a",
            use_stable_diffusion_model: model,
            use_vae_model: request.vae.isEmpty ? nil : request.vae,
            output_format: "png",
            stream_progress_updates: true,
            stream_image_progress: false,
            session_id: "llamatron")
        let rendered = try await post("render", body: body)
        let response = try JSONDecoder().decode(RenderResponse.self, from: rendered)

        var streamPath = response.stream ?? response.task.map { "image/stream/\($0)" } ?? ""
        while streamPath.hasPrefix("/") { streamPath.removeFirst() }
        guard !streamPath.isEmpty else { throw ImageGenError.failed("The server didn't return a task to stream.") }

        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let text = (try? await getString(streamPath)) ?? ""
            switch Self.parseStream(text) {
            case .image(let data): return data
            case .failed(let detail): throw ImageGenError.failed(detail)
            case .pending: break
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw ImageGenError.failed("Image generation timed out.")
    }

    // MARK: - Stream parsing (pure, testable)

    enum StreamResult: Equatable { case pending, image(Data), failed(String) }

    /// Scans an Easy Diffusion stream body (concatenated JSON objects) for the final result: an
    /// `output[0].data` data-URI (→ `.image`) or a `status:"failed"` (→ `.failed`), else `.pending`.
    static func parseStream(_ text: String) -> StreamResult {
        var result: StreamResult = .pending
        for object in jsonObjects(in: text) {
            guard let data = object.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let output = dict["output"] as? [[String: Any]],
               let dataURI = output.first?["data"] as? String,
               let bytes = decodeDataURI(dataURI) {
                result = .image(bytes)
            } else if (dict["status"] as? String) == "failed" {
                result = .failed((dict["detail"] as? String) ?? "Image generation failed.")
            }
        }
        return result
    }

    /// Splits a body of concatenated top-level JSON objects into their individual substrings,
    /// respecting strings and escapes so braces inside text don't confuse the depth count.
    static func jsonObjects(in text: String) -> [String] {
        var objects: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for idx in text.indices {
            let ch = text[idx]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = idx }
                depth += 1
            case "}":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start { objects.append(String(text[s...idx])); start = nil }
                }
            default: break
            }
        }
        return objects
    }

    /// Decodes a `data:image/...;base64,xxxx` URI (or a bare base64 string) to bytes.
    static func decodeDataURI(_ uri: String) -> Data? {
        let base64 = uri.components(separatedBy: ",").last ?? uri
        return Data(base64Encoded: base64)
    }

    // MARK: - Networking

    private func resolvedURL() throws -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { throw ImageGenError.invalidURL }
        return url
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: try resolvedURL().appending(path: path))
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ImageGenError.http(http.statusCode)
        }
        return data
    }

    private func getString(_ path: String) async throws -> String {
        String(decoding: try await get(path), as: UTF8.self)
    }

    private func post<Body: Encodable>(_ path: String, body: Body) async throws -> Data {
        var request = URLRequest(url: try resolvedURL().appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ImageGenError.http(http.statusCode)
        }
        return data
    }

    private struct ModelsResponse: Decodable {
        let models: [Entry]
        struct Entry: Decodable {
            let model: String
            let name: String?
            let tags: [String]
        }
    }

    private struct RenderResponse: Decodable {
        let stream: String?
        let task: Int?
    }

    private struct RenderBody: Encodable {
        let prompt: String
        let negative_prompt: String
        let seed: Int
        let width: Int
        let height: Int
        let num_outputs: Int
        let num_inference_steps: Int
        let guidance_scale: Double
        let sampler_name: String
        let use_stable_diffusion_model: String
        let use_vae_model: String?
        let output_format: String
        let stream_progress_updates: Bool
        let stream_image_progress: Bool
        let session_id: String
    }
}
