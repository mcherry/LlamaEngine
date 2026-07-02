import Foundation

/// Clips text to a token budget by keeping the head and tail with a marker between,
/// since the start and end of a document usually carry the most signal. Pure, so it
/// is unit-tested.
public enum TextTruncator {
    private static let marker = "\n\n…[trimmed for length]…\n\n"

    public static func truncate(_ text: String, toTokens maxTokens: Int) -> String {
        guard maxTokens > 0 else { return "" }
        let maxChars = maxTokens * TokenEstimator.charsPerToken
        guard text.count > maxChars else { return text }

        let keep = maxChars - marker.count
        guard keep > 0 else { return String(text.prefix(maxChars)) }

        let headChars = keep * 2 / 3
        let tailChars = keep - headChars
        let head = text.prefix(headChars)
        let tail = text.suffix(tailChars)
        return head + marker + tail
    }
}
