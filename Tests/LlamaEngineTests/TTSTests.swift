import XCTest
import AVFoundation
@testable import LlamaEngine

final class TTSTests: XCTestCase {

    func testIsConfiguredRequiresEnabledAndURL() {
        XCTAssertFalse(TTS.isConfigured(enabled: false, serverURL: "http://localhost:8880"))
        XCTAssertFalse(TTS.isConfigured(enabled: true, serverURL: ""))
        XCTAssertFalse(TTS.isConfigured(enabled: true, serverURL: "   "))
        XCTAssertTrue(TTS.isConfigured(enabled: true, serverURL: "http://localhost:8880"))
    }

    func testDecodeVoicesObjectShape() {
        let json = #"{"voices":[{"id":"af_heart","name":"Heart"},{"id":"am_adam"}]}"#
        let voices = KokoroTTSProvider.decodeVoices(Data(json.utf8))
        XCTAssertEqual(voices.map(\.id), ["af_heart", "am_adam"])
        XCTAssertEqual(voices.first?.name, "Heart")
        XCTAssertEqual(voices.last?.name, "am_adam")   // name falls back to the id
    }

    func testDecodeVoicesStringShape() {
        let voices = KokoroTTSProvider.decodeVoices(Data(#"{"voices":["af_heart","af_bella"]}"#.utf8))
        XCTAssertEqual(voices.map(\.id), ["af_heart", "af_bella"])
        XCTAssertEqual(voices.first?.name, "af_heart")
    }

    func testDecodeVoicesTolerantOfGarbage() {
        XCTAssertTrue(KokoroTTSProvider.decodeVoices(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(KokoroTTSProvider.decodeVoices(Data("{}".utf8)).isEmpty)
    }

    func testTTSEngineRoundTrip() {
        XCTAssertEqual(TTSEngine(rawValue: "apple"), .apple)
        XCTAssertEqual(TTSEngine(rawValue: "server"), .server)
        XCTAssertEqual(TTSEngine.allCases.count, 2)
    }

    func testTextForSpeechStripsMarkdown() {
        let md = "# Title\n\nHere is `code` and **bold** and a [link](http://x).\n\n```\ncode block\n```\n- item"
        let plain = TextForSpeech.plain(md)
        XCTAssertFalse(plain.contains("#"))
        XCTAssertFalse(plain.contains("`"))
        XCTAssertFalse(plain.contains("*"))
        XCTAssertFalse(plain.contains("code block"))   // fenced block removed
        XCTAssertFalse(plain.contains("http://x"))      // url dropped
        XCTAssertTrue(plain.contains("Title"))
        XCTAssertTrue(plain.contains("link"))           // link text kept
        XCTAssertTrue(plain.contains("item"))
    }

    func testAppleRateClampsAroundDefault() {
        XCTAssertEqual(SpeechController.appleRate(for: 1.0), AVSpeechUtteranceDefaultSpeechRate, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(SpeechController.appleRate(for: 5.0), AVSpeechUtteranceMaximumSpeechRate)
        XCTAssertGreaterThanOrEqual(SpeechController.appleRate(for: 0.01), AVSpeechUtteranceMinimumSpeechRate)
    }

    func testRevealedCountMapsProgressToCharacters() {
        XCTAssertEqual(SpeechController.revealedCount(progress: 0, total: 100), 0)
        XCTAssertEqual(SpeechController.revealedCount(progress: 0.5, total: 100), 50)
        XCTAssertEqual(SpeechController.revealedCount(progress: 1, total: 100), 100)
    }

    func testRevealedCountClampsOutOfRange() {
        XCTAssertEqual(SpeechController.revealedCount(progress: -0.2, total: 100), 0)
        XCTAssertEqual(SpeechController.revealedCount(progress: 1.5, total: 100), 100)
        XCTAssertEqual(SpeechController.revealedCount(progress: 0.5, total: 0), 0)
    }
}
