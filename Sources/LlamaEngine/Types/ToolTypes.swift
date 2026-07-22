import Foundation

/// A minimal, dependency-free JSON value. Tool arguments and JSON-Schema fragments are
/// decoded into this — inspected as data, never evaluated as code. `Codable` so it
/// round-trips on the wire; `Equatable` so decoded calls are easy to assert in tests.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public extension JSONValue {
    /// The object dictionary, when this is an object.
    var objectValue: [String: JSONValue]? {
        if case let .object(dict) = self { return dict }
        return nil
    }

    /// The string at `key`, when this is an object whose value at `key` is a string.
    func string(_ key: String) -> String? {
        if case let .object(dict) = self, case let .string(value)? = dict[key] { return value }
        return nil
    }

    /// The integer at `key`, when this is an object whose value at `key` is a number.
    func int(_ key: String) -> Int? {
        if case let .object(dict) = self, case let .number(value)? = dict[key] { return Int(value) }
        return nil
    }

    /// A compact JSON string of this value, with verbatim keys ("{}" on failure). Used to
    /// serialize tool-call arguments for the wire and for the audit record.
    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

/// A JSON-Schema fragment describing a tool's parameters, sent to the model. A thin
/// wrapper over `JSONValue` so it encodes transparently as the schema object.
public struct JSONSchema: Codable, Sendable, Equatable {
    public var value: JSONValue

    public init(_ value: JSONValue) { self.value = value }

    public init(from decoder: Decoder) throws {
        value = try JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    /// Builds an `{"type":"object", "properties":{…}, "required":[…]}` schema — the shape
    /// tool parameters take. Keys are emitted verbatim, so use snake_case parameter names:
    /// Ollama snake-cases request keys, which would otherwise rename camelCase params.
    public static func object(properties: [String: JSONValue], required: [String] = []) -> JSONSchema {
        var root: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            root["required"] = .array(required.map(JSONValue.string))
        }
        return JSONSchema(.object(root))
    }

    /// An empty object schema, for tools that take no arguments.
    public static let empty = JSONSchema(.object(["type": .string("object"), "properties": .object([:])]))
}

/// A tool definition sent to the model: what it is and the shape of its arguments. The
/// model may respond with a `ToolCall`; it never runs anything itself.
public struct ToolSpec: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: JSONSchema

    public init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Wraps a `ToolSpec` in the OpenAI `{"type":"function","function":{…}}` envelope both
/// Ollama and llama.cpp expect in a request's `tools` array.
struct ToolWireEnvelope: Encodable {
    let type = "function"
    let function: ToolSpec

    init(_ function: ToolSpec) { self.function = function }
}

/// A tool call the model proposed, normalized from either backend's stream. `arguments`
/// is decoded data — inspected and validated, never executed as code.
public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// A raw fragment of a streamed tool call. Ollama delivers a whole call in one delta
/// (arguments as a JSON object, re-serialized here to a string); llama.cpp streams a
/// call across several deltas keyed by `index` (arguments as a growing JSON string).
/// `ToolCallAssembler` merges deltas into finished `ToolCall`s.
public struct ToolCallDelta: Sendable, Equatable {
    public var index: Int
    public var id: String?
    public var name: String?
    public var argumentsFragment: String

    public init(index: Int, id: String? = nil, name: String? = nil, argumentsFragment: String = "") {
        self.index = index
        self.id = id
        self.name = name
        self.argumentsFragment = argumentsFragment
    }
}

/// Merges streamed `ToolCallDelta`s into finished `ToolCall`s. Pure and static so the
/// streaming accumulation can be unit-tested without a server. Fragments are grouped by
/// `index` (first-seen order); the first non-empty `id`/`name` wins and argument
/// fragments are concatenated in arrival order, then parsed into a `JSONValue`.
public enum ToolCallAssembler {
    public static func assemble(_ deltas: [ToolCallDelta]) -> [ToolCall] {
        var order: [Int] = []
        var byIndex: [Int: (id: String?, name: String?, arguments: String)] = [:]
        for delta in deltas {
            if byIndex[delta.index] == nil {
                order.append(delta.index)
                byIndex[delta.index] = (nil, nil, "")
            }
            var entry = byIndex[delta.index]!
            if let id = delta.id, !id.isEmpty { entry.id = id }
            if let name = delta.name, !name.isEmpty { entry.name = name }
            entry.arguments += delta.argumentsFragment
            byIndex[delta.index] = entry
        }
        return order.compactMap { index in
            let entry = byIndex[index]!
            // A fragment group with no name is not a real call (defensive against odd streams).
            guard let name = entry.name, !name.isEmpty else { return nil }
            return ToolCall(id: entry.id ?? "call_\(index)",
                            name: name,
                            arguments: parseArguments(entry.arguments))
        }
    }

    /// Parses an accumulated argument string into a `JSONValue`; an empty or malformed
    /// string yields an empty object rather than throwing, so a partial or odd stream
    /// degrades gracefully instead of dropping the call.
    static func parseArguments(_ raw: String) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object([:])
        }
        return value
    }
}
