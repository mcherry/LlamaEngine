import XCTest
@testable import LlamaEngine

final class SessionExporterTests: XCTestCase {

    private func sampleSession() -> SessionExporter.Session {
        SessionExporter.Session(
            title: "Test Chat",
            backend: "Ollama",
            model: "qwen-14b",
            contextSize: 32768,
            systemPrompt: "You are helpful.",
            createdAt: Date(timeIntervalSince1970: 0),
            turns: [
                SessionExporter.Turn(role: "user", content: "Hello", thinking: "",
                                     createdAt: Date(timeIntervalSince1970: 1),
                                     promptTokens: nil, evalTokens: nil,
                                     generationSeconds: nil, firstTokenSeconds: nil),
                SessionExporter.Turn(role: "assistant", content: "Hi there!", thinking: "pondering",
                                     createdAt: Date(timeIntervalSince1970: 2),
                                     promptTokens: 10, evalTokens: 5,
                                     generationSeconds: 1.5, firstTokenSeconds: 0.3)
            ]
        )
    }

    func testMarkdownIncludesTitleAndTurns() {
        let md = SessionExporter.markdown(sampleSession())
        XCTAssertTrue(md.contains("# Test Chat"))
        XCTAssertTrue(md.contains("**Model:** qwen-14b"))
        XCTAssertTrue(md.contains("## System Prompt"))
        XCTAssertTrue(md.contains("Hello"))
        XCTAssertTrue(md.contains("Hi there!"))
        XCTAssertTrue(md.contains("10 prompt tokens"))
    }

    func testMarkdownWrapsReasoningInDetails() {
        let md = SessionExporter.markdown(sampleSession())
        XCTAssertTrue(md.contains("<details><summary>Reasoning</summary>"))
        XCTAssertTrue(md.contains("pondering"))
    }

    func testMarkdownOmitsEmptySystemPrompt() {
        var session = sampleSession()
        session.systemPrompt = "   "
        let md = SessionExporter.markdown(session)
        XCTAssertFalse(md.contains("## System Prompt"))
    }

    func testJSONIsValidAndRoundTrips() throws {
        let json = SessionExporter.json(sampleSession())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Test Chat")
        XCTAssertEqual(object["model"] as? String, "qwen-14b")
        XCTAssertEqual(object["contextSize"] as? Int, 32768)
        let turns = try XCTUnwrap(object["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1]["evalTokens"] as? Int, 5)
        XCTAssertEqual(turns[1]["thinking"] as? String, "pondering")
    }

    func testJSONOmitsNilStats() throws {
        let json = SessionExporter.json(sampleSession())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let turns = try XCTUnwrap(object["turns"] as? [[String: Any]])
        // The user turn has no token stats.
        XCTAssertNil(turns[0]["promptTokens"])
        XCTAssertNil(turns[0]["thinking"])
    }
}
