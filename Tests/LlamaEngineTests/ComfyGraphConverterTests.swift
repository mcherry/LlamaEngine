import XCTest
@testable import LlamaEngine

/// Hermetic tests for UI-graph → API-format conversion, including the seed control_after_generate
/// offset, trailing UI-only widgets, dropped nodes, and subgraph/unknown-node rejection.
final class ComfyGraphConverterTests: XCTestCase {

    /// A schema for the node types used below, with `input_order` (widget mapping depends on it).
    static func schema() -> ComfyObjectInfo {
        ComfyObjectInfo.parse(Data(#"""
        {"CheckpointLoaderSimple":{"input":{"required":{"ckpt_name":[["model.safetensors"]]}},
          "input_order":{"required":["ckpt_name"]}},
         "CLIPTextEncode":{"input":{"required":{"text":["STRING",{}],"clip":["CLIP"]}},
          "input_order":{"required":["text","clip"]}},
         "EmptyLatentImage":{"input":{"required":{"width":["INT",{}],"height":["INT",{}],"batch_size":["INT",{}]}},
          "input_order":{"required":["width","height","batch_size"]}},
         "KSampler":{"input":{"required":{"seed":["INT",{}],"steps":["INT",{}],"cfg":["FLOAT",{}],
            "sampler_name":[["euler","dpmpp_2m"]],"scheduler":[["normal","karras"]],"denoise":["FLOAT",{}],
            "model":["MODEL"],"positive":["CONDITIONING"],"negative":["CONDITIONING"],"latent_image":["LATENT"]}},
          "input_order":{"required":["seed","steps","cfg","sampler_name","scheduler","denoise","model","positive","negative","latent_image"]}},
         "VAEDecode":{"input":{"required":{"samples":["LATENT"],"vae":["VAE"]}},
          "input_order":{"required":["samples","vae"]}},
         "SaveImage":{"input":{"required":{"images":["IMAGE"],"filename_prefix":["STRING",{}]}},
          "input_order":{"required":["images","filename_prefix"]}},
         "LoadImage":{"input":{"required":{"image":[["a.png"]]}},"input_order":{"required":["image"]}}}
        """#.utf8))
    }

    /// A flat txt2img graph including a Note (dropped), a muted KSampler (dropped), and a KSampler
    /// whose widgets_values carries the "randomize" control value after the seed.
    static let flatGraph = Data(#"""
    {"nodes":[
      {"id":4,"type":"CheckpointLoaderSimple","mode":0,"inputs":[],"widgets_values":["model.safetensors"]},
      {"id":6,"type":"CLIPTextEncode","mode":0,"inputs":[{"name":"clip","link":10}],"widgets_values":["a cat"]},
      {"id":7,"type":"CLIPTextEncode","mode":0,"inputs":[{"name":"clip","link":11}],"widgets_values":["blurry"]},
      {"id":5,"type":"EmptyLatentImage","mode":0,"inputs":[],"widgets_values":[512,768,1]},
      {"id":3,"type":"KSampler","mode":0,
       "inputs":[{"name":"model","link":12},{"name":"positive","link":13},{"name":"negative","link":14},{"name":"latent_image","link":15}],
       "widgets_values":[42,"randomize",20,7.5,"euler","normal",1.0]},
      {"id":8,"type":"VAEDecode","mode":0,"inputs":[{"name":"samples","link":16},{"name":"vae","link":17}],"widgets_values":[]},
      {"id":9,"type":"SaveImage","mode":0,"inputs":[{"name":"images","link":18}],"widgets_values":["out"]},
      {"id":99,"type":"Note","mode":0,"inputs":[],"widgets_values":["ignore me"]},
      {"id":88,"type":"KSampler","mode":2,"inputs":[],"widgets_values":[1,"fixed",1,1,"euler","normal",1]}
    ],
    "links":[
      [10,4,1,6,0,"CLIP"],[11,4,1,7,0,"CLIP"],[12,4,0,3,0,"MODEL"],[13,6,0,3,1,"CONDITIONING"],
      [14,7,0,3,2,"CONDITIONING"],[15,5,0,3,3,"LATENT"],[16,3,0,8,0,"LATENT"],[17,4,2,8,1,"VAE"],[18,8,0,9,0,"IMAGE"]
    ]}
    """#.utf8)

    private func node(_ api: [String: Any], _ id: String) throws -> [String: Any] {
        try XCTUnwrap((api[id] as? [String: Any])?["inputs"] as? [String: Any])
    }

    func testConvertsFlatGraphResolvingLinksAndWidgets() throws {
        let data = try ComfyGraphConverter.toAPIFormat(Self.flatGraph, objectInfo: Self.schema())
        let api = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // KSampler: the "randomize" control value must be skipped so steps/cfg land correctly.
        let k = try node(api, "3")
        XCTAssertEqual(k["seed"] as? Int, 42)
        XCTAssertEqual(k["steps"] as? Int, 20)
        XCTAssertEqual(k["cfg"] as? Double, 7.5)
        XCTAssertEqual(k["sampler_name"] as? String, "euler")
        XCTAssertEqual(k["scheduler"] as? String, "normal")
        XCTAssertEqual(k["denoise"] as? Double, 1.0)
        XCTAssertEqual((k["model"] as? [Any])?.first as? String, "4")
        XCTAssertEqual((k["positive"] as? [Any])?.first as? String, "6")
        XCTAssertEqual((k["latent_image"] as? [Any])?.first as? String, "5")

        XCTAssertEqual(try node(api, "6")["text"] as? String, "a cat")
        XCTAssertEqual((try node(api, "6")["clip"] as? [Any])?.first as? String, "4")
        let latent = try node(api, "5")
        XCTAssertEqual(latent["width"] as? Int, 512)
        XCTAssertEqual(latent["height"] as? Int, 768)
        XCTAssertEqual(latent["batch_size"] as? Int, 1)
        XCTAssertEqual(try node(api, "9")["filename_prefix"] as? String, "out")

        // Note (UI-only) and the muted KSampler are dropped.
        XCTAssertNil(api["99"])
        XCTAssertNil(api["88"])
        XCTAssertEqual(api.count, 7)
    }

    func testIgnoresTrailingUIOnlyWidget() throws {
        // LoadImage's second widgets_values entry ("image", the upload button) has no declared
        // input in object_info, so it must be ignored.
        let graph = Data(#"""
        {"nodes":[{"id":1,"type":"LoadImage","mode":0,"inputs":[],"widgets_values":["photo.png","image"]}],"links":[]}
        """#.utf8)
        let data = try ComfyGraphConverter.toAPIFormat(graph, objectInfo: Self.schema())
        let api = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inputs = try node(api, "1")
        XCTAssertEqual(inputs["image"] as? String, "photo.png")
        XCTAssertNil(inputs["upload"])
        XCTAssertEqual(inputs.count, 1)
    }

    func testThrowsForSubgraphOrUnknownNode() {
        let graph = Data(#"""
        {"nodes":[{"id":57,"type":"f2fdebf6-dfaf-43b6-9eb2-7f70613cfdc1","mode":0,"inputs":[],"widgets_values":[]}],"links":[]}
        """#.utf8)
        XCTAssertThrowsError(try ComfyGraphConverter.toAPIFormat(graph, objectInfo: Self.schema())) { error in
            guard case ComfyGraphConverter.ConvertError.unsupportedNodes(let types) = error else {
                return XCTFail("expected unsupportedNodes, got \(error)")
            }
            XCTAssertEqual(types, ["f2fdebf6-dfaf-43b6-9eb2-7f70613cfdc1"])
        }
    }

    func testThrowsForNonGraphPayload() {
        // An API-format node dictionary has no "nodes" array.
        let apiFormat = Data(#"{"3":{"class_type":"KSampler","inputs":{"seed":1}}}"#.utf8)
        XCTAssertThrowsError(try ComfyGraphConverter.toAPIFormat(apiFormat, objectInfo: Self.schema())) { error in
            XCTAssertEqual(error as? ComfyGraphConverter.ConvertError, .notGraphFormat)
        }
    }

    func testConvertedFlatGraphAutobinds() throws {
        // End-to-end: convert → auto-bind should detect the standard txt2img parameters.
        let data = try ComfyGraphConverter.toAPIFormat(Self.flatGraph, objectInfo: Self.schema())
        let params = ComfyWorkflowTemplate.detectedParameters(in: data)
        let keys = Set(params.map(\.key))
        XCTAssertTrue(keys.isSuperset(of: [.prompt, .negativePrompt, .model, .seed, .steps, .cfg, .width, .height]))
    }
}
