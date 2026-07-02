import Foundation

/// A concrete way to fit attached content into the prompt, ordered most → least
/// faithful. The planner emits these; the assembler executes them with fallback.
public enum ContextStrategy: String, Sendable, CaseIterable {
    /// Include every attached chunk verbatim.
    case inline
    /// Embed chunks and the query, include only the most relevant ones (RAG).
    case retrieval
    /// Map-reduce the document into a shorter summary.
    case summarize
    /// Head/tail clip to fit — the always-available floor.
    case truncate

    public var label: String {
        switch self {
        case .inline: return "Full text"
        case .retrieval: return "Retrieved excerpts"
        case .summarize: return "Summary"
        case .truncate: return "Truncated"
        }
    }
}

/// The user-facing selection for a session. `.auto` lets the planner choose by size;
/// the others force a primary strategy, while the engine still falls back on failure.
/// Exposed in session settings so a chat can be re-run with a different approach.
public enum ContextMode: String, Sendable, CaseIterable, Identifiable {
    case auto
    case inline
    case retrieval
    case summarize

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .inline: return "Always full text"
        case .retrieval: return "Always retrieve (RAG)"
        case .summarize: return "Always summarize"
        }
    }

    public var help: String {
        switch self {
        case .auto: return "Pick the best fit by size, falling back as needed."
        case .inline: return "Send the whole document. Best for small files."
        case .retrieval: return "Send only the most relevant excerpts. Best for lookups in large files."
        case .summarize: return "Condense the document first. Best for whole-document questions."
        }
    }
}
