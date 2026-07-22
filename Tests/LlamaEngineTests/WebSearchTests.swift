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
        XCTAssertFalse(WebSearch.isReady(.marginalia, config: empty)) // needs a key like the other engines
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
        let failing = StubProvider(results: [], failStatus: 429)
        let meta = MetaSearchProvider(providers: [
            (kind: .wikipedia, provider: a),
            (kind: .marginalia, provider: b),
            (kind: .brave, provider: failing)
        ], rateLimiter: MetaRateLimiter())
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
        let meta = MetaSearchProvider(providers: [
            (kind: .wikipedia, provider: a),
            (kind: .brave, provider: b)
        ], rateLimiter: MetaRateLimiter())
        let results = try await meta.search("q", limit: 4, offset: 0)
        // Each engine returned its 4; the merged pool of 8 distinct URLs is capped to the limit.
        XCTAssertEqual(results.count, 4)
    }

    func testMetaProvidersReflectEnabledAndReady() {
        var config = WebSearchConfig() // all providers enabled by default
        config.braveAPIKey = "k"
        let providers = WebSearch.metaProviders(config: config)
        XCTAssertTrue(providers.contains(.wikipedia))  // keyless, always ready
        XCTAssertFalse(providers.contains(.marginalia)) // no key → not ready
        XCTAssertTrue(providers.contains(.brave))      // now keyed
        XCTAssertFalse(providers.contains(.exa))       // no key → not ready
        XCTAssertEqual(providers, WebSearch.catalog.filter { providers.contains($0) }) // catalog order
    }

    func testMetaProvidersHonorEnabledSet() {
        var config = WebSearchConfig(enabledProviders: [.wikipedia])
        // Only Wikipedia is enabled, so it's the sole meta engine.
        XCTAssertEqual(WebSearch.metaProviders(config: config), [.wikipedia])
        XCTAssertTrue(WebSearch.isReady(.meta, config: config))

        config.enabledProviders = []
        XCTAssertTrue(WebSearch.metaProviders(config: config).isEmpty)
        XCTAssertFalse(WebSearch.isReady(.meta, config: config)) // no engines → meta not ready
    }

    func testMetaRunReportsPerProviderOutcomes() async {
        let ok = StubProvider(results: [
            WebSearch.Result(title: "R1", url: "https://r1.com", snippet: ""),
            WebSearch.Result(title: "R2", url: "https://r2.com", snippet: "")
        ])
        let badKey = StubProvider(results: [], failStatus: 401)
        let limited = StubProvider(results: [], failStatus: 429)
        let meta = MetaSearchProvider(providers: [
            (kind: .brave, provider: ok),
            (kind: .exa, provider: badKey),
            (kind: .tinyfish, provider: limited)
        ], rateLimiter: MetaRateLimiter())
        let run = await meta.run("q", limit: 10)
        XCTAssertEqual(run.results.count, 2) // only the working engine contributed
        XCTAssertEqual(run.outcomes.map(\.provider), [.brave, .exa, .tinyfish]) // provider order
        XCTAssertNil(run.outcomes[0].failureReason)
        XCTAssertEqual(run.outcomes[0].resultCount, 2)
        XCTAssertEqual(run.outcomes[1].failureReason, .authentication)
        XCTAssertEqual(run.outcomes[2].failureReason, .rateLimited)
        XCTAssertEqual(run.outcomes.filter(\.failed).count, 2)
    }

    func testFailureReasonMapping() {
        XCTAssertEqual(WebSearch.failureReason(for: WebSearch.SearchError.http(401, retryAfter: nil)), .authentication)
        XCTAssertEqual(WebSearch.failureReason(for: WebSearch.SearchError.http(403, retryAfter: nil)), .authentication)
        XCTAssertEqual(WebSearch.failureReason(for: WebSearch.SearchError.http(429, retryAfter: 30)), .rateLimited)
        XCTAssertEqual(WebSearch.failureReason(for: WebSearch.SearchError.http(402, retryAfter: nil)), .outOfQuota)
        XCTAssertEqual(WebSearch.failureReason(for: WebSearch.SearchError.http(432, retryAfter: nil)), .outOfQuota)
        XCTAssertEqual(WebSearch.failureReason(for: WebSearch.SearchError.http(500, retryAfter: nil)), .unavailable)
        XCTAssertEqual(WebSearch.failureReason(for: WebSearch.SearchError.transport("x")), .unavailable)
    }

    func testRetryAfterExtraction() {
        XCTAssertEqual(WebSearch.retryAfter(for: WebSearch.SearchError.http(429, retryAfter: 30)), 30)
        XCTAssertNil(WebSearch.retryAfter(for: WebSearch.SearchError.http(500, retryAfter: nil)))
        XCTAssertNil(WebSearch.retryAfter(for: WebSearch.SearchError.transport("x")))
    }

    func testRetryAfterHeaderParsing() {
        let url = URL(string: "https://x.com")!
        let with = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "45"])!
        XCTAssertEqual(WebSearch.retryAfterSeconds(from: with), 45)
        let without = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:])!
        XCTAssertNil(WebSearch.retryAfterSeconds(from: without))
        let nonNumeric = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "soon"])!
        XCTAssertNil(WebSearch.retryAfterSeconds(from: nonNumeric))
    }

    func testRateLimitGateParksAndExpires() {
        var gate = RateLimitGate(defaultBackoff: 60, quotaCooldown: 3600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.record(.brave, reason: .rateLimited, retryAfter: 30, now: t0)
        XCTAssertFalse(gate.isAvailable(.brave, now: t0))
        XCTAssertEqual(gate.status(.brave, now: t0)?.remaining, 30)
        XCTAssertEqual(gate.status(.brave, now: t0)?.reason, .rateLimited)
        XCTAssertTrue(gate.isAvailable(.brave, now: t0.addingTimeInterval(31)))  // cooldown elapsed
        gate.record(.tavily, reason: .rateLimited, retryAfter: nil, now: t0)     // no header → default
        XCTAssertEqual(gate.status(.tavily, now: t0)?.remaining, 60)
        gate.record(.exa, reason: .outOfQuota, now: t0)
        XCTAssertEqual(gate.status(.exa, now: t0)?.remaining, 3600)
        gate.record(.linkup, reason: .authentication, now: t0)                   // no cooldown
        gate.record(.tinyfish, reason: .unavailable, now: t0)                    // no cooldown
        XCTAssertTrue(gate.isAvailable(.linkup, now: t0))
        XCTAssertTrue(gate.isAvailable(.tinyfish, now: t0))
        gate.record(.brave, reason: nil, now: t0)                                // success clears
        XCTAssertTrue(gate.isAvailable(.brave, now: t0))
    }

    func testMetaSkipsCoolingProviderOnNextRun() async {
        let steady = StubProvider(results: [WebSearch.Result(title: "S", url: "https://s.com", snippet: "")])
        let flaky = CallCountingStub(failStatus: 429, retryAfter: 300)
        let meta = MetaSearchProvider(providers: [
            (kind: .wikipedia, provider: steady),
            (kind: .brave, provider: flaky)
        ], rateLimiter: MetaRateLimiter())

        let first = await meta.run("q", limit: 10)
        XCTAssertEqual(first.outcomes.first { $0.provider == .brave }?.failureReason, .rateLimited)
        XCTAssertNotNil(first.outcomes.first { $0.provider == .brave }?.retryAfter)
        let callsAfterFirst = await flaky.count()
        XCTAssertEqual(callsAfterFirst, 1)

        let second = await meta.run("q", limit: 10)
        let callsAfterSecond = await flaky.count()
        XCTAssertEqual(callsAfterSecond, 1)  // cooling down → not re-hit
        XCTAssertEqual(second.outcomes.first { $0.provider == .brave }?.failureReason, .rateLimited)
        XCTAssertEqual(second.results.map(\.url), ["https://s.com"])  // wikipedia still contributes
    }

    func testFastModeStopsAtFirstResult() async {
        let first = CallCountingStub(results: [WebSearch.Result(title: "F", url: "https://f.com", snippet: "")])
        let second = CallCountingStub(results: [WebSearch.Result(title: "S", url: "https://s.com", snippet: "")])
        let meta = MetaSearchProvider(providers: [
            (kind: .wikipedia, provider: first),
            (kind: .marginalia, provider: second)
        ], rateLimiter: MetaRateLimiter(), mode: .fast)
        let run = await meta.run("q", limit: 10)
        XCTAssertEqual(run.results.map(\.url), ["https://f.com"])   // first engine won
        let firstCalls = await first.count()
        let secondCalls = await second.count()
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 0)                              // second never queried
    }

    func testFastModeFallsPastEmptyProvider() async {
        let empty = CallCountingStub(results: [])   // succeeds with no results
        let hit = CallCountingStub(results: [WebSearch.Result(title: "H", url: "https://h.com", snippet: "")])
        let meta = MetaSearchProvider(providers: [
            (kind: .wikipedia, provider: empty),
            (kind: .marginalia, provider: hit)
        ], rateLimiter: MetaRateLimiter(), mode: .fast)
        let run = await meta.run("q", limit: 10)
        XCTAssertEqual(run.results.map(\.url), ["https://h.com"])   // fell through the empty one
        let emptyCalls = await empty.count()
        let hitCalls = await hit.count()
        XCTAssertEqual(emptyCalls, 1)
        XCTAssertEqual(hitCalls, 1)
    }

    func testResilientRetriesTransientFailure() async {
        let flaky = CallCountingStub(results: [WebSearch.Result(title: "R", url: "https://r.com", snippet: "")],
                                     failStatus: 500, failFirst: 1)   // fails once, then succeeds
        let meta = MetaSearchProvider(providers: [(kind: .wikipedia, provider: flaky)],
                                      rateLimiter: MetaRateLimiter(), mode: .resilient)
        let run = await meta.run("q", limit: 10)
        XCTAssertEqual(run.results.map(\.url), ["https://r.com"])   // retried and succeeded
        let calls = await flaky.count()
        XCTAssertEqual(calls, 2)
    }

    func testFastDoesNotRetryTransientFailure() async {
        let flaky = CallCountingStub(results: [WebSearch.Result(title: "R", url: "https://r.com", snippet: "")],
                                     failStatus: 500, failFirst: 1)
        let meta = MetaSearchProvider(providers: [(kind: .wikipedia, provider: flaky)],
                                      rateLimiter: MetaRateLimiter(), mode: .fast)
        let run = await meta.run("q", limit: 10)
        XCTAssertTrue(run.results.isEmpty)                          // no retry → no results
        let calls = await flaky.count()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(run.outcomes.first { $0.provider == .wikipedia }?.failureReason, .unavailable)
    }

    func testSearchUsageRecordsAndCounts() {
        let now = day(2026, 7, 15)
        var json = SearchUsage.recording([.brave, .brave, .exa], into: "", now: now)
        XCTAssertEqual(SearchUsage.count(.brave, in: json, now: now), 2)
        XCTAssertEqual(SearchUsage.count(.exa, in: json, now: now), 1)
        XCTAssertEqual(SearchUsage.count(.tavily, in: json, now: now), 0)
        json = SearchUsage.recording([.brave], into: json, now: now)
        XCTAssertEqual(SearchUsage.count(.brave, in: json, now: now), 3)
    }

    func testSearchUsageResetsOnNewMonth() {
        let july = day(2026, 7, 31)
        let august = day(2026, 8, 1)
        let json = SearchUsage.recording([.brave], into: "", now: july)
        XCTAssertEqual(SearchUsage.count(.brave, in: json, now: july), 1)
        XCTAssertEqual(SearchUsage.count(.brave, in: json, now: august), 0)   // rolled over
        let augustJSON = SearchUsage.recording([.brave], into: json, now: august)
        XCTAssertEqual(SearchUsage.count(.brave, in: augustJSON, now: august), 1)
    }
}

/// A canned provider for meta-search tests: returns fixed results, or throws `.http(failStatus)`.
private struct StubProvider: WebSearchProvider {
    let results: [WebSearch.Result]
    var failStatus: Int? = nil
    var retryAfter: TimeInterval? = nil
    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        if let failStatus { throw WebSearch.SearchError.http(failStatus, retryAfter: retryAfter) }
        return Array(results.prefix(limit))
    }
}

/// A stateful stub that counts how many times it was queried — for asserting a cooling-down
/// provider isn't re-hit, and for retry/fallback tests. Fails its first `failFirst` calls.
private actor CallCountingStub: WebSearchProvider {
    private var calls = 0
    let results: [WebSearch.Result]
    let failStatus: Int?
    let retryAfter: TimeInterval?
    let failFirst: Int
    init(results: [WebSearch.Result] = [], failStatus: Int? = nil, retryAfter: TimeInterval? = nil, failFirst: Int = .max) {
        self.results = results
        self.failStatus = failStatus
        self.retryAfter = retryAfter
        self.failFirst = failFirst
    }
    func search(_ query: String, limit: Int, offset: Int) async throws -> [WebSearch.Result] {
        calls += 1
        if let failStatus, calls <= failFirst { throw WebSearch.SearchError.http(failStatus, retryAfter: retryAfter) }
        return Array(results.prefix(limit))
    }
    func count() -> Int { calls }
}

/// Builds a local-calendar date for the deterministic usage tests.
private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}
