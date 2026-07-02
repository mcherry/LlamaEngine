import XCTest
@testable import LlamaEngine

final class ImageGenTests: XCTestCase {

    // MARK: - ImageGen.isConfigured

    func testIsConfiguredRequiresEnabledAndURL() {
        XCTAssertFalse(ImageGen.isConfigured(enabled: false, serverURL: "http://localhost:9000"))
        XCTAssertFalse(ImageGen.isConfigured(enabled: true, serverURL: ""))
        XCTAssertFalse(ImageGen.isConfigured(enabled: true, serverURL: "   "))
        XCTAssertTrue(ImageGen.isConfigured(enabled: true, serverURL: "http://localhost:9000"))
    }

    // MARK: - ImageDimensions.parse

    func testParseDimensions() {
        XCTAssertEqual(ImageDimensions.parse("768x512")?.width, 768)
        XCTAssertEqual(ImageDimensions.parse("768x512")?.height, 512)
        XCTAssertEqual(ImageDimensions.parse(" 640 X 640 ")?.width, 640)
        XCTAssertNil(ImageDimensions.parse("768"))
        XCTAssertNil(ImageDimensions.parse("0x512"))
        XCTAssertNil(ImageDimensions.parse("axb"))
    }

    // MARK: - decodeModels (tag filter, name fallback, tolerant)

    func testDecodeModelsFiltersByTag() {
        let json = """
        {"models":[
          {"model":"sd-v1-5","name":"Stable Diffusion 1.5","tags":["stable-diffusion"]},
          {"model":"vae-ft-mse","name":"VAE","tags":["vae"]},
          {"model":"sdxl","tags":["stable-diffusion"]}
        ]}
        """
        let models = EasyDiffusionProvider.decodeModels(Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["sd-v1-5", "sdxl"])
        XCTAssertEqual(models.first?.name, "Stable Diffusion 1.5")
        XCTAssertEqual(models.last?.name, "sdxl")   // name falls back to the model id
        XCTAssertEqual(EasyDiffusionProvider.decodeModels(Data(json.utf8), tag: "vae").map(\.id), ["vae-ft-mse"])
    }

    func testDecodeModelsTolerantOfGarbage() {
        XCTAssertTrue(EasyDiffusionProvider.decodeModels(Data("not json".utf8)).isEmpty)
    }

    // MARK: - jsonObjects / decodeDataURI / parseStream

    func testJSONObjectsSplitsConcatenatedObjects() {
        XCTAssertEqual(EasyDiffusionProvider.jsonObjects(in: #"{"step":1,"total_steps":10}{"step":2}"#).count, 2)
    }

    func testJSONObjectsIgnoresBracesInStrings() {
        XCTAssertEqual(EasyDiffusionProvider.jsonObjects(in: #"{"detail":"a } brace"}{"x":1}"#).count, 2)
    }

    func testDecodeDataURI() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(EasyDiffusionProvider.decodeDataURI("data:image/png;base64," + png.base64EncodedString()), png)
        XCTAssertEqual(EasyDiffusionProvider.decodeDataURI(png.base64EncodedString()), png)   // bare base64
    }

    func testParseStreamImage() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        let uri = "data:image/png;base64," + png.base64EncodedString()
        let text = "{\"step\":9,\"total_steps\":10}" + "{\"output\":[{\"data\":\"\(uri)\",\"seed\":42}]}"
        guard case .image(let data) = EasyDiffusionProvider.parseStream(text) else {
            return XCTFail("expected .image")
        }
        XCTAssertEqual(data, png)
    }

    func testParseStreamFailed() {
        XCTAssertEqual(EasyDiffusionProvider.parseStream(#"{"status":"failed","detail":"out of memory"}"#),
                       .failed("out of memory"))
    }

    func testParseStreamPending() {
        XCTAssertEqual(EasyDiffusionProvider.parseStream(#"{"step":3,"total_steps":10}"#), .pending)
    }
}
