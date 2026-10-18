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
    /// The `num_ctx` sent with summary requests. Pass the chat's own: Ollama reloads the model
    /// whenever it changes.
    public var contextSize: Int

    /// Excerpts scoring below this fraction of the best one are left out, so a large window
    /// isn't filled with loose matches.
    public static let relevanceCutoff = 0.6
    /// The most excerpts retrieval sends for one question.
    public static let maxExcerpts = 24

    public init(client: (any ServerBackend)?,
                embedder: any EmbeddingBackend,
                chatModel: String,
                contextSize: Int = 8192) {
        self.client = client
        self.embedder = embedder
        self.chatModel = chatModel
        self.contextSize = contextSize
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
                    return try await retrieve(chunks, question: query, query: retrievalQuery ?? query,
                                              available: available, attempted: attempted, onStatus: onStatus)
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
                          question: String,
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

        // Keywords come from the question alone, so a follow-up isn't dragged toward the
        // previous answer's wording; the embedding still sees the recent turns.
        let lexical = LexicalFilter.bm25(chunks.map(\.text),
                                         paths: chunks.map(\.filePath),
                                         keywords: LexicalFilter.keywords(from: question))

        // Embed what isn't cached yet. For a large source that's only the best keyword matches,
        // so the first question doesn't wait on the whole source; cached chunks all still count.
        var working = chunks
        var newEmbeddings: [UUID: [Float]] = [:]
        let missing = LexicalFilter.narrow(lexical).filter { working[$0].embedding?.count != dimension }
        if !missing.isEmpty {
            // Embed in batches so progress can be reported for a large source (each batch is
            // still embedded in parallel internally).
            let total = missing.count
            let batchSize = 48
            var start = 0
            while start < total {
                let end = min(start + batchSize, total)
                let slice = Array(missing[start..<end])
                let vectors = try await embedder.embed(model: "",
                                                       input: slice.map { "search_document: " + working[$0].text })
                for (k, index) in slice.enumerated() {
                    working[index].embedding = vectors[k]
                    newEmbeddings[working[index].id] = vectors[k]
                }
                start = end
                await onStatus?("Embedding excerpts… \(end) of \(total)")
            }
        }

        let relevance = Self.hybridRelevance(
            semantic: working.map { chunk in
                chunk.embedding.flatMap { $0.count == dimension ? Vector.cosineSimilarity(queryVector, $0) : nil }
            },
            lexical: lexical)
        guard let best = relevance.max(), best > 0 else { throw OllamaError.server("No relevant content found.") }
        // MMR compares each pick against the whole pool, so cap it well above `maxExcerpts`.
        let pool = relevance.indices
            .filter { relevance[$0] >= Self.relevanceCutoff * best }
            .sorted { relevance[$0] > relevance[$1] }
            .prefix(100)

        // Select with Maximal Marginal Relevance so the chosen excerpts are both
        // relevant *and* diverse: MMR penalizes a candidate that duplicates what's
        // already picked, so near-identical chunks (e.g. overlapping neighbors) don't
        // crowd out other useful passages and waste the budget.
        let candidates = pool.map {
            MMRCandidate(id: working[$0].id,
                         relevance: Float(relevance[$0]),
                         embedding: working[$0].embedding ?? [],
                         tokens: TokenEstimator.estimate(working[$0].text))
        }
        let selectedIDs = Set(Self.mmrSelect(candidates, available: available, limit: Self.maxExcerpts))
        let selected = pool.filter { selectedIDs.contains(working[$0].id) }
        guard !selected.isEmpty else { throw OllamaError.server("No relevant content found.") }

        let retrieved = selected.map {
            RetrievedChunkInfo(id: working[$0].id,
                               sourceName: working[$0].displaySource,
                               ordinal: working[$0].ordinal,
                               score: Float(relevance[$0]),
                               text: working[$0].text)
        }

        let ordered = selected.map { working[$0] }.sorted { $0.ordinal < $1.ordinal }
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
            contextSize: contextSize,
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

    /// One 0–1 relevance per chunk from its meaning (`semantic`, cosine; nil when unembedded) and
    /// keywords (`lexical`, BM25), each scaled to the best chunk. Keywords lead because the
    /// on-device embedder is weak: alone it rarely ranks the answer near the top. With no keyword
    /// hits at all, meaning decides alone. Pure/testable.
    public static func hybridRelevance(semantic: [Float?], lexical: [Double],
                                       semanticWeight: Double = 0.3) -> [Double] {
        let present = semantic.compactMap { $0 }
        let low = Double(present.min() ?? 0), high = Double(present.max() ?? 0)
        let topLexical = lexical.max() ?? 0
        return semantic.indices.map { i in
            let meaning = semantic[i].map { high > low ? (Double($0) - low) / (high - low) : 1 } ?? 0
            guard topLexical > 0 else { return meaning }
            let keywords = i < lexical.count ? lexical[i] / topLexical : 0
            return semanticWeight * meaning + (1 - semanticWeight) * keywords
        }
    }

    /// Orders candidates by Maximal Marginal Relevance and returns the IDs that fit the
    /// token budget, at most `limit` of them. Each step picks the candidate maximizing
    /// `λ·relevance − (1−λ)·maxSimilarityToPicked`, so highly relevant but redundant
    /// chunks are deferred in favor of ones that add new information. Pure/testable.
    public static func mmrSelect(_ candidates: [MMRCandidate], available: Int, limit: Int = .max,
                                 lambda: Double = 0.7) -> [UUID] {
        guard available > 0, limit > 0 else { return [] }
        var remaining = candidates
        var selected: [MMRCandidate] = []
        var used = 0
        while !remaining.isEmpty, selected.count < limit {
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
