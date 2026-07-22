import Foundation

/// The "hello world" tool: returns the current date and time, optionally in a given IANA
/// time zone. `pure` — no I/O and no side effects — so it exercises the whole agent loop
/// with zero attack surface. The formatting is a pure static function so the output is
/// unit-testable with a fixed clock.
public struct CurrentDateTimeTool: AgentTool {
    public init() {}

    public let name = "current_datetime"
    public let description = "Returns the current date and time. Optionally in a specific IANA time zone."
    public let riskTier: ToolRiskTier = .pure

    public var parameters: JSONSchema {
        .object(properties: [
            "timezone": .object([
                "type": .string("string"),
                "description": .string("IANA time zone identifier, e.g. \"America/New_York\". Defaults to UTC.")
            ])
        ])
    }

    public func validate(_ arguments: JSONValue) throws {
        if let identifier = arguments.string("timezone"), TimeZone(identifier: identifier) == nil {
            throw ToolError.invalidArgument("Unknown time zone: \(identifier)")
        }
    }

    public func execute(_ arguments: JSONValue) async throws -> ToolResult {
        let identifier = arguments.string("timezone") ?? "UTC"
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw ToolError.invalidArgument("Unknown time zone: \(identifier)")
        }
        let text = Self.format(Date(), timeZone: timeZone, zoneName: identifier)
        return ToolResult(content: text, displaySummary: text)
    }

    /// Formats `date` in `timeZone`, labelled with `zoneName` (the requested identifier).
    /// Labelled explicitly because `TimeZone(identifier: "UTC").identifier` normalizes to
    /// "GMT" on Apple platforms. Pure and static so the exact output can be unit-tested.
    public static func format(_ date: Date, timeZone: TimeZone, zoneName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(formatter.string(from: date)) \(zoneName)"
    }
}
