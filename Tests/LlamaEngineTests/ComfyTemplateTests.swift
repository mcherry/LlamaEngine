import XCTest
@testable import LlamaEngine

/// Hermetic tests for the ComfyUI workflow-template model: mapping an `ImageRequest` onto a
/// template's node bindings, node lookups, model-name resolution, and Codable round-tripping.
final class ComfyTemplateTests: XCTestCase {

    /// A minimal txt2img workflow with friendly bindings, mirroring ComfyUI's default graph.
    static func sampleTemplate() -> ComfyWorkflowTemplate {
        let workflow = Data(#"""
        {"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"base.safetensors"}},
         "6":{"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["4",1]}},
         "7":{"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["4",1]}},
         "5":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":512,"batch_size":1}},
         "3":{"class_type":"KSampler","inputs":{"seed":0,"steps":20,"cfg":7.0,"sampler_name":"euler",
              "scheduler":"normal","denoise":1.0,"model":["4",0],"positive":["6",0],
              "negative":["7",0],"latent_image":["5",0]}},
         "8":{"class_type":"VAEDecode","inputs":{"samples":["3",0],"vae":["4",2]}},
         "9":{"class_type":"SaveImage","inputs":{"images":["8",0]}}}
        """#.utf8)
        return ComfyWorkflowTemplate(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Sample txt2img", kind: .textToImage, workflowJSON: workflow,
            parameters: [
                ComfyParameter(key: .prompt, nodeID: "6", input: "text", type: .string),
                ComfyParameter(key: .negativePrompt, nodeID: "7", input: "text", type: .string),
                ComfyParameter(key: .model, nodeID: "4", input: "ckpt_name", type: .string),
                ComfyParameter(key: .sampler, nodeID: "3", input: "sampler_name", type: .string),
                ComfyParameter(key: .seed, nodeID: "3", input: "seed", type: .int),
                ComfyParameter(key: .steps, nodeID: "3", input: "steps", type: .int),
                ComfyParameter(key: .cfg, nodeID: "3", input: "cfg", type: .double),
                ComfyParameter(key: .width, nodeID: "5", input: "width", type: .int),
                ComfyParameter(key: .height, nodeID: "5", input: "height", type: .int),
            ])
    }

    // MARK: - Request → inputs mapping

    func testTemplateInputsMapImageRequestOntoBoundNodes() {
        let request = ImageRequest(prompt: "a cat", negativePrompt: "blurry", model: "base.safetensors",
                                   steps: 8, width: 768, height: 512, cfgScale: 1.5, vae: "",
                                   seed: 123, sampler: "euler")
        let inputs = Self.sampleTemplate().inputs(for: request)
        XCTAssertEqual(inputs.strings[ComfyNodeInput(nodeID: "6", input: "text")], "a cat")
        XCTAssertEqual(inputs.strings[ComfyNodeInput(nodeID: "7", input: "text")], "blurry")
        XCTAssertEqual(inputs.strings[ComfyNodeInput(nodeID: "4", input: "ckpt_name")], "base.safetensors")
        XCTAssertEqual(inputs.strings[ComfyNodeInput(nodeID: "3", input: "sampler_name")], "euler")
        XCTAssertEqual(inputs.ints[ComfyNodeInput(nodeID: "3", input: "seed")], 123)
        XCTAssertEqual(inputs.ints[ComfyNodeInput(nodeID: "3", input: "steps")], 8)
        XCTAssertEqual(inputs.ints[ComfyNodeInput(nodeID: "5", input: "width")], 768)
        XCTAssertEqual(inputs.ints[ComfyNodeInput(nodeID: "5", input: "height")], 512)
        XCTAssertEqual(inputs.doubles[ComfyNodeInput(nodeID: "3", input: "cfg")], 1.5)
    }

    func testTemplateInputsSkipEmptyModelAndNilSeed() {
        let request = ImageRequest(prompt: "p", negativePrompt: "n", model: "", steps: 5,
                                   width: 512, height: 512, cfgScale: 7, vae: "", seed: nil, sampler: "")
        let inputs = Self.sampleTemplate().inputs(for: request)
        XCTAssertNil(inputs.strings[ComfyNodeInput(nodeID: "4", input: "ckpt_name")])   // empty model → template default
        XCTAssertNil(inputs.strings[ComfyNodeInput(nodeID: "3", input: "sampler_name")]) // empty sampler → template default
        XCTAssertNil(inputs.ints[ComfyNodeInput(nodeID: "3", input: "seed")])           // nil seed → caller resolves
        XCTAssertEqual(inputs.strings[ComfyNodeInput(nodeID: "6", input: "text")], "p") // prompt still bound
        XCTAssertEqual(inputs.ints[ComfyNodeInput(nodeID: "3", input: "steps")], 5)     // steps still bound
    }

    // MARK: - Node lookups

    func testTemplateClassTypeLookup() {
        let template = Self.sampleTemplate()
        XCTAssertEqual(template.classType(ofNode: "4"), "CheckpointLoaderSimple")
        XCTAssertEqual(template.classType(ofNode: "3"), "KSampler")
        XCTAssertNil(template.classType(ofNode: "999"))
        XCTAssertEqual(template.modelParameter?.input, "ckpt_name")
    }

    // MARK: - Model-name resolution (ComfyUIProvider pure helper)

    func testProviderModelNamesPrefersTemplateModelNode() {
        let info = ComfyObjectInfo.parse(Data(#"""
        {"CheckpointLoaderSimple":{"input":{"required":{"ckpt_name":[["base.safetensors","other.safetensors"]]}}},
         "UNETLoader":{"input":{"required":{"unet_name":[["flux.sft"]]}}}}
        """#.utf8))
        // The template binds .model to the checkpoint loader, so only its combo is used (no flux.sft).
        XCTAssertEqual(ComfyUIProvider.modelNames(from: info, template: Self.sampleTemplate()),
                       ["base.safetensors", "other.safetensors"])
    }

    func testProviderModelNamesUnionsLoadersWithoutTemplate() {
        let info = ComfyObjectInfo.parse(Data(#"""
        {"CheckpointLoaderSimple":{"input":{"required":{"ckpt_name":[["base.safetensors"]]}}},
         "UNETLoader":{"input":{"required":{"unet_name":[["flux.sft"]]}}}}
        """#.utf8))
        XCTAssertEqual(ComfyUIProvider.modelNames(from: info, template: nil),
                       ["base.safetensors", "flux.sft"])
    }

    func testProviderModelNamesDedupes() {
        let info = ComfyObjectInfo.parse(Data(#"""
        {"CheckpointLoaderSimple":{"input":{"required":{"ckpt_name":[["dup.safetensors"]]}}},
         "UNETLoader":{"input":{"required":{"unet_name":[["dup.safetensors","x.sft"]]}}}}
        """#.utf8))
        XCTAssertEqual(ComfyUIProvider.modelNames(from: info, template: nil), ["dup.safetensors", "x.sft"])
    }

    // MARK: - Persistence

    func testTemplateCodableRoundTrip() throws {
        let template = Self.sampleTemplate()
        let decoded = try JSONDecoder().decode(ComfyWorkflowTemplate.self,
                                               from: JSONEncoder().encode(template))
        XCTAssertEqual(decoded, template)
        XCTAssertEqual(decoded.kind, .textToImage)
        XCTAssertEqual(decoded.parameter(.prompt)?.nodeID, "6")
        XCTAssertEqual(decoded.parameters.count, 9)
    }
}
