import XCTest
@testable import LlamaEngine

final class ContextAssemblerTests: XCTestCase {

    // MARK: - Enriched retrieval query

    func testEnrichedQueryWithNoRecentReturnsCurrent() {
        XCTAssertEqual(ContextAssembler.enrichedRetrievalQuery(current: "hello", recentTurns: []),
                       "hello")
    }

    func testEnrichedQueryPrependsRecentTurns() {
        let q = ContextAssembler.enrichedRetrievalQuery(
            current: "what about the second one?",
            recentTurns: ["List three cars", "Supra, Miata, GT-R"])
        XCTAssertTrue(q.contains("Supra, Miata, GT-R"))
        XCTAssertTrue(q.hasSuffix("what about the second one?"), "current question stays last")
    }

    func testEnrichedQueryKeepsOnlyRecentTail() {
        // With keepTurns 2, only the last two prior turns are used.
        let q = ContextAssembler.enrichedRetrievalQuery(
            current: "current",
            recentTurns: ["oldest", "middle", "newest"])
        XCTAssertFalse(q.contains("oldest"))
        XCTAssertTrue(q.contains("middle"))
        XCTAssertTrue(q.contains("newest"))
    }

    func testEnrichedQueryCapsRecentLength() {
        let long = String(repeating: "x", count: 2000)
        let q = ContextAssembler.enrichedRetrievalQuery(current: "current", recentTurns: [long])
        // Capped tail (500) + newline + "current".
        XCTAssertLessThanOrEqual(q.count, 500 + 1 + "current".count)
        XCTAssertTrue(q.hasSuffix("current"))
    }

    // MARK: - MMR selection

    private func candidate(_ id: UUID, _ relevance: Float, _ embedding: [Float], tokens: Int = 10) -> MMRCandidate {
        MMRCandidate(id: id, relevance: relevance, embedding: embedding, tokens: tokens)
    }

    func testMMRPrefersDiverseOverRedundant() {
        let a = UUID(), b = UUID(), c = UUID()
        // A and B are identical (redundant); C is orthogonal and slightly less relevant.
        let candidates = [
            candidate(a, 0.9, [1, 0]),
            candidate(b, 0.9, [1, 0]),
            candidate(c, 0.7, [0, 1]),
        ]
        let order = ContextAssembler.mmrSelect(candidates, available: 100)
        // Highest-relevance A first, then the diverse C beats the redundant B.
        XCTAssertEqual(order, [a, c, b])
    }

    func testMMRRespectsBudget() {
        let a = UUID(), b = UUID(), c = UUID()
        let candidates = [
            candidate(a, 0.9, [1, 0]),
            candidate(b, 0.8, [0, 1]),
            candidate(c, 0.7, [1, 1]),
        ]
        // Budget fits only one 10-token chunk beyond the first (15 < 20).
        let order = ContextAssembler.mmrSelect(candidates, available: 15)
        XCTAssertEqual(order.count, 1)
        XCTAssertEqual(order.first, a)
    }

    func testMMREmptyAndZeroBudget() {
        XCTAssertTrue(ContextAssembler.mmrSelect([], available: 100).isEmpty)
        let one = candidate(UUID(), 0.9, [1, 0])
        XCTAssertTrue(ContextAssembler.mmrSelect([one], available: 0).isEmpty)
    }

    func testMMRAlwaysKeepsAtLeastTheTopChunk() {
        // A single chunk larger than the budget is still returned (better than nothing).
        let id = UUID()
        let order = ContextAssembler.mmrSelect([candidate(id, 0.9, [1, 0], tokens: 9999)], available: 100)
        XCTAssertEqual(order, [id])
    }
}
