import Foundation

/// Writes a text file inside a folder the user granted. The first `mutating` tool, so it
/// is the first that can change anything on disk.
///
/// Containment is `FilePathGuard`'s job; this type owns the *write* rules:
/// - text only, size-capped
/// - never sets the executable bit, even for a `.sh` file — the user runs it deliberately,
///   so a script the model wrote cannot become a script the machine runs on its own
/// - atomic replace, so a failed write cannot leave a half-written file behind
/// - refuses to replace a directory
public struct WriteFileTool: AgentTool {
    public var policy: FileAccessPolicy

    public init(policy: FileAccessPolicy = FileAccessPolicy()) {
        self.policy = policy
    }

    public let name = "write_file"
    public let description = """
        Writes a text file to disk inside a folder the user has granted access to. \
        Creates the file if it does not exist and replaces it if it does. Files are never \
        made executable; ask the user to run scripts themselves.
        """
    public let riskTier: ToolRiskTier = .mutating

    public var parameters: JSONSchema {
        .object(properties: [
            "path": .object([
                "type": .string("string"),
                "description": .string("Absolute path of the file to write, e.g. /tmp/scratch/build.sh")
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("The full text to write. Replaces the file's existing contents.")
            ])
        ], required: ["path", "content"])
    }

    public func validate(_ arguments: JSONValue) throws {
        _ = try resolveTarget(arguments)
    }

    public func execute(_ arguments: JSONValue) async throws -> ToolResult {
        let (url, data) = try resolveTarget(arguments)
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        let existed = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if existed, isDirectory.boolValue {
            throw ToolError.invalidArgument("\(url.path) is a folder.")
        }

        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ToolError.executionFailed("Could not write \(url.path): \(error.localizedDescription)")
        }
        // Explicit, non-executable mode: .atomic replaces the inode, so whatever the old
        // file's permissions were does not carry over.
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let verb = existed ? "Replaced" : "Created"
        return ToolResult(content: "\(verb) \(url.path) (\(data.count) bytes).",
                          displaySummary: "\(verb) \(url.lastPathComponent)")
    }

    // MARK: - Pure validation

    /// Resolves and contains the path and validates the payload, without touching disk
    /// beyond the existence checks containment itself requires.
    func resolveTarget(_ arguments: JSONValue) throws -> (url: URL, data: Data) {
        let url = try FilePathGuard.resolve(arguments.string("path"), policy: policy)
        guard let content = arguments.string("content") else {
            throw ToolError.invalidArgument("Provide the file's content as text.")
        }
        guard let data = content.data(using: .utf8) else {
            throw ToolError.invalidArgument("Content must be valid text.")
        }
        guard data.count <= policy.maxBytes else {
            throw ToolError.invalidArgument(
                "That content is \(data.count) bytes; the limit is \(policy.maxBytes).")
        }
        return (url, data)
    }
}
