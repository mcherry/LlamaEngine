import Foundation

/// Splits text into chunks sized for embedding/retrieval, preferring to break on
/// paragraph boundaries so each chunk stays coherent. Over-long paragraphs are hard
/// split by character count. Pure and synchronous so it can be unit-tested.
public struct TextChunker {
    public var targetTokens: Int
    public var overlapTokens: Int

    public init(targetTokens: Int = 320, overlapTokens: Int = 48) {
        self.targetTokens = max(1, targetTokens)
        self.overlapTokens = max(0, overlapTokens)
    }

    private var maxChars: Int { targetTokens * TokenEstimator.charsPerToken }
    private var overlapChars: Int { overlapTokens * TokenEstimator.charsPerToken }

    public func chunk(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Atomic pieces: paragraphs, with any over-long paragraph hard-split.
        var pieces: [String] = []
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if p.count <= maxChars {
                pieces.append(p)
            } else {
                pieces.append(contentsOf: hardSplit(p))
            }
        }

        // Accumulate pieces into chunks up to the target size.
        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + 2 + piece.count <= maxChars {
                current += "\n\n" + piece
            } else {
                chunks.append(current)
                current = piece
            }
        }
        if !current.isEmpty { chunks.append(current) }

        return applyOverlap(chunks)
    }

    /// Prepends a short tail of the previous chunk to each subsequent chunk so a fact
    /// spanning a boundary is still retrievable from either side.
    private func applyOverlap(_ chunks: [String]) -> [String] {
        guard overlapChars > 0, chunks.count > 1 else { return chunks }
        var result = [chunks[0]]
        for i in 1..<chunks.count {
            let tail = String(chunks[i - 1].suffix(overlapChars))
            result.append(tail + "\n\n" + chunks[i])
        }
        return result
    }

    private func hardSplit(_ text: String) -> [String] {
        var result: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[idx..<end]))
            idx = end
        }
        return result
    }
}
