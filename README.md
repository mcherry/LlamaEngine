# LlamaEngine

A portable Swift package that provides a **complete local-LLM interface** — extracted
from [Llamatron](https://github.com/mcherry/Lammatron) so multiple apps can share one
feature-complete AI engine instead of each reimplementing it.

It bundles everything Llamatron does today:

- **Backends** — Ollama (streaming, thinking models, generation params, `num_ctx`
  right-sizing, `keep_alive`, `num_predict`, per-model token calibration, `/api/show`
  context length, model management) and Apple Intelligence (Foundation Models), behind
  a protocol + registry so new backends are easy to add.
- **Context / RAG** — attachments, chunking, embeddings, retrieval (MMR), map-reduce
  summarize, truncate, token budgeting/planning, calibration, query enrichment.
- **Conversation history** management (full / truncate / summarize / retrieve).
- **Vision** (native + preprocessor pipeline), **web ingestion** (fetch/search/robots/
  extraction), **image generation**, **TTS + STT** (dictation, narration).
- **Rendering** — markdown, Mermaid (sanitizer + inline WebView), syntax highlighting.
- A **batteries-included SwiftData store** + a persisting conversation controller, and
  **reusable SwiftUI screens**, so a host app is basically just UI + branding.

> **Status: planning.** See **[PLAN.md](PLAN.md)** for the full architecture and the
> phased, always-green extraction plan. Implementation has not started yet.

## Products (planned)

| Product | Contents |
|---|---|
| `LlamaEngine` | Core logic, backends, services. No SwiftUI / SwiftData. |
| `LlamaEngineStore` | SwiftData `@Model`s + schema + the persisting `ConversationController`. |
| `LlamaEngineUI` | Reusable SwiftUI screens + rendering views (+ bundled `mermaid.min.js`). |

## Platforms

macOS 15+ (Swift 6). The core and store are largely iOS-ready for a future target;
`LlamaEngineUI`'s AppKit bits would need UIKit variants.

## License

To be decided — the engine is shared between an MIT-licensed app (Llamatron) and a
proprietary one, so licensing is an open question tracked in the plan.
