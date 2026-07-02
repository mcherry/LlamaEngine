import Foundation

/// LlamaEngine — a portable local-LLM interface extracted from Llamatron.
///
/// This is the core product: backends, context/RAG, services, and settings, with no
/// SwiftUI or SwiftData dependency. See `PLAN.md` for the phased extraction.
public enum LlamaEngine {
    /// Package version, bumped as the extraction progresses.
    public static let version = "0.0.1"
}
