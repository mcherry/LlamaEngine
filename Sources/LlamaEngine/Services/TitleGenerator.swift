import Foundation

/// Generates a short session title from the first exchange using the session's own
/// model. Best-effort and cancellable: it never blocks the chat, and a failure just
/// leaves the existing title in place.
public enum TitleGenerator {
    public static func generate(model: String,
                         userMessage: String,
                         assistantReply: String,
                         client: ChatStreaming) async -> String? {
        let system = "You write short conversation titles. Reply with only a 3 to 6 word title. No quotes, no punctuation, no preamble, no thinking."
        let trimmedReply = String(assistantReply.prefix(500))
        let user = "First user message:\n\(userMessage)\n\nAssistant reply:\n\(trimmedReply)\n\nTitle:"

        let request = ChatRequest(
            model: model,
            messages: [
                ChatTurn(role: Role.system.rawValue, content: system),
                ChatTurn(role: Role.user.rawValue, content: user)
            ],
            contextSize: 4096,
            stream: false,
            // Generous budget so a thinking model can finish reasoning *and* still
            // emit the title; with a tiny budget it spends everything on hidden
            // reasoning and the reply's `content` comes back empty.
            numPredict: 1024,
            // Ask models that support it to skip reasoning entirely (fast, clean
            // titles). Always-thinking models ignore this, hence the budget above.
            think: false
        )

        do {
            var full = ""
            for try await chunk in client.chat(request) {
                full += chunk.contentDelta
            }
            // nil if the model produced nothing usable (e.g. a thinking model that
            // ran out of budget). The caller leaves the title auto and retries on a
            // later turn rather than falling back to the raw prompt text.
            return clean(full)
        } catch {
            return nil
        }
    }

    /// Trims the raw model output down to a clean title. Pure, so it is unit-tested:
    /// strips `<think>` reasoning, keeps the first non-empty line, removes wrapping
    /// quotes and trailing punctuation, and caps the length.
    public static func clean(_ raw: String) -> String? {
        var text = stripThink(raw).trimmingCharacters(in: .whitespacesAndNewlines)

        text = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        return capWords(text)
    }

    /// Removes `<think>…</think>` reasoning blocks, including a trailing unclosed one.
    private static func stripThink(_ raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<think>"),
              let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let open = text.range(of: "<think>") {
            text.removeSubrange(open.lowerBound..<text.endIndex)
        }
        return text
    }

    private static func capWords(_ text: String, max: Int = 8) -> String {
        let words = text.split(separator: " ")
        guard words.count > max else { return text }
        return words.prefix(max).joined(separator: " ")
    }
}
