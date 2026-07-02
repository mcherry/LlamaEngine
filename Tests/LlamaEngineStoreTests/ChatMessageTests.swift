import XCTest
import LlamaEngine
@testable import LlamaEngineStore

final class ChatMessageTests: XCTestCase {

    // MARK: - generationDurationLabel

    func testDurationNilWhenUnset() {
        let message = ChatMessage(role: .assistant, content: "hi")
        XCTAssertNil(message.generationDurationLabel)
    }

    func testDurationNilWhenZeroOrNegative() {
        let message = ChatMessage(role: .assistant, content: "hi")
        message.generationSeconds = 0
        XCTAssertNil(message.generationDurationLabel)
    }

    func testDurationSubSecondShowsOneDecimal() {
        let message = ChatMessage(role: .assistant, content: "hi")
        message.generationSeconds = 0.83
        XCTAssertEqual(message.generationDurationLabel, "0.8s")
    }

    func testDurationWholeSeconds() {
        let message = ChatMessage(role: .assistant, content: "hi")
        message.generationSeconds = 30.4
        XCTAssertEqual(message.generationDurationLabel, "30s")
    }

    func testDurationRoundsToNearestSecond() {
        let message = ChatMessage(role: .assistant, content: "hi")
        message.generationSeconds = 5.6
        XCTAssertEqual(message.generationDurationLabel, "6s")
    }

    func testDurationMinutesAndSeconds() {
        let message = ChatMessage(role: .assistant, content: "hi")
        message.generationSeconds = 95
        XCTAssertEqual(message.generationDurationLabel, "1m 35s")
    }

    func testDurationExactMinute() {
        let message = ChatMessage(role: .assistant, content: "hi")
        message.generationSeconds = 60
        XCTAssertEqual(message.generationDurationLabel, "1m 0s")
    }
}
