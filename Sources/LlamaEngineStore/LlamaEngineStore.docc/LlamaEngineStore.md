# ``LlamaEngineStore``

Batteries‑included SwiftData persistence for LlamaEngine: the default data model plus a
persisting conversation controller.

## Overview

`LlamaEngineStore` builds on the core `LlamaEngine` product. It provides:

- The default `@Model` types — ``ChatSession``, ``ChatMessage``, ``Attachment``,
  ``DocumentChunk``, and ``PromptPreset`` — with their relationships and cascade rules.
- ``ConversationController`` — a `@MainActor`, `@Observable` controller that drives the
  whole send → stream → RAG → vision → image flow, writing results straight into your
  models.
- ``AttachmentLoader`` — turns a file (or in‑memory text) into a chunked ``Attachment``.

Register the schema the store owns when you build your container:

```swift
import SwiftData
import LlamaEngine
import LlamaEngineStore

let container = try ModelContainer(for: Schema(LlamaEngineStore.models))
```

Then drive a conversation. The controller is observable, so SwiftUI updates as the reply
streams in:

```swift
@MainActor
func send(_ text: String, in session: ChatSession, context: ModelContext) {
    let controller = ConversationController()
    controller.send(
        text: text,
        session: session,
        client: OllamaClient(baseURLString: "http://localhost:11434"),
        embeddingModel: "nomic-embed-text",
        modelContext: context
    )
    // Observe controller.isStreaming / controller.contextInfo / session.orderedMessages.
}
```

To export a conversation, use the ``ChatSession/exportSnapshot()`` helper with the core
`SessionExporter`.

## Topics

### The conversation engine

- ``ConversationController``
- ``ContextInfo``

### Data model

- ``ChatSession``
- ``ChatMessage``
- ``Attachment``
- ``DocumentChunk``
- ``PromptPreset``

### Loading content

- ``AttachmentLoader``
