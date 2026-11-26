import Foundation

/// Retry starts another execution; approval and input resumes keep this identity.
public struct ProductTaskIdentity: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public init(id: UUID = UUID(), startedAt: Date = Date()) { self.id = id; self.startedAt = startedAt }
}

public enum ProductTaskGroup: String, CaseIterable, Sendable { case attention, active, finished }

public extension TaskRunStatus {
    var taskGroup: ProductTaskGroup {
        switch self {
        case .running: .active
        case .waitingForConfirmation, .waitingForInput, .incomplete, .failed, .recoveryRequired: .attention
        case .succeeded, .cancelled: .finished
        }
    }
    var isTerminal: Bool {
        switch self {
        case .running, .waitingForConfirmation, .waitingForInput: false
        default: true
        }
    }
}

public struct ProductTaskRun: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let messageID: UUID
    public var workspaceID: String?
    public var mode: ChatMode
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var status: TaskRunStatus
    public var prompt: String
    public var answer: String
    public var trace: [DispatcherTraceEntry]
    public var artifacts: [TaskArtifact]
    public var completion: TaskCompletionAssessment?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var contentTruncated: Bool
    public var toolCount: Int
    public let isLegacy: Bool
    public var resourceContext: RunResourceContext? = nil
}

public struct ProductTaskRunSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let messageID: UUID
    public let workspaceID: String?
    public let mode: ChatMode
    public let title: String
    public let preview: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: TaskRunStatus
    public let sessionHidden: Bool
}

public enum ProductTaskHistoryError: Error, Sendable { case invalidRecord, identityConflict }
