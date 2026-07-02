import Foundation

/// One conversation turn as a plain `Sendable` value (never a SwiftData `@Model`),
/// so history management can run across actor boundaries. `id` lets the caller write a
/// freshly computed embedding back to the persistent message.
public struct HistoryTurn: Sendable, Equatable {
    public let id: UUID
    public let role: String          // Role.user / Role.assistant raw value
    public let content: String
    public let createdAt: Date
    public var embedding: [Float]?

    public init(id: UUID, role: String, content: String, createdAt: Date, embedding: [Float]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.embedding = embedding
    }
}

/// Pure, synchronous helpers for fitting conversation history into a token budget.
/// The model-dependent strategies (summarize, retrieve) live in the view model; the
/// token math and turn selection here are unit-tested without a server.
public enum ConversationHistory {
    /// Estimated token cost of a list of turns.
    public static func tokenCount(_ turns: [HistoryTurn]) -> Int {
        turns.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
    }

    /// Whether the whole history fits in `budget` tokens.
    public static func fits(_ turns: [HistoryTurn], budget: Int) -> Bool {
        tokenCount(turns) <= budget
    }

    /// Splits turns into (older, recent) keeping the last `keepRecent` as recent.
    public static func splitRecent(_ turns: [HistoryTurn], keepRecent: Int) -> (older: [HistoryTurn], recent: [HistoryTurn]) {
        guard turns.count > keepRecent else { return ([], turns) }
        let cut = turns.count - keepRecent
        return (Array(turns[..<cut]), Array(turns[cut...]))
    }

    /// Keeps the newest turns that fit in `budget`, dropping from the oldest. The very
    /// last turn (the new user message) is always kept even if it alone exceeds budget.
    public static func truncateToFit(_ turns: [HistoryTurn], budget: Int) -> (kept: [HistoryTurn], dropped: Int) {
        guard !turns.isEmpty else { return ([], 0) }
        var kept: [HistoryTurn] = []
        var used = 0
        for turn in turns.reversed() {
            let cost = TokenEstimator.estimate(turn.content)
            if kept.isEmpty || used + cost <= budget {
                kept.append(turn)
                used += cost
            } else {
                break
            }
        }
        kept.reverse()
        return (kept, turns.count - kept.count)
    }
}
