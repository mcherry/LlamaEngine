import XCTest
@testable import LlamaEngine

/// Containment tests for the filesystem tools. The app is unsandboxed, so these assertions
/// are the only thing standing between an injected instruction and the user's disk.
final class FileAccessPolicyTests: XCTestCase {

    private var root: URL!
    private var policy: FileAccessPolicy!

    override func setUpWithError() throws {
        // Resolved up front: on macOS the temp dir is under /var, a symlink to /private/var.
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llamatron-fileguard-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        policy = FileAccessPolicy(roots: [root])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func expectRejected(_ path: String,
                               _ message: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertThrowsError(try FilePathGuard.resolve(path, policy: policy),
                             message, file: file, line: line)
    }

    // MARK: - Allowed

    func testFileDirectlyInsideRootIsAllowed() throws {
        let resolved = try FilePathGuard.resolve(root.appendingPathComponent("notes.txt").path,
                                                 policy: policy)
        XCTAssertEqual(resolved.lastPathComponent, "notes.txt")
        XCTAssertTrue(FilePathGuard.contains(root, resolved))
    }

    func testNewNestedPathIsAllowedEvenThoughParentsDoNotExistYet() throws {
        let target = root.appendingPathComponent("a/b/c/build.sh")
        let resolved = try FilePathGuard.resolve(target.path, policy: policy)
        XCTAssertTrue(FilePathGuard.contains(root, resolved))
        XCTAssertEqual(resolved.lastPathComponent, "build.sh")
    }

    // MARK: - Traversal and containment

    func testParentTraversalIsRejected() {
        expectRejected(root.appendingPathComponent("../escaped.txt").path,
                       "`..` must not climb out of the root")
    }

    func testDeepParentTraversalIsRejected() {
        expectRejected(root.appendingPathComponent("a/b/../../../escaped.txt").path,
                       "multi-level `..` must not climb out of the root")
    }

    func testSiblingDirectoryWithSharedPrefixIsRejected() {
        // The classic string-prefix bug: "/tmp/foo-evil".hasPrefix("/tmp/foo") is true.
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-evil")
            .appendingPathComponent("payload.txt")
        expectRejected(sibling.path, "a shared path prefix must not imply containment")
    }

    func testRootItselfIsNotAWritableTarget() {
        expectRejected(root.path, "the root directory is not a file target")
    }

    func testPathOutsideEveryRootIsRejected() {
        expectRejected("/etc/hosts", "paths outside the granted roots must be refused")
    }

    func testRelativePathIsRejected() {
        expectRejected("notes.txt", "relative paths have no well-defined base")
    }

    func testEmptyRootsFailClosed() {
        policy = FileAccessPolicy(roots: [])
        expectRejected(root.appendingPathComponent("notes.txt").path,
                       "no granted roots must mean no access")
    }

    func testNulByteIsRejected() {
        expectRejected(root.appendingPathComponent("ok.txt").path + "\0/../../etc/passwd",
                       "a NUL byte must not truncate the path at the syscall boundary")
    }

    // MARK: - Symlinks

    func testSymlinkedParentDirectoryCannotSmuggleANewFileOut() throws {
        // The case plain resolvingSymlinksInPath() misses: the leaf does not exist yet.
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: URL(fileURLWithPath: "/etc"))
        expectRejected(link.appendingPathComponent("evil.txt").path,
                       "a symlinked parent must not escape the root")
    }

    func testSymlinkAtTheTargetIsRefusedEvenWhenItPointsInsideTheRoot() throws {
        let real = root.appendingPathComponent("real.txt")
        try "hello".write(to: real, atomically: true, encoding: .utf8)
        let alias = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        expectRejected(alias.path, "writing through a symlink must be refused outright")
    }

    // MARK: - Hidden and protected names

    func testHiddenFileIsRejectedByDefault() {
        expectRejected(root.appendingPathComponent(".env").path,
                       "dot-files must be unreachable by default")
    }

    func testHiddenDirectoryIsRejectedByDefault() {
        expectRejected(root.appendingPathComponent(".ssh/authorized_keys").path,
                       "dot-directories must be unreachable by default")
    }

    func testHiddenPathIsAllowedWhenTheUserOptsIn() throws {
        policy = FileAccessPolicy(roots: [root], allowHidden: true)
        let resolved = try FilePathGuard.resolve(root.appendingPathComponent(".env").path,
                                                 policy: policy)
        XCTAssertEqual(resolved.lastPathComponent, ".env")
    }

    func testHiddenRootDoesNotPenaliseItsOwnComponents() throws {
        // Only components *below* the root are the model's choice.
        let hiddenRoot = root.appendingPathComponent(".scratch")
        try FileManager.default.createDirectory(at: hiddenRoot, withIntermediateDirectories: true)
        policy = FileAccessPolicy(roots: [hiddenRoot])
        let resolved = try FilePathGuard.resolve(hiddenRoot.appendingPathComponent("ok.txt").path,
                                                 policy: policy)
        XCTAssertEqual(resolved.lastPathComponent, "ok.txt")
    }

    func testPersistenceLocationsAreRejectedInsideAGrantedRoot() {
        expectRejected(root.appendingPathComponent("LaunchAgents/com.evil.plist").path,
                       "launch-agent paths must stay protected even inside a root")
    }

    // MARK: - Root validation

    func testFilesystemRootCannotBeGranted() {
        XCTAssertThrowsError(try FilePathGuard.validateRoot(URL(fileURLWithPath: "/")))
    }

    func testSystemDirectoriesCannotBeGranted() {
        for path in ["/System", "/usr", "/etc", "/Library", "/Applications"] {
            XCTAssertThrowsError(try FilePathGuard.validateRoot(URL(fileURLWithPath: path)),
                                 "\(path) must not be grantable")
        }
    }

    func testHomeDirectoryItselfCannotBeGranted() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        XCTAssertThrowsError(try FilePathGuard.validateRoot(home),
                             "the whole home directory is too broad to grant")
    }

    func testAFileCannotBeGrantedAsARoot() throws {
        let file = root.appendingPathComponent("not-a-dir.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FilePathGuard.validateRoot(file))
    }

    func testAnOrdinaryFolderCanBeGranted() throws {
        XCTAssertEqual(try FilePathGuard.validateRoot(root).path, root.path)
    }
}
