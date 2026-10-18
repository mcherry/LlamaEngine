import XCTest
@testable import LlamaEngine

final class WriteFileToolTests: XCTestCase {

    private var root: URL!
    private var tool: WriteFileTool!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llamatron-write-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tool = WriteFileTool(policy: FileAccessPolicy(roots: [root], maxBytes: 1024))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func args(path: String, content: String) -> JSONValue {
        .object(["path": .string(path), "content": .string(content)])
    }

    func testWritesFileContents() async throws {
        let target = root.appendingPathComponent("hello.txt")
        let result = try await tool.execute(args(path: target.path, content: "hello"))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "hello")
    }

    func testWrittenScriptIsNotExecutable() async throws {
        // A script the model wrote must never become a script the machine can run on
        // its own — the user has to invoke it deliberately.
        let target = root.appendingPathComponent("build.sh")
        _ = try await tool.execute(args(path: target.path, content: "#!/bin/bash\necho hi\n"))

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value & 0o111, 0, "no executable bit may be set")
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: target.path))
    }

    func testCreatesIntermediateDirectoriesInsideTheRoot() async throws {
        let target = root.appendingPathComponent("a/b/c/notes.txt")
        _ = try await tool.execute(args(path: target.path, content: "deep"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "deep")
    }

    func testReplacesAnExistingFile() async throws {
        let target = root.appendingPathComponent("notes.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let result = try await tool.execute(args(path: target.path, content: "new"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        XCTAssertTrue(result.content.contains("Replaced"))
    }

    func testRefusesContentOverTheSizeCap() async {
        let target = root.appendingPathComponent("big.txt")
        let oversized = String(repeating: "x", count: 2048)
        await XCTAssertThrowsErrorAsync(try await tool.execute(args(path: target.path,
                                                                   content: oversized)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "a rejected write must not create the file")
    }

    func testRefusesPathOutsideTheGrantedRoot() async {
        await XCTAssertThrowsErrorAsync(
            try await tool.execute(args(path: "/etc/evil.txt", content: "nope")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/etc/evil.txt"))
    }

    func testValidateRejectsBeforeAnythingIsCreated() {
        let target = root.appendingPathComponent("../escaped.txt")
        XCTAssertThrowsError(try tool.validate(args(path: target.path, content: "x")))
    }

    func testRefusesToReplaceADirectory() async throws {
        let dir = root.appendingPathComponent("a-folder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await XCTAssertThrowsErrorAsync(try await tool.execute(args(path: dir.path, content: "x")))
    }

    // MARK: - Policy

    func testMutatingAlwaysConfirmsEvenWhenApprovedForTheSession() {
        // The bypass that exists for network tools must not reach `mutating`: a stale or
        // tampered approval set must never grant a silent write.
        let settings = SessionToolSettings(enabled: true,
                                           allowedTools: ["write_file"],
                                           approvedForSession: ["write_file"])
        let decision = ToolPolicy().decide(tool: WriteFileTool(), settings: settings)
        XCTAssertEqual(decision, .needsConfirmation)
    }

    func testNetworkToolStillHonoursSessionApproval() {
        let settings = SessionToolSettings(enabled: true,
                                           allowedTools: ["fetch_url"],
                                           approvedForSession: ["fetch_url"])
        XCTAssertEqual(ToolPolicy().decide(tool: FetchURLTool(), settings: settings), .allow)
    }

    func testWriteFileIsDeniedWhenNotAllowListed() {
        let settings = SessionToolSettings(enabled: true, allowedTools: [])
        guard case .deny = ToolPolicy().decide(tool: WriteFileTool(), settings: settings) else {
            return XCTFail("an un-allow-listed write must be denied")
        }
    }
}

/// `XCTAssertThrowsError` has no async overload in this toolchain.
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  _ message: String = "",
                                  file: StaticString = #filePath,
                                  line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "Expected an error" : message, file: file, line: line)
    } catch {
        // expected
    }
}
