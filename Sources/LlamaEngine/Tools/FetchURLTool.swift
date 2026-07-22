import Foundation

/// Host-supplied controls for `fetch_url`. Per the 2026-07-21 decision, `fetch_url` MAY
/// reach local/LAN/private addresses (to test local servers), so it is *not* SSRF-blocked;
/// these are the compensating controls the host configures.
public struct FetchURLConfig: Sendable, Equatable {
    /// Allow reaching localhost / private-range / `.local` addresses. Default true (the
    /// deliberate relaxation); set false to restrict `fetch_url` to public hosts.
    public var allowLocalNetwork: Bool
    /// If non-empty, only these hosts (exact or subdomain) may be fetched.
    public var allowedHosts: [String]
    /// Hosts (exact or subdomain) that are always rejected.
    public var blockedHosts: [String]

    public init(allowLocalNetwork: Bool = true, allowedHosts: [String] = [], blockedHosts: [String] = []) {
        self.allowLocalNetwork = allowLocalNetwork
        self.allowedHosts = allowedHosts
        self.blockedHosts = blockedHosts
    }
}

/// Fetches a URL and returns its readable text. `network` and the most open tool, so it is
/// last and always behind confirmation. Goes through `WebAccess.fetch` (robots.txt + per-host
/// rate limit + `WebFetcher`'s http/https-only, content-type, and size checks). Compensating
/// controls beyond that: GET-only, scheme ∈ {http, https}, an optional host allow/deny list,
/// a toggle to disable local reach, and the exact resolved URL surfaced in the confirmation.
public struct FetchURLTool: AgentTool {
    public var config: FetchURLConfig

    public init(config: FetchURLConfig = FetchURLConfig()) {
        self.config = config
    }

    public let name = "fetch_url"
    public let description = "Fetches a web page (or a local/LAN URL) with a GET request and returns its readable text."
    public let riskTier: ToolRiskTier = .network

    public var parameters: JSONSchema {
        .object(properties: [
            "url": .object([
                "type": .string("string"),
                "description": .string("The full http or https URL to fetch.")
            ])
        ], required: ["url"])
    }

    public func validate(_ arguments: JSONValue) throws {
        _ = try Self.validateURL(arguments.string("url"), config: config)
    }

    public func execute(_ arguments: JSONValue) async throws -> ToolResult {
        let url = try Self.validateURL(arguments.string("url"), config: config)
        let (resolved, html) = try await WebAccess.shared.fetch(url.absoluteString)
        let extracted = HTMLExtractor.extract(html)
        var header = resolved.absoluteString
        if !extracted.title.isEmpty { header = "\(extracted.title)\n\(resolved.absoluteString)" }
        let body = extracted.text.isEmpty ? "(No readable text found on the page.)" : extracted.text
        return ToolResult(content: "\(header)\n\n\(body)",
                          displaySummary: "Fetched \(resolved.host ?? resolved.absoluteString)")
    }

    // MARK: - Pure validation

    /// Validates a candidate URL against the scheme rule and the host allow/deny/local
    /// policy. Throws `ToolError.invalidArgument` (nothing runs) on rejection.
    static func validateURL(_ raw: String?, config: FetchURLConfig) throws -> URL {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ToolError.invalidArgument("Provide a URL.")
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host else {
            throw ToolError.invalidArgument("Not a valid URL: \(raw)")
        }
        guard scheme == "http" || scheme == "https" else {
            throw ToolError.invalidArgument("Only http and https URLs are allowed.")
        }
        let lowerHost = host.lowercased()
        if matches(lowerHost, config.blockedHosts) {
            throw ToolError.invalidArgument("That host is on the block list.")
        }
        if !config.allowedHosts.isEmpty, !matches(lowerHost, config.allowedHosts) {
            throw ToolError.invalidArgument("That host is not on the allow list.")
        }
        if !config.allowLocalNetwork, isLocalHost(lowerHost) {
            throw ToolError.invalidArgument("Local and private addresses are turned off for fetch_url.")
        }
        return url
    }

    /// True when `host` equals, or is a subdomain of, any entry in `list`.
    static func matches(_ host: String, _ list: [String]) -> Bool {
        list.contains { entry in
            let target = entry.lowercased()
            return host == target || host.hasSuffix("." + target)
        }
    }

    /// Heuristic for a loopback / private / link-local / `.local` address.
    static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host == "::1" || host == "0.0.0.0" { return true }
        // IPv6 unique-local (fc00::/7) / link-local (fe80::).
        if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, let second) where (16...31).contains(second): return true
        default: return false
        }
    }
}
