import Foundation
import SwiftData

/// An audit record of one tool call the model made during an assistant turn: the tool,
/// the exact arguments, and the result fed back to the model. Persisted as a cascade
/// child of `ChatMessage` so the turn inspector can show the full tool-call graph. The
/// model conversation itself replays through transient `ChatTurn`s, not these records.
@Model
public final class ToolCallRecord {
    public var id: UUID = UUID()
    /// The tool that was called (e.g. "current_datetime").
    public var toolName: String = ""
    /// The arguments the model proposed, as a JSON string (verbatim keys).
    public var arguments: String = "{}"
    /// The result content fed back to the model.
    public var result: String = ""
    /// True when the tool failed (unknown tool, invalid arguments, or a thrown error);
    /// the error message is still fed back so the model can recover.
    public var isError: Bool = false
    /// How the call was gated: "auto" (pure, auto-run), "confirmed"/"approved" (the user
    /// allowed it), "denied" (disallowed or the user declined), "invalid" (bad arguments),
    /// or "unknown" (no such tool).
    public var decision: String = "auto"
    /// Wall-clock execution time, when the tool actually ran (nil for a blocked call).
    public var durationSeconds: Double?
    public var createdAt: Date = Date.now

    /// Inverse side of `ChatMessage.toolCallRecords`.
    public var message: ChatMessage?

    public init(toolName: String, arguments: String, result: String, isError: Bool,
                decision: String = "auto", durationSeconds: Double? = nil, createdAt: Date = .now) {
        self.id = UUID()
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.decision = decision
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}
