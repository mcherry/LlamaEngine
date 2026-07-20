import Foundation
import LlamaEngine
import SwiftData

/// A file the user attached to a session for context. Holds the extracted plain text
/// and its chunked form; chunk embeddings are computed lazily the first time the
/// retrieval strategy runs. Cascade-deleted with its session.
@Model
public final class Attachment {
    public var id: UUID = UUID()
    public var fileName: String = ""
    public var fullText: String = ""
    /// Cached estimate so the UI can show size without re-counting.
    public var tokenEstimate: Int = 0
    /// Number of files indexed when this attachment is a directory source; `0` for a
    /// single file, pasted note, web page, or image.
    public var fileCount: Int = 0
    public var createdAt: Date = Date.now
    /// Raw image bytes when this attachment is an image (else `nil`). Images are sent
    /// to vision models rather than chunked/embedded as text.
    public var imageData: Data?
    /// Cached vision description of the image, produced by the session's vision model
    /// (the "eyes" step). Empty until extracted; reused across turns.
    public var imageDescription: String = ""

    public var session: ChatSession?

    @Relationship(deleteRule: .cascade, inverse: \DocumentChunk.attachment)
    public var chunks: [DocumentChunk] = []

    public init(fileName: String, fullText: String) {
        self.id = UUID()
        self.fileName = fileName
        self.fullText = fullText
        self.tokenEstimate = TokenEstimator.estimate(fullText)
        self.createdAt = .now
    }

    /// Creates an image attachment from raw bytes (no text chunks).
    public init(fileName: String, imageData: Data) {
        self.id = UUID()
        self.fileName = fileName
        self.imageData = imageData
        self.fullText = ""
        self.tokenEstimate = 0
        self.createdAt = .now
    }

    /// Whether this attachment is an image (vision input) rather than a text document.
    public var isImage: Bool { imageData != nil }

    /// Whether this attachment is a directory source (many files indexed as one unit)
    /// rather than a single file, note, or web page.
    public var isDirectory: Bool { fileCount > 0 }

    /// Base64 encoding of the image, for the Ollama `images` field.
    public var imageBase64: String? {
        imageData?.base64EncodedString()
    }

    public var orderedChunks: [DocumentChunk] {
        chunks.sorted { $0.ordinal < $1.ordinal }
    }
}
