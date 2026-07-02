import XCTest
@testable import LlamaEngine

final class ConversationHistoryTests: XCTestCase {

    private func turn(_ content: String, _ role: Role = .user, _ t: TimeInterval = 0) -> HistoryTurn {
        HistoryTurn(id: UUID(), role: role.rawValue, content: content,
                    createdAt: Date(timeIntervalSince1970: t), embedding: nil)
    }

    // MARK: - token count / fits

    func testTokenCountSumsTurns() {
        let turns = [turn(String(repeating: "a", count: 40)),   // ~10 tokens
                     turn(String(repeating: "b", count: 40))]   // ~10 tokens
        XCTAssertEqual(ConversationHistory.tokenCount(turns), 20)
    }

    func testFits() {
        let turns = [turn(String(repeating: "a", count: 40))]   // ~10 tokens
        XCTAssertTrue(ConversationHistory.fits(turns, budget: 10))
        XCTAssertFalse(ConversationHistory.fits(turns, budget: 9))
    }

    // MARK: - splitRecent

    func testSplitRecentKeepsLastN() {
        let turns = (0..<10).map { turn("t\($0)", .user, Double($0)) }
        let (older, recent) = ConversationHistory.splitRecent(turns, keepRecent: 4)
        XCTAssertEqual(older.count, 6)
        XCTAssertEqual(recent.count, 4)
        XCTAssertEqual(recent.first?.content, "t6")
        XCTAssertEqual(recent.last?.content, "t9")
    }

    func testSplitRecentFewerThanKeep() {
        let turns = [turn("a"), turn("b")]
        let (older, recent) = ConversationHistory.splitRecent(turns, keepRecent: 4)
        XCTAssertTrue(older.isEmpty)
        XCTAssertEqual(recent.count, 2)
    }

    // MARK: - truncateToFit

    func testTruncateKeepsNewestWithinBudget() {
        // Each turn ~10 tokens (40 chars). Budget 25 -> keep 2 newest.
        let turns = (0..<5).map { turn(String(repeating: "x", count: 40), .user, Double($0)) }
        let (kept, dropped) = ConversationHistory.truncateToFit(turns, budget: 25)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(dropped, 3)
        XCTAssertEqual(kept.last, turns.last, "newest turn is always kept")
    }

    func testTruncateAlwaysKeepsLastEvenIfOverBudget() {
        let turns = [turn(String(repeating: "y", count: 400))]   // ~100 tokens
        let (kept, dropped) = ConversationHistory.truncateToFit(turns, budget: 5)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(dropped, 0)
    }

    func testTruncateEverythingFitsKeepsAll() {
        let turns = (0..<3).map { turn("short", .user, Double($0)) }
        let (kept, dropped) = ConversationHistory.truncateToFit(turns, budget: 1000)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(dropped, 0)
    }

    func testTruncateEmpty() {
        let (kept, dropped) = ConversationHistory.truncateToFit([], budget: 100)
        XCTAssertTrue(kept.isEmpty)
        XCTAssertEqual(dropped, 0)
    }

    // MARK: - embedding pack/unpack round trip

    func testVectorPackUnpack() {
        let v: [Float] = [0.0, 1.5, -2.25, 3.125]
        let restored = Vector.unpack(Vector.pack(v))
        XCTAssertEqual(restored.count, v.count)
        for (a, b) in zip(v, restored) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }
}
