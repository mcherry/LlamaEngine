import Foundation

/// Searches the web via the app's configured provider. `network`. Wraps `WebSearch.search`,
/// which uses sanctioned provider APIs that are already rate-limited and cooldown-gated, so
/// the tool adds no new fetching surface. Returns result titles, URLs, and snippets — never
/// page contents (that is `fetch_url`). The host injects the `WebSearchConfig` (provider +
/// keys), keeping the engine UserDefaults-free.
public struct WebSearchTool: AgentTool {
    public var config: WebSearchConfig

    public init(config: WebSearchConfig = WebSearchConfig()) {
        self.config = config
    }

    public let name = "web_search"
    public let description = "Searches the web and returns result titles, URLs, and snippets. Use it for current events or facts you are unsure about."
    public let riskTier: ToolRiskTier = .network

    public var parameters: JSONSchema {
        .object(properties: [
            "query": .object([
                "type": .string("string"),
                "description": .string("The search query.")
            ]),
            "count": .object([
                "type": .string("integer"),
                "description": .string("How many results to return (1-10, default 5).")
            ])
        ], required: ["query"])
    }

    public func validate(_ arguments: JSONValue) throws {
        guard let query = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            throw ToolError.invalidArgument("Provide a search query.")
        }
    }

    public func execute(_ arguments: JSONValue) async throws -> ToolResult {
        let query = (arguments.string("query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError.invalidArgument("Provide a search query.") }
        guard WebSearch.isConfigured(config) else {
            throw ToolError.executionFailed("Web search is not set up. Choose a provider in Settings.")
        }
        let limit = min(max(arguments.int("count") ?? 5, 1), 10)
        let page = try await WebSearch.search(query, config: config)
        let results = Array(page.results.prefix(limit))
        guard !results.isEmpty else {
            return ToolResult(content: "No results for \"\(query)\".", displaySummary: "No results")
        }
        return ToolResult(content: Self.format(results),
                          displaySummary: "\(results.count) result\(results.count == 1 ? "" : "s") for \"\(query)\"")
    }

    /// Numbered "title / url / snippet" list — pure so the shape is unit-testable.
    static func format(_ results: [WebSearch.Result]) -> String {
        results.enumerated().map { index, result in
            var lines = ["\(index + 1). \(result.title)", "   \(result.url)"]
            if !result.snippet.isEmpty { lines.append("   \(result.snippet)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
