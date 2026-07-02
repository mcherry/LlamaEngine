import Foundation

// MARK: - Models list (/api/tags)

/// One model entry from `/api/tags`. `Sendable` so it can cross actor boundaries.
public struct OllamaModel: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    public let details: Details?
    public let size: Int?
    /// Capability tags from `/api/tags`, e.g. `["completion", "vision", "tools"]`.
    public let capabilities: [String]?

    public var id: String { name }

    public init(name: String, details: Details?, size: Int? = nil, capabilities: [String]? = nil) {
        self.name = name
        self.details = details
        self.size = size
        self.capabilities = capabilities
    }

    public struct Details: Codable, Sendable, Hashable {
        public let family: String?
        public let families: [String]?
        public let parameterSize: String?

        public init(family: String?, families: [String]?, parameterSize: String?) {
            self.family = family
            self.families = families
            self.parameterSize = parameterSize
        }

        enum CodingKeys: String, CodingKey {
            case family
            case families
            case parameterSize = "parameter_size"
        }
    }

    /// Heuristic to keep embedding-only models (e.g. `nomic-embed-text`) out of the
    /// chat picker. `/api/tags` doesn't report capabilities, so we match on the name
    /// and model family, which covers the common embedding models.
    public var isEmbeddingModel: Bool {
        if let capabilities { return capabilities.contains("embedding") }
        var haystack = [name.lowercased(), (details?.family ?? "").lowercased()]
        haystack.append(contentsOf: (details?.families ?? []).map { $0.lowercased() })
        return haystack.contains { $0.contains("embed") }
    }

    /// Whether this model can accept image input (multimodal vision).
    public var supportsVision: Bool {
        capabilities?.contains("vision") ?? false
    }

    /// Human-readable on-disk size, e.g. "18.6 GB".
    public var sizeLabel: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

public struct TagsResponse: Codable, Sendable {
    public let models: [OllamaModel]

    public init(models: [OllamaModel]) {
        self.models = models
    }
}

struct VersionResponse: Codable, Sendable {
    let version: String
}

// MARK: - Model management (/api/ps, /api/pull, /api/delete)

/// A currently-loaded model from `/api/ps`.
public struct RunningModel: Sendable, Identifiable {
    public let name: String
    public let sizeVRAM: Int?
    public var id: String { name }

    public init(name: String, sizeVRAM: Int?) {
        self.name = name
        self.sizeVRAM = sizeVRAM
    }

    public var vramLabel: String? {
        guard let sizeVRAM else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(sizeVRAM), countStyle: .file)
    }
}

struct PsResponse: Decodable, Sendable {
    let models: [Entry]
    struct Entry: Decodable, Sendable {
        let name: String
        let sizeVram: Int?
    }
}

/// One progress update while pulling a model (`/api/pull` streams JSONL).
public struct PullProgress: Sendable {
    public var status: String
    public var completed: Int?
    public var total: Int?

    public init(status: String, completed: Int?, total: Int?) {
        self.status = status
        self.completed = completed
        self.total = total
    }

    /// Download fraction in `0...1` when byte counts are present.
    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
}
