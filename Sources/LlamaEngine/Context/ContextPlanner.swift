import Foundation

/// Chooses an ordered list of strategies to try for fitting attached content into the
/// budget: a primary pick plus graceful fallbacks. Pure and deterministic, so the
/// whole decision policy is unit-tested without a server.
public enum ContextPlanner {
    /// - Parameters:
    ///   - contentTokens: estimated size of all attached content.
    ///   - available: tokens free for context (from `ContextBudget`).
    ///   - mode: the session's selection (`.auto` or a forced strategy).
    ///   - wholeDocTask: whether the prompt reads like it needs the whole document
    ///     (e.g. "summarize", "outline") rather than a focused lookup.
    /// - Returns: strategies to attempt in order; always ends with `.truncate` as a
    ///   floor when there is content to inject. Empty when there is nothing to add.
    public static func plan(contentTokens: Int,
                            available: Int,
                            mode: ContextMode,
                            wholeDocTask: Bool) -> [ContextStrategy] {
        guard contentTokens > 0, available > 0 else { return [] }

        let fits = contentTokens <= available

        var order: [ContextStrategy]
        switch mode {
        case .inline:
            // Forced: honor the user's choice even if it overflows; they can re-run
            // with another mode. Still list fallbacks for completeness.
            order = [.inline, .retrieval, .summarize]
        case .retrieval:
            order = [.retrieval, .summarize]
        case .summarize:
            order = [.summarize, .retrieval]
        case .auto:
            if fits {
                order = [.inline, .retrieval, .summarize]
            } else if wholeDocTask {
                order = [.summarize, .retrieval]
            } else {
                order = [.retrieval, .summarize]
            }
        }

        order.append(.truncate)

        // De-duplicate while preserving order.
        var seen = Set<ContextStrategy>()
        return order.filter { seen.insert($0).inserted }
    }

    /// Heuristic: does the prompt look like it wants whole-document coverage rather
    /// than a focused lookup? Used only in `.auto` mode to bias toward summarize.
    public static func looksLikeWholeDocTask(_ prompt: String) -> Bool {
        let p = prompt.lowercased()
        let cues = [
            "summarize", "summary", "summarise", "outline", "overview", "tl;dr",
            "tldr", "key points", "main points", "gist", "whole document",
            "entire document", "overall", "high level", "high-level"
        ]
        return cues.contains { p.contains($0) }
    }
}
