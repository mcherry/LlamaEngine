import XCTest
@testable import LlamaEngine

final class WebSearchTests: XCTestCase {

    func testDecodeSearXNGRespectsLimitAndFields() throws {
        let json = """
        {"results":[
          {"url":"https://a.com","title":"A","content":"snip a"},
          {"url":"https://b.com","title":"B","content":"snip b"},
          {"url":"https://c.com","title":"C","content":"snip c"}
        ]}
        """
        let results = try WebSearch.decodeSearXNG(Data(json.utf8), limit: 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "A")
        XCTAssertEqual(results[0].url, "https://a.com")
        XCTAssertEqual(results[0].snippet, "snip a")
    }

    func testDecodeSearXNGTitleFallsBackToURL() throws {
        let results = try WebSearch.decodeSearXNG(Data(#"{"results":[{"url":"https://a.com"}]}"#.utf8), limit: 5)
        XCTAssertEqual(results.first?.title, "https://a.com")
        XCTAssertEqual(results.first?.snippet, "")
    }

    func testDecodeBrave() throws {
        let json = #"{"web":{"results":[{"title":"A","url":"https://a.com","description":"snip a"}]}}"#
        let results = try WebSearch.decodeBrave(Data(json.utf8), limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "A")
        XCTAssertEqual(results[0].snippet, "snip a")
    }

    func testDecodeBraveMissingWebReturnsEmpty() throws {
        XCTAssertTrue(try WebSearch.decodeBrave(Data("{}".utf8), limit: 5).isEmpty)
    }

    func testDecodeWikipediaBuildsURLAndStripsSnippetHTML() throws {
        let json = #"{"query":{"search":[{"title":"Linear B","snippet":"<span class=\"searchmatch\">Linear</span> B &amp; scripts","pageid":1},{"title":"Other","snippet":"x","pageid":2}]}}"#
        let results = try WebSearch.decodeWikipedia(Data(json.utf8), limit: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Linear B")
        XCTAssertEqual(results[0].url, "https://en.wikipedia.org/wiki/Linear_B")
        XCTAssertEqual(results[0].snippet, "Linear B & scripts")
    }

    func testDecodeWikipediaMissingQueryReturnsEmpty() throws {
        XCTAssertTrue(try WebSearch.decodeWikipedia(Data("{}".utf8), limit: 5).isEmpty)
    }

    func testDecodeTavily() throws {
        let json = #"{"query":"q","results":[{"title":"A","url":"https://a.com","content":"snip a","score":0.9}]}"#
        let results = try WebSearch.decodeTavily(Data(json.utf8), limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "A")
        XCTAssertEqual(results[0].url, "https://a.com")
        XCTAssertEqual(results[0].snippet, "snip a")
    }

    func testDecodeTavilyTitleFallsBackToURL() throws {
        let results = try WebSearch.decodeTavily(Data(#"{"results":[{"url":"https://a.com"}]}"#.utf8), limit: 5)
        XCTAssertEqual(results.first?.title, "https://a.com")
        XCTAssertEqual(results.first?.snippet, "")
    }

    func testDecodeMarginalia() throws {
        let json = #"{"query":"q","license":"CC","results":[{"url":"https://a.com","title":"A","description":"snip a"}]}"#
        let results = try WebSearch.decodeMarginalia(Data(json.utf8), limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "A")
        XCTAssertEqual(results[0].url, "https://a.com")
        XCTAssertEqual(results[0].snippet, "snip a")
    }

    func testDecodeMarginaliaRespectsLimit() throws {
        let json = #"{"results":[{"url":"https://a.com","title":"A","description":"a"},{"url":"https://b.com","title":"B","description":"b"}]}"#
        XCTAssertEqual(try WebSearch.decodeMarginalia(Data(json.utf8), limit: 1).count, 1)
    }

    func testDecodeExaUsesHighlightAsSnippet() throws {
        let json = #"{"requestId":"x","results":[{"title":"A","url":"https://a.com","highlights":["snip a","more"],"summary":"sum a","text":"full text a"}]}"#
        let results = try WebSearch.decodeExa(Data(json.utf8), limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "A")
        XCTAssertEqual(results[0].url, "https://a.com")
        XCTAssertEqual(results[0].snippet, "snip a")
    }

    func testDecodeExaFallsBackSummaryThenText() throws {
        let summaryOnly = #"{"results":[{"title":"A","url":"https://a.com","summary":"sum a"}]}"#
        XCTAssertEqual(try WebSearch.decodeExa(Data(summaryOnly.utf8), limit: 5).first?.snippet, "sum a")

        let textOnly = #"{"results":[{"title":"A","url":"https://a.com","text":"full text a"}]}"#
        XCTAssertEqual(try WebSearch.decodeExa(Data(textOnly.utf8), limit: 5).first?.snippet, "full text a")
    }

    func testDecodeExaTitleFallsBackToURLAndRespectsLimit() throws {
        let json = #"{"results":[{"url":"https://a.com"},{"url":"https://b.com"}]}"#
        let results = try WebSearch.decodeExa(Data(json.utf8), limit: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "https://a.com")
        XCTAssertEqual(results.first?.snippet, "")
    }

    func testDecodeLinkup() throws {
        let json = #"{"results":[{"name":"A","url":"https://a.com","content":"snip a","type":"text"}]}"#
        let results = try WebSearch.decodeLinkup(Data(json.utf8), limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "A")
        XCTAssertEqual(results[0].url, "https://a.com")
        XCTAssertEqual(results[0].snippet, "snip a")
    }

    func testDecodeLinkupTitleFallsBackToURLAndRespectsLimit() throws {
        let json = #"{"results":[{"url":"https://a.com"},{"url":"https://b.com"}]}"#
        let results = try WebSearch.decodeLinkup(Data(json.utf8), limit: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "https://a.com")
        XCTAssertEqual(results.first?.snippet, "")
    }

    func testDecodeTinyFish() throws {
        let json = #"{"query":"q","results":[{"position":1,"site_name":"a.com","title":"A","snippet":"snip a","url":"https://a.com"}],"total_results":10,"page":0}"#
        let results = try WebSearch.decodeTinyFish(Data(json.utf8), limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "A")
        XCTAssertEqual(results[0].url, "https://a.com")
        XCTAssertEqual(results[0].snippet, "snip a")
    }

    func testDecodeTinyFishTitleFallsBackToURLAndRespectsLimit() throws {
        let json = #"{"results":[{"url":"https://a.com"},{"url":"https://b.com"}]}"#
        let results = try WebSearch.decodeTinyFish(Data(json.utf8), limit: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "https://a.com")
        XCTAssertEqual(results.first?.snippet, "")
    }

    // MARK: - Pagination

    func testProviderCapabilities() {
        XCTAssertEqual(WebSearch.ProviderKind.tavily.searchCapabilities, SearchCapabilities(pageSize: 20, maxResults: 20))
        XCTAssertEqual(WebSearch.ProviderKind.exa.searchCapabilities, SearchCapabilities(pageSize: 20, maxResults: 20))
        XCTAssertEqual(WebSearch.ProviderKind.linkup.searchCapabilities, SearchCapabilities(pageSize: 20, maxResults: 20))
        XCTAssertEqual(WebSearch.ProviderKind.tinyfish.searchCapabilities, SearchCapabilities(pageSize: 20, maxResults: 20))
        XCTAssertEqual(WebSearch.ProviderKind.meta.searchCapabilities, SearchCapabilities(pageSize: 20, maxResults: 20))
        XCTAssertEqual(WebSearch.ProviderKind.brave.searchCapabilities, SearchCapabilities(pageSize: 20, maxResults: 200))
        XCTAssertEqual(WebSearch.ProviderKind.marginalia.searchCapabilities, SearchCapabilities(pageSize: 20, maxResults: 100))
        XCTAssertNil(WebSearch.ProviderKind.wikipedia.searchCapabilities.maxResults)
        XCTAssertNil(WebSearch.ProviderKind.searxng.searchCapabilities.maxResults)
    }

    func testPageLimitClampsToMax() {
        let unbounded = SearchCapabilities(pageSize: 20, maxResults: nil)
        XCTAssertEqual(WebSearch.pageLimit(offset: 0, caps: unbounded), 20)
        XCTAssertEqual(WebSearch.pageLimit(offset: 100, caps: unbounded), 20)

        let capped = SearchCapabilities(pageSize: 20, maxResults: 20)
        XCTAssertEqual(WebSearch.pageLimit(offset: 0, caps: capped), 20)
        XCTAssertEqual(WebSearch.pageLimit(offset: 20, caps: capped), 0) // ceiling reached
    }

    func testPaginationStateHasMoreWhenFullPageUnderMax() {
        let caps = SearchCapabilities(pageSize: 20, maxResults: 100)
        let state = WebSearch.paginationState(offset: 0, returned: 20, requested: 20, caps: caps)
        XCTAssertTrue(state.hasMore)
        XCTAssertEqual(state.nextOffset, 20)
    }

    func testPaginationStateStopsAtMax() {
        let caps = SearchCapabilities(pageSize: 20, maxResults: 20) // Tavily-like
        let state = WebSearch.paginationState(offset: 0, returned: 20, requested: 20, caps: caps)
        XCTAssertFalse(state.hasMore) // loaded == max
    }

    func testPaginationStateStopsOnShortPage() {
        let caps = SearchCapabilities(pageSize: 20, maxResults: nil)
        let state = WebSearch.paginationState(offset: 0, returned: 12, requested: 20, caps: caps)
        XCTAssertFalse(state.hasMore) // fewer than requested → end of results
    }

    func testDecodeTavilyOffsetSlicesResults() throws {
        let json = #"{"results":[{"url":"https://a.com","title":"A"},{"url":"https://b.com","title":"B"},{"url":"https://c.com","title":"C"}]}"#
        let sliced = try WebSearch.decodeTavily(Data(json.utf8), limit: 2, offset: 1)
        XCTAssertEqual(sliced.map(\.url), ["https://b.com", "https://c.com"])
    }

    // MARK: - Provider catalog / readiness

    func testCatalogExcludesNoneAndMeta() {
        XCTAssertFalse(WebSearch.catalog.contains(.none))
        XCTAssertFalse(WebSearch.catalog.contains(.meta))
        XCTAssertEqual(WebSearch.catalog.count, WebSearch.ProviderKind.allCases.count - 2)
    }

    func testEveryCatalogProviderHasSummary() {
        for provider in WebSearch.catalog {
            XCTAssertFalse(provider.summary.isEmpty, "\(provider) is missing a summary")
        }
    }

    func testKeyedProvidersHaveSignupURL() {
        for provider in WebSearch.catalog where provider.credentialKind == .apiKey && provider != .marginalia {
            XCTAssertNotNil(provider.signupURL, "\(provider) is missing a signup URL")
        }
    }

    func testCredentialKinds() {
        XCTAssertEqual(WebSearch.ProviderKind.wikipedia.credentialKind, .none)
        XCTAssertEqual(WebSearch.ProviderKind.searxng.credentialKind, .instanceURL)
        XCTAssertEqual(WebSearch.ProviderKind.exa.credentialKind, .apiKey)
    }

    func testIsReadyReflectsCredentials() {
        let empty = WebSearchConfig()
        XCTAssertTrue(WebSearch.isReady(.wikipedia, config: empty))  // keyless
        XCTAssertTrue(WebSearch.isReady(.marginalia, config: empty)) // default "public" key
        XCTAssertFalse(WebSearch.isReady(.exa, config: empty))
        XCTAssertFalse(WebSearch.isReady(.searxng, config: empty))

        var configured = empty
        configured.exaAPIKey = "k"
        configured.searxngURL = "http://localhost:8080"
        XCTAssertTrue(WebSearch.isReady(.exa, config: configured))
        XCTAssertTrue(WebSearch.isReady(.searxng, config: configured))
    }

    // MARK: - Meta-search

    func testMetaProviderMetadata() {
        XCTAssertFalse(WebSearch.catalog.contains(.meta))
        XCTAssertEqual(WebSearch.ProviderKind.meta.credentialKind, .none)
        XCTAssertFalse(WebSearch.ProviderKind.meta.summary.isEmpty)
        // Meta is always ready: it can always fall back to the keyless engines.
        XCTAssertTrue(WebSearch.isReady(.meta, config: WebSearchConfig()))
    }

    func testCanonicalURLNormalizesForDedup() {
        XCTAssertEqual(WebSearch.canonicalURL("https://www.Example.com/Path/"), "example.com/Path")
        XCTAssertEqual(WebSearch.canonicalURL("http://example.com/Path"), "example.com/Path")
        XCTAssertEqual(WebSearch.canonicalURL("https://example.com/p?utm_source=x&id=5#frag"), "example.com/p?id=5")
        XCTAssertEqual(WebSearch.canonicalURL("https://example.com/"), "example.com")
        XCTAssertEqual(WebSearch.canonicalURL("https://example.com"), "example.com")
    }

    func testMergeRRFBoostsConsensusAndDedups() {
        let listA = [
            WebSearch.Result(title: "Shared", url: "https://shared.com/x", snippet: ""),
            WebSearch.Result(title: "OnlyA", url: "https://a.com", snippet: "")
        ]
        let listB = [
            WebSearch.Result(title: "OnlyB", url: "https://b.com", snippet: ""),
            WebSearch.Result(title: "SharedDup", url: "https://www.shared.com/x/", snippet: "")
        ]
        let merged = WebSearch.mergeRRF([listA, listB])
        // The consensus page dedups to one entry (canonical URL) and ranks first.
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.first?.url, "https://shared.com/x")
        XCTAssertEqual(merged.first?.title, "Shared") // first-seen result is kept
    }

    func testMetaSearchFansOutMergesAndIsolatesFailures() async throws {
        let a = StubProvider(results: [
            WebSearch.Result(title: "Shared", url: "https://shared.com", snippet: "a"),
            WebSearch.Result(title: "OnlyA", url: "https://a.com", snippet: "a")
        ])
        let b = StubProvider(results: [
            WebSearch.Result(title: "Shared", url: "https://shared.com", snippet: "b"),
            WebSearch.Result(title: "OnlyB", url: "https://b.com", snippet: "b")
        ])
        let failing = StubProvider(results: [], fails: true)
        let meta = MetaSearchProvider(providers: [a, b, failing])
        let results = try await meta.search("q", limit: 10, offset: 0)
        // Shared (two engines) ranks first; the failing provider is isolated and contributes nothing.
        XCTAssertEqual(results.map { $0.url }, ["https://shared.com", "https://a.com", "https://b.com"])
    }

    func testMetaSearchCapsMergedResultsToLimit() async throws {
        let a = StubProvider(results: (0..<5).map {
            WebSearch.Result(title: "A\($0)", url: "https://a.com/\($0)", snippet: "")
        })
        let b = StubProvider(results: (0..<5).map {
            WebSearch.Result(title: "B\($0)", url: "https://b.com/\($0)", snippet: "")
        })
        let meta = MetaSearchProvider(providers: [a, b])
        let results = try await meta.search("q", limit: 4, offset: 0)
        // Each engine returned its 4; the merged pool of 8 distinct URLs is capped to the limit.
        XCTAssertEqual(results.count, 4)
    }

    func testMetaProvidersReflectEnabledAndReady() {
        var config = WebSearchConfig() // all providers enabled by default
        config.braveAPIKey = "k"
        let providers = WebSearch.metaProviders(config: config)
        XCTAssertTrue(providers.contains(.wikipedia))  // keyless, always ready
        XCTAssertTrue(providers.contains(.marginalia)) // shared public key
        XCTAssertTrue(providers.contains(.brave))      // now keyed
        XCTAssertFalse(providers.contains(.exa))       // no key → not ready
        XCTAssertEqual(providers, WebSearch.catalog.filter { providers.contains($0) }) // catalog order
    }

    func testMetaProvidersHonorEnabledSet() {
        var config = WebSearchConfig(enabledProviders: [.wikipedia])
        // Marginalia is ready but not enabled, so it's excluded.
        XCTAssertEqual(WebSearch.metaProviders(config: config), [.wikipedia])
        XCTAssertTrue(WebSearch.isReady(.meta, config: config))

        config.enabledProviders = []
        XCTAssertTrue(WebSearch.metaProviders(config: config).isEmpty)
        XCTAssertFalse(WebSearch.isReady(.meta, config: config)) // no engines → meta not ready
    }
}

/// A canned provider for meta-search tests: returns fixed results, or throws when `fails`.
private struct StubProvider: WebSearchProvider {
    let results: [WebSearch.Result]
    var fails = false
    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        if fails { throw WebSearch.SearchError.http(429) }
        return Array(results.prefix(limit))
    }
}
