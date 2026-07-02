import Foundation

/// Configuration for `WebSearch`, injected by the host app (which owns where these
/// settings are persisted). Replaces the engine reaching into `UserDefaults`.
public struct WebSearchConfig: Sendable {
    public var provider: WebSearch.ProviderKind
    public var searxngURL: String
    public var braveAPIKey: String
    public var tavilyAPIKey: String
    public var marginaliaAPIKey: String

    public init(provider: WebSearch.ProviderKind = .none,
                searxngURL: String = "",
                braveAPIKey: String = "",
                tavilyAPIKey: String = "",
                marginaliaAPIKey: String = "public") {
        self.provider = provider
        self.searxngURL = searxngURL
        self.braveAPIKey = braveAPIKey
        self.tavilyAPIKey = tavilyAPIKey
        self.marginaliaAPIKey = marginaliaAPIKey
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

    public enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
        case none, wikipedia, searxng, marginalia, brave, tavily
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .none: return "Off"
            case .wikipedia: return "Wikipedia"
            case .searxng: return "SearXNG"
            case .marginalia: return "Marginalia"
            case .brave: return "Brave"
            case .tavily: return "Tavily"
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

    /// Runs `query` against the provider configured in Settings, returning up to `limit`
    /// results. Throws `notConfigured` when no provider is set.
    public static func search(_ query: String, limit: Int = 8, config: WebSearchConfig) async throws -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let provider = configuredProvider(config) else { throw SearchError.notConfigured }
        return try await provider.search(trimmed, limit: limit)
    }

    /// Whether the given configuration yields a usable search provider.
    public static func isConfigured(_ config: WebSearchConfig) -> Bool {
        configuredProvider(config) != nil
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

    static func decodeTavily(_ data: Data, limit: Int) throws -> [Result] {
        let response = try JSONDecoder().decode(TavilyResponse.self, from: data)
        return response.results.prefix(limit).map {
            Result(title: ($0.title ?? $0.url), url: $0.url, snippet: $0.content ?? "")
        }
    }

    static func decodeMarginalia(_ data: Data, limit: Int) throws -> [Result] {
        let response = try JSONDecoder().decode(MarginaliaResponse.self, from: data)
        return response.results.prefix(limit).map {
            Result(title: ($0.title ?? $0.url), url: $0.url, snippet: $0.description ?? "")
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
}

/// A configured search backend.
protocol WebSearchProvider: Sendable {
    func search(_ query: String, limit: Int) async throws -> [WebSearch.Result]
}

/// A self-hosted SearXNG instance (`/search?format=json`). No API key; the user runs it.
struct SearXNGProvider: WebSearchProvider {
    let baseURL: String

    func search(_ query: String, limit: Int) async throws -> [WebSearch.Result] {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmed + "/search") else {
            throw WebSearch.SearchError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json")
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

    func search(_ query: String, limit: Int) async throws -> [WebSearch.Result] {
        guard var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search") else {
            throw WebSearch.SearchError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(limit))
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
    func search(_ query: String, limit: Int) async throws -> [WebSearch.Result] {
        guard var components = URLComponents(string: "https://en.wikipedia.org/w/api.php") else {
            throw WebSearch.SearchError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: String(limit)),
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

    func search(_ query: String, limit: Int) async throws -> [WebSearch.Result] {
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
            "max_results": limit
        ])
        let data = try await WebSearch.run(request)
        return try WebSearch.decodeTavily(data, limit: limit)
    }
}

/// Marginalia — an independent, non-commercial engine with its own index, strong on the
/// text-heavy "small web" the big engines bury. The `public` key works out of the box
/// (shared rate limit); a free personal key is available by email.
struct MarginaliaProvider: WebSearchProvider {
    let apiKey: String

    func search(_ query: String, limit: Int) async throws -> [WebSearch.Result] {
        guard var components = URLComponents(string: "https://api2.marginalia-search.com/search") else {
            throw WebSearch.SearchError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "count", value: String(limit))
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
