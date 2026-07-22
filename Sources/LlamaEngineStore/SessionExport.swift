import Foundation
import LlamaEngine

public extension ChatSession {
    /// Builds a `Sendable` export snapshot of this session for `SessionExporter`
    /// (system turns omitted), so callers don't hand-map `@Model` fields into
    /// `SessionExporter.Session`.
    func exportSnapshot() -> SessionExporter.Session {
        SessionExporter.Session(
            title: title,
            backend: backend.label,
            model: modelName,
            contextSize: contextSize,
            systemPrompt: systemPrompt,
            createdAt: createdAt,
            turns: orderedMessages
                .filter { $0.role != .system }
                .map { message in
                    SessionExporter.Turn(role: message.role.rawValue,
                                         content: message.content,
                                         thinking: message.thinking,
                                         createdAt: message.createdAt,
                                         promptTokens: message.promptTokens,
                                         evalTokens: message.evalTokens,
                                         generationSeconds: message.generationSeconds,
                                         firstTokenSeconds: message.firstTokenSeconds)
                }
        )
    }

    /// The non-image attachment chunks as `Sendable` `RetrievableChunk` values, so the
    /// `retrieve_context` tool can read the session's sources without capturing a `@Model`.
    /// Mirrors the marshaling the automatic RAG pipeline uses. Call on the main actor.
    func retrievableChunks() -> [RetrievableChunk] {
        var result: [RetrievableChunk] = []
        for attachment in orderedAttachments where !attachment.isImage {
            for chunk in attachment.orderedChunks {
                result.append(RetrievableChunk(id: chunk.id,
                                               sourceName: attachment.fileName,
                                               ordinal: chunk.ordinal,
                                               text: chunk.text,
                                               embedding: chunk.embedding,
                                               filePath: chunk.filePath))
            }
        }
        return result
    }
}

