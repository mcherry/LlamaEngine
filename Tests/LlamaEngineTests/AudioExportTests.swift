import XCTest
import AVFoundation
@testable import LlamaEngine

final class AudioExportTests: XCTestCase {

    /// Empty/invalid audio data fails cleanly rather than producing a bogus file.
    /// (The full encode path — Apple synth and Kokoro WAV → AAC `.m4a` via the system Apple
    /// M4A export — can't run in the headless test host, which lacks the media encoder XPC
    /// services; it's verified at runtime.)
    func testEmptyWavThrows() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await AudioExport.writeM4A(wav: Data(), to: url)
            XCTFail("Expected an error for empty audio data.")
        } catch {
            // Expected.
        }
    }
}
