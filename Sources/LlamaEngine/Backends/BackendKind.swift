import Foundation

/// Which engine a session talks to. `ollama` is a remote Ollama server; `appleIntelligence`
/// is Apple's on-device Foundation Models (macOS 26+, only when enabled on the system);
/// `imageGeneration` turns prompts into images via a local image server (Settings).
/// Stored on `ChatSession` as a raw string for SwiftData simplicity.
public enum BackendKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case ollama
    case appleIntelligence
    case imageGeneration

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ollama: return "Ollama"
        case .appleIntelligence: return "Apple Intelligence"
        case .imageGeneration: return "Image Generation"
        }
    }

    public var systemImage: String {
        switch self {
        case .ollama: return "server.rack"
        case .appleIntelligence: return "apple.logo"
        case .imageGeneration: return "photo"
        }
    }
}
