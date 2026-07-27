import Foundation

/// Recovers tool calls the model emitted as **text** instead of as structured `tool_calls`.
///
/// In roughly 9% of measured runs, a model writes its call as markup and the server's chat
/// template fails to convert it. The turn then arrives with `finish_reason: "stop"`, the
/// markup sitting in `content`, and an empty `tool_calls` array. A loop that treats "no tool
/// calls" as "the model is finished" reports success having done nothing at all.
///
/// Families differ in how they spell it, so several shapes are accepted:
///
/// - `<function=name><parameter=k>v</parameter></function>` and `<function=name>{json}</function>`
/// - `<tool_call>{"name":…,"arguments":{…}}</tool_call>` (Qwen); `<function_call>` likewise
/// - `[TOOL_CALLS] [{"name":…,"arguments":{…}}]` (Mistral)
/// - `<|python_tag|>{"name":…}` (Llama 3.x)
/// - a whole message that is nothing but a call object, or an array of them
///
/// **False positives are the real hazard**, since prose *about* a tool would otherwise be
/// executed as one. `knownTools` is the guard: when supplied, a recovered call whose name
/// isn't a real tool is discarded. Callers with a registry should always pass it.
///
/// Pure and `nonisolated` so the parsing is testable without a server.
public enum TextualToolCall {

    /// Opening/closing tag pairs whose body is a JSON call envelope.
    private static let envelopeTags = [
        ("<tool_call>", "</tool_call>"),
        ("<function_call>", "</function_call>"),
    ]

    /// Markers after which the remainder is a JSON call, with no closing tag.
    private static let envelopePrefixes = ["[TOOL_CALLS]", "<|python_tag|>"]

    /// Whether `content` is worth trying to recover. Cheap, because it has to run on every
    /// zero-call turn to be any use.
    public static func looksLikeMarkup(_ content: String) -> Bool {
        if content.contains("<function=") { return true }
        if envelopeTags.contains(where: { content.contains($0.0) }) { return true }
        if envelopePrefixes.contains(where: { content.contains($0) }) { return true }
        return isBareEnvelope(content)
    }

    /// Tool calls recovered from `content`, in the order they appear.
    ///
    /// - Parameter knownTools: the names the registry actually has. Anything else is
    ///   dropped. An empty set disables the check.
    public static func parse(_ content: String, knownTools: Set<String> = []) -> [ToolCall] {
        guard looksLikeMarkup(content) else { return [] }

        var calls: [ToolCall] = []
        for block in blocks(in: content) {
            for call in block.calls(startingAt: calls.count) {
                guard knownTools.isEmpty || knownTools.contains(call.name) else { continue }
                calls.append(call)
            }
        }
        return calls
    }

    /// `content` with the recovered markup removed, so the transcript shows the prose the
    /// model wrote around it rather than raw tags.
    public static func stripped(_ content: String) -> String {
        guard looksLikeMarkup(content) else { return content }
        var result = content
        for block in blocks(in: content).reversed() {
            result.replaceSubrange(block.range, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Blocks

    private struct Block {
        enum Style {
            case function(name: String)
            case envelope
        }
        let style: Style
        let body: String
        let range: Range<String.Index>

        func calls(startingAt index: Int) -> [ToolCall] {
            switch style {
            case .function(let name):
                guard !name.isEmpty else { return [] }
                return [ToolCall(id: "recovered-\(index)",
                                 name: name,
                                 arguments: TextualToolCall.arguments(from: body))]
            case .envelope:
                return TextualToolCall.envelopeCalls(body, startingAt: index)
            }
        }
    }

    private static func blocks(in content: String) -> [Block] {
        var found = functionBlocks(in: content)
        for (open, close) in envelopeTags {
            found += taggedBlocks(in: content, open: open, close: close)
        }
        for prefix in envelopePrefixes {
            found += prefixedBlocks(in: content, prefix: prefix)
        }
        if found.isEmpty, isBareEnvelope(content) {
            found.append(Block(style: .envelope, body: content,
                               range: content.startIndex..<content.endIndex))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `<function=name> … </function>`. An unterminated block still counts — the model ran
    /// out of tokens mid-call, and the arguments it did emit are usually complete.
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
            let blockEnd = close?.upperBound ?? content.endIndex

            blocks.append(Block(style: .function(name: name),
                                body: String(content[nameEnd.upperBound..<bodyEnd]),
                                range: open.lowerBound..<blockEnd))
            searchStart = blockEnd
            if searchStart >= content.endIndex { break }
        }
        return blocks
    }

    private static func taggedBlocks(in content: String, open: String, close: String) -> [Block] {
        var blocks: [Block] = []
        var searchStart = content.startIndex

        while let start = content.range(of: open, range: searchStart..<content.endIndex) {
            let end = content.range(of: close, range: start.upperBound..<content.endIndex)
            let bodyEnd = end?.lowerBound ?? content.endIndex
            let blockEnd = end?.upperBound ?? content.endIndex

            blocks.append(Block(style: .envelope,
                                body: String(content[start.upperBound..<bodyEnd]),
                                range: start.lowerBound..<blockEnd))
            searchStart = blockEnd
            if searchStart >= content.endIndex { break }
        }
        return blocks
    }

    /// A marker with no closing tag: everything after it is the payload.
    private static func prefixedBlocks(in content: String, prefix: String) -> [Block] {
        guard let start = content.range(of: prefix) else { return [] }
        return [Block(style: .envelope,
                      body: String(content[start.upperBound...]),
                      range: start.lowerBound..<content.endIndex)]
    }

    /// Whether the whole message is a call object, or an array of them, with no tags.
    /// Deliberately strict — it must be the *entire* content, or prose quoting JSON would
    /// start getting executed.
    private static func isBareEnvelope(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        return !envelopeCalls(trimmed, startingAt: 0).isEmpty
    }

    // MARK: - Envelopes

    /// Decodes `{"name":…,"arguments":{…}}`, or an array of them. Some templates spell the
    /// second key `parameters`, and some send the arguments as a JSON *string*.
    static func envelopeCalls(_ body: String, startingAt index: Int) -> [ToolCall] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }

        switch decoded {
        case .object:
            return [call(from: decoded, index: index)].compactMap { $0 }
        case .array(let elements):
            return elements.enumerated().compactMap { call(from: $1, index: index + $0) }
        default:
            return []
        }
    }

    private static func call(from value: JSONValue, index: Int) -> ToolCall? {
        guard case let .object(fields) = value,
              case let .string(name)? = fields["name"], !name.isEmpty else { return nil }

        let raw = fields["arguments"] ?? fields["parameters"] ?? .object([:])
        return ToolCall(id: "recovered-\(index)", name: name, arguments: normalised(raw))
    }

    /// Arguments sometimes arrive as a JSON *string* rather than an object.
    private static func normalised(_ value: JSONValue) -> JSONValue {
        if case .object = value { return value }
        if case let .string(text) = value,
           let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object = decoded {
            return decoded
        }
        return .object([:])
    }

    // MARK: - Parameter tags

    /// `<parameter=key>value</parameter>` children, or a bare JSON object.
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
            // Models put the value on its own line; those newlines are markup, but interior
            // whitespace is content and must survive.
            if value.hasPrefix("\n") { value.removeFirst() }
            if value.hasSuffix("\n") { value.removeLast() }

            if !key.isEmpty { parameters[key] = .string(value) }
            searchStart = close?.upperBound ?? body.endIndex
            if searchStart >= body.endIndex { break }
        }
        return parameters
    }
}
