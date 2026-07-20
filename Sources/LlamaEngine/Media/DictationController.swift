import AVFoundation
import Observation
import Speech

/// Drives speech-to-text dictation for the composer: streams microphone audio through
/// `SFSpeechRecognizer` (on-device when supported) and publishes a live `transcript`.
/// `@MainActor` so its observable state updates the UI directly; recognition callbacks
/// hop back to the main actor with only `Sendable` values.
///
/// Submission is the caller's job: the live transcript flows into the draft, and the
/// user sends manually. When `autoSend` is on, a pause in speech bumps `autoSendTick`
/// so the view can submit hands-free.
@MainActor
@Observable
public final class DictationController {
    /// True while the microphone is open and transcribing.
    public private(set) var isListening = false
    /// The best transcription so far for the current dictation session.
    public private(set) var transcript = ""
    /// Set when dictation can't start or fails, for the UI to surface (and clear).
    public var errorMessage: String?
    /// Incremented when a speech pause should auto-submit (only when `autoSend` is on).
    /// The view observes this and sends the draft.
    public private(set) var autoSendTick = 0
    /// True when a previous attempt crashed the app inside the Speech framework (the
    /// most common cause is Dictation being turned off system-wide, which the framework
    /// can't recover from in a sandboxed app). Detected via a persisted "crash guard"
    /// flag; when set, the mic warns instead of trying again and crashing.
    public private(set) var isUnavailable = false

    /// When true, a pause longer than `silenceSeconds` ends dictation and requests a send.
    public var autoSend = false
    /// Silence (no new words) that counts as "done speaking" for auto-send.
    public var silenceSeconds: Double = 1.5
    /// Enable Apple voice processing on the mic (noise suppression + echo cancellation).
    /// It can present a multi-channel input, which is downmixed to mono for the recognizer.
    public var useVoiceProcessing = false

    /// Whether speech recognition is usable at all (a recognizer exists for the locale).
    public var isSupported: Bool { recognizer != nil }

    /// UserDefaults flag set just before the call that can crash, and cleared the instant
    /// recognition responds. If it's still set at launch, the last attempt crashed.
    private static let crashGuardKey = "dictationCrashGuard"

    private let recognizer = SFSpeechRecognizer()
    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var sink: AudioSink?
    private var task: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var starting = false

    public init() {
        // A guard left set from a previous launch means dictation crashed the app last
        // time (Speech service unavailable). Start disabled so we don't crash again.
        isUnavailable = UserDefaults.standard.bool(forKey: Self.crashGuardKey)
    }

    /// Starts dictation if idle, otherwise stops it.
    public func toggle() {
        if isListening || starting { stop() } else { start() }
    }

    /// Requests permission (first run) and begins streaming microphone audio. All work
    /// stays on the main actor — the engine and recognizer are set up from one consistent
    /// queue, which the audio frameworks expect.
    public func start() {
        guard !isListening, !starting else { return }
        if isUnavailable {
            // A prior attempt crashed the app. Re-arm but don't retry on this click, so a
            // persistent problem can't immediately crash again.
            clearCrashGuard()
            isUnavailable = false
            errorMessage = "Speech-to-text hit a problem last time and was paused. Click the mic to try again."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available on this Mac."
            return
        }
        starting = true
        transcript = ""
        errorMessage = nil
        // Check the existing authorization status synchronously and only *request* it
        // when it's genuinely undetermined. Re-requesting speech authorization when it's
        // already decided crashes inside the Speech framework in a sandboxed app.
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            requestMicThenBegin()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { @Sendable [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.starting else { return }
                    guard status == .authorized else {
                        self.starting = false
                        self.errorMessage = "Allow speech recognition in System Settings ▸ Privacy & Security to dictate."
                        return
                    }
                    self.requestMicThenBegin()
                }
            }
        default:
            starting = false
            errorMessage = "Allow speech recognition in System Settings ▸ Privacy & Security to dictate."
        }
    }

    /// Requests microphone access only if it isn't already decided, then begins the session.
    private func requestMicThenBegin() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.starting else { return }
                    guard granted else {
                        self.starting = false
                        self.errorMessage = "Allow microphone access in System Settings ▸ Privacy & Security to dictate."
                        return
                    }
                    self.beginSession()
                }
            }
        default:
            starting = false
            errorMessage = "Allow microphone access in System Settings ▸ Privacy & Security to dictate."
        }
    }

    private func beginSession() {
        guard let recognizer else { starting = false; return }
        // A fresh engine each session avoids stale CoreAudio state from a prior run.
        engine = AVAudioEngine()
        let input = engine.inputNode
        // Voice processing (echo cancellation + noise suppression) must be enabled before
        // the engine starts; it can change the input format, so read the format after.
        if useVoiceProcessing { try? input.setVoiceProcessingEnabled(true) }
        let format = input.outputFormat(forBus: 0)
        // On the first run the HAL may not be ready the instant permission is granted;
        // a zero-channel/zero-rate format would crash `installTap`/`start`.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            starting = false
            errorMessage = "The microphone isn't ready yet. Try the mic again."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep audio on-device when the Mac supports it (privacy + offline).
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        // Voice processing can present a multi-channel input (e.g. 9 ch here), but the
        // recognizer needs mono — downmix in the sink when the input isn't already mono.
        let monoFormat = format.channelCount > 1
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
            : nil
        let sink = AudioSink(request, monoFormat: monoFormat)
        self.sink = sink

        // Arm the crash guard right before recognition starts; cleared the moment it
        // responds. If a future failure ever takes the app down here, the mic disables
        // itself next launch instead of crashing again.
        UserDefaults.standard.set(true, forKey: Self.crashGuardKey)
        UserDefaults.standard.synchronize()

        // Start recognition before wiring the microphone, matching Apple's pattern. The
        // handler is @Sendable (nonisolated): the Speech framework calls it on a
        // background queue, so it must not be main-actor-isolated.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // Extract only Sendable values before hopping to the main actor.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.handle(text: text, isFinal: isFinal, failed: failed)
            }
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            // Runs on the audio thread; the sink guards against appending after the
            // request has been ended (which would crash).
            sink.append(buffer)
        }
        #if os(iOS)
        // iOS requires an active audio session before the engine can tap the microphone.
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default,
                                         options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            clearCrashGuard()
            starting = false
            errorMessage = error.localizedDescription
            teardown()
            return
        }
        #endif
        engine.prepare()
        do {
            try engine.start()
        } catch {
            clearCrashGuard()
            starting = false
            errorMessage = error.localizedDescription
            teardown()
            return
        }

        starting = false
        isListening = true
        if autoSend { restartSilenceTimer() }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        // Recognition responded, so it didn't crash — clear the crash guard.
        clearCrashGuard()
        guard isListening else { return }
        if let text {
            transcript = text
            if autoSend { restartSilenceTimer() }
        }
        if isFinal {
            // The recognizer ended the utterance on its own.
            if autoSend && !transcript.isEmpty {
                autoSendTick &+= 1
            }
            stop()
        } else if failed {
            // The recognition task ended with an error and produced nothing usable.
            if transcript.isEmpty {
                errorMessage = "Speech recognition didn't catch anything. Try the mic again."
            }
            stop()
        }
    }

    /// Restarts the "stopped speaking" countdown; firing it auto-submits.
    private func restartSilenceTimer() {
        silenceTask?.cancel()
        let seconds = max(0.3, silenceSeconds)
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isListening, !self.transcript.isEmpty else { return }
                self.autoSendTick &+= 1
                self.stop()
            }
        }
    }

    /// Stops dictation and releases the microphone. The transcript stays in the draft.
    public func stop() {
        guard isListening || starting else { return }
        silenceTask?.cancel()
        silenceTask = nil
        task?.cancel()
        task = nil
        teardown()
        starting = false
        isListening = false
    }

    /// Tears down the audio engine and recognition request.
    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        sink?.finish()
        sink = nil
        request = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    public func clearError() { errorMessage = nil }

    /// Clears the persisted crash-guard flag (recognition didn't take the app down).
    private func clearCrashGuard() {
        UserDefaults.standard.set(false, forKey: Self.crashGuardKey)
    }

    /// Combines existing draft text with a live transcript: the transcript is appended
    /// after the draft (with a single separating space), so dictation adds to whatever
    /// the user already typed.
    public nonisolated static func composed(base: String, transcript: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBase.isEmpty { return transcript }
        if transcript.isEmpty { return trimmedBase }
        return trimmedBase + " " + transcript
    }
}

/// A thread-safe bridge from the real-time audio tap to the recognition request. The tap
/// runs on the audio I/O thread while teardown happens on the main actor; the lock ensures
/// a buffer is never appended after `finish()` has ended the request (which would crash).
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// Set when the input is multi-channel (e.g. with voice processing on); buffers are
    /// downmixed to this mono format before the recognizer sees them.
    private let monoFormat: AVAudioFormat?

    init(_ request: SFSpeechAudioBufferRecognitionRequest, monoFormat: AVAudioFormat? = nil) {
        self.request = request
        self.monoFormat = monoFormat
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let toAppend = monoFormat.flatMap { Self.mono(buffer, to: $0) } ?? buffer
        lock.lock(); defer { lock.unlock() }
        request?.append(toAppend)
    }

    /// Copies the primary (first) channel into a mono buffer at the same sample rate.
    /// The recognizer rejects multi-channel audio, which voice processing can produce.
    private static func mono(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData, buffer.format.channelCount > 1 else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let dst = out.floatChannelData![0]
        let ch0 = src[0]
        for f in 0..<frames { dst[f] = ch0[f] }
        return out
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        request?.endAudio()
        request = nil
    }
}
