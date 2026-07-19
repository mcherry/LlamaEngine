import XCTest
@testable import LlamaEngine

final class LlamaServerClientTests: XCTestCase {

    // MARK: - SSE line parsing

    func testParseContentDelta() throws {
        let line = #"data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"Hello"}}],"object":"chat.completion.chunk"}"#
        let event = try XCTUnwrap(LlamaServerClient.parseSSELine(line))
        XCTAssertEqual(event.content, "Hello")
        XCTAssertEqual(event.reasoning, "")
        XCTAssertFalse(event.isTerminator)
        XCTAssertNil(event.finishReason)
    }

    func testParseReasoningDelta() throws {
        // Reasoning models (gpt-oss/harmony) stream chain-of-thought as reasoning_content.
        let line = #"data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"User asks"}}]}"#
        let event = try XCTUnwrap(LlamaServerClient.parseSSELine(line))
        XCTAssertEqual(event.reasoning, "User asks")
        XCTAssertEqual(event.content, "")
    }

    func testParseFinishReason() throws {
        let line = #"data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}]}"#
        let event = try XCTUnwrap(LlamaServerClient.parseSSELine(line))
        XCTAssertEqual(event.finishReason, "stop")
        XCTAssertEqual(event.content, "")
    }

    func testParseUsageAndTimings() throws {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":34},"timings":{"prompt_n":12,"predicted_n":34,"predicted_ms":2000.0}}"#
        let event = try XCTUnwrap(LlamaServerClient.parseSSELine(line))
        XCTAssertEqual(event.promptTokens, 12)
        XCTAssertEqual(event.completionTokens, 34)
        XCTAssertEqual(event.evalDurationNanos, 2_000_000_000)   // 2000 ms -> nanos
    }

    func testParseDoneTerminator() throws {
        let event = try XCTUnwrap(LlamaServerClient.parseSSELine("data: [DONE]"))
        XCTAssertTrue(event.isTerminator)
    }

    func testParseBlankAndNonDataLinesReturnNil() throws {
        XCTAssertNil(try LlamaServerClient.parseSSELine(""))
        XCTAssertNil(try LlamaServerClient.parseSSELine("   "))
        XCTAssertNil(try LlamaServerClient.parseSSELine(": keep-alive comment"))
        XCTAssertNil(try LlamaServerClient.parseSSELine("event: message"))
    }

    func testParseErrorPayloadThrows() {
        let line = #"data: {"error":{"message":"boom","code":500}}"#
        XCTAssertThrowsError(try LlamaServerClient.parseSSELine(line)) { error in
            guard case LlamaServerError.server(let message) = error else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertEqual(message, "boom")
        }
    }

    // MARK: - Reasoning effort mapping

    func testReasoningEffortMapping() {
        XCTAssertEqual(LlamaServerClient.reasoningEffort(for: false), "low")
        XCTAssertEqual(LlamaServerClient.reasoningEffort(for: true), "high")
        XCTAssertNil(LlamaServerClient.reasoningEffort(for: nil))
    }

    // MARK: - Chat body encoding

    func testEncodeChatBodyShape() throws {
        let request = ChatRequest(
            model: "gpt-oss",
            messages: [ChatTurn(role: "user", content: "Hi")],
            contextSize: 32768,
            numPredict: 256,
            parameters: GenerationParameters(temperature: 0.7, topP: 0.9, topK: 40,
                                             repeatPenalty: 1.1, seed: 42, stop: ["STOP"])
        )
        let data = try LlamaServerClient.encodeChatBody(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["max_tokens"] as? Int, 256)
        XCTAssertEqual(object["temperature"] as? Double, 0.7)
        XCTAssertEqual(object["top_p"] as? Double, 0.9)
        XCTAssertEqual(object["top_k"] as? Int, 40)
        XCTAssertEqual(object["repeat_penalty"] as? Double, 1.1)
        XCTAssertEqual(object["seed"] as? Int, 42)
        XCTAssertEqual(object["stop"] as? [String], ["STOP"])
        let streamOptions = try XCTUnwrap(object["stream_options"] as? [String: Any])
        XCTAssertEqual(streamOptions["include_usage"] as? Bool, true)
    }

    func testEncodeChatBodyOmitsUnsetParameters() throws {
        let request = ChatRequest(model: "m", messages: [ChatTurn(role: "user", content: "Hi")],
                                  contextSize: 4096)
        let data = try LlamaServerClient.encodeChatBody(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["temperature"])
        XCTAssertNil(object["max_tokens"])
        XCTAssertNil(object["stop"])
        XCTAssertNil(object["seed"])
    }

    func testEncodeChatBodyInjectsReasoningSystemMessageWhenThinkFalse() throws {
        let request = ChatRequest(model: "m", messages: [ChatTurn(role: "user", content: "Hi")],
                                  contextSize: 4096, think: false)
        let data = try LlamaServerClient.encodeChatBody(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Reasoning: low")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
    }

    func testEncodeChatBodyNoReasoningMessageWhenThinkNil() throws {
        let request = ChatRequest(model: "m", messages: [ChatTurn(role: "user", content: "Hi")],
                                  contextSize: 4096)
        let data = try LlamaServerClient.encodeChatBody(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
    }

    // MARK: - Models parsing

    func testParseModelsFromDataArray() throws {
        let json = #"{"models":[{"name":"gpt-oss","capabilities":["completion"]}],"data":[{"id":"gpt-oss","meta":{"n_ctx":131072,"n_embd":2880}}]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ModelsResponse.self, from: Data(json.utf8))
        let models = LlamaServerClient.parseModels(response)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].name, "gpt-oss")
        XCTAssertEqual(models[0].capabilities, ["completion"])
        XCTAssertFalse(models[0].supportsVision)
        XCTAssertEqual(response.data?.first?.meta?.nCtx, 131072)
    }

    func testParseModelsFallsBackToModelsArray() throws {
        let json = #"{"models":[{"name":"only-here","capabilities":["completion"]}]}"#
        let response = try JSONDecoder().decode(ModelsResponse.self, from: Data(json.utf8))
        let models = LlamaServerClient.parseModels(response)
        XCTAssertEqual(models.map(\.name), ["only-here"])
    }

    // MARK: - Init

    func testInitRejectsInvalidURL() {
        XCTAssertNil(LlamaServerClient(baseURLString: ""))
        XCTAssertNil(LlamaServerClient(baseURLString: "not a url"))
        XCTAssertNotNil(LlamaServerClient(baseURLString: "http://192.168.1.10:8080"))
    }
}
