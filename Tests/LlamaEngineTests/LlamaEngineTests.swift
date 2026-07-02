import XCTest
@testable import LlamaEngine

final class LlamaEngineTests: XCTestCase {
    func testVersionIsPresent() {
        XCTAssertFalse(LlamaEngine.version.isEmpty)
    }
}
