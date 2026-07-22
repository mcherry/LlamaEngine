import Foundation

/// The per-session tool configuration the host passes into a turn (like `WebSearchConfig`).
/// The engine stays UserDefaults-free; the app owns persistence and the confirmation UI.
/// Off by default — a session sees no tool unless the user opts in and allow-lists it.
public struct SessionToolSettings: Sendable, Equatable {
    /// Master switch. When false, no tool is advertised and none can run.
    public var enabled: Bool
    /// Tools the user has individually allow-listed by name. A tool not in this set is
    /// denied even when `enabled`.
    public var allowedTools: Set<String>
    /// Tools the user chose "Approve for this chat" in a prior confirmation, so a
    /// higher-risk tool does not re-prompt on every call. The host persists this.
    public var approvedForSession: Set<String>
    /// Whether `readLocal`-tier tools require confirmation (default true). `network` and
    /// `mutating` always confirm regardless; `pure` never does.
    public var confirmReadLocal: Bool

    public init(enabled: Bool = false,
                allowedTools: Set<String> = [],
                approvedForSession: Set<String> = [],
                confirmReadLocal: Bool = true) {
        self.enabled = enabled
        self.allowedTools = allowedTools
        self.approvedForSession = approvedForSession
        self.confirmReadLocal = confirmReadLocal
    }
}

/// What the policy decided for a proposed call, before it runs.
public enum ToolDecision: Sendable, Equatable {
    case allow                        // pure tier, or already approved for the session
    case needsConfirmation            // above pure — a human must approve first
    case deny(reason: String)         // tools off, or this tool not allow-listed
}

/// Maps a tool's risk tier plus the session's settings to a decision. Pure/testable. The
/// tier — not the tool's own opinion — drives the default: `mutating` and `network` never
/// auto-run, `readLocal` is confirm-by-default (configurable), `pure` auto-runs.
public struct ToolPolicy: Sendable {
    public init() {}

    public func decide(tool: any AgentTool, settings: SessionToolSettings) -> ToolDecision {
        guard settings.enabled else { return .deny(reason: "Tools are off for this chat.") }
        guard settings.allowedTools.contains(tool.name) else {
            return .deny(reason: "\(tool.name) is not enabled for this chat.")
        }
        if settings.approvedForSession.contains(tool.name) { return .allow }
        switch tool.riskTier {
        case .pure:      return .allow
        case .readLocal: return settings.confirmReadLocal ? .needsConfirmation : .allow
        case .network:   return .needsConfirmation
        case .mutating:  return .needsConfirmation
        }
    }
}

/// The request handed to the host's confirmation UI when a call needs approval. Carries
/// the exact tool and its *literal* arguments so the sheet can surface what the model is
/// asking to do — this is what neutralises indirect injection (the ask becomes visible).
public struct ToolConfirmationRequest: Sendable, Identifiable {
    public let id = UUID()
    public let toolName: String
    public let toolDescription: String
    public let riskTier: ToolRiskTier
    public let arguments: JSONValue
    /// A pretty-printed rendering of `arguments` for display.
    public let argumentsJSON: String

    public init(toolName: String, toolDescription: String, riskTier: ToolRiskTier, arguments: JSONValue) {
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.riskTier = riskTier
        self.arguments = arguments
        self.argumentsJSON = Self.pretty(arguments)
    }

    private static func pretty(_ value: JSONValue) -> String {
        guard let data = value.jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object,
                                                          options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: formatted, encoding: .utf8) else {
            return value.jsonString
        }
        return text
    }
}

/// The host's answer to a confirmation request.
public enum ToolConfirmationOutcome: Sendable, Equatable {
    case denied
    case approvedOnce
    /// Approve now and remember for the rest of the session (the host persists it, so the
    /// next turn passes the tool in `approvedForSession`). Never offered for `mutating`.
    case approvedForSession
}

/// The async hook the host provides to drive the confirmation sheet. Runs on the host's
/// actor (typically `@MainActor`). A `nil` handler (or `.denied`) blocks the call.
public typealias ToolConfirmationHandler = @Sendable (ToolConfirmationRequest) async -> ToolConfirmationOutcome

/// Everything the host supplies to run tools for a turn: the tools + loop caps
/// (`registry`), the per-session policy inputs (`settings`), the decision function
/// (`policy`), and the confirmation hook. Bundled so `send()` keeps a small signature.
public struct ToolContext: Sendable {
    public var registry: ToolRegistry
    public var settings: SessionToolSettings
    public var policy: ToolPolicy
    public var confirm: ToolConfirmationHandler?

    public init(registry: ToolRegistry,
                settings: SessionToolSettings,
                policy: ToolPolicy = ToolPolicy(),
                confirm: ToolConfirmationHandler? = nil) {
        self.registry = registry
        self.settings = settings
        self.policy = policy
        self.confirm = confirm
    }

    /// Only the enabled, allow-listed tools' specs are advertised to the model — a
    /// disabled or un-allow-listed tool never appears in the request payload.
    public var activeSpecs: [ToolSpec] {
        guard settings.enabled else { return [] }
        return registry.tools.filter { settings.allowedTools.contains($0.name) }.map(\.spec)
    }

    /// True when the loop should engage: tools enabled and at least one allow-listed tool
    /// is present in the registry.
    public var isActive: Bool {
        settings.enabled && registry.tools.contains { settings.allowedTools.contains($0.name) }
    }
}
