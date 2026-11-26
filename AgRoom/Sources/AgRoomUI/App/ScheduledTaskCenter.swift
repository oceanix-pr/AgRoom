import Foundation
import AppKit
import Observation
import AgRoomCore

// MARK: - Scheduled Task Center

public enum ScheduledTaskCenterError: Error, Equatable {
    case disabled
    case busy
    case notFound
    case databaseUnavailable
    case unsupportedProfile
    case startFailed
}

/// App 级定时调度中心：负责到期检查、启动/唤醒补算、单飞、运行记录与通知。
/// 执行仍然由 `ScheduledRunner` 复用 Core 的引擎组装；本类只处理 App 生命周期与 UI 状态。
///
/// 归属：App 进程内单例。关闭窗口后 App 仍驻留菜单栏，调度继续；⌘Q/注销后停止。
/// 数据：每个任务/运行记录绑定自身空间的 `DatabaseQueue`，不把服务缓存到 `Hub`。
@MainActor
@Observable
public final class ScheduledTaskCenter {

    public static let shared = ScheduledTaskCenter()

    /// 正在运行的任务 id（UI 用来显示运行中/停止按钮）。
    public private(set) var runningTaskIDs: Set<UUID> = []
    /// 任务或运行状态变化时递增；UI 监听后重新读取当前空间。
    public private(set) var revision = 0
    /// 最近一次扫描失败原因（脱敏；UI 只作诊断提示）。
    public private(set) var lastScanError: String?

    private var spaceStore: SpaceStore?
    private var scanLoop: Task<Void, Never>?
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeRunIdentities: [AppSpace: [UUID: UUID]] = [:]
    func activeRunIDs(in space: AppSpace) -> Set<UUID> { Set(activeRunIdentities[space]?.values.filter { pendingResults[$0] == nil } ?? []) }
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private struct PendingResult {
        let space: AppSpace
        let task: ScheduledTask
        let run: ScheduledRun
        let store: ScheduledRunStore
    }
    private var pendingResults: [UUID: PendingResult] = [:]
    private var savingResults: Set<UUID> = []
    private var failedSaveIDs: Set<UUID> = []
    private var timedOutRuns: Set<UUID> = []
    private var enabled: @MainActor () -> Bool = { DispatcherSettings.scheduledTasksEnabled }
    private var notificationSink: (@MainActor (String, String) async -> Void)?
    private var executeRun: @MainActor (SpaceStore, AppSpace, ScheduledTask, Date?, DaemonRunSettings, UUID) async -> ScheduledRunResult = {
        await ScheduledRunner.run(spaceStore: $0, space: $1, task: $2, scheduledFor: $3, settings: $4, runID: $5)
    }

    public var hasUnsavedResults: Bool { !failedSaveIDs.isEmpty }
    func hasPendingResult(taskID: UUID, space: AppSpace) -> Bool {
        pendingResults.values.contains { $0.space == space && $0.task.id == taskID && failedSaveIDs.contains($0.run.id) }
    }
    func isSavingResult(taskID: UUID, space: AppSpace) -> Bool {
        pendingResults.values.contains { $0.space == space && $0.task.id == taskID && savingResults.contains($0.run.id) }
    }
    func activeTaskIDs(in space: AppSpace) -> Set<UUID> {
        Set((activeRunIdentities[space] ?? [:]).filter { pendingResults[$0.value] == nil }.map(\.key))
    }
    func retrySaving(taskID: UUID, space: AppSpace) async {
        guard let entry = pendingResults.values.first(where: { $0.space == space && $0.task.id == taskID }) else { return }
        await persistCompleted(entry.run.id)
    }
    /// 正在写入运行记录/推进触发游标的启动中任务：防止扫码与手动运行在 await 间交错。
    private var startingTaskIDs: Set<UUID> = []
    private var isScanning = false
    private var rescanRequested = false
    private var lastEnabledState: Bool?
    private var resetFireDates = false
    private var settingGeneration = UUID()
    private var started = false
    private var activity: NSObjectProtocol?
    private var defaultObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {}

    /// An isolated scheduler host: no observers, production files or automatic scan loop.
    init(spaceStore: SpaceStore, enabled: @escaping @MainActor () -> Bool,
         execute: @escaping @MainActor (SpaceStore, AppSpace, ScheduledTask, Date?, DaemonRunSettings, UUID) async -> ScheduledRunResult,
         notification: @escaping @MainActor (String, String) async -> Void) {
        self.spaceStore = spaceStore; self.enabled = enabled; self.executeRun = execute
        self.notificationSink = notification; self.started = true
        self.lastEnabledState = enabled()
    }

    // MARK: - Lifecycle

    /// App 启动时调用（AppDelegate）。只启动一次；总开关关闭时仍保留扫描器，
    /// 用户开启设置后无需重启即可生效。
    public func start() {
        guard !started else { return }
        started = true
        // 与 daemon 相同：路径迁移必须先于任何空间库读取；重复调用幂等。
        spaceStore = SpaceStore()
        lastEnabledState = enabled()
        // 只避免 App Nap 合并/延迟 tick，不阻止系统睡眠。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.background],
            reason: "AgRoom scheduled tasks"
        )
        installObservers()
        scanLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await self?.scanDueTasks()
            }
        }
        Task { [weak self] in
            await self?.markInterruptedRuns()
            await self?.scanDueTasks()
        }
        HubLogger.shared.info("ScheduledTaskCenter started")
    }

    public func stop() {
        guard started else { return }
        started = false
        scanLoop?.cancel()
        scanLoop = nil
        for task in activeTasks.values { task.cancel() }
        for task in timeoutTasks.values { task.cancel() }
        activeTasks.removeAll()
        timeoutTasks.removeAll()
        runningTaskIDs = []
        for observer in defaultObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        defaultObservers.removeAll()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        spaceStore = nil
        isScanning = false
        rescanRequested = false
        HubLogger.shared.info("ScheduledTaskCenter stopped")
    }

    /// 设置开关切换、页面手动刷新时立即检查一次。
    public func refreshNow() {
        guard started else { return }
        Task { [weak self] in await self?.scanDueTasks() }
    }

    public func schedulingSettingChanged(to value: Bool) {
        if lastEnabledState == false && value { resetFireDates = true }
        lastEnabledState = value; settingGeneration = UUID()
        refreshNow()
    }

    public func isRunning(taskID: UUID, space: AppSpace) -> Bool {
        activeTaskIDs(in: space).contains(taskID)
    }

    /// 手动运行一次：不改变下一次计划时间；总开关关闭时拒绝。
    public func runNow(taskID: UUID, space: AppSpace) async throws {
        guard enabled() else { throw ScheduledTaskCenterError.disabled }
        guard let spaceStore, let queue = await spaceStore.prepare(space) else {
            throw ScheduledTaskCenterError.databaseUnavailable
        }
        guard activeTasks.isEmpty, startingTaskIDs.isEmpty, pendingResults.isEmpty else {
            throw ScheduledTaskCenterError.busy
        }
        startingTaskIDs.insert(taskID)
        defer { startingTaskIDs.remove(taskID) }

        let taskStore = ScheduledTaskStore(databaseQueue: queue)
        let runStore = ScheduledRunStore(databaseQueue: queue)
        guard let task = try await taskStore.task(id: taskID) else {
            throw ScheduledTaskCenterError.notFound
        }
        guard task.isProfileSupported else { throw ScheduledTaskCenterError.unsupportedProfile }

        let run = ScheduledRun(
            taskID: task.id,
            taskName: task.name,
            trigger: .manual,
            scheduledFor: nil
        )
        guard try await runStore.insert(run) else { throw ScheduledTaskCenterError.busy }
        do {
            try await beginExecution(
                space: space,
                task: task,
                run: run,
                nextFireAt: task.nextFireAt,
                spaceStore: spaceStore,
                taskStore: taskStore,
                runStore: runStore
            )
        } catch {
            var failed = run
            failed.status = .failed
            failed.finishedAt = Date()
            failed.errorCode = "start_failed"
            failed.errorText = error.localizedDescription
            try? await runStore.update(failed)
            throw ScheduledTaskCenterError.startFailed
        }
    }

    /// 请求停止当前任务；运行真正收尾后才从 runningTaskIDs 移除。
    public func cancel(taskID: UUID, space: AppSpace) {
        guard isRunning(taskID: taskID, space: space) else { return }
        activeTasks[taskID]?.cancel()
    }

    // MARK: - Scheduling

    private func markInterruptedRuns() async {
        guard let spaceStore else { return }
        for space in AppSpace.allCases {
            guard let queue = await spaceStore.prepare(space) else { continue }
            do {
                let count = try await ScheduledRunStore(databaseQueue: queue).markInterrupted()
                if count > 0 {
                    HubLogger.shared.warning(
                        "Scheduled runs marked interrupted in \(space.rawValue): \(count)"
                    )
                }
            } catch {
                HubLogger.shared.error(
                    "Scheduled run reconciliation failed in \(space.rawValue): \(HubLogger.safeErrorSummary(error))"
                )
            }
        }
    }

    private func scanDueTasks() async {
        guard started, let spaceStore else { return }
        guard enabled() else { lastEnabledState = false; return }
        if lastEnabledState == false { resetFireDates = true }
        lastEnabledState = true
        if isScanning {
            rescanRequested = true
            return
        }
        isScanning = true
        defer {
            isScanning = false
            if rescanRequested {
                rescanRequested = false
                Task { [weak self] in await self?.scanDueTasks() }
            }
        }

        let now = Date()
        if resetFireDates {
            let generation = settingGeneration
            do {
                for space in AppSpace.allCases {
                    if let queue = await spaceStore.prepare(space) { try await ScheduledTaskStore(databaseQueue: queue).resumeFromNow(now) }
                }
                guard enabled(), generation == settingGeneration else { return }
                resetFireDates = false; revision += 1
            } catch {
                lastScanError = L.string("scheduled.error.database_unavailable")
                return
            }
        }
        for space in AppSpace.allCases {
            guard let queue = await spaceStore.prepare(space) else { continue }
            let taskStore = ScheduledTaskStore(databaseQueue: queue)
            let runStore = ScheduledRunStore(databaseQueue: queue)
            do {
                let tasks = try await taskStore.enabled()
                for task in tasks where task.enabled && task.isProfileSupported {
                    let decision = ScheduleCalculator.dueDecision(
                        task: task,
                        now: now,
                        isActive: activeTasks[task.id] != nil
                    )
                    switch decision {
                    case .notDue:
                        continue
                    case .run(let scheduledFor, _):
                        // 全局单飞：已有任意定时运行（或正在启动）时，保留到期状态等下一轮。
                        guard activeTasks.isEmpty, startingTaskIDs.isEmpty, pendingResults.isEmpty else { continue }
                        let trigger: ScheduledRunTrigger = now.timeIntervalSince(scheduledFor) > 60
                            ? .catchUp
                            : .scheduled
                        await startScheduledRun(
                            space: space,
                            task: task,
                            scheduledFor: scheduledFor,
                            trigger: trigger,
                            now: now,
                            spaceStore: spaceStore,
                            taskStore: taskStore,
                            runStore: runStore
                        )
                    case .skipOverlap(let scheduledFor):
                        await recordSkippedOccurrence(
                            task: task,
                            scheduledFor: scheduledFor,
                            now: now,
                            taskStore: taskStore,
                            runStore: runStore
                        )
                    case .missed(let scheduledFor):
                        await recordMissedOccurrence(
                            space: space,
                            task: task,
                            scheduledFor: scheduledFor,
                            now: now,
                            taskStore: taskStore,
                            runStore: runStore
                        )
                    }
                }
                lastScanError = nil
            } catch {
                lastScanError = error.localizedDescription
                HubLogger.shared.error(
                    "Scheduled scan failed in \(space.rawValue): \(HubLogger.safeErrorSummary(error))"
                )
            }
        }
    }

    private func startScheduledRun(
        space: AppSpace,
        task: ScheduledTask,
        scheduledFor: Date,
        trigger: ScheduledRunTrigger,
        now: Date,
        spaceStore: SpaceStore,
        taskStore: ScheduledTaskStore,
        runStore: ScheduledRunStore
    ) async {
        guard activeTasks.isEmpty, startingTaskIDs.isEmpty, pendingResults.isEmpty else { return }
        startingTaskIDs.insert(task.id)
        defer { startingTaskIDs.remove(task.id) }

        let nextFireAt = ScheduleCalculator.nextFireDate(for: task.schedule, after: now)
        let run = ScheduledRun(
            taskID: task.id,
            taskName: task.name,
            trigger: trigger,
            scheduledFor: scheduledFor
        )

        do {
            let inserted = try await runStore.insert(run)
            // 先推进下一次触发，避免慢运行期间同一计划时刻被重复领取。
            // 即使 insert 因唯一索引返回 false（上一轮已记录该时刻），也必须推进，
            // 否则 nextFireAt 会永久停在过去并反复命中同一条记录。
            try await taskStore.updateNextFireAt(id: task.id, nextFireAt: nextFireAt)
            if nextFireAt == nil {
                try await taskStore.setEnabled(id: task.id, enabled: false)
            }
            guard inserted else { return }
            try await beginExecution(
                space: space,
                task: task,
                run: run,
                nextFireAt: nextFireAt,
                spaceStore: spaceStore,
                taskStore: taskStore,
                runStore: runStore
            )
        } catch {
            var failed = run
            failed.status = .failed
            failed.finishedAt = Date()
            failed.errorCode = "start_failed"
            failed.errorText = error.localizedDescription
            try? await runStore.update(failed)
            HubLogger.shared.error(
                "Scheduled run start failed for \(task.id.uuidString): \(HubLogger.safeErrorSummary(error))"
            )
        }
    }

    private func recordSkippedOccurrence(
        task: ScheduledTask,
        scheduledFor: Date,
        now: Date,
        taskStore: ScheduledTaskStore,
        runStore: ScheduledRunStore
    ) async {
        let run = ScheduledRun(
            taskID: task.id,
            taskName: task.name,
            trigger: .scheduled,
            scheduledFor: scheduledFor,
            status: .skipped,
            finishedAt: now,
            errorCode: "overlap",
            errorText: "The previous run was still active."
        )
        do {
            _ = try await runStore.insert(run)
        } catch {
            lastScanError = error.localizedDescription
            HubLogger.shared.error(
                "Scheduled overlap record failed for \(task.id.uuidString): \(HubLogger.safeErrorSummary(error))"
            )
            return
        }
        let nextFireAt = ScheduleCalculator.nextFireDate(for: task.schedule, after: now)
        try? await taskStore.updateNextFireAt(id: task.id, nextFireAt: nextFireAt)
        try? await taskStore.updateLastRun(id: task.id, lastRunAt: now, lastRunStatus: .skipped)
        if nextFireAt == nil {
            try? await taskStore.setEnabled(id: task.id, enabled: false)
        }
        revision += 1
    }

    private func recordMissedOccurrence(
        space: AppSpace,
        task: ScheduledTask,
        scheduledFor: Date,
        now: Date,
        taskStore: ScheduledTaskStore,
        runStore: ScheduledRunStore
    ) async {
        let run = ScheduledRun(
            taskID: task.id,
            taskName: task.name,
            trigger: .scheduled,
            scheduledFor: scheduledFor,
            status: .missed,
            finishedAt: now,
            errorCode: "missed",
            errorText: "The scheduled time passed outside the catch-up window."
        )
        do {
            _ = try await runStore.insert(run)
        } catch {
            lastScanError = error.localizedDescription
            HubLogger.shared.error(
                "Scheduled missed record failed for \(task.id.uuidString): \(HubLogger.safeErrorSummary(error))"
            )
            return
        }
        let nextFireAt = ScheduleCalculator.nextFireDate(for: task.schedule, after: now)
        try? await taskStore.updateNextFireAt(id: task.id, nextFireAt: nextFireAt)
        try? await taskStore.updateLastRun(id: task.id, lastRunAt: now, lastRunStatus: .missed)
        if nextFireAt == nil {
            try? await taskStore.setEnabled(id: task.id, enabled: false)
        }
        revision += 1
        await notifyMissed(space: space, task: task)
    }

    private func beginExecution(
        space: AppSpace,
        task: ScheduledTask,
        run: ScheduledRun,
        nextFireAt: Date?,
        spaceStore: SpaceStore,
        taskStore: ScheduledTaskStore,
        runStore: ScheduledRunStore
    ) async throws {
        var running = run
        running.status = .running
        running.startedAt = Date()
        try await runStore.update(running)

        let execution = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.executeRun(spaceStore, space, task, run.scheduledFor, Self.runSettings(), run.id)
            await self.finishExecution(
                space: space,
                task: task,
                run: running,
                result: result,
                nextFireAt: nextFireAt,
                taskStore: taskStore,
                runStore: runStore
            )
        }
        activeTasks[task.id] = execution
        activeRunIdentities[space, default: [:]][task.id] = run.id
        timeoutTasks[task.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(task.effectiveOptions.budget.seconds) + 1))
            guard !Task.isCancelled else { return }
            self?.timedOutRuns.insert(run.id)
            self?.activeTasks[task.id]?.cancel()
        }
        runningTaskIDs = Set(activeTasks.keys)
        revision += 1
    }

    private func finishExecution(
        space: AppSpace,
        task: ScheduledTask,
        run: ScheduledRun,
        result: ScheduledRunResult,
        nextFireAt: Date?,
        taskStore: ScheduledTaskStore,
        runStore: ScheduledRunStore
    ) async {
        var finished = run
        finished.status = result.status
        finished.finishedAt = Date()
        finished.outputText = result.outputText
        finished.summary = result.summary
        finished.toolNames = result.toolNames
        finished.toolCallCount = result.toolCallCount
        finished.inputTokens = result.inputTokens
        finished.outputTokens = result.outputTokens
        finished.errorCode = result.errorCode
        finished.errorText = result.errorText
        finished.durationMs = result.durationMs

        finished.experience = result.experience
        if timedOutRuns.remove(run.id) != nil {
            finished.status = .failed; finished.errorCode = "budget_time"
            finished.errorText = "The scheduled task reached its time limit."
        }
        timeoutTasks[task.id]?.cancel(); timeoutTasks[task.id] = nil
        pendingResults[run.id] = .init(space: space, task: task, run: finished, store: runStore)
        runningTaskIDs = Set(activeTasks.keys).subtracting(pendingResults.values.map { $0.task.id })
        revision += 1
        // User cancellation must not cancel the terminal receipt write itself.
        await Task { @MainActor in await self.persistCompleted(run.id) }.value
    }

    private func persistCompleted(_ runID: UUID) async {
        guard let pending = pendingResults[runID], !savingResults.contains(runID) else { return }
        savingResults.insert(runID)
        defer { savingResults.remove(runID); revision += 1 }
        for attempt in 0..<3 {
            do {
                let stored = try await pending.store.finish(pending.run, task: pending.task)
                failedSaveIDs.remove(runID)
                pendingResults[runID] = nil; activeTasks[pending.task.id] = nil
                if activeRunIdentities[pending.space]?[pending.task.id] == runID {
                    activeRunIdentities[pending.space]?[pending.task.id] = nil
                }
                runningTaskIDs = Set(activeTasks.keys).subtracting(pendingResults.values.map { $0.task.id })
                await notifyFinished(space: pending.space, task: pending.task, run: stored)
                HubLogger.shared.info("Scheduled result receipt committed: \(runID.uuidString)")
                return
            } catch {
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(250 * (attempt + 1))) }
            }
        }
        HubLogger.shared.error("Scheduled result receipt could not be committed; execution will not be replayed")
        failedSaveIDs.insert(runID)
    }

    // MARK: - Notifications

    private func notifyFinished(space: AppSpace, task: ScheduledTask, run: ScheduledRun) async {
        let isCurrentSpace = space == currentSpace
        switch run.status {
        case .succeeded:
            guard task.notificationPolicy.notifyOnSuccess, ScheduledComparison.shouldNotify(run),
                  !NSApplication.shared.isActive || task.effectiveOptions.notifyOnlyOnChange else { return }
            await sendNotification(
                title: L.string("scheduled.notify.succeeded.title"),
                body: isCurrentSpace
                    ? L.format("scheduled.notify.succeeded.body", task.name)
                    : L.string("scheduled.notify.other.succeeded.body")
            )
        case .failed:
            guard task.notificationPolicy.notifyOnFailure else { return }
            await sendNotification(
                title: L.string("scheduled.notify.failed.title"),
                body: isCurrentSpace
                    ? L.format("scheduled.notify.failed.body", task.name)
                    : L.string("scheduled.notify.other.failed.body")
            )
        default:
            break
        }
    }

    private func notifyMissed(space: AppSpace, task: ScheduledTask) async {
        guard task.notificationPolicy.notifyOnMissed else { return }
        await sendNotification(
            title: L.string("scheduled.notify.missed.title"),
            body: space == currentSpace
                ? L.format("scheduled.notify.missed.body", task.name)
                : L.string("scheduled.notify.other.missed.body")
        )
    }

    /// 当前展示空间：通知只对当前空间显示任务名，另一空间只报通用结果。
    /// `ScheduledTaskCenter` 不持有 UI 的 SpaceStore，读取 SpaceStore 持久化的当前空间键。
    private var currentSpace: AppSpace {
        AppSpace(rawValue: UserDefaults.standard.string(forKey: SpaceStore.StorageKeys.currentSpace) ?? "")
            ?? .work
    }

    private func sendNotification(title: String, body: String) async {
        if let notificationSink { await notificationSink(title, body); return }
        do {
            try await NotificationService().send(
                title: title,
                body: body,
                category: .scheduled
            )
        } catch {
            // 通知权限/分类关闭不改变运行结果；落库已完成。
            HubLogger.shared.warning("Scheduled notification skipped: \(HubLogger.safeErrorSummary(error))")
        }
    }

    // MARK: - Lifecycle Observers

    private func installObservers() {
        let defaultCenter = NotificationCenter.default
        defaultObservers.append(defaultCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        })
        defaultObservers.append(defaultCenter.addObserver(
            forName: NSNotification.Name.NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        })
        defaultObservers.append(defaultCenter.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        })
    }

    // MARK: - Settings Snapshot

    private static func runSettings() -> DaemonRunSettings {
        let replyLanguage = UserDefaults.standard.string(forKey: "agroom.agentReplyLanguage")
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        let effort = DispatcherSettings.reasoningEffort
        return DaemonRunSettings(
            maxTokens: min(DispatcherSettings.maxTokens, ScheduledCapabilityProfile.maxOutputTokens),
            temperature: DispatcherSettings.temperature,
            reasoningEffortRaw: effort == .standard ? nil : effort.rawValue,
            maxSteps: min(DispatcherSettings.maxSteps, ScheduledCapabilityProfile.maxSteps),
            replyLanguageInstruction: replyLanguage.agentReplyLanguageName,
            personaInstruction: DispatcherSettings.personaInstruction,
            dispatcherName: DispatcherSettings.dispatcherPromptName,
            workspacePath: "",
            autoReviewEnabled: false,
            permissionMode: .readOnly,
            teamTasksEnabled: false,
            teamWritesEnabled: false
        )
    }
}
