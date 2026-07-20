import Foundation
import NaturalLanguage

/// On-device text embeddings via Apple's Natural Language framework — no server, no
/// configuration, available on every Mac. It is **not** Apple Intelligence, so it works
/// even when that's disabled. This lets retrieval (RAG) over attachments and conversation
/// history work regardless of which chat backend a session uses: an Ollama server with no
/// embedding model, a llama.cpp server started without `--embeddings`, or an on-device
/// Apple session with no server at all.
///
/// Uses `NLEmbedding.sentenceEmbedding`, which is synchronous, offline, and always present.
/// Quality is below a dedicated transformer embedder (e.g. `nomic-embed-text`), but nothing
/// needs to be set up and retrieval still beats truncation for large sources. A future,
/// higher-quality path could adopt `NLContextualEmbedding` (transformer-based, multilingual)
/// behind this same protocol; it downloads an on-device asset on first use.
///
/// A value type holding no NL state — the model is fetched per call (the framework caches
/// it) — so it stays `Sendable` and is safe to hand to the off-main context assembler.
public struct AppleEmbedder: EmbeddingBackend {
    public init() {}

    /// A stable identifier for this embedding space. Vectors from different embedders
    /// aren't comparable (their dimensions differ), so callers key cache validity on it.
    public static let identifier = "apple.nl.sentence"

    /// Embeds each input string into a fixed-size vector. The `model` argument is ignored
    /// (there's a single on-device model). Server-embedder task prefixes
    /// (`search_document:` / `search_query:`) are stripped so they don't pollute the text.
    public func embed(model: String, input: [String]) async throws -> [[Float]] {
        guard !input.isEmpty else { return [] }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw AppleEmbedderError.unavailable
        }
        let dimension = embedding.dimension
        return input.map { text in
            let clean = Self.stripTaskPrefix(text)
            if let vector = embedding.vector(for: clean) {
                return vector.map(Float.init)
            }
            // The model returns nil for empty/degenerate text; a zero vector scores 0
            // similarity, so such a chunk simply isn't selected.
            return [Float](repeating: 0, count: dimension)
        }
    }

    /// Removes a leading `search_document:` / `search_query:` task prefix (a convention the
    /// context assembler prepends for server embedders) so the on-device model sees clean
    /// text. Pure/static for testing.
    public static func stripTaskPrefix(_ text: String) -> String {
        for prefix in ["search_document:", "search_query:"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

/// Errors from the on-device embedder.
public enum AppleEmbedderError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "On-device text embeddings aren't available on this system."
        }
    }
}
