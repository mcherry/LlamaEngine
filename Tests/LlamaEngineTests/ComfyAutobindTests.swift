import XCTest
@testable import LlamaEngine

/// Hermetic tests for auto-detecting txt2img parameter bindings from an API-format workflow.
final class ComfyAutobindTests: XCTestCase {

    /// A standard ComfyUI txt2img graph (checkpoint → two CLIP encoders → KSampler → decode → save).
    /// Node ids for the positive/negative encoders are deliberately "unusual" (positive is a
    /// higher-numbered id than negative) to prove detection follows the sampler's links, not id order.
    static let standardGraph = Data(#"""
    {"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"zimage_turbo.safetensors"}},
     "10":{"class_type":"CLIPTextEncode","inputs":{"text":"a cat","clip":["4",1]}},
     "6":{"class_type":"CLIPTextEncode","inputs":{"text":"blurry","clip":["4",1]}},
     "5":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":512,"batch_size":1}},
     "3":{"class_type":"KSampler","inputs":{"seed":0,"steps":20,"cfg":7.0,"sampler_name":"euler",
          "scheduler":"normal","denoise":1.0,"model":["4",0],"positive":["10",0],
          "negative":["6",0],"latent_image":["5",0]}},
     "8":{"class_type":"VAEDecode","inputs":{"samples":["3",0],"vae":["4",2]}},
     "9":{"class_type":"SaveImage","inputs":{"images":["8",0]}}}
    """#.utf8)

    private func binding(_ params: [ComfyParameter], _ key: ComfyParameterKey) -> ComfyParameter? {
        params.first { $0.key == key }
    }

    func testAutobindDetectsStandardTxt2ImgBindings() {
        let params = ComfyWorkflowTemplate.detectedParameters(in: Self.standardGraph)
        XCTAssertEqual(binding(params, .seed)?.nodeID, "3")
        XCTAssertEqual(binding(params, .seed)?.input, "seed")
        XCTAssertEqual(binding(params, .steps)?.nodeID, "3")
        XCTAssertEqual(binding(params, .cfg)?.nodeID, "3")
        XCTAssertEqual(binding(params, .sampler)?.input, "sampler_name")
        XCTAssertEqual(binding(params, .scheduler)?.input, "scheduler")
        XCTAssertEqual(binding(params, .denoise)?.input, "denoise")
        XCTAssertEqual(binding(params, .width)?.nodeID, "5")
        XCTAssertEqual(binding(params, .height)?.nodeID, "5")
        XCTAssertEqual(binding(params, .model)?.nodeID, "4")
        XCTAssertEqual(binding(params, .model)?.input, "ckpt_name")
    }

    func testAutobindDistinguishesPromptFromNegativeViaLinks() {
        let params = ComfyWorkflowTemplate.detectedParameters(in: Self.standardGraph)
        // Positive link → node 10, negative link → node 6 (not id order).
        XCTAssertEqual(binding(params, .prompt)?.nodeID, "10")
        XCTAssertEqual(binding(params, .prompt)?.input, "text")
        XCTAssertEqual(binding(params, .negativePrompt)?.nodeID, "6")
    }

    func testAutoboundTemplateRunsThroughInputsMapping() {
        // End-to-end: an auto-bound template maps an ImageRequest onto the right nodes.
        let template = ComfyWorkflowTemplate.autobound(name: "Z", workflowJSON: Self.standardGraph)
        let request = ImageRequest(prompt: "hello", negativePrompt: "bad", model: "zimage_turbo.safetensors",
                                   steps: 6, width: 768, height: 1024, cfgScale: 1.0, vae: "", seed: 99,
                                   sampler: "dpmpp_2m")
        let inputs = template.inputs(for: request)
        XCTAssertEqual(inputs.strings[ComfyNodeInput(nodeID: "10", input: "text")], "hello")
        XCTAssertEqual(inputs.strings[ComfyNodeInput(nodeID: "6", input: "text")], "bad")
        XCTAssertEqual(inputs.ints[ComfyNodeInput(nodeID: "3", input: "seed")], 99)
        XCTAssertEqual(inputs.ints[ComfyNodeInput(nodeID: "5", input: "height")], 1024)
        XCTAssertEqual(inputs.strings[ComfyNodeInput(nodeID: "4", input: "ckpt_name")], "zimage_turbo.safetensors")
    }

    func testAutobindHandlesKSamplerAdvancedNoiseSeed() {
        let graph = Data(#"""
        {"1":{"class_type":"UNETLoader","inputs":{"unet_name":"flux.sft"}},
         "2":{"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["9",0]}},
         "3":{"class_type":"KSamplerAdvanced","inputs":{"noise_seed":5,"steps":20,"cfg":3.5,
              "sampler_name":"euler","scheduler":"simple","model":["1",0],"positive":["2",0],
              "negative":["2",0],"latent_image":["4",0]}},
         "4":{"class_type":"EmptyLatentImage","inputs":{"width":1024,"height":1024,"batch_size":1}}}
        """#.utf8)
        let params = ComfyWorkflowTemplate.detectedParameters(in: graph)
        XCTAssertEqual(binding(params, .seed)?.input, "noise_seed")
        XCTAssertEqual(binding(params, .model)?.nodeID, "1")
        XCTAssertEqual(binding(params, .model)?.input, "unet_name")
    }

    func testAutobindPartialGraphBindsWhatItCan() {
        // No latent node linked → no width/height, but the sampler scalars + prompt still bind.
        let graph = Data(#"""
        {"6":{"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["4",1]}},
         "3":{"class_type":"KSampler","inputs":{"seed":0,"steps":8,"cfg":2.0,"sampler_name":"euler",
              "scheduler":"normal","denoise":1.0,"positive":["6",0]}}}
        """#.utf8)
        let params = ComfyWorkflowTemplate.detectedParameters(in: graph)
        XCTAssertNotNil(binding(params, .steps))
        XCTAssertEqual(binding(params, .prompt)?.nodeID, "6")
        XCTAssertNil(binding(params, .width))
        XCTAssertNil(binding(params, .model))
    }

    func testAutobindReturnsEmptyWithoutSampler() {
        let graph = Data(#"{"9":{"class_type":"SaveImage","inputs":{"images":["8",0]}}}"#.utf8)
        XCTAssertTrue(ComfyWorkflowTemplate.detectedParameters(in: graph).isEmpty)
    }

    /// The real Z-Image Turbo API graph: the model loader sits behind a ModelSamplingAuraFlow patch,
    /// the negative is a ConditioningZeroOut (no text), and the latent is EmptySD3LatentImage.
    static let zImageTurboGraph = Data(#"""
    {"9":{"inputs":{"filename_prefix":"z-image-turbo","images":["57:8",0]},"class_type":"SaveImage"},
     "57:30":{"inputs":{"clip_name":"qwen_3_4b.safetensors","type":"lumina2","device":"default"},"class_type":"CLIPLoader"},
     "57:29":{"inputs":{"vae_name":"ae.safetensors"},"class_type":"VAELoader"},
     "57:33":{"inputs":{"conditioning":["57:27",0]},"class_type":"ConditioningZeroOut"},
     "57:8":{"inputs":{"samples":["57:3",0],"vae":["57:29",0]},"class_type":"VAEDecode"},
     "57:28":{"inputs":{"unet_name":"z_image_turbo_bf16.safetensors","weight_dtype":"default"},"class_type":"UNETLoader"},
     "57:27":{"inputs":{"text":"a seaside portrait","clip":["57:30",0]},"class_type":"CLIPTextEncode"},
     "57:13":{"inputs":{"width":1024,"height":1024,"batch_size":1},"class_type":"EmptySD3LatentImage"},
     "57:11":{"inputs":{"shift":3,"model":["57:28",0]},"class_type":"ModelSamplingAuraFlow"},
     "57:3":{"inputs":{"seed":0,"steps":8,"cfg":1,"sampler_name":"res_multistep","scheduler":"simple",
             "denoise":1,"model":["57:11",0],"positive":["57:27",0],"negative":["57:33",0],
             "latent_image":["57:13",0]},"class_type":"KSampler"}}
    """#.utf8)

    func testAutobindFollowsModelChainOnZImageTurbo() {
        let params = ComfyWorkflowTemplate.detectedParameters(in: Self.zImageTurboGraph)
        // Model loader is two hops back (sampler → ModelSamplingAuraFlow → UNETLoader).
        XCTAssertEqual(binding(params, .model)?.nodeID, "57:28")
        XCTAssertEqual(binding(params, .model)?.input, "unet_name")
        // Prompt is the direct CLIPTextEncode; the ConditioningZeroOut negative has no text → unbound.
        XCTAssertEqual(binding(params, .prompt)?.nodeID, "57:27")
        XCTAssertNil(binding(params, .negativePrompt))
        // Size + sampler scalars still detected.
        XCTAssertEqual(binding(params, .width)?.nodeID, "57:13")
        XCTAssertEqual(binding(params, .height)?.nodeID, "57:13")
        XCTAssertEqual(binding(params, .seed)?.nodeID, "57:3")
        XCTAssertEqual(binding(params, .sampler)?.input, "sampler_name")
    }

    func testAutoboundZImageTurboCarriesAuthoredDefaults() {
        // Selecting this template should seed a host's controls to the turbo model's real defaults.
        let template = ComfyWorkflowTemplate.autobound(name: "Z-Image Turbo", workflowJSON: Self.zImageTurboGraph)
        XCTAssertEqual(template.defaultInt(.steps), 8)
        XCTAssertEqual(template.defaultDouble(.cfg), 1.0)
        XCTAssertEqual(template.defaultInt(.width), 1024)
        XCTAssertEqual(template.defaultString(.model), "z_image_turbo_bf16.safetensors")
    }

    // MARK: - Text-to-image gate

    func testTextToImageGateAcceptsStandardGraph() {
        XCTAssertNotNil(ComfyWorkflowTemplate.textToImage(name: "Z", workflowJSON: Self.standardGraph))
        XCTAssertTrue(ComfyWorkflowTemplate.autobound(name: "Z", workflowJSON: Self.standardGraph).isTextToImage)
        XCTAssertNotNil(ComfyWorkflowTemplate.textToImage(name: "ZT", workflowJSON: Self.zImageTurboGraph))
    }

    func testTextToImageGateRejectsNonTxt2Img() {
        // A face-swap-style graph: no sampler, prompt, or seed → not text-to-image.
        let graph = Data(#"""
        {"3":{"class_type":"ReActorFaceSwap","inputs":{"swap_model":"inswapper_128.onnx"}},
         "9":{"class_type":"SaveImage","inputs":{"images":["3",0]}}}
        """#.utf8)
        XCTAssertNil(ComfyWorkflowTemplate.textToImage(name: "Face Swap", workflowJSON: graph))
        XCTAssertFalse(ComfyWorkflowTemplate.autobound(name: "Face Swap", workflowJSON: graph).isTextToImage)
    }
}
