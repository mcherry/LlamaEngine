import XCTest
import LlamaEngine
@testable import LlamaEngineStore

/// Round-trip tests for the `SessionConfig` snapshot/apply used by "new chat like this"
/// and session presets. `ChatSession` is instantiated directly (no container needed for
/// plain property access).
final class SessionConfigTests: XCTestCase {

    func testSnapshotApplyRoundTrip() {
        let source = ChatSession()
        source.backend = .llamaServer
        source.modelName = "gpt-oss"
        source.contextSize = 8192
        source.systemPrompt = "You are helpful."
        source.temperature = 0.35
        source.topK = 40
        source.seed = 12345
        source.reasoningMode = .on
        source.historyMode = .retrieve
        source.contextMode = .retrieval
        source.imageSteps = 30
        source.ttsEnabled = true

        let dest = ChatSession()
        dest.apply(source.configSnapshot())

        XCTAssertEqual(dest.backend, .llamaServer)
        XCTAssertEqual(dest.modelName, "gpt-oss")
        XCTAssertEqual(dest.contextSize, 8192)
        XCTAssertEqual(dest.systemPrompt, "You are helpful.")
        XCTAssertEqual(dest.temperature, 0.35)
        XCTAssertEqual(dest.topK, 40)
        XCTAssertEqual(dest.seed, 12345)
        XCTAssertEqual(dest.reasoningMode, .on)
        XCTAssertEqual(dest.historyMode, .retrieve)
        XCTAssertEqual(dest.contextMode, .retrieval)
        XCTAssertEqual(dest.imageSteps, 30)
        XCTAssertTrue(dest.ttsEnabled)
    }

    func testConfigCodableRoundTrip() throws {
        var config = SessionConfig()
        config.modelName = "qwen3:14b"
        config.temperature = 0.7
        config.contextSize = 16384
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: data)
        XCTAssertEqual(decoded.modelName, "qwen3:14b")
        XCTAssertEqual(decoded.temperature, 0.7)
        XCTAssertEqual(decoded.contextSize, 16384)
    }

    func testPresetDecodeToleratesMissingKeys() throws {
        // A preset saved before a field existed decodes fine (missing keys → nil).
        let json = #"{"id":"abc","name":"Old","config":{"modelName":"llama3"}}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let preset = try JSONDecoder().decode(SessionPreset.self, from: data)
        XCTAssertEqual(preset.name, "Old")
        XCTAssertEqual(preset.config.modelName, "llama3")
        XCTAssertNil(preset.config.temperature)
    }

    func testApplySkipsNilNonOptionalFields() {
        let dest = ChatSession()
        dest.modelName = "keep-me"
        var config = SessionConfig()   // everything nil…
        config.temperature = 0.9       // …except one generation param
        dest.apply(config)
        // The non-optional field is left untouched (nil skipped); the optional one applies.
        XCTAssertEqual(dest.modelName, "keep-me")
        XCTAssertEqual(dest.temperature, 0.9)
    }
}
