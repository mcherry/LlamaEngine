import XCTest
@testable import LlamaEngine

final class BackendProfileTests: XCTestCase {

    func testEveryBackendHasMatchingProfile() {
        for kind in BackendKind.allCases {
            XCTAssertEqual(kind.profile.kind, kind, "profile.kind mismatch for \(kind)")
        }
    }

    func testOllamaHasFullServerCapabilities() {
        let p = BackendKind.ollama.profile
        XCTAssertTrue(p.needsServerURL)
        XCTAssertTrue(p.listsModels)
        XCTAssertTrue(p.contextWindowAdjustable)
        XCTAssertTrue(p.supportsSampling)
        XCTAssertTrue(p.supportsReasoning)
        XCTAssertTrue(p.supportsRetrieval)
        XCTAssertTrue(p.supportsKeepAlive)
        XCTAssertTrue(p.supportsModelManagement)
        XCTAssertFalse(p.producesImages)
        XCTAssertTrue(p.isChatBackend)
    }

    func testLlamaServerHasFixedWindowAndNoManagement() {
        let p = BackendKind.llamaServer.profile
        XCTAssertTrue(p.needsServerURL)
        XCTAssertTrue(p.listsModels)
        // Fixed at server launch, so the app doesn't set the window or manage models.
        XCTAssertFalse(p.contextWindowAdjustable)
        XCTAssertFalse(p.supportsKeepAlive)
        XCTAssertFalse(p.supportsModelManagement)
        XCTAssertTrue(p.supportsSampling)
        XCTAssertTrue(p.supportsReasoning)
        XCTAssertTrue(p.supportsRetrieval)
    }

    func testAppleIsOnDeviceWithNoServer() {
        let p = BackendKind.appleIntelligence.profile
        XCTAssertTrue(p.isOnDevice)
        XCTAssertFalse(p.needsServerURL)
        XCTAssertFalse(p.listsModels)
        XCTAssertFalse(p.supportsSampling)   // uses its own AppleGenerationOptions
        XCTAssertFalse(p.isOptionalFeature)
    }

    func testImageGenerationIsAnOptionalImageBackend() {
        let p = BackendKind.imageGeneration.profile
        XCTAssertTrue(p.producesImages)
        XCTAssertFalse(p.isChatBackend)
        XCTAssertTrue(p.isOptionalFeature)
        XCTAssertTrue(p.needsServerURL)
        XCTAssertTrue(p.listsModels)
        XCTAssertFalse(p.supportsRetrieval)
    }

    func testOnlyImageGenerationIsAnOptionalFeature() {
        let optional = BackendKind.allCases.filter { $0.profile.isOptionalFeature }
        XCTAssertEqual(optional, [.imageGeneration])
    }
}
