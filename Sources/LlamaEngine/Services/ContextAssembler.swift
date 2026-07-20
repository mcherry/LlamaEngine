import Foundation

/// A chunk handed to the assembler. A plain `Sendable` value (never a SwiftData
/// `@Model`), so it can cross actor boundaries safely. `id` lets the caller write a
/// freshly computed embedding back to the persistent chunk.
public struct RetrievableChunk: Sendable {
    public let id: UUID
    public let sourceName: String
    /// Global order across all attachments, for readable assembly.
    public let ordinal: Int
    public let text: String
    public var embedding: [Float]?
    /// Relative file path (for directory sources) used for path-aware lexical matching and
    /// inspector labels. `nil` for single-file, pasted, or web attachments.
    public let filePath: String?

    public init(id: UUID, sourceName: String, ordinal: Int, text: String, embedding: [Float]? = nil, filePath: String? = nil) {
        self.id = id
        self.sourceName = sourceName
        self.ordinal = ordinal
        self.text = text
        self.embedding = embedding
        self.filePath = filePath
    }

    /// The label shown to the model and the user: the file path for directory sources,
    /// otherwise the attachment name. Lets the model cite the exact file an excerpt is from.
    public var displaySource: String { filePath ?? sourceName }
}

/// A retrieved chunk plus its relevance score, for the retrieval inspector. A plain
/// `Codable`/`Sendable` value persisted (encoded) on the assistant message.
public struct RetrievedChunkInfo: Codable, Sendable, Identifiable {
    public var id: UUID
    public var sourceName: String
    public var ordinal: Int
    public var score: Float
    public var text: String

    public init(id: UUID, sourceName: String, ordinal: Int, score: Float, text: String) {
        self.id = id
        self.sourceName = sourceName
        self.ordinal = ordinal
        self.score = score
        self.text = text
    }
}

/// The result of assembling context: the text block to inject, which strategy won,
/// the sources used, any newly computed embeddings to persist, and a short note for
/// the UI. All `Sendable`.
public struct AssembledContext: Sendable {
    public var contextText: String
    public var strategyUsed: ContextStrategy
    public var sourceLabels: [String]
    public var newEmbeddings: [UUID: [Float]]
    public var note: String?
    public var attempted: [ContextStrategy]
    /// Per-chunk relevance scores when the retrieval strategy ran; empty otherwise.
    public var retrieved: [RetrievedChunkInfo] = []
}

/// Runs the strategy ladder produced by `ContextPlanner`: it tries each strategy in
/// order and falls through to the next on failure (e.g. the embedding endpoint is
/// down → drop from retrieval to summarize to truncate), so it always yields
/// *something* usable. Operates purely on `Sendable` values and a `ServerBackend`
/// (Ollama or llama.cpp), so it embeds and summarizes against whichever server the
/// session uses.
public struct ContextAssembler: Sendable {
    /// The chat backend, reused for map-reduce summarization. Optional because retrieval
    /// (via the injected embedder) and inline/truncate need no server, so a session with
    /// no server (Apple-only) can still assemble context — summarize just won't run.
    public var client: (any ServerBackend)?
    /// Produces embeddings for the retrieval strategy. On-device by default, so retrieval
    /// works regardless of which chat backend the session uses.
    public var embedder: any EmbeddingBackend
    /// The session's chat model, reused for map-reduce summarization.
    public var chatModel: String

    public init(client: (any ServerBackend)?,
                embedder: any EmbeddingBackend,
                chatModel: String) {
        self.client = client
        self.embedder = embedder
        self.chatModel = chatModel
    }

    public func assemble(chunks: [RetrievableChunk],
                  query: String,
                  available: Int,
                  plan: [ContextStrategy],
                  retrievalQuery: String? = nil,
                  onStatus: (@Sendable (String) async -> Void)? = nil) async -> AssembledContext? {
        guard !chunks.isEmpty, !plan.isEmpty, available > 0 else { return nil }

        var attempted: [ContextStrategy] = []
        for strategy in plan {
            attempted.append(strategy)
            do {
                switch strategy {
                case .inline:
                    return inline(chunks, attempted: attempted)
                case .truncate:
                    return truncate(chunks, available: available, attempted: attempted)
                case .retrieval:
                    return try await retrieve(chunks, query: retrievalQuery ?? query, available: available, attempted: attempted, onStatus: onStatus)
                case .summarize:
                    return try await summarize(chunks, query: query, available: available, attempted: attempted, onStatus: onStatus)
                }
            } catch is CancellationError {
                return nil
            } catch {
                continue // graceful fallback to the next strategy
            }
        }
        return nil
    }

    // MARK: - Strategies

    private func inline(_ chunks: [RetrievableChunk], attempted: [ContextStrategy]) -> AssembledContext {
        let ordered = chunks.sorted { $0.ordinal < $1.ordinal }
        return AssembledContext(
            contextText: render(ordered),
            strategyUsed: .inline,
            sourceLabels: labels(for: ordered),
            newEmbeddings: [:],
            note: nil,
            attempted: attempted
        )
    }

    private func truncate(_ chunks: [RetrievableChunk], available: Int, attempted: [ContextStrategy]) -> AssembledContext {
        let ordered = chunks.sorted { $0.ordinal < $1.ordinal }
        let joined = ordered.map(\.text).joined(separator: "\n\n")
        let clipped = TextTruncator.truncate(joined, toTokens: available)
        return AssembledContext(
            contextText: clipped,
            strategyUsed: .truncate,
            sourceLabels: labels(for: ordered),
            newEmbeddings: [:],
            note: "Content was truncated to fit the context budget.",
            attempted: attempted
        )
    }

    private func retrieve(_ chunks: [RetrievableChunk],
                          query: String,
                          available: Int,
                          attempted: [ContextStrategy],
                          onStatus: (@Sendable (String) async -> Void)? = nil) async throws -> AssembledContext {
        // Embed the query first so we know the embedder's vector dimension. A cached chunk
        // vector of a different length was produced by a different embedder and can't be
        // compared, so it's treated as missing and recomputed. (Task prefixes are a server-
        // embedder convention; the on-device embedder strips them.)
        let queryVector = try await embedder.embed(model: "",
                                                  input: ["search_query: " + query]).first ?? []
        guard !queryVector.isEmpty else { throw OllamaError.server("Empty query embedding.") }
        let dimension = queryVector.count

        // Stage 1 — lexical pre-filter: narrow to candidates before the costly embedding of
        // missing chunks. Only engages for large sets with enough keyword matches; small docs
        // and synonym-only queries fall through to full semantic retrieval over everything.
        let keywords = LexicalFilter.keywords(from: query)
        let kept = LexicalFilter.narrow(chunks.map(\.text),
                                        paths: chunks.map(\.filePath),
                                        keywords: keywords)
        var working = kept.count == chunks.count ? chunks : kept.map { chunks[$0] }
        var newEmbeddings: [UUID: [Float]] = [:]
        let missing = working.enumerated().filter { $0.element.embedding?.count != dimension }
        if !missing.isEmpty {
            // Embed in batches so progress can be reported for a large source (each batch is
            // still embedded in parallel internally). Cached chunks are skipped, so repeat
            // queries stay cheap.
            let total = missing.count
            let batchSize = 48
            var start = 0
            while start < total {
                let end = min(start + batchSize, total)
                let slice = Array(missing[start..<end])
                let vectors = try await embedder.embed(model: "",
                                                       input: slice.map { "search_document: " + $0.element.text })
                for (k, item) in slice.enumerated() {
                    working[item.offset].embedding = vectors[k]
                    newEmbeddings[item.element.id] = vectors[k]
                }
                start = end
                await onStatus?("Embedding excerpts… \(end) of \(total)")
            }
        }

        let scored = working.compactMap { chunk -> (chunk: RetrievableChunk, score: Float)? in
            guard let embedding = chunk.embedding else { return nil }
            return (chunk, Vector.cosineSimilarity(queryVector, embedding))
        }.sorted { $0.score > $1.score }

        // Select with Maximal Marginal Relevance so the chosen excerpts are both
        // relevant *and* diverse: MMR penalizes a candidate that duplicates what's
        // already picked, so near-identical chunks (e.g. overlapping neighbors) don't
        // crowd out other useful passages and waste the budget.
        let candidates = scored.map {
            MMRCandidate(id: $0.chunk.id,
                         relevance: $0.score,
                         embedding: $0.chunk.embedding ?? [],
                         tokens: TokenEstimator.estimate($0.chunk.text))
        }
        let selectedIDs = Self.mmrSelect(candidates, available: available)
        let byID = Dictionary(working.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = selectedIDs.compactMap { byID[$0] }
        guard !selected.isEmpty else { throw OllamaError.server("No relevant content found.") }

        let selectedSet = Set(selectedIDs)
        let retrieved = scored
            .filter { selectedSet.contains($0.chunk.id) }
            .map { RetrievedChunkInfo(id: $0.chunk.id,
                                     sourceName: $0.chunk.displaySource,
                                     ordinal: $0.chunk.ordinal,
                                     score: $0.score,
                                     text: $0.chunk.text) }

        let ordered = selected.sorted { $0.ordinal < $1.ordinal }
        return AssembledContext(
            contextText: render(ordered),
            strategyUsed: .retrieval,
            sourceLabels: labels(for: ordered),
            newEmbeddings: newEmbeddings,
            note: "Using \(selected.count) of \(chunks.count) excerpts most relevant to your question.",
            attempted: attempted,
            retrieved: retrieved
        )
    }

    private func summarize(_ chunks: [RetrievableChunk],
                           query: String,
                           available: Int,
                           attempted: [ContextStrategy],
                           onStatus: (@Sendable (String) async -> Void)? = nil) async throws -> AssembledContext {
        // Map: summarize each chunk with the task in view. Run a bounded number of
        // summaries concurrently so a many-chunk document doesn't take N sequential
        // round-trips, while capping load on the server.
        let ordered = chunks.sorted { $0.ordinal < $1.ordinal }
        let summaries = try await mapSummaries(ordered, query: query, onStatus: onStatus)

        // Reduce: collapse the summaries until they fit (bounded iterations).
        var combined = summaries.joined(separator: "\n\n")
        var iterations = 0
        while TokenEstimator.estimate(combined) > available, iterations < 3, summaries.count > 1 {
            await onStatus?("Combining summaries…")
            combined = try await summarizeOne(combined, query: query)
            iterations += 1
        }
        if TokenEstimator.estimate(combined) > available {
            combined = TextTruncator.truncate(combined, toTokens: available)
        }

        return AssembledContext(
            contextText: combined,
            strategyUsed: .summarize,
            sourceLabels: labels(for: chunks),
            newEmbeddings: [:],
            note: "Summarized \(chunks.count) sections of the attached content.",
            attempted: attempted
        )
    }

    private func summarizeOne(_ text: String, query: String) async throws -> String {
        guard let client else { throw OllamaError.server("Summarization needs a chat server.") }
        let system = "You compress documents so they can be used to answer a question later. Summarize the text, preserving facts, names, numbers, and anything relevant to the user's task. Be concise and output only the summary."
        let user = "User's task: \(query)\n\nText:\n\(text)\n\nSummary:"
        let request = ChatRequest(
            model: chatModel,
            messages: [
                ChatTurn(role: Role.system.rawValue, content: system),
                ChatTurn(role: Role.user.rawValue, content: user)
            ],
            contextSize: 8192,
            stream: false,
            numPredict: 512,
            think: false
        )
        var output = ""
        for try await chunk in client.chat(request) {
            output += chunk.contentDelta
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OllamaError.server("Empty summary.") }
        return trimmed
    }

    // MARK: - Rendering

    private func render(_ chunks: [RetrievableChunk]) -> String {
        chunks.map { "[\($0.displaySource)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    private func labels(for chunks: [RetrievableChunk]) -> [String] {
        Array(Set(chunks.map(\.displaySource))).sorted()
    }

    /// Summarizes chunks with bounded concurrency, preserving input order. Keeps at
    /// most `maxConcurrent` summary calls in flight so a large document is summarized
    /// quickly without overwhelming the server.
    private func mapSummaries(_ chunks: [RetrievableChunk], query: String,
                              onStatus: (@Sendable (String) async -> Void)? = nil) async throws -> [String] {
        let maxConcurrent = 4
        let total = chunks.count
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var results = [String](repeating: "", count: total)
            var next = 0
            var completed = 0
            for _ in 0..<min(maxConcurrent, total) {
                let i = next; next += 1
                group.addTask { (i, try await summarizeOne(chunks[i].text, query: query)) }
            }
            while let (index, summary) = try await group.next() {
                results[index] = summary
                completed += 1
                await onStatus?("Summarizing sections… \(completed) of \(total)")
                if next < total {
                    let i = next; next += 1
                    group.addTask { (i, try await summarizeOne(chunks[i].text, query: query)) }
                }
            }
            return results
        }
    }
}

// MARK: - Maximal Marginal Relevance

/// A retrieval candidate for MMR selection: its relevance to the query, its embedding
/// (to measure redundancy against already-picked items), and its token cost.
public struct MMRCandidate: Sendable {
    public let id: UUID
    public let relevance: Float
    public let embedding: [Float]
    public let tokens: Int

    public init(id: UUID, relevance: Float, embedding: [Float], tokens: Int) {
        self.id = id
        self.relevance = relevance
        self.embedding = embedding
        self.tokens = tokens
    }
}

extension ContextAssembler {
    /// Builds the text used to *retrieve* document chunks: the current question plus a
    /// short tail of recent turns. This lets context-dependent follow-ups ("what about
    /// the second one?") retrieve using the surrounding conversation instead of an
    /// under-specified query. Only affects retrieval scoring, not the prompt. Pure.
    public static func enrichedRetrievalQuery(current: String,
                                       recentTurns: [String],
                                       keepTurns: Int = 2,
                                       maxRecentChars: Int = 500) -> String {
        let tail = recentTurns.suffix(keepTurns)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return current }
        return String(tail.suffix(maxRecentChars)) + "\n" + current
    }

    /// Orders candidates by Maximal Marginal Relevance and returns the IDs that fit the
    /// token budget. Each step picks the candidate maximizing
    /// `λ·relevance − (1−λ)·maxSimilarityToPicked`, so highly relevant but redundant
    /// chunks are deferred in favor of ones that add new information. Pure/testable.
    public static func mmrSelect(_ candidates: [MMRCandidate], available: Int, lambda: Double = 0.7) -> [UUID] {
        guard available > 0 else { return [] }
        var remaining = candidates
        var selected: [MMRCandidate] = []
        var used = 0
        while !remaining.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.greatestFiniteMagnitude
            for (index, candidate) in remaining.enumerated() {
                let redundancy = selected
                    .map { Double(Vector.cosineSimilarity(candidate.embedding, $0.embedding)) }
                    .max() ?? 0
                let score = lambda * Double(candidate.relevance) - (1 - lambda) * redundancy
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            let chosen = remaining.remove(at: bestIndex)
            if !selected.isEmpty, used + chosen.tokens > available { break }
            selected.append(chosen)
            used += chosen.tokens
            if used >= available { break }
        }
        return selected.map(\.id)
    }
}
