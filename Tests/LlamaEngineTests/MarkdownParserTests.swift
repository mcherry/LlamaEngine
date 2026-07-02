import XCTest
@testable import LlamaEngine

final class MarkdownParserTests: XCTestCase {

    func testParagraph() {
        XCTAssertEqual(MarkdownParser.parse("Hello **world**."),
                       [.paragraph("Hello **world**.")])
    }

    func testHeadingLevels() {
        XCTAssertEqual(MarkdownParser.parse("# One"), [.heading(level: 1, text: "One")])
        XCTAssertEqual(MarkdownParser.parse("### Three"), [.heading(level: 3, text: "Three")])
        // Seven hashes is not a heading.
        XCTAssertEqual(MarkdownParser.parse("####### Nope"), [.paragraph("####### Nope")])
        // A hash without a space is not a heading.
        XCTAssertEqual(MarkdownParser.parse("#tag"), [.paragraph("#tag")])
    }

    func testFencedCodeBlockWithLanguage() {
        let md = "```swift\nlet x = 1\n\nprint(x)\n```"
        XCTAssertEqual(MarkdownParser.parse(md),
                       [.codeBlock(language: "swift", code: "let x = 1\n\nprint(x)")])
    }

    func testUnterminatedCodeBlockRunsToEnd() {
        let md = "```\nstill streaming"
        XCTAssertEqual(MarkdownParser.parse(md),
                       [.codeBlock(language: nil, code: "still streaming")])
    }

    func testUnorderedList() {
        let md = "- one\n* two\n+ three"
        XCTAssertEqual(MarkdownParser.parse(md),
                       [.unorderedList(["one", "two", "three"])])
    }

    func testOrderedList() {
        let md = "1. first\n2. second\n10. tenth"
        XCTAssertEqual(MarkdownParser.parse(md),
                       [.orderedList(["first", "second", "tenth"])])
    }

    func testBlockQuote() {
        let md = "> a quote\n> second line"
        XCTAssertEqual(MarkdownParser.parse(md),
                       [.quote(["a quote", "second line"])])
    }

    func testHorizontalRule() {
        XCTAssertEqual(MarkdownParser.parse("---"), [.horizontalRule])
        XCTAssertEqual(MarkdownParser.parse("***"), [.horizontalRule])
        XCTAssertEqual(MarkdownParser.parse("___"), [.horizontalRule])
    }

    func testMixedDocumentOrder() {
        let md = """
        # Title

        Intro paragraph.

        ```python
        print("hi")
        ```

        - a
        - b

        1. one
        2. two

        > note

        ---
        """
        XCTAssertEqual(MarkdownParser.parse(md), [
            .heading(level: 1, text: "Title"),
            .paragraph("Intro paragraph."),
            .codeBlock(language: "python", code: "print(\"hi\")"),
            .unorderedList(["a", "b"]),
            .orderedList(["one", "two"]),
            .quote(["note"]),
            .horizontalRule
        ])
    }

    func testParagraphBreaksAtBlankLine() {
        let md = "Line one\nstill one\n\nSecond paragraph"
        XCTAssertEqual(MarkdownParser.parse(md),
                       [.paragraph("Line one\nstill one"), .paragraph("Second paragraph")])
    }

    // MARK: - Tables

    func testSimpleTable() {
        let md = """
        | Name | Size |
        |------|------|
        | qwen | 14b  |
        | gpt  | 7b   |
        """
        XCTAssertEqual(MarkdownParser.parse(md), [
            .table(headers: ["Name", "Size"],
                   rows: [["qwen", "14b"], ["gpt", "7b"]])
        ])
    }

    func testTableWithAlignmentColons() {
        let md = """
        | Left | Center | Right |
        | :--- | :----: | ----: |
        | a    | b      | c     |
        """
        XCTAssertEqual(MarkdownParser.parse(md), [
            .table(headers: ["Left", "Center", "Right"],
                   rows: [["a", "b", "c"]])
        ])
    }

    func testTableWithoutOuterPipes() {
        let md = """
        Name | Size
        -----|-----
        qwen | 14b
        """
        XCTAssertEqual(MarkdownParser.parse(md), [
            .table(headers: ["Name", "Size"], rows: [["qwen", "14b"]])
        ])
    }

    func testRaggedRowsNormalizedToHeaderCount() {
        let md = """
        | A | B | C |
        |---|---|---|
        | 1 | 2 |
        | 1 | 2 | 3 | 4 |
        """
        XCTAssertEqual(MarkdownParser.parse(md), [
            .table(headers: ["A", "B", "C"],
                   rows: [["1", "2", ""], ["1", "2", "3"]])
        ])
    }

    func testParagraphFollowedByTable() {
        let md = """
        Here is a table:

        | A | B |
        |---|---|
        | 1 | 2 |
        """
        XCTAssertEqual(MarkdownParser.parse(md), [
            .paragraph("Here is a table:"),
            .table(headers: ["A", "B"], rows: [["1", "2"]])
        ])
    }

    func testPipesWithoutDelimiterStayParagraph() {
        // A line with pipes but no `|---|` delimiter row is not a table.
        let md = "a | b | c\nd | e | f"
        XCTAssertEqual(MarkdownParser.parse(md), [.paragraph("a | b | c\nd | e | f")])
    }

    func testTableEndsAtBlankLine() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |

        After.
        """
        XCTAssertEqual(MarkdownParser.parse(md), [
            .table(headers: ["A", "B"], rows: [["1", "2"]]),
            .paragraph("After.")
        ])
    }
}
