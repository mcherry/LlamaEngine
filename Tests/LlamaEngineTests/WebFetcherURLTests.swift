import XCTest
@testable import LlamaEngine

/// Tests for `WebFetcher.normalizedURL` (scheme normalization + non-HTTP rejection).
/// Stays in Llamatron until the web-fetch layer moves into LlamaEngine (Phase 2).
final class WebFetcherURLTests: XCTestCase {

    func testNormalizesAndDefaultsToHTTPS() {
        XCTAssertEqual(WebFetcher.normalizedURL("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(WebFetcher.normalizedURL("  http://x.org/p  ")?.absoluteString, "http://x.org/p")
    }

    func testRejectsNonHTTPSchemes() {
        XCTAssertNil(WebFetcher.normalizedURL("file:///etc/passwd"))
        XCTAssertNil(WebFetcher.normalizedURL("data:text/html,hi"))
        XCTAssertNil(WebFetcher.normalizedURL("ftp://x.org"))
        XCTAssertNil(WebFetcher.normalizedURL(""))
    }
}
