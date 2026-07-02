import Foundation

/// Spaces requests to each host so the app is a polite web citizen — a per-host minimum
/// interval. An `actor`, so reservations are made atomically (concurrent callers for the
/// same host queue behind each other) even though the wait itself happens off the lock.
actor RateLimiter {
    private var nextAllowed: [String: Date] = [:]
    private let minInterval: TimeInterval

    init(minInterval: TimeInterval = 1.0) {
        self.minInterval = minInterval
    }

    /// Reserves the next polite slot for `host` and waits until it arrives.
    func waitForTurn(host: String) async {
        let now = Date()
        let scheduled = max(now, nextAllowed[host] ?? now)
        // Reserve the slot *before* sleeping so concurrent callers line up.
        nextAllowed[host] = scheduled.addingTimeInterval(minInterval)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

/// The single, app-wide gateway for fetching web pages politely: it respects each host's
/// `robots.txt` (for our user-agent), rate-limits per host, and then delegates to
/// `WebFetcher`. Everything that pulls a URL — manual paste and search results — goes
/// through here, so the app never hammers a site or ignores its robots rules.
public actor WebAccess {
    public static let shared = WebAccess()

    private let limiter = RateLimiter(minInterval: 1.0)
    private var robotsByHost: [String: RobotsTxt.Rules] = [:]
    private let userAgentToken = "Llamatron"

    public enum AccessError: LocalizedError {
        case disallowedByRobots
        public var errorDescription: String? {
            switch self {
            case .disallowedByRobots:
                return "This site's robots.txt asks automated tools not to fetch that page, so it was skipped. You can still open it in a browser and paste the text."
            }
        }
    }

    /// Politely fetches `urlString`: robots.txt check, then per-host rate limit, then the
    /// hardened `WebFetcher`. Throws `AccessError.disallowedByRobots` when robots blocks it.
    public func fetch(_ urlString: String, timeout: TimeInterval = 20) async throws -> (url: URL, html: String) {
        guard let url = WebFetcher.normalizedURL(urlString), let host = url.host else {
            throw WebFetcher.FetchError.invalidURL
        }
        let path = url.path.isEmpty ? "/" : url.path
        guard await isAllowed(host: host, scheme: url.scheme ?? "https", path: path) else {
            throw AccessError.disallowedByRobots
        }
        await limiter.waitForTurn(host: host)
        return try await WebFetcher.fetch(url.absoluteString, timeout: timeout)
    }

    /// Whether robots.txt (cached per host) permits our user-agent to fetch `path`.
    func isAllowed(host: String, scheme: String, path: String) async -> Bool {
        let rules: RobotsTxt.Rules
        if let cached = robotsByHost[host] {
            rules = cached
        } else {
            rules = await fetchRobots(host: host, scheme: scheme)
            robotsByHost[host] = rules
        }
        return RobotsTxt.isAllowed(path, in: rules)
    }

    private func fetchRobots(host: String, scheme: String) async -> RobotsTxt.Rules {
        guard let url = URL(string: "\(scheme)://\(host)/robots.txt") else {
            return RobotsTxt.Rules(directives: [])
        }
        await limiter.waitForTurn(host: host)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Llamatron/1.0", forHTTPHeaderField: "User-Agent")
        // A 2xx text robots.txt is honored; anything else (404/5xx/timeout) means "no rules".
        if let (data, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let text = String(data: data, encoding: .utf8) {
            return RobotsTxt.rules(for: userAgentToken, in: text)
        }
        return RobotsTxt.Rules(directives: [])
    }
}
