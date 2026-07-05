import Foundation
import LlamaEngine
import SwiftData

/// Owns the send/stream/persist flow for one chat session. `@MainActor` so it only
/// ever touches SwiftData `@Model` objects on the main actor; the networking layer
/// hands back plain `Sendable` `ChatChunk` values across the boundary.
@MainActor
@Observable
public final class ConversationController {
    public var isStreaming = false
    public var errorMessage: String?
    /// Set after context assembly so the UI can show which strategy was used.
    public var contextInfo: ContextInfo?
    /// Transient status shown while a pre-step runs (e.g. "Looking at image…").
    public var activityStatus: String?

    private var streamTask: Task<Void, Never>?

    /// Learns per-model token-estimate correction factors from real `prompt_eval_count`
    /// values, so budgeting reflects how each model actually tokenizes.
    private let tokenCalibrator = TokenCalibrator()

    /// The highest `num_ctx` used so far per session. Right-sizing never drops below
    /// this within a session, so the request window doesn't shrink between turns and
    /// needlessly invalidate the server's prompt (KV) cache.
    private var contextFloors: [UUID: Int] = [:]

    public init() {}

    /// Inserts the user turn, opens an empty assistant turn, assembles any attached
    /// document context, then streams deltas into the assistant turn. Assembly and
    /// streaming both run in the same cancellable task.
    public func send(text: String,
              session: ChatSession,
              client: OllamaClient?,
              embeddingModel: String,
              diagramGuidance: Bool = false,
              rightSizeContext: Bool = true,
              keepAliveMinutes: Int = 5,
              imageServerURL: String = "",
              imageBackendKind: String = ImageBackendKind.easyDiffusion.rawValue,
              imageWorkflowTemplate: ComfyWorkflowTemplate? = nil,
              modelContext: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session.isConfigured else { return }

        // Image-generation backend doesn't stream text — render the prompt to an image.
        if session.backend == .imageGeneration {
            generateImage(text: trimmed,
                          session: session,
                          serverURL: imageServerURL,
                          backendKindRaw: imageBackendKind,
                          template: imageWorkflowTemplate,
                          modelContext: modelContext)
            return
        }

        // Resolve the chat backend up front. Ollama needs a reachable server; Apple
        // Intelligence runs entirely on-device and needs no client.
        let backend: ChatStreaming
        switch session.backend {
        case .ollama:
            guard let client else {
                errorMessage = "Invalid server URL. Check Settings."
                return
            }
            backend = client
        case .appleIntelligence:
            backend = FoundationModelsBackend(options: session.appleOptions)
        case .imageGeneration:
            return   // handled above
        }

        errorMessage = nil
        contextInfo = nil

        let userMessage = ChatMessage(role: .user, content: trimmed)
        userMessage.session = session
        modelContext.insert(userMessage)

        let assistant = ChatMessage(role: .assistant, content: "")
        assistant.session = session
        modelContext.insert(assistant)

        session.updatedAt = .now

        isStreaming = true
        streamTask = Task { [weak self] in
            guard let self else { return }

            // Assemble document context (may embed/summarize) before the request.
            let contextBlock = await self.assembleContext(query: trimmed,
                                                          session: session,
                                                          into: assistant,
                                                          client: client,
                                                          embeddingModel: embeddingModel)

            if Task.isCancelled {
                if assistant.content.isEmpty { modelContext.delete(assistant) }
                self.isStreaming = false
                return
            }

            // Vision pre-step: if the session has image attachments, either describe
            // them with a vision model (preprocessor pipeline) or pass them natively to
            // the primary model.
            let vision = await self.assembleVision(query: trimmed,
                                                   session: session,
                                                   into: assistant,
                                                   client: client)

            if Task.isCancelled {
                if assistant.content.isEmpty { modelContext.delete(assistant) }
                self.isStreaming = false
                return
            }

            let historyTurns = await self.assembleHistory(session: session,
                                                          newUserText: trimmed,
                                                          contextBlock: contextBlock,
                                                          into: assistant,
                                                          client: client,
                                                          embeddingModel: embeddingModel)
            let turns = self.buildTurns(for: session,
                                        contextBlock: contextBlock,
                                        historyTurns: historyTurns,
                                        imageDescription: vision.description,
                                        nativeImages: vision.nativeImages,
                                        diagramGuidance: diagramGuidance)

            // Size the request window: cap the user's choice to the model's real limit,
            // then — when right-sizing is on — shrink to the smallest preset that still
            // holds this prompt plus a reply, so small chats don't allocate a huge KV
            // cache. The reply reserve keeps room so the answer isn't cut off. The
            // prompt estimate is scaled by the model's learned tokenization factor so a
            // dense prompt isn't under-sized.
            let ceiling = self.contextCeiling(for: session)
            let scale = self.tokenCalibrator.scale(for: session.modelName)
            let rawPromptTokens = TokenEstimator.estimate(turns.map(\.content))
            let scaledPromptTokens = Int((Double(rawPromptTokens) * scale).rounded(.up))
            let reserve = ContextBudget(contextSize: ceiling, systemTokens: 0,
                                        historyTokens: 0, userTokens: 0).responseReserve
            let effectiveCtx = rightSizeContext
                ? ContextSize.rightSized(needed: scaledPromptTokens + reserve, ceiling: ceiling)
                : ceiling
            // Never shrink num_ctx within a session (monotonic, clamped to the ceiling)
            // so the server's prompt cache isn't invalidated by a smaller window.
            let stableCtx: Int
            if rightSizeContext {
                stableCtx = min(ceiling, max(effectiveCtx, self.contextFloors[session.id] ?? 0))
                self.contextFloors[session.id] = stableCtx
            } else {
                stableCtx = effectiveCtx
            }
            // keep_alive: negative keeps the model resident indefinitely; positive is a
            // minute window; zero omits the field (server default).
            let keepAlive: String? = keepAliveMinutes < 0 ? "-1"
                : (keepAliveMinutes > 0 ? "\(keepAliveMinutes)m" : nil)
            let request = ChatRequest(model: session.modelName,
                                      messages: turns,
                                      contextSize: stableCtx,
                                      numPredict: session.maxResponseTokens,
                                      think: session.reasoningMode.think,
                                      keepAlive: keepAlive,
                                      parameters: session.generationParameters)
            assistant.requestPayload = RequestInspector.payload(for: request,
                                                                backend: session.backend,
                                                                appleOptions: session.appleOptions)
            await self.consume(backend.chat(request),
                               into: assistant,
                               session: session,
                               titleBackend: backend,
                               rawPromptEstimate: rawPromptTokens,
                               modelContext: modelContext)
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        activityStatus = nil
    }

    /// Forgets a session's `num_ctx` floor so a cleared conversation right-sizes afresh.
    public func resetContextSizing(for session: ChatSession) {
        contextFloors[session.id] = nil
    }

    public func dismissError() {
        errorMessage = nil
    }

    /// Image-generation backend: render the prompt to an image reply via the configured
    /// local image server. Runs off-main in the cancellable `streamTask`; the rendered
    /// PNG is stored on the assistant message. No text streaming, history, or RAG.
    private func generateImage(text: String,
                               session: ChatSession,
                               serverURL: String,
                               backendKindRaw: String,
                               template: ComfyWorkflowTemplate?,
                               modelContext: ModelContext) {
        let request = ImageRequest(prompt: text,
                                   negativePrompt: session.imageNegativePrompt,
                                   model: session.imageModel,
                                   steps: session.imageSteps,
                                   width: session.imageSize,
                                   height: session.imageSize,
                                   cfgScale: session.imageCFG,
                                   vae: session.imageVAE,
                                   seed: session.imageSeed,
                                   sampler: session.imageSampler,
                                   upscaler: session.imageUpscaler,
                                   upscaleAmount: session.imageUpscaleAmount,
                                   latentUpscalerSteps: session.imageLatentUpscalerSteps,
                                   faceCorrection: session.imageFaceCorrection,
                                   clipSkip: session.imageClipSkip)
        runImageGeneration(request: request, session: session, serverURL: serverURL,
                           backendKindRaw: backendKindRaw, template: template, modelContext: modelContext)
    }

    /// Re-renders a previously generated image as a new turn, reusing its prompt and
    /// parameters but rolling a fresh random seed (so the result differs).
    public func regenerateImage(from message: ChatMessage,
                         session: ChatSession,
                         serverURL: String,
                         backendKindRaw: String,
                         imageWorkflowTemplate: ComfyWorkflowTemplate? = nil,
                         modelContext: ModelContext) {
        guard !isStreaming, let info = message.imageGenInfo else { return }
        var request = ImageRequest(prompt: info.prompt,
                                   negativePrompt: info.negativePrompt,
                                   model: info.model,
                                   steps: info.steps,
                                   width: info.width,
                                   height: info.height,
                                   cfgScale: info.cfgScale,
                                   vae: info.vae,
                                   seed: nil,
                                   sampler: info.sampler ?? "euler_a",
                                   upscaler: info.upscaler ?? "",
                                   upscaleAmount: info.upscaleAmount ?? 4,
                                   latentUpscalerSteps: info.latentUpscalerSteps ?? 10,
                                   faceCorrection: info.faceCorrection ?? "",
                                   clipSkip: info.clipSkip ?? false)
        request.seed = Int.random(in: 0...Int(UInt32.max))
        runImageGeneration(request: request, session: session, serverURL: serverURL,
                           backendKindRaw: backendKindRaw, template: imageWorkflowTemplate, modelContext: modelContext)
    }

    /// Shared image-generation flow: insert the prompt + assistant turns, render the
    /// request off-main, and store the PNG and its parameters on the assistant message.
    private func runImageGeneration(request: ImageRequest,
                                    session: ChatSession,
                                    serverURL: String,
                                    backendKindRaw: String,
                                    template: ComfyWorkflowTemplate?,
                                    modelContext: ModelContext) {
        guard ImageGen.isConfigured(enabled: true, serverURL: serverURL) else {
            errorMessage = "Set an image server URL in Settings → Image Generation."
            return
        }
        errorMessage = nil
        contextInfo = nil

        let userMessage = ChatMessage(role: .user, content: request.prompt)
        userMessage.session = session
        modelContext.insert(userMessage)

        let assistant = ChatMessage(role: .assistant, content: "")
        assistant.session = session
        assistant.imageGenInfo = ImageGenInfo(request)
        modelContext.insert(assistant)
        session.updatedAt = .now

        let kind = ImageBackendKind(rawValue: backendKindRaw) ?? .easyDiffusion
        // ComfyUI generates through a selected workflow template; other backends need only the URL.
        let provider: ImageProvider = kind == .comfyUI
            ? ComfyUIProvider(baseURLString: serverURL, template: template)
            : kind.makeProvider(baseURLString: serverURL)

        isStreaming = true
        activityStatus = "Generating image…"
        let started = Date()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await provider.generate(request)
                assistant.generatedImageData = data
                assistant.generationSeconds = Date().timeIntervalSince(started)
                session.updatedAt = .now
            } catch is CancellationError {
                modelContext.delete(assistant)
            } catch {
                modelContext.delete(assistant)
                self.errorMessage = error.localizedDescription
            }
            self.activityStatus = nil
            self.isStreaming = false
            self.streamTask = nil
        }
    }

    // MARK: - Streaming

    private func consume(_ stream: AsyncThrowingStream<ChatChunk, Error>,
                         into assistant: ChatMessage,
                         session: ChatSession,
                         titleBackend: ChatStreaming,
                         rawPromptEstimate: Int = 0,
                         modelContext: ModelContext) async {
        let started = Date()
        var sawFirstToken = false
        do {
            for try await chunk in stream {
                if !sawFirstToken,
                   !chunk.contentDelta.isEmpty || !chunk.thinkingDelta.isEmpty {
                    assistant.firstTokenSeconds = Date().timeIntervalSince(started)
                    sawFirstToken = true
                }
                if chunk.isReplacement {
                    // Cumulative snapshot (Apple backend): replace the body.
                    assistant.content = chunk.contentDelta
                } else {
                    if !chunk.contentDelta.isEmpty {
                        assistant.content += chunk.contentDelta
                    }
                    if !chunk.thinkingDelta.isEmpty {
                        assistant.thinking += chunk.thinkingDelta
                    }
                }
                if chunk.done {
                    assistant.promptTokens = chunk.promptTokens
                    assistant.evalTokens = chunk.evalTokens
                    assistant.evalDurationNanos = chunk.evalDurationNanos
                    // "length" means the model hit the context window mid-reply.
                    assistant.wasTruncated = (chunk.doneReason == "length")
                    // Calibrate the token estimator against the server's real count so
                    // future budgets for this model reflect its true tokenization.
                    if session.backend == .ollama, let actual = chunk.promptTokens {
                        tokenCalibrator.record(model: session.modelName,
                                               rawEstimate: rawPromptEstimate,
                                               actualTokens: actual)
                    }
                }
            }
            assistant.generationSeconds = Date().timeIntervalSince(started)
            session.updatedAt = .now
            isStreaming = false
            await maybeGenerateTitle(for: session, client: titleBackend)
        } catch {
            isStreaming = false
            let cancelled = (error is CancellationError) || (error as? URLError)?.code == .cancelled
            if cancelled {
                // The user stopped generation; keep whatever streamed so far.
                if !assistant.content.isEmpty {
                    assistant.generationSeconds = Date().timeIntervalSince(started)
                }
                session.updatedAt = .now
                return
            }
            // A real failure with no content: drop the empty assistant bubble.
            if assistant.content.isEmpty {
                modelContext.delete(assistant)
            } else {
                assistant.generationSeconds = Date().timeIntervalSince(started)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// A short system instruction (opt-in, app-wide) telling the model how to emit
    /// diagrams so they render cleanly inline. Addresses two common model habits:
    /// unquoted Mermaid labels (which fail to parse) and "paste this into an online
    /// editor" boilerplate (redundant since the app renders diagrams in place).
    public static let diagramGuidanceText = """
    Rendering note: this app renders Mermaid diagrams inline. When a diagram helps, \
    include it as a single ```mermaid code block. Put any node label that contains \
    punctuation in double quotes, e.g. A["Use weapon (knife, bat)"]. Do not tell the \
    user to copy or paste the diagram into an external or online editor.
    """

    /// Prepends the session system prompt and any attachment-context block to the
    /// already-prepared conversation `historyTurns` (which include the new user turn).
    /// When `nativeImages` is non-empty, they're attached to the latest user turn so a
    /// vision-capable primary model receives the image directly.
    ///
    /// Turn order is deliberately stable-prefix-first — system prompt, then guidance,
    /// then the reference/context blocks, then history ending in the new user turn — so
    /// the large, unchanging leading content stays byte-identical across turns and the
    /// server can reuse its cached prompt (KV) prefix instead of re-evaluating it.
    private func buildTurns(for session: ChatSession,
                            contextBlock: String?,
                            historyTurns: [ChatTurn],
                            imageDescription: String? = nil,
                            nativeImages: [String] = [],
                            diagramGuidance: Bool = false) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        let systemPrompt = session.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            turns.append(ChatTurn(role: Role.system.rawValue, content: systemPrompt))
        }
        if diagramGuidance {
            turns.append(ChatTurn(role: Role.system.rawValue, content: Self.diagramGuidanceText))
        }
        if let contextBlock, !contextBlock.isEmpty {
            let preamble = """
            You have been given reference material to help answer the conversation. \
            Use it when relevant; if it doesn't contain the answer, say so rather than guessing.

            <reference_material>
            \(contextBlock)
            </reference_material>
            """
            turns.append(ChatTurn(role: Role.system.rawValue, content: preamble))
        }
        if let imageDescription, !imageDescription.isEmpty {
            turns.append(ChatTurn(role: Role.system.rawValue, content: """
            The user attached image(s), described below by a vision model. Treat this \
            description as your view of the image(s).

            <image_description>
            \(imageDescription)
            </image_description>
            """))
        }
        var history = historyTurns
        // Attach native images to the last user turn (the new message).
        if !nativeImages.isEmpty,
           let lastUser = history.lastIndex(where: { $0.role == Role.user.rawValue }) {
            let t = history[lastUser]
            history[lastUser] = ChatTurn(role: t.role, content: t.content, images: nativeImages)
        }
        turns.append(contentsOf: history)
        return turns
    }

    // MARK: - Vision (image attachments)

    /// The outcome of the vision pre-step: a text description to inject (preprocessor
    /// pipeline), and/or base64 images to send natively to the primary model.
    private struct VisionResult {
        var description: String?
        var nativeImages: [String]
    }

    /// Runs the vision step for image attachments. For a vision-capable primary model
    /// with no separate vision model set, sends the raw images natively. Otherwise
    /// describes them with the session's vision model and returns the text to inject,
    /// caching descriptions on the attachments. Annotates `assistant.visionNote`.
    private func assembleVision(query: String,
                                session: ChatSession,
                                into assistant: ChatMessage,
                                client: OllamaClient?) async -> VisionResult {
        let images = session.orderedAttachments.filter(\.isImage)
        guard !images.isEmpty else { return VisionResult(description: nil, nativeImages: []) }

        let primarySupportsVision = session.backend == .ollama
            && availableVisionModelNames.contains(session.modelName)
        let visionModel = session.visionModel

        // Native path: primary model can see, and no separate vision model is set.
        if visionModel.isEmpty && primarySupportsVision {
            let names = images.map(\.fileName).joined(separator: ", ")
            assistant.visionNote = "Sent \(images.count) image\(images.count == 1 ? "" : "s") (\(names)) natively to \(session.modelName)."
            return VisionResult(description: nil, nativeImages: images.compactMap(\.imageBase64))
        }

        // Preprocessor path needs a vision model and a reachable server.
        guard !visionModel.isEmpty, let client else {
            assistant.visionNote = "No vision model set and the primary model can't see images; the attached image was ignored. Set a vision model in Session Settings."
            return VisionResult(description: nil, nativeImages: [])
        }

        activityStatus = "Looking at image…"
        defer { activityStatus = nil }

        let toDescribe = images
            .filter { $0.imageDescription.isEmpty }
            .compactMap { att -> VisionImage? in
                guard let b64 = att.imageBase64 else { return nil }
                return VisionImage(id: att.id, name: att.fileName, base64: b64)
            }
        if !toDescribe.isEmpty {
            let extractor = VisionExtractor(client: client, visionModel: visionModel)
            let described = await extractor.describe(toDescribe, userPrompt: query)
            let byID = Dictionary(images.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for d in described { byID[d.id]?.imageDescription = d.description }
        }

        let blocks = images
            .filter { !$0.imageDescription.isEmpty }
            .map { "[\($0.fileName)]\n\($0.imageDescription)" }
        let descriptionText = blocks.joined(separator: "\n\n")
        assistant.visionNote = "Described \(images.count) image\(images.count == 1 ? "" : "s") with \(visionModel), then sent the description to \(session.modelName).\n\n\(descriptionText)"
        return VisionResult(description: descriptionText.isEmpty ? nil : descriptionText, nativeImages: [])
    }

    /// Names of the session's models known to support vision (populated by
    /// `loadVisionCapabilities`). Lets the controller choose native vs. preprocessor paths.
    public var availableVisionModelNames: Set<String> = []

    /// Trained context length per Ollama model name (from `/api/show`, populated by
    /// `loadModelContextLength`). Lets budgeting and `num_ctx` respect the model's real limit.
    public var modelContextLengths: [String: Int] = [:]

    /// The effective context window for this session: the user's chosen size, capped to
    /// the model's real trained limit when known. Budget planning and the request both
    /// respect this so the app never plans for room the model doesn't actually have.
    public func contextCeiling(for session: ChatSession) -> Int {
        guard session.backend == .ollama,
              let maxLen = modelContextLengths[session.modelName], maxLen > 0 else {
            return session.contextSize
        }
        return min(session.contextSize, maxLen)
    }

    /// Loads which server models support vision into `availableVisionModelNames`, so the
    /// controller can choose the native-vision vs. preprocessor path when an image is
    /// attached. Silent no-op without a reachable client. Callers inject the client so
    /// the controller stays configuration-free.
    public func loadVisionCapabilities(client: OllamaClient?) async {
        guard let client else { return }
        if let models = try? await client.models() {
            availableVisionModelNames = Set(models.filter(\.supportsVision).map(\.name))
        }
    }

    /// Looks up the session model's trained context length (`/api/show`) into
    /// `modelContextLengths`, so budgeting and `num_ctx` respect the model's real limit
    /// instead of the user's raw preset. Skips backends other than Ollama, unnamed models,
    /// already-cached lookups, and unreachable clients.
    public func loadModelContextLength(for session: ChatSession, client: OllamaClient?) async {
        guard session.backend == .ollama, !session.modelName.isEmpty,
              modelContextLengths[session.modelName] == nil,
              let client else { return }
        if let length = try? await client.modelContextLength(session.modelName), length > 0 {
            modelContextLengths[session.modelName] = length
        }
    }

    // MARK: - Conversation history management

    private let recentTurnsToKeep = 6

    /// Resolves the conversation portion of the request according to the session's
    /// `historyMode`. Short chats (that fit the window) always send everything; the
    /// modes only engage when the full history would overflow.
    private func assembleHistory(session: ChatSession,
                                 newUserText: String,
                                 contextBlock: String?,
                                 into assistant: ChatMessage,
                                 client: OllamaClient?,
                                 embeddingModel: String) async -> [ChatTurn] {
        let conv = session.orderedMessages
            .filter { $0.role != .system && !$0.content.isEmpty }
            .map { HistoryTurn(id: $0.id, role: $0.role.rawValue, content: $0.content,
                               createdAt: $0.createdAt, embedding: $0.embedding) }
        guard !conv.isEmpty else { return [] }

        // Plan against a window shrunk by the model's learned tokenization factor, so a
        // dense history is recognized as over-budget before the server truncates it.
        let ceiling = contextCeiling(for: session)
        let scale = tokenCalibrator.scale(for: session.modelName)
        let planningWindow = max(1, Int(Double(ceiling) / scale))
        let reserve = ContextBudget(contextSize: planningWindow,
                                    systemTokens: 0, historyTokens: 0, userTokens: 0).responseReserve
        let overhead = TokenEstimator.estimate(session.systemPrompt)
            + TokenEstimator.estimate(contextBlock ?? "")
        let budget = max(0, planningWindow - overhead - reserve)

        // Everything fits: pristine full history, no network, no note.
        if ConversationHistory.fits(conv, budget: budget) {
            return conv.map { ChatTurn(role: $0.role, content: $0.content) }
        }

        // Over budget: apply the mode. Server-dependent modes fall back to truncation
        // when there's no reachable server (e.g. an Apple-only session).
        let mode = (session.historyMode.needsServer && client == nil) ? .truncate : session.historyMode
        switch mode {
        case .full:
            assistant.historyNote = "History (~\(ConversationHistory.tokenCount(conv)) tokens) exceeds the \(ceiling)-token window; the server will clamp it. Choose a History mode in Session Settings to manage it."
            return conv.map { ChatTurn(role: $0.role, content: $0.content) }

        case .truncate:
            let (kept, dropped) = ConversationHistory.truncateToFit(conv, budget: budget)
            if dropped > 0 {
                assistant.historyNote = "Truncated: dropped the \(dropped) oldest turn\(dropped == 1 ? "" : "s") to fit the window; kept the \(kept.count) most recent."
            }
            return kept.map { ChatTurn(role: $0.role, content: $0.content) }

        case .summarize:
            return await summarizeHistory(conv, budget: budget, session: session,
                                          into: assistant, client: client!)

        case .retrieve:
            return await retrieveHistory(conv, budget: budget, query: newUserText,
                                         session: session, into: assistant,
                                         client: client!, embeddingModel: embeddingModel)
        }
    }

    /// Rolling-summary mode: keep recent turns verbatim, fold older turns into a cached
    /// summary that grows over time. Falls back to truncation if summarizing fails.
    private func summarizeHistory(_ conv: [HistoryTurn],
                                  budget: Int,
                                  session: ChatSession,
                                  into assistant: ChatMessage,
                                  client: OllamaClient) async -> [ChatTurn] {
        let (older, recent) = ConversationHistory.splitRecent(conv, keepRecent: recentTurnsToKeep)
        let (keptRecent, _) = ConversationHistory.truncateToFit(recent, budget: budget)

        guard !older.isEmpty else {
            return keptRecent.map { ChatTurn(role: $0.role, content: $0.content) }
        }

        // Fold any not-yet-summarized older turns into the running summary.
        let already = session.summarizedUntil
        let toFold = older.filter { already == nil || $0.createdAt > already! }
        var summary = session.historySummary
        if !toFold.isEmpty {
            let convoText = toFold.map { "\($0.role): \($0.content)" }.joined(separator: "\n\n")
            let prior = summary.isEmpty ? "" : "Summary so far:\n\(summary)\n\n"
            let input = "\(prior)New conversation to fold into the summary:\n\(convoText)"
            if let updated = await summarizeText(input, client: client, model: session.modelName) {
                summary = updated
                session.historySummary = updated
                session.summarizedUntil = older.last?.createdAt
            } else if summary.isEmpty {
                // Summarization failed and we have nothing cached: truncate instead.
                let (kept, dropped) = ConversationHistory.truncateToFit(conv, budget: budget)
                assistant.historyNote = "Summary unavailable; truncated the \(dropped) oldest turn\(dropped == 1 ? "" : "s") instead."
                return kept.map { ChatTurn(role: $0.role, content: $0.content) }
            }
        }

        var turns: [ChatTurn] = []
        if !summary.isEmpty {
            turns.append(ChatTurn(role: Role.system.rawValue,
                                  content: "Summary of earlier conversation (older turns condensed):\n\(summary)"))
            assistant.historyNote = "Rolling summary: condensed \(older.count) older turn\(older.count == 1 ? "" : "s"), kept the \(keptRecent.count) most recent verbatim.\n\nSummary:\n\(summary)"
        }
        turns.append(contentsOf: keptRecent.map { ChatTurn(role: $0.role, content: $0.content) })
        return turns
    }

    /// Retrieval mode: keep recent turns verbatim, and inject only the older turns most
    /// relevant to the new message (by embedding similarity). Falls back to truncation
    /// if embedding fails.
    private func retrieveHistory(_ conv: [HistoryTurn],
                                 budget: Int,
                                 query: String,
                                 session: ChatSession,
                                 into assistant: ChatMessage,
                                 client: OllamaClient,
                                 embeddingModel: String) async -> [ChatTurn] {
        let (older, recent) = ConversationHistory.splitRecent(conv, keepRecent: recentTurnsToKeep)
        let (keptRecent, _) = ConversationHistory.truncateToFit(recent, budget: budget)
        let remaining = max(0, budget - ConversationHistory.tokenCount(keptRecent))

        guard !older.isEmpty, remaining > 0 else {
            return keptRecent.map { ChatTurn(role: $0.role, content: $0.content) }
        }

        do {
            var working = older
            var newEmbeddings: [UUID: [Float]] = [:]
            let missing = working.enumerated().filter { $0.element.embedding == nil }
            if !missing.isEmpty {
                let vectors = try await client.embed(model: embeddingModel,
                                                     input: missing.map { "search_document: " + $0.element.content })
                for (k, item) in missing.enumerated() {
                    working[item.offset].embedding = vectors[k]
                    newEmbeddings[item.element.id] = vectors[k]
                }
            }
            let queryVector = try await client.embed(model: embeddingModel,
                                                     input: ["search_query: " + query]).first ?? []
            guard !queryVector.isEmpty else { throw OllamaError.server("Empty query embedding.") }

            // Persist freshly computed embeddings back onto the @Model messages.
            if !newEmbeddings.isEmpty {
                let byID = Dictionary(session.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for (id, vector) in newEmbeddings { byID[id]?.embedding = vector }
            }

            let scored = working.compactMap { turn -> (turn: HistoryTurn, score: Float)? in
                guard let embedding = turn.embedding else { return nil }
                return (turn, Vector.cosineSimilarity(queryVector, embedding))
            }.sorted { $0.score > $1.score }

            var selected: [(turn: HistoryTurn, score: Float)] = []
            var used = 0
            for candidate in scored {
                let cost = TokenEstimator.estimate(candidate.turn.content)
                if !selected.isEmpty, used + cost > remaining { break }
                selected.append(candidate)
                used += cost
                if used >= remaining { break }
            }
            guard !selected.isEmpty else {
                return keptRecent.map { ChatTurn(role: $0.role, content: $0.content) }
            }

            let chrono = selected.sorted { $0.turn.createdAt < $1.turn.createdAt }
            let block = "Relevant earlier messages from this conversation:\n\n"
                + chrono.map { "\($0.turn.role): \($0.turn.content)" }.joined(separator: "\n\n")

            let infos = chrono.enumerated().map { index, item in
                RetrievedChunkInfo(id: item.turn.id,
                                   sourceName: item.turn.role == Role.user.rawValue ? "You" : "Assistant",
                                   ordinal: index, score: item.score, text: item.turn.content)
            }
            assistant.historyRetrievalData = try? JSONEncoder().encode(infos)
            assistant.historyNote = "Retrieved \(selected.count) of \(older.count) earlier turn\(older.count == 1 ? "" : "s") most relevant to your message; kept the \(keptRecent.count) most recent verbatim."

            var turns = [ChatTurn(role: Role.system.rawValue, content: block)]
            turns.append(contentsOf: keptRecent.map { ChatTurn(role: $0.role, content: $0.content) })
            return turns
        } catch {
            let (kept, dropped) = ConversationHistory.truncateToFit(conv, budget: budget)
            assistant.historyNote = "Retrieval unavailable (\(error.localizedDescription)); truncated the \(dropped) oldest turn\(dropped == 1 ? "" : "s") instead."
            return kept.map { ChatTurn(role: $0.role, content: $0.content) }
        }
    }

    /// One-shot summary call used by rolling-summary history mode.
    private func summarizeText(_ text: String, client: OllamaClient, model: String) async -> String? {
        let system = "You maintain a running summary of a conversation so it can continue within a limited context window. Preserve decisions, facts, names, numbers, the user's goals, and open questions. Drop pleasantries and redundancy. Output only the updated summary."
        let request = ChatRequest(model: model,
                                  messages: [ChatTurn(role: Role.system.rawValue, content: system),
                                             ChatTurn(role: Role.user.rawValue, content: text)],
                                  contextSize: 8192, stream: false, numPredict: 512, think: false)
        do {
            var out = ""
            for try await chunk in client.chat(request) { out += chunk.contentDelta }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    // MARK: - Context assembly

    /// Builds the document-context block for this turn, if the session has
    /// attachments. Gathers `Sendable` chunks on the main actor, runs the strategy
    /// ladder off-actor via `ContextAssembler`, then persists any new embeddings.
    private func assembleContext(query: String,
                                 session: ChatSession,
                                 into assistant: ChatMessage,
                                 client: OllamaClient?,
                                 embeddingModel: String) async -> String? {
        let attachments = session.orderedAttachments.filter { !$0.isImage }
        guard !attachments.isEmpty else { return nil }
        // Context assembly (embeddings, summarization) runs on the Ollama server. An
        // Apple-only session with no server simply sends without document context.
        guard let client else { return nil }

        var chunks: [RetrievableChunk] = []
        var ordinal = 0
        for attachment in attachments {
            for chunk in attachment.orderedChunks {
                chunks.append(RetrievableChunk(id: chunk.id,
                                               sourceName: attachment.fileName,
                                               ordinal: ordinal,
                                               text: chunk.text,
                                               embedding: chunk.embedding))
                ordinal += 1
            }
        }
        guard !chunks.isEmpty else { return nil }

        let contentTokens = chunks.reduce(0) { $0 + TokenEstimator.estimate($1.text) }
        let historyTokens = session.orderedMessages
            .filter { $0.role != .system && !$0.content.isEmpty }
            .reduce(0) { $0 + TokenEstimator.estimate($1.content) }
        // Plan against a window shrunk by the model's learned tokenization factor, so
        // dense sources are recognized as too large (and retrieval/summarize kicks in)
        // before they would overflow the real window.
        let ceiling = contextCeiling(for: session)
        let scale = tokenCalibrator.scale(for: session.modelName)
        let planningWindow = max(1, Int(Double(ceiling) / scale))
        let budget = ContextBudget(contextSize: planningWindow,
                                   systemTokens: TokenEstimator.estimate(session.systemPrompt),
                                   historyTokens: historyTokens,
                                   userTokens: TokenEstimator.estimate(query))
        let available = budget.availableForContext
        guard available > 0 else { return nil }

        let plan = ContextPlanner.plan(contentTokens: contentTokens,
                                       available: available,
                                       mode: session.contextMode,
                                       wholeDocTask: ContextPlanner.looksLikeWholeDocTask(query))
        guard !plan.isEmpty else { return nil }

        let assembler = ContextAssembler(client: client,
                                         chatModel: session.modelName,
                                         embeddingModel: embeddingModel)
        // Retrieve using the question plus a short tail of recent turns so follow-ups
        // resolve against the surrounding conversation.
        let priorTurns = session.orderedMessages
            .filter { $0.role != .system && !$0.content.isEmpty }
            .dropLast()
            .suffix(2)
            .map(\.content)
        let retrievalQuery = ContextAssembler.enrichedRetrievalQuery(current: query, recentTurns: Array(priorTurns))
        guard let result = await assembler.assemble(chunks: chunks,
                                                    query: query,
                                                    available: available,
                                                    plan: plan,
                                                    retrievalQuery: retrievalQuery) else { return nil }

        // Persist freshly computed embeddings back onto the @Model chunks.
        if !result.newEmbeddings.isEmpty {
            let chunksByID = Dictionary(attachments.flatMap(\.chunks).map { ($0.id, $0) },
                                        uniquingKeysWith: { first, _ in first })
            for (id, vector) in result.newEmbeddings {
                chunksByID[id]?.embedding = vector
            }
        }

        // In automatic mode, when the sources are too large to send whole, the planner
        // drops from inline to retrieval/summarize. Surface that as a non-blocking
        // advisory so the user knows the reply is still reliable and how to get a
        // whole-document answer if they want one.
        let autoSwitched = session.contextMode == .auto
            && contentTokens > available
            && (result.strategyUsed == .retrieval || result.strategyUsed == .summarize)
        let warning: String? = autoSwitched
            ? "Sources are large for this \(ContextSize.label(ceiling)) window — auto-switched to \(result.strategyUsed.label) so the reply isn't cut off. For a whole-document answer, increase the context size or attach a smaller source."
            : nil

        contextInfo = ContextInfo(strategy: result.strategyUsed,
                                  sources: result.sourceLabels,
                                  note: result.note,
                                  warning: warning)
        if !result.retrieved.isEmpty {
            assistant.retrievalData = try? JSONEncoder().encode(result.retrieved)
        }
        return result.contextText
    }

    // MARK: - Auto-naming

    private func maybeGenerateTitle(for session: ChatSession, client: ChatStreaming) async {
        guard session.titleIsAuto else { return }
        let conversation = session.orderedMessages.filter { $0.role != .system }
        guard let firstUser = conversation.first(where: { $0.role == .user })?.content,
              let firstAssistant = conversation.first(where: { $0.role == .assistant })?.content,
              !firstAssistant.isEmpty else { return }

        let title = await TitleGenerator.generate(model: session.modelName,
                                                   userMessage: firstUser,
                                                   assistantReply: firstAssistant,
                                                   client: client)
        // Re-check: the user may have renamed while the title was generating. Mark the
        // session done auto-naming so it only happens once (until an explicit reset).
        if let title, session.titleIsAuto {
            session.title = title
            session.titleIsAuto = false
        }
    }
}

/// A short summary of how attached context was fitted into the last turn, for display.
public struct ContextInfo: Equatable {
    public var strategy: ContextStrategy
    public var sources: [String]
    public var note: String?
    /// A non-blocking advisory shown prominently when automatic mode had to switch
    /// away from full-text to keep the reply from being truncated.
    public var warning: String?

    public init(strategy: ContextStrategy, sources: [String], note: String? = nil, warning: String? = nil) {
        self.strategy = strategy
        self.sources = sources
        self.note = note
        self.warning = warning
    }

    public var summary: String {
        let sourceList = sources.isEmpty ? "" : " · " + sources.joined(separator: ", ")
        return "Context: \(strategy.label)\(sourceList)"
    }
}
