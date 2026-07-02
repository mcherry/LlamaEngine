import XCTest
@testable import LlamaEngine

final class RobotsTxtTests: XCTestCase {

    func testEmptyRobotsAllowsEverything() {
        XCTAssertTrue(RobotsTxt.isAllowed("/anything", userAgent: "Llamatron", robots: ""))
    }

    func testDisallowAll() {
        let robots = "User-agent: *\nDisallow: /"
        XCTAssertFalse(RobotsTxt.isAllowed("/x", userAgent: "Llamatron", robots: robots))
        XCTAssertFalse(RobotsTxt.isAllowed("/", userAgent: "Llamatron", robots: robots))
    }

    func testEmptyDisallowImposesNoRestriction() {
        XCTAssertTrue(RobotsTxt.isAllowed("/x", userAgent: "Bot", robots: "User-agent: *\nDisallow:"))
    }

    func testPathPrefixDisallow() {
        let robots = "User-agent: *\nDisallow: /private"
        XCTAssertFalse(RobotsTxt.isAllowed("/private/page", userAgent: "Bot", robots: robots))
        XCTAssertFalse(RobotsTxt.isAllowed("/privatestuff", userAgent: "Bot", robots: robots))
        XCTAssertTrue(RobotsTxt.isAllowed("/public", userAgent: "Bot", robots: robots))
    }

    func testAllowOverridesByLongestMatch() {
        let robots = "User-agent: *\nDisallow: /a\nAllow: /a/b"
        XCTAssertTrue(RobotsTxt.isAllowed("/a/b/c", userAgent: "Bot", robots: robots))   // longer Allow wins
        XCTAssertFalse(RobotsTxt.isAllowed("/a/x", userAgent: "Bot", robots: robots))    // Disallow
    }

    func testUserAgentSpecificGroupWins() {
        let robots = """
        User-agent: Llamatron
        Disallow: /

        User-agent: *
        Disallow:
        """
        XCTAssertFalse(RobotsTxt.isAllowed("/x", userAgent: "Llamatron/1.0", robots: robots))
        XCTAssertTrue(RobotsTxt.isAllowed("/x", userAgent: "OtherBot", robots: robots))
    }

    func testEndAnchorWithWildcard() {
        let robots = "User-agent: *\nDisallow: /*.pdf$"
        XCTAssertFalse(RobotsTxt.isAllowed("/docs/report.pdf", userAgent: "Bot", robots: robots))
        XCTAssertTrue(RobotsTxt.isAllowed("/docs/report.pdf?dl=1", userAgent: "Bot", robots: robots))
        XCTAssertTrue(RobotsTxt.isAllowed("/docs/report.html", userAgent: "Bot", robots: robots))
    }
}
