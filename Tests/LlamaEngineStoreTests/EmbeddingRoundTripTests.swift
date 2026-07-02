import XCTest
import LlamaEngine
@testable import LlamaEngineStore

/// Tests for Llamatron-side types that back retrieval but haven't moved into
/// LlamaEngine yet: the SwiftData `DocumentChunk` embedding packing and the
/// `OllamaModel` embedding-model heuristic. (These migrate to the package with the
/// store and backend layers in later phases.)
final class EmbeddingRoundTripTests: XCTestCase {

    func testEmbeddingEncodeDecodeRoundTrip() {
        let original: [Float] = [0.1, -0.5, 3.14159, 0, 42]
        let restored = DocumentChunk.decode(DocumentChunk.encode(original))
        XCTAssertEqual(restored.count, original.count)
        for (a, b) in zip(original, restored) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    func testEmbeddingModelFlag() {
        XCTAssertTrue(OllamaModel(name: "nomic-embed-text", details: nil).isEmbeddingModel)
        XCTAssertFalse(OllamaModel(name: "qwen-14b", details: nil).isEmbeddingModel)
    }
}
