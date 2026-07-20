import Foundation

/// A cheap, dependency-free lexical pre-filter ("internal grep") that narrows a large set
/// of chunks to those most likely relevant to a query *before* the expensive semantic
/// (embedding + cosine) stage. Pure and synchronous, so it is unit-tested.
///
/// It is deliberately a *narrowing* step, never a hard gate: for small chunk sets, queries
/// with no usable terms, or when too few chunks match lexically (a synonym-only query), it
/// returns everything so semantic retrieval still sees the full set.
public enum LexicalFilter {
    /// Common English + question words that carry no retrieval signal.
    public static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "else", "of", "to", "in", "on",
        "at", "by", "for", "with", "from", "as", "is", "are", "was", "were", "be", "been",
        "being", "it", "its", "this", "that", "these", "those", "i", "you", "he", "she",
        "we", "they", "me", "my", "your", "our", "their", "what", "which", "who", "whom",
        "how", "why", "when", "where", "do", "does", "did", "can", "could", "should",
        "would", "will", "shall", "may", "might", "must", "not", "no", "yes", "about",
        "into", "over", "under", "out", "so", "than", "too", "very", "some", "any", "all"
    ]

    /// Extracts search terms from a free-text query: split on non-alphanumerics, split
    /// `camelCase` identifiers, lowercase, drop stopwords and very short tokens, dedupe.
    public static func keywords(from query: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for rawToken in query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            for piece in splitCamelCase(String(rawToken)) {
                let term = piece.lowercased()
                guard term.count >= 3, !stopWords.contains(term), seen.insert(term).inserted else { continue }
                result.append(term)
            }
        }
        return result
    }

    /// Splits a `camelCase`/`PascalCase` token into its parts, plus the whole token, so a
    /// query like "isLoading" yields both `loading` and `isloading`.
    static func splitCamelCase(_ token: String) -> [String] {
        let chars = Array(token)
        guard chars.count > 1 else { return [token] }
        var parts: [String] = []
        var current = String(chars[0])
        for i in 1..<chars.count {
            let c = chars[i]
            if c.isUppercase && !chars[i - 1].isUppercase {
                parts.append(current)
                current = String(c)
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        if parts.count > 1 { parts.append(token) }   // keep the whole token too
        return parts
    }

    /// How many distinct query terms appear (case-insensitively) in the text. Substring
    /// match, so partial identifiers count ("auth" hits "authenticate").
    public static func hitCount(_ text: String, keywords: [String]) -> Int {
        guard !keywords.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        for term in keywords where text.range(of: term, options: .caseInsensitive) != nil {
            count += 1
        }
        return count
    }

    /// Narrows chunk indices to the most lexically relevant. `paths` (optional, parallel to
    /// `texts`) are matched too and weighted higher (a path hit is a strong signal). Returns
    /// ALL indices when narrowing shouldn't apply: `texts.count <= engageAbove`, no keywords,
    /// or fewer than `floor` chunks match (so it falls back to full semantic retrieval).
    public static func narrow(_ texts: [String],
                              paths: [String?] = [],
                              keywords: [String],
                              engageAbove: Int = 200,
                              limit: Int = 300,
                              floor: Int = 8) -> [Int] {
        let n = texts.count
        guard n > engageAbove, !keywords.isEmpty else { return Array(0..<n) }
        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(n)
        for i in 0..<n {
            var score = hitCount(texts[i], keywords: keywords)
            if i < paths.count, let path = paths[i] {
                score += 2 * hitCount(path, keywords: keywords)   // a path hit weighs more
            }
            if score > 0 { scored.append((i, score)) }
        }
        guard scored.count >= floor else { return Array(0..<n) }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.index)
    }
}
