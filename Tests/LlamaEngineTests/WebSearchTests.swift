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

    // MARK: - Pagination

    func testProviderCapabilities() {
        XCTAssertEqual(WebSearch.ProviderKind.tavily.searchCapabilities, SearchCapabilities(pageSize: 20, maxResults: 20))
        XCTAssertEqual(WebSearch.ProviderKind.exa.searchCapabilities, SearchCapabilities(pageSize: 20, maxResults: 20))
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
}
