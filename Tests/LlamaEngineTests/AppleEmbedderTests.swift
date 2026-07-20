import XCTest
import NaturalLanguage
@testable import LlamaEngine

final class AppleEmbedderTests: XCTestCase {

    // MARK: - Task-prefix stripping (pure)

    func testStripsSearchDocumentPrefix() {
        XCTAssertEqual(AppleEmbedder.stripTaskPrefix("search_document: hello world"), "hello world")
    }

    func testStripsSearchQueryPrefix() {
        XCTAssertEqual(AppleEmbedder.stripTaskPrefix("search_query: what is swift"), "what is swift")
    }

    func testLeavesUnprefixedTextUnchanged() {
        XCTAssertEqual(AppleEmbedder.stripTaskPrefix("just some text"), "just some text")
    }

    // MARK: - Embedding

    func testEmptyInputReturnsEmpty() async throws {
        let vectors = try await AppleEmbedder().embed(model: "", input: [])
        XCTAssertTrue(vectors.isEmpty)
    }

    func testEmbedsToStableDimension() async throws {
        try XCTSkipIf(NLEmbedding.sentenceEmbedding(for: .english) == nil,
                      "Sentence embedding model unavailable on this host.")
        let vectors = try await AppleEmbedder().embed(model: "",
                                                      input: ["the cat sat on the mat", "hello there"])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertGreaterThan(vectors[0].count, 0)
        XCTAssertEqual(vectors[0].count, vectors[1].count, "All vectors share one dimension.")
    }

    func testRelatedTextScoresHigherThanUnrelated() async throws {
        try XCTSkipIf(NLEmbedding.sentenceEmbedding(for: .english) == nil,
                      "Sentence embedding model unavailable on this host.")
        let vectors = try await AppleEmbedder().embed(model: "", input: [
            "search_query: a dog barked loudly",
            "search_document: the puppy made a loud barking noise",
            "search_document: quarterly financial spreadsheet totals"
        ])
        let related = Vector.cosineSimilarity(vectors[0], vectors[1])
        let unrelated = Vector.cosineSimilarity(vectors[0], vectors[2])
        XCTAssertGreaterThan(related, unrelated, "Semantically related text should score higher.")
    }
}
