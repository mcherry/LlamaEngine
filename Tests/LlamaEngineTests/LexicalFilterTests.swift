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

    func testHitCountSubstringCaseInsensitive() {
        // Substring match (no stemming): "auth" hits "Authenticator", "retry" hits "retry".
        XCTAssertEqual(LexicalFilter.hitCount("The Authenticator retry loop", keywords: ["auth", "retry", "cache"]), 2)
        XCTAssertEqual(LexicalFilter.hitCount("", keywords: ["auth"]), 0)
        XCTAssertEqual(LexicalFilter.hitCount("anything", keywords: []), 0)
    }

    func testNarrowKeepsAllForSmallSets() {
        let texts = (0..<10).map { "chunk \($0)" }
        XCTAssertEqual(LexicalFilter.narrow(texts, keywords: ["chunk"]), Array(0..<10))
    }

    func testNarrowKeepsAllWhenNoKeywords() {
        let texts = (0..<300).map { "chunk \($0)" }
        XCTAssertEqual(LexicalFilter.narrow(texts, keywords: []).count, 300)
    }

    func testNarrowSelectsMatchesForLargeSets() {
        let texts = (0..<250).map { $0 % 12 == 0 ? "auth token flow \($0)" : "unrelated content \($0)" }
        let kept = LexicalFilter.narrow(texts, keywords: ["auth"], engageAbove: 200, limit: 300, floor: 8)
        XCTAssertLessThan(kept.count, 250)
        XCTAssertTrue(kept.allSatisfy { texts[$0].contains("auth") })
    }

    func testNarrowFallsBackWhenTooFewMatches() {
        var texts = (0..<250).map { "unrelated \($0)" }
        texts[0] = "auth here"; texts[1] = "auth again"
        XCTAssertEqual(LexicalFilter.narrow(texts, keywords: ["auth"], floor: 8).count, 250)
    }

    func testNarrowWeightsPathHits() {
        let texts = (0..<250).map { "unrelated \($0)" }
        var paths: [String?] = (0..<250).map { _ in "src/misc.swift" }
        for i in 0..<10 { paths[i] = "src/Auth/Login.swift" }
        let kept = LexicalFilter.narrow(texts, paths: paths, keywords: ["auth"], floor: 8)
        XCTAssertLessThan(kept.count, 250)
        XCTAssertTrue(kept.contains(0))
    }
}
