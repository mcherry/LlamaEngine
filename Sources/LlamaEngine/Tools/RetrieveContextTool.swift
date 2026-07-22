import Foundation

/// Retrieves the most relevant excerpts from the documents attached to *this chat*.
/// `readLocal` — it reads only what the user already attached, entirely on-device (the
/// embedding runs through `AppleEmbedder`, no network). The host injects a `Sendable`
/// snapshot of the session's chunks, so the tool never captures a SwiftData `@Model`.
public struct RetrieveContextTool: AgentTool {
    public var chunks: [RetrievableChunk]
    public var embedder: any EmbeddingBackend
    /// Rough token budget for the combined excerpts fed back to the model.
    public var maxTokens: Int

    public init(chunks: [RetrievableChunk] = [],
                embedder: any EmbeddingBackend = AppleEmbedder(),
                maxTokens: Int = 1500) {
        self.chunks = chunks
        self.embedder = embedder
        self.maxTokens = maxTokens
    }

    public let name = "retrieve_context"
    public let description = "Searches the documents and sources attached to this chat and returns the most relevant excerpts."
    public let riskTier: ToolRiskTier = .readLocal

    public var parameters: JSONSchema {
        .object(properties: [
            "query": .object([
                "type": .string("string"),
                "description": .string("What to look for in the attached sources.")
            ]),
            "count": .object([
                "type": .string("integer"),
                "description": .string("Maximum excerpts to return (1-8, default 4).")
            ])
        ], required: ["query"])
    }

    public func validate(_ arguments: JSONValue) throws {
        guard let query = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            throw ToolError.invalidArgument("Provide something to search for.")
        }
    }

    public func execute(_ arguments: JSONValue) async throws -> ToolResult {
        let query = (arguments.string("query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError.invalidArgument("Provide something to search for.") }
        guard !chunks.isEmpty else {
            throw ToolError.executionFailed("No documents are attached to this chat.")
        }
        let limit = min(max(arguments.int("count") ?? 4, 1), 8)

        // Embed the query, then fill in any chunk embeddings not already cached.
        guard let queryVector = try await embedder.embed(model: "", input: ["search_query: " + query]).first,
              !queryVector.isEmpty else {
            throw ToolError.executionFailed("Could not process the query.")
        }
        var vectors = chunks.map { $0.embedding ?? [] }
        let missing = vectors.enumerated().filter { $0.element.isEmpty }.map(\.offset)
        if !missing.isEmpty {
            let texts = missing.map { "search_document: " + chunks[$0].text }
            let embedded = try await embedder.embed(model: "", input: texts)
            for (position, offset) in missing.enumerated() where position < embedded.count {
                vectors[offset] = embedded[position]
            }
        }

        let ranked = chunks.indices
            .map { (index: $0, score: Vector.cosineSimilarity(queryVector, vectors[$0])) }
            .sorted { $0.score > $1.score }

        var picked: [RetrievableChunk] = []
        var usedTokens = 0
        for entry in ranked.prefix(limit) {
            let chunk = chunks[entry.index]
            let cost = TokenEstimator.estimate([chunk.text])
            if !picked.isEmpty && usedTokens + cost > maxTokens { break }
            picked.append(chunk)
            usedTokens += cost
        }
        guard !picked.isEmpty else {
            return ToolResult(content: "No relevant excerpts found in the attached sources.",
                              displaySummary: "No matches")
        }
        return ToolResult(content: Self.format(picked),
                          displaySummary: "\(picked.count) excerpt\(picked.count == 1 ? "" : "s")")
    }

    /// "[source]\nexcerpt" blocks — pure so the shape is unit-testable.
    static func format(_ chunks: [RetrievableChunk]) -> String {
        chunks.map { "[\($0.displaySource)]\n\($0.text)" }.joined(separator: "\n\n")
    }
}
