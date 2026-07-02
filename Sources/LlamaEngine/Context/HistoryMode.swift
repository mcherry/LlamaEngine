import Foundation

/// How a session's *conversation history* is fitted into the context window when it
/// grows past the budget. (Distinct from `ContextMode`, which governs attached files.)
/// All modes only kick in when the full history would overflow the window — short
/// chats always send everything verbatim.
public enum HistoryMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Send the full transcript every turn; let the server clamp if it overflows.
    case full
    /// Drop the oldest turns until the recent history fits.
    case truncate
    /// Condense old turns into a rolling summary, keep recent turns verbatim.
    case summarize
    /// Embed past turns and inject only the ones most relevant to the new message.
    case retrieve

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .full: return "Full history"
        case .truncate: return "Truncate old turns"
        case .summarize: return "Rolling summary"
        case .retrieve: return "Retrieve relevant turns"
        }
    }

    public var help: String {
        switch self {
        case .full:
            return "Send the whole conversation every turn. Most accurate and reproducible; the server clamps it if it overflows the window."
        case .truncate:
            return "When the window fills, drop the oldest turns. Free and predictable, but old context is lost."
        case .summarize:
            return "When the window fills, condense older turns into a running summary and keep recent turns in full. Needs the Ollama server."
        case .retrieve:
            return "When the window fills, embed past turns and include only those most relevant to your new message. Needs the Ollama server."
        }
    }

    /// Whether this mode needs the Ollama server (for summarizing or embedding). When
    /// unavailable, the engine falls back to truncation.
    public var needsServer: Bool {
        self == .summarize || self == .retrieve
    }
}
