import XCTest
@testable import LlamaEngine

final class LexicalFilterTests: XCTestCase {

    func testKeywordsSplitCamelCaseAndDropStopwords() {
        let kws = LexicalFilter.keywords(from: "How does the isLoading spinner work?")
        XCTAssertTrue(kws.contains("loading"))
        XCTAssertTrue(kws.contains("spinner"))
        XCTAssertTrue(kws.contains("work"))
        XCTAssertFalse(kws.contains("the"))
        XCTAssertFalse(kws.contains("how"))
    }

    func testKeywordsSplitSnakeCaseAndDedupe() {
        let kws = LexicalFilter.keywords(from: "auth_token auth_token retry")
        XCTAssertEqual(kws.filter { $0 == "auth" }.count, 1)
        XCTAssertTrue(kws.contains("auth"))
        XCTAssertTrue(kws.contains("token"))
        XCTAssertTrue(kws.contains("retry"))
    }

    // MARK: - BM25

    func testBM25RanksARareTermAboveCommonOnes() {
        var texts = (0..<20).map { "the shell runs a command \($0)" }
        texts[7] = "the shell runs a pipeline with pipefail"
        let scores = LexicalFilter.bm25(texts, keywords: ["shell", "pipefail"])
        XCTAssertEqual(scores.indices.max { scores[$0] < scores[$1] }, 7)
    }

    func testBM25MatchesWordPrefixesAndIdentifierParts() {
        let scores = LexicalFilter.bm25(["The Authenticator retry loop", "isLoading spinner", "auth_token flow", "nothing here"],
                                        keywords: ["auth", "loading", "token"])
        XCTAssertGreaterThan(scores[0], 0)   // "auth" starts "Authenticator"
        XCTAssertGreaterThan(scores[1], 0)   // camelCase part
        XCTAssertGreaterThan(scores[2], 0)   // snake_case part
        XCTAssertEqual(scores[3], 0)
    }

    func testBM25SplitsOnUnicodePunctuation() {
        let scores = LexicalFilter.bm25(["\u{201C}quoted\u{201D} words\u{2014}dashes", "other"], keywords: ["quoted", "dashes"])
        XCTAssertGreaterThan(scores[0], 0)
        XCTAssertEqual(scores[1], 0)
    }

    func testBM25IsZeroWithoutKeywords() {
        XCTAssertEqual(LexicalFilter.bm25(["anything", "else"], keywords: []), [0, 0])
        XCTAssertEqual(LexicalFilter.bm25([], keywords: ["x"]), [])
    }

    func testBM25CountsPathHits() {
        let scores = LexicalFilter.bm25(["same text", "same text"],
                                        paths: ["src/Auth/Login.swift", "src/misc.swift"],
                                        keywords: ["auth"])
        XCTAssertGreaterThan(scores[0], scores[1])
    }

    // MARK: - Embedding shortlist

    func testNarrowKeepsAllForSmallSets() {
        XCTAssertEqual(LexicalFilter.narrow([Double](repeating: 1, count: 10)), Array(0..<10))
    }

    func testNarrowKeepsAllWhenTooFewMatch() {
        var scores = [Double](repeating: 0, count: 250)
        scores[0] = 2; scores[1] = 1
        XCTAssertEqual(LexicalFilter.narrow(scores, floor: 8).count, 250)
    }

    func testNarrowKeepsTheBestMatchesForLargeSets() {
        let scores = (0..<250).map { $0 % 12 == 0 ? Double($0) : 0 }
        let kept = LexicalFilter.narrow(scores, limit: 5)
        XCTAssertEqual(kept, [240, 228, 216, 204, 192])
    }
}
