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
}
