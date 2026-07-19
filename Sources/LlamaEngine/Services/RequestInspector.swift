import Foundation

/// Builds a readable, pretty-printed JSON description of the exact request a turn
/// produced, for the request inspector. For Ollama it reflects the literal wire body;
/// for Apple it shows the rendered instructions/prompt and on-device options.
public enum RequestInspector {
    public static func payload(for request: ChatRequest,
                        backend: BackendKind,
                        appleOptions: AppleGenerationOptions) -> String? {
        switch backend {
        case .ollama:
            return ollamaPayload(request)
        case .llamaServer:
            return llamaServerPayload(request)
        case .appleIntelligence:
            return applePayload(request, options: appleOptions)
        case .imageGeneration:
            return nil
        }
    }

    /// The literal Ollama `/api/chat` body, re-serialized with sorted, pretty keys.
    private static func ollamaPayload(_ request: ChatRequest) -> String? {
        guard let data = try? OllamaClient.encodeChatBody(request),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return prettyString(object)
    }

    /// The literal llama.cpp `/v1/chat/completions` body (OpenAI-compatible),
    /// re-serialized with sorted, pretty keys.
    private static func llamaServerPayload(_ request: ChatRequest) -> String? {
        guard let data = try? LlamaServerClient.encodeChatBody(request),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return prettyString(object)
    }

    private static func applePayload(_ request: ChatRequest,
                                     options: AppleGenerationOptions) -> String? {
        let (instructions, prompt) = FoundationModelsBackend.render(request.messages)
        var opts: [String: Any] = ["samplingMode": options.samplingMode.rawValue]
        if let t = options.temperature { opts["temperature"] = t }
        if let m = options.maximumResponseTokens { opts["maximumResponseTokens"] = m }
        if options.samplingMode == .topK, let k = options.topK { opts["topK"] = k }
        if options.samplingMode == .topP, let p = options.topP { opts["topP"] = p }
        if options.samplingMode.usesSeed, let s = options.seed { opts["seed"] = s }

        let object: [String: Any] = [
            "backend": "appleIntelligence",
            "instructions": instructions,
            "prompt": prompt,
            "options": opts
        ]
        return prettyString(object)
    }

    private static func prettyString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
