import Foundation
import SwiftData

/// One chunk of an attachment's text, plus its embedding once computed. The embedding
/// is stored as packed `Data` (a contiguous block of 32-bit floats) so SwiftData can
/// persist it cheaply; `embedding` is the typed accessor.
@Model
public final class DocumentChunk {
    public var id: UUID = UUID()
    public var ordinal: Int = 0
    public var text: String = ""
    /// `[Float]` packed little-endian; `nil` until the chunk has been embedded.
    public var embeddingData: Data?
    /// Relative path within the source directory when this chunk came from a directory
    /// attachment (e.g. `Sources/App/main.swift`); `nil` for single-file, pasted, or web
    /// attachments. Drives path-aware lexical ranking and per-file inspector labels.
    public var filePath: String?

    public var attachment: Attachment?

    public init(ordinal: Int, text: String) {
        self.id = UUID()
        self.ordinal = ordinal
        self.text = text
    }

    /// Typed view over `embeddingData`.
    public var embedding: [Float]? {
        get { embeddingData.map(Self.decode) }
        set { embeddingData = newValue.map(Self.encode) }
    }

    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        var vector = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.stride)
        _ = vector.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return vector
    }
}
