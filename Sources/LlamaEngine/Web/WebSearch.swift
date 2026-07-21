import Foundation

/// Configuration for `WebSearch`, injected by the host app (which owns where these
/// settings are persisted). Replaces the engine reaching into `UserDefaults`.
public struct WebSearchConfig: Sendable {
    public var provider: WebSearch.ProviderKind
    public var searxngURL: String
    public var braveAPIKey: String
    public var tavilyAPIKey: String
    public var exaAPIKey: String
    public var linkupAPIKey: String
    public var tinyfishAPIKey: String
    public var marginaliaAPIKey: String

    public init(provider: WebSearch.ProviderKind = .none,
                searxngURL: String = "",
                braveAPIKey: String = "",
                tavilyAPIKey: String = "",
                exaAPIKey: String = "",
                linkupAPIKey: String = "",
                tinyfishAPIKey: String = "",
                marginaliaAPIKey: String = "public") {
        self.provider = provider
        self.searxngURL = searxngURL
        self.braveAPIKey = braveAPIKey
        self.tavilyAPIKey = tavilyAPIKey
        self.exaAPIKey = exaAPIKey
        self.linkupAPIKey = linkupAPIKey
        self.tinyfishAPIKey = tinyfishAPIKey
        self.marginaliaAPIKey = marginaliaAPIKey
    }
}

/// Static pagination capabilities of a search provider — declared in code per provider
/// (not user-configurable): how many results to request per fetch, and the hard ceiling on
/// total results (`nil` = unbounded). A provider that can't paginate (e.g. Tavily) sets
/// `pageSize` equal to `maxResults`, so a single fetch returns everything and "more" is
/// never offered. Invariant: a non-nil `maxResults` is a multiple of `pageSize`.
public struct SearchCapabilities: Sendable, Equatable {
    public var pageSize: Int
    public var maxResults: Int?
    public init(pageSize: Int, maxResults: Int?) {
        self.pageSize = pageSize
        self.maxResults = maxResults
    }
}

/// Web search for context, **provider-agnostic** and using only *sanctioned* APIs — never
/// scraping a search engine's HTML (which is what gets blocked). The user picks a provider
/// in Settings: **Wikipedia** (no key) or a self-hosted **SearXNG** instance (no key); the
/// independent **Marginalia** engine (a shared `public` key, or a free personal one); or the
/// keyed **Brave** / **Tavily** APIs. Result fetching still goes through `WebAccess` (robots
/// + rate limits). The response decoders are pure, so parsing is unit-testable.
public enum WebSearch {

    public struct Result: Identifiable, Equatable, Sendable {
        public var title: String
        public var url: String
        public var snippet: String
        public var id: String { url }

        public init(title: String, url: String, snippet: String) {
            self.title = title
            self.url = url
            self.snippet = snippet
        }
    }

    /// A page of results plus whether more can be loaded and the offset to request next.
    /// Returned by ``search(_:offset:config:)`` so the caller can append pages without
    /// re-deriving pagination state.
    public struct SearchPage: Sendable {
        public let results: [Result]
        public let hasMore: Bool
        public let nextOffset: Int
        public init(results: [Result], hasMore: Bool, nextOffset: Int) {
            self.results = results
            self.hasMore = hasMore
            self.nextOffset = nextOffset
        }
    }

    public enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
        case none, wikipedia, searxng, marginalia, brave, tavily, exa, linkup, tinyfish
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .none: return "Off"
            case .wikipedia: return "Wikipedia"
            case .searxng: return "SearXNG"
            case .marginalia: return "Marginalia"
            case .brave: return "Brave"
            case .tavily: return "Tavily"
            case .exa: return "Exa"
            case .linkup: return "Linkup"
            case .tinyfish: return "TinyFish"
            }
        }

        /// Static pagination capabilities. Page size is uniform; only the ceiling differs.
        /// Tavily can't paginate (`pageSize == maxResults` → one fetch); Brave/Marginalia
        /// have API-imposed ceilings; Wikipedia/SearXNG are effectively unbounded.
        public var searchCapabilities: SearchCapabilities {
            switch self {
            case .none:       return SearchCapabilities(pageSize: 20, maxResults: 0)
            case .tavily:     return SearchCapabilities(pageSize: 20, maxResults: 20)
            case .exa:        return SearchCapabilities(pageSize: 20, maxResults: 20)
            case .linkup:     return SearchCapabilities(pageSize: 20, maxResults: 20)
            case .tinyfish:   return SearchCapabilities(pageSize: 20, maxResults: 20)
            case .brave:      return SearchCapabilities(pageSize: 20, maxResults: 200)
            case .marginalia: return SearchCapabilities(pageSize: 20, maxResults: 100)
            case .wikipedia:  return SearchCapabilities(pageSize: 20, maxResults: nil)
            case .searxng:    return SearchCapabilities(pageSize: 20, maxResults: nil)
            }
        }

        /// What credential the user must supply — drives the provider manager UI.
        public var credentialKind: WebSearch.CredentialKind {
            switch self {
            case .none, .wikipedia: return .none
            case .searxng: return .instanceURL
            case .marginalia, .brave, .tavily, .exa, .linkup, .tinyfish: return .apiKey
            }
        }

        /// A one-line description shown in the provider manager.
        public var summary: String {
            switch self {
            case .none: return ""
            case .wikipedia: return "English Wikipedia — great for history, places, and general facts. No account needed."
            case .searxng: return "A self-hosted SearXNG instance that aggregates real engines. No account needed."
            case .marginalia: return "An independent engine for text-heavy, non-commercial pages. Works out of the box with the shared “public” key."
            case .brave: return "Brave’s own independent search index, with a generous free tier."
            case .tavily: return "An LLM-focused search API with a free tier."
            case .exa: return "Neural + keyword search built for AI, with free monthly credits."
            case .linkup: return "A production web-search API for AI, with free monthly credits."
            case .tinyfish: return "Browser-rendered live search — free, and uses no credits."
            }
        }

        /// Where to get an API key (nil for keyless providers or ones without self-serve signup).
        public var signupURL: String? {
            switch self {
            case .brave: return "https://api-dashboard.search.brave.com/"
            case .tavily: return "https://app.tavily.com/"
            case .exa: return "https://dashboard.exa.ai/api-keys"
            case .linkup: return "https://app.linkup.so/"
            case .tinyfish: return "https://agent.tinyfish.ai/api-keys"
            case .none, .wikipedia, .searxng, .marginalia: return nil
            }
        }

        /// The provider’s API documentation.
        public var docsURL: String? {
            switch self {
            case .wikipedia: return "https://www.mediawiki.org/wiki/API:Search"
            case .searxng: return "https://docs.searxng.org/"
            case .marginalia: return "https://about.marginalia-search.com/article/api/"
            case .brave: return "https://api-dashboard.search.brave.com/app/documentation"
            case .tavily: return "https://docs.tavily.com/"
            case .exa: return "https://exa.ai/docs"
            case .linkup: return "https://docs.linkup.so/"
            case .tinyfish: return "https://docs.tinyfish.ai/search-api"
            case .none: return nil
            }
        }
    }

    public enum SearchError: LocalizedError {
        case notConfigured
        case http(Int)
        case transport(String)
        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No search provider is set up. Choose one in Settings → Web Search."
            case .http(let code):
                return "The search provider returned an error (HTTP \(code))."
            case .transport(let message):
                return message
            }
        }
    }

    /// Runs `query` against the configured provider, returning the page starting at
    /// `offset` (0 for the first page) plus whether more results can be loaded. The page
    /// size and ceiling come from the provider's ``ProviderKind/searchCapabilities``.
    /// Throws `notConfigured` when no provider is set.
    public static func search(_ query: String, offset: Int = 0, config: WebSearchConfig) async throws -> SearchPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchPage(results: [], hasMore: false, nextOffset: offset) }
        guard let provider = configuredProvider(config) else { throw SearchError.notConfigured }
        let caps = config.provider.searchCapabilities
        let limit = pageLimit(offset: offset, caps: caps)
        guard limit > 0 else { return SearchPage(results: [], hasMore: false, nextOffset: offset) }
        let results = try await provider.search(trimmed, limit: limit, offset: offset)
        let state = paginationState(offset: offset, returned: results.count, requested: limit, caps: caps)
        return SearchPage(results: results, hasMore: state.hasMore, nextOffset: state.nextOffset)
    }

    /// How many results to request for the page starting at `offset`, clamped so the running
    /// total never exceeds the provider's `maxResults`. Pure, for testing.
    static func pageLimit(offset: Int, caps: SearchCapabilities) -> Int {
        let remaining = caps.maxResults.map { max(0, $0 - offset) } ?? caps.pageSize
        return min(caps.pageSize, remaining)
    }

    /// Whether more results can be loaded after this page, and the offset to request next.
    /// A short page (fewer than requested) or reaching `maxResults` stops pagination. The
    /// next offset advances by the requested amount so page-based providers stay aligned
    /// even when the caller de-duplicates. Pure, for testing.
    static func paginationState(offset: Int, returned: Int, requested: Int,
                                caps: SearchCapabilities) -> (hasMore: Bool, nextOffset: Int) {
        let loaded = offset + returned
        let underMax = caps.maxResults.map { loaded < $0 } ?? true
        let fullPage = requested > 0 && returned >= requested
        return (fullPage && underMax, offset + requested)
    }

    /// Whether the given configuration yields a usable search provider.
    public static func isConfigured(_ config: WebSearchConfig) -> Bool {
        configuredProvider(config) != nil
    }

    /// Whether `provider` has the credential/URL it needs in `config` to run a search.
    /// Ignores `config.provider`, so the provider manager can show per-row readiness.
    public static func isReady(_ provider: ProviderKind, config: WebSearchConfig) -> Bool {
        var probe = config
        probe.provider = provider
        return isConfigured(probe)
    }

    /// The user-selectable providers (everything except `.none`) for the provider manager.
    public static let catalog: [ProviderKind] = ProviderKind.allCases.filter { $0 != .none }

    /// The kind of credential a provider needs — drives the provider manager’s field type.
    public enum CredentialKind: String, Sendable {
        case none, apiKey, instanceURL
    }

    /// Builds the provider from an injected `WebSearchConfig`, or nil when
    /// none/unconfigured. The host app owns where the settings live.
    static func configuredProvider(_ config: WebSearchConfig) -> WebSearchProvider? {
        switch config.provider {
        case .none:
            return nil
        case .wikipedia:
            return WikipediaProvider()
        case .searxng:
            let base = config.searxngURL.trimmingCharacters(in: .whitespaces)
            return base.isEmpty ? nil : SearXNGProvider(baseURL: base)
        case .marginalia:
            // Falls back to the shared `public` key so the provider works out of the box.
            let key = config.marginaliaAPIKey.trimmingCharacters(in: .whitespaces)
            return MarginaliaProvider(apiKey: key.isEmpty ? "public" : key)
        case .brave:
            let key = config.braveAPIKey.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : BraveProvider(apiKey: key)
        case .tavily:
            let key = config.tavilyAPIKey.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : TavilyProvider(apiKey: key)
        case .exa:
            let key = config.exaAPIKey.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : ExaProvider(apiKey: key)
        case .linkup:
            let key = config.linkupAPIKey.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : LinkupProvider(apiKey: key)
        case .tinyfish:
            let key = config.tinyfishAPIKey.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : TinyFishProvider(apiKey: key)
        }
    }

    // MARK: - Pure decoders

    static func decodeSearXNG(_ data: Data, limit: Int) throws -> [Result] {
        let response = try JSONDecoder().decode(SearXNGResponse.self, from: data)
        return response.results.prefix(limit).map {
            Result(title: ($0.title ?? $0.url), url: $0.url, snippet: $0.content ?? "")
        }
    }

    static func decodeBrave(_ data: Data, limit: Int) throws -> [Result] {
        let response = try JSONDecoder().decode(BraveResponse.self, from: data)
        return (response.web?.results ?? []).prefix(limit).map {
            Result(title: ($0.title ?? $0.url), url: $0.url, snippet: $0.description ?? "")
        }
    }

    static func decodeWikipedia(_ data: Data, limit: Int) throws -> [Result] {
        let response = try JSONDecoder().decode(WikipediaResponse.self, from: data)
        return (response.query?.search ?? []).prefix(limit).map { item in
            // Snippets arrive as HTML (with <span class="searchmatch">); run them through the
            // tested extractor to strip tags and decode entities. Build the article URL from
            // the title (spaces → underscores, percent-encoded).
            let underscored = item.title.replacingOccurrences(of: " ", with: "_")
            let path = underscored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? underscored
            return Result(title: item.title,
                          url: "https://en.wikipedia.org/wiki/\(path)",
                          snippet: HTMLExtractor.extract(item.snippet ?? "").text)
        }
    }

    static func decodeTavily(_ data: Data, limit: Int, offset: Int = 0) throws -> [Result] {
        let response = try JSONDecoder().decode(TavilyResponse.self, from: data)
        // Tavily has no offset param, so we request `offset + limit` and drop the earlier
        // ones here to emulate a page.
        return response.results.dropFirst(offset).prefix(limit).map {
            Result(title: ($0.title ?? $0.url), url: $0.url, snippet: $0.content ?? "")
        }
    }

    static func decodeMarginalia(_ data: Data, limit: Int) throws -> [Result] {
        let response = try JSONDecoder().decode(MarginaliaResponse.self, from: data)
        return response.results.prefix(limit).map {
            Result(title: ($0.title ?? $0.url), url: $0.url, snippet: $0.description ?? "")
        }
    }

    static func decodeExa(_ data: Data, limit: Int) throws -> [Result] {
        let response = try JSONDecoder().decode(ExaResponse.self, from: data)
        return response.results.prefix(limit).map { item in
            // Prefer a highlight (requested via `contents.highlights`), then a summary, then a
            // trimmed slice of the page text — whichever the response actually carries.
            let snippet = item.highlights?.first(where: { !$0.isEmpty })
                ?? item.summary
                ?? item.text.map { String($0.prefix(400)) }
                ?? ""
            return Result(title: (item.title ?? item.url), url: item.url, snippet: snippet)
        }
    }

    static func decodeLinkup(_ data: Data, limit: Int) throws -> [Result] {
        let response = try JSONDecoder().decode(LinkupResponse.self, from: data)
        return response.results.prefix(limit).map {
            Result(title: ($0.name ?? $0.url), url: $0.url, snippet: $0.content ?? "")
        }
    }

    static func decodeTinyFish(_ data: Data, limit: Int) throws -> [Result] {
        let response = try JSONDecoder().decode(TinyFishResponse.self, from: data)
        return response.results.prefix(limit).map {
            Result(title: ($0.title ?? $0.url), url: $0.url, snippet: $0.snippet ?? "")
        }
    }

    private struct SearXNGResponse: Decodable {
        let results: [Item]
        struct Item: Decodable { let url: String; let title: String?; let content: String? }
    }

    private struct BraveResponse: Decodable {
        let web: Web?
        struct Web: Decodable { let results: [Item] }
        struct Item: Decodable { let title: String?; let url: String; let description: String? }
    }

    private struct WikipediaResponse: Decodable {
        let query: Query?
        struct Query: Decodable { let search: [Item] }
        struct Item: Decodable { let title: String; let snippet: String? }
    }

    private struct TavilyResponse: Decodable {
        let results: [Item]
        struct Item: Decodable { let title: String?; let url: String; let content: String? }
    }

    private struct MarginaliaResponse: Decodable {
        let results: [Item]
        struct Item: Decodable { let url: String; let title: String?; let description: String? }
    }

    private struct ExaResponse: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let title: String?
            let url: String
            let text: String?
            let summary: String?
            let highlights: [String]?
        }
    }

    private struct LinkupResponse: Decodable {
        let results: [Item]
        struct Item: Decodable { let name: String?; let url: String; let content: String? }
    }

    private struct TinyFishResponse: Decodable {
        let results: [Item]
        struct Item: Decodable { let title: String?; let url: String; let snippet: String? }
    }
}

/// A configured search backend.
protocol WebSearchProvider: Sendable {
    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result]
}

/// A self-hosted SearXNG instance (`/search?format=json`). No API key; the user runs it.
struct SearXNGProvider: WebSearchProvider {
    let baseURL: String

    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmed + "/search") else {
            throw WebSearch.SearchError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "pageno", value: String(offset / limit + 1))
        ]
        guard let url = components.url else { throw WebSearch.SearchError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Llamatron/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await WebSearch.run(request)
        return try WebSearch.decodeSearXNG(data, limit: limit)
    }
}

/// The Brave Search API (keyed; clean JSON, generous free tier).
struct BraveProvider: WebSearchProvider {
    let apiKey: String

    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        guard var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search") else {
            throw WebSearch.SearchError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset / limit))
        ]
        guard let url = components.url else { throw WebSearch.SearchError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await WebSearch.run(request)
        return try WebSearch.decodeBrave(data, limit: limit)
    }
}

/// Wikipedia via the MediaWiki search API (`action=query&list=search`). No key needed —
/// ideal for real-world grounding (history, places, science). English Wikipedia.
struct WikipediaProvider: WebSearchProvider {
    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        guard var components = URLComponents(string: "https://en.wikipedia.org/w/api.php") else {
            throw WebSearch.SearchError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: String(limit)),
            URLQueryItem(name: "sroffset", value: String(offset)),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { throw WebSearch.SearchError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Llamatron/1.0 (macOS assistant)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await WebSearch.run(request)
        return try WebSearch.decodeWikipedia(data, limit: limit)
    }
}

/// Tavily — a search API built for LLM agents, with a free tier. POST JSON, Bearer auth.
struct TavilyProvider: WebSearchProvider {
    let apiKey: String

    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw WebSearch.SearchError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "max_results": offset + limit
        ])
        let data = try await WebSearch.run(request)
        return try WebSearch.decodeTavily(data, limit: limit, offset: offset)
    }
}

/// Marginalia — an independent, non-commercial engine with its own index, strong on the
/// text-heavy "small web" the big engines bury. The `public` key works out of the box
/// (shared rate limit); a free personal key is available by email.
struct MarginaliaProvider: WebSearchProvider {
    let apiKey: String

    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        guard var components = URLComponents(string: "https://api2.marginalia-search.com/search") else {
            throw WebSearch.SearchError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "count", value: String(limit)),
            URLQueryItem(name: "page", value: String(offset / limit + 1))
        ]
        guard let url = components.url else { throw WebSearch.SearchError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "API-Key")
        request.setValue("Llamatron/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await WebSearch.run(request)
        return try WebSearch.decodeMarginalia(data, limit: limit)
    }
}

/// Exa — a search API built for AIs (neural + keyword), POST JSON with an `x-api-key`
/// header. Requests highlights so each result carries a usable snippet. Its capabilities cap
/// results to a single fetch (like Tavily), so `offset` is always 0 and unused here.
struct ExaProvider: WebSearchProvider {
    let apiKey: String

    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        guard let url = URL(string: "https://api.exa.ai/search") else {
            throw WebSearch.SearchError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "numResults": limit,
            "contents": ["highlights": true]
        ])
        let data = try await WebSearch.run(request)
        return try WebSearch.decodeExa(data, limit: limit)
    }
}

/// Linkup — a production web-search API for AI (POST JSON, Bearer auth). Uses the
/// `searchResults` output so results carry URLs + snippets. Single page (no offset).
struct LinkupProvider: WebSearchProvider {
    let apiKey: String

    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        guard let url = URL(string: "https://api.linkup.so/v1/search") else {
            throw WebSearch.SearchError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "q": query,
            "depth": "standard",
            "outputType": "searchResults",
            "maxResults": limit
        ])
        let data = try await WebSearch.run(request)
        return try WebSearch.decodeLinkup(data, limit: limit)
    }
}

/// TinyFish — a browser-rendered search API (GET, `X-API-Key` header). Search is free and
/// uses no credits. Single page here (its `page` param is left at the default).
struct TinyFishProvider: WebSearchProvider {
    let apiKey: String

    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        guard var components = URLComponents(string: "https://api.search.tinyfish.ai") else {
            throw WebSearch.SearchError.notConfigured
        }
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components.url else { throw WebSearch.SearchError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await WebSearch.run(request)
        return try WebSearch.decodeTinyFish(data, limit: limit)
    }
}

extension WebSearch {
    /// Shared request runner with HTTP/transport error mapping.
    static func run(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SearchError.http(http.statusCode)
            }
            return data
        } catch let error as SearchError {
            throw error
        } catch {
            throw SearchError.transport(error.localizedDescription)
        }
    }
}
