import XCTest
@testable import LlamaEngine

/// Hermetic tests for ComfyUIClient's pure request/response logic and the object-info
/// decoder. The networked paths (upload/run against a live server) aren't exercised here.
final class ComfyUITests: XCTestCase {

    // MARK: - applyInputs (override injection)

    func testApplyInputsOverridesAndPreserves() throws {
        let workflow = Data(#"""
        {"6":{"class_type":"CLIPTextEncode","inputs":{"text":"old","clip":["4",1]}},
         "3":{"class_type":"KSampler","inputs":{"seed":0,"steps":20}}}
        """#.utf8)
        let out = try ComfyUIClient.applyInputs(
            to: workflow,
            strings: [ComfyNodeInput(nodeID: "6", input: "text"): "new prompt"],
            ints: [ComfyNodeInput(nodeID: "3", input: "seed"): 42])

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        let n6 = try XCTUnwrap((obj["6"] as? [String: Any])?["inputs"] as? [String: Any])
        XCTAssertEqual(n6["text"] as? String, "new prompt")
        XCTAssertNotNil(n6["clip"] as? [Any])                 // untouched input preserved
        let n3 = try XCTUnwrap((obj["3"] as? [String: Any])?["inputs"] as? [String: Any])
        XCTAssertEqual(n3["seed"] as? Int, 42)
        XCTAssertEqual(n3["steps"] as? Int, 20)               // untouched input preserved
    }

    func testApplyInputsSkipsUnknownNodes() throws {
        let workflow = Data(#"{"3":{"class_type":"KSampler","inputs":{"seed":0}}}"#.utf8)
        let out = try ComfyUIClient.applyInputs(
            to: workflow, ints: [ComfyNodeInput(nodeID: "999", input: "seed"): 7])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertNil(obj["999"])
    }

    func testApplyInputsRejectsNonObjectWorkflow() {
        XCTAssertThrowsError(try ComfyUIClient.applyInputs(to: Data("[]".utf8)))
    }

    // MARK: - request/response parsing

    func testWrapPrompt() throws {
        let wf = Data(#"{"3":{"class_type":"KSampler","inputs":{"seed":1}}}"#.utf8)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with:
            ComfyUIClient.wrapPrompt(wf, clientID: "cid")) as? [String: Any])
        XCTAssertEqual(obj["client_id"] as? String, "cid")
        XCTAssertNotNil(obj["prompt"] as? [String: Any])
    }

    func testParsePromptID() {
        XCTAssertEqual(ComfyUIClient.parsePromptID(Data(#"{"prompt_id":"abc-123","number":1}"#.utf8)), "abc-123")
        XCTAssertNil(ComfyUIClient.parsePromptID(Data("{}".utf8)))
    }

    func testParseHistoryOutputsAndCompletion() {
        let history = Data(#"""
        {"abc":{"outputs":{"9":{"images":[{"filename":"ComfyUI_0001.png","subfolder":"","type":"output"}]}},
                "status":{"status_str":"success","completed":true}}}
        """#.utf8)
        let refs = ComfyUIClient.parseHistoryOutputs(history, promptID: "abc")
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.filename, "ComfyUI_0001.png")
        XCTAssertEqual(refs.first?.type, "output")
        XCTAssertTrue(ComfyUIClient.historyIsComplete(history, promptID: "abc"))
        XCTAssertNil(ComfyUIClient.parseHistoryError(history, promptID: "abc"))
        XCTAssertTrue(ComfyUIClient.parseHistoryOutputs(history, promptID: "nope").isEmpty)
        XCTAssertFalse(ComfyUIClient.historyIsComplete(Data("{}".utf8), promptID: "abc"))
    }

    func testParseHistoryError() {
        let history = Data(#"""
        {"abc":{"status":{"status_str":"error",
          "messages":[["execution_error",{"exception_message":"CUDA out of memory"}]]}}}
        """#.utf8)
        XCTAssertEqual(ComfyUIClient.parseHistoryError(history, promptID: "abc"), "CUDA out of memory")
    }

    // MARK: - ComfyObjectInfo

    func testObjectInfoParse() {
        let info = Data(#"""
        {"CheckpointLoaderSimple":{"input":{"required":{"ckpt_name":[["a.safetensors","b.safetensors"]]}}},
         "KSampler":{"input":{"required":{"seed":["INT",{"default":0}],"steps":["INT",{"default":20}]},
                              "optional":{"denoise":["FLOAT",{"default":1.0}]}}}}
        """#.utf8)
        let parsed = ComfyObjectInfo.parse(info)
        XCTAssertEqual(parsed.comboOptions(node: "CheckpointLoaderSimple", input: "ckpt_name"),
                       ["a.safetensors", "b.safetensors"])
        XCTAssertEqual(parsed.inputs(of: "KSampler")["seed"]?.typeName, "INT")
        XCTAssertEqual(parsed.inputs(of: "KSampler")["denoise"]?.required, false)
        XCTAssertNil(parsed.comboOptions(node: "KSampler", input: "seed"))
        XCTAssertTrue(parsed.nodeTypes.contains("KSampler"))
        XCTAssertTrue(ComfyObjectInfo.parse(Data("nonsense".utf8)).nodes.isEmpty)
    }

    // MARK: - value/client basics

    func testComfyInputsConvenienceSetters() {
        var inputs = ComfyInputs()
        inputs.set("hi", node: "6", input: "text")
        inputs.set(42, node: "3", input: "seed")
        inputs.set(7.5, node: "3", input: "cfg")
        XCTAssertEqual(inputs.strings[ComfyNodeInput(nodeID: "6", input: "text")], "hi")
        XCTAssertEqual(inputs.ints[ComfyNodeInput(nodeID: "3", input: "seed")], 42)
        XCTAssertEqual(inputs.doubles[ComfyNodeInput(nodeID: "3", input: "cfg")], 7.5)
    }

    func testClientInitGuardsInvalidURL() {
        XCTAssertNil(ComfyUIClient(baseURLString: ""))
        XCTAssertNil(ComfyUIClient(baseURLString: "not a url"))
        XCTAssertNotNil(ComfyUIClient(baseURLString: "http://localhost:8188"))
    }
}
