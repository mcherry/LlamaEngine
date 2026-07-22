import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Chat backend powered by Apple's on-device Foundation Models. Conforms to
/// `ChatStreaming` so it drops into the same view-model flow as `OllamaClient`.
///
/// The struct stores nothing framework-typed, so it compiles on the macOS 15
/// deployment target; every Foundation Models call is guarded by
/// `#if canImport(FoundationModels)` and `if #available(macOS 26, *)`. If the model
/// isn't available at call time, the stream finishes with a descriptive error.
public struct FoundationModelsBackend: ChatStreaming {
    /// Per-session Apple generation controls. A plain `Sendable` value (no
    /// FoundationModels types), so the struct compiles on the macOS 15 target.
    public var options: AppleGenerationOptions

    public init(options: AppleGenerationOptions = AppleGenerationOptions()) {
        self.options = options
    }

    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [options] in
                #if canImport(FoundationModels)
                if #available(macOS 26, iOS 26, *) {
                    await Self.stream(request, options: options, into: continuation)
                } else {
                    continuation.finish(throwing: AppleIntelligenceError.unsupportedOS)
                }
                #else
                continuation.finish(throwing: AppleIntelligenceError.unsupportedOS)
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    private static func stream(_ request: ChatRequest,
                               options: AppleGenerationOptions,
                               into continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation) async {
        guard case .available = SystemLanguageModel.default.availability else {
            continuation.finish(throwing: AppleIntelligenceError.unavailable(AppleIntelligence.statusMessage))
            return
        }

        let (instructions, prompt) = render(request.messages)
        let session = LanguageModelSession(instructions: instructions)
        let generationOptions = makeOptions(options)

        do {
            // Apple yields cumulative snapshots: each `snapshot.content` is the whole
            // reply so far. We forward it as a replacement chunk, so the message body
            // is set (not appended) — matching the snapshot semantics exactly.
            var latest = ""
            for try await snapshot in session.streamResponse(to: prompt, options: generationOptions) {
                try Task.checkCancellation()
                latest = snapshot.content
                continuation.yield(ChatChunk(contentDelta: latest, done: false, isReplacement: true))
            }
            continuation.yield(ChatChunk(contentDelta: latest, done: true, isReplacement: true))
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Maps our plain options onto Apple's `GenerationOptions`, choosing a sampling
    /// strategy. A seed is honored only by the random modes, for reproducibility.
    /// Internal so the tool-calling session (`AppleToolSession`) can reuse it.
    @available(macOS 26, iOS 26, *)
    static func makeOptions(_ o: AppleGenerationOptions) -> GenerationOptions {
        let sampling: GenerationOptions.SamplingMode?
        switch o.samplingMode {
        case .automatic:
            sampling = nil
        case .greedy:
            sampling = .greedy
        case .topK:
            sampling = .random(top: o.topK ?? 50, seed: seedValue(o.seed))
        case .topP:
            sampling = .random(probabilityThreshold: o.topP ?? 0.9, seed: seedValue(o.seed))
        }
        return GenerationOptions(sampling: sampling,
                                 temperature: o.temperature,
                                 maximumResponseTokens: o.maximumResponseTokens)
    }

    /// Apple wants a `UInt64?` seed; our session stores `Int?`. Drop negatives.
    private static func seedValue(_ seed: Int?) -> UInt64? {
        guard let seed, seed >= 0 else { return nil }
        return UInt64(seed)
    }
    #endif

    /// Splits the turn list into on-device `instructions` (the system prompt) and a
    /// single `prompt`. A fresh session is created per send, so prior turns are folded
    /// into the prompt as a labeled dialogue for the model to continue.
    public static func render(_ turns: [ChatTurn]) -> (instructions: String, prompt: String) {
        let system = turns
            .filter { $0.role == Role.system.rawValue }
            .map(\.content)
            .joined(separator: "\n\n")

        let conversation = turns.filter { $0.role != Role.system.rawValue }
        let prompt: String
        if conversation.count <= 1 {
            prompt = conversation.last?.content ?? ""
        } else {
            prompt = conversation.map { turn in
                let speaker = turn.role == Role.assistant.rawValue ? "Assistant" : "User"
                return "\(speaker): \(turn.content)"
            }.joined(separator: "\n\n")
        }

        let instructions = system.isEmpty
            ? "You are a helpful assistant. Answer the user's most recent message."
            : system
        return (instructions, prompt)
    }
}
