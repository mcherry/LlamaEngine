import Foundation
import SwiftData

/// **Phase 0 spike.** A throwaway SwiftData model that proves an `@Model` defined
/// inside this package can be registered in a host `ModelContainer` and round-trips
/// through insert/save/fetch. It is deleted once the real models (`ChatSession`,
/// `ChatMessage`, …) land in Phase 3.
@Model
public final class SpikeNote {
    public var id: UUID
    public var text: String
    public var createdAt: Date

    public init(text: String) {
        self.id = UUID()
        self.text = text
        self.createdAt = .now
    }
}

/// LlamaEngineStore — the batteries-included SwiftData layer.
///
/// Hosts register `models` in their `ModelContainer` schema; the real model set and the
/// persisting `ConversationController` arrive in Phase 3.
public enum LlamaEngineStore {
    /// The persistent models this package contributes to a host schema.
    public static let models: [any PersistentModel.Type] = [
        SpikeNote.self
    ]
}
