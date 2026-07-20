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
}
