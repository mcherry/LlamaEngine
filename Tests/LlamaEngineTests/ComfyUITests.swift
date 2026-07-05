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

    // MARK: - ComfyWorkflowValidator (pre-flight against a server schema)

    /// A small server schema: two model loaders (combo inputs) and a sampler (combos + typed
    /// inputs + graph connections) — enough to exercise every validation branch.
    static func sampleInfo() -> ComfyObjectInfo {
        ComfyObjectInfo.parse(Data(#"""
        {"CheckpointLoaderSimple":{"input":{"required":{"ckpt_name":[["sd_xl_base.safetensors","zimage_turbo.safetensors"]]}}},
         "VAELoader":{"input":{"required":{"vae_name":[["vae-ft-mse.safetensors"]]}}},
         "KSampler":{"input":{"required":{
            "seed":["INT",{"default":0}],"steps":["INT",{"default":20}],"cfg":["FLOAT",{"default":7.0}],
            "sampler_name":[["euler","dpmpp_2m"]],"scheduler":[["normal","karras"]],
            "model":["MODEL"],"positive":["CONDITIONING"],"negative":["CONDITIONING"],"latent_image":["LATENT"]}}}}
        """#.utf8))
    }

    func testValidateCleanWorkflowHasNoIssues() throws {
        let workflow = Data(#"""
        {"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"zimage_turbo.safetensors"}},
         "3":{"class_type":"KSampler","inputs":{"seed":123,"steps":8,"cfg":1.5,
              "sampler_name":"euler","scheduler":"normal",
              "model":["4",0],"positive":["6",0],"negative":["7",0],"latent_image":["5",0]}}}
        """#.utf8)
        XCTAssertTrue(try ComfyWorkflowValidator.validate(workflow: workflow, against: Self.sampleInfo()).isEmpty)
    }

    func testValidateFlagsMissingModelsAcrossCombos() throws {
        let workflow = Data(#"""
        {"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"missing.safetensors"}},
         "3":{"class_type":"KSampler","inputs":{"seed":1,"steps":8,"cfg":1.5,
              "sampler_name":"lcm","scheduler":"normal","model":["4",0]}}}
        """#.utf8)
        let issues = try ComfyWorkflowValidator.validate(workflow: workflow, against: Self.sampleInfo())
        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues.allSatisfy { $0.isBlocking })
        XCTAssertTrue(issues.contains {
            $0.classType == "CheckpointLoaderSimple" && $0.kind == .missingModel(input: "ckpt_name", value: "missing.safetensors")
        })
        XCTAssertTrue(issues.contains { $0.kind == .missingModel(input: "sampler_name", value: "lcm") })
    }

    func testValidateFlagsMissingNodeType() throws {
        let workflow = Data(#"{"9":{"class_type":"ReActorFaceSwap","inputs":{"swap_model":"inswapper_128.onnx"}}}"#.utf8)
        let issues = try ComfyWorkflowValidator.validate(workflow: workflow, against: Self.sampleInfo())
        XCTAssertEqual(issues.count, 1)                       // missing node stops input inspection
        XCTAssertEqual(issues.first?.kind, .missingNodeType)
        XCTAssertEqual(issues.first?.classType, "ReActorFaceSwap")
        XCTAssertEqual(issues.first?.isBlocking, true)
    }

    func testValidateUnknownInputIsAdvisory() throws {
        let workflow = Data(#"{"3":{"class_type":"KSampler","inputs":{"seed":1,"bogus":"x"}}}"#.utf8)
        let issues = try ComfyWorkflowValidator.validate(workflow: workflow, against: Self.sampleInfo())
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .unknownInput("bogus"))
        XCTAssertEqual(issues.first?.isBlocking, false)        // advisory, not fatal
    }

    func testValidatorSkipsConnectionsAndNumbers() throws {
        // Values as they arrive from JSONSerialization (NSNumber, arrays), not Swift literals.
        let node = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"""
        {"inputs":{"model":["4",0],"seed":20,"flag":true,"name":"euler"}}
        """#.utf8)) as? [String: Any])
        let inputs = try XCTUnwrap(node["inputs"] as? [String: Any])
        XCTAssertTrue(ComfyWorkflowValidator.isConnection(try XCTUnwrap(inputs["model"])))
        XCTAssertFalse(ComfyWorkflowValidator.isConnection(try XCTUnwrap(inputs["seed"])))
        XCTAssertNil(ComfyWorkflowValidator.comboString(try XCTUnwrap(inputs["seed"])))
        XCTAssertNil(ComfyWorkflowValidator.comboString(try XCTUnwrap(inputs["flag"])))
        XCTAssertEqual(ComfyWorkflowValidator.comboString(try XCTUnwrap(inputs["name"])), "euler")
    }

    func testValidateRejectsNonObjectWorkflow() {
        XCTAssertThrowsError(try ComfyWorkflowValidator.validate(workflow: Data("[]".utf8),
                                                                 against: Self.sampleInfo()))
    }

    // MARK: - Server-workflow discovery (/history parsing)

    func testParseHistoryDedupsLabelsAndOrders() throws {
        let history = Data(#"""
        {"old-run":{"prompt":[1,"old-run",
            {"3":{"class_type":"KSampler","inputs":{"seed":1}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"cats"}}},
            {"create_time":1000}]},
         "new-run":{"prompt":[2,"new-run",
            {"3":{"class_type":"KSampler","inputs":{"seed":2}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"cats"}}},
            {"create_time":3000}]},
         "other":{"prompt":[3,"other",
            {"1":{"class_type":"UNETLoader","inputs":{}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"dogs"}}},
            {"create_time":2000}]}}
        """#.utf8)
        let result = ComfyUIClient.parseHistory(history, limit: 10)
        // The two "cats" runs share a signature → deduped; "dogs" is distinct → 2 total.
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.source), [.history, .history])
        // Newest first: cats (t=3000) before dogs (t=2000).
        XCTAssertEqual(result.first?.name, "cats")
        XCTAssertTrue(result.contains { $0.name == "dogs" })
        // The kept "cats" is the newest run (seed 2, not the older seed 1).
        let workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: result[0].apiWorkflow) as? [String: Any])
        let seed = ((workflow["3"] as? [String: Any])?["inputs"] as? [String: Any])?["seed"] as? Int
        XCTAssertEqual(seed, 2)
    }

    func testParseHistoryFallsBackToRunLabel() {
        let history = Data(#"""
        {"abc12345-xyz":{"prompt":[1,"abc12345-xyz",{"3":{"class_type":"KSampler","inputs":{"seed":1}}},{"create_time":1}]}}
        """#.utf8)
        let result = ComfyUIClient.parseHistory(history, limit: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Run abc12345")   // no SaveImage → id-prefixed fallback
    }
}
