# Getting Started

Stream a chat, run retrieval, and manage models with LlamaEngine.

## Talk to a model

Create an ``OllamaClient`` pointed at a running Ollama server and stream a reply. The
client is a small `Sendable` value — safe to hand to a background task.

```swift
import LlamaEngine

guard let client = OllamaClient(baseURLString: "http://localhost:11434") else { return }

let request = ChatRequest(
    model: "llama3.2",
    messages: [ChatTurn(role: Role.user.rawValue, content: "Explain diffusion models briefly.")],
    contextSize: 8192
)

for try await chunk in client.chat(request) {
    print(chunk.contentDelta, terminator: "")   // incremental answer text
    print(chunk.thinkingDelta, terminator: "")   // reasoning text (thinking models)
    if chunk.done { break }
}
```

``ChatChunk`` carries incremental ``ChatChunk/contentDelta`` (append) unless
``ChatChunk/isReplacement`` is `true` (Apple's Foundation Models stream cumulative
snapshots). When ``ChatChunk/done`` is set, token counts and ``ChatChunk/doneReason`` are
available.

## Tune generation

Pass ``GenerationParameters`` for reproducible or steered output, and ``ReasoningMode`` to
control a thinking model:

```swift
let request = ChatRequest(
    model: "qwen3",
    messages: turns,
    contextSize: 16_384,
    think: ReasoningMode.on.think,
    parameters: GenerationParameters(temperature: 0.7, seed: 42)
)
```

## Retrieve over documents (RAG)

Gather your source text as ``RetrievableChunk`` values, then let ``ContextAssembler`` embed,
retrieve (with MMR diversity), and assemble a context block within a token budget planned by
``ContextPlanner`` and ``ContextBudget``.

```swift
let assembler = ContextAssembler(client: client, chatModel: "llama3.2",
                                 embeddingModel: "nomic-embed-text")

let result = await assembler.assemble(
    chunks: chunks,
    query: userQuestion,
    available: budget.availableForContext,
    plan: plan,
    retrievalQuery: ContextAssembler.enrichedRetrievalQuery(current: userQuestion, recentTurns: recent)
)
```

## Manage models

``ModelManager`` is a `@MainActor`, `@Observable` controller for listing, pulling (with
progress), and deleting models. Bind its state directly to your UI.

```swift
@MainActor let manager = ModelManager()
await manager.reload(serverURL: "http://localhost:11434")
// manager.models, manager.running, manager.isLoading

manager.pull("llama3.2", serverURL: "http://localhost:11434")
// manager.isPulling, manager.pullStatus, manager.pullFraction
```

## Add persistence

Everything above is stateless. To get saved conversations, attachments, and a controller
that drives the full send → stream → RAG → vision flow into SwiftData `@Model` objects, add
the `LlamaEngineStore` product and use its `ConversationController`. See the
`LlamaEngineStore` documentation.
