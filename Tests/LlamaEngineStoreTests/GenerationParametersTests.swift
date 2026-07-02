import XCTest
import LlamaEngine
@testable import LlamaEngineStore

final class GenerationParametersTests: XCTestCase {

    // MARK: - GenerationParameters

    func testIsEmptyWhenUnset() {
        XCTAssertTrue(GenerationParameters().isEmpty)
    }

    func testIsNotEmptyWithSeed() {
        XCTAssertFalse(GenerationParameters(seed: 42).isEmpty)
    }

    func testIsNotEmptyWithStop() {
        XCTAssertFalse(GenerationParameters(stop: ["END"]).isEmpty)
    }

    // MARK: - ChatSession.generationParameters

    func testSessionParametersReflectFields() {
        let session = ChatSession(modelName: "qwen")
        session.temperature = 0.7
        session.seed = 99
        session.stopSequences = ["STOP"]

        let p = session.generationParameters
        XCTAssertEqual(p.temperature, 0.7)
        XCTAssertEqual(p.seed, 99)
        XCTAssertEqual(p.stop, ["STOP"])
        XCTAssertNil(p.topP)
    }

    // MARK: - Wire encoding

    private func encodedOptions(_ request: ChatRequest) throws -> [String: Any] {
        let data = try OllamaClient.encodeChatBody(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["options"] as? [String: Any])
    }

    func testEncodesAllParametersWithSnakeCaseKeys() throws {
        let params = GenerationParameters(temperature: 0.7, topP: 0.9, topK: 40,
                                          repeatPenalty: 1.1, seed: 42, stop: ["END", "STOP"])
        let request = ChatRequest(model: "qwen",
                                  messages: [ChatTurn(role: "user", content: "hi")],
                                  contextSize: 4096,
                                  parameters: params)
        let options = try encodedOptions(request)

        XCTAssertEqual(options["temperature"] as? Double, 0.7)
        XCTAssertEqual(options["top_p"] as? Double, 0.9)
        XCTAssertEqual(options["top_k"] as? Int, 40)
        XCTAssertEqual(options["repeat_penalty"] as? Double, 1.1)
        XCTAssertEqual(options["seed"] as? Int, 42)
        XCTAssertEqual(options["num_ctx"] as? Int, 4096)
        XCTAssertEqual(options["stop"] as? [String], ["END", "STOP"])
    }

    /// The request payload (used by the turn inspector) must encode the *entire*
    /// conversation in order, so a long chat's payload is complete and accurate.
    func testEncodesAllMessagesInOrder() throws {
        let messages = [
            ChatTurn(role: "system", content: "sys"),
            ChatTurn(role: "user", content: "u1"),
            ChatTurn(role: "assistant", content: "a1"),
            ChatTurn(role: "user", content: "u2"),
            ChatTurn(role: "assistant", content: "a2"),
            ChatTurn(role: "user", content: "u3"),
        ]
        let request = ChatRequest(model: "qwen", messages: messages, contextSize: 8192)
        let data = try OllamaClient.encodeChatBody(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertEqual(encoded.count, messages.count, "every message must be present")
        XCTAssertEqual(encoded.map { $0["content"] as? String },
                       ["sys", "u1", "a1", "u2", "a2", "u3"], "order must be preserved")
        XCTAssertEqual(encoded.last?["role"] as? String, "user", "latest turn is last")
    }

    func testOmitsUnsetParameters() throws {
        let request = ChatRequest(model: "qwen", messages: [], contextSize: 8192)
        let options = try encodedOptions(request)

        XCTAssertNil(options["temperature"])
        XCTAssertNil(options["top_p"])
        XCTAssertNil(options["top_k"])
        XCTAssertNil(options["repeat_penalty"])
        XCTAssertNil(options["seed"])
        XCTAssertNil(options["stop"])
        XCTAssertEqual(options["num_ctx"] as? Int, 8192)
    }

    func testSeedAloneIsEncoded() throws {
        let request = ChatRequest(model: "qwen", messages: [], contextSize: 4096,
                                  parameters: GenerationParameters(seed: 7))
        let options = try encodedOptions(request)
        XCTAssertEqual(options["seed"] as? Int, 7)
        XCTAssertNil(options["temperature"])
    }

    func testThinkOmittedWhenNil() throws {
        let request = ChatRequest(model: "qwen", messages: [], contextSize: 4096)
        let data = try OllamaClient.encodeChatBody(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["think"])
    }

    func testThinkEncodedWhenSet() throws {
        let request = ChatRequest(model: "qwen", messages: [], contextSize: 4096, think: false)
        let data = try OllamaClient.encodeChatBody(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["think"] as? Bool, false)
    }

    // MARK: - keep_alive / num_predict

    func testKeepAliveOmittedWhenNil() throws {
        let request = ChatRequest(model: "qwen", messages: [], contextSize: 4096)
        let data = try OllamaClient.encodeChatBody(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["keep_alive"])
    }

    func testKeepAliveEncodedWhenSet() throws {
        let request = ChatRequest(model: "qwen", messages: [], contextSize: 4096, keepAlive: "30m")
        let data = try OllamaClient.encodeChatBody(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["keep_alive"] as? String, "30m")
    }

    func testNumPredictEncodedInOptions() throws {
        let request = ChatRequest(model: "qwen", messages: [], contextSize: 4096, numPredict: 256)
        let options = try encodedOptions(request)
        XCTAssertEqual(options["num_predict"] as? Int, 256)
    }

    func testNumPredictOmittedWhenNil() throws {
        let request = ChatRequest(model: "qwen", messages: [], contextSize: 4096)
        let options = try encodedOptions(request)
        XCTAssertNil(options["num_predict"])
    }

    // MARK: - ReasoningMode

    func testReasoningModeThinkMapping() {
        XCTAssertNil(ReasoningMode.auto.think)
        XCTAssertEqual(ReasoningMode.on.think, true)
        XCTAssertEqual(ReasoningMode.off.think, false)
    }

    func testReasoningModeRawRoundTrip() {
        for mode in ReasoningMode.allCases {
            XCTAssertEqual(ReasoningMode(rawValue: mode.rawValue), mode)
        }
    }

    func testSessionReasoningDefaultsToAuto() {
        XCTAssertEqual(ChatSession().reasoningMode, .auto)
    }

    func testSessionReasoningPersistsRaw() {
        let session = ChatSession()
        session.reasoningMode = .on
        XCTAssertEqual(session.reasoningRaw, ReasoningMode.on.rawValue)
    }
}
