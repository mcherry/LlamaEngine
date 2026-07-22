import XCTest
@testable import LlamaEngine

/// Phase A tool-calling tests: the pure value types, the streamed-delta assembler, and
/// both backends' tool encoding + tool_call decoding. All offline/hermetic.
final class ToolCallingTests: XCTestCase {

    // MARK: - Role

    func testRoleToolRawValue() {
        XCTAssertEqual(Role.tool.rawValue, "tool")
        XCTAssertEqual(Role(rawValue: "tool"), .tool)
    }

    // MARK: - JSONValue

    func testJSONValueRoundTrips() throws {
        let json = #"{"a":1,"b":"x","c":true,"d":[1,2],"e":{"f":null}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let reDecoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value, reDecoded)
        XCTAssertEqual(value.string("b"), "x")
        XCTAssertEqual(value.objectValue?["c"], .bool(true))
    }

    func testJSONSchemaObjectBuilderEncodesSchema() throws {
        let schema = JSONSchema.object(
            properties: ["city": .object(["type": .string("string")])],
            required: ["city"])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "object")
        XCTAssertEqual(object?["required"] as? [String], ["city"])
        XCTAssertNotNil((object?["properties"] as? [String: Any])?["city"])
    }

    // MARK: - ToolCallAssembler

    func testAssembleSingleCompleteCall() {
        let calls = ToolCallAssembler.assemble([
            ToolCallDelta(index: 0, id: "abc", name: "get_weather", argumentsFragment: #"{"city":"Paris"}"#)
        ])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "abc")
        XCTAssertEqual(calls[0].name, "get_weather")
        XCTAssertEqual(calls[0].arguments.string("city"), "Paris")
    }

    func testAssembleFragmentedCall() {
        // The llama.cpp shape: name in the first fragment, arguments accreted across deltas.
        let calls = ToolCallAssembler.assemble([
            ToolCallDelta(index: 0, id: "c1", name: "get_weather", argumentsFragment: #"{"ci"#),
            ToolCallDelta(index: 0, argumentsFragment: #"ty":"Ber"#),
            ToolCallDelta(index: 0, argumentsFragment: #"lin"}"#)
        ])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "get_weather")
        XCTAssertEqual(calls[0].arguments.string("city"), "Berlin")
    }

    func testAssembleMultipleCallsAndSynthesizesMissingID() {
        let calls = ToolCallAssembler.assemble([
            ToolCallDelta(index: 0, name: "a", argumentsFragment: "{}"),
            ToolCallDelta(index: 1, name: "b", argumentsFragment: #"{"x":1}"#)
        ])
        XCTAssertEqual(calls.map(\.name), ["a", "b"])
        XCTAssertEqual(calls[0].id, "call_0")   // synthesized when the backend omits an id
        XCTAssertEqual(calls[1].id, "call_1")
    }

    func testAssembleDropsNamelessFragments() {
        let calls = ToolCallAssembler.assemble([ToolCallDelta(index: 0, argumentsFragment: #"{"x":1}"#)])
        XCTAssertTrue(calls.isEmpty)
    }

    func testAssembleMalformedArgumentsBecomeEmptyObject() {
        let calls = ToolCallAssembler.assemble([ToolCallDelta(index: 0, name: "x", argumentsFragment: "{not json")])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments, .object([:]))
    }

    // MARK: - Ollama wire encoding

    private func ollamaBody(_ request: ChatRequest) throws -> [String: Any] {
        let data = try OllamaClient.encodeChatBody(request)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testOllamaEncodesToolsInOpenAIEnvelope() throws {
        let spec = ToolSpec(name: "get_weather", description: "Weather for a city",
                            parameters: .object(properties: ["city": .object(["type": .string("string")])],
                                                required: ["city"]))
        let request = ChatRequest(model: "qwen", messages: [ChatTurn(role: "user", content: "hi")],
                                  contextSize: 4096, tools: [spec])
        let tools = try XCTUnwrap(try ollamaBody(request)["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
        XCTAssertEqual(function["description"] as? String, "Weather for a city")
        XCTAssertEqual((function["parameters"] as? [String: Any])?["required"] as? [String], ["city"])
    }

    func testOllamaOmitsToolsWhenEmpty() throws {
        let request = ChatRequest(model: "qwen", messages: [ChatTurn(role: "user", content: "hi")],
                                  contextSize: 4096)
        XCTAssertNil(try ollamaBody(request)["tools"])
    }

    // MARK: - Ollama tool_call decoding

    func testOllamaParseLineDecodesToolCalls() throws {
        let line = #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Rome"}}}]},"done":false}"#
        let chunk = try XCTUnwrap(try OllamaClient.parseLine(line))
        XCTAssertEqual(chunk.toolCallDeltas.count, 1)
        let calls = ToolCallAssembler.assemble(chunk.toolCallDeltas)
        XCTAssertEqual(calls.first?.name, "get_weather")
        XCTAssertEqual(calls.first?.arguments.string("city"), "Rome")
    }

    func testOllamaToolArgumentsPreserveCamelCaseKeys() throws {
        // Args are parsed via JSONSerialization, so camelCase keys survive the request
        // decoder's snake_case strategy (which would otherwise rename them).
        let line = #"{"message":{"tool_calls":[{"id":"x","function":{"name":"f","arguments":{"maxResults":5}}}]}}"#
        let chunk = try XCTUnwrap(try OllamaClient.parseLine(line))
        let calls = ToolCallAssembler.assemble(chunk.toolCallDeltas)
        XCTAssertEqual(calls.first?.arguments.objectValue?.keys.contains("maxResults"), true)
    }

    func testOllamaParseLineWithoutToolCallsIsEmpty() throws {
        let chunk = try XCTUnwrap(try OllamaClient.parseLine(#"{"message":{"content":"hi"},"done":false}"#))
        XCTAssertTrue(chunk.toolCallDeltas.isEmpty)
        XCTAssertEqual(chunk.contentDelta, "hi")
    }

    // MARK: - llama.cpp wire encoding

    private func llamaBody(_ request: ChatRequest) throws -> [String: Any] {
        let data = try LlamaServerClient.encodeChatBody(request)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLlamaServerEncodesTools() throws {
        let spec = ToolSpec(name: "f", description: "d", parameters: .empty)
        let request = ChatRequest(model: "m", messages: [ChatTurn(role: "user", content: "hi")],
                                  contextSize: 4096, tools: [spec])
        let tools = try XCTUnwrap(try llamaBody(request)["tools"] as? [[String: Any]])
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "f")
    }

    func testLlamaServerOmitsToolsWhenEmpty() throws {
        let request = ChatRequest(model: "m", messages: [ChatTurn(role: "user", content: "hi")], contextSize: 4096)
        XCTAssertNil(try llamaBody(request)["tools"])
    }

    // MARK: - llama.cpp tool_call decoding (streamed fragments)

    func testLlamaServerParseSSELineDecodesToolCallFragment() throws {
        let line = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":"{\"ci"}}]}}]}"#
        let event = try XCTUnwrap(try LlamaServerClient.parseSSELine(line))
        XCTAssertEqual(event.toolCallDeltas.count, 1)
        XCTAssertEqual(event.toolCallDeltas[0].index, 0)
        XCTAssertEqual(event.toolCallDeltas[0].id, "call_1")
        XCTAssertEqual(event.toolCallDeltas[0].name, "get_weather")
        XCTAssertEqual(event.toolCallDeltas[0].argumentsFragment, #"{"ci"#)
    }

    func testLlamaServerToolCallStreamAssembles() throws {
        let line1 = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"f","arguments":"{\"x\":"}}]}}]}"#
        let line2 = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"42}"}}]}}]}"#
        let e1 = try XCTUnwrap(try LlamaServerClient.parseSSELine(line1))
        let e2 = try XCTUnwrap(try LlamaServerClient.parseSSELine(line2))
        let calls = ToolCallAssembler.assemble(e1.toolCallDeltas + e2.toolCallDeltas)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "f")
        XCTAssertEqual(calls[0].arguments, .object(["x": .number(42)]))
    }

    func testLlamaServerParseSSELineWithoutToolCallsIsEmpty() throws {
        let event = try XCTUnwrap(try LlamaServerClient.parseSSELine(#"data: {"choices":[{"delta":{"content":"hi"}}]}"#))
        XCTAssertTrue(event.toolCallDeltas.isEmpty)
        XCTAssertEqual(event.content, "hi")
    }

    // MARK: - llama.cpp capability detection (/props)

    func testParsePropsDetectsToolsAndVision() {
        let json = #"{"chat_template_caps":{"supports_tools":true,"supports_tool_calls":true},"modalities":{"vision":true}}"#
        let caps = LlamaServerClient.parseProps(Data(json.utf8))
        XCTAssertTrue(caps.contains("tools"))
        XCTAssertTrue(caps.contains("vision"))
    }

    func testParsePropsToolsOnly() {
        XCTAssertEqual(LlamaServerClient.parseProps(Data(#"{"chat_template_caps":{"supports_tools":true}}"#.utf8)), ["tools"])
    }

    func testParsePropsEmptyWhenNoCaps() {
        XCTAssertTrue(LlamaServerClient.parseProps(Data(#"{"build_info":"b10066"}"#.utf8)).isEmpty)
    }
}
