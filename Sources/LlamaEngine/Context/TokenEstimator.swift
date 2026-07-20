import Foundation

/// Cheap, dependency-free token estimate. Real tokenization is model-specific, so we
/// approximate at ~4 characters per token (slightly conservative for prose, a touch
/// low for dense code). Pure, so it is unit-tested and safe to call anywhere.
public enum TokenEstimator {
    public static let charsPerToken = 4

    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // Count UTF-8 bytes, not `String.count`: the latter walks the whole string
        // segmenting grapheme clusters (O(n) and slow on large sources), while byte
        // count is far cheaper and, for the mostly-ASCII text we chunk, effectively
        // identical. Multi-byte text counts slightly higher, which keeps budgets safe.
        return Int((Double(text.utf8.count) / Double(charsPerToken)).rounded(.up))
    }

    public static func estimate(_ texts: [String]) -> Int {
        texts.reduce(0) { $0 + estimate($1) }
    }
}
