import Foundation

// MARK: - Team Coordinator

/// 每个任务一个协调器 actor：校验计划、按 DAG ready set 调度 Worker、
/// 汇总产物与用量、处理取消/失败/预算，并在检查点把报告快照交给持久化观察者。
///
/// 任务失败/取消会返回一份带已完成产物的报告，不会静默丢弃已经拿到的结果。
public typealias TeamReportObserver = @Sendable (TeamTaskReport) async -> Void

public actor TeamCoordinator {
    public nonisolated let events: AsyncStream<TeamTaskEvent>

    private let eventContinuation: AsyncStream<TeamTaskEvent>.Continuation
    private let taskID: UUID
    public let space: AppSpace
    private let plan: TeamPlan
    private let budget: TeamBudget
    private let blackboard: TeamBlackboard
    private let factory: any TeamWorkerFactory
    private let maxSubtasks: Int
    private let verifier: (any TeamVerifier)?
    private let progressCenter: TeamProgressCenter
    private let onReport: TeamReportObserver?
    private let parentBudget: ExecutionBudgetLedger?
    private let inheritedDeadline: Date?
    private var startedAt = Date()

    private var status: TeamTaskStatus = .planning
    private var runTask: Task<TeamTaskReport, Error>?
    /// 终态报告缓存：同一协调器重复 run() 必须返回同一结果，不能重跑副作用。
    private var terminalReport: TeamTaskReport?
    private var cancelRequested = false

    public init(
        taskID: UUID = UUID(),
        space: AppSpace = .work,
        plan: TeamPlan,
        budget: TeamBudget = .default,
        blackboard: TeamBlackboard = TeamBlackboard(),
        factory: any TeamWorkerFactory,
        verifier: (any TeamVerifier)? = nil,
        progressCenter: TeamProgressCenter = .shared,
        maxSubtasks: Int = TeamPlanValidator.maximumSubtasks,
        onReport: TeamReportObserver? = nil,
        parentBudget: ExecutionBudgetLedger? = nil,
        deadline: Date? = nil
    ) {
        self.taskID = taskID
        self.space = space
        self.plan = plan
        self.budget = budget
        self.blackboard = blackboard
        self.factory = factory
        self.verifier = verifier
        self.progressCenter = progressCenter
        self.maxSubtasks = maxSubtasks
        self.onReport = onReport
        self.parentBudget = parentBudget
        self.inheritedDeadline = deadline
        let (stream, continuation) = AsyncStream.makeStream(
            of: TeamTaskEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        self.events = stream
        self.eventContinuation = continuation
    }

    public var currentStatus: TeamTaskStatus { status }

    /// 请求取消：取消共享的 run Task，子 Worker 的结构化任务随之收到取消。
    public func cancel() {
        cancelRequested = true
        runTask?.cancel()
    }

    /// 等待当前运行真正收尾（删除任务前使用，避免记录已删但 Worker 还在写）。
    public func waitForCompletion() async {
        guard let runTask else { return }
        _ = await runTask.result
    }

    /// 执行任务。重复调用优先返回缓存的终态报告；运行中则复用同一个 run Task。
    /// 显式重试需要创建新的协调器/运行 ID，而不是再次调用这里。
    public func run() async throws -> TeamTaskReport {
        if let terminalReport { return terminalReport }
        if let existing = runTask {
            return try await existing.value
        }
        let task = Task { try await self.execute() }
        runTask = task
        do {
            let report = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            terminalReport = report
            runTask = nil
            return report
        } catch {
            runTask = nil
            throw error
        }
    }

    // MARK: Execution

    private func execute() async throws -> TeamTaskReport {
        do {
            try TeamPlanValidator.validate(plan, budget: budget, maxSubtasks: maxSubtasks)
        } catch {
            status = .failed
            eventContinuation.finish()
            throw error
        }

        status = .running
        startedAt = Date()
        let eventSink: @Sendable (TeamTaskEvent) -> Void = { [eventContinuation] event in
            eventContinuation.yield(event)
        }
        eventSink(.started(taskID: taskID, goal: plan.goal))

        // 局部常量：Worker 任务只捕获 Sendable 值，避免把 actor 的隔离状态带进子任务。
        let factory = self.factory
        let taskID = self.taskID
        let plan = self.plan
        let budget = self.budget
        let blackboard = self.blackboard
        let verifier = self.verifier
        let progressCenter = self.progressCenter
        let onReport = self.onReport
        let startedAt = self.startedAt
        let maxConcurrency = min(
            plan.maxConcurrency,
            budget.maxConcurrentWorkers,
            TeamPlanValidator.maximumConcurrency
        )
        // 只有显式设置团队 Token 上限，才从这份额度中为验证预留。
        let verificationReserve = verifier == nil
            ? 0
            : (budget.maxTokens.map { max(1_024, $0 / 10) } ?? 0)
        let budgetLedger = ExecutionBudgetLedger(
            maxTokens: budget.maxTokens,
            maxToolCalls: budget.maxToolCalls,
            deadline: min(inheritedDeadline ?? .distantFuture, startedAt.addingTimeInterval(budget.maxWallClockSeconds)),
            verificationReserve: verificationReserve,
            parent: parentBudget
        )

        var pending = Set(plan.subtasks.map(\.id))
        var succeeded = Set<UUID>()
        var finished = Set<UUID>()
        var results: [UUID: TeamSubtaskResult] = [:]
        var reports: [UUID: TeamSubtaskReport] = [:]
        var artifactsBySubtask: [UUID: [TeamArtifact]] = [:]
        var usage = TeamUsage.zero
        var openQuestions: [String] = []
        var errors: [String] = []
        var reservedTokens = 0
        var runningWorkers = 0
        var runningSubtasks = Set<UUID>()
        var budgetExceeded = false

        // 任务板先看到“已启动”的记录；运行中每个子任务结束后再刷新一次快照。
        if let onReport {
            let initial = Self.makeReport(
                taskID: taskID,
                plan: plan,
                status: .running,
                reports: [:],
                artifacts: [],
                usage: .zero,
                openQuestions: [],
                errors: [],
                startedAt: startedAt,
                finishedAt: Date(),
                verification: nil
            )
            await onReport(initial)
        }

        await withTaskGroup(of: WorkerCompletion.self) { group in
            defer { group.cancelAll() }
            let deadlineID = UUID()
            let remaining = max(0, budgetLedger.deadline?.timeIntervalSinceNow ?? budget.maxWallClockSeconds)
            group.addTask {
                try? await Task.sleep(for: .seconds(remaining))
                return WorkerCompletion(subtaskID: deadlineID, workerName: "deadline", result: nil, error: "deadline")
            }
            while true {
                if Task.isCancelled {
                    cancelRequested = true
                }
                if cancelRequested {
                    group.cancelAll()
                    break
                }
                if let deadline = budgetLedger.deadline, Date() >= deadline {
                    errors.append("Task wall-clock budget exceeded.")
                    budgetExceeded = true
                    group.cancelAll()
                    break
                }
                if budget.maxTokens.map({ usage.tokens >= $0 }) == true || usage.toolCalls >= budget.maxToolCalls {
                    errors.append("Task token or tool-call budget exceeded.")
                    budgetExceeded = true
                    group.cancelAll()
                    break
                }

                // 上游已终结但未成功：下游递归标 blocked，而不是让它们永远等一个不会来的产物。
                var changed = true
                while changed {
                    changed = false
                    for subtask in plan.subtasks where pending.contains(subtask.id) {
                        let dependencies = Set(subtask.dependsOn)
                        guard dependencies.contains(where: { finished.contains($0) && !succeeded.contains($0) }) else {
                            continue
                        }
                        pending.remove(subtask.id)
                        finished.insert(subtask.id)
                        let reason = "Skipped because an upstream subtask did not succeed."
                        reports[subtask.id] = TeamSubtaskReport(
                            id: subtask.id,
                            title: subtask.title,
                            role: subtask.role.rawValue,
                            outcome: .blocked,
                            summary: reason
                        )
                        errors.append("\(subtask.title): \(reason)")
                        changed = true
                    }
                }

                let ready = plan.subtasks.filter { subtask in
                    pending.contains(subtask.id)
                        && Set(subtask.dependsOn).isSubset(of: succeeded)
                }
                var capacity = maxConcurrency - runningWorkers
                for subtask in ready {
                    guard capacity > 0 else { break }
                    if let limit = budget.maxTokens {
                        guard subtask.estimatedTokens <= limit - usage.tokens - reservedTokens else {
                            pending.remove(subtask.id)
                            finished.insert(subtask.id)
                            reports[subtask.id] = TeamSubtaskReport(
                                id: subtask.id,
                                title: subtask.title,
                                role: subtask.role.rawValue,
                                outcome: .blocked,
                                summary: "Skipped: token budget would be exceeded."
                            )
                            errors.append("\(subtask.title): skipped because the token budget would be exceeded.")
                            continue
                        }
                        reservedTokens += subtask.estimatedTokens
                    }
                    let inputs = subtask.dependsOn.flatMap { artifactsBySubtask[$0] ?? [] }
                    pending.remove(subtask.id)
                    runningWorkers += 1
                    runningSubtasks.insert(subtask.id)
                    capacity -= 1
                    eventSink(.subtaskStarted(
                        taskID: taskID,
                        subtaskID: subtask.id,
                        title: subtask.title,
                        role: subtask.role.rawValue,
                        agent: subtask.assignee ?? subtask.role.rawValue
                    ))
                    group.addTask {
                        await Self.runWorker(
                            factory: factory,
                            taskID: taskID,
                            plan: plan,
                            subtask: subtask,
                            inputs: inputs,
                            budget: budget,
                            budgetLedger: budgetLedger
                        )
                    }
                }

                if runningWorkers == 0 {
                    if pending.isEmpty { break }
                    // 走到这里说明剩余节点依赖未满足且没有被上面的 blocked 逻辑覆盖；
                    // 保守收尾，避免调度器死循环。
                    for id in pending {
                        guard let subtask = plan.subtasks.first(where: { $0.id == id }) else { continue }
                        reports[id] = TeamSubtaskReport(
                            id: id,
                            title: subtask.title,
                            role: subtask.role.rawValue,
                            outcome: .blocked,
                            summary: "Not scheduled: dependencies could not be resolved."
                        )
                        errors.append("\(subtask.title): dependencies could not be resolved.")
                    }
                    pending.removeAll()
                    break
                }

                guard let completion = await group.next() else { break }
                if completion.subtaskID == deadlineID {
                    errors.append("Task wall-clock budget exceeded.")
                    budgetExceeded = true
                    group.cancelAll()
                    break
                }
                runningWorkers -= 1
                runningSubtasks.remove(completion.subtaskID)
                guard let subtask = plan.subtasks.first(where: { $0.id == completion.subtaskID }) else {
                    continue
                }
                reservedTokens = max(0, reservedTokens - subtask.estimatedTokens)

                if let result = completion.result {
                    results[subtask.id] = result
                    usage = usage.adding(result.usage)
                    openQuestions.append(contentsOf: result.openQuestions)
                    // 失败/阻塞的 Worker 也可能留下有价值的半成品；产物照常入黑板，
                    // 只是不会解锁依赖它的下游节点。
                    let committed = result.artifacts.isEmpty
                        ? []
                        : await blackboard.commit(
                            taskID: taskID,
                            subtaskID: subtask.id,
                            producer: completion.workerName,
                            drafts: result.artifacts
                        )
                    if result.outcome == .succeeded {
                        artifactsBySubtask[subtask.id] = committed
                        succeeded.insert(subtask.id)
                        finished.insert(subtask.id)
                        reports[subtask.id] = TeamSubtaskReport(
                            id: subtask.id,
                            title: subtask.title,
                            role: subtask.role.rawValue,
                            outcome: .succeeded,
                            summary: result.summary,
                            artifacts: committed.map(\.ref),
                            evidence: result.evidence,
                            usage: result.usage
                        )
                    } else {
                        finished.insert(subtask.id)
                        let message = result.summary.isEmpty ? "Subtask did not succeed." : result.summary
                        reports[subtask.id] = TeamSubtaskReport(
                            id: subtask.id,
                            title: subtask.title,
                            role: subtask.role.rawValue,
                            outcome: result.outcome,
                            summary: message,
                            artifacts: committed.map(\.ref),
                            evidence: result.evidence,
                            usage: result.usage
                        )
                        errors.append("\(subtask.title): \(message)")
                    }
                    eventSink(.subtaskFinished(
                        taskID: taskID,
                        subtaskID: subtask.id,
                        outcome: result.outcome,
                        summary: result.summary
                    ))
                } else {
                    finished.insert(subtask.id)
                    let message = completion.error ?? "Worker failed without a result."
                    reports[subtask.id] = TeamSubtaskReport(
                        id: subtask.id,
                        title: subtask.title,
                        role: subtask.role.rawValue,
                        outcome: .failed,
                        summary: message
                    )
                    errors.append("\(subtask.title): \(message)")
                    eventSink(.subtaskFinished(
                        taskID: taskID,
                        subtaskID: subtask.id,
                        outcome: .failed,
                        summary: message
                    ))
                }
                if let onReport {
                    let snapshot = Self.makeReport(
                        taskID: taskID,
                        plan: plan,
                        status: .running,
                        reports: reports,
                        artifacts: await blackboard.artifacts(for: taskID),
                        usage: usage,
                        openQuestions: openQuestions,
                        errors: errors,
                        startedAt: startedAt,
                        finishedAt: Date(),
                        verification: nil
                    )
                    await onReport(snapshot)
                }
            }
            group.cancelAll()
        }

        // 补全未启动/未收尾节点：取消/预算/依赖失败都要有明确报告，不能从结果里消失。
        for subtask in plan.subtasks where reports[subtask.id] == nil {
            let wasRunning = runningSubtasks.contains(subtask.id)
            let outcome: TeamSubtaskOutcome = (cancelRequested || wasRunning) ? .blocked : .failed
            let summary: String
            if cancelRequested {
                summary = wasRunning ? "Cancelled while running." : "Cancelled before start."
            } else if wasRunning {
                summary = budgetExceeded
                    ? "Not completed: the task limit was reached while this worker was running."
                    : "Not completed: the worker was still running when the task ended."
            } else if budgetExceeded {
                summary = "Not run: task budget was exhausted."
            } else {
                summary = "Not run."
            }
            reports[subtask.id] = TeamSubtaskReport(
                id: subtask.id,
                title: subtask.title,
                role: subtask.role.rawValue,
                outcome: outcome,
                summary: summary
            )
            if !cancelRequested {
                errors.append("\(subtask.title): \(summary)")
            }
        }

        let allSucceeded = plan.subtasks.allSatisfy { results[$0.id]?.outcome == .succeeded }

        // 独立验证：只在全部子任务成功且未取消/未超预算时执行。
        // 验证者的 token 用量进入任务账本；结论失败或格式不可解析都按失败处理。
        var verification: TeamVerification?
        if !cancelRequested, !budgetExceeded, allSucceeded, let verifier {
            await budgetLedger.releaseVerificationReserve()
            let artifactsForVerifier = await blackboard.artifacts(for: taskID)
            let subtaskReports = plan.subtasks.compactMap { reports[$0.id] }
            do {
                verification = try await TaskDeadline.run(until: budgetLedger.deadline) { [plan, taskID] in
                    await verifier.verify(taskID: taskID, plan: plan, artifacts: artifactsForVerifier,
                                          subtasks: subtaskReports, budgetLedger: budgetLedger)
                }
            } catch {
                budgetExceeded = true
                errors.append("Verification exceeded the task deadline or was cancelled.")
            }
            if let verification {
                usage = usage.adding(verification.usage)
                if !verification.passed {
                    errors.append("Verification failed: \(verification.summary)")
                }
                if budget.maxTokens.map({ usage.tokens > $0 }) == true || usage.toolCalls > budget.maxToolCalls {
                    budgetExceeded = true
                    errors.append("Task budget exceeded after verification.")
                }
            }
            if Task.isCancelled {
                cancelRequested = true
            }
        }
        let finishedAt = Date()

        let finalStatus: TeamTaskStatus
        if cancelRequested {
            finalStatus = .cancelled
        } else if budgetExceeded {
            // 所有节点都成功但总用量越过任务上限时，任务仍是失败的：
            // 不能让“看起来完成”掩盖预算超支。
            finalStatus = .failed
        } else if allSucceeded, verification?.passed != false {
            finalStatus = .completed
        } else {
            finalStatus = .failed
        }

        var totalUsage = usage
        totalUsage.duration = finishedAt.timeIntervalSince(startedAt)
        let artifacts = await blackboard.artifacts(for: taskID)
        let uniqueQuestions = Self.unique(openQuestions)
        let uniqueErrors = Self.unique(errors)
        let orderedReports = plan.subtasks.compactMap { reports[$0.id] }

        let report = TeamTaskReport(
            taskID: taskID,
            goal: plan.goal,
            status: finalStatus,
            subtasks: orderedReports,
            artifacts: artifacts,
            usage: totalUsage,
            openQuestions: uniqueQuestions,
            errors: uniqueErrors,
            startedAt: startedAt,
            finishedAt: finishedAt,
            verification: verification,
            estimatedTokens: plan.estimatedTokens
        )
        status = finalStatus
        await progressCenter.clear(taskID: taskID)
        await onReport?(report)
        eventSink(.finished(report))
        eventContinuation.finish()
        return report
    }

    // MARK: Worker Execution

    private struct WorkerCompletion: Sendable {
        let subtaskID: UUID
        let workerName: String
        let result: TeamSubtaskResult?
        let error: String?
    }

    private static func runWorker(
        factory: any TeamWorkerFactory,
        taskID: UUID,
        plan: TeamPlan,
        subtask: TeamSubtask,
        inputs: [TeamArtifact],
        budget: TeamBudget,
        budgetLedger: ExecutionBudgetLedger
    ) async -> WorkerCompletion {
        let started = Date()
        do {
            let worker = try await factory.makeWorker(
                taskID: taskID,
                plan: plan,
                subtask: subtask,
                inputs: inputs,
                budget: budget,
                budgetLedger: budgetLedger
            )
            try Task.checkCancellation()
            var result = try await worker.run()
            try Task.checkCancellation()
            result.subtaskID = subtask.id
            result.usage.duration = Date().timeIntervalSince(started)
            if result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.summary = "Worker returned no summary."
            }
            // 即使 Worker 忘了提交产物，成功结果也要有一个可被下游读取的摘要产物。
            if result.outcome == .succeeded, result.artifacts.isEmpty {
                result.artifacts = [
                    TeamArtifactDraft(
                        kind: subtask.outputKind.isEmpty ? "report" : subtask.outputKind,
                        title: subtask.title,
                        content: result.summary
                    )
                ]
            }
            return WorkerCompletion(
                subtaskID: subtask.id,
                workerName: worker.name,
                result: result,
                error: nil
            )
        } catch is CancellationError {
            return WorkerCompletion(
                subtaskID: subtask.id,
                workerName: subtask.assignee ?? subtask.role.rawValue,
                result: nil,
                error: "cancelled"
            )
        } catch {
            return WorkerCompletion(
                subtaskID: subtask.id,
                workerName: subtask.assignee ?? subtask.role.rawValue,
                result: nil,
                error: error.localizedDescription
            )
        }
    }

    private static func makeReport(
        taskID: UUID,
        plan: TeamPlan,
        status: TeamTaskStatus,
        reports: [UUID: TeamSubtaskReport],
        artifacts: [TeamArtifact],
        usage: TeamUsage,
        openQuestions: [String],
        errors: [String],
        startedAt: Date,
        finishedAt: Date,
        verification: TeamVerification?
    ) -> TeamTaskReport {
        TeamTaskReport(
            taskID: taskID,
            goal: plan.goal,
            status: status,
            subtasks: plan.subtasks.compactMap { reports[$0.id] },
            artifacts: artifacts,
            usage: usage,
            openQuestions: unique(openQuestions),
            errors: unique(errors),
            startedAt: startedAt,
            finishedAt: finishedAt,
            verification: verification,
            estimatedTokens: plan.estimatedTokens
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
