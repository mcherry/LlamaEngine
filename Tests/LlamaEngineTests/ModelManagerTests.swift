import XCTest
@testable import LlamaEngine

/// Hermetic tests for `ModelManager`'s observable state and guard paths. The networked
/// paths (reload/pull/delete against a live server) are exercised via the live E2E
/// scripts, not here; these cover initial state and the no-server guards.
@MainActor
final class ModelManagerTests: XCTestCase {

    func testInitialStateIsEmpty() {
        let manager = ModelManager()
        XCTAssertTrue(manager.models.isEmpty)
        XCTAssertTrue(manager.running.isEmpty)
        XCTAssertFalse(manager.isLoading)
        XCTAssertFalse(manager.isPulling)
        XCTAssertEqual(manager.pullStatus, "")
        XCTAssertNil(manager.pullFraction)
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.isRunning("anything"))
    }

    func testReloadWithInvalidURLSetsErrorAndDoesNotHang() async {
        let manager = ModelManager()
        await manager.reload(serverURL: "")
        XCTAssertEqual(manager.errorMessage, "Invalid server URL. Check Settings.")
        XCTAssertFalse(manager.isLoading)
        XCTAssertTrue(manager.models.isEmpty)
    }

    func testPullWithEmptyNameIsNoOp() {
        let manager = ModelManager()
        manager.pull("   ", serverURL: "http://localhost:11434")
        XCTAssertFalse(manager.isPulling)
        XCTAssertEqual(manager.pullStatus, "")
    }

    func testCancelPullWhenIdleIsHarmless() {
        let manager = ModelManager()
        manager.cancelPull()
        XCTAssertFalse(manager.isPulling)
    }
}
