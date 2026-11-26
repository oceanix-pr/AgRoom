import Foundation

/// Shared by one task and its children. Only short synchronous state is locked.
public final class TaskAuthorizationState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var revoked = false
    private var generation: UInt64 = 0

    public init(enabled: Bool) { self.enabled = enabled }

    public var snapshot: (enabled: Bool, revoked: Bool, generation: UInt64) {
        lock.withLock { (enabled, revoked, generation) }
    }

    public func setEnabled(_ value: Bool) {
        lock.withLock {
            guard enabled != value else { return }
            enabled = value
            generation &+= 1
        }
    }

    public func revoke() {
        lock.withLock { revoked = true; generation &+= 1 }
    }
}

// MARK: - Execution Context

/// 一次运行共享的身份、权限、预算、取消与审计边界。
/// 派生上下文只允许收窄权限和分配预算，不能凭空扩权。
public struct ExecutionContext: Sendable {
    public let space: AppSpace
    public let sessionID: UUID?
    public let runID: UUID
    public let parentRunID: UUID?
    public let rootRunID: UUID
    public let subtaskID: UUID?
    public let permissionPolicy: PermissionPolicy?
    /// 本次任务的目录、能力与用户限制；nil = 旧装配，不启用任务范围自动批准。
    public let taskScope: TaskExecutionScope?
    public let authorizationState: TaskAuthorizationState
    public let budgetLedger: ExecutionBudgetLedger?
    public let deadline: Date?

    public init(
        space: AppSpace,
        sessionID: UUID? = nil,
        runID: UUID = UUID(),
        parentRunID: UUID? = nil,
        rootRunID: UUID? = nil,
        subtaskID: UUID? = nil,
        permissionPolicy: PermissionPolicy?,
        taskScope: TaskExecutionScope? = nil,
        authorizationState: TaskAuthorizationState? = nil,
        budgetLedger: ExecutionBudgetLedger? = nil,
        deadline: Date? = nil
    ) {
        self.space = space
        self.sessionID = sessionID
        self.runID = runID
        self.parentRunID = parentRunID
        self.rootRunID = rootRunID ?? runID
        self.subtaskID = subtaskID
        self.permissionPolicy = permissionPolicy
        self.taskScope = taskScope
        self.authorizationState = authorizationState ?? TaskAuthorizationState(enabled: taskScope?.autoReviewEnabled ?? false)
        self.budgetLedger = budgetLedger
        self.deadline = [deadline, budgetLedger?.deadline].compactMap { $0 }.min()
    }

    /// 派生子任务上下文：新 runID，保留父运行关联；
    /// 权限只能取与原策略的交集（由调用方传入已收窄策略），预算共享同一账本。
    public func child(
        subtaskID: UUID,
        permissionPolicy: PermissionPolicy,
        budgetLedger: ExecutionBudgetLedger? = nil,
        deadline: Date? = nil
    ) -> ExecutionContext {
        let childRunID = UUID()
        return ExecutionContext(
            space: space,
            sessionID: sessionID,
            runID: childRunID,
            parentRunID: runID,
            rootRunID: rootRunID,
            subtaskID: subtaskID,
            permissionPolicy: permissionPolicy,
            taskScope: taskScope?.child(runID: childRunID, subtaskID: subtaskID),
            authorizationState: authorizationState,
            budgetLedger: budgetLedger ?? self.budgetLedger,
            deadline: [deadline, self.deadline].compactMap { $0 }.min()
        )
    }

    public func checkDeadline() throws {
        if let deadline, Date() >= deadline { throw BudgetError.deadlineExceeded }
    }
}
