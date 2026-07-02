import Foundation

/// Small vector helpers for retrieval scoring. Pure, so they are unit-tested.
public enum Vector {
    /// Cosine similarity in `[-1, 1]`. Returns `0` for empty/mismatched/zero vectors
    /// so callers can treat it as "no signal" rather than crashing.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    /// Packs a vector into contiguous little-endian `Float` bytes for cheap SwiftData
    /// storage. `unpack` is the inverse.
    public static func pack(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func unpack(_ data: Data) -> [Float] {
        var vector = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.stride)
        _ = vector.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return vector
    }
}
