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

    @MainActor
    @discardableResult
    public static func load(from url: URL,
                     into session: ChatSession,
                     modelContext: ModelContext) throws -> Attachment {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let data = try Data(contentsOf: url)

        // Image attachments are stored raw and sent to a vision model — not chunked.
        if isImage(url) {
            let attachment = Attachment(fileName: name, imageData: data)
            attachment.session = session
            modelContext.insert(attachment)
            return attachment
        }

        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw LoaderError.unreadable(name)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LoaderError.empty(name)
        }

        let attachment = Attachment(fileName: name, fullText: text)
        attachment.session = session
        modelContext.insert(attachment)

        let chunker = TextChunker()
        for (index, chunkText) in chunker.chunk(text).enumerated() {
            let chunk = DocumentChunk(ordinal: index, text: chunkText)
            chunk.attachment = attachment
            modelContext.insert(chunk)
        }
        return attachment
    }

    /// Creates a text attachment from in-memory text (a pasted note or a fetched web page)
    /// and chunks it for retrieval — the same path file imports use, so the content actually
    /// reaches the model's context. Returns the inserted attachment.
    @MainActor
    @discardableResult
    public static func makeTextAttachment(name: String,
                                   text: String,
                                   into session: ChatSession,
                                   modelContext: ModelContext) -> Attachment {
        let attachment = Attachment(fileName: name, fullText: text)
        attachment.session = session
        modelContext.insert(attachment)

        let chunker = TextChunker()
        for (index, chunkText) in chunker.chunk(text).enumerated() {
            let chunk = DocumentChunk(ordinal: index, text: chunkText)
            chunk.attachment = attachment
            modelContext.insert(chunk)
        }
        return attachment
    }
}
