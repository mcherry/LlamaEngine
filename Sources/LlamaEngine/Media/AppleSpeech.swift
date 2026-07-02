import AVFoundation

/// On-device text-to-speech via `AVSpeechSynthesizer`. This exposes the installed system
/// voices for the Settings picker; actual playback is driven by `SpeechController`.
public enum AppleSpeech {
    /// All installed system voices, as `TTSVoice`s (`id` = the voice identifier), sorted
    /// by language then name so related voices group together in the picker.
    public static func voices() -> [TTSVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { TTSVoice(id: $0.identifier, name: "\($0.name) (\($0.language))") }
    }
}
