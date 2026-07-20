import XCTest
@testable import LlamaEngine

final class DirectoryFilterTests: XCTestCase {

    func testSkipsDependencyAndBuildDirectories() {
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory("node_modules"))
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory("Pods"))
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory("build"))
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory(".build"))
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory("DerivedData"))
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory("__pycache__"))
    }

    func testSkipsHiddenDirectories() {
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory(".git"))
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory(".vscode"))
    }

    func testKeepsSourceDirectories() {
        XCTAssertFalse(DirectoryFilter.shouldSkipDirectory("Sources"))
        XCTAssertFalse(DirectoryFilter.shouldSkipDirectory("src"))
        XCTAssertFalse(DirectoryFilter.shouldSkipDirectory("app"))
    }

    func testCaseInsensitiveDirectoryMatch() {
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory("NODE_MODULES"))
        XCTAssertTrue(DirectoryFilter.shouldSkipDirectory("Build"))
    }

    func testSkipsBinaryAndHiddenFiles() {
        XCTAssertTrue(DirectoryFilter.shouldSkipFile("logo.png"))
        XCTAssertTrue(DirectoryFilter.shouldSkipFile("archive.zip"))
        XCTAssertTrue(DirectoryFilter.shouldSkipFile("libFoo.dylib"))
        XCTAssertTrue(DirectoryFilter.shouldSkipFile("yarn.lock"))
        XCTAssertTrue(DirectoryFilter.shouldSkipFile(".env"))
    }

    func testKeepsTextAndSourceFiles() {
        XCTAssertFalse(DirectoryFilter.shouldSkipFile("main.swift"))
        XCTAssertFalse(DirectoryFilter.shouldSkipFile("README.md"))
        XCTAssertFalse(DirectoryFilter.shouldSkipFile("index.ts"))
        // Extensionless files (Makefile, Dockerfile, LICENSE) are kept for the content sniff.
        XCTAssertFalse(DirectoryFilter.shouldSkipFile("Dockerfile"))
        XCTAssertFalse(DirectoryFilter.shouldSkipFile("Makefile"))
    }

    func testBinarySniffDetectsNulByte() {
        let text = Data("let x = 42\nprint(x)\n".utf8)
        XCTAssertFalse(DirectoryFilter.looksBinary(text))

        var binary = Data("ELF".utf8)
        binary.append(contentsOf: [0x00, 0x01, 0x02, 0x00])
        XCTAssertTrue(DirectoryFilter.looksBinary(binary))
    }

    func testRelativePathUnderRoot() {
        let root = URL(fileURLWithPath: "/Users/me/project")
        let file = URL(fileURLWithPath: "/Users/me/project/Sources/App/main.swift")
        XCTAssertEqual(DirectoryFilter.relativePath(of: file, under: root),
                       "Sources/App/main.swift")
    }

    func testRelativePathFallsBackToLastComponent() {
        let root = URL(fileURLWithPath: "/Users/me/project")
        let file = URL(fileURLWithPath: "/elsewhere/orphan.txt")
        XCTAssertEqual(DirectoryFilter.relativePath(of: file, under: root), "orphan.txt")
    }
}
