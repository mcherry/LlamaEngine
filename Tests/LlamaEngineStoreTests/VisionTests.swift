import XCTest
import LlamaEngine
@testable import LlamaEngineStore

final class VisionTests: XCTestCase {

    // MARK: - Capability detection

    func testSupportsVisionFromCapabilities() {
        XCTAssertTrue(OllamaModel(name: "llava", details: nil, capabilities: ["completion", "vision"]).supportsVision)
        XCTAssertFalse(OllamaModel(name: "qwen-14b", details: nil, capabilities: ["completion"]).supportsVision)
        XCTAssertFalse(OllamaModel(name: "x", details: nil, capabilities: nil).supportsVision)
    }

    func testEmbeddingDetectionPrefersCapabilities() {
        // Capabilities win when present.
        XCTAssertTrue(OllamaModel(name: "nomic-embed-text", details: nil, capabilities: ["embedding"]).isEmbeddingModel)
        XCTAssertFalse(OllamaModel(name: "weird-embed-name", details: nil, capabilities: ["completion"]).isEmbeddingModel)
        // Falls back to name heuristic when capabilities are absent.
        XCTAssertTrue(OllamaModel(name: "nomic-embed-text", details: nil, capabilities: nil).isEmbeddingModel)
    }

    func testTagsDecodeCapabilities() throws {
        let json = #"{"models":[{"name":"llava:latest","capabilities":["completion","vision"]}]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let response = try JSONDecoder().decode(TagsResponse.self, from: data)
        XCTAssertEqual(response.models.first?.capabilities, ["completion", "vision"])
        XCTAssertTrue(response.models.first?.supportsVision ?? false)
    }

    // MARK: - ChatTurn image encoding

    private func encodedTurn(_ turn: ChatTurn) throws -> [String: Any] {
        let data = try JSONEncoder().encode(turn)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testChatTurnOmitsImagesWhenEmpty() throws {
        let json = try encodedTurn(ChatTurn(role: "user", content: "hi"))
        XCTAssertNil(json["images"], "images key must be omitted when there are none")
        XCTAssertEqual(json["content"] as? String, "hi")
    }

    func testChatTurnEncodesImages() throws {
        let json = try encodedTurn(ChatTurn(role: "user", content: "look", images: ["BASE64DATA"]))
        XCTAssertEqual(json["images"] as? [String], ["BASE64DATA"])
    }

    func testChatRequestBodyEncodesImagesInMessage() throws {
        let request = ChatRequest(model: "llava",
                                  messages: [ChatTurn(role: "user", content: "what is this?", images: ["IMG"])],
                                  contextSize: 4096)
        let data = try OllamaClient.encodeChatBody(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["images"] as? [String], ["IMG"])
    }

    // MARK: - Attachment image model

    func testImageAttachmentFlags() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic
        let img = Attachment(fileName: "shot.png", imageData: bytes)
        XCTAssertTrue(img.isImage)
        XCTAssertEqual(img.imageBase64, bytes.base64EncodedString())
        XCTAssertTrue(img.fullText.isEmpty)

        let doc = Attachment(fileName: "notes.txt", fullText: "hello")
        XCTAssertFalse(doc.isImage)
        XCTAssertNil(doc.imageBase64)
    }

    func testLoaderIsImageDetection() {
        XCTAssertTrue(AttachmentLoader.isImage(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertTrue(AttachmentLoader.isImage(URL(fileURLWithPath: "/tmp/a.JPEG")))
        XCTAssertFalse(AttachmentLoader.isImage(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(AttachmentLoader.isImage(URL(fileURLWithPath: "/tmp/a.swift")))
    }

    func testSessionVisionModelDefaultEmpty() {
        XCTAssertEqual(ChatSession().visionModel, "")
    }
}
