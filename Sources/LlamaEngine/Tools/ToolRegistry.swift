import Foundation

/// How much a tool can affect the world, used to decide whether it may auto-run. Phase B
/// ships only `pure` tools (auto-run); the confirmation gate for higher tiers arrives in a
/// later phase. Ordered least-to-most privileged.
public enum ToolRiskTier: String, Sendable, Codable, CaseIterable {
    case pure       // no I/O, no side effects (e.g. current_datetime, calculator)
    case readLocal  // reads on-device data the user already granted (e.g. session RAG)
    case network    // makes an outbound request (e.g. web_search, fetch_url)
    case mutating   // changes state on the device or a server
}

/// Errors a tool raises for bad arguments or a failed run. The message is safe to feed
/// back to the model verbatim (it never leaks anything the model didn't already provide).
public enum ToolError: LocalizedError, Equatable {
    case invalidArgument(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): return message
        case .executionFailed(let message): return message
        }
    }
}

/// The outcome of running a tool, fed back to the model as a `role:"tool"` message.
/// `content` is what the model sees; `displaySummary` is a short line for the inspector.
public struct ToolResult: Sendable, Equatable {
    public var content: String
    public var displaySummary: String
    public var isError: Bool

    public init(content: String, displaySummary: String? = nil, isError: Bool = false) {
        self.content = content
        self.displaySummary = displaySummary ?? content
        self.isError = isError
    }

    /// An error result: the message is both the content the model sees and the summary.
    public static func failure(_ message: String) -> ToolResult {
        ToolResult(content: message, displaySummary: message, isError: true)
    }
}

/// A tool the model can call. Pure logic with no `@Model` capture, so it stays `Sendable`
/// and testable. The model only ever proposes a call; `execute` runs locally in the app
/// process — the server is inference-only.
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONSchema { get }
    var riskTier: ToolRiskTier { get }
    /// Rejects malformed arguments *before* execution; throw `ToolError.invalidArgument`.
    func validate(_ arguments: JSONValue) throws
    func execute(_ arguments: JSONValue) async throws -> ToolResult
}

public extension AgentTool {
    /// The specification sent to the model in the request's `tools` array.
    var spec: ToolSpec { ToolSpec(name: name, description: description, parameters: parameters) }
}

/// The set of tools available to a conversation, plus the loop safety limits. The app
/// builds one and passes it into the controller (like `WebSearchConfig`), so the engine
/// stays UserDefaults-free and the host decides which tools are enabled.
public struct ToolRegistry: Sendable {
    public var tools: [any AgentTool]
    /// Hard cap on tool rounds per user turn (defends against runaway loops).
    public var maxIterations: Int
    /// Cap on a single tool result's size before it is fed back (defends against a tool
    /// flooding the context window).
    public var maxOutputBytes: Int

    public init(tools: [any AgentTool], maxIterations: Int = 5, maxOutputBytes: Int = 8192) {
        self.tools = tools
        self.maxIterations = maxIterations
        self.maxOutputBytes = maxOutputBytes
    }

    /// The specs to advertise to the model. Empty registry ⇒ no tools sent.
    public var specs: [ToolSpec] { tools.map(\.spec) }

    public func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.name == name }
    }

    /// Validates and runs a proposed call, capping the output. Never throws: an unknown
    /// tool or a thrown error becomes an *error* `ToolResult` that is fed back to the model
    /// so it can recover, rather than aborting the turn.
    public func run(_ call: ToolCall) async -> ToolResult {
        guard let tool = tool(named: call.name) else {
            return .failure("Unknown tool: \(call.name)")
        }
        do {
            try tool.validate(call.arguments)
            var result = try await tool.execute(call.arguments)
            result.content = Self.cap(result.content, maxBytes: maxOutputBytes)
            return result
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Truncates `text` to at most `maxBytes` UTF-8 bytes on a character boundary, adding a
    /// visible marker so the model knows the result was clipped.
    static func cap(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let marker = "\n…[truncated]"
        let budget = max(0, maxBytes - marker.utf8.count)
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > budget { break }
            result.append(character)
            used += size
        }
        return result + marker
    }
}
