import Foundation
import SwiftData

/// A saved, reusable system prompt for the prompt library. Users save the current
/// session's system prompt as a named preset and apply it to any session.
@Model
public final class PromptPreset {
    public var id: UUID = UUID()
    public var name: String = ""
    public var content: String = ""
    public var createdAt: Date = Date.now

    public init(name: String, content: String) {
        self.id = UUID()
        self.name = name
        self.content = content
        self.createdAt = .now
    }
}
