import Foundation

/// Recovers tool calls the model emitted as **text** instead of as structured `tool_calls`.
///
/// In roughly 9% of measured runs, a model writes its call as markup —
/// `<function=read_file><parameter=path>main.swift</parameter></function>` — and the
/// server's chat template fails to convert it. The turn then arrives with
/// `finish_reason: "stop"`, the markup sitting in `content`, and an empty `tool_calls`
/// array. A loop that treats "no tool calls" as "the model is finished" reports success
/// having done nothing at all.
///
/// This is invisible without looking for it, and presents to the user as "the agent
/// randomly does nothing", so the loop scans zero-call turns rather than trusting them.
///
/// Pure and `nonisolated` so the parsing is testable without a server.
public enum TextualToolCall {

    /// Whether `content` contains markup worth trying to recover. Cheap enough to run on
    /// every zero-call turn.
    public static func looksLikeMarkup(_ content: String) -> Bool {
        content.contains("<function=") || content.contains("<tool_call>")
    }

    /// Tool calls recovered from `content`, in the order they appear. Empty when there's
    /// nothing to recover.
    public static func parse(_ content: String) -> [ToolCall] {
        guard looksLikeMarkup(content) else { return [] }

        var calls: [ToolCall] = []
        for block in blocks(in: content) {
            switch block.style {
            case .function:
                guard !block.name.isEmpty else { continue }
                calls.append(ToolCall(id: "recovered-\(calls.count)",
                                      name: block.name,
                                      arguments: arguments(from: block.body)))
            case .toolCall:
                guard let call = toolCallEnvelope(block.body, index: calls.count) else { continue }
                calls.append(call)
            }
        }
        return calls
    }

    /// `content` with the recovered markup removed, so the transcript shows whatever prose
    /// the model wrote around it rather than raw tags.
    public static func stripped(_ content: String) -> String {
        guard looksLikeMarkup(content) else { return content }
        var result = content
        for block in blocks(in: content).reversed() {
            result.replaceSubrange(block.range, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Scanning

    private struct Block {
        enum Style { case function, toolCall }
        let style: Style
        let name: String
        let body: String
        let range: Range<String.Index>
    }

    /// Finds each recoverable region, in document order. Two shapes appear in practice:
    /// `<function=name> … </function>` and Qwen's `<tool_call>{json}</tool_call>`.
    ///
    /// An unterminated block still counts — the model ran out of tokens mid-call, and the
    /// arguments it did emit are usually complete.
    private static func blocks(in content: String) -> [Block] {
        (functionBlocks(in: content) + toolCallBlocks(in: content))
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func functionBlocks(in content: String) -> [Block] {
        var blocks: [Block] = []
        var searchStart = content.startIndex

        while let open = content.range(of: "<function=", range: searchStart..<content.endIndex) {
            guard let nameEnd = content.range(of: ">", range: open.upperBound..<content.endIndex) else {
                break
            }
            let name = String(content[open.upperBound..<nameEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let close = content.range(of: "</function>", range: nameEnd.upperBound..<content.endIndex)
            let bodyEnd = close?.lowerBound ?? content.endIndex
            let body = String(content[nameEnd.upperBound..<bodyEnd])
            let blockEnd = close?.upperBound ?? content.endIndex

            blocks.append(Block(style: .function, name: name, body: body,
                                range: open.lowerBound..<blockEnd))
            searchStart = blockEnd
            if searchStart >= content.endIndex { break }
        }
        return blocks
    }

    private static func toolCallBlocks(in content: String) -> [Block] {
        var blocks: [Block] = []
        var searchStart = content.startIndex

        while let open = content.range(of: "<tool_call>", range: searchStart..<content.endIndex) {
            let close = content.range(of: "</tool_call>", range: open.upperBound..<content.endIndex)
            let bodyEnd = close?.lowerBound ?? content.endIndex
            let body = String(content[open.upperBound..<bodyEnd])
            let blockEnd = close?.upperBound ?? content.endIndex

            blocks.append(Block(style: .toolCall, name: "", body: body,
                                range: open.lowerBound..<blockEnd))
            searchStart = blockEnd
            if searchStart >= content.endIndex { break }
        }
        return blocks
    }

    /// `{"name": "read_file", "arguments": {…}}` — the payload inside a `<tool_call>` tag.
    /// Some templates spell the second key `parameters`.
    private static func toolCallEnvelope(_ body: String, index: Int) -> ToolCall? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(fields) = decoded,
              case let .string(name)? = fields["name"], !name.isEmpty else { return nil }

        let arguments = fields["arguments"] ?? fields["parameters"] ?? .object([:])
        return ToolCall(id: "recovered-\(index)",
                        name: name,
                        arguments: arguments.objectValue == nil ? .object([:]) : arguments)
    }

    // MARK: - Arguments

    /// Arguments come in two shapes: `<parameter=key>value</parameter>` children, or a bare
    /// JSON object. Both are seen in practice, so both are accepted.
    private static func arguments(from body: String) -> JSONValue {
        let parameters = parseParameters(body)
        if !parameters.isEmpty { return .object(parameters) }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object = decoded {
            return decoded
        }
        return .object([:])
    }

    private static func parseParameters(_ body: String) -> [String: JSONValue] {
        var parameters: [String: JSONValue] = [:]
        var searchStart = body.startIndex

        while let open = body.range(of: "<parameter=", range: searchStart..<body.endIndex) {
            guard let nameEnd = body.range(of: ">", range: open.upperBound..<body.endIndex) else { break }
            let key = String(body[open.upperBound..<nameEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let close = body.range(of: "</parameter>", range: nameEnd.upperBound..<body.endIndex)
            let valueEnd = close?.lowerBound ?? body.endIndex
            var value = String(body[nameEnd.upperBound..<valueEnd])
            // Models put the value on its own line; the surrounding newlines are markup,
            // but interior whitespace is content and must survive.
            if value.hasPrefix("\n") { value.removeFirst() }
            if value.hasSuffix("\n") { value.removeLast() }

            if !key.isEmpty { parameters[key] = .string(value) }
            searchStart = close?.upperBound ?? body.endIndex
            if searchStart >= body.endIndex { break }
        }
        return parameters
    }
}
