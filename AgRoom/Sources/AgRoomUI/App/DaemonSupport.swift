import Foundation
import AppKit
import Observation
import AgRoomCore
import Darwin

// MARK: - Daemon Controller（守护进程拉起）

/// 定位并拉起守护进程可执行文件。
/// 二进制位置（按优先级）：
/// 1. 环境变量 AGROOM_DAEMON_PATH（开发调试用）
/// 2. App 包内 Contents/MacOS/AgRoomDaemon（XcodeGen embed 正式布局）
/// 3. 与当前可执行文件同目录（swift run / .build/debug 布局）
public enum DaemonController {

    private static let relayReadyPrefix = "AGROOM_DAEMON_READY_V2 "
    private static let relayReadyTimeout: TimeInterval = 10
    @MainActor private static var readyRelayProcess: Process?

    @MainActor
    public static func spawnDaemon() {
        if let readyRelayProcess, readyRelayProcess.isRunning { return }
        guard let url = locateDaemonBinary() else {
            HubLogger.shared.error("Daemon binary not found; background tasks will wait for next launch")
            return
        }
        let process = Process()
        process.executableURL = url
        process.arguments = []
        // Process-wide output cannot be attributed to one space. Structured
        // diagnostics use HubLogger; do not append raw stderr to global daemon/.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            HubLogger.shared.info("Daemon spawned (pid \(process.processIdentifier))")
        } catch {
            HubLogger.shared.error("Daemon spawn failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    /// Start the bundled Daemon while an older version may still hold the
    /// global lock. A versioned nonce reply proves this child has opened the
    /// lock inode and entered its wait path before the App exits.
    @MainActor
    public static func spawnRelayDaemon() async -> Bool {
        // A prior worker may have completed its last scan while still alive.
        // Each exit with actionable records needs a newly armed waiter.
        guard let url = locateDaemonBinary() else {
            HubLogger.shared.error("Daemon relay binary not found")
            return false
        }
        let nonce = UUID().uuidString
        let pipe = Pipe()
        let process = Process()
        process.executableURL = url
        process.arguments = ["--wait-for-lock", "--ready-token", nonce]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            HubLogger.shared.error("Daemon relay spawn failed: \(HubLogger.safeErrorSummary(error))")
            return false
        }
        pipe.fileHandleForWriting.closeFile()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let ready = await Task.detached(priority: .utility) {
            waitForRelayReady(fd: descriptor, nonce: nonce)
        }.value
        pipe.fileHandleForReading.closeFile()
        if !ready, process.isRunning { process.terminate() }
        if ready {
            readyRelayProcess = process
            HubLogger.shared.info("Daemon relay is ready to acquire the global lock")
        } else {
            HubLogger.shared.error("Daemon relay did not acknowledge the handoff")
        }
        return ready
    }

    private nonisolated static func waitForRelayReady(fd: Int32, nonce: String) -> Bool {
        let expected = Array((relayReadyPrefix + nonce + "\n").utf8)
        let deadline = Date().addingTimeInterval(relayReadyTimeout)
        var received: [UInt8] = []
        while true {
            let remaining = Int32(max(0, min(10_000, Int(deadline.timeIntervalSinceNow * 1_000))))
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let status = Darwin.poll(&descriptor, 1, remaining)
            if status == 0 { return false }
            if status < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard descriptor.revents & Int16(POLLIN) != 0 else { return false }
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            guard count > 0 else { return false }
            received.append(contentsOf: bytes.prefix(count))
            guard received.count <= 256, expected.starts(with: received) else { return false }
            if received.last == 10 { return received == expected }
        }
    }

    static func locateDaemonBinary() -> URL? {
        if let override = ProcessInfo.processInfo.environment["AGROOM_DAEMON_PATH"],
           FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        var candidates: [URL] = []
        let bundle = Bundle.main.bundleURL
        // XcodeGen embed：tool 依赖进 Contents/Resources（CodeSignOnCopy）
        candidates.append(bundle.appendingPathComponent("Contents/Resources/AgRoomDaemon"))
        candidates.append(bundle.appendingPathComponent("Contents/MacOS/AgRoomDaemon"))
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("AgRoomDaemon"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Daemon Supervisor（启动监督 + 轮询）

/// App 侧守护进程监督器：
/// - 启动时若有遗留移交且守护进程未存活 → 补拉（含崩溃自愈）
/// - 2s 轮询移交目录与 PID 锁；从「运行中 → 清空」边沿发完成通知（ChatViewModel 刷新）
/// - 公布后台会话集合：ChatView 据此禁发对应会话，避免与后台写回互相踩踏
@MainActor
@Observable
public final class DaemonSupervisor {

    public static let shared = DaemonSupervisor()

    /// 守护进程全部任务完成（ChatViewModel 从库刷新）
    public static let daemonRunsDidFinish = Notification.Name("agroom.daemon.runsDidFinish")

    /// 守护进程存活且有任务在跑
    public private(set) var isRunning = false
    /// Menu-bar coordination without exposing cross-space session IDs.
    public private(set) var hasBlockedSessions = false
    private var backgroundSessionIdsBySpace: [AppSpace: Set<UUID>] = [:]
    public private(set) var recoverySessionIds: [AppSpace: Set<UUID>] = [:]
    /// Legacy corrupt evidence has no trusted session owner. Until it is
    /// inspected, no conversation can safely start a new run.
    public private(set) var hasUnattributedHandoffEvidence = false
    public private(set) var spacesWithUnattributedEvidence: Set<AppSpace> = []

    private var timer: Timer?
    /// 进行中的轮询任务：上一轮未完成时跳过，避免 I/O 变慢时任务堆积
    private var refreshTask: Task<Void, Never>?
    private var lastRespawnAttempt: Date?
    private static let respawnBackoff: TimeInterval = 5

    private init() {}

    /// App 启动调用：遗留移交补拉守护进程 + 开始轮询
    public func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 指定会话是否后台执行中（ChatView 发送守卫）
    public func isBackgroundRun(space: AppSpace, sessionID: UUID?) -> Bool {
        if hasUnattributedHandoffEvidence || spacesWithUnattributedEvidence.contains(space) { return true }
        guard let sessionID else { return false }
        return backgroundSessionIdsBySpace[space]?.contains(sessionID) == true
    }

    /// 轮询移交目录与 PID 锁。
    ///
    /// 目录枚举 + 逐 `run-*.json` 解码 + `pendingHandoffs()` + PID 存活探测都是文件 I/O，
    /// 全部放到后台执行，只把「后台会话集合 / 守护进程存活」两个结果带回 MainActor 应用：
    /// 2s 周期若在主线程做整套扫描，记录堆积后会把主线程持续拉进解码与目录枚举。
    private func refresh() {
        guard refreshTask == nil else { return }
        let store = DaemonHandoffStore.standard
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                let ownership = store.ownershipSnapshot()
                return (blockedBySpace: ownership.blockedSessionIdsBySpace,
                    actionable: ownership.hasActionableRecords,
                    alive: store.isDaemonAlive(), recoveries: ownership.recoverySessionIds,
                    unattributed: ownership.hasUnattributedQuarantine,
                    unattributedSpaces: ownership.unattributedSpaces)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            if self.recoverySessionIds != snapshot.recoveries { self.recoverySessionIds = snapshot.recoveries }
            if self.hasUnattributedHandoffEvidence != snapshot.unattributed {
                self.hasUnattributedHandoffEvidence = snapshot.unattributed
            }
            if self.spacesWithUnattributedEvidence != snapshot.unattributedSpaces {
                self.spacesWithUnattributedEvidence = snapshot.unattributedSpaces
            }
            self.apply(blockedBySpace: snapshot.blockedBySpace,
                actionable: snapshot.actionable, alive: snapshot.alive)
        }
    }

    /// 在 MainActor 上应用一次轮询结果：补拉守护进程 + 更新对外状态 + 完成边沿通知
    private func apply(blockedBySpace: [AppSpace: Set<UUID>], actionable: Bool, alive: Bool) {
        if !alive, actionable,
           lastRespawnAttempt.map({ Date().timeIntervalSince($0) >= Self.respawnBackoff }) ?? true {
            // 运行期也监督：daemon 崩溃或锁释放竞态留下任务时，带退避重新拉起。
            lastRespawnAttempt = Date()
            DaemonController.spawnDaemon()
        }
        let nowRunning = alive && actionable
        let finishedEdge = isRunning && !nowRunning && !actionable
        // 仅在值真正变化时赋值：@Observable 的 setter 无条件通知观察者，
        // 每 2s 无脑赋值会让 RootView/ChatView 持续重算 body，把整窗反复带进
        // 布局与约束更新，放大 AppKit「约束更新途中再次请求更新」的崩溃面
        if isRunning != nowRunning { isRunning = nowRunning }
        if backgroundSessionIdsBySpace != blockedBySpace { backgroundSessionIdsBySpace = blockedBySpace }
        let blocked = blockedBySpace.values.contains { !$0.isEmpty }
        if hasBlockedSessions != blocked { hasBlockedSessions = blocked }
        if finishedEdge {
            NotificationCenter.default.post(name: Self.daemonRunsDidFinish, object: nil)
        }
    }
}

// MARK: - Chat Run Identity（运行身份）

/// 一次发送的运行身份：每次发送（或挂起后原地续跑）都产生新 id。
/// 引擎回调与任务收尾都携带该 id，UI 据此丢弃旧运行的迟到事件，
/// 避免「停止后立即再发送」时旧回调污染新消息或清零新运行的全局状态
struct ChatRunID: Hashable, Sendable {
    let value: UUID

    init() {
        value = UUID()
    }
}

/// 一次发送的运行上下文：本轮所有可变运行态（引擎、任务、流式缓冲、轨迹）的唯一所有者。
/// 旧运行的收尾只清理自己的上下文；新运行建立后旧上下文不再持有任何全局状态
@MainActor
final class ChatRunContext {
    let id: ChatRunID
    /// 本轮归属空间（写回/移交时指明空间库）
    let space: AppSpace
    /// 本轮归属会话 id
    let sessionID: UUID
    /// 本轮助手消息 id（流式写回与结果写回按此定位）
    let messageID: UUID
    /// 只影响尚未执行的调用；变更世代使在途审核失效。
    private(set) var autoReviewEnabled: Bool
    private(set) var autoReviewRevision: UInt = 0
    /// 本轮权限模式快照：运行/挂起期间界面禁止切换，保证一轮内能力上限稳定
    let permissionMode: PermissionMode
    let workspacePath: String
    let memoryExcluded: Bool

    func updateAutoReview(_ enabled: Bool) {
        autoReviewEnabled = enabled
        autoReviewRevision &+= 1
    }

    func acceptsAutoReview(revision: UInt) -> Bool {
        autoReviewEnabled && autoReviewRevision == revision
    }

    /// 本轮引擎（挂起态保留以支持原地续跑）
    var engine: DispatcherEngine?
    var goalID: UUID?
    var goalStartingRevision: UUID?
    var goalExecution: GoalExecutionSnapshot?
    var goalProgress: GoalProgressState?
    var goalRequestedStop: GoalStopReason?
    /// 本轮任务（挂起后为 nil）
    var task: Task<Void, Never>?
    /// 是否正在流式执行；确认/提问挂起后为 false（但上下文保留）
    var isStreaming = false
    /// 退出移交中：取消本地任务但不按「已中止」落库（守护进程接管续跑）
    var isHandingOff = false
    /// Only a confirmed session save makes a suspended confirmation/question
    /// safe to review after restart without keeping this live engine.
    var suspensionPersisted = false
    /// 本轮已执行的工具轨迹（脱离 liveTrace 全局镜像，供旧运行独立收尾）
    var trace: [DispatcherTraceEntry] = []

    /// 正文增量缓冲（模型 token 频率远高于渲染需求，150ms 合并一次写回）
    var streamBuffer = ""
    var lastDeltaFlush = Date.distantPast
    var deltaFlushScheduled = false
    /// 轮中周期落盘时间戳：流式写回每 8 秒静默持久化一次
    var lastStreamPersist: Date?
    /// 推理增量缓冲（思考型模型）
    var reasoningBuffer = ""
    var reasoningFlushScheduled = false
    /// 终态已用完整记录覆盖预览，迟到增量不得再次追加。
    var hasFinalResponse = false
    /// 取消或失败已经进入保存收尾，不能再次取消其保存任务。
    var isFinishing = false
    /// 人工保存重试可能在取消收尾尚未退出时完成。
    var terminalSaveSucceeded = false

    init(
        id: ChatRunID = ChatRunID(),
        space: AppSpace,
        sessionID: UUID,
        messageID: UUID,
        autoReviewEnabled: Bool = false,
        permissionMode: PermissionMode = .workspaceWrite,
        workspacePath: String = "",
        memoryExcluded: Bool = false
    ) {
        self.id = id
        self.space = space
        self.sessionID = sessionID
        self.messageID = messageID
        self.autoReviewEnabled = autoReviewEnabled
        self.permissionMode = permissionMode
        self.workspacePath = workspacePath
        self.memoryExcluded = memoryExcluded
    }
}

/// 运行槽：按会话持有各自的运行上下文，保证「收尾只清自己会话的运行」。
/// 独立于视图模型，可直接对运行身份语义做回归测试：
/// 「停止 → 立即再次发送」时旧运行的收尾不得清零新运行；
/// A、B 两个会话可各跑一轮，A 的收尾不影响仍在运行的 B
@MainActor
@Observable
final class ChatRunState {
    /// 会话 id → 该会话当前运行上下文（键不存在 = 该会话空闲）
    private var runsBySession: [UUID: ChatRunContext] = [:]

    /// 全部运行上下文（退出移交按运行枚举）
    var allRuns: [ChatRunContext] { Array(runsBySession.values) }

    /// 指定会话的当前运行（nil = 该会话空闲）
    func current(for sessionId: UUID) -> ChatRunContext? {
        runsBySession[sessionId]
    }

    /// 开始一轮运行（新发送 / 挂起后原地续跑）。同一会话只保留最新运行
    func begin(_ run: ChatRunContext) {
        run.isStreaming = true
        runsBySession[run.sessionID] = run
    }

    /// 该上下文是否仍是其所属会话的当前运行身份
    func isCurrent(_ run: ChatRunContext) -> Bool {
        runsBySession[run.sessionID]?.id == run.id
    }

    /// 事件投递判定：返回仍持有该 runID 的运行上下文（旧运行的事件返回 nil）。
    /// 按 runID 全表查找：其他会话建立新运行不会让本会话的合法事件被丢弃
    func accept(_ runID: ChatRunID) -> ChatRunContext? {
        runsBySession.values.first { $0.id == runID && !$0.isHandingOff }
    }

    /// 按身份收尾：仅当仍是所属会话的当前运行才清理；返回是否真的清理了
    @discardableResult
    func finish(_ run: ChatRunContext) -> Bool {
        guard isCurrent(run) else { return false }
        run.engine = nil
        run.isStreaming = false
        runsBySession[run.sessionID] = nil
        return true
    }

    /// 挂起（等待确认/提问）：保留运行身份与引擎以支持原地续跑，仅退出流式态
    func suspend(_ run: ChatRunContext) {
        guard isCurrent(run) else { return }
        // 上下文是引用类型，原地挂起时也要通知正在观察会话运行态的列表行。
        withMutation(keyPath: \.runsBySession) {
            run.isStreaming = false
        }
    }

    /// 立即清空指定会话的运行身份（停止 / 删除会话）：不等被取消任务收尾
    func clear(for sessionId: UUID) {
        runsBySession[sessionId] = nil
    }
}

// MARK: - Chat Run Registry（运行注册表）

/// 全局运行注册表：按「运行」登记所有 ChatViewModel 的在跑轮，
/// App 退出时统一做守护移交（写移交文件 + 取消本地任务）。
/// 同一模型可有多个会话同时运行——按 runID 逐轮登记，
/// 避免 A 收尾时把仍在运行的 B 一并除名、漏掉退出移交。
/// 模型弱引用登记，页面销毁自动失联
@MainActor
@Observable
public final class ChatRunRegistry {

    public static let shared = ChatRunRegistry()

    private final class Entry {
        weak var model: ChatViewModel?
        let runID: ChatRunID
        init(model: ChatViewModel, runID: ChatRunID) {
            self.model = model
            self.runID = runID
        }
    }
    @ObservationIgnored private var entries: [Entry] = []
    /// A closing main window may release RootView's model cache. Keep only
    /// models that still own a live run or an uncertain handoff claim.
    @ObservationIgnored private var retainedModels: [ObjectIdentifier: ChatViewModel] = [:]

    private final class ActivityEntry {
        weak var source: (any MenuBarActivitySource)?
        init(_ source: any MenuBarActivitySource) { self.source = source }
    }
    private var activitySources: [ActivityEntry] = []

    init() {}

    /// 与退出移交独立：挂起后仍弱引用活动来源，才能显示非当前会话的待确认状态。
    func registerActivitySource(_ source: any MenuBarActivitySource) {
        activitySources.removeAll { $0.source == nil }
        guard !activitySources.contains(where: { $0.source === source }) else { return }
        activitySources.append(ActivityEntry(source))
    }

    public var menuBarActivity: MenuBarRobotActivity {
        var result = MenuBarRobotActivity()
        for entry in activitySources {
            guard let activity = entry.source?.menuBarActivity else { continue }
            result.isWorking = result.isWorking || activity.isWorking
            result.needsAttention = result.needsAttention || activity.needsAttention
        }
        return result
    }

    /// 某轮开始运行时登记
    func add(_ model: ChatViewModel, runID: ChatRunID) {
        guard !entries.contains(where: { $0.runID == runID }) else { return }
        entries.append(Entry(model: model, runID: runID))
        refreshRetention(for: model)
        entries.removeAll { $0.model == nil }
    }

    /// 某轮结束（完成/挂起/停止/失败）时除名；只移除该轮，其他会话的运行继续保留
    func remove(runID: ChatRunID) {
        let affected = entries.filter { $0.runID == runID }.compactMap(\.model)
        entries.removeAll { $0.runID == runID || $0.model == nil }
        for model in affected { refreshRetention(for: model) }
    }

    private func refreshRetention(for model: ChatViewModel) {
        let key = ObjectIdentifier(model)
        if model.isAnyRunning || model.hasUnhandoffableRunningRuns || model.hasUncertainHandoffClaims {
            retainedModels[key] = model
        } else {
            retainedModels[key] = nil
        }
    }

    /// Include suspended models, which no longer have a streaming registry
    /// entry, so an unsaved confirmation cannot disappear during App exit.
    private var liveModels: [ChatViewModel] {
        // A late cancellation callback can remove the run entry before an
        // uncertain handoff is reconciled. Recheck retained models on every
        // registry read so a resolved claim does not keep the model forever.
        for model in Array(retainedModels.values) {
            refreshRetention(for: model)
        }
        var seen = Set<ObjectIdentifier>()
        let registered = Array(retainedModels.values) + entries.compactMap(\.model)
            + activitySources.compactMap { $0.source as? ChatViewModel }
        return registered.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    public var hasUnhandoffableRunningRuns: Bool {
        liveModels.contains { $0.hasUnhandoffableRunningRuns }
    }

    public var hasUncertainHandoffClaims: Bool {
        liveModels.contains { $0.hasUncertainHandoffClaims }
    }

    public var handoffableRunCount: Int {
        liveModels.reduce(0) { $0 + $1.activeHandoffableRunCount }
    }

    /// 是否存在可移交的运行轮（流式中，非挂起态）
    public var hasActiveRuns: Bool {
        handoffableRunCount > 0
    }

    /// 退出移交：每个在跑且未挂起的轮写移交文件并取消本地任务；返回移交的运行数。
    /// 同一模型可能有多个会话在跑：按模型去重，逐模型移交其全部可移交轮
    @discardableResult
    public func handoffAllAndCancel() -> Int {
        var count = 0
        for model in liveModels {
            count += model.handoffToDaemon()
            refreshRetention(for: model)
        }
        entries.removeAll { $0.model == nil }
        return count
    }
}
