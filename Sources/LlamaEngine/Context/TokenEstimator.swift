import Foundation

/// Cheap, dependency-free token estimate. Real tokenization is model-specific, so we
/// approximate at ~4 characters per token (slightly conservative for prose, a touch
/// low for dense code). Pure, so it is unit-tested and safe to call anywhere.
public enum TokenEstimator {
    public static let charsPerToken = 4

    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / Double(charsPerToken)).rounded(.up))
    }

    public static func estimate(_ texts: [String]) -> Int {
        texts.reduce(0) { $0 + estimate($1) }
    }
}
