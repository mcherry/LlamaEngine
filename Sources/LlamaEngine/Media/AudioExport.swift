import AVFoundation

/// Encodes speech to a single canonical format — **AAC in an `.m4a`** — so saved audio is
/// consistent regardless of engine and stays small. Both engines render to a temporary PCM
/// file (the Kokoro server's WAV, or the Apple synthesizer's streamed buffers) which the
/// system Apple M4A export preset transcodes. Apple has no MP3 *encoder*, so `.m4a` (AAC) is
/// the small, dependency-free choice.
enum AudioExport {
    enum ExportError: LocalizedError {
        case noAudio
        case encodeFailed
        var errorDescription: String? {
            switch self {
            case .noAudio: return "There was no audio to save."
            case .encodeFailed: return "Couldn't encode the audio."
            }
        }
    }

    /// Transcodes WAV/PCM `data` (from the Kokoro server) to an AAC `.m4a` at `url`.
    static func writeM4A(wav data: Data, to url: URL) async throws {
        guard !data.isEmpty else { throw ExportError.noAudio }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)
        try await exportM4A(from: tmp, to: url)
    }

    /// Renders `text` with the on-device synthesizer and writes an AAC `.m4a` at `url`.
    static func writeM4A(appleText text: String, voice: String, speed: Double, to url: URL) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await renderAppleSpeech(text: text, voice: voice, speed: speed, to: tmp)
        try await exportM4A(from: tmp, to: url)
    }

    /// Transcodes a local PCM audio file to AAC `.m4a` using the system Apple M4A preset —
    /// the robust path (hand-rolled AAC encoding hits format edge cases, e.g. error "!dat").
    private static func exportM4A(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.encodeFailed
        }
        try? FileManager.default.removeItem(at: destination)   // export needs a free path
        try await session.export(to: destination, as: .m4a)
    }

    /// Synthesizes `text` on-device and writes raw PCM to `url` in the synthesizer's own format
    /// (so no conversion is needed); the caller transcodes it to `.m4a`.
    private static func renderAppleSpeech(text: String, voice: String, speed: Double, to url: URL) async throws {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        if !voice.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voice) { utterance.voice = v }
        utterance.rate = SpeechController.appleRate(for: speed)

        let writer = PCMFileWriter(url: url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                writer.handle(pcm, continuation: continuation)
            }
        }
        writer.close()   // finalize/flush the PCM file before it's transcoded
        // Keep the synthesizer alive until the streamed write has finished.
        withExtendedLifetime(synthesizer) {}
    }
}

/// Writes the synthesizer's streamed PCM buffers to one PCM file in the synth's own format
/// (no conversion). Resumes the continuation when the synth signals the end (an empty buffer)
/// or on the first error. The synth invokes its callback serially on one thread, so the
/// unchecked-`Sendable` state is touched from only that thread.
private final class PCMFileWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private var finished = false

    init(url: URL) { self.url = url }

    /// Finalizes the file (flushing it to disk) once the synth has finished.
    func close() { file = nil }

    func handle(_ pcm: AVAudioPCMBuffer, continuation: CheckedContinuation<Void, Error>) {
        guard !finished else { return }
        if pcm.frameLength == 0 {
            finished = true
            if file == nil {
                continuation.resume(throwing: AudioExport.ExportError.noAudio)
            } else {
                continuation.resume()
            }
            return
        }
        do {
            if file == nil {
                // Match the file's processing format to the buffer so no conversion is needed.
                file = try AVAudioFile(forWriting: url,
                                       settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat,
                                       interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            finished = true
            continuation.resume(throwing: error)
        }
    }
}
