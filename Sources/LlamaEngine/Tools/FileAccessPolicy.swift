import Foundation

/// Host-supplied controls for the filesystem tools. Empty `roots` means no filesystem
/// access at all — the tool refuses every path, so forgetting to configure it fails closed.
///
/// The app is no longer sandboxed, so this policy *is* the containment boundary. Nothing
/// below it stops a bad path; treat every change here as security-relevant.
public struct FileAccessPolicy: Sendable, Equatable {
    /// Directories the user explicitly granted. A path must resolve strictly inside one
    /// of these. Never populated from model output — only from a folder picker.
    public var roots: [URL]
    /// Largest file the tool will write, in bytes.
    public var maxBytes: Int
    /// Whether dot-files and dot-directories may be written *below* a root. Off by
    /// default: it is what keeps `.ssh`, `.aws`, `.env`, `.git` and shell rc files out
    /// of reach even when a root sits above them.
    public var allowHidden: Bool

    public init(roots: [URL] = [], maxBytes: Int = 1_048_576, allowHidden: Bool = false) {
        self.roots = roots
        self.maxBytes = maxBytes
        self.allowHidden = allowHidden
    }
}

/// Resolves and contains filesystem paths for the `mutating` file tools.
///
/// The threat model is an attacker-controlled *model*: web-search results or a fetched
/// page can carry injected instructions, so every path the model proposes is hostile
/// input. Containment is therefore structural, never a matter of the model behaving:
///
/// 1. absolute paths only — a relative path has no well-defined base here
/// 2. lexical `..` and `.` removed, then any surviving `..` rejected
/// 3. symlinks resolved on the deepest *existing* ancestor, so a not-yet-created file
///    cannot be smuggled through a symlinked parent
/// 4. containment compared **component-wise** against resolved roots, so `/tmp/foo-evil`
///    does not pass for root `/tmp/foo`
/// 5. dot-files below the root rejected unless explicitly allowed
/// 6. an existing symlink at the target is refused outright rather than written through
public enum FilePathGuard {

    /// Path components that are never writable, even inside a granted root. These are
    /// persistence and credential locations; a dot-prefix rule alone would miss them.
    static let deniedComponents: Set<String> = [
        "LaunchAgents", "LaunchDaemons", "StartupItems", "Keychains",
        "authorized_keys", "known_hosts", "id_rsa", "id_ed25519", "credentials"
    ]

    /// Directories that may never be granted as roots, however the user picks them.
    /// Compared against the symlink-resolved path.
    static let deniedRoots: Set<String> = [
        "/", "/System", "/usr", "/bin", "/sbin", "/etc", "/Library",
        "/Applications", "/Volumes", "/private", "/private/etc", "/private/var"
    ]

    // MARK: - Root validation

    /// Validates a directory the *user* chose in a folder picker. Rejects the filesystem
    /// root, system trees, and the home directory itself — all so broad that granting
    /// them would defeat the point of asking.
    public static func validateRoot(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ToolError.invalidArgument("\(url.path) is not an existing folder.")
        }
        if deniedRoots.contains(resolved.path) {
            throw ToolError.invalidArgument("\(resolved.path) is a system location and cannot be granted.")
        }
        // NSHomeDirectory() rather than homeDirectoryForCurrentUser: the latter is macOS-only
        // and this type has to compile for the iOS target too.
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path == home.path {
            throw ToolError.invalidArgument("Grant a specific folder rather than your whole home directory.")
        }
        if resolved.pathComponents.contains(where: { deniedComponents.contains($0) }) {
            throw ToolError.invalidArgument("\(resolved.path) contains a protected system location.")
        }
        return resolved
    }

    // MARK: - Path resolution

    /// Resolves a model-proposed path and proves it lands inside a granted root.
    /// Throws `ToolError.invalidArgument` — nothing is created or opened on failure.
    public static func resolve(_ raw: String?, policy: FileAccessPolicy) throws -> URL {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            throw ToolError.invalidArgument("Provide a file path.")
        }
        guard !policy.roots.isEmpty else {
            throw ToolError.invalidArgument("No folders have been granted for file access.")
        }
        // A NUL byte truncates the path at the syscall boundary, so a name that passed
        // these checks could open a different file.
        guard !trimmed.contains("\0") else {
            throw ToolError.invalidArgument("That path contains an illegal character.")
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ToolError.invalidArgument("Use an absolute path, for example /tmp/scratch/notes.txt")
        }

        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        guard !standardized.pathComponents.contains("..") else {
            throw ToolError.invalidArgument("That path escapes its folder.")
        }

        let resolved = resolvingExistingAncestor(standardized)

        let roots = policy.roots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        }
        guard let root = roots.first(where: { contains($0, resolved) }) else {
            throw ToolError.invalidArgument(
                "\(standardized.path) is outside the folders you granted. Allowed: "
                + roots.map(\.path).joined(separator: ", "))
        }

        // Only the components *below* the root are the model's choice, so a user who
        // deliberately grants a hidden folder is not punished for it.
        let relative = Array(resolved.pathComponents.dropFirst(root.pathComponents.count))
        if !policy.allowHidden, relative.contains(where: { $0.hasPrefix(".") }) {
            throw ToolError.invalidArgument("Hidden files and folders are not writable.")
        }
        if relative.contains(where: { deniedComponents.contains($0) }) {
            throw ToolError.invalidArgument("That location is protected.")
        }

        try rejectIfSymlink(at: standardized)
        try rejectIfSymlink(at: resolved)
        return resolved
    }

    // MARK: - Internals

    /// Resolves symlinks on the deepest ancestor that exists, then re-appends the
    /// not-yet-existing tail. `resolvingSymlinksInPath()` alone is not enough: it leaves
    /// a path whose parent is a symlink untouched when the leaf does not exist yet, which
    /// is exactly the case when creating a new file.
    static func resolvingExistingAncestor(_ url: URL) -> URL {
        let fm = FileManager.default
        var tail: [String] = []
        var current = url.standardizedFileURL

        while !fm.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return url.standardizedFileURL }
            tail.insert(current.lastPathComponent, at: 0)
            current = parent
        }

        var resolved = current.resolvingSymlinksInPath().standardizedFileURL
        for component in tail { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }

    /// Component-wise containment. A string prefix test would accept `/tmp/foo-evil`
    /// for root `/tmp/foo`; this cannot. `child` must be strictly below `root`.
    static func contains(_ root: URL, _ child: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.count > rootComponents.count else { return false }
        return Array(childComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Refuses a path whose leaf is itself a symlink. Writing through one would land
    /// outside the root even though the resolved path checked out.
    static func rejectIfSymlink(at url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ToolError.invalidArgument("\(url.path) is a symbolic link.")
        }
    }
}
