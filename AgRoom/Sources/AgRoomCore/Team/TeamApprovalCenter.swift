import Foundation
import CryptoKit

// MARK: - Approval Models

/// 一个等待用户批准的文件写入请求。内容只存在内存中，不落盘；
/// 任务被取消、审批超时或 App 退出时请求消失，Worker 不会自行放行。
public struct TeamApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let space: String
    public let taskID: UUID
    public let taskGoal: String
    public let subtaskID: UUID
    public let subtaskTitle: String
    public let path: String
    public let oldContent: String?
    public let newContent: String
    public let requestedAt: Date
    public let expiresAt: Date
    public let oldDigest: String?
    public let newDigest: String
    public let policyVersion: Int

    public init(
        id: UUID = UUID(),
        space: String,
        taskID: UUID,
        taskGoal: String,
        subtaskID: UUID,
        subtaskTitle: String,
        path: String,
        oldContent: String?,
        newContent: String,
        requestedAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(600),
        oldDigest: String? = nil,
        newDigest: String? = nil,
        policyVersion: Int = 0
    ) {
        self.id = id
        self.space = space
        self.taskID = taskID
        self.taskGoal = taskGoal
        self.subtaskID = subtaskID
        self.subtaskTitle = subtaskTitle
        self.path = path
        self.oldContent = oldContent
        self.newContent = newContent
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.oldDigest = oldDigest ?? oldContent.map(TeamApprovalRequest.digest)
        self.newDigest = newDigest ?? TeamApprovalRequest.digest(newContent)
        self.policyVersion = policyVersion
    }

    public static func digest(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum TeamApprovalDecision: Sendable, Equatable {
    case approved
    case denied
    case expired
    case cancelled
}

enum TeamApprovalError: LocalizedError {
    case denied
    case expired
    case cancelled

    var errorDescription: String? {
        switch self {
        case .denied: return "The user denied this team file write."
        case .expired: return "The team file write approval expired before the user decided."
        case .cancelled: return "The team file write approval was cancelled."
        }
    }
}

// MARK: - Waiter

/// 单次恢复保护：超时、取消和用户决定可能竞争，只允许 resume 一次。
private final class TeamApprovalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TeamApprovalDecision, Never>?
    private var result: TeamApprovalDecision?

    func install(_ continuation: CheckedContinuation<TeamApprovalDecision, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ decision: TeamApprovalDecision) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: decision)
        } else {
            if result == nil { result = decision }
            lock.unlock()
        }
    }
}

// MARK: - Approval Center

/// 进程内中央审批中心：Worker 写入前在这里挂起，任务板审批收件箱列出并决定。
/// 按空间过滤；不持久化，不跨进程（daemon 不启用团队写）。
public actor TeamApprovalCenter {
    public static let shared = TeamApprovalCenter()

    private struct Pending {
        let request: TeamApprovalRequest
        let waiter: TeamApprovalWaiter
        let timeoutTask: Task<Void, Never>
    }

    private var pending: [UUID: Pending] = [:]

    public init() {}

    /// 挂起等待用户决定。超时/取消/拒绝都会返回明确结果。
    public func request(
        _ request: TeamApprovalRequest,
        timeout: TimeInterval = 600
    ) async -> TeamApprovalDecision {
        let id = request.id
        let waiter = TeamApprovalWaiter()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, timeout)))
            await self?.expire(id)
        }
        pending[id] = Pending(request: request, waiter: waiter, timeoutTask: timeoutTask)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                if Task.isCancelled {
                    Task { self.cancel(id) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    public func pendingRequests(space: String) -> [TeamApprovalRequest] {
        pending.values
            .map(\.request)
            .filter { $0.space == space }
            .sorted { $0.requestedAt < $1.requestedAt }
    }

    /// 用户决定。space 必须匹配，避免跨空间按 id 放行。
    @discardableResult
    public func resolve(id: UUID, space: String, approved: Bool) -> Bool {
        guard let entry = pending[id], entry.request.space == space else {
            return false
        }
        pending.removeValue(forKey: id)
        entry.timeoutTask.cancel()
        entry.waiter.finish(approved ? .approved : .denied)
        return true
    }

    /// 取消某任务的全部待审批请求（任务删除/放弃时调用）。
    public func cancel(taskID: UUID) {
        let ids = pending.values
            .filter { $0.request.taskID == taskID }
            .map { $0.request.id }
        for id in ids {
            cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask.cancel()
        entry.waiter.finish(.cancelled)
    }

    private func expire(_ id: UUID) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask.cancel()
        entry.waiter.finish(.expired)
    }
}
