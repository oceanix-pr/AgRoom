import Foundation

// MARK: - Lease

/// 单文件写租约：同一路径同一时刻只允许一个团队 Worker 写入。
/// 只在内存中；TTL 到期自动失效，进程退出即释放。
public struct TeamLease: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let space: String
    public let path: String
    public let ownerTaskID: UUID
    public let ownerSubtaskID: UUID
    public let expiresAt: Date
}

public enum TeamLeaseError: LocalizedError, Equatable {
    case conflict(path: String)
    case invalidPath

    public var errorDescription: String? {
        switch self {
        case .conflict(let path):
            return "Another team worker is writing \(path). Wait for it to finish and retry."
        case .invalidPath:
            return "Team write path is empty or invalid."
        }
    }
}

// MARK: - Lease Center

/// 进程内写租约中心：路径级独占，跨任务生效。
public actor TeamLeaseCenter {
    public static let shared = TeamLeaseCenter()

    private var leases: [String: TeamLease] = [:]

    public init() {}

    public func acquire(
        space: String,
        path: String,
        taskID: UUID,
        subtaskID: UUID,
        ttl: TimeInterval = 120
    ) throws -> TeamLease {
        let key = Self.key(space: space, path: path)
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw TeamLeaseError.invalidPath
        }
        purgeExpired()
        if let existing = leases[key],
           existing.ownerTaskID != taskID || existing.ownerSubtaskID != subtaskID {
            throw TeamLeaseError.conflict(path: path)
        }
        let lease = TeamLease(
            id: UUID(),
            space: space,
            path: path,
            ownerTaskID: taskID,
            ownerSubtaskID: subtaskID,
            expiresAt: Date().addingTimeInterval(min(max(ttl, 5), 600))
        )
        leases[key] = lease
        return lease
    }

    public func release(_ lease: TeamLease) {
        let key = Self.key(space: lease.space, path: lease.path)
        guard leases[key]?.id == lease.id else { return }
        leases.removeValue(forKey: key)
    }

    public func activeLease(space: String, path: String) -> TeamLease? {
        purgeExpired()
        return leases[Self.key(space: space, path: path)]
    }

    private func purgeExpired() {
        let now = Date()
        leases = leases.filter { $0.value.expiresAt > now }
    }

    private static func key(space: String, path: String) -> String {
        "\(space)\u{1F}\(path)"
    }
}
