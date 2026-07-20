import Foundation
import LlamaEngine
import SwiftData
import UniformTypeIdentifiers

/// Reads a user-selected text file and turns it into an `Attachment` with chunked
/// `DocumentChunk`s, inserted into the given session. Embeddings are computed later,
/// lazily, by the retrieval strategy.
public enum AttachmentLoader {
    /// Text-like content types offered in the file importer.
    public static let allowedTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .sourceCode, .json, .xml,
                               .yaml, .commaSeparatedText, .html]
        for ext in ["md", "markdown", "log", "toml", "ini", "csv", "tsv",
                    "swift", "py", "js", "ts", "rs", "go", "rb", "java",
                    "c", "h", "cpp", "hpp", "sh", "sql"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    /// Image content types for vision-model attachments.
    public static let imageTypes: [UTType] = [.png, .jpeg, .gif, .bmp, .tiff, .webP, .heic, .image]

    /// All types offered in the importer (text documents + images).
    public static var importTypes: [UTType] { allowedTypes + imageTypes }

    public enum LoaderError: LocalizedError {
        case unreadable(String)
        case empty(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Couldn't read \(name) as text."
            case .empty(let name): return "\(name) is empty."
            }
        }
    }

    /// Whether a URL looks like an image, by its uniform type or extension.
    public static func isImage(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) {
            return true
        }
        return ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif"]
            .contains(url.pathExtension.lowercased())
    }

    /// A `Sendable` snapshot of what to insert, computed off the main actor.
    private struct Prepared: Sendable {
        let imageData: Data?
        let text: String?
        let chunks: [String]
    }

    /// Reads, decodes, and chunks a file — the IO + CPU work — off the main actor. Pure and
    /// `nonisolated` so it runs on a detached task. Uses a memory-mapped read to avoid copying
    /// a large file into memory.
    private static func prepareFile(url: URL, name: String) throws -> Prepared {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if isImage(url) { return Prepared(imageData: data, text: nil, chunks: []) }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw LoaderError.unreadable(name)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LoaderError.empty(name)
        }
        return Prepared(imageData: nil, text: text, chunks: TextChunker().chunk(text))
    }

    @MainActor
    @discardableResult
    public static func load(from url: URL,
                     into session: ChatSession,
                     modelContext: ModelContext,
                     onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> Attachment {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent

        // Read, decode, and chunk off the main actor so a large file doesn't freeze the UI.
        let prepared = try await Task.detached(priority: .userInitiated) {
            try prepareFile(url: url, name: name)
        }.value

        // Image attachments are stored raw and sent to a vision model — not chunked.
        if let imageData = prepared.imageData {
            let attachment = Attachment(fileName: name, imageData: imageData)
            attachment.session = session
            modelContext.insert(attachment)
            return attachment
        }

        let attachment = Attachment(fileName: name, fullText: prepared.text ?? "")
        attachment.session = session
        modelContext.insert(attachment)
        await insertChunks(prepared.chunks, into: attachment, modelContext: modelContext, onProgress: onProgress)
        return attachment
    }

    /// Inserts `DocumentChunk`s in batches, yielding to the run loop between batches so a large
    /// source stays responsive, and reporting progress in `0...1`. SwiftData `@Model`s must be
    /// created on the main actor, so this stays here; only the read/chunk work moved off.
    @MainActor
    private static func insertChunks(_ chunks: [String],
                                     into attachment: Attachment,
                                     modelContext: ModelContext,
                                     onProgress: (@MainActor (Double) -> Void)?) async {
        let total = chunks.count
        guard total > 0 else { onProgress?(1); return }
        let batchSize = 200
        var index = 0
        while index < total {
            let end = min(index + batchSize, total)
            for i in index..<end {
                let chunk = DocumentChunk(ordinal: i, text: chunks[i])
                chunk.attachment = attachment
                modelContext.insert(chunk)
            }
            index = end
            onProgress?(Double(index) / Double(total))
            if index < total { await Task.yield() }
        }
    }

    /// Creates a text attachment from in-memory text (a pasted note or a fetched web page)
    /// and chunks it for retrieval — the same path file imports use, so the content actually
    /// reaches the model's context. Returns the inserted attachment.
    @MainActor
    @discardableResult
    public static func makeTextAttachment(name: String,
                                   text: String,
                                   into session: ChatSession,
                                   modelContext: ModelContext,
                                   onProgress: (@MainActor (Double) -> Void)? = nil) async -> Attachment {
        let attachment = Attachment(fileName: name, fullText: text)
        attachment.session = session
        modelContext.insert(attachment)
        let chunks = await Task.detached(priority: .userInitiated) { TextChunker().chunk(text) }.value
        await insertChunks(chunks, into: attachment, modelContext: modelContext, onProgress: onProgress)
        return attachment
    }

    // MARK: - Directory sources

    /// A `Sendable` snapshot of one indexed file: its path relative to the attached folder,
    /// plus its chunked text.
    private struct PreparedFile: Sendable {
        let path: String
        let chunks: [String]
    }

    /// The result of walking a directory off the main actor — the files worth indexing,
    /// already chunked, and whether the caps cut the walk short.
    private struct PreparedDirectory: Sendable {
        let files: [PreparedFile]
        let truncated: Bool
    }

    /// Attaches a whole folder as one retrievable source: walks the tree, skipping
    /// dependency/build directories, binary or oversized files, and hidden entries, then
    /// chunks each surviving text file tagged with its relative path. The walk + read +
    /// chunk work runs off the main actor; only the `@Model` inserts happen here. Progress
    /// is reported as a human-readable status plus a `0...1` fraction.
    @MainActor
    @discardableResult
    public static func indexDirectory(at url: URL,
                                      into session: ChatSession,
                                      modelContext: ModelContext,
                                      onProgress: (@MainActor (String, Double) -> Void)? = nil) async throws -> Attachment {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let folderName = url.lastPathComponent

        onProgress?("Scanning \(folderName)…", 0)
        // Walk, read, and chunk the whole tree off the main actor so a big repo doesn't
        // freeze the UI while it's scanned.
        let prepared = await Task.detached(priority: .userInitiated) {
            scanDirectory(root: url)
        }.value
        guard !prepared.files.isEmpty else { throw LoaderError.empty(folderName) }

        let attachment = Attachment(fileName: folderName, fullText: "")
        attachment.fileCount = prepared.files.count
        attachment.session = session
        modelContext.insert(attachment)
        await insertDirectoryChunks(prepared.files,
                                    into: attachment,
                                    modelContext: modelContext,
                                    onProgress: onProgress)
        return attachment
    }

    /// Walks `root` depth-first, applying `DirectoryFilter` in cheap-to-expensive order
    /// (directory name, file name, size, then a binary-content sniff) and enforcing the
    /// file-count/byte caps. Pure and `nonisolated`, so it runs on a detached task. Uses
    /// memory-mapped reads to avoid copying large files into memory.
    private static func scanDirectory(root: URL) -> PreparedDirectory {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsHiddenFiles],
                                                      errorHandler: { _, _ in true }) else {
            return PreparedDirectory(files: [], truncated: false)
        }

        let chunker = TextChunker()
        var files: [PreparedFile] = []
        var totalBytes = 0
        var truncated = false

        for case let fileURL as URL in enumerator {
            if files.count >= DirectoryFilter.maxFiles || totalBytes >= DirectoryFilter.maxTotalBytes {
                truncated = true
                break
            }
            let values = try? fileURL.resourceValues(forKeys: keys)

            if values?.isDirectory == true {
                if DirectoryFilter.shouldSkipDirectory(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if DirectoryFilter.shouldSkipFile(fileURL.lastPathComponent) { continue }
            if let size = values?.fileSize, size > DirectoryFilter.maxFileBytes { continue }

            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                  !data.isEmpty,
                  !DirectoryFilter.looksBinary(data),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let chunks = chunker.chunk(text)
            guard !chunks.isEmpty else { continue }
            files.append(PreparedFile(path: DirectoryFilter.relativePath(of: fileURL, under: root),
                                      chunks: chunks))
            totalBytes += data.count
        }
        // Stable path order so chunk ordinals are deterministic and the assembled context
        // reads file-by-file rather than in filesystem enumeration order.
        return PreparedDirectory(files: files.sorted { $0.path < $1.path }, truncated: truncated)
    }

    /// Inserts every file's chunks as `DocumentChunk`s tagged with their relative path, in
    /// batches that yield to the run loop so a large tree stays responsive, reporting a
    /// per-file status and `0...1` progress.
    @MainActor
    private static func insertDirectoryChunks(_ files: [PreparedFile],
                                              into attachment: Attachment,
                                              modelContext: ModelContext,
                                              onProgress: (@MainActor (String, Double) -> Void)?) async {
        let totalChunks = files.reduce(0) { $0 + $1.chunks.count }
        guard totalChunks > 0 else { onProgress?("", 1); return }
        var ordinal = 0
        var inserted = 0
        var tokens = 0
        for (fileIndex, file) in files.enumerated() {
            for text in file.chunks {
                let chunk = DocumentChunk(ordinal: ordinal, text: text)
                chunk.filePath = file.path
                chunk.attachment = attachment
                modelContext.insert(chunk)
                ordinal += 1
                inserted += 1
                tokens += TokenEstimator.estimate(text)
                if inserted % 200 == 0 {
                    onProgress?("Indexing \(attachment.fileName): \(fileIndex + 1) of \(files.count) files",
                                Double(inserted) / Double(totalChunks))
                    await Task.yield()
                }
            }
        }
        attachment.tokenEstimate = tokens
        onProgress?("", 1)
    }
}
