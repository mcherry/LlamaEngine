import Foundation

/// Which engine speaks a chat's replies. `apple` is the on-device synthesizer (no
/// server, no setup); `server` is a local Kokoro TTS server. Stored on `ChatSession`
/// as a raw string, like `BackendKind`.
public enum TTSEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    case apple
    case server

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .apple: return "Apple (on-device)"
        case .server: return "Kokoro server"
        }
    }
}
