import Foundation

// MARK: - Team Run Registry

/// 进程内运行注册表：任务板通过它真正取消当前空间的运行任务，
/// 而不是只修改数据库状态。键包含空间，跨空间 ID 不会误取消。
public actor TeamRunRegistry {
    public static let shared = TeamRunRegistry()

    private struct Key: Hashable {
        let space: String
        let taskID: UUID
    }

    private var coordinators: [Key: TeamCoordinator] = [:]

    public init() {}

    public func register(_ coordinator: TeamCoordinator, taskID: UUID, space: AppSpace) {
        coordinators[Key(space: space.rawValue, taskID: taskID)] = coordinator
    }

    public func unregister(taskID: UUID, space: AppSpace) {
        coordinators.removeValue(forKey: Key(space: space.rawValue, taskID: taskID))
    }

    /// 请求取消；返回是否找到本空间的运行。
    @discardableResult
    public func cancel(taskID: UUID, space: AppSpace) async -> Bool {
        guard let coordinator = coordinators[Key(space: space.rawValue, taskID: taskID)] else {
            return false
        }
        await coordinator.cancel()
        await coordinator.waitForCompletion()
        return true
    }

    public func isRunning(taskID: UUID, space: AppSpace) -> Bool {
        coordinators[Key(space: space.rawValue, taskID: taskID)] != nil
    }

    public func activeTaskIDs(in space: AppSpace) -> Set<UUID> {
        Set(coordinators.keys.filter { $0.space == space.rawValue }.map(\.taskID))
    }
}
