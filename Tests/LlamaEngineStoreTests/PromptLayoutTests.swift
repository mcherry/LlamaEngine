import XCTest
import LlamaEngine
@testable import LlamaEngineStore

/// Where attached-source context lands in the request: stable content up front, so the
/// server's prompt cache covers the history; per-turn context with the new message.
@MainActor
final class PromptLayoutTests: XCTestCase {

    private let history = [
        ChatTurn(role: Role.user.rawValue, content: "earlier question"),
        ChatTurn(role: Role.assistant.rawValue, content: "earlier answer"),
        ChatTurn(role: Role.user.rawValue, content: "new question"),
    ]

    private func session() -> ChatSession {
        let session = ChatSession(modelName: "m")
        session.systemPrompt = "Be brief."
        return session
    }

    func testRetrievedContextTravelsWithTheNewMessage() {
        let turns = ConversationController().buildTurns(for: session(), documents: ("EXCERPTS", .retrieval),
                                                        historyTurns: history)
        XCTAssertEqual(turns.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertEqual(turns[0].content, "Be brief.")
        XCTAssertEqual(turns[1].content, "earlier question")
        XCTAssertTrue(turns[3].content.contains("<reference_material>\nEXCERPTS\n</reference_material>"))
        XCTAssertTrue(turns[3].content.hasSuffix("\n\nnew question"))
    }

    func testInlineDocumentsStayInTheStablePrefix() {
        let turns = ConversationController().buildTurns(for: session(), documents: ("WHOLE DOCUMENT", .inline),
                                                        historyTurns: history)
        XCTAssertEqual(turns.map(\.role), ["system", "system", "user", "assistant", "user"])
        XCTAssertTrue(turns[1].content.contains("WHOLE DOCUMENT"))
        XCTAssertEqual(turns[4].content, "new question")
    }

    func testNativeImagesStillReachTheNewMessage() {
        let turns = ConversationController().buildTurns(for: session(), documents: ("EXCERPTS", .summarize),
                                                        historyTurns: history, nativeImages: ["aGk="])
        XCTAssertEqual(turns.last?.images, ["aGk="])
        XCTAssertTrue(turns.last?.content.contains("EXCERPTS") ?? false)
    }
}
