import Foundation

/// Repairs the most common Mermaid **flowchart** syntax error in LLM output: node
/// labels that contain bracket or operator characters (the brackets plus `~`, `<`, `>`,
/// `&`, `;`, `#`, and backtick) without being quoted, which the Mermaid parser rejects
/// (e.g. `D[Use weapon (knife, bat)]` or `E[Mass: >100 masses]`). The
/// fix is to wrap such labels in double quotes — `D["Use weapon (knife, bat)"]` — which
/// is semantically identical to an unquoted label.
///
/// Pure and synchronous, so it is unit-tested. **Typographic normalization**
/// (``normalizeTypography(_:)``) runs on *every* diagram type; the label-quoting repair
/// applies only to `graph` / `flowchart` diagrams. Because an already-valid flowchart
/// never has bare brackets in an unquoted label, valid diagrams pass through unchanged —
/// and callers should still render the original first and only fall back to the repaired
/// version when the original fails to parse.
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
        "~", "<", ">", "&", ";", "#", "`", "\""
    ]

    /// Invisible characters dropped entirely (they break lexing silently): zero-width
    /// space / non-joiner / joiner, the word joiner, BOM / zero-width no-break space, the
    /// soft hyphen, and the Mongolian vowel separator.
    private static let invisibleScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}", "\u{180E}"
    ]

    /// Exotic Unicode spaces collapsed to a plain space (a non-breaking space between two
    /// tokens is a classic invisible break).
    private static let unicodeSpaces: Set<Unicode.Scalar> = [
        "\u{00A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}",
        "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}",
        "\u{205F}", "\u{3000}"
    ]

    /// Typographic characters mapped to their ASCII equivalents: smart quotes, dashes,
    /// arrows, ellipsis, Unicode line/paragraph separators, and full-width structural
    /// punctuation. Ordinary text and non-Latin scripts are left intact.
    private static let scalarReplacements: [Unicode.Scalar: String] = [
        // Double quotes / guillemets / double prime
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
        "\u{00AB}": "\"", "\u{00BB}": "\"", "\u{2033}": "\"", "\u{FF02}": "\"",
        // Single quotes / apostrophes / prime / single guillemets
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{2032}": "'", "\u{2039}": "'", "\u{203A}": "'", "\u{FF07}": "'",
        // Dashes and the minus sign → hyphen-minus
        "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-", "\u{2013}": "-",
        "\u{2014}": "-", "\u{2015}": "-", "\u{2212}": "-", "\u{FF0D}": "-",
        // Ellipsis
        "\u{2026}": "...",
        // Unicode line / paragraph separators → newline
        "\u{2028}": "\n", "\u{2029}": "\n",
        // Arrows → ASCII
        "\u{2190}": "<-", "\u{2192}": "->", "\u{2194}": "<->",
        "\u{21D0}": "<=", "\u{21D2}": "=>", "\u{21D4}": "<=>",
        "\u{21A6}": "->", "\u{27F5}": "<-", "\u{27F6}": "->",
        "\u{2794}": "->", "\u{2799}": "->", "\u{279C}": "->", "\u{27A1}": "->", "\u{2B95}": "->",
        // Full-width structural punctuation → ASCII
        "\u{FF08}": "(", "\u{FF09}": ")", "\u{FF3B}": "[", "\u{FF3D}": "]",
        "\u{FF5B}": "{", "\u{FF5D}": "}", "\u{FF1C}": "<", "\u{FF1E}": ">",
        "\u{FF5C}": "|", "\u{FF03}": "#", "\u{FF06}": "&", "\u{FF1B}": ";", "\u{FF5E}": "~"
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
        let normalized = normalizeTypography(source)
        guard isFlowchart(normalized) else { return normalized }
        // Process per line: node labels don't span newlines, and this lets us skip
        // `%%` comment / `%%{init}%%` directive lines (which legitimately contain
        // brackets) without mangling them.
        let lines = normalized.components(separatedBy: "\n")
        let repaired = lines.map { line -> String in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("%%") ? line : repairLine(line)
        }
        return repaired.joined(separator: "\n")
    }

    /// Normalizes the typographic characters LLMs routinely emit that Mermaid's ASCII
    /// lexer can't parse — smart quotes, en/em dashes, arrows, ellipses, full-width
    /// punctuation — plus invisible gremlins (non-breaking / zero-width spaces, BOM, soft
    /// hyphens) and CR/LF & Unicode line separators. Applied to every diagram type (these
    /// are pure typographic variants of the ASCII Mermaid expects). Pure, for testing.
    public static func normalizeTypography(_ source: String) -> String {
        // Normalize line endings first so CRLF doesn't become a doubled newline below.
        let lineNormalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var out = ""
        out.reserveCapacity(lineNormalized.count)
        for scalar in lineNormalized.unicodeScalars {
            if invisibleScalars.contains(scalar) { continue }
            if let replacement = scalarReplacements[scalar] {
                out += replacement
            } else if unicodeSpaces.contains(scalar) {
                out += " "
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
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
