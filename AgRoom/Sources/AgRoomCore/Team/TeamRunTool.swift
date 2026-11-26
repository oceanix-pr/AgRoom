import Foundation

// MARK: - Team Run Tool

/// 主调度 Agent 的团队入口：接受一个小子任务 DAG，内部用 `TeamCoordinator` 并行执行，
/// 最后把结构化结果摘要回填宿主模型。
///
/// P0 明确只读：Worker 不能写文件、跑 Shell、发邮件、改提醒或向用户提问。
/// 需要这些动作的任务仍由主对话里的原工具完成。
public struct TeamRunTool: DispatcherTool {
    public let factory: any TeamWorkerFactory
    public let store: TeamTaskStore?
    public let verifier: (any TeamVerifier)?
    public let budget: TeamBudget
    public let maxSubtasks: Int
    public let allowsWrites: Bool
    public let space: AppSpace
    /// 显式重试时指向原任务；首次运行 nil。
    public let parentTaskID: UUID?
    let parentBudget = AgentBudgetRelay()
    let executionContext = AgentExecutionContextRelay()

    public init(
        factory: any TeamWorkerFactory,
        store: TeamTaskStore? = nil,
        verifier: (any TeamVerifier)? = nil,
        budget: TeamBudget = .default,
        maxSubtasks: Int = TeamPlanValidator.maximumSubtasks,
        allowsWrites: Bool = false,
        space: AppSpace = .work,
        parentTaskID: UUID? = nil
    ) {
        self.factory = factory
        self.store = store
        self.verifier = verifier
        self.budget = budget
        self.maxSubtasks = maxSubtasks
        self.allowsWrites = allowsWrites
        self.space = space
        self.parentTaskID = parentTaskID
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "team_run",
            description: "Run a small team of read-only sub-agents in parallel on independent subtasks. "
                + "Use when a task has 2-6 independent research or analysis strands that can be explored concurrently. "
                + "Each subtask objective must be self-contained: workers cannot see the main conversation. "
                + "Workers are read-only by default. If team file writes are enabled, they may call team_write only inside the conversation workspace; every write waits for your explicit approval in the Team Tasks inbox. "
                + "Workers never run shell commands, send email, change reminders, or ask the user. "
                + "Declare dependencies with `depends_on` keys; a dependent subtask starts only after its upstream artifacts are committed. "
                + "An independent verifier checks the final result against the goal and acceptance criteria; failed verification fails the task. "
                + "Returns a digest of structured findings and artifacts. Do not use for simple questions or strictly sequential work.",
            parametersSchemaJSON: #"""
            {"type":"object","properties":{"goal":{"type":"string","description":"The overall goal the team must complete"},"acceptance":{"type":"array","items":{"type":"string"},"description":"Optional task-level acceptance criteria"},"max_concurrency":{"type":"integer","description":"Maximum concurrent workers, 1-4. Default 3."},"subtasks":{"type":"array","minItems":1,"maxItems":6,"description":"Independent subtasks; dependencies use their key values","items":{"type":"object","properties":{"key":{"type":"string","description":"Stable short id used by depends_on, e.g. sources, facts, draft"},"title":{"type":"string","description":"Short subtask title"},"objective":{"type":"string","description":"Self-contained instruction: what to investigate or produce"},"role":{"type":"string","description":"researcher / analyst / reviewer / synthesizer, or an agent name"},"agent":{"type":"string","description":"Optional exact sub-agent name or nickname; omit to resolve by role"},"depends_on":{"type":"array","items":{"type":"string"},"description":"Keys of upstream subtasks whose artifacts this subtask needs"},"acceptance":{"type":"array","items":{"type":"string"},"description":"Optional subtask-level acceptance criteria"},"output_kind":{"type":"string","description":"Expected artifact kind, e.g. report / findings / comparison"},"max_steps":{"type":"integer","description":"Tool-step budget for this worker, 2-40"},"estimated_tokens":{"type":"integer","description":"Estimated total token usage for planning"},"write_scopes":{"type":"array","items":{"type":"string"},"description":"Optional subdirectories of the conversation workspace this worker may write through team_write. Omit to use the whole workspace; the host resolves and confines every path."}},"required":["title","objective"]}}},"required":["goal","subtasks"]}
            """#
        )
    }

    public let requiresConfirmation = false
    /// 团队写开启后，整个 `team_run` 按非幂等写对待：恢复/重试不得盲目重放。
    /// 入口本身的权限仍按只读编排能力处理；真正的写由 Worker 的审批+租约约束。
    public var sideEffectClass: ToolSideEffectClass {
        allowsWrites ? .nonIdempotentWrite : .readOnly
    }
    public var permissionClass: PermissionClass { .readOnly }

    public func execute(argumentsJSON: String) async throws -> String {
        let plan = try TeamPlanPayload.decode(argumentsJSON)
        let report = try await run(plan: plan, parentTaskID: parentTaskID)
        try Task.checkCancellation()
        return report.digest()
    }

    func retry(plan: TeamPlan, parentTaskID: UUID, revisionTitle: String?) async throws -> TeamTaskReport {
        guard !allowsWrites, let store else { throw TeamError.retryUnavailable }
        let next = try await store.planForRetry(id: parentTaskID, expectedPlan: plan, revisionTitle: revisionTitle)
        return try await run(plan: next, parentTaskID: parentTaskID)
    }

    /// 直接以已校验的计划运行（任务板显式重试复用同一装配）。
    /// 每次调用生成新的 taskID/runID，并通过 parentTaskID 关联原任务。
    public func run(plan: TeamPlan, parentTaskID: UUID?) async throws -> TeamTaskReport {
        if let context = executionContext.value, context.space != space {
            throw WorkspaceProjectError.wrongWorkspace
        }
        if plan.revision != nil, allowsWrites || verifier == nil {
            throw TeamError.retryUnavailable
        }
        let taskID = UUID()
        let runID = UUID()
        let store = self.store
        let versions = TeamReportVersionBox()
        let onReport: TeamReportObserver?
        if let store {
            onReport = { report in
                // 任务板是旁路：持久化失败不能阻断已完成的任务结果。
                // 首次允许创建；后续迟到回调不允许复活已删除任务，并受 runVersion 保护。
                let version = versions.next()
                try? await store.save(
                    plan: plan,
                    report: report,
                    runID: runID,
                    runVersion: version,
                    parentTaskID: parentTaskID,
                    createIfMissing: version == 1
                )
            }
        } else {
            onReport = nil
        }
        let coordinator = TeamCoordinator(
            taskID: taskID,
            space: space,
            plan: plan,
            budget: budget,
            factory: factory,
            verifier: verifier,
            maxSubtasks: maxSubtasks,
            onReport: onReport,
            parentBudget: parentBudget.value,
            deadline: executionContext.value?.deadline
        )
        await TeamRunRegistry.shared.register(coordinator, taskID: taskID, space: space)
        defer {
            Task { await TeamRunRegistry.shared.unregister(taskID: taskID, space: space) }
        }
        let identity = ProviderRequestMetadata(runID: taskID, parentRunID: executionContext.value?.runID,
            purpose: .worker, space: space, rootRunID: executionContext.value?.rootRunID ?? taskID)
        let report = try await ProviderRequestContext.$current.withValue(identity) {
            try await coordinator.run()
        }
        // 用户停止时把取消继续上抛，避免把已取消任务当作正常团队结果回填。
        try Task.checkCancellation()
        return report
    }
}

/// 串行递增的报告版本：每次观察者回调只允许写入比已提交版本更新的快照。
private final class TeamReportVersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

// MARK: - Model-facing Payload

/// `team_run` 的模型输入 DTO。模型只认识 key，不认识 UUID；
/// 这里把 key 解析成内部依赖 id，再做计划校验。
struct TeamPlanPayload: Decodable {
    struct Subtask: Decodable {
        let key: String?
        let title: String
        let objective: String
        let role: String?
        let agent: String?
        let dependsOn: [String]?
        let acceptance: [String]?
        let outputKind: String?
        let maxSteps: Int?
        let estimatedTokens: Int?
        let writeScopes: [String]?

        enum CodingKeys: String, CodingKey {
            case key, title, objective, role, agent
            case dependsOn = "depends_on"
            case acceptance
            case outputKind = "output_kind"
            case maxSteps = "max_steps"
            case estimatedTokens = "estimated_tokens"
            case writeScopes = "write_scopes"
        }
    }

    let goal: String
    let acceptance: [String]?
    let maxConcurrency: Int?
    let subtasks: [Subtask]

    enum CodingKeys: String, CodingKey {
        case goal, acceptance, subtasks
        case maxConcurrency = "max_concurrency"
    }

    static func decode(_ json: String) throws -> TeamPlan {
        guard let data = json.data(using: .utf8) else {
            throw TeamError.invalidArguments("arguments are not valid UTF-8")
        }
        let payload: TeamPlanPayload
        do {
            payload = try JSONDecoder().decode(TeamPlanPayload.self, from: data)
        } catch {
            throw TeamError.invalidArguments(error.localizedDescription)
        }
        guard !payload.subtasks.isEmpty else {
            throw TeamPlanError.noSubtasks
        }

        var usedKeys = Set<String>()
        var keyToID: [String: UUID] = [:]
        var subtasksWithKeys: [(Subtask, UUID, String)] = []
        for (index, raw) in payload.subtasks.enumerated() {
            let trimmedKey = (raw.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmedKey.isEmpty ? "subtask_\(index + 1)" : trimmedKey
            guard usedKeys.insert(key).inserted else {
                throw TeamError.invalidArguments("duplicate subtask key '\(key)'")
            }
            let id = UUID()
            keyToID[key] = id
            subtasksWithKeys.append((raw, id, key))
        }

        var subtasks: [TeamSubtask] = []
        for (raw, id, _) in subtasksWithKeys {
            let dependencyKeys = (raw.dependsOn ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let dependencies = try dependencyKeys.map { dependencyKey -> UUID in
                guard let dependency = keyToID[dependencyKey] else {
                    throw TeamPlanError.unknownDependencyKey(dependencyKey)
                }
                return dependency
            }
            let roleName = (raw.role ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let role = TeamRole(roleName.isEmpty ? "researcher" : roleName)
            let assignee = raw.agent?.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputKind = (raw.outputKind ?? "report").trimmingCharacters(in: .whitespacesAndNewlines)
            subtasks.append(TeamSubtask(
                id: id,
                title: raw.title.trimmingCharacters(in: .whitespacesAndNewlines),
                objective: raw.objective.trimmingCharacters(in: .whitespacesAndNewlines),
                role: role,
                assignee: (assignee?.isEmpty ?? true) ? nil : assignee,
                dependsOn: dependencies,
                outputKind: outputKind.isEmpty ? "report" : outputKind,
                acceptance: raw.acceptance ?? [],
                maxSteps: min(max(raw.maxSteps ?? 8, 1), 40),
                estimatedTokens: max(0, raw.estimatedTokens ?? 12_000),
                writeScopes: raw.writeScopes ?? []
            ))
        }

        let acceptance = (payload.acceptance ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return TeamPlan(
            goal: payload.goal.trimmingCharacters(in: .whitespacesAndNewlines),
            acceptance: acceptance,
            subtasks: subtasks,
            maxConcurrency: min(max(payload.maxConcurrency ?? 3, 1), 4)
        )
    }
}
