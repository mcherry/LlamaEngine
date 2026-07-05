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

    // MARK: - Option enums map to the server's expected raw values

    func testOptionRawValues() {
        XCTAssertEqual(ImageSampler.dpmppSDE.rawValue, "dpmpp_sde")
        XCTAssertEqual(ImageSampler.dpmpp2m.rawValue, "dpmpp_2m")
        XCTAssertEqual(ImageSampler.eulerA.rawValue, "euler_a")
        XCTAssertEqual(ImageUpscaler.none.rawValue, "")
        XCTAssertEqual(ImageUpscaler.latent.rawValue, "latent_upscaler")
        XCTAssertEqual(ImageUpscaler.realEsrgan4x.rawValue, "RealESRGAN_x4plus")
        XCTAssertEqual(FaceCorrection.none.rawValue, "")
        XCTAssertEqual(FaceCorrection.gfpgan.rawValue, "GFPGANv1.4")
    }

    // MARK: - ImageGenInfo carries the new parameters and stays back-compatible

    func testImageGenInfoCapturesNewParameters() {
        let request = ImageRequest(prompt: "a cat", negativePrompt: "", model: "realvisxl",
                                   steps: 30, width: 1024, height: 1024, cfgScale: 5, vae: "sdxl-vae",
                                   seed: 7, sampler: "dpmpp_sde", upscaler: "latent_upscaler",
                                   upscaleAmount: 2, latentUpscalerSteps: 12,
                                   faceCorrection: "CodeFormer", clipSkip: true)
        let info = ImageGenInfo(request)
        XCTAssertEqual(info.sampler, "dpmpp_sde")
        XCTAssertEqual(info.upscaler, "latent_upscaler")
        XCTAssertEqual(info.upscaleAmount, 2)
        XCTAssertEqual(info.latentUpscalerSteps, 12)
        XCTAssertEqual(info.faceCorrection, "CodeFormer")
        XCTAssertEqual(info.clipSkip, true)
    }

    func testImageGenInfoRoundTrips() throws {
        let request = ImageRequest(prompt: "p", negativePrompt: "n", model: "m", steps: 20,
                                   width: 512, height: 512, cfgScale: 7, vae: "", seed: nil,
                                   sampler: "dpmpp_2m", upscaler: "RealESRGAN_x4plus", upscaleAmount: 4,
                                   latentUpscalerSteps: 10, faceCorrection: "", clipSkip: false)
        let data = try JSONEncoder().encode(ImageGenInfo(request))
        let decoded = try JSONDecoder().decode(ImageGenInfo.self, from: data)
        XCTAssertEqual(decoded.sampler, "dpmpp_2m")
        XCTAssertEqual(decoded.upscaler, "RealESRGAN_x4plus")
        XCTAssertEqual(decoded.upscaleAmount, 4)
    }

    /// A record saved before these controls existed (no new keys) must still decode,
    /// with the new fields coming back as `nil`.
    func testImageGenInfoDecodesLegacyRecordWithoutNewKeys() throws {
        let legacy = """
        {"prompt":"old","negativePrompt":"","model":"sd-v1-5","width":512,"height":512,
         "steps":25,"cfgScale":7.5,"vae":""}
        """
        let info = try JSONDecoder().decode(ImageGenInfo.self, from: Data(legacy.utf8))
        XCTAssertEqual(info.prompt, "old")
        XCTAssertNil(info.sampler)
        XCTAssertNil(info.upscaler)
        XCTAssertNil(info.clipSkip)
    }
}
