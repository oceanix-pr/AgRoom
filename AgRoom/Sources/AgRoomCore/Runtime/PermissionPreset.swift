import Foundation

/// A preset composes the capability ceiling and approval behavior. Enforcement
/// continues to use PermissionPolicy and the unified approval pipeline.
public struct PermissionConfiguration: Sendable, Equatable {
    public let mode: PermissionMode
    public let autoReviewEnabled: Bool

    public init(mode: PermissionMode, autoReviewEnabled: Bool) {
        self.mode = mode
        self.autoReviewEnabled = autoReviewEnabled
    }

    public var preset: PermissionPreset {
        PermissionPreset.sessionOptions.first { $0.configuration == self } ?? .custom
    }
}

/// Follows DeepSeek Harness's preset/catalog model. Auto is session-only;
/// unmatched legacy combinations remain display-only custom configurations.
/// AgRoom's Auto retains workspace confinement and mandatory confirmations.
public enum PermissionPreset: String, Sendable, Hashable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case extendedAccess = "danger-full-access"
    case autoReview = "auto"
    case custom

    public static let defaultOptions: [Self] = [.readOnly, .workspaceWrite, .extendedAccess]
    public static let sessionOptions: [Self] = defaultOptions + [.autoReview]

    /// Custom is a derived display state, never a selectable or writable preset.
    public var configuration: PermissionConfiguration? {
        switch self {
        case .readOnly: .init(mode: .readOnly, autoReviewEnabled: false)
        case .workspaceWrite: .init(mode: .workspaceWrite, autoReviewEnabled: false)
        case .extendedAccess: .init(mode: .dangerFullAccess, autoReviewEnabled: false)
        case .autoReview: .init(mode: .workspaceWrite, autoReviewEnabled: true)
        case .custom: nil
        }
    }

    public var requiresAcknowledgement: Bool {
        self == .extendedAccess || self == .autoReview
    }
}
