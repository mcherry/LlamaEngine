import Foundation

/// Turns raw HTML into clean plain text for web sources — a readability-lite
/// extractor: it drops scripts, styles, and common boilerplate (nav/header/footer/aside),
/// preserves paragraph breaks, strips the remaining tags, and decodes HTML entities. Pure
/// (no networking), so the parsing is unit-testable. Treat its output as *untrusted
/// reference text* — never as instructions.
public enum HTMLExtractor {

    public struct Result: Equatable {
        public var title: String
        public var text: String
        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    public static func extract(_ html: String) -> Result {
        let title = decodeEntities(firstGroup("<title[^>]*>(.*?)</title>", in: html) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var s = html
        // Drop comments and whole non-content elements (with their contents).
        s = replace("<!--.*?-->", in: s, with: " ")
        for tag in ["script", "style", "head", "noscript", "template", "svg", "nav", "header", "footer", "aside", "form"] {
            s = replace("<\(tag)\\b[^>]*>.*?</\(tag)>", in: s, with: " ")
        }
        // Turn block-level boundaries into line breaks so text doesn't run together.
        s = replace("</(p|div|li|h[1-6]|tr|section|article|blockquote|ul|ol|table)>", in: s, with: "\n")
        s = replace("<br\\s*/?>", in: s, with: "\n")
        // Strip every remaining tag.
        s = replace("<[^>]+>", in: s, with: " ")
        s = decodeEntities(s)

        // Collapse runs of spaces, trim each line, drop blank lines.
        let lines = s.components(separatedBy: "\n")
            .map { replace("[ \\t\\u00A0]+", in: $0, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Result(title: title, text: lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    /// Case-insensitive, dot-matches-newline replace via ICU regex.
    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: "(?is)" + pattern, with: replacement, options: .regularExpression)
    }

    /// The first capture group of `pattern` in `text`, or nil.
    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}",
        "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}",
        "&copy;": "\u{00A9}", "&reg;": "\u{00AE}", "&trade;": "\u{2122}", "&deg;": "\u{00B0}"
    ]

    static func decodeEntities(_ text: String) -> String {
        var s = text
        // Numeric entities: &#123; and &#x1F;
        s = replaceNumericEntities(s)
        for (entity, value) in namedEntities {
            s = s.replacingOccurrences(of: entity, with: value)
        }
        // &amp; is handled above; do it last-ish by also catching a double-encoded form.
        return s
    }

    private static func replaceNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let isHex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
