import XCTest
import LlamaEngine
@testable import LlamaEngineStore

final class BackendTests: XCTestCase {

    // MARK: - BackendKind

    func testBackendKindRawRoundTrip() {
        for kind in BackendKind.allCases {
            XCTAssertEqual(BackendKind(rawValue: kind.rawValue), kind)
        }
    }

    func testBackendKindUnknownRawIsNil() {
        XCTAssertNil(BackendKind(rawValue: "gemini"))
    }

    func testBackendKindLabels() {
        XCTAssertEqual(BackendKind.ollama.label, "Ollama")
        XCTAssertEqual(BackendKind.appleIntelligence.label, "Apple Intelligence")
    }

    // MARK: - ChatSession.isConfigured / backend accessor

    func testOllamaSessionNeedsModel() {
        let session = ChatSession(modelName: "")
        session.backend = .ollama
        XCTAssertFalse(session.isConfigured)

        session.modelName = "qwen-14b"
        XCTAssertTrue(session.isConfigured)
    }

    func testAppleSessionAlwaysConfigured() {
        let session = ChatSession(modelName: "")
        session.backend = .appleIntelligence
        XCTAssertTrue(session.isConfigured, "Apple Intelligence has a single on-device model")
    }

    func testBackendAccessorPersistsRaw() {
        let session = ChatSession()
        XCTAssertEqual(session.backend, .ollama)
        session.backend = .appleIntelligence
        XCTAssertEqual(session.backendRaw, BackendKind.appleIntelligence.rawValue)
    }

    // MARK: - AppleIntelligence availability

    func testAppleIntelligenceStatusIsConsistent() {
        // We can't force a specific status in CI, but the convenience flag and the
        // message must always agree with the status value.
        let available = AppleIntelligence.isAvailable
        XCTAssertEqual(available, AppleIntelligence.status == .available)
        XCTAssertFalse(AppleIntelligence.statusMessage.isEmpty)
    }

    // MARK: - ChatChunk replacement semantics

    func testChatChunkDefaultsToAppend() {
        let chunk = ChatChunk(contentDelta: "hi", done: false)
        XCTAssertFalse(chunk.isReplacement)
    }

    func testChatChunkReplacementFlag() {
        let chunk = ChatChunk(contentDelta: "full text", done: true, isReplacement: true)
        XCTAssertTrue(chunk.isReplacement)
        XCTAssertEqual(chunk.contentDelta, "full text")
    }

    /// The Ollama line parser must keep append semantics (never replacement).
    func testOllamaParsedChunksAreAppend() throws {
        let line = #"{"message":{"content":"Hello"},"done":false}"#
        let chunk = try XCTUnwrap(OllamaClient.parseLine(line))
        XCTAssertFalse(chunk.isReplacement)
    }
}
