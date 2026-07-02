import AVFoundation
import Observation

/// Drives text-to-speech playback for the chat: either Apple's on-device synthesizer or a
/// Kokoro server (fetched off-main, then played via `AVAudioPlayer`). `@MainActor` so the
/// observable `speakingMessageID` updates the UI directly; only one message speaks at a time.
@MainActor
@Observable
public final class SpeechController: NSObject {
    /// The id of the message currently being spoken, or `nil` when idle.
    public private(set) var speakingMessageID: UUID?
    /// The id of the message whose audio is being saved, or `nil` when not saving.
    public private(set) var savingMessageID: UUID?
    /// Set when a save fails, for the UI to surface (and clear).
    public var saveError: String?
    /// The id of the message being *narrated* — held hidden until audio starts, then
    /// revealed in step with playback (auto-speak). `nil` for plain "read aloud".
    public private(set) var narratingMessageID: UUID?
    /// Fraction of the narrated message's audio that has played, 0…1. Drives how much
    /// of the reply text is revealed.
    public private(set) var narrationProgress: Double = 0

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var fetchTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    /// UTF-16 length of the text handed to the Apple synthesizer, for mapping spoken
    /// ranges onto narration progress.
    private var narrationTotalChars = 0

    public override init() {
        super.init()
        synth.delegate = self
    }

    /// Resolved engine + voice/speed settings for one speak request.
    public struct Config: Sendable {
        public var engine: TTSEngine
        public var appleVoice: String
        public var serverURL: String
        public var serverVoice: String
        public var speed: Double

        public init(engine: TTSEngine, appleVoice: String, serverURL: String,
                    serverVoice: String, speed: Double) {
            self.engine = engine
            self.appleVoice = appleVoice
            self.serverURL = serverURL
            self.serverVoice = serverVoice
            self.speed = speed
        }
    }

    /// Speaks `text` for `messageID`, or stops if that message is already speaking.
    public func toggle(messageID: UUID, text: String, config: Config) {
        if speakingMessageID == messageID { stop() } else { speak(messageID: messageID, text: text, config: config) }
    }

    /// Starts speaking `text` (stopping anything already playing). When `narrate` is
    /// true the reply is treated as a narration: callers keep its text hidden until
    /// playback starts, then reveal it in step with `narrationProgress`.
    public func speak(messageID: UUID, text: String, config: Config, narrate: Bool = false) {
        stop()
        let spoken = TextForSpeech.plain(text)
        guard !spoken.isEmpty else { return }
        speakingMessageID = messageID
        if narrate {
            narratingMessageID = messageID
            narrationProgress = 0
        }

        switch config.engine {
        case .apple:
            narrationTotalChars = narrate ? (spoken as NSString).length : 0
            let utterance = AVSpeechUtterance(string: spoken)
            if !config.appleVoice.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: config.appleVoice) {
                utterance.voice = voice
            }
            utterance.rate = Self.appleRate(for: config.speed)
            synth.speak(utterance)
        case .server:
            let provider = KokoroTTSProvider(baseURLString: config.serverURL)
            let request = TTSRequest(text: spoken, voice: config.serverVoice, speed: config.speed, format: "wav")
            fetchTask = Task { [weak self] in
                let data = try? await provider.synthesize(request)
                guard let self, self.speakingMessageID == messageID else { return }
                guard let data, let player = try? AVAudioPlayer(data: data) else {
                    self.speakingMessageID = nil
                    self.clearNarration()
                    return
                }
                player.delegate = self
                self.player = player
                player.play()
                if narrate { self.startServerProgress(duration: player.duration) }
            }
        }
    }

    /// Polls the server player's playback position to drive `narrationProgress`.
    private func startServerProgress(duration: TimeInterval) {
        progressTask?.cancel()
        guard duration > 0 else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player, player.isPlaying else { break }
                self.narrationProgress = min(1, player.currentTime / duration)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Clears narration tracking (cancelling the progress poll). Revealing the full
    /// reply text is the caller's job once `narratingMessageID` is `nil`.
    private func clearNarration() {
        progressTask?.cancel()
        progressTask = nil
        narratingMessageID = nil
        narrationProgress = 0
        narrationTotalChars = 0
    }

    /// Renders `text` to a single AAC `.m4a` at `url` (Apple on-device or the Kokoro server).
    public func saveAudio(messageID: UUID, text: String, config: Config, to url: URL) {
        guard savingMessageID == nil else { return }
        let spoken = TextForSpeech.plain(text)
        guard !spoken.isEmpty else { return }
        savingMessageID = messageID
        Task { [weak self] in
            do {
                switch config.engine {
                case .apple:
                    try await AudioExport.writeM4A(appleText: spoken, voice: config.appleVoice,
                                                   speed: config.speed, to: url)
                case .server:
                    let provider = KokoroTTSProvider(baseURLString: config.serverURL)
                    let data = try await provider.synthesize(
                        TTSRequest(text: spoken, voice: config.serverVoice, speed: config.speed, format: "wav"))
                    try await AudioExport.writeM4A(wav: data, to: url)
                }
            } catch {
                self?.saveError = error.localizedDescription
            }
            self?.savingMessageID = nil
        }
    }

    /// Stops any in-progress speech and clears the speaking state.
    public func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
        speakingMessageID = nil
        clearNarration()
    }

    /// Maps a 0.5–2.0 "speed" onto `AVSpeechUtterance.rate` around the platform default.
    public nonisolated static func appleRate(for speed: Double) -> Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        return min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// How many characters of a `total`-length reply to reveal at a given narration
    /// `progress` (0…1), clamped to the valid range.
    public nonisolated static func revealedCount(progress: Double, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let clamped = min(1, max(0, progress))
        return min(total, max(0, Int((clamped * Double(total)).rounded())))
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        // Reveal up to the end of the word about to be spoken.
        let spokenEnd = characterRange.location + characterRange.length
        Task { @MainActor [weak self] in
            guard let self, self.narratingMessageID != nil, self.narrationTotalChars > 0 else { return }
            self.narrationProgress = min(1, Double(spokenEnd) / Double(self.narrationTotalChars))
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speakingMessageID = nil
            self?.clearNarration()
        }
    }
}

extension SpeechController: AVAudioPlayerDelegate {
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.speakingMessageID = nil
            self?.clearNarration()
        }
    }
}
