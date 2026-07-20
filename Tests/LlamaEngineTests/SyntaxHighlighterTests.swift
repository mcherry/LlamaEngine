import XCTest
@testable import LlamaEngine

final class SyntaxHighlighterTests: XCTestCase {

    private func kinds(_ code: String, _ language: String?) -> [SyntaxHighlighter.Kind] {
        SyntaxHighlighter.tokens(code, language: language).map(\.kind)
    }

    /// Convenience: the text of the first token of a given kind.
    private func firstText(_ code: String, _ language: String?,
                           _ kind: SyntaxHighlighter.Kind) -> String? {
        SyntaxHighlighter.tokens(code, language: language).first { $0.kind == kind }?.text
    }

    func testPlainOutputTagStaysPlain() {
        // A deliberately-plain tag keeps fixed-width output uncolored even though it is
        // tagged, so logs / diffs / transcripts aren't speckled with color.
        for tag in ["text", "output", "log", "diff", "console"] {
            let tokens = SyntaxHighlighter.tokens("let x = 42 // note", language: tag)
            XCTAssertEqual(tokens, [.init(kind: .plain, text: "let x = 42 // note")], "tag: \(tag)")
        }
    }

    func testNilLanguageIsSinglePlainToken() {
        let tokens = SyntaxHighlighter.tokens("plain text", language: nil)
        XCTAssertEqual(tokens, [.init(kind: .plain, text: "plain text")])
    }

    func testUnknownTaggedLanguageGetsGenericHighlighting() {
        // An unrecognized but tagged language falls back to generic highlighting: universal
        // keywords, numbers, and strings still color.
        let code = "func greet() { val x = 42; return \"hi\" }"
        let tokens = SyntaxHighlighter.tokens(code, language: "someobscurelang")
        XCTAssertTrue(tokens.contains(.init(kind: .keyword, text: "func")))
        XCTAssertTrue(tokens.contains(.init(kind: .keyword, text: "val")))
        XCTAssertTrue(tokens.contains(.init(kind: .keyword, text: "return")))
        XCTAssertEqual(firstText(code, "someobscurelang", .number), "42")
        XCTAssertEqual(firstText(code, "someobscurelang", .string), "\"hi\"")
        // The tokens must still reassemble to the exact source.
        XCTAssertEqual(tokens.map(\.text).joined(), code)
    }

    func testGenericSniffsDominantCommentMarker() {
        // Lines starting with ';' make it the sniffed comment marker for an unknown tag.
        let code = "; a header comment\nfoo bar\n; another comment"
        let comments = SyntaxHighlighter.tokens(code, language: "weirdlang")
            .filter { $0.kind == .comment }
        XCTAssertEqual(comments.count, 2)
        XCTAssertEqual(comments.first?.text, "; a header comment")
    }

    func testAssemblyProfile() {
        let code = "mov rax, 0x10 ; load\nsyscall"
        XCTAssertTrue(kinds(code, "asm").contains(.keyword))
        XCTAssertEqual(firstText(code, "asm", .keyword), "mov")
        XCTAssertEqual(firstText(code, "asm", .number), "0x10")
        XCTAssertEqual(firstText(code, "asm", .comment), "; load")
        // Case-insensitive: uppercase mnemonics/registers still color.
        XCTAssertTrue(SyntaxHighlighter.tokens("MOV RAX, 1", language: "nasm")
            .contains(.init(kind: .keyword, text: "MOV")))
    }

    func testReassemblyPreservesSource() {
        // Concatenating all token texts must reproduce the input exactly.
        let code = "func f() { let x = 42 // note\n return \"hi\" }"
        let joined = SyntaxHighlighter.tokens(code, language: "swift").map(\.text).joined()
        XCTAssertEqual(joined, code)
    }

    func testSwiftKeywordsStringsCommentsNumbers() {
        let code = "let n = 0xFF // hex\nlet s = \"hello\""
        let tokens = SyntaxHighlighter.tokens(code, language: "swift")
        XCTAssertTrue(tokens.contains(.init(kind: .keyword, text: "let")))
        XCTAssertEqual(firstText(code, "swift", .number), "0xFF")
        XCTAssertEqual(firstText(code, "swift", .comment), "// hex")
        XCTAssertEqual(firstText(code, "swift", .string), "\"hello\"")
    }

    func testPythonHashComment() {
        let code = "x = 1  # set x\n"
        XCTAssertEqual(firstText(code, "python", .comment), "# set x")
        // A '#' must NOT be treated as a comment in a C-family language.
        XCTAssertNil(firstText("#include <stdio.h>", "c", .comment))
    }

    func testJavaScriptBacktickString() {
        let code = "const t = `hi ${name}`"
        XCTAssertEqual(firstText(code, "js", .string), "`hi ${name}`")
        XCTAssertTrue(SyntaxHighlighter.tokens(code, language: "js")
            .contains(.init(kind: .keyword, text: "const")))
    }

    func testSqlKeywordsAreCaseInsensitive() {
        let upper = SyntaxHighlighter.tokens("SELECT * FROM t", language: "sql")
        XCTAssertTrue(upper.contains(.init(kind: .keyword, text: "SELECT")))
        XCTAssertTrue(upper.contains(.init(kind: .keyword, text: "FROM")))
        // SQL uses single-quoted strings and -- comments.
        XCTAssertEqual(firstText("select 'a' -- note", "sql", .string), "'a'")
        XCTAssertEqual(firstText("select 'a' -- note", "sql", .comment), "-- note")
    }

    func testBlockCommentSpansLines() {
        let code = "a /* multi\nline */ b"
        XCTAssertEqual(firstText(code, "c", .comment), "/* multi\nline */")
    }

    func testUnterminatedStringRunsToEnd() {
        let code = "let s = \"still typing"
        XCTAssertEqual(firstText(code, "swift", .string), "\"still typing")
    }

    func testUnterminatedBlockCommentRunsToEnd() {
        let code = "x /* never closed"
        XCTAssertEqual(firstText(code, "swift", .comment), "/* never closed")
    }

    func testPythonTripleQuotedString() {
        let code = "x = \"\"\"line1\nline2\"\"\""
        XCTAssertEqual(firstText(code, "python", .string), "\"\"\"line1\nline2\"\"\"")
    }

    func testEscapedQuoteInsideStringDoesNotTerminate() {
        let code = "\"a\\\"b\""           // "a\"b"
        XCTAssertEqual(firstText(code, "swift", .string), "\"a\\\"b\"")
    }

    func testIdentifierContainingKeywordNotFlagged() {
        // "letter" contains "let" but must remain plain (never a keyword token).
        let tokens = SyntaxHighlighter.tokens("letter = 1", language: "swift")
        XCTAssertFalse(tokens.contains(.init(kind: .keyword, text: "let")))
        XCTAssertFalse(tokens.contains { $0.kind == .keyword })
        // The identifier survives within the plain text (coalesced with following spaces).
        XCTAssertTrue(tokens.contains { $0.kind == .plain && $0.text.contains("letter") })
    }

    func testFloatAndExponentNumbers() {
        XCTAssertEqual(firstText("y = 3.14", "swift", .number), "3.14")
        XCTAssertEqual(firstText("y = 1.0e-9", "swift", .number), "1.0e-9")
    }
}
