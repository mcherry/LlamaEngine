import XCTest
import LlamaEngine
@testable import LlamaEngineStore

/// Tests for `HistoryMode` and its `ChatSession` default. These stay in Llamatron
/// until the model enums + SwiftData store move into LlamaEngine in a later phase.
final class HistoryModeTests: XCTestCase {

    func testHistoryModeNeedsServer() {
        XCTAssertFalse(HistoryMode.full.needsServer)
        XCTAssertFalse(HistoryMode.truncate.needsServer)
        XCTAssertTrue(HistoryMode.summarize.needsServer)
        XCTAssertTrue(HistoryMode.retrieve.needsServer)
    }

    func testHistoryModeRawRoundTrip() {
        for mode in HistoryMode.allCases {
            XCTAssertEqual(HistoryMode(rawValue: mode.rawValue), mode)
        }
    }

    func testSessionDefaultsToFullHistory() {
        XCTAssertEqual(ChatSession().historyMode, .full)
    }
}
