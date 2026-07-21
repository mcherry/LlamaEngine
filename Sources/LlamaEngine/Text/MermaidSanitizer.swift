import Foundation

/// Repairs the most common Mermaid **flowchart** syntax error in LLM output: node
/// labels that contain bracket or operator characters (the brackets plus `~`, `<`, `>`,
/// `&`, `;`, `#`, and backtick) without being quoted, which the Mermaid parser rejects
/// (e.g. `D[Use weapon (knife, bat)]` or `E[Mass: >100 masses]`). The
/// fix is to wrap such labels in double quotes — `D["Use weapon (knife, bat)"]` — which
/// is semantically identical to an unquoted label.
///
/// Pure and synchronous, so it is unit-tested. Only `graph` / `flowchart` diagrams are
/// touched; every other diagram type is returned unchanged. Because an already-valid
/// flowchart never has bare brackets in an unquoted label, valid diagrams pass through
/// unchanged — and callers should still render the original first and only fall back to
/// the repaired version when the original fails to parse.
public enum MermaidSanitizer {
    /// Characters that force a label to be quoted (structural tokens the parser would
    /// otherwise try to interpret). Beyond the brackets these include Mermaid operators
    /// that are unrecognized inside an unquoted label: `~`, `<`/`>` (link and flag
    /// tokens), `&` (node list), `;` (statement end), `#` (entity code) and backtick.
    /// Quoting is semantically identical, so quoting extra labels is always safe. Note
    /// this is only ever applied to text already found *inside* a node shape, so `style`
    /// / `linkStyle` lines and `#` colour codes are untouched.
    private static let triggers: Set<Character> = [
        "(", ")", "[", "]", "{", "}",
        "~", "<", ">", "&", ";", "#", "`"
    ]

    /// Node-shape opening delimiters (longest first) paired with their candidate
    /// closing delimiters. Ordering matters so `[[` is matched before `[`, etc.
    private static let shapes: [(open: String, close: [String])] = [
        ("([", ["])"]),     // stadium
        ("[[", ["]]"]),     // subroutine
        ("[(", [")]"]),     // cylinder
        ("((", ["))"]),     // circle
        ("{{", ["}}"]),     // hexagon
        ("[/", ["/]", "\\]"]), // parallelogram / trapezoid
        ("[\\", ["/]", "\\]"]), // parallelogram alt / trapezoid alt
        ("[", ["]"]),       // rectangle
        ("(", [")"]),       // round
        ("{", ["}"]),       // rhombus
        ("|", ["|"]),       // pipe edge label: A -->|label| B
    ]

    /// Returns `source` with flowchart node labels quoted where required. Non-flowchart
    /// input is returned unchanged.
    public static func repair(_ source: String) -> String {
        guard isFlowchart(source) else { return source }
        // Process per line: node labels don't span newlines, and this lets us skip
        // `%%` comment / `%%{init}%%` directive lines (which legitimately contain
        // brackets) without mangling them.
        let lines = source.components(separatedBy: "\n")
        let repaired = lines.map { line -> String in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("%%") ? line : repairLine(line)
        }
        return repaired.joined(separator: "\n")
    }

    /// Quotes node labels on a single flowchart line.
    private static func repairLine(_ line: String) -> String {
        // First normalize inline edge labels (A-- text --> B) to the pipe form with a
        // quoted label (A-->|"text"| B), which is Mermaid's reliable way to carry
        // punctuation. Then the shape scanner quotes node labels and pipe-form edge
        // labels (the "|" shape). Doing the inline conversion first keeps the scanner
        // from mis-reading parentheses inside an edge label as a round node.
        let chars = Array(convertInlineEdgeLabels(line))
        let n = chars.count
        var result = ""
        result.reserveCapacity(n + 16)
        var i = 0

        while i < n {
            if let shape = shape(at: chars, i),
               let (closeStart, closer) = findCloser(chars,
                                                     from: i + shape.open.count,
                                                     candidates: shape.close) {
                let inner = String(chars[(i + shape.open.count)..<closeStart])
                result += shape.open + quoteIfNeeded(inner) + closer
                i = closeStart + closer.count
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// Matches an inline edge label: `<startOp> text <endOp>` where the link operators
    /// have whitespace around the label text. Captures the text and the end operator.
    private static let inlineEdgeRegex: NSRegularExpression = {
        let pattern = #"(?:--|==)[ \t]+(\S.*?)[ \t]+(-->|---|==>|===|--[xo]|==[xo])"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Rewrites inline edge labels that contain bracket characters into the pipe form
    /// with a quoted label: `A -- foo (bar) --> B` becomes `A -->|"foo (bar)"| B`. Other
    /// lines (and labels without brackets) are returned unchanged.
    private static func convertInlineEdgeLabels(_ line: String) -> String {
        let ns = line as NSString
        let matches = inlineEdgeRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }

        var result = line
        // Apply right-to-left so earlier match ranges stay valid as we splice.
        for match in matches.reversed() {
            let text = ns.substring(with: match.range(at: 1))
            guard text.contains(where: { triggers.contains($0) }) else { continue }
            let endOp = ns.substring(with: match.range(at: 2))
            let replacement = "\(endOp)|\(quoteIfNeeded(text))|"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func isFlowchart(_ source: String) -> Bool {
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue } // blank / comment / directive
            let lower = line.lowercased()
            return lower == "graph" || lower == "flowchart"
                || lower.hasPrefix("graph ") || lower.hasPrefix("flowchart ")
                || lower.hasPrefix("graph\t") || lower.hasPrefix("flowchart\t")
        }
        return false
    }

    private static func shape(at chars: [Character], _ i: Int) -> (open: String, close: [String])? {
        for shape in shapes where matches(chars, i, shape.open) {
            return shape
        }
        return nil
    }

    /// Finds the earliest occurrence of any candidate closer at or after `from`.
    private static func findCloser(_ chars: [Character],
                                   from: Int,
                                   candidates: [String]) -> (Int, String)? {
        var k = from
        while k < chars.count {
            for candidate in candidates where matches(chars, k, candidate) {
                return (k, candidate)
            }
            k += 1
        }
        return nil
    }

    private static func matches(_ chars: [Character], _ i: Int, _ token: String) -> Bool {
        let t = Array(token)
        guard i + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[i + k] != t[k] { return false }
        return true
    }

    /// Quotes `inner` if it contains a trigger character and isn't already quoted.
    private static func quoteIfNeeded(_ inner: String) -> String {
        if inner.count >= 2, inner.hasPrefix("\""), inner.hasSuffix("\"") { return inner }
        guard inner.contains(where: { triggers.contains($0) }) else { return inner }
        let escaped = inner.replacingOccurrences(of: "\"", with: "#quot;")
        return "\"\(escaped)\""
    }
}
