import Foundation

/// The role of a chat turn. Stored on a message as a raw string for SwiftData
/// simplicity and mapped to this enum in code.
public enum Role: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
    case tool
}
