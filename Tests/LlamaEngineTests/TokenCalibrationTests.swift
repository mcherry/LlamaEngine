import XCTest
@testable import LlamaEngine

final class TokenCalibrationTests: XCTestCase {

    // MARK: - Pure EMA update

    func testFirstObservationSetsRatio() throws {
        // Dense text: 133 real tokens for a 100-token estimate -> factor 1.33.
        let factor = try XCTUnwrap(TokenCalibrator.updatedFactor(current: nil,
                                                                 rawEstimate: 100,
                                                                 actualTokens: 133))
        XCTAssertEqual(factor, 1.33, accuracy: 0.0001)
    }

    func testEmaBlendsTowardObservation() throws {
        // current 1.0, observed 1.5 -> 1.0 + 0.3*(1.5-1.0) = 1.15.
        let factor = try XCTUnwrap(TokenCalibrator.updatedFactor(current: 1.0,
                                                                 rawEstimate: 100,
                                                                 actualTokens: 150))
        XCTAssertEqual(factor, 1.15, accuracy: 0.0001)
    }

    func testClampsToFloorOfOne() throws {
        // A model that tokenizes sparsely (80 tokens for 100 est) must not shrink the
        // estimate: calibration is conservative-only, so the factor floors at 1.0.
        let factor = try XCTUnwrap(TokenCalibrator.updatedFactor(current: nil,
                                                                 rawEstimate: 100,
                                                                 actualTokens: 80))
        XCTAssertEqual(factor, 1.0, accuracy: 0.0001)
    }

    func testClampsToCeiling() throws {
        let factor = try XCTUnwrap(TokenCalibrator.updatedFactor(current: nil,
                                                                 rawEstimate: 100,
                                                                 actualTokens: 500))
        XCTAssertEqual(factor, 2.5, accuracy: 0.0001)
    }

    func testInvalidInputsReturnNil() {
        XCTAssertNil(TokenCalibrator.updatedFactor(current: 1.2, rawEstimate: 0, actualTokens: 100))
        XCTAssertNil(TokenCalibrator.updatedFactor(current: 1.2, rawEstimate: 100, actualTokens: 0))
    }

    // MARK: - Store round-trip

    @MainActor
    func testRecordThenScalePersistsPerModel() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TokenCalibrationTests-\(UUID().uuidString)"))
        let calibrator = TokenCalibrator(userDefaults: defaults)

        XCTAssertEqual(calibrator.scale(for: "qwen"), 1.0, "unlearned models default to 1.0")

        calibrator.record(model: "qwen", rawEstimate: 100, actualTokens: 130)
        XCTAssertEqual(calibrator.scale(for: "qwen"), 1.3, accuracy: 0.0001)

        // A fresh instance on the same store reloads the learned factor.
        let reloaded = TokenCalibrator(userDefaults: defaults)
        XCTAssertEqual(reloaded.scale(for: "qwen"), 1.3, accuracy: 0.0001)
        XCTAssertEqual(reloaded.scale(for: "other"), 1.0)
    }
}
