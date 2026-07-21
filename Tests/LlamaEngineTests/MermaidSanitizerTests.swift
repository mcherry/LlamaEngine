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
}
