import Foundation

/// Computes how many tokens are free for injected document context after reserving
/// room for the system prompt, conversation history, the new user message, and the
/// model's reply. Pure, so it is unit-tested.
public struct ContextBudget {
    public var contextSize: Int
    public var systemTokens: Int
    public var historyTokens: Int
    public var userTokens: Int

    public init(contextSize: Int, systemTokens: Int, historyTokens: Int, userTokens: Int) {
        self.contextSize = contextSize
        self.systemTokens = systemTokens
        self.historyTokens = historyTokens
        self.userTokens = userTokens
    }

    /// Tokens kept in reserve for the model's reply: a quarter of the window, bounded
    /// so tiny windows still leave something and large ones keep real room. The cap is
    /// generous because reasoning models emit a long "thinking" pass *before* the
    /// answer — too small a reserve and the reply gets truncated mid-sentence.
    public var responseReserve: Int {
        max(1024, min(8192, contextSize / 4))
    }

    /// We estimate tokens at ~4 characters each, but real tokenization of dense or
    /// technical text runs higher (closer to 3 chars/token), so a document can occupy
    /// far more of the window than the estimate suggests. We therefore fill only this
    /// fraction of the free space with injected context, leaving slack so the prompt
    /// doesn't overflow once the server tokenizes it for real. Errs toward reliability.
    public static let safetyFraction = 0.75

    /// Tokens left for injected document context (never negative), after reserving the
    /// reply and applying the estimate-undercount safety margin.
    public var availableForContext: Int {
        let used = systemTokens + historyTokens + userTokens + responseReserve
        let free = max(0, contextSize - used)
        return Int((Double(free) * Self.safetyFraction).rounded(.down))
    }
}
