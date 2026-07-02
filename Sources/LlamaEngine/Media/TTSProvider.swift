import Foundation

/// A voice offered by a TTS engine, for the Settings picker.
public struct TTSVoice: Identifiable, Hashable, Sendable {
    /// The id the engine expects (a Kokoro voice name, or an Apple voice identifier).
    public let id: String
    /// Human-facing name (often the same as `id`).
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Errors surfaced by the speech layer.
public enum TTSError: LocalizedError {
    case invalidURL
    case http(Int)
    case noVoiceSelected
    case empty
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The speech server address isn't a valid URL."
        case .http(let code): return "The speech server returned HTTP \(code)."
        case .noVoiceSelected: return "Pick a voice in Settings first."
        case .empty: return "There's nothing to speak."
        case .failed(let message): return message
        }
    }
}

/// A single speech request: the text plus the tunables chosen in Settings.
public struct TTSRequest: Sendable {
    public var text: String
    public var voice: String
    /// Playback pace (1.0 = normal).
    public var speed: Double = 1.0
    /// Audio container the server returns. WAV is lossless and plays directly; saving
    /// re-encodes to AAC `.m4a` (see `AudioExport`).
    public var format: String = "wav"

    public init(text: String, voice: String, speed: Double = 1.0, format: String = "wav") {
        self.text = text
        self.voice = voice
        self.speed = speed
        self.format = format
    }
}

/// A speech backend that runs on a local server. New servers are added by writing
/// another conforming type — there is no user-facing way to register backends.
/// `listVoices()` powers the Settings Test + voice picker; `synthesize()` returns audio.
public protocol TTSProvider: Sendable {
    func listVoices() async throws -> [TTSVoice]
    func synthesize(_ request: TTSRequest) async throws -> Data
}

/// Gating helper for the optional server-speech path.
public enum TTS {
    /// The gate the server engine checks: enabled, with a non-empty server URL.
    /// (Playback additionally needs a selected voice; reported as a clear error at call time.)
    public static func isConfigured(enabled: Bool, serverURL: String) -> Bool {
        enabled && !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Builds the local server speech provider (Kokoro) pointed at `baseURLString`,
    /// for listing voices and synthesizing audio.
    public static func serverProvider(baseURLString: String) -> TTSProvider {
        KokoroTTSProvider(baseURLString: baseURLString)
    }
}
