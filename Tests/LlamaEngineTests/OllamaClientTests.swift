import XCTest
@testable import LlamaEngine

final class OllamaClientTests: XCTestCase {

    // MARK: - Stream line parsing

    func testParseStreamingDelta() throws {
        let line = #"{"model":"qwen-14b","message":{"role":"assistant","content":"Hello"},"done":false}"#
        let chunk = try XCTUnwrap(OllamaClient.parseLine(line))
        XCTAssertEqual(chunk.contentDelta, "Hello")
        XCTAssertFalse(chunk.done)
        XCTAssertNil(chunk.evalTokens)
        XCTAssertNil(chunk.promptTokens)
    }

    func testParseFinalLineWithStats() throws {
        let line = #"{"message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":12,"eval_count":34,"eval_duration":1000000000}"#
        let chunk = try XCTUnwrap(OllamaClient.parseLine(line))
        XCTAssertTrue(chunk.done)
        XCTAssertEqual(chunk.contentDelta, "")
        XCTAssertEqual(chunk.promptTokens, 12)
        XCTAssertEqual(chunk.evalTokens, 34)
        XCTAssertEqual(chunk.evalDurationNanos, 1_000_000_000)
    }

    func testParseDoneReasonLength() throws {
        let line = #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"length","eval_count":34}"#
        let chunk = try XCTUnwrap(OllamaClient.parseLine(line))
        XCTAssertTrue(chunk.done)
        XCTAssertEqual(chunk.doneReason, "length")
    }

    func testParseDoneReasonAbsentIsNil() throws {
        let chunk = try XCTUnwrap(OllamaClient.parseLine(#"{"message":{"content":"Hi"},"done":false}"#))
        XCTAssertNil(chunk.doneReason)
    }

    func testParseBlankLineReturnsNil() throws {
        XCTAssertNil(try OllamaClient.parseLine("   "))
        XCTAssertNil(try OllamaClient.parseLine("\n"))
        XCTAssertNil(try OllamaClient.parseLine(""))
    }

    func testParseThinkingDelta() throws {
        let line = #"{"message":{"role":"assistant","content":"","thinking":"Let me think"},"done":false}"#
        let chunk = try XCTUnwrap(OllamaClient.parseLine(line))
        XCTAssertEqual(chunk.thinkingDelta, "Let me think")
        XCTAssertEqual(chunk.contentDelta, "")
    }

    func testParseContentLineHasNoThinking() throws {
        let line = #"{"message":{"role":"assistant","content":"Hello"},"done":false}"#
        let chunk = try XCTUnwrap(OllamaClient.parseLine(line))
        XCTAssertEqual(chunk.contentDelta, "Hello")
        XCTAssertEqual(chunk.thinkingDelta, "")
    }

    func testParseErrorPayloadThrows() {
        let line = #"{"error":"model 'foo' not found"}"#
        XCTAssertThrowsError(try OllamaClient.parseLine(line)) { error in
            guard case OllamaError.server(let message) = error else {
                return XCTFail("Expected OllamaError.server, got \(error)")
            }
            XCTAssertEqual(message, "model 'foo' not found")
        }
    }

    func testParseSequenceReconstructsReply() throws {
        let lines = [
            #"{"message":{"content":"Hel"},"done":false}"#,
            #"{"message":{"content":"lo"},"done":false}"#,
            #"{"message":{"content":"!"},"done":true,"eval_count":3}"#
        ]
        var reply = ""
        var finished = false
        for line in lines {
            let chunk = try XCTUnwrap(OllamaClient.parseLine(line))
            reply += chunk.contentDelta
            finished = finished || chunk.done
        }
        XCTAssertEqual(reply, "Hello!")
        XCTAssertTrue(finished)
    }

    // MARK: - /api/show context length

    func testParseContextLengthFromModelInfo() throws {
        let json = #"""
        {"model_info":{"general.architecture":"qwen3","qwen3.context_length":40960,"qwen3.embedding_length":5120}}
        """#
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertEqual(OllamaClient.parseContextLength(data), 40960)
    }

    func testParseContextLengthMissingIsNil() throws {
        let data = try XCTUnwrap(#"{"model_info":{"general.architecture":"llama"}}"#.data(using: .utf8))
        XCTAssertNil(OllamaClient.parseContextLength(data))
    }

    func testParseContextLengthNoModelInfoIsNil() throws {
        let data = try XCTUnwrap(#"{"license":"MIT"}"#.data(using: .utf8))
        XCTAssertNil(OllamaClient.parseContextLength(data))
    }

    func testParseContextLengthGarbageIsNil() throws {
        let data = try XCTUnwrap("not json".data(using: .utf8))
        XCTAssertNil(OllamaClient.parseContextLength(data))
    }

    // MARK: - Title cleanup

    func testTitleStripsQuotesAndTrailingPunctuation() {
        XCTAssertEqual(TitleGenerator.clean("  \"Swift Concurrency Help.\"  "),
                       "Swift Concurrency Help")
    }

    func testTitleKeepsFirstNonEmptyLine() {
        XCTAssertEqual(TitleGenerator.clean("Build Script Fixes\nextra rambling"),
                       "Build Script Fixes")
    }

    func testTitleStripsLeadingThinkBlock() {
        XCTAssertEqual(TitleGenerator.clean("<think>let me think</think>\nNetwork Layer Design"),
                       "Network Layer Design")
    }

    func testTitleUnclosedThinkBlockReturnsNil() {
        // A reasoning model truncated mid-thought leaves no usable title.
        XCTAssertNil(TitleGenerator.clean("<think>still reasoning and never finished"))
    }

    func testTitleCapsWordCount() {
        let long = "one two three four five six seven eight nine ten"
        XCTAssertEqual(TitleGenerator.clean(long), "one two three four five six seven eight")
    }

    func testTitleEmptyReturnsNil() {
        XCTAssertNil(TitleGenerator.clean("   "))
        XCTAssertNil(TitleGenerator.clean(""))
    }

    // MARK: - Embedding model filtering

    func testEmbeddingModelDetectedByName() {
        let model = OllamaModel(name: "nomic-embed-text", details: nil)
        XCTAssertTrue(model.isEmbeddingModel)
    }

    func testEmbeddingModelDetectedByFamily() {
        let details = OllamaModel.Details(family: "bert-embeddings", families: nil, parameterSize: nil)
        let model = OllamaModel(name: "some-model", details: details)
        XCTAssertTrue(model.isEmbeddingModel)
    }

    func testChatModelNotFlaggedAsEmbedding() {
        let model = OllamaModel(name: "qwen-14b", details: nil)
        XCTAssertFalse(model.isEmbeddingModel)
    }
}
