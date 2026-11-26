import Foundation

// MARK: - Progress Entry

/// 某个子任务最近一次工具动作的快照。只存在内存，不落库；
/// 任务结束后由协调器清理。用于任务板显示“谁正在做什么”。
public struct TeamProgressEntry: Sendable, Equatable, Identifiable {
    public let taskID: UUID
    public let subtaskID: UUID
    public let subtaskTitle: String
    public let agentName: String
    public let toolName: String
    public let succeeded: Bool?
    public let duration: TimeInterval
    public let updatedAt: Date

    public var id: UUID { subtaskID }

    public init(
        taskID: UUID,
        subtaskID: UUID,
        subtaskTitle: String,
        agentName: String,
        toolName: String,
        succeeded: Bool?,
        duration: TimeInterval,
        updatedAt: Date = Date()
    ) {
        self.taskID = taskID
        self.subtaskID = subtaskID
        self.subtaskTitle = subtaskTitle
        self.agentName = agentName
        self.toolName = toolName
        self.succeeded = succeeded
        self.duration = max(0, duration)
        self.updatedAt = updatedAt
    }
}

// MARK: - Progress Center

/// 进程内进度中心：Worker 每次工具完成时更新，任务板轮询显示。
public actor TeamProgressCenter {
    public static let shared = TeamProgressCenter()

    private var entries: [UUID: [UUID: TeamProgressEntry]] = [:]

    public init() {}

    public func update(
        taskID: UUID,
        subtaskID: UUID,
        subtaskTitle: String,
        agentName: String,
        toolName: String,
        succeeded: Bool?,
        duration: TimeInterval
    ) {
        entries[taskID, default: [:]][subtaskID] = TeamProgressEntry(
            taskID: taskID,
            subtaskID: subtaskID,
            subtaskTitle: subtaskTitle,
            agentName: agentName,
            toolName: toolName,
            succeeded: succeeded,
            duration: duration
        )
    }

    public func progress(taskID: UUID) -> [TeamProgressEntry] {
        (entries[taskID] ?? [:]).values.sorted { $0.updatedAt < $1.updatedAt }
    }

    public func clear(taskID: UUID) {
        entries.removeValue(forKey: taskID)
    }
}
