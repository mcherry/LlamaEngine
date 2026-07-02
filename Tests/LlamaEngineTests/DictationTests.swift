import XCTest
@testable import LlamaEngine

final class DictationTests: XCTestCase {

    func testComposedAppendsTranscriptToDraft() {
        XCTAssertEqual(DictationController.composed(base: "Hi", transcript: "there"), "Hi there")
    }

    func testComposedUsesTranscriptWhenDraftEmpty() {
        XCTAssertEqual(DictationController.composed(base: "", transcript: "hello world"), "hello world")
        XCTAssertEqual(DictationController.composed(base: "   ", transcript: "hello"), "hello")
    }

    func testComposedTrimsBaseAndKeepsSingleSpace() {
        XCTAssertEqual(DictationController.composed(base: "  Hi  ", transcript: "there"), "Hi there")
    }

    func testComposedKeepsDraftWhenTranscriptEmpty() {
        XCTAssertEqual(DictationController.composed(base: "Hi", transcript: ""), "Hi")
        XCTAssertEqual(DictationController.composed(base: "", transcript: ""), "")
    }
}
