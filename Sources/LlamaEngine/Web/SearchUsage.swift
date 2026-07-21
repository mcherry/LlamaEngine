import Foundation

/// A per-provider request tally for the current month, so the app can show roughly how much
/// each search engine has been used (handy for free-tier awareness). Deliberately just a
/// local count — **an estimate, not authoritative billing** (see the observed-limits model).
/// Persisted by the host app as a JSON blob; all the logic here is pure and testable.
public struct SearchUsage: Codable, Sendable, Equatable {
    /// The month these counts belong to, as `"YYYY-MM"`. Counts reset when the month rolls over.
    public var month: String
    /// Request count per provider, keyed by `ProviderKind.rawValue`.
    public var counts: [String: Int]

    public init(month: String, counts: [String: Int] = [:]) {
        self.month = month
        self.counts = counts
    }

    /// The current month key (`"YYYY-MM"`) in the user's calendar.
    public static func currentMonth(_ now: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Decodes usage from a JSON blob, resetting to an empty current month when the blob is
    /// missing, malformed, or from a previous month.
    public static func decode(_ json: String, now: Date = Date()) -> SearchUsage {
        let month = currentMonth(now)
        guard let data = json.data(using: .utf8),
              let usage = try? JSONDecoder().decode(SearchUsage.self, from: data),
              usage.month == month else {
            return SearchUsage(month: month)
        }
        return usage
    }

    /// This value re-encoded to a JSON string for persistence.
    public func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Returns an updated JSON blob with each provider's current-month count incremented.
    public static func recording(_ providers: [WebSearch.ProviderKind], into json: String, now: Date = Date()) -> String {
        var usage = decode(json, now: now)
        for provider in providers { usage.counts[provider.rawValue, default: 0] += 1 }
        return usage.encoded()
    }

    /// The recorded request count for `provider` in the current month (0 if none / rolled over).
    public static func count(_ provider: WebSearch.ProviderKind, in json: String, now: Date = Date()) -> Int {
        decode(json, now: now).counts[provider.rawValue] ?? 0
    }
}
