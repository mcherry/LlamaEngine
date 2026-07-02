import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Errors from the Apple Intelligence backend.
public enum AppleIntelligenceError: LocalizedError {
    case unsupportedOS
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Apple Intelligence requires macOS 26 or later."
        case .unavailable(let message):
            return message
        }
    }
}

/// Runtime capability check for Apple's on-device Foundation Models. Compiles on the
/// macOS 15 deployment target by guarding every framework use behind
/// `#if canImport(FoundationModels)` and `if #available(macOS 26, *)`, so the option
/// only lights up when Apple Intelligence is genuinely available on the system.
public enum AppleIntelligence {
    public enum Status: Equatable {
        case available
        case unavailable(String)
        case unsupportedOS
    }

    public static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(describe(reason))
            @unknown default:
                return .unavailable("Apple Intelligence is unavailable.")
            }
        } else {
            return .unsupportedOS
        }
        #else
        return .unsupportedOS
        #endif
    }

    /// True only when the on-device model is ready to use right now.
    public static var isAvailable: Bool {
        status == .available
    }

    /// A human-readable explanation for the current status, for UI and errors.
    public static var statusMessage: String {
        switch status {
        case .available:
            return "Apple Intelligence is available on this Mac."
        case .unavailable(let message):
            return message
        case .unsupportedOS:
            return "Requires macOS 26 or later."
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use it here."
        case .modelNotReady:
            return "The on-device model is still downloading or preparing."
        @unknown default:
            return "Apple Intelligence is unavailable."
        }
    }
    #endif
}
