import XCTest
@testable import LlamaEngine

final class MermaidSanitizerTests: XCTestCase {

    func testQuotesLabelWithParentheses() {
        // The exact failure the user hit: unquoted parentheses in a node label.
        let src = "graph TD\n A --> D[Use melee weapon (knife, bat, etc.)]"
        let fixed = MermaidSanitizer.repair(src)
        XCTAssertEqual(fixed,
                       "graph TD\n A --> D[\"Use melee weapon (knife, bat, etc.)\"]")
    }

    func testLeavesCleanLabelsUntouched() {
        let src = "graph TD\n A[Start] --> B[Stop]"
        XCTAssertEqual(MermaidSanitizer.repair(src), src)
    }

    func testLeavesAlreadyQuotedLabelUntouched() {
        let src = "graph TD\n A[\"Use (knife)\"] --> B[End]"
        XCTAssertEqual(MermaidSanitizer.repair(src), src)
    }

    func testNonFlowchartReturnedUnchanged() {
        // A sequence diagram must not be altered even though it contains parentheses.
        let src = "sequenceDiagram\n Alice->>John: Hello (hi) there"
        XCTAssertEqual(MermaidSanitizer.repair(src), src)
    }

    func testRoundNodeWithBracket() {
        let src = "graph LR\n A(Config [beta]) --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph LR\n A(\"Config [beta]\") --> B")
    }

    func testSubroutineShapePreserved() {
        // `[[ ]]` must be matched as a unit, not as a `[` with inner `[text`.
        let src = "graph TD\n A[[Step (one)]] --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n A[[\"Step (one)\"]] --> B")
    }

    func testRhombusWithParens() {
        let src = "graph TD\n A{Decision (yes/no)} --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n A{\"Decision (yes/no)\"} --> B")
    }

    func testFlowchartKeywordAlsoRepaired() {
        let src = "flowchart LR\n A[Pick (x)] --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "flowchart LR\n A[\"Pick (x)\"] --> B")
    }

    func testEscapesEmbeddedQuotes() {
        let src = "graph TD\n A[Say \"hi\" (now)] --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n A[\"Say #quot;hi#quot; (now)\"] --> B")
    }

    func testPlainPunctuationNotQuoted() {
        // Colons, commas, dots, hyphens are valid unquoted; don't needlessly quote.
        let src = "graph TD\n A[Time: 5pm, ok-go] --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src), src)
    }

    func testQuotesLabelWithTildeOrGreaterThan() {
        // The IC 1101 galaxy diagram: ~ and > are Mermaid tokens the lexer rejects
        // inside an unquoted label. Quoting makes them literal.
        let src = "graph TD\n D[Stars: ~100 trillion]\n E[Mass: >100 solar]"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n D[\"Stars: ~100 trillion\"]\n E[\"Mass: >100 solar\"]")
    }

    func testStyleDirectiveWithHashNotMangled() {
        // `style` lines carry # colour codes but aren't node labels — leave them alone.
        let src = "graph TD\n A[X] --> B[Y]\n style A fill:#f9f,stroke:#333"
        XCTAssertEqual(MermaidSanitizer.repair(src), src)
    }

    func testLeadingDirectiveStillDetectsFlowchart() {
        let src = "%%{init: {'theme':'dark'}}%%\ngraph TD\n A[x (y)] --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "%%{init: {'theme':'dark'}}%%\ngraph TD\n A[\"x (y)\"] --> B")
    }

    // MARK: - Edge labels

    func testInlineEdgeLabelWithParensConvertedToPipe() {
        // The exact failure the user hit: parentheses in an inline edge label.
        let src = "graph TD\n F -- Ranged (Gun) --> G"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n F -->|\"Ranged (Gun)\"| G")
    }

    func testPipeEdgeLabelWithParensQuoted() {
        let src = "graph TD\n F -->|Ranged (Gun)| G"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n F -->|\"Ranged (Gun)\"| G")
    }

    func testPipeEdgeLabelAlreadyQuotedUntouched() {
        let src = "graph TD\n F -->|\"Ranged (Gun)\"| G"
        XCTAssertEqual(MermaidSanitizer.repair(src), src)
    }

    func testInlineEdgeLabelWithoutBracketsUntouched() {
        // No bracket characters -> valid as-is, leave the inline form alone.
        let src = "graph TD\n A -- yes --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src), src)
    }

    func testThickInlineEdgeLabelWithParens() {
        let src = "graph TD\n A == Mass (kg) ==> B"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n A ==>|\"Mass (kg)\"| B")
    }

    func testEdgeLabelAndNodeLabelTogether() {
        let src = "graph TD\n F -- Ranged (Gun) --> G[Aim (head)]"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n F -->|\"Ranged (Gun)\"| G[\"Aim (head)\"]")
    }

    func testPlainArrowNotMisread() {
        // A bare arrow with bracket node labels must not be treated as an edge label.
        let src = "graph TD\n A[x (1)] --> B[y (2)]"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n A[\"x (1)\"] --> B[\"y (2)\"]")
    }

    // MARK: - Typographic normalization

    func testNormalizesSmartQuotesInFlowchartLabel() {
        // The exact reported failure: curly quotes wrapping a node label.
        let src = "graph TD\n P --> Q[\u{201C}No Taxation Without Representation\u{201D}]"
        let fixed = MermaidSanitizer.repair(src)
        XCTAssertEqual(fixed, "graph TD\n P --> Q[\"No Taxation Without Representation\"]")
        XCTAssertFalse(fixed.unicodeScalars.contains("\u{201C}"))
    }

    func testNormalizesArrowInLabelThenQuotes() {
        // The next failure in the same diagram: a → inside a label.
        let src = "graph TD\n P --> S[Eventually \u{2192} Independence]"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n P --> S[\"Eventually -> Independence\"]")
    }

    func testNormalizesDashesEllipsisAndApostrophe() {
        let raw = "a \u{2014} b \u{2013} c \u{2212} d\u{2026} it\u{2019}s"
        XCTAssertEqual(MermaidSanitizer.normalizeTypography(raw), "a - b - c - d... it's")
    }

    func testStripsInvisiblesAndCollapsesSpaces() {
        // zero-width space (drop), NBSP (→ space), BOM (drop), soft hyphen (drop).
        let raw = "A\u{200B}B\u{00A0}C\u{FEFF}D\u{00AD}E"
        XCTAssertEqual(MermaidSanitizer.normalizeTypography(raw), "AB CDE")
    }

    func testNormalizesLineEndings() {
        XCTAssertEqual(MermaidSanitizer.normalizeTypography("a\r\nb\rc\u{2028}d"), "a\nb\nc\nd")
    }

    func testNormalizesFullwidthPunctuation() {
        // Full-width parens become ASCII, then the round-node label (with brackets) quotes.
        let src = "graph TD\n A\u{FF08}x [1]\u{FF09} --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src), "graph TD\n A(\"x [1]\") --> B")
    }

    func testNormalizationAppliesToNonFlowcharts() {
        // Smart quotes in a sequence-diagram message are normalized even though the
        // label-quoting repair is flowchart-only.
        let src = "sequenceDiagram\n Alice->>John: He said \u{201C}hi\u{201D}"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "sequenceDiagram\n Alice->>John: He said \"hi\"")
    }

    func testEmbeddedStraightQuoteMidLabelGetsQuoted() {
        // A stray double-quote mid-label (no other trigger) now forces quoting + escape.
        let src = "graph TD\n A[He said \"hi\" today] --> B"
        XCTAssertEqual(MermaidSanitizer.repair(src),
                       "graph TD\n A[\"He said #quot;hi#quot; today\"] --> B")
    }
}
