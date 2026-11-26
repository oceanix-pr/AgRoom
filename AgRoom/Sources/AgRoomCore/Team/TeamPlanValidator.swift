import Foundation

// MARK: - Plan Validation Error

public enum TeamPlanError: LocalizedError, Equatable, Sendable {
    case emptyGoal
    case noSubtasks
    case tooManySubtasks(limit: Int)
    case emptyTitle(UUID)
    case emptyObjective(UUID)
    case duplicateID(UUID)
    case unknownDependency(subtask: UUID, dependency: UUID)
    case unknownDependencyKey(String)
    case cycle
    case writeScopeNotSupported(UUID)
    case invalidWriteScope(UUID)
    case invalidMaxSteps(UUID)
    case invalidEstimate(UUID)
    case invalidConcurrency
    case budgetTooSmall(estimated: Int, budget: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyGoal:
            return "Team task requires a non-empty goal."
        case .noSubtasks:
            return "Team task requires at least one subtask."
        case .tooManySubtasks(let limit):
            return "Team task has too many subtasks; the limit is \(limit)."
        case .emptyTitle(let id):
            return "Subtask \(id.uuidString) requires a non-empty title."
        case .emptyObjective(let id):
            return "Subtask \(id.uuidString) requires a non-empty objective."
        case .duplicateID(let id):
            return "Subtask id \(id.uuidString) is duplicated."
        case .unknownDependency(let subtask, let dependency):
            return "Subtask \(subtask.uuidString) depends on unknown subtask \(dependency.uuidString)."
        case .unknownDependencyKey(let key):
            return "Subtask dependency key '\(key)' does not match any subtask key."
        case .cycle:
            return "Team plan contains a dependency cycle."
        case .writeScopeNotSupported(let id):
            return "Subtask \(id.uuidString) declares a write scope but team writes are unavailable."
        case .invalidWriteScope(let id):
            return "Subtask \(id.uuidString) has an empty or invalid write scope."
        case .invalidMaxSteps(let id):
            return "Subtask \(id.uuidString) has an invalid max_steps; expected 1...40."
        case .invalidEstimate(let id):
            return "Subtask \(id.uuidString) has a negative estimated_tokens."
        case .invalidConcurrency:
            return "Team plan max_concurrency must be between 1 and 4."
        case .budgetTooSmall(let estimated, let budget):
            return "Estimated team usage (\(estimated) tokens) exceeds the task budget (\(budget) tokens)."
        }
    }
}

// MARK: - Plan Validator

/// 计划是模型输出，和工具参数一样不可信：落库/执行前先做确定性校验。
public enum TeamPlanValidator {
    public static let maximumSubtasks = 8
    public static let maximumConcurrency = 4

    public static func validate(
        _ plan: TeamPlan,
        budget: TeamBudget,
        maxSubtasks: Int = maximumSubtasks
    ) throws {
        guard !plan.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TeamPlanError.emptyGoal
        }
        guard !plan.subtasks.isEmpty else {
            throw TeamPlanError.noSubtasks
        }
        guard plan.subtasks.count <= maxSubtasks else {
            throw TeamPlanError.tooManySubtasks(limit: maxSubtasks)
        }
        guard (1...maximumConcurrency).contains(plan.maxConcurrency) else {
            throw TeamPlanError.invalidConcurrency
        }

        var seenIDs = Set<UUID>()
        for id in plan.subtasks.map(\.id) {
            guard seenIDs.insert(id).inserted else {
                throw TeamPlanError.duplicateID(id)
            }
        }

        var byID: [UUID: TeamSubtask] = [:]
        for subtask in plan.subtasks {
            byID[subtask.id] = subtask
        }

        for subtask in plan.subtasks {
            guard !subtask.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TeamPlanError.emptyTitle(subtask.id)
            }
            guard !subtask.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TeamPlanError.emptyObjective(subtask.id)
            }
            guard (1...40).contains(subtask.maxSteps) else {
                throw TeamPlanError.invalidMaxSteps(subtask.id)
            }
            for scope in subtask.writeScopes {
                let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.contains("\0") {
                    throw TeamPlanError.invalidWriteScope(subtask.id)
                }
            }
            for dependency in Set(subtask.dependsOn) where byID[dependency] == nil {
                throw TeamPlanError.unknownDependency(subtask: subtask.id, dependency: dependency)
            }
            guard subtask.estimatedTokens >= 0 else {
                throw TeamPlanError.invalidEstimate(subtask.id)
            }
        }

        // Kahn 拓扑排序：只校验无环，执行顺序由协调器按 ready set 动态决定。
        var indegree: [UUID: Int] = Dictionary(uniqueKeysWithValues: plan.subtasks.map { ($0.id, 0) })
        var outgoing: [UUID: [UUID]] = Dictionary(uniqueKeysWithValues: plan.subtasks.map { ($0.id, []) })
        for subtask in plan.subtasks {
            for dependency in Set(subtask.dependsOn) {
                indegree[subtask.id, default: 0] += 1
                outgoing[dependency, default: []].append(subtask.id)
            }
        }
        var queue = plan.subtasks.map(\.id).filter { indegree[$0] == 0 }
        var visited = 0
        while let current = queue.popLast() {
            visited += 1
            for next in outgoing[current] ?? [] {
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 {
                    queue.append(next)
                }
            }
        }
        guard visited == plan.subtasks.count else {
            throw TeamPlanError.cycle
        }

        if let limit = budget.maxTokens {
            let estimated = plan.estimatedTokens
            guard let estimated, estimated <= limit else {
                throw TeamPlanError.budgetTooSmall(estimated: estimated ?? .max, budget: limit)
            }
        }
    }
}
