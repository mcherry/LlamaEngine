import Foundation

/// Keyword search over chunks: BM25 relevance for ranking, and the shortlist of chunks worth
/// embedding when a source is large. Pure and synchronous, so it is unit-tested.
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

    /// BM25 relevance of each text to `keywords`, 0 when none appear. A word matches every
    /// keyword it starts with ("file" finds "files" and "filename"), and words split like
    /// `keywords(from:)`, so identifiers match by their parts. A hit in `paths` (parallel to
    /// `texts`) counts double: the file a chunk came from is a strong signal.
    public static func bm25(_ texts: [String], paths: [String?] = [], keywords: [String]) -> [Double] {
        let n = texts.count
        let terms = keywords.map { Array($0.utf8) }
        guard n > 0, !terms.isEmpty else { return [Double](repeating: 0, count: n) }
        var frequencies: [[Double]] = []
        var lengths: [Int] = []
        var documentFrequency = [Int](repeating: 0, count: terms.count)
        frequencies.reserveCapacity(n)
        lengths.reserveCapacity(n)
        for i in 0..<n {
            var tf = [Double](repeating: 0, count: terms.count)
            lengths.append(countMatches(of: terms, in: texts[i], weight: 1, into: &tf))
            if i < paths.count, let path = paths[i] {
                _ = countMatches(of: terms, in: path, weight: 2, into: &tf)
            }
            for j in tf.indices where tf[j] > 0 { documentFrequency[j] += 1 }
            frequencies.append(tf)
        }
        let k1 = 1.2, b = 0.75
        let averageLength = max(1, Double(lengths.reduce(0, +)) / Double(n))
        let idf = documentFrequency.map { log(1 + (Double(n - $0) + 0.5) / (Double($0) + 0.5)) }
        return (0..<n).map { i in
            let saturation = k1 * (1 - b + b * Double(lengths[i]) / averageLength)
            var score = 0.0
            for j in terms.indices where frequencies[i][j] > 0 {
                let f = frequencies[i][j]
                score += idf[j] * f * (k1 + 1) / (f + saturation)
            }
            return score
        }
    }

    /// Adds `weight` to `tf[j]` for each word of `text` that starts with `terms[j]`, and returns
    /// the number of words. Works on Unicode scalars, not Characters: it runs over every chunk
    /// for every question.
    private static func countMatches(of terms: [[UInt8]], in text: String, weight: Double,
                                     into tf: inout [Double]) -> Int {
        var words = 0
        var word: [UInt8] = []
        var partStarts = [0]
        var previousIsUpper = false

        func match(_ piece: ArraySlice<UInt8>) {
            for j in terms.indices where piece.starts(with: terms[j]) { tf[j] += weight }
        }
        func endWord() {
            guard !word.isEmpty else { return }
            words += 1
            if partStarts.count > 1 {
                for (k, start) in partStarts.enumerated() {
                    match(word[start..<(k + 1 < partStarts.count ? partStarts[k + 1] : word.count)])
                }
            }
            match(word[...])
            word.removeAll(keepingCapacity: true)
            partStarts.removeAll(keepingCapacity: true)
            partStarts.append(0)
            previousIsUpper = false
        }

        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                let byte = UInt8(scalar.value)
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                    word.append(byte)
                    previousIsUpper = false
                case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                    if !word.isEmpty, !previousIsUpper { partStarts.append(word.count) }
                    word.append(byte + 32)
                    previousIsUpper = true
                default:
                    endWord()
                }
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                let isUpper = scalar.properties.isUppercase
                if isUpper, !word.isEmpty, !previousIsUpper { partStarts.append(word.count) }
                word.append(contentsOf: scalar.properties.lowercaseMapping.utf8)
                previousIsUpper = isUpper
            } else {
                endWord()
            }
        }
        endWord()
        return words
    }

    /// The chunks worth embedding for a large source: the best keyword matches by `scores`.
    /// Returns every index for `engageAbove` chunks or fewer, or when fewer than `floor` match
    /// (a question worded differently from the source), so semantic search still sees them all.
    public static func narrow(_ scores: [Double],
                              engageAbove: Int = 200,
                              limit: Int = 300,
                              floor: Int = 8) -> [Int] {
        let all = Array(scores.indices)
        guard scores.count > engageAbove else { return all }
        let matches = all.filter { scores[$0] > 0 }
        guard matches.count >= floor else { return all }
        return Array(matches.sorted { scores[$0] > scores[$1] }.prefix(limit))
    }
}
