# ``LlamaEngine``

A headless, local‑LLM AI layer for Ollama‑based apps: models, streaming, RAG, vision,
speech, image generation, and web access — with no UI.

## Overview

LlamaEngine is the core product of the package. It imports no SwiftUI and no AppKit, so it
can back any front end — a macOS app, a menu‑bar utility, a CLI, or an iOS/iPadOS app.

It talks to [Ollama](https://ollama.com), a llama.cpp server, and Apple Intelligence behind the
``ChatStreaming`` / ``LLMBackend`` protocols, and provides the supporting machinery for
retrieval‑augmented chat: chunking, embeddings, token budgeting, conversation‑history
management, vision, speech, image generation, and web ingestion.

For batteries‑included persistence — SwiftData models plus a persisting controller — add the
`LlamaEngineStore` product.

- Note: The engine reads no `UserDefaults` or `@AppStorage`. Hosts pass configuration into
  each call, so settings ownership stays in the app.

## Topics

### Getting started

- <doc:GettingStarted>

### Talking to a model

- ``OllamaClient``
- ``LlamaServerClient``
- ``ChatStreaming``
- ``LLMBackend``
- ``FoundationModelsBackend``
- ``BackendKind``
- ``BackendProfile``
- ``OllamaError``

### Requests & responses

- ``ChatRequest``
- ``ChatTurn``
- ``ChatChunk``
- ``GenerationParameters``
- ``ReasoningMode``
- ``Role``

### Model management

- ``ModelManager``
- ``OllamaModel``
- ``RunningModel``
- ``PullProgress``
- ``ServerProbe``

### Context & retrieval (RAG)

- ``ContextAssembler``
- ``EmbeddingBackend``
- ``AppleEmbedder``
- ``LexicalFilter``
- ``DirectoryFilter``
- ``RetrievableChunk``
- ``RetrievedChunkInfo``
- ``AssembledContext``
- ``MMRCandidate``
- ``ContextPlanner``
- ``ContextBudget``
- ``ContextStrategy``
- ``ContextMode``
- ``ContextSize``

### Conversation history

- ``ConversationHistory``
- ``HistoryTurn``
- ``HistoryMode``

### Tokens & vectors

- ``TokenEstimator``
- ``TokenCalibrator``
- ``TextChunker``
- ``TextTruncator``
- ``Vector``

### Vision

- ``VisionExtractor``
- ``VisionImage``
- ``VisionDescription``

### Image generation

- ``ImageProvider``
- ``ImageRequest``
- ``ImageGenInfo``
- ``ImageModel``
- ``ImageBackendKind``
- ``ImageSampler``
- ``ImageUpscaler``
- ``FaceCorrection``
- ``ImageDimensions``
- ``ImageGen``
- ``ImageGenError``

### Speech

- ``SpeechController``
- ``DictationController``
- ``TTSProvider``
- ``TTSRequest``
- ``TTSVoice``
- ``TTSEngine``
- ``TTS``
- ``AppleSpeech``
- ``TTSError``

### Web

- ``WebAccess``
- ``WebSearch``
- ``WebSearchConfig``
- ``RateLimitGate``
- ``SearchUsage``
- ``HTMLExtractor``
- ``RobotsTxt``

### Text rendering (logic)

- ``MarkdownParser``
- ``MarkdownBlock``
- ``MermaidSanitizer``
- ``SyntaxHighlighter``
- ``DiagramHintFilter``

### Apple Intelligence

- ``AppleIntelligence``
- ``AppleGenerationOptions``
- ``AppleSamplingMode``

### Other services

- ``TitleGenerator``
- ``SessionExporter``
- ``RequestInspector``
