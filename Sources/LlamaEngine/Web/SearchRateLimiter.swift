import Foundation

/// Pure per-provider cooldown bookkeeping for meta-search rate-limit hygiene. When a provider
/// rate-limits (HTTP 429) or reports an exhausted quota (402/432/433), it's parked until a
/// cooldown elapses so repeated fan-outs never re-hit it — the key protection against getting a
/// key throttled or banned during heavy use. Deterministic: inject `now` in tests.
public struct RateLimitGate: Sendable {
    public struct Cooldown: Sendable, Equatable {
        public let reason: WebSearch.SearchFailureReason
        public let until: Date
    }

    public private(set) var cooldowns: [WebSearch.ProviderKind: Cooldown] = [:]
    /// Backoff applied to a rate-limit that arrives with no `Retry-After` header.
    public var defaultBackoff: TimeInterval
    /// Backoff applied when a provider reports an exhausted quota/plan (a session-ish parking).
    public var quotaCooldown: TimeInterval

    public init(defaultBackoff: TimeInterval = 60, quotaCooldown: TimeInterval = 3600) {
        self.defaultBackoff = defaultBackoff
        self.quotaCooldown = quotaCooldown
    }

    /// Records the result of querying `provider`: a nil reason (success) clears any cooldown; a
    /// rate-limit parks it for `retryAfter` (or `defaultBackoff`); out-of-quota parks it for
    /// `quotaCooldown`; auth/unavailable are left alone (user-fixable / transient).
    public mutating func record(_ provider: WebSearch.ProviderKind,
                                reason: WebSearch.SearchFailureReason?,
                                retryAfter: TimeInterval? = nil,
                                now: Date = Date()) {
        guard let reason else { cooldowns[provider] = nil; return }
        let delay: TimeInterval
        switch reason {
        case .rateLimited: delay = max(0, retryAfter ?? defaultBackoff)
        case .outOfQuota: delay = quotaCooldown
        case .authentication, .unavailable: return
        }
        cooldowns[provider] = Cooldown(reason: reason, until: now.addingTimeInterval(delay))
    }

    /// Whether `provider` may be queried at `now` (an elapsed cooldown counts as available).
    public func isAvailable(_ provider: WebSearch.ProviderKind, now: Date = Date()) -> Bool {
        guard let cooldown = cooldowns[provider] else { return true }
        return now >= cooldown.until
    }

    /// The active cooldown (reason + remaining seconds) for `provider`, or nil if available.
    public func status(_ provider: WebSearch.ProviderKind, now: Date = Date())
        -> (reason: WebSearch.SearchFailureReason, remaining: TimeInterval)? {
        guard let cooldown = cooldowns[provider], cooldown.until > now else { return nil }
        return (cooldown.reason, cooldown.until.timeIntervalSince(now))
    }
}

/// Process-wide holder for the meta-search cooldown gate, shared across searches so a limit hit
/// on one run suppresses that provider on later runs until it cools down. An actor for safe
/// concurrent access from the parallel fan-out.
actor MetaRateLimiter {
    private var gate: RateLimitGate

    init(gate: RateLimitGate = RateLimitGate()) { self.gate = gate }

    /// Splits `providers` into those available now and those still cooling (reason + remaining).
    func availability(_ providers: [WebSearch.ProviderKind], now: Date = Date())
        -> (available: [WebSearch.ProviderKind],
            cooling: [WebSearch.ProviderKind: (reason: WebSearch.SearchFailureReason, remaining: TimeInterval)]) {
        var available: [WebSearch.ProviderKind] = []
        var cooling: [WebSearch.ProviderKind: (reason: WebSearch.SearchFailureReason, remaining: TimeInterval)] = [:]
        for provider in providers {
            if let status = gate.status(provider, now: now) { cooling[provider] = status }
            else { available.append(provider) }
        }
        return (available, cooling)
    }

    /// Applies each provider's outcome to the gate (success clears a cooldown, limits park it).
    func record(_ entries: [(provider: WebSearch.ProviderKind,
                             reason: WebSearch.SearchFailureReason?,
                             retryAfter: TimeInterval?)],
                now: Date = Date()) {
        for entry in entries {
            gate.record(entry.provider, reason: entry.reason, retryAfter: entry.retryAfter, now: now)
        }
    }

    /// Clears all cooldowns.
    func reset() { gate = RateLimitGate() }
}

extension WebSearch {
    /// Shared, session-scoped meta-search rate-limit gate (in-memory; resets on relaunch).
    static let metaRateLimiter = MetaRateLimiter()
}
