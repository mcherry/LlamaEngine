import XCTest
@testable import LlamaEngine

final class ContextStrategyTests: XCTestCase {

    // MARK: - TokenEstimator

    func testTokenEstimateRoundsUp() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        XCTAssertEqual(TokenEstimator.estimate("abcd"), 1)       // 4 chars
        XCTAssertEqual(TokenEstimator.estimate("abcde"), 2)      // 5 chars -> ceil(1.25)
        XCTAssertEqual(TokenEstimator.estimate(["abcd", "abcd"]), 2)
    }

    // MARK: - ContextBudget

    func testBudgetReservesForResponseAndInputs() {
        let budget = ContextBudget(contextSize: 8192, systemTokens: 100, historyTokens: 200, userTokens: 50)
        // reserve = clamp(8192/4 = 2048) = 2048; used = 100+200+50+2048 = 2398; free = 5794;
        // available fills only safetyFraction (0.75) of free = floor(5794 * 0.75) = 4345.
        XCTAssertEqual(budget.responseReserve, 2048)
        XCTAssertEqual(budget.availableForContext, 4345)
    }

    func testBudgetNeverNegative() {
        let budget = ContextBudget(contextSize: 1000, systemTokens: 5000, historyTokens: 0, userTokens: 0)
        XCTAssertEqual(budget.availableForContext, 0)
    }

    func testBudgetResponseReserveBounds() {
        XCTAssertEqual(ContextBudget(contextSize: 1000, systemTokens: 0, historyTokens: 0, userTokens: 0).responseReserve, 1024)
        XCTAssertEqual(ContextBudget(contextSize: 100000, systemTokens: 0, historyTokens: 0, userTokens: 0).responseReserve, 8192)
    }

    func testBudgetReservesFullCapForReasoningOnLargeWindow() {
        // A 32K window reserves the full cap so a reasoning model's thinking + answer fit.
        let budget = ContextBudget(contextSize: 32768, systemTokens: 0, historyTokens: 0, userTokens: 0)
        XCTAssertEqual(budget.responseReserve, 8192)
        // free = 32768 - 8192 = 24576; available = floor(24576 * 0.75) = 18432.
        XCTAssertEqual(budget.availableForContext, 18432)
    }

    func testLargeDocAutoSwitchesToRetrievalWithRealisticBudget() {
        // Regression: a ~21k-token *estimate* in a 32K window must NOT inline — it tokenizes
        // to ~28k for real and would truncate a reasoning reply, so auto switches to retrieval.
        let budget = ContextBudget(contextSize: 32768, systemTokens: 10, historyTokens: 0, userTokens: 10)
        let plan = ContextPlanner.plan(contentTokens: 21181,
                                       available: budget.availableForContext,
                                       mode: .auto,
                                       wholeDocTask: false)
        XCTAssertEqual(plan.first, .retrieval)
    }

    // MARK: - ContextSize.rightSized

    func testRightSizedSnapsUpToPreset() {
        // A small request in a 32K ceiling snaps down to the smallest preset that fits.
        XCTAssertEqual(ContextSize.rightSized(needed: 300, ceiling: 32768), 4096)
        XCTAssertEqual(ContextSize.rightSized(needed: 5000, ceiling: 32768), 8192)
        XCTAssertEqual(ContextSize.rightSized(needed: 9000, ceiling: 32768), 16384)
    }

    func testRightSizedNeverExceedsCeiling() {
        // Need beyond the ceiling just returns the ceiling (the hard cap).
        XCTAssertEqual(ContextSize.rightSized(needed: 40000, ceiling: 32768), 32768)
        // Smallest preset above need is over the ceiling -> clamp to ceiling.
        XCTAssertEqual(ContextSize.rightSized(needed: 5000, ceiling: 6000), 6000)
    }

    func testRightSizedHandlesNonPresetCeiling() {
        // A model-reported max (non-preset) is honored as the cap.
        XCTAssertEqual(ContextSize.rightSized(needed: 100, ceiling: 40960), 4096)
        XCTAssertEqual(ContextSize.rightSized(needed: 50000, ceiling: 40960), 40960)
    }

    // MARK: - ContextPlanner: auto mode

    func testPlanAutoInlineWhenItFits() {
        let plan = ContextPlanner.plan(contentTokens: 100, available: 1000, mode: .auto, wholeDocTask: false)
        XCTAssertEqual(plan, [.inline, .retrieval, .summarize, .truncate])
    }

    func testPlanAutoRetrievalWhenTooBigAndFocused() {
        let plan = ContextPlanner.plan(contentTokens: 5000, available: 1000, mode: .auto, wholeDocTask: false)
        XCTAssertEqual(plan, [.retrieval, .summarize, .truncate])
    }

    func testPlanAutoSummarizeWhenTooBigAndWholeDoc() {
        let plan = ContextPlanner.plan(contentTokens: 5000, available: 1000, mode: .auto, wholeDocTask: true)
        XCTAssertEqual(plan, [.summarize, .retrieval, .truncate])
    }

    // MARK: - ContextPlanner: forced modes still fall back

    func testPlanForcedRetrieval() {
        let plan = ContextPlanner.plan(contentTokens: 5000, available: 1000, mode: .retrieval, wholeDocTask: false)
        XCTAssertEqual(plan, [.retrieval, .summarize, .truncate])
    }

    func testPlanForcedSummarize() {
        let plan = ContextPlanner.plan(contentTokens: 5000, available: 1000, mode: .summarize, wholeDocTask: false)
        XCTAssertEqual(plan, [.summarize, .retrieval, .truncate])
    }

    func testPlanForcedInline() {
        let plan = ContextPlanner.plan(contentTokens: 5000, available: 1000, mode: .inline, wholeDocTask: false)
        XCTAssertEqual(plan, [.inline, .retrieval, .summarize, .truncate])
    }

    func testPlanAlwaysEndsWithTruncate() {
        for mode in ContextMode.allCases {
            let plan = ContextPlanner.plan(contentTokens: 9999, available: 100, mode: mode, wholeDocTask: false)
            XCTAssertEqual(plan.last, .truncate, "mode \(mode) should fall back to truncate")
        }
    }

    func testPlanEmptyWhenNoContentOrBudget() {
        XCTAssertTrue(ContextPlanner.plan(contentTokens: 0, available: 1000, mode: .auto, wholeDocTask: false).isEmpty)
        XCTAssertTrue(ContextPlanner.plan(contentTokens: 100, available: 0, mode: .auto, wholeDocTask: false).isEmpty)
    }

    func testPlanHasNoDuplicates() {
        let plan = ContextPlanner.plan(contentTokens: 5000, available: 100, mode: .retrieval, wholeDocTask: false)
        XCTAssertEqual(plan.count, Set(plan).count)
    }

    // MARK: - Whole-doc heuristic

    func testWholeDocHeuristic() {
        XCTAssertTrue(ContextPlanner.looksLikeWholeDocTask("Please summarize this file"))
        XCTAssertTrue(ContextPlanner.looksLikeWholeDocTask("Give me an OVERVIEW"))
        XCTAssertTrue(ContextPlanner.looksLikeWholeDocTask("tl;dr?"))
        XCTAssertFalse(ContextPlanner.looksLikeWholeDocTask("What port does the server use?"))
    }

    // MARK: - Vector cosine

    func testCosineIdenticalIsOne() {
        XCTAssertEqual(Vector.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1, accuracy: 1e-6)
    }

    func testCosineOrthogonalIsZero() {
        XCTAssertEqual(Vector.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-6)
    }

    func testCosineMismatchedOrEmptyIsZero() {
        XCTAssertEqual(Vector.cosineSimilarity([1, 2, 3], [1, 2]), 0)
        XCTAssertEqual(Vector.cosineSimilarity([], []), 0)
        XCTAssertEqual(Vector.cosineSimilarity([0, 0], [0, 0]), 0)
    }

    func testCosineOppositeIsNegativeOne() {
        XCTAssertEqual(Vector.cosineSimilarity([1, 1], [-1, -1]), -1, accuracy: 1e-6)
    }

    // MARK: - TextChunker

    func testChunkerEmpty() {
        XCTAssertTrue(TextChunker().chunk("   ").isEmpty)
    }

    func testChunkerSmallTextIsOneChunk() {
        let chunks = TextChunker(targetTokens: 100, overlapTokens: 0).chunk("Hello world")
        XCTAssertEqual(chunks, ["Hello world"])
    }

    func testChunkerSplitsByParagraphWithinBudget() {
        // targetTokens 10 -> ~40 chars per chunk.
        let para = String(repeating: "a", count: 30)
        let text = "\(para)\n\n\(para)\n\n\(para)"
        let chunks = TextChunker(targetTokens: 10, overlapTokens: 0).chunk(text)
        XCTAssertGreaterThan(chunks.count, 1)
        // Every chunk should contain the source content somewhere.
        XCTAssertTrue(chunks.allSatisfy { $0.contains("a") })
    }

    func testChunkerHardSplitsLongParagraph() {
        let huge = String(repeating: "x", count: 500)   // far over a 10-token (~40 char) budget
        let chunks = TextChunker(targetTokens: 10, overlapTokens: 0).chunk(huge)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), huge)
    }

    // MARK: - TextTruncator

    func testTruncatorShortTextUnchanged() {
        XCTAssertEqual(TextTruncator.truncate("short", toTokens: 100), "short")
    }

    func testTruncatorClipsAndKeepsHeadAndTail() {
        let text = String(repeating: "A", count: 200) + String(repeating: "Z", count: 200)
        let result = TextTruncator.truncate(text, toTokens: 20) // ~80 chars budget
        XCTAssertLessThan(result.count, text.count)
        XCTAssertTrue(result.hasPrefix("A"))
        XCTAssertTrue(result.hasSuffix("Z"))
        XCTAssertTrue(result.contains("trimmed"))
    }

    func testTruncatorZeroBudgetIsEmpty() {
        XCTAssertEqual(TextTruncator.truncate("anything", toTokens: 0), "")
    }
}
