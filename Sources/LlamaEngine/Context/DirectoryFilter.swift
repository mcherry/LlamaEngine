import Foundation

/// Pure rules for deciding which files and directories to index when a whole folder is
/// attached as a source. Keeping the policy here (rather than buried in the file walker)
/// makes it testable and easy to tune: what to descend into, what to skip, and the size
/// caps that keep a huge tree from blowing up memory or the index.
///
/// The walker applies these in cheap-to-expensive order: directory name, file name /
/// extension, on-disk size, then a binary-content sniff on the bytes actually read.
public enum DirectoryFilter {
    /// Skip any single file larger than this (bytes). Big files are usually data dumps,
    /// minified bundles, or media — costly to chunk and rarely useful as prose context.
    public static let maxFileBytes = 1_000_000

    /// Stop indexing once this many files have been taken, so an enormous monorepo stays
    /// bounded. The walker enforces it; the value lives here so tests can reason about it.
    public static let maxFiles = 5_000

    /// Stop indexing once the taken files exceed this many bytes of text in total.
    public static let maxTotalBytes = 64 * 1_000_000

    /// Directory names whose whole subtree is skipped: dependency caches, build output,
    /// virtualenvs, and VCS metadata. Matched case-insensitively. Hidden directories
    /// (leading `.`) are skipped separately by the walker.
    public static let skippedDirectories: Set<String> = [
        "node_modules", "bower_components", "vendor", "pods", "carthage",
        "build", "dist", "out", "target", "bin", "obj", "deriveddata",
        ".build", ".next", ".nuxt", ".svelte-kit", ".output", ".parcel-cache",
        "venv", ".venv", "env", "__pycache__", ".mypy_cache", ".pytest_cache",
        ".tox", ".gradle", ".idea", ".vscode", ".cache", ".terraform",
        "coverage", ".nyc_output", "tmp", "temp", "logs",
    ]

    /// File extensions treated as binary / non-text and skipped outright (images, media,
    /// archives, compiled artifacts, databases, fonts). Matched case-insensitively.
    public static let binaryExtensions: Set<String> = [
        // images
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif",
        "ico", "icns", "svg", "psd", "ai",
        // audio / video
        "mp3", "wav", "flac", "aac", "ogg", "m4a", "mp4", "mov", "avi", "mkv", "webm",
        // archives
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "jar", "war", "ear",
        // compiled / binary artifacts
        "o", "a", "so", "dylib", "dll", "exe", "class", "pyc", "pyo", "wasm",
        "bin", "dat", "dmg", "pkg", "iso",
        // databases
        "db", "sqlite", "sqlite3", "realm", "mdb",
        // fonts
        "woff", "woff2", "ttf", "otf", "eot",
        // documents that aren't plain text
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "numbers", "pages",
        // misc large/generated
        "lock", "map", "min",
    ]

    /// Whether to skip an entire directory subtree by its name.
    public static func shouldSkipDirectory(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        return skippedDirectories.contains(name.lowercased())
    }

    /// Whether to skip a file by its name alone (before reading it). Hidden files and
    /// known-binary extensions are rejected here.
    public static func shouldSkipFile(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return binaryExtensions.contains(ext)
    }

    /// A cheap heuristic that a blob is binary rather than text: a NUL byte in the first
    /// few kilobytes. Real text files effectively never contain NUL, while executables,
    /// images, and archives almost always do near the start.
    public static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8_000).contains(0)
    }

    /// The path of `url` relative to `root` (POSIX-style, no leading slash), e.g.
    /// `Sources/App/main.swift`. Falls back to the last path component if `url` is
    /// somehow not under `root`.
    public static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return url.lastPathComponent }
        var relative = String(fullPath.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? url.lastPathComponent : relative
    }
}
