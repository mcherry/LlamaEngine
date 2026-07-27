import XCTest
@testable import LlamaEngine

/// A zero-call turn is not proof the model finished. These cover the ~9% of measured runs
/// where the call arrives as markup in `content` instead of as `tool_calls`.
final class TextualToolCallTests: XCTestCase {

    func testPlainProseIsNotMistakenForMarkup() {
        XCTAssertFalse(TextualToolCall.looksLikeMarkup("I'll read the file next."))
        XCTAssertTrue(TextualToolCall.parse("I'll read the file next.").isEmpty)
    }

    func testRecoversAParameterStyleCall() {
        let content = "<function=read_file><parameter=path>Sources/main.swift</parameter></function>"
        let calls = TextualToolCall.parse(content)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
        XCTAssertEqual(calls.first?.arguments.string("path"), "Sources/main.swift")
    }

    func testRecoversMultipleParameters() {
        let content = """
        <function=edit_file>
        <parameter=path>a.swift</parameter>
        <parameter=old_string>let a = 1</parameter>
        <parameter=new_string>let a = 2</parameter>
        </function>
        """
        let call = TextualToolCall.parse(content).first
        XCTAssertEqual(call?.arguments.string("path"), "a.swift")
        XCTAssertEqual(call?.arguments.string("old_string"), "let a = 1")
        XCTAssertEqual(call?.arguments.string("new_string"), "let a = 2")
    }

    func testMultiLineParameterValuesKeepTheirInteriorWhitespace() {
        let content = """
        <function=write_file><parameter=content>
        func f() {
            return 1
        }
        </parameter></function>
        """
        XCTAssertEqual(TextualToolCall.parse(content).first?.arguments.string("content"),
                       "func f() {\n    return 1\n}")
    }

    func testRecoversAJSONBodiedCall() {
        let content = #"<function=grep_search>{"query":"needle","limit":5}</function>"#
        let call = TextualToolCall.parse(content).first
        XCTAssertEqual(call?.name, "grep_search")
        XCTAssertEqual(call?.arguments.string("query"), "needle")
        XCTAssertEqual(call?.arguments.int("limit"), 5)
    }

    func testRecoversSeveralCallsInOneTurn() {
        let content = """
        <function=read_file><parameter=path>a.swift</parameter></function>
        <function=read_file><parameter=path>b.swift</parameter></function>
        """
        let calls = TextualToolCall.parse(content)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map { $0.arguments.string("path") }, ["a.swift", "b.swift"])
    }

    func testRecoveredCallsHaveDistinctIdentifiers() {
        let content = """
        <function=read_file><parameter=path>a.swift</parameter></function>
        <function=read_file><parameter=path>b.swift</parameter></function>
        """
        let ids = TextualToolCall.parse(content).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testAnUnterminatedCallStillYieldsWhatItHas() {
        // The model ran out of tokens mid-call; the arguments it emitted are usually whole.
        let content = "<function=read_file><parameter=path>a.swift</parameter>"
        XCTAssertEqual(TextualToolCall.parse(content).first?.arguments.string("path"), "a.swift")
    }

    func testACallWithNoArgumentsIsStillRecovered() {
        let calls = TextualToolCall.parse("<function=list_dir></function>")
        XCTAssertEqual(calls.first?.name, "list_dir")
        XCTAssertEqual(calls.first?.arguments, .object([:]))
    }

    func testMarkupIsRemovedFromWhatTheUserSees() {
        let content = "Let me look at that.\n<function=read_file><parameter=path>a.swift</parameter></function>"
        XCTAssertEqual(TextualToolCall.stripped(content), "Let me look at that.")
    }

    func testStrippingLeavesOrdinaryTextAlone() {
        XCTAssertEqual(TextualToolCall.stripped("Just prose."), "Just prose.")
    }

    func testStrippingRemovesEveryBlock() {
        let content = """
        First.
        <function=a></function>
        Second.
        <function=b></function>
        """
        let stripped = TextualToolCall.stripped(content)
        XCTAssertFalse(stripped.contains("<function="))
        XCTAssertTrue(stripped.contains("First."))
        XCTAssertTrue(stripped.contains("Second."))
    }

    func testMalformedMarkupIsIgnoredRatherThanCrashing() {
        XCTAssertTrue(TextualToolCall.parse("<function=").isEmpty)
        XCTAssertTrue(TextualToolCall.parse("<function=>").isEmpty)
    }

    // MARK: - Qwen's <tool_call> envelope

    func testRecoversAToolCallEnvelope() {
        let content = #"<tool_call>{"name": "read_file", "arguments": {"path": "a.swift"}}</tool_call>"#
        let call = TextualToolCall.parse(content).first
        XCTAssertEqual(call?.name, "read_file")
        XCTAssertEqual(call?.arguments.string("path"), "a.swift")
    }

    func testAcceptsParametersAsTheArgumentKey() {
        // Some chat templates spell it "parameters".
        let content = #"<tool_call>{"name": "list_dir", "parameters": {"path": "."}}</tool_call>"#
        XCTAssertEqual(TextualToolCall.parse(content).first?.arguments.string("path"), ".")
    }

    func testAToolCallWithNoArgumentsIsRecovered() {
        let content = #"<tool_call>{"name": "list_dir"}</tool_call>"#
        XCTAssertEqual(TextualToolCall.parse(content).first?.arguments, .object([:]))
    }

    func testRecoversSeveralToolCallEnvelopes() {
        let content = """
        <tool_call>{"name": "read_file", "arguments": {"path": "a.swift"}}</tool_call>
        <tool_call>{"name": "read_file", "arguments": {"path": "b.swift"}}</tool_call>
        """
        XCTAssertEqual(TextualToolCall.parse(content).map { $0.arguments.string("path") },
                       ["a.swift", "b.swift"])
    }

    func testBothMarkupStylesAreRecoveredInDocumentOrder() {
        let content = """
        <tool_call>{"name": "first"}</tool_call>
        <function=second></function>
        """
        XCTAssertEqual(TextualToolCall.parse(content).map(\.name), ["first", "second"])
    }

    func testAnEnvelopeWithNoNameIsIgnored() {
        XCTAssertTrue(TextualToolCall.parse(#"<tool_call>{"arguments":{}}</tool_call>"#).isEmpty)
    }

    func testMalformedEnvelopeJSONIsIgnored() {
        XCTAssertTrue(TextualToolCall.parse("<tool_call>not json</tool_call>").isEmpty)
    }

    func testToolCallMarkupIsRemovedFromWhatTheUserSees() {
        let content = #"Reading it.\#n<tool_call>{"name": "read_file"}</tool_call>"#
        XCTAssertEqual(TextualToolCall.stripped(content), "Reading it.")
    }

    // MARK: - Other families

    func testMistralToolCallsMarker() {
        let content = #"[TOOL_CALLS] [{"name": "read_file", "arguments": {"path": "a.swift"}}]"#
        let call = TextualToolCall.parse(content).first
        XCTAssertEqual(call?.name, "read_file")
        XCTAssertEqual(call?.arguments.string("path"), "a.swift")
    }

    func testLlamaPythonTagMarker() {
        let content = #"<|python_tag|>{"name": "list_dir", "arguments": {"path": "."}}"#
        XCTAssertEqual(TextualToolCall.parse(content).first?.name, "list_dir")
    }

    func testFunctionCallTagIsTreatedLikeToolCall() {
        let content = #"<function_call>{"name": "list_dir"}</function_call>"#
        XCTAssertEqual(TextualToolCall.parse(content).first?.name, "list_dir")
    }

    func testAWholeMessageThatIsJustACallIsRecovered() {
        let content = #"{"name": "read_file", "arguments": {"path": "a.swift"}}"#
        XCTAssertEqual(TextualToolCall.parse(content).first?.name, "read_file")
    }

    func testAWholeMessageThatIsAnArrayOfCallsIsRecovered() {
        let content = #"[{"name": "read_file"}, {"name": "list_dir"}]"#
        XCTAssertEqual(TextualToolCall.parse(content).map(\.name), ["read_file", "list_dir"])
    }

    func testArgumentsSentAsAJSONStringAreDecoded() {
        let content = #"<tool_call>{"name": "read_file", "arguments": "{\"path\": \"a.swift\"}"}</tool_call>"#
        XCTAssertEqual(TextualToolCall.parse(content).first?.arguments.string("path"), "a.swift")
    }

    // MARK: - False positives

    func testProseMentioningJSONIsNotExecuted() {
        // The dangerous case: text *about* a call must never become one.
        let content = #"You could call {"name": "read_file"} but I'd rather explain first."#
        XCTAssertTrue(TextualToolCall.parse(content).isEmpty)
    }

    func testACodeBlockContainingACallShapeIsNotExecuted() {
        let content = "Here's the shape:\n```json\n{\"name\": \"read_file\"}\n```"
        XCTAssertTrue(TextualToolCall.parse(content).isEmpty)
    }

    func testUnknownToolNamesAreDiscarded() {
        let content = #"<tool_call>{"name": "rm_rf_everything"}</tool_call>"#
        XCTAssertTrue(TextualToolCall.parse(content, knownTools: ["read_file"]).isEmpty)
    }

    func testKnownToolNamesSurviveTheFilter() {
        let content = #"<tool_call>{"name": "read_file"}</tool_call>"#
        XCTAssertEqual(TextualToolCall.parse(content, knownTools: ["read_file"]).count, 1)
    }

    func testOnlyTheKnownCallsAreKeptFromAMixedBatch() {
        let content = #"[{"name": "read_file"}, {"name": "made_up"}]"#
        XCTAssertEqual(TextualToolCall.parse(content, knownTools: ["read_file"]).map(\.name),
                       ["read_file"])
    }

    func testOrdinaryJSONWithoutANameIsNotACall() {
        XCTAssertTrue(TextualToolCall.parse(#"{"path": "a.swift"}"#).isEmpty)
    }
}
