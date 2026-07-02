import XCTest
import LlamaEngine
@testable import LlamaEngineStore

final class AppleGenerationOptionsTests: XCTestCase {

    func testEmptyByDefault() {
        XCTAssertTrue(AppleGenerationOptions().isEmpty)
    }

    func testNotEmptyWithTemperature() {
        XCTAssertFalse(AppleGenerationOptions(temperature: 0.5).isEmpty)
    }

    func testNotEmptyWithSamplingMode() {
        XCTAssertFalse(AppleGenerationOptions(samplingMode: .greedy).isEmpty)
    }

    func testNotEmptyWithMaxTokens() {
        XCTAssertFalse(AppleGenerationOptions(maximumResponseTokens: 256).isEmpty)
    }

    func testSamplingModeUsesSeed() {
        XCTAssertTrue(AppleSamplingMode.topK.usesSeed)
        XCTAssertTrue(AppleSamplingMode.topP.usesSeed)
        XCTAssertFalse(AppleSamplingMode.greedy.usesSeed)
        XCTAssertFalse(AppleSamplingMode.automatic.usesSeed)
    }

    func testSamplingModeRawRoundTrip() {
        for mode in AppleSamplingMode.allCases {
            XCTAssertEqual(AppleSamplingMode(rawValue: mode.rawValue), mode)
        }
    }

    // MARK: - ChatSession bridge

    func testSessionAppleOptionsReflectFields() {
        let session = ChatSession()
        session.backend = .appleIntelligence
        session.temperature = 0.6
        session.maxResponseTokens = 300
        session.appleSamplingMode = .topP
        session.topP = 0.95
        session.seed = 7

        let o = session.appleOptions
        XCTAssertEqual(o.temperature, 0.6)
        XCTAssertEqual(o.maximumResponseTokens, 300)
        XCTAssertEqual(o.samplingMode, .topP)
        XCTAssertEqual(o.topP, 0.95)
        XCTAssertEqual(o.seed, 7)
    }

    func testSessionAppleSamplingDefaultsToAutomatic() {
        XCTAssertEqual(ChatSession().appleSamplingMode, .automatic)
    }

    func testSessionSeedSharedBetweenBackends() {
        // Seed reuses the same stored field for both Ollama and Apple options.
        let session = ChatSession()
        session.seed = 42
        XCTAssertEqual(session.generationParameters.seed, 42)
        XCTAssertEqual(session.appleOptions.seed, 42)
    }
}
