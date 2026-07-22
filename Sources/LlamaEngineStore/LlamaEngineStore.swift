import Foundation
import SwiftData

/// LlamaEngineStore — the batteries-included SwiftData layer for LlamaEngine.
///
/// Hosts register `models` in their `ModelContainer` schema to get the full default
/// persistence model (`ChatSession`, `ChatMessage`, `Attachment`, `DocumentChunk`,
/// `PromptPreset`) plus the persisting `ConversationController` that drives the
/// send/stream/RAG flow.
public enum LlamaEngineStore {
    /// The persistent models this package contributes to a host `Schema`. Pass this to
    /// `ModelContainer(for:)` (optionally combined with an app's own models).
    public static let models: [any PersistentModel.Type] = [
        ChatSession.self,
        ChatMessage.self,
        Attachment.self,
        DocumentChunk.self,
        PromptPreset.self,
        ToolCallRecord.self,
    ]
}
