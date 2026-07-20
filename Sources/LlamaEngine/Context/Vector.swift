import Foundation
import Accelerate

/// Small vector helpers for retrieval scoring. Pure, so they are unit-tested.
public enum Vector {
    /// Cosine similarity in `[-1, 1]`. Returns `0` for empty/mismatched/zero vectors
    /// so callers can treat it as "no signal" rather than crashing. Backed by Accelerate
    /// (`vDSP`) so the dot product and norms are SIMD-vectorized — this is the retrieval
    /// scoring hot path over potentially thousands of chunks.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dot: Float = 0
        var sumSqA: Float = 0
        var sumSqB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)
        vDSP_svesq(a, 1, &sumSqA, n)   // Σ a²
        vDSP_svesq(b, 1, &sumSqB, n)   // Σ b²
        let denom = (sumSqA * sumSqB).squareRoot()
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
