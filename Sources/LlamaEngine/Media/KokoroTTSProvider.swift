import Foundation

/// Talks to a **Kokoro-FastAPI** server (an OpenAI-compatible local TTS server).
/// `listVoices()` hits `GET /v1/audio/voices`; `synthesize()` posts to `POST /v1/audio/speech`
/// and returns audio bytes. `Sendable` so it can be handed to an off-main `Task`.
struct KokoroTTSProvider: TTSProvider {
    var baseURLString: String
    /// Generous, since a long reply can take a while to render.
    var timeout: TimeInterval = 300

    private func base() throws -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw TTSError.invalidURL
        }
        return url
    }

    func listVoices() async throws -> [TTSVoice] {
        var request = URLRequest(url: try base().appendingPathComponent("v1/audio/voices"))
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TTSError.http(http.statusCode)
        }
        return Self.decodeVoices(data)
    }

    /// Pure, testable voice decode. Accepts either `{"voices":[{"id","name"}]}` (current
    /// Kokoro-FastAPI) or `{"voices":["af_heart", …]}`. Tolerates anything else by returning `[]`.
    static func decodeVoices(_ data: Data) -> [TTSVoice] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["voices"] as? [Any] else { return [] }
        var voices: [TTSVoice] = []
        for item in raw {
            if let id = item as? String {
                voices.append(TTSVoice(id: id, name: id))
            } else if let dict = item as? [String: Any], let id = dict["id"] as? String {
                voices.append(TTSVoice(id: id, name: (dict["name"] as? String) ?? id))
            }
        }
        return voices
    }

    func synthesize(_ request: TTSRequest) async throws -> Data {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTSError.empty }
        guard !request.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTSError.noVoiceSelected
        }
        var urlRequest = URLRequest(url: try base().appendingPathComponent("v1/audio/speech"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            RenderBody(model: "kokoro", voice: request.voice, input: trimmed,
                       response_format: request.format, speed: request.speed))
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TTSError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw TTSError.failed("The server returned no audio.") }
        return data
    }

    private struct RenderBody: Encodable {
        let model: String
        let voice: String
        let input: String
        let response_format: String
        let speed: Double
    }
}
