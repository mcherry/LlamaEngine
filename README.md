# LlamaEngine

A **headless Swift package that provides a complete, local‑LLM AI layer** — everything an
[Ollama](https://ollama.com)‑based chat app needs (models, streaming, RAG, vision, speech,
image generation, web access, persistence) with **no UI baked in**. Extracted from
[Llamatron](https://github.com/mcherry/Lammatron) so any app can depend on one
feature‑complete engine and own only its presentation.

The core imports **no SwiftUI and no AppKit** — the same engine can back a macOS app, a
menu‑bar utility, a CLI, or (in future) iOS. The app "handles everything else"; LlamaEngine
handles all things AI.

## Features

- **Backends** — Ollama (streaming, thinking/reasoning models, generation parameters,
  `num_ctx` right‑sizing, `keep_alive`, `num_predict`, per‑model token calibration,
  `/api/show` context length) and Apple Intelligence (Foundation Models), behind a
  `ChatStreaming` / `LLMBackend` protocol so new backends are easy to add.
- **Model management** — list / pull (with progress) / delete / running models via a
  headless, observable `ModelManager`.
- **Context / RAG** — attachments, chunking, embeddings, retrieval with MMR diversity,
  map‑reduce summarization, truncation, token budgeting/planning, per‑model calibration,
  and retrieval‑query enrichment.
- **Conversation history** — full / truncate / rolling‑summary / embedding‑retrieval modes
  that engage only when the window would overflow.
- **Vision** — native (send images to a vision‑capable model) or a preprocessor pipeline
  (describe with a dedicated vision model, then inject the text).
- **Image generation** — Easy Diffusion backend with sampler, VAE, upscaler/hires, face
  correction, and CLIP‑skip controls.
- **Speech** — text‑to‑speech (Apple on‑device or a Kokoro server) and dictation
  (speech‑to‑text) with live narration.
- **Web** — fetch, `robots.txt` compliance, readable HTML extraction, and multi‑provider
  search (SearXNG, Brave, Tavily, Marginalia, Wikipedia).
- **Rendering logic** — Markdown parsing, Mermaid sanitizing, and syntax highlighting
  (pure logic; you supply the views).
- **Batteries‑included persistence** — a SwiftData store (`ChatSession`, `ChatMessage`,
  `Attachment`, …) plus a persisting `ConversationController` that drives the whole
  send → stream → RAG flow straight into your models.

## Requirements

- **macOS 15+**
- **Swift 6** (built with complete strict concurrency)

## Installation

Add the package with Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/mcherry/LlamaEngine.git", branch: "main"),
]
```

Then add the products your target needs:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "LlamaEngine", package: "LlamaEngine"),
        .product(name: "LlamaEngineStore", package: "LlamaEngine"), // optional: persistence
    ]
)
```

For local development against a checkout: `.package(path: "../LlamaEngine")`.

## Products

| Product | Import | Contents | Depends on |
|---|---|---|---|
| `LlamaEngine` | `import LlamaEngine` | Core: backends, context/RAG, services, media, text logic, web. No SwiftUI/SwiftData. | — |
| `LlamaEngineStore` | `import LlamaEngineStore` | SwiftData `@Model`s + schema + the persisting `ConversationController`. | `LlamaEngine` |

Use **`LlamaEngine`** alone if you manage your own state; add **`LlamaEngineStore`** for
batteries‑included persistence.

## Quick start

### Stream a chat (core only)

```swift
import LlamaEngine

guard let client = OllamaClient(baseURLString: "http://localhost:11434") else { return }

let request = ChatRequest(
    model: "llama3.2",
    messages: [ChatTurn(role: "user", content: "Explain diffusion models in one sentence.")],
    contextSize: 8192
)

for try await chunk in client.chat(request) {
    print(chunk.contentDelta, terminator: "") // incremental reply text
    if chunk.done { break }
}
```

### Persisted conversation (with the store)

```swift
import SwiftData
import LlamaEngine
import LlamaEngineStore

// Register the engine-owned schema in your container.
let container = try ModelContainer(for: Schema(LlamaEngineStore.models))

@MainActor
func startChat() {
    let controller = ConversationController()
    let session = ChatSession(modelName: "llama3.2")
    container.mainContext.insert(session)

    controller.send(
        text: "Hello!",
        session: session,
        client: OllamaClient(baseURLString: "http://localhost:11434"),
        embeddingModel: "nomic-embed-text",
        modelContext: container.mainContext
    )
    // Observe `controller.isStreaming` and `session.orderedMessages` from SwiftUI.
}
```

`ConversationController` handles streaming, thinking‑model output, context budgeting, RAG
over attachments, conversation‑history management, vision, and image generation — writing
results straight into your `@Model` objects.

### Manage models

```swift
@MainActor let manager = ModelManager()
await manager.reload(serverURL: "http://localhost:11434")   // → manager.models / manager.running
manager.pull("llama3.2", serverURL: "http://localhost:11434") // → manager.pullStatus / .pullFraction
```

## Architecture

Two layers in one package:

```
LlamaEngine  (core — headless, no SwiftUI/SwiftData)
├── Backends/  Ollama + Apple Intelligence behind ChatStreaming/LLMBackend; ModelManager
├── Types/     Sendable wire types: ChatTurn, ChatRequest, ChatChunk, GenerationParameters, Role
├── Context/   Chunking, vectors, token budgeting/calibration, history, planning
├── Services/  ContextAssembler (RAG), VisionExtractor, TitleGenerator, SessionExporter, ServerProbe
├── Media/     Image generation, TTS + dictation, image/voice option enums
├── Text/      Markdown / Mermaid / syntax-highlight parsing (logic only, no views)
└── Web/        Fetch, robots.txt, HTML extraction, multi-provider search

LlamaEngineStore  (SwiftData — depends on core)
├── Models/                  @Model ChatSession, ChatMessage, Attachment, DocumentChunk, PromptPreset
├── ConversationController   @MainActor @Observable — the send/stream/RAG engine
├── AttachmentLoader         file → chunked Attachment
└── LlamaEngineStore.models  the schema hosts register in their ModelContainer
```

**Design rule:** the engine owns **AI logic**; the host owns **presentation and settings**.
The host passes configuration into calls — the engine reads no `UserDefaults` or
`@AppStorage` of its own.

## Key types

- **Backends & requests:** `OllamaClient`, `ChatStreaming` / `LLMBackend`,
  `FoundationModelsBackend`, `BackendKind`, `ChatRequest`, `ChatTurn`, `ChatChunk`,
  `GenerationParameters`, `ReasoningMode`, `ModelManager`, `OllamaModel`
- **Context / RAG:** `ContextAssembler`, `ContextPlanner`, `ContextBudget`,
  `ContextStrategy` / `ContextMode`, `ConversationHistory` / `HistoryMode`, `TextChunker`,
  `TokenEstimator`, `TokenCalibrator`, `Vector`
- **Media:** `ImageProvider`, `ImageRequest`, `ImageSampler` / `ImageUpscaler` /
  `FaceCorrection`, `ImageBackendKind`, `TTSProvider`, `SpeechController`,
  `DictationController`, `TTSEngine`
- **Web:** `WebAccess`, `WebSearch` (+ `WebSearchConfig`), `HTMLExtractor`, `RobotsTxt`
- **Store:** `ConversationController`, `ChatSession`, `ChatMessage`, `Attachment`,
  `DocumentChunk`, `PromptPreset`, `AttachmentLoader`

## Extending

- **Add an LLM backend** — conform to `ChatStreaming` (or `LLMBackend` for models +
  embeddings) and return an `AsyncThrowingStream<ChatChunk, Error>` from `chat(_:)`.
- **Add an image backend** — conform to `ImageProvider` and add an `ImageBackendKind` case.
- **Add a speech backend** — conform to `TTSProvider`.
- **Add a search provider** — extend `WebSearch.ProviderKind` and `WebSearchConfig`.

## Documentation

Full API reference is provided as DocC catalogs (one per product). Build it in Xcode with
**Product → Build Documentation**, or from the command line with the
[Swift‑DocC plugin](https://github.com/apple/swift-docc-plugin):

```
swift package generate-documentation --target LlamaEngine
```

## Testing

```
swift test
```

The suite is hermetic (no network or running server required): decoders, stream parsers,
token budgeting, calibration, retrieval, and controller guard paths are all unit‑tested.

## License

Not yet finalized — the engine is shared between an MIT‑licensed app (Llamatron) and a
proprietary one, so licensing is an open decision.

---

_Historical design notes and the phased extraction record live in [PLAN.md](PLAN.md)._
