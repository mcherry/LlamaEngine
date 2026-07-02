import Foundation

/// A small, dependency-free `robots.txt` parser and matcher — enough to be a polite
/// citizen for single-page web fetches. It selects the rule group for our user-agent
/// (an exact-ish token match preferred over the `*` group), then applies Allow/Disallow
/// with `*`/`$` wildcards and longest-match precedence (Allow winning ties), per the
/// Robots Exclusion Protocol. Pure, so the matching is unit-testable.
public enum RobotsTxt {

    public struct Directive: Equatable {
        public var allow: Bool
        public var pattern: String
        public init(allow: Bool, pattern: String) {
            self.allow = allow
            self.pattern = pattern
        }
    }

    /// The directives that apply to a chosen user-agent. Empty = no restrictions.
    public struct Rules: Equatable {
        public var directives: [Directive]
        public init(directives: [Directive]) {
            self.directives = directives
        }
    }

    /// Whether `path` may be fetched for `userAgent` given `robots` content.
    public static func isAllowed(_ path: String, userAgent: String, robots: String) -> Bool {
        isAllowed(path, in: rules(for: userAgent, in: robots))
    }

    /// Applies a selected rule group to `path`: the longest matching pattern wins, Allow
    /// beats Disallow on ties, and no match means allowed.
    public static func isAllowed(_ path: String, in rules: Rules) -> Bool {
        let target = path.isEmpty ? "/" : path
        var best: (allow: Bool, length: Int)?
        for directive in rules.directives {
            guard let length = matchLength(pattern: directive.pattern, path: target) else { continue }
            if best == nil || length > best!.length || (length == best!.length && directive.allow) {
                best = (directive.allow, length)
            }
        }
        return best?.allow ?? true
    }

    /// The Allow/Disallow directives for the group that best matches `userAgent`: the
    /// longest agent token contained in the UA wins; otherwise the `*` group; otherwise no
    /// restrictions.
    public static func rules(for userAgent: String, in robots: String) -> Rules {
        let groups = parse(robots)
        let ua = userAgent.lowercased()
        var specific: (length: Int, directives: [Directive])?
        var wildcard: [Directive]?
        for group in groups {
            for agent in group.agents {
                let token = agent.lowercased()
                if token == "*" {
                    wildcard = group.directives
                } else if !token.isEmpty, ua.contains(token) {
                    if specific == nil || token.count > specific!.length {
                        specific = (token.count, group.directives)
                    }
                }
            }
        }
        return Rules(directives: specific?.directives ?? wildcard ?? [])
    }

    // MARK: - Parsing

    private struct Group {
        var agents: [String]
        var directives: [Directive]
    }

    private static func parse(_ robots: String) -> [Group] {
        var groups: [Group] = []
        var current = Group(agents: [], directives: [])
        var sawDirective = false

        func flush() {
            if !current.agents.isEmpty || !current.directives.isEmpty {
                groups.append(current)
            }
        }

        for rawLine in robots.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "user-agent":
                // A user-agent line that follows directives starts a new group.
                if sawDirective {
                    flush()
                    current = Group(agents: [], directives: [])
                    sawDirective = false
                }
                current.agents.append(value)
            case "allow":
                if !value.isEmpty { current.directives.append(Directive(allow: true, pattern: value)) }
                sawDirective = true
            case "disallow":
                // An empty Disallow imposes no restriction (allow all) — skip it.
                if !value.isEmpty { current.directives.append(Directive(allow: false, pattern: value)) }
                sawDirective = true
            default:
                break   // sitemap, crawl-delay, etc. are ignored
            }
        }
        flush()
        return groups
    }

    // MARK: - Path matching

    /// If `pattern` matches the start of `path` (`*` = any run, trailing `$` = end anchor),
    /// returns the pattern's literal length (for longest-match precedence); else nil.
    static func matchLength(pattern: String, path: String) -> Int? {
        guard !pattern.isEmpty else { return nil }
        guard matchesPrefix(pattern: pattern, path: path) else { return nil }
        return pattern.reduce(0) { $0 + ($1 == "*" || $1 == "$" ? 0 : 1) }
    }

    private static func matchesPrefix(pattern: String, path: String) -> Bool {
        let endAnchored = pattern.hasSuffix("$")
        let body = endAnchored ? String(pattern.dropLast()) : pattern
        let parts = body.components(separatedBy: "*")

        var index = path.startIndex
        for (i, part) in parts.enumerated() where !part.isEmpty {
            if i == 0 {
                guard path[index...].hasPrefix(part) else { return false }
                index = path.index(index, offsetBy: part.count)
            } else {
                guard let range = path.range(of: part, range: index..<path.endIndex) else { return false }
                index = range.upperBound
            }
        }
        if endAnchored {
            // With a trailing "*$" the end is unconstrained; otherwise the path must end here.
            if parts.last?.isEmpty == true { return true }
            return index == path.endIndex
        }
        return true
    }
}
