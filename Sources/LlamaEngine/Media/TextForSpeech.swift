import Foundation

/// Turns rendered Markdown into plain prose for text-to-speech, so the synthesizer reads
/// words rather than syntax: it drops fenced code blocks, strips inline markers
/// (backticks, emphasis), keeps link/image text but not the URL, and removes leading
/// heading/quote/list markers. Pure, so it is unit-tested.
enum TextForSpeech {
    static func plain(_ text: String) -> String {
        var s = text
        // Drop fenced code blocks entirely (don't read code aloud).
        s = replace("(?s)```.*?```", in: s, with: " ")
        // Images then links: keep the visible text, drop the URL.
        s = replace("!\\[([^\\]]*)\\]\\([^)]*\\)", in: s, with: "$1")
        s = replace("\\[([^\\]]*)\\]\\([^)]*\\)", in: s, with: "$1")
        // Inline code backticks.
        s = s.replacingOccurrences(of: "`", with: "")
        // Leading block markers (headings, quotes, list bullets/numbers).
        s = replace("(?m)^[ \\t]{0,3}(#{1,6}|>|[-*+]|[0-9]+\\.)[ \\t]+", in: s, with: "")
        // Emphasis / strikethrough markers.
        s = replace("[*_~]", in: s, with: "")
        // Collapse runs of spaces and excess blank lines.
        s = replace("[ \\t]+", in: s, with: " ")
        s = replace("\\n{3,}", in: s, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
