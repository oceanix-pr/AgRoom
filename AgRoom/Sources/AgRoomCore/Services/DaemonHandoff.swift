import Foundation
import Darwin
import CryptoKit

// MARK: - Daemon Run Settings

/// 引擎运行配置快照：App 侧读 UserDefaults 后随移交文件传给守护进程。
/// 守护进程是独立可执行文件，UserDefaults.standard 域与 App 不同，
/// 一切可变配置必须显式携带（不能让守护进程自己读 App 配置）
public struct DaemonRunSettings: Codable, Sendable {
    /// 单次请求补全上限
    public var maxTokens: Int
    /// 采样温度
    public var temperature: Double
    /// 思考力度（nil = standard，不发参数）
    public var reasoningEffortRaw: String?
    /// 单轮工具步数预算
    public var maxSteps: Int
    /// 回复语言指令（如 "Simplified Chinese"；App 侧已解析为最终指令名）
    public var replyLanguageInstruction: String
    /// 人设指令（nil = 无人设）
    public var personaInstruction: String?
    /// 调度 Agent 昵称（nil/空 = 不注入，模型自报 Dispatcher Agent）。
    /// 与 personaInstruction 同理：守护进程的 UserDefaults 域不同，不能自己读 App 配置
    public var dispatcherName: String?
    /// 会话工作区绝对路径（空 = 各空间默认工作区）。
    /// 由会话归属工作区解析而来，决定本轮文件类工具的写入根
    public var workspacePath: String
    public var chatMode: ChatMode
    /// Fresh foreground turns resolve the workflow automatically; handoffs freeze the result.
    public var automaticWorkflow: Bool
    /// 仅对同一规则允许的调用自动放行；Shell 无头硬确认保持有效。
    public var autoReviewEnabled: Bool
    /// 会话权限模式（旧移交文件缺省 = danger-full-access，保持旧行为）。
    public var permissionMode: PermissionMode
    /// 多智体协作开关（旧移交文件缺省关闭：不向模型公布 team_run）。
    public var teamTasksEnabled: Bool
    /// 团队写文件开关（旧移交文件缺省关闭；daemon 无审批人，实际不会启用）。
    public var teamWritesEnabled: Bool
    /// 新任务只有显式继承会话开关才能申请宿主执行。
    public var allowsHostExecution: Bool = false
    public var dataPolicy: TaskDataPolicy = .configuredServices
    /// 只有前台主动移交才填写；旧记录缺失时不能恢复文件写自动批准。
    public var taskAuthorization: TaskExecutionScope? = nil
    public var taskBudget: ExecutionBudgetCheckpoint? = nil
    public var resourceContext: RunResourceContext? = nil
    public var modelParameters: ResolvedModelParameters? = nil

    public init(
        maxTokens: Int,
        temperature: Double,
        reasoningEffortRaw: String?,
        maxSteps: Int,
        replyLanguageInstruction: String,
        personaInstruction: String?,
        dispatcherName: String? = nil,
        workspacePath: String,
        autoReviewEnabled: Bool = false,
        permissionMode: PermissionMode = .workspaceWrite,
        teamTasksEnabled: Bool = false,
        teamWritesEnabled: Bool = false,
        chatMode: ChatMode = .chat,
        automaticWorkflow: Bool = false
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.reasoningEffortRaw = reasoningEffortRaw
        self.maxSteps = maxSteps
        self.replyLanguageInstruction = replyLanguageInstruction
        self.personaInstruction = personaInstruction
        self.dispatcherName = dispatcherName
        self.workspacePath = workspacePath
        self.chatMode = chatMode
        self.automaticWorkflow = automaticWorkflow
        self.autoReviewEnabled = autoReviewEnabled
        self.permissionMode = permissionMode
        self.teamTasksEnabled = teamTasksEnabled
        self.teamWritesEnabled = teamWritesEnabled
    }

    // 旧版移交文件使用相对工作区名（workspaceFolder）；升级后按绝对路径读取，
    // 相对旧值无法解析为工作区目录，忽略并回退默认工作区
    private enum CodingKeys: String, CodingKey {
        case maxTokens, temperature, reasoningEffortRaw, maxSteps
        case replyLanguageInstruction, personaInstruction, dispatcherName
        case workspacePath, chatMode, automaticWorkflow, autoReviewEnabled, permissionMode, teamTasksEnabled, teamWritesEnabled
        case allowsHostExecution, dataPolicy
        case taskAuthorization
        case taskBudget
        case resourceContext, modelParameters
    }

    private enum LegacyKeys: String, CodingKey {
        case workspaceFolder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxTokens = try c.decode(Int.self, forKey: .maxTokens)
        temperature = try c.decode(Double.self, forKey: .temperature)
        reasoningEffortRaw = try c.decodeIfPresent(String.self, forKey: .reasoningEffortRaw)
        maxSteps = try c.decode(Int.self, forKey: .maxSteps)
        replyLanguageInstruction = try c.decode(String.self, forKey: .replyLanguageInstruction)
        personaInstruction = try c.decodeIfPresent(String.self, forKey: .personaInstruction)
        dispatcherName = try c.decodeIfPresent(String.self, forKey: .dispatcherName)
        let legacyContainer = try decoder.container(keyedBy: LegacyKeys.self)
        let legacy = try legacyContainer.decodeIfPresent(String.self, forKey: .workspaceFolder) ?? ""
        workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath)
            ?? (legacy.hasPrefix("/") || legacy.hasPrefix("~") ? legacy : "")
        chatMode = try c.decodeIfPresent(ChatMode.self, forKey: .chatMode) ?? .chat
        automaticWorkflow = try c.decodeIfPresent(Bool.self, forKey: .automaticWorkflow) ?? false
        autoReviewEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoReviewEnabled) ?? false
        permissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
            ?? .dangerFullAccess
        teamTasksEnabled = try c.decodeIfPresent(Bool.self, forKey: .teamTasksEnabled) ?? false
        teamWritesEnabled = try c.decodeIfPresent(Bool.self, forKey: .teamWritesEnabled) ?? false
        allowsHostExecution = try c.decodeIfPresent(Bool.self, forKey: .allowsHostExecution) ?? true
        dataPolicy = try c.decodeIfPresent(TaskDataPolicy.self, forKey: .dataPolicy) ?? .configuredServices
        taskAuthorization = try c.decodeIfPresent(TaskExecutionScope.self, forKey: .taskAuthorization)
        taskBudget = try c.decodeIfPresent(ExecutionBudgetCheckpoint.self, forKey: .taskBudget)
        resourceContext = try c.decodeIfPresent(RunResourceContext.self, forKey: .resourceContext)
        modelParameters = try c.decodeIfPresent(ResolvedModelParameters.self, forKey: .modelParameters)
    }
}

// MARK: - Daemon Handoff

/// 移交任务：App 退出时仍在流式运行的一轮对话。
/// 守护进程按快照续跑工具循环，完成后把结果写回会话库；
/// 若停在确认/提问挂起上，则持久化挂起快照列（App 重启后按既有恢复路径续跑）
public struct DaemonHandoff: Codable, Sendable {
    public let id: UUID
    /// 任务归属空间（空间数据库物理隔离，写回时按此挂库）
    public let space: AppSpace
    public let sessionId: UUID
    public let assistantMessageId: UUID
    public let createdAt: Date
    public let snapshot: EngineRunSnapshot
    public let settings: DaemonRunSettings

    public init(
        id: UUID = UUID(),
        space: AppSpace,
        sessionId: UUID,
        assistantMessageId: UUID,
        createdAt: Date = Date(),
        snapshot: EngineRunSnapshot,
        settings: DaemonRunSettings
    ) {
        self.id = id
        self.space = space
        self.sessionId = sessionId
        self.assistantMessageId = assistantMessageId
        self.createdAt = createdAt
        self.snapshot = snapshot
        self.settings = settings
    }
}

// MARK: - Tool Side Effect Class

/// 工具副作用分类：决定退出移交 / 守护进程恢复时能否重放。
/// 保守默认是「非幂等写」——忘记声明的写类工具不会被自动重放
public enum ToolSideEffectClass: String, Codable, Sendable {
    /// 只读：无外部副作用，可安全重试，不入执行日志
    case readOnly
    /// 幂等写：重复执行结果一致，可重试
    case idempotentWrite
    /// 非幂等写：提醒、通知、Shell、写 SQL、删除、浏览器提交等，绝不自动重放
    case nonIdempotentWrite
}

// MARK: - Operation Journal（副作用执行日志）

/// 非只读工具的执行日志：执行前落 intent，执行后落 receipt（原子替换）。
///
/// 恢复规则：
/// - 有 receipt 且运行/空间/轮次/工具/参数摘要完全匹配：复用结果，不重新执行；
/// - 只有 intent：结果不确定 → 该轮进入 `recoveryRequired`，等用户处置；
/// - 旧摘要或未知版本：保留文件，转人工核实；
/// - 只读工具不入日志，可安全重试。
///
/// 脱敏：只记录 operationID / 工具名 / 参数摘要 / 成败，不写完整参数、文件正文或输出全文
/// （回执截断保存，仅用于恢复去重，不作为展示内容）
///
/// 写入顺序：所有「改内存 → 落盘 → 报成功」都在**同一个专属串行 I/O 队列**上完成。
/// 原实现用 NSLock 只保护内存、编码与替换在锁外，两个并发 persist 可以按相反顺序完成，
/// 旧快照覆盖新快照——已确认成功的操作会从磁盘上消失。落盘失败时内存改动回滚，
/// 保证「返回 true」等价于「磁盘上确实有这条记录」。
///
/// 加载状态：不存在 / 健康 / 旧版 / 未知版本 / 损坏 / 不可读。不可核验状态**不能**被当成空日志——那会让
/// 守护进程误判「没有未决操作」而继续自动执行。这两类保留原文件并拒绝新写入，转人工处置。
public final class OperationJournal: @unchecked Sendable {

    /// 日志加载状态。
    public enum LoadState: Sendable, Equatable {
        /// 尚无日志文件（首次运行）
        case missing
        /// 日志已成功读取
        case healthy
        /// 旧格式不含可核验身份，保留文件供人工恢复。
        case legacy
        case unsupportedVersion(Int)
        case invalidIdentity
        /// 文件存在但无法解码：保留现场，转人工
        case corrupted
        /// 文件存在但读不出来（权限 / IO 错误）
        case unreadable(String)

        /// 是否可用于新的自动化执行；损坏 / 不可读必须转人工处置
        public var isUsable: Bool {
            switch self {
            case .missing, .healthy: return true
            case .legacy, .unsupportedVersion, .invalidIdentity, .corrupted, .unreadable: return false
            }
        }
    }

    public struct Binding: Codable, Sendable, Hashable {
        public let runID: UUID
        public let space: AppSpace

        public init(runID: UUID, space: AppSpace) {
            self.runID = runID
            self.space = space
        }
    }

    public struct CallIdentity: Sendable, Equatable {
        public let binding: Binding
        public let modelStep: Int
        public let toolName: String
        public let argumentDigest: String

        public init(binding: Binding, modelStep: Int, toolName: String, argumentsJSON: String) {
            self.binding = binding
            self.modelStep = modelStep
            self.toolName = toolName
            self.argumentDigest = Self.digest(argumentsJSON)
        }

        private static func digest(_ argumentsJSON: String) -> String {
            "sha256:" + SHA256.hash(data: Data(argumentsJSON.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    public enum CachedOutcome: Sendable, Equatable {
        case missing
        case unresolved
        case identityMismatch
        case saved(result: String, succeeded: Bool)
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let operationID: String
        public let toolName: String
        /// 参数 SHA-256 摘要；旧长度摘要仅供人工核实，不能自动复用。
        public let argumentDigest: String
        public let binding: Binding?
        public let modelStep: Int?
        public var receipt: String?
        public var succeeded: Bool?
        /// 回执是否被截断（恢复去重可接受截断文本，展示方需知道内容不完整）
        public var receiptTruncated: Bool?
        public var evidence: ToolExecutionEvidence?

        func matches(_ identity: CallIdentity) -> Bool {
            binding == identity.binding && modelStep == identity.modelStep
                && toolName == identity.toolName && argumentDigest == identity.argumentDigest
        }
    }

    /// 磁盘格式：带版本号，便于后续演进；读取时兼容旧版（仅 entries 字典）
    private struct Payload: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    /// A Task Center preview may include only a journal whose every entry
    /// carries the requested run and space binding. Malformed and legacy
    /// journals remain available to the recovery workflow, not Finder.
    static func isBoundForInspection(_ data: Data, to binding: Binding) -> Bool {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == currentVersion, !payload.entries.isEmpty else { return false }
        return payload.entries.allSatisfy { key, entry in
            entry.operationID == key && entry.binding == binding && entry.modelStep != nil
        }
    }

    private static let currentVersion = 2
    /// 回执保存上限（恢复去重用，不用于展示）
    private static let receiptLimit = 4096

    private let fileURL: URL
    /// 专属串行 I/O 执行器：把「更新内存 → 持久化 → 确认」排成严格顺序
    private let ioQueue = DispatchQueue(label: "com.agroom.operation-journal.io")
    /// 仅在 ioQueue 上访问；提交成功前不会前进，保证与磁盘一致
    private var entries: [String: Entry] = [:]
    /// Daemon 使用持久的 DaemonRunRecord.id；普通引擎由执行上下文绑定。
    public let explicitBinding: Binding?

    public let loadState: LoadState

    public init(directory: URL, binding: Binding? = nil) {
        self.fileURL = directory.appendingPathComponent("operations.json")
        self.explicitBinding = binding
        let (state, loaded) = Self.load(from: fileURL)
        self.loadState = state
        self.entries = loaded
    }

    /// 读取磁盘状态：区分不存在 / 健康 / 损坏 / 不可读。损坏与不可读都保留原文件。
    private static func load(from url: URL) -> (LoadState, [String: Entry]) {
        let runDirectory = url.deletingLastPathComponent()
        let parent = runDirectory.deletingLastPathComponent()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else {
            var info = stat()
            return lstat(parent.path, &info) != 0 && errno == ENOENT
                ? (.missing, [:]) : (.unreadable("journal parent directory invalid"), [:])
        }
        defer { close(parentFD) }
        let directoryFD = openat(parentFD, runDirectory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            var info = stat()
            return lstat(runDirectory.path, &info) != 0 && errno == ENOENT
                ? (.missing, [:]) : (.unreadable("journal directory invalid"), [:])
        }
        defer { close(directoryFD) }
        let grandparent = parent.deletingLastPathComponent()
        let grandparentFD = open(grandparent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard grandparentFD >= 0 else { return (.unreadable("journal ancestor invalid"), [:]) }
        defer { close(grandparentFD) }
        let rootParentFD = open(grandparent.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootParentFD >= 0 else { return (.unreadable("journal root parent invalid"), [:]) }
        defer { close(rootParentFD) }
        guard DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: rootParentFD, named: grandparent.lastPathComponent,
                childFD: grandparentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: grandparentFD, named: parent.lastPathComponent,
                childFD: parentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: parentFD, named: runDirectory.lastPathComponent,
                childFD: directoryFD) else { return (.unreadable("journal path changed"), [:]) }
        let fileFD = openat(directoryFD, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fileFD >= 0 else {
            return errno == ENOENT ? (.missing, [:]) : (.unreadable("journal file invalid"), [:])
        }
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fileFD, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1 else {
            return (.unreadable("journal file identity invalid"), [:])
        }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            HubLogger.shared.error("Operation journal unreadable: \(HubLogger.safeErrorSummary(error))")
            return (.unreadable("journal read failed"), [:])
        }
        guard DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: rootParentFD, named: grandparent.lastPathComponent,
                childFD: grandparentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: grandparentFD, named: parent.lastPathComponent,
                childFD: parentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: parentFD, named: runDirectory.lastPathComponent,
                childFD: directoryFD) else { return (.unreadable("journal path changed"), [:]) }
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(Payload.self, from: data) {
            guard payload.version == currentVersion else {
                return (payload.version == 1 ? .legacy : .unsupportedVersion(payload.version), payload.entries)
            }
            guard Self.identitiesAreValid(payload.entries) else { return (.invalidIdentity, payload.entries) }
            return (.healthy, payload.entries)
        }
        // 兼容旧版：无版本号，直接是 entries 字典
        if let legacy = try? decoder.decode([String: Entry].self, from: data) {
            return (.legacy, legacy)
        }
        HubLogger.shared.error("Operation journal corrupted; manual recovery required")
        return (.corrupted, [:])
    }

    /// 是否需要人工处置（日志损坏 / 不可读时无法判定未决操作）
    public var requiresManualRecovery: Bool {
        guard loadState.isUsable else { return true }
        return ioQueue.sync {
            !Self.identitiesAreValid(entries)
                || (explicitBinding.map { binding in
                    entries.values.contains { $0.binding != binding }
                } ?? false)
        }
    }

    /// 当前日志的持久身份。未显式绑定的测试/前台引擎从第一条可信 intent 取得。
    public var binding: Binding? {
        explicitBinding ?? ioQueue.sync { entries.values.first?.binding }
    }

    public func acceptsEngine(runID: UUID, space: AppSpace) -> Bool {
        guard !requiresManualRecovery else { return false }
        if let explicitBinding {
            return explicitBinding.runID == runID && explicitBinding.space == space
        }
        guard let existing = binding else { return true }
        return existing.runID == runID && existing.space == space
    }

    private static func identitiesAreValid(_ entries: [String: Entry]) -> Bool {
        let bindings = Set(entries.values.compactMap(\.binding))
        guard bindings.count <= 1 else { return false }
        return entries.allSatisfy { pair in
            let entry = pair.value
            guard pair.key == entry.operationID, entry.binding != nil,
                  let step = entry.modelStep, step >= 0,
                  entry.receipt == nil || entry.succeeded != nil else { return false }
            let digest = entry.argumentDigest
            return digest.hasPrefix("sha256:") && digest.count == 71
                && digest.dropFirst(7).allSatisfy { $0.isHexDigit }
        }
    }

    public var isEmpty: Bool { ioQueue.sync { entries.isEmpty } }

    /// 仅供旧日志兼容夹具构造。无绑定身份的条目一律需人工恢复；
    /// 生产执行路径必须调用带 CallIdentity 的重载。
    ///
    /// **返回是否已成功落盘**：调用方必须先确认 intent 在磁盘上，才能执行有副作用的工具。
    /// 只写内存就执行，进程在工具执行期间退出会留下「做了但无记录」的窗口，恢复时
    /// 既无法判定操作是否已执行，也无法阻止重放。
    @discardableResult
    func recordIntent(operationID: String, toolName: String, argumentDigest: String) -> Bool {
        mutate { entries in
            if let existing = entries[operationID] {
                return existing.toolName == toolName && existing.argumentDigest == argumentDigest
            }
            entries[operationID] = Entry(
                operationID: operationID,
                toolName: toolName,
                argumentDigest: argumentDigest,
                binding: nil,
                modelStep: nil,
                receipt: nil,
                succeeded: nil,
                receiptTruncated: nil
            )
            return true
        }
    }

    /// 引擎的可信写入口：首次落盘时绑定运行、空间、模型轮次、工具和强参数摘要。
    @discardableResult
    public func recordIntent(operationID: String, identity: CallIdentity) -> Bool {
        guard !requiresManualRecovery,
              identity.modelStep >= 0, !operationID.isEmpty, !identity.toolName.isEmpty,
              explicitBinding.map({ $0 == identity.binding }) ?? true else { return false }
        return mutate { entries in
            guard entries[operationID] == nil,
                  entries.values.allSatisfy({ $0.binding == identity.binding }) else { return false }
            entries[operationID] = Entry(
                operationID: operationID,
                toolName: identity.toolName,
                argumentDigest: identity.argumentDigest,
                binding: identity.binding,
                modelStep: identity.modelStep,
                receipt: nil,
                succeeded: nil,
                receiptTruncated: nil
            )
            return true
        }
    }

    /// 记录执行回执（执行之后调用）；返回是否已成功落盘。
    @discardableResult
    public func recordReceipt(operationID: String, result: String, succeeded: Bool, evidence: ToolExecutionEvidence? = nil) -> Bool {
        mutate { entries in
            guard var entry = entries[operationID] else { return false }
            entry.receipt = String(result.prefix(Self.receiptLimit))
            entry.succeeded = succeeded
            entry.receiptTruncated = result.count > Self.receiptLimit
            entry.evidence = evidence
            entries[operationID] = entry
            return true
        }
    }

    /// 已保存的回执（恢复时复用，避免重放副作用）
    public func receipt(operationID: String) -> String? {
        ioQueue.sync { entries[operationID]?.receipt }
    }

    func evidence(operationID: String, identity: CallIdentity) -> ToolExecutionEvidence? {
        ioQueue.sync {
            guard let entry = entries[operationID], entry.matches(identity), entry.receipt != nil else { return nil }
            return entry.evidence
        }
    }

    /// 仅身份完全一致的回执可复用；旧格式与碰撞显式失败关闭。
    public func cachedOutcome(operationID: String, identity: CallIdentity) -> CachedOutcome {
        guard !requiresManualRecovery,
              explicitBinding.map({ $0 == identity.binding }) ?? true else { return .identityMismatch }
        return ioQueue.sync {
            guard let entry = entries[operationID] else { return .missing }
            guard entry.matches(identity) else { return .identityMismatch }
            guard let receipt = entry.receipt, let succeeded = entry.succeeded else { return .unresolved }
            return .saved(result: receipt, succeeded: succeeded)
        }
    }

    /// 是否已有该 operationID 的记录（内存与磁盘一致，落盘成功才算有）
    public func hasPersistedIntent(_ operationID: String) -> Bool {
        ioQueue.sync { entries[operationID] != nil }
    }

    /// 有 intent 无 receipt 的操作：结果不确定，恢复时不得重放
    public func unresolvedEntries() -> [Entry] {
        ioQueue.sync { entries.values.filter { $0.receipt == nil }.sorted { $0.operationID < $1.operationID } }
    }

    public func unresolvedOperationIDs() -> [String] {
        ioQueue.sync {
            entries.values.filter { $0.receipt == nil }.map(\.operationID).sorted()
        }
    }

    public func clear() {
        ioQueue.sync {
            guard loadState.isUsable else { return }
            let runDirectory = fileURL.deletingLastPathComponent()
            let parent = runDirectory.deletingLastPathComponent()
            let grandparentFD = open(parent.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard grandparentFD >= 0 else { return }
            defer { close(grandparentFD) }
            let grandparent = parent.deletingLastPathComponent()
            let rootParentFD = open(grandparent.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootParentFD >= 0 else { return }
            defer { close(rootParentFD) }
            let parentFD = openat(grandparentFD, parent.lastPathComponent,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { return }
            defer { close(parentFD) }
            let directoryFD = openat(parentFD, runDirectory.lastPathComponent,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { return }
            defer { close(directoryFD) }
            guard DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: rootParentFD, named: grandparent.lastPathComponent,
                    childFD: grandparentFD),
                  DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: grandparentFD, named: parent.lastPathComponent, childFD: parentFD),
                  DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: parentFD, named: runDirectory.lastPathComponent,
                    childFD: directoryFD),
                  let present = DaemonDescriptorMutation.exists(in: directoryFD,
                    named: fileURL.lastPathComponent) else { return }
            if present {
                guard DaemonDescriptorMutation.unlinkRegularFile(in: directoryFD,
                    named: fileURL.lastPathComponent) else { return }
            }
            guard DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: rootParentFD, named: grandparent.lastPathComponent,
                    childFD: grandparentFD),
                  DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: grandparentFD, named: parent.lastPathComponent, childFD: parentFD),
                  DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: parentFD, named: runDirectory.lastPathComponent,
                    childFD: directoryFD) else { return }
            entries.removeAll()
        }
    }

    /// 串行化「改内存 → 落盘 → 确认」：落盘失败回滚内存改动并返回 false。
    /// 损坏 / 不可读的日志拒绝任何写入，避免覆盖现场。
    private func mutate(_ body: (inout [String: Entry]) -> Bool) -> Bool {
        guard loadState.isUsable else { return false }
        return ioQueue.sync {
            var candidate = entries
            guard body(&candidate) else { return false }
            if candidate == entries { return true }
            guard persist(candidate) else { return false }
            entries = candidate
            return true
        }
    }

    /// 原子落盘（调用方必须已在 ioQueue 上）；返回是否成功。
    ///
    /// 不再吞掉错误：调用方（工具执行路径）必须知道「副作用日志没写下去」，
    /// 否则会在没有恢复依据的情况下继续执行有副作用的操作。
    private func persist(_ snapshot: [String: Entry]) -> Bool {
        let payload = Payload(version: Self.currentVersion, entries: snapshot)
        guard let data = try? JSONEncoder().encode(payload) else {
            HubLogger.shared.error("Operation journal encode failed")
            return false
        }
        let directory = fileURL.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        let grandparentFD = open(parent.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard grandparentFD >= 0 else { return false }
        defer { close(grandparentFD) }
        let grandparent = parent.deletingLastPathComponent()
        let rootParentFD = open(grandparent.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootParentFD >= 0 else { return false }
        defer { close(rootParentFD) }
        var parentFD = openat(grandparentFD, parent.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var parentCreated = false
        if parentFD < 0 && errno == ENOENT {
            guard mkdirat(grandparentFD, parent.lastPathComponent, 0o700) == 0 else { return false }
            parentCreated = true
            parentFD = openat(grandparentFD, parent.lastPathComponent,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentFD >= 0 else { return false }
        defer { close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0,
              parentInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: rootParentFD, named: grandparent.lastPathComponent,
                childFD: grandparentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: grandparentFD, named: parent.lastPathComponent,
                childFD: parentFD) else { return false }
        if parentCreated {
            guard parentInfo.st_uid == geteuid(), fchmod(parentFD, 0o700) == 0 else { return false }
        }
        let directoryName = directory.lastPathComponent
        guard mkdirat(parentFD, directoryName, 0o700) == 0 || errno == EEXIST else { return false }
        let directoryFD = openat(parentFD, directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(), fchmod(directoryFD, 0o700) == 0,
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: rootParentFD, named: grandparent.lastPathComponent,
                childFD: grandparentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: grandparentFD, named: parent.lastPathComponent,
                childFD: parentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: parentFD, named: directoryName,
                childFD: directoryFD) else { return false }
        let temporaryName = "operations-\(UUID().uuidString).tmp"
        let temporaryFD = openat(directoryFD, temporaryName,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporaryFD >= 0 else { return false }
        defer { unlinkat(directoryFD, temporaryName, 0) }
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(temporaryFD, base.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        guard wrote, fchmod(temporaryFD, 0o600) == 0, fsync(temporaryFD) == 0 else {
            close(temporaryFD)
            return false
        }
        close(temporaryFD)
        guard DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: rootParentFD, named: grandparent.lastPathComponent,
                childFD: grandparentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: grandparentFD, named: parent.lastPathComponent,
                childFD: parentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: parentFD, named: directoryName, childFD: directoryFD),
              renameat(directoryFD, temporaryName, directoryFD, fileURL.lastPathComponent) == 0,
              fsync(directoryFD) == 0,
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: rootParentFD, named: grandparent.lastPathComponent,
                childFD: grandparentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: grandparentFD, named: parent.lastPathComponent,
                childFD: parentFD),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: parentFD, named: directoryName,
                childFD: directoryFD) else {
            HubLogger.shared.error("Operation journal write failed")
            return false
        }
        return true
    }
}

/// Daemon 提交与异常收尾共用的保留凭证判定。任一信号不完整时禁止删除交接记录。
public enum DaemonJournalRecoveryGate {
    public static func requiresManualRecovery(
        journal: OperationJournal,
        engineJournalUnavailable: Bool,
        snapshot: EngineRunSnapshot,
        allowLiveUserAction: Bool = false
    ) -> Bool {
        engineJournalUnavailable || snapshot.journalUnavailable
            || !snapshot.pendingToolCallIds.isEmpty
            || (!allowLiveUserAction && snapshot.requiresManualToolRecovery)
            || journal.requiresManualRecovery
            || !journal.unresolvedOperationIDs().isEmpty
    }
}

// MARK: - Daemon Run State（持久化状态机）

/// 守护进程接管任务的持久化状态。每次变化都原子替换落盘：
/// `pending → running → committing → completed`；与用户交互时停在挂起态；
/// 结果不确定（有 intent 无 receipt）进入 `recoveryRequired`，等用户处置，绝不自动重放
public enum DaemonRunState: Codable, Sendable, Equatable {
    case pending
    case running
    case awaitingConfirmation
    case awaitingInput
    case committing
    case completed
    case recoveryRequired(reason: String)

    /// 是否仍需守护进程动作（completed / recoveryRequired 为终态，不再自动处理）
    public var isActionable: Bool {
        switch self {
        case .completed, .recoveryRequired: return false
        case .pending, .running, .awaitingConfirmation, .awaitingInput, .committing: return true
        }
    }
}

/// 一次接管任务的持久化记录（状态机载体）：状态每次变化整条原子替换
public struct DaemonRunRecord: Codable, Sendable {
    /// Missing in old records = the original, unrestored generation.
    public var restorationToken: String?
    public let id: UUID
    public let space: AppSpace
    public let sessionId: UUID
    public let assistantMessageId: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var state: DaemonRunState
    public var snapshot: EngineRunSnapshot
    public var settings: DaemonRunSettings
    /// committing 阶段的待提交最终正文：进入 committing 前写入。
    /// 崩溃重启后若状态为 `committing` 且有该文本，可直接提交，无需重新请求模型
    /// （重新请求会重新生成模型输出，产生与已执行副作用不一致的第二份结果）
    public var pendingFinalText: String?

    public init(
        id: UUID = UUID(),
        space: AppSpace,
        sessionId: UUID,
        assistantMessageId: UUID,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        state: DaemonRunState = .pending,
        snapshot: EngineRunSnapshot,
        settings: DaemonRunSettings,
        pendingFinalText: String? = nil
    ) {
        self.id = id
        self.space = space
        self.sessionId = sessionId
        self.assistantMessageId = assistantMessageId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.snapshot = snapshot
        self.settings = settings
        self.pendingFinalText = pendingFinalText
    }
}

// MARK: - Daemon Capability Set（守护能力集）

/// 守护进程确实支持的工具能力：无头进程没有浏览器会话、原生小应用预览
/// 或前台媒体授权；排除集合与通用宿主能力描述共用同一事实源。
public enum DaemonCapabilitySet {

    /// 依赖前台 UI 会话或系统授权、无头进程无法可靠执行的能力
    public static let unsupportedToolNames = EngineHostCapabilities.headless.unsupportedToolNames

    /// 是否支持某工具
    public static func supports(_ toolName: String) -> Bool {
        !toolName.hasPrefix("mcp_") && EngineHostCapabilities.headless.supportsTool(named: toolName)
    }

    /// 过滤工具面：仅保留守护进程确实支持的工具
    public static func filter(_ tools: [any DispatcherTool]) -> [any DispatcherTool] {
        tools.filter { supports($0.definition.name) }
    }
}

// MARK: - Daemon Handoff Store

public enum DaemonRecordOrigin: Hashable, Sendable {
    case legacyRoot
    case space(AppSpace)
}

public struct LocatedDaemonRecord: Sendable {
    public let record: DaemonRunRecord
    public let origin: DaemonRecordOrigin

    public init(record: DaemonRunRecord, origin: DaemonRecordOrigin) {
        self.record = record
        self.origin = origin
    }
}

/// File mutations receive already opened, trusted directory descriptors. A
/// later replacement of a space directory cannot redirect these operations
/// into another space. The caller owns and closes every descriptor.
enum DaemonDescriptorMutation {
    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\0")
    }

    static func directoryStillMatchesEntry(parentFD: Int32, named name: String,
                                           childFD: Int32) -> Bool {
        guard safeName(name) else { return false }
        var linked = stat()
        var opened = stat()
        return fstatat(parentFD, name, &linked, AT_SYMLINK_NOFOLLOW) == 0 &&
            fstat(childFD, &opened) == 0 &&
            linked.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) &&
            opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) &&
            linked.st_uid == geteuid() && opened.st_uid == geteuid() &&
            linked.st_dev == opened.st_dev && linked.st_ino == opened.st_ino
    }

    static func regularFileStatus(in directoryFD: Int32, named name: String) -> stat? {
        guard safeName(name) else { return nil }
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1 else { return nil }
        return info
    }

    static func exists(in directoryFD: Int32, named name: String) -> Bool? {
        guard safeName(name) else { return nil }
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        return errno == ENOENT ? false : nil
    }

    static func digest(in directoryFD: Int32, named name: String,
                       maxBytes: Int64 = 64 * 1024 * 1024) -> Data? {
        guard let before = regularFileStatus(in: directoryFD, named: name),
              before.st_size >= 0, before.st_size <= maxBytes else { return nil }
        let fd = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameIdentity(before, opened) else { return nil }
        var hasher = SHA256()
        var bytesRead: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard bytesRead <= maxBytes - Int64(chunk.count) else { return nil }
                bytesRead += Int64(chunk.count)
                hasher.update(data: chunk)
            }
        } catch { return nil }
        var after = stat()
        guard bytesRead == before.st_size,
              fstatat(directoryFD, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              sameVersion(before, after) else { return nil }
        return Data(hasher.finalize())
    }

    static func read(in directoryFD: Int32, named name: String,
                     maxBytes: Int64 = 64 * 1024 * 1024) -> Data? {
        guard let before = regularFileStatus(in: directoryFD, named: name),
              before.st_size >= 0, before.st_size <= maxBytes else { return nil }
        let fd = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameIdentity(before, opened) else { return nil }
        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard data.count <= Int(maxBytes) - chunk.count else { return nil }
                data.append(chunk)
            }
        } catch { return nil }
        guard data.count == Int(before.st_size) else { return nil }
        var after = stat()
        guard fstatat(directoryFD, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              sameVersion(before, after) else { return nil }
        return data
    }

    static func names(in directoryFD: Int32, limit: Int = 100_000) -> [String]? {
        let scanFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scanFD >= 0, let directory = fdopendir(scanFD) else {
            if scanFD >= 0 { close(scanFD) }
            return nil
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? names : nil }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard safeName(name), names.count < limit else { return nil }
            names.append(name)
        }
    }

    static func unlinkRegularFile(in directoryFD: Int32, named name: String,
                                  matching expectedDigest: Data? = nil) -> Bool {
        guard regularFileStatus(in: directoryFD, named: name) != nil else { return false }
        if let expectedDigest, digest(in: directoryFD, named: name) != expectedDigest { return false }
        return unlinkat(directoryFD, name, 0) == 0 && fsync(directoryFD) == 0
    }

    static func moveRegularFile(from sourceFD: Int32, named sourceName: String,
                                to destinationFD: Int32, named destinationName: String,
                                matching expectedDigest: Data) -> Bool {
        guard safeName(destinationName),
              digest(in: sourceFD, named: sourceName) == expectedDigest else { return false }
        guard renameatx_np(sourceFD, sourceName, destinationFD, destinationName,
                           UInt32(RENAME_EXCL)) == 0 else { return false }
        return fsync(sourceFD) == 0 && fsync(destinationFD) == 0
    }

    static func createOnly(_ data: Data, in directoryFD: Int32, named name: String) -> Bool {
        install(data, in: directoryFD, named: name, replacing: false)
    }

    static func replaceAtomically(_ data: Data, in directoryFD: Int32,
                                  named name: String) -> Bool {
        install(data, in: directoryFD, named: name, replacing: true)
    }

    private static func install(_ data: Data, in directoryFD: Int32,
                                named name: String, replacing: Bool) -> Bool {
        guard safeName(name) else { return false }
        if replacing {
            guard let exists = exists(in: directoryFD, named: name),
                  !exists || regularFileStatus(in: directoryFD, named: name) != nil else { return false }
        }
        let temporary = ".pending-\(UUID().uuidString)"
        let fd = openat(directoryFD, temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd); _ = unlinkat(directoryFD, temporary, 0) }
        let wrote = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wrote, fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { return false }
        let installed: Bool
        if replacing {
            installed = renameat(directoryFD, temporary, directoryFD, name) == 0
        } else {
            installed = linkat(directoryFD, temporary, directoryFD, name, 0) == 0
        }
        return installed && fsync(directoryFD) == 0
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
            lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid &&
            lhs.st_nlink == rhs.st_nlink
    }

    private static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

/// 移交文件存取 + 守护进程单例锁。
/// 新记录按空间分区；旧根目录只处理历史记录与全局锁。
public final class DaemonHandoffStore: @unchecked Sendable {

    /// The record body can be quarantined when it is unreadable. Keep its
    /// space/session identity separately so a later App launch still knows
    /// which conversation must wait for manual recovery.
    private struct RecordOwner: Codable {
        let version: Int
        let id: UUID
        let space: AppSpace
        let sessionId: UUID
        let assistantMessageId: UUID
        let taskRunID: UUID?

        init(_ record: DaemonRunRecord) {
            version = 1
            id = record.id
            space = record.space
            sessionId = record.sessionId
            assistantMessageId = record.assistantMessageId
            taskRunID = record.settings.taskAuthorization?.runID
        }

        func matches(_ record: DaemonRunRecord) -> Bool {
            version == 1 && id == record.id && space == record.space &&
                sessionId == record.sessionId && assistantMessageId == record.assistantMessageId &&
                taskRunID == record.settings.taskAuthorization?.runID
        }

        func matches(_ handoff: DaemonHandoff) -> Bool {
            version == 1 && id == handoff.id && space == handoff.space &&
                sessionId == handoff.sessionId && assistantMessageId == handoff.assistantMessageId &&
                taskRunID == handoff.settings.taskAuthorization?.runID
        }
    }

    public enum RecordStatus: Sendable {
        case absent, active, recoveryRequired, completed, uncertain
    }

    public struct OwnershipSnapshot: Sendable {
        /// Process coordination only: no cross-space session identity escapes.
        public let hasActionableRecords: Bool
        public let blockedSessionIdsBySpace: [AppSpace: Set<UUID>]
        public let recoverySessionIds: [AppSpace: Set<UUID>]
        /// A legacy/corrupt record without trusted ownership cannot be mapped
        /// to one space. All new sends must wait for explicit inspection.
        public let hasUnattributedQuarantine: Bool
        public let unattributedSpaces: Set<AppSpace>
        public let ambiguousRunIDsBySpace: [AppSpace: Set<UUID>]
    }

    public struct QuarantinedEvidence: Identifiable, Sendable {
        public let id: String
        public let fileURL: URL
        public let origin: DaemonRecordOrigin
        public let recordID: UUID?
        public let space: AppSpace?
        public let sessionID: UUID?
        public let assistantMessageID: UUID?
        public let taskRunID: UUID?
        /// Binds inspection and manual resolution to the bytes shown by the scan.
        /// The digest itself contains no file content.
        public let sourceDigest: Data?

        init(id: String, fileURL: URL, origin: DaemonRecordOrigin,
             recordID: UUID?, space: AppSpace?, sessionID: UUID?,
             assistantMessageID: UUID?, taskRunID: UUID?,
             sourceDigest: Data? = nil) {
            self.id = id
            self.fileURL = fileURL
            self.origin = origin
            self.recordID = recordID
            self.space = space
            self.sessionID = sessionID
            self.assistantMessageID = assistantMessageID
            self.taskRunID = taskRunID
            self.sourceDigest = sourceDigest
        }
    }

    public static let standard = DaemonHandoffStore()

    public let directory: URL
    private let lockFileName = "daemon.lock"
    private let storeLockFileName = "store.lock"
    private let fileManager = FileManager.default
    private struct RootIdentity {
        let device: dev_t
        let inode: ino_t
    }
    private let rootIdentity: RootIdentity?

    private final class PinnedOrigin {
        let origin: DaemonRecordOrigin
        let rootFD: Int32
        let baseFD: Int32

        init(origin: DaemonRecordOrigin, rootFD: Int32, baseFD: Int32) {
            self.origin = origin
            self.rootFD = rootFD
            self.baseFD = baseFD
        }

        deinit {
            if baseFD != rootFD { close(baseFD) }
            close(rootFD)
        }
    }

    private func openPinnedOrigin(_ origin: DaemonRecordOrigin) -> PinnedOrigin? {
        guard trustedRootStillPresent(requirePrivatePermissions: true), let rootIdentity else { return nil }
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        var root = stat()
        guard fstat(rootFD, &root) == 0,
              root.st_dev == rootIdentity.device, root.st_ino == rootIdentity.inode,
              root.st_uid == geteuid(), root.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              trustedRootStillPresent(requirePrivatePermissions: true) else {
            close(rootFD)
            return nil
        }
        switch origin {
        case .legacyRoot:
            return PinnedOrigin(origin: origin, rootFD: rootFD, baseFD: rootFD)
        case .space(let space):
            let baseFD = openat(rootFD, space.rawValue,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard baseFD >= 0,
                  DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: rootFD, named: space.rawValue, childFD: baseFD) else {
                if baseFD >= 0 { close(baseFD) }
                close(rootFD)
                return nil
            }
            return PinnedOrigin(origin: origin, rootFD: rootFD, baseFD: baseFD)
        }
    }

    private func stillLinked(_ pinned: PinnedOrigin) -> Bool {
        guard trustedRootStillPresent(requirePrivatePermissions: true) else { return false }
        if case .space(let space) = pinned.origin {
            return DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: pinned.rootFD, named: space.rawValue, childFD: pinned.baseFD)
        }
        return true
    }

    private func openChildDirectory(_ name: String, in parentFD: Int32,
                                    create: Bool = false) -> Int32? {
        guard DaemonDescriptorMutation.safeName(name) else { return nil }
        if create, mkdirat(parentFD, name, 0o700) != 0 && errno != EEXIST { return nil }
        let childFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard childFD >= 0 else { return nil }
        guard DaemonDescriptorMutation.directoryStillMatchesEntry(
            parentFD: parentFD, named: name, childFD: childFD) else {
            close(childFD)
            return nil
        }
        return childFD
    }

    private func fileLocation(for url: URL) -> (origin: DaemonRecordOrigin, quarantined: Bool)? {
        let parent = url.deletingLastPathComponent()
        for origin in [DaemonRecordOrigin.legacyRoot] + AppSpace.allCases.map({ .space($0) }) {
            let base = storageDirectory(for: origin)
            if parent == base { return (origin, false) }
            if parent == base.appendingPathComponent("quarantine", isDirectory: true) {
                return (origin, true)
            }
        }
        return nil
    }

    private func names(in origin: DaemonRecordOrigin, quarantine: Bool = false) -> [String]? {
        guard let pinned = openPinnedOrigin(origin), stillLinked(pinned) else { return nil }
        let childFD = quarantine ? openChildDirectory("quarantine", in: pinned.baseFD) : nil
        if quarantine && childFD == nil { return nil }
        defer { if let childFD { close(childFD) } }
        guard let found = DaemonDescriptorMutation.names(in: childFD ?? pinned.baseFD),
              stillLinked(pinned),
              childFD == nil || DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: pinned.baseFD, named: "quarantine", childFD: childFD!) else { return nil }
        return found
    }

    public init(baseDirectory: URL? = nil) {
        let supportDir = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = (baseDirectory ?? supportDir
            .appendingPathComponent("AgRoom", isDirectory: true))
            .appendingPathComponent("daemon", isDirectory: true)
        self.directory = root
        self.rootIdentity = Self.prepareRoot(root)
    }

    private static func prepareRoot(_ root: URL) -> RootIdentity? {
        do {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch { return nil }
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { return nil }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var opened = stat()
        var linked = stat()
        guard fstat(fd, &opened) == 0, lstat(root.path, &linked) == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              opened.st_uid == geteuid(),
              opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
              opened.st_mode & 0o022 == 0 else { return nil }
        if opened.st_mode & 0o200 != 0, fchmod(fd, 0o700) != 0 { return nil }
        return RootIdentity(device: opened.st_dev, inode: opened.st_ino)
    }

    private func trustedRootStillPresent(requirePrivatePermissions: Bool = false) -> Bool {
        guard let rootIdentity else { return false }
        var linked = stat()
        return lstat(directory.path, &linked) == 0 &&
            linked.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) &&
            linked.st_uid == geteuid() &&
            linked.st_dev == rootIdentity.device && linked.st_ino == rootIdentity.inode &&
            linked.st_mode & 0o022 == 0 &&
            (!requirePrivatePermissions || linked.st_mode & 0o777 == 0o700)
    }

    public var lockFileURL: URL { directory.appendingPathComponent(lockFileName) }
    public var storeLockFileURL: URL { directory.appendingPathComponent(storeLockFileName) }

    /// One outermost Store mutation at a time. Callers must use private
    /// unlocked helpers for nested writes rather than acquiring this twice.
    /// The inode is permanent: deleting it would allow split-brain locks.
    private func withStoreMutationLock<Result>(failure: Result,
                                               _ body: () -> Result) -> Result {
        withFileLock(at: storeLockFileURL, nonblocking: false, failure: failure, body)
    }

    /// Manual evidence resolution must exclude a Daemon that may be using the
    /// same files. Always acquire daemon.lock before store.lock, and never
    /// hold either one across a SessionService suspension.
    private func withStoppedDaemon<Result>(failure: Result,
                                           _ body: () -> Result) -> Result {
        withFileLock(at: lockFileURL, nonblocking: true, failure: failure, body)
    }

    private func withFileLock<Result>(at url: URL, nonblocking: Bool,
                                      failure: Result, _ body: () -> Result) -> Result {
            guard url == lockFileURL || url == storeLockFileURL,
                  let pinned = openPinnedOrigin(.legacyRoot), stillLinked(pinned) else {
                HubLogger.shared.error("Daemon storage root invalid")
                return failure
            }
            let name = url.lastPathComponent
            let fd = openat(pinned.baseFD, name,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else {
                HubLogger.shared.error("Daemon coordination lock unavailable")
                return failure
            }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0,
                  opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  opened.st_uid == geteuid(), opened.st_nlink == 1 else {
                HubLogger.shared.error("Daemon coordination lock inode invalid")
                return failure
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let failureCode = errno
                if !nonblocking && DispatchTime.now().uptimeNanoseconds < deadline &&
                    (failureCode == EWOULDBLOCK || failureCode == EINTR) {
                    usleep(20_000)
                    continue
                }
                HubLogger.shared.error("Daemon coordination lock acquisition failed")
                return failure
            }
            defer { flock(fd, LOCK_UN) }
            var linked = stat()
            guard fstatat(pinned.baseFD, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  linked.st_dev == opened.st_dev, linked.st_ino == opened.st_ino,
                  linked.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  fchmod(fd, 0o600) == 0,
                  stillLinked(pinned) else {
                HubLogger.shared.error("Daemon coordination lock path changed or permissions failed")
                return failure
            }
            return body()
    }

    // MARK: - Handoff Files

    /// 写入移交文件；返回文件 URL（失败返回 nil——App 侧据此放弃移交改为原样中止）
    @discardableResult
    public func write(_ handoff: DaemonHandoff) -> URL? {
        withStoreMutationLock(failure: nil as URL?) {
            let url = directory.appendingPathComponent("handoff-\(handoff.id.uuidString).json")
            guard let pinned = openPinnedOrigin(.legacyRoot),
                  let data = try? JSONEncoder().encode(handoff),
                  DaemonDescriptorMutation.replaceAtomically(data, in: pinned.baseFD,
                    named: url.lastPathComponent), stillLinked(pinned) else {
                HubLogger.shared.error("Daemon handoff write failed")
                return nil
            }
            return url
        }
    }

    /// 待接管任务列表（按创建时间先后）
    private func pendingHandoffs() -> [DaemonHandoff] {
        guard let pinned = openPinnedOrigin(.legacyRoot), stillLinked(pinned),
              let files = DaemonDescriptorMutation.names(in: pinned.baseFD) else { return [] }
        let decoder = JSONDecoder()
        let results: [DaemonHandoff] = files
            .filter { $0.hasPrefix("handoff-") && $0.hasSuffix(".json") }
            .compactMap { name -> DaemonHandoff? in
                guard let data = DaemonDescriptorMutation.read(in: pinned.baseFD, named: name),
                      let handoff = try? decoder.decode(DaemonHandoff.self, from: data),
                      name == "handoff-\(handoff.id.uuidString).json" else {
                    // Read-only scan: ownershipSnapshot will find the original
                    // malformed file and fail closed without moving evidence.
                    return nil
                }
                let ownerName = "owner-\(handoff.id.uuidString).json"
                guard let hasOwner = DaemonDescriptorMutation.exists(in: pinned.baseFD,
                    named: ownerName) else { return nil }
                if hasOwner, owner(id: handoff.id, baseFD: pinned.baseFD)?.matches(handoff) != true {
                    return nil
                }
                return handoff
            }
            .sorted { $0.createdAt < $1.createdAt }
        return stillLinked(pinned) ? results : []
    }

    /// 完成接管后删除移交文件
    @discardableResult
    public func remove(id: UUID) -> Bool {
        withStoreMutationLock(failure: false) {
            guard let pinned = openPinnedOrigin(.legacyRoot), stillLinked(pinned) else { return false }
            let name = "handoff-\(id.uuidString).json"
            guard let present = DaemonDescriptorMutation.exists(in: pinned.baseFD,
                named: name) else { return false }
            if !present { return true }
            guard DaemonDescriptorMutation.unlinkRegularFile(in: pinned.baseFD,
                named: name), stillLinked(pinned) else {
                HubLogger.shared.error("Daemon legacy handoff removal failed")
                return false
            }
            return true
        }
    }

    // MARK: - Run Records（持久化状态机）

    private func storageDirectory(for origin: DaemonRecordOrigin) -> URL {
        switch origin {
        case .legacyRoot: return directory
        case .space(let space):
            // The path segment comes only from the fixed AppSpace enum.
            return directory.appendingPathComponent(space.rawValue, isDirectory: true)
        }
    }

    private func ensureStorageDirectory(for origin: DaemonRecordOrigin) -> Bool {
        guard let root = openPinnedOrigin(.legacyRoot), stillLinked(root) else { return false }
        guard case .space(let space) = origin else { return true }
        if mkdirat(root.baseFD, space.rawValue, 0o700) != 0 && errno != EEXIST { return false }
        guard let spaceFD = openChildDirectory(space.rawValue, in: root.baseFD) else { return false }
        defer { close(spaceFD) }
        var info = stat()
        guard fstat(spaceFD, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), fchmod(spaceFD, 0o700) == 0,
              stillLinked(root),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: root.baseFD, named: space.rawValue, childFD: spaceFD) else { return false }
        return true
    }

    private enum SpaceDirectoryState { case absent, trusted, invalid }

    private func spaceDirectoryState(_ space: AppSpace) -> SpaceDirectoryState {
        guard let root = openPinnedOrigin(.legacyRoot), stillLinked(root),
              let present = DaemonDescriptorMutation.exists(in: root.baseFD,
                named: space.rawValue) else { return .invalid }
        guard present else { return .absent }
        guard let fd = openChildDirectory(space.rawValue, in: root.baseFD) else { return .invalid }
        defer { close(fd) }
        return stillLinked(root) ? .trusted : .invalid
    }

    private func quarantineDirectoryState(for origin: DaemonRecordOrigin) -> SpaceDirectoryState {
        guard let pinned = openPinnedOrigin(origin), stillLinked(pinned),
              let present = DaemonDescriptorMutation.exists(in: pinned.baseFD,
                named: "quarantine") else { return .invalid }
        guard present else { return .absent }
        guard let fd = openChildDirectory("quarantine", in: pinned.baseFD) else { return .invalid }
        defer { close(fd) }
        return stillLinked(pinned) ? .trusted : .invalid
    }

    /// 记录文件 URL（`run-<uuid>.json`；状态每次变化整条原子替换）
    func recordFileURL(id: UUID, origin: DaemonRecordOrigin = .legacyRoot) -> URL {
        storageDirectory(for: origin).appendingPathComponent("run-\(id.uuidString).json")
    }

    private func ownerFileURL(id: UUID, origin: DaemonRecordOrigin = .legacyRoot) -> URL {
        storageDirectory(for: origin).appendingPathComponent("owner-\(id.uuidString).json")
    }

    private func readRegularFile(at url: URL) -> Data? {
        guard let location = fileLocation(for: url),
              let pinned = openPinnedOrigin(location.origin), stillLinked(pinned) else { return nil }
        let childFD = location.quarantined
            ? openChildDirectory("quarantine", in: pinned.baseFD) : nil
        if location.quarantined && childFD == nil { return nil }
        defer { if let childFD { close(childFD) } }
        guard let data = DaemonDescriptorMutation.read(
            in: childFD ?? pinned.baseFD, named: url.lastPathComponent),
            stillLinked(pinned),
            childFD == nil || DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: pinned.baseFD, named: "quarantine", childFD: childFD!) else { return nil }
        return data
    }

    private func owner(id: UUID, origin: DaemonRecordOrigin = .legacyRoot) -> RecordOwner? {
        guard let data = readRegularFile(at: ownerFileURL(id: id, origin: origin)) else { return nil }
        return try? JSONDecoder().decode(RecordOwner.self, from: data)
    }

    private func trustedBody(at url: URL, origin: DaemonRecordOrigin) -> Bool {
        guard let location = fileLocation(for: url), location.origin == origin,
              !location.quarantined, let pinned = openPinnedOrigin(origin),
              stillLinked(pinned) else { return false }
        return trustedBody(named: url.lastPathComponent, baseFD: pinned.baseFD,
            origin: origin) && stillLinked(pinned)
    }

    private func trustedOwner(id: UUID, origin: DaemonRecordOrigin) -> Bool {
        guard let pinned = openPinnedOrigin(origin), stillLinked(pinned) else { return false }
        return trustedOwner(id: id, baseFD: pinned.baseFD, origin: origin) &&
            stillLinked(pinned)
    }

    private func ensureOwner(for record: DaemonRunRecord, in pinned: PinnedOrigin) -> Bool {
        let name = "owner-\(record.id.uuidString).json"
        guard let present = DaemonDescriptorMutation.exists(in: pinned.baseFD,
            named: name) else { return false }
        if present {
            guard let data = DaemonDescriptorMutation.read(in: pinned.baseFD, named: name),
                  let owner = try? JSONDecoder().decode(RecordOwner.self, from: data),
                  owner.matches(record), stillLinked(pinned) else {
                HubLogger.shared.error("Daemon run owner identity mismatch")
                return false
            }
            return true
        }
        guard let data = try? JSONEncoder().encode(RecordOwner(record)),
              stillLinked(pinned),
              DaemonDescriptorMutation.createOnly(data, in: pinned.baseFD, named: name),
              stillLinked(pinned) else {
            HubLogger.shared.error("Daemon run owner write failed")
            return false
        }
        return true
    }

    /// Pure path lookup. The journal writer creates its directory only while
    /// the Daemon owns daemon.lock; a Task Center read must not create it.
    public func runDirectory(id: UUID, origin: DaemonRecordOrigin) -> URL {
        storageDirectory(for: origin).appendingPathComponent("run-\(id.uuidString)", isDirectory: true)
    }

    /// 写入/更新任务记录（整条原子替换）
    @discardableResult
    public func writeRecord(_ record: DaemonRunRecord) -> Bool {
        writeRecord(record, origin: .space(record.space))
    }

    /// App 首次移交只能创建新身份，不能覆盖 Daemon 已推进的同 ID 记录。
    /// 先写私有临时文件，再以 link(2) 原子地安装目标；目标已存在时失败。
    @discardableResult
    public func createHandoffRecord(_ record: DaemonRunRecord) -> Bool {
        withStoreMutationLock(failure: false) { createHandoffRecordUnlocked(record) }
    }

    private func createHandoffRecordUnlocked(_ record: DaemonRunRecord) -> Bool {
        let origin = DaemonRecordOrigin.space(record.space)
        guard ensureStorageDirectory(for: origin),
              case .absent = recordStatus(id: record.id, origin: origin),
              let pinned = openPinnedOrigin(origin) else { return false }
        // Include both old run- and handoff- records; the latter were written
        // before owner sidecars existed. A same-ID record in the other space
        // remains independent.
        let ownership = ownershipSnapshot()
        guard !ownership.hasUnattributedQuarantine,
              !ownership.unattributedSpaces.contains(record.space),
              ownership.ambiguousRunIDsBySpace[record.space]?.contains(record.id) != true,
              !rawLocatedRecords().contains(where: {
                  $0.record.id == record.id && $0.record.space == record.space
              }) else { return false }
        guard let ownerData = try? JSONEncoder().encode(RecordOwner(record)),
              stillLinked(pinned),
              DaemonDescriptorMutation.createOnly(ownerData, in: pinned.baseFD,
                named: "owner-\(record.id.uuidString).json"),
              let recordData = try? JSONEncoder().encode(record),
              stillLinked(pinned),
              DaemonDescriptorMutation.createOnly(recordData, in: pinned.baseFD,
                named: "run-\(record.id.uuidString).json"),
              stillLinked(pinned) else {
            return false
        }
        return true
    }

    @discardableResult
    public func writeRecord(_ record: DaemonRunRecord, origin: DaemonRecordOrigin) -> Bool {
        withStoreMutationLock(failure: false) { writeRecordUnlocked(record, origin: origin) }
    }

    private func writeRecordUnlocked(_ record: DaemonRunRecord, origin: DaemonRecordOrigin) -> Bool {
        if case .space(let space) = origin, space != record.space { return false }
        if origin == .legacyRoot {
            // The shared root is migration-only. It may advance an existing
            // legacy run/handoff, but must never accept a newly created run.
            let existing = rawLocatedRecords().filter {
                $0.origin == .legacyRoot && $0.record.id == record.id &&
                    $0.record.space == record.space && $0.record.sessionId == record.sessionId &&
                    $0.record.assistantMessageId == record.assistantMessageId
            }
            guard existing.count == 1 else { return false }
        }
        guard ensureStorageDirectory(for: origin),
              let pinned = openPinnedOrigin(origin), stillLinked(pinned),
              ensureOwner(for: record, in: pinned),
              let data = try? JSONEncoder().encode(record),
              DaemonDescriptorMutation.replaceAtomically(data, in: pinned.baseFD,
                named: "run-\(record.id.uuidString).json"), stillLinked(pinned) else {
            HubLogger.shared.error("Daemon run record write failed")
            return false
        }
        if origin == .legacyRoot {
            // Advance the old handoff only after the new body is durable.
            // An identity change leaves both sources for manual review.
            let handoffName = "handoff-\(record.id.uuidString).json"
            guard let present = DaemonDescriptorMutation.exists(in: pinned.baseFD,
                named: handoffName) else { return false }
            if present {
                guard let oldData = DaemonDescriptorMutation.read(in: pinned.baseFD,
                        named: handoffName),
                      let handoff = try? JSONDecoder().decode(DaemonHandoff.self, from: oldData),
                      handoff.id == record.id, handoff.space == record.space,
                      handoff.sessionId == record.sessionId,
                      handoff.assistantMessageId == record.assistantMessageId,
                      stillLinked(pinned),
                      DaemonDescriptorMutation.unlinkRegularFile(in: pinned.baseFD,
                        named: handoffName, matching: Data(SHA256.hash(data: oldData))) else { return false }
            }
        }
        return stillLinked(pinned)
    }

    public enum RecordPresence: Sendable {
        case absent, valid, uncertain
    }

    /// A failed atomic write may still have completed its rename. Only a
    /// successful directory listing can prove absence; unreadable or malformed
    /// records must never release the App's execution claim.
    public func recordPresence(id: UUID, origin: DaemonRecordOrigin) -> RecordPresence {
        switch recordStatus(id: id, origin: origin) {
        case .absent: return .absent
        case .uncertain: return .uncertain
        case .active, .recoveryRequired, .completed: return .valid
        }
    }

    /// A failed write is a proven success only when the durable record is the
    /// exact snapshot claimed by this App run. A same-ID foreign record, an
    /// advanced generation, or duplicate legacy evidence is uncertain.
    public func recordPresence(matching expected: DaemonRunRecord,
                               origin: DaemonRecordOrigin) -> RecordPresence {
        let status = recordPresence(id: expected.id, origin: origin)
        guard case .valid = status else { return status }
        let matches = locatedRecords().filter {
            $0.record.id == expected.id && $0.origin == origin
        }
        guard matches.count == 1 else { return .uncertain }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let actual = try? encoder.encode(matches[0].record),
              let wanted = try? encoder.encode(expected),
              actual == wanted else { return .uncertain }
        return .valid
    }

    func recordPresence(id: UUID) -> RecordPresence {
        switch recordStatus(id: id) {
        case .absent: return .absent
        case .uncertain: return .uncertain
        case .active, .recoveryRequired, .completed: return .valid
        }
    }

    /// A quarantined run remains uncertain even after the located-record scan moved its
    /// malformed JSON out of the active queue. A completed recovery record,
    /// including one explicitly abandoned by the user, no longer owns execution.
    public func recordStatus(id: UUID, origin: DaemonRecordOrigin) -> RecordStatus {
        guard trustedRootStillPresent() else { return .uncertain }
        if case .space(let space) = origin {
            switch spaceDirectoryState(space) {
            case .absent: return .absent
            case .invalid: return .uncertain
            case .trusted: break
            }
        }
        let base = storageDirectory(for: origin)
        let name = recordFileURL(id: id, origin: origin).lastPathComponent
        let legacyHandoffName = "handoff-\(id.uuidString).json"
        let ownerName = "owner-\(id.uuidString).json"
        guard let names = names(in: origin) else { return .uncertain }
        if names.contains("quarantine") {
            guard let quarantined = self.names(in: origin, quarantine: true) else { return .uncertain }
            if quarantined.contains(where: { $0.hasSuffix("-\(name)") ||
                (origin == .legacyRoot && $0.hasSuffix("-\(legacyHandoffName)")) ||
                $0.hasSuffix("-owner-\(id.uuidString).json") }) { return .uncertain }
        }
        if origin == .legacyRoot, names.contains(legacyHandoffName) {
            guard !names.contains(name),
                  let data = readRegularFile(at: base.appendingPathComponent(legacyHandoffName)),
                  let handoff = try? JSONDecoder().decode(DaemonHandoff.self, from: data),
                  handoff.id == id else { return .uncertain }
            if names.contains(ownerName),
               owner(id: id, origin: origin)?.matches(handoff) != true { return .uncertain }
            return .active
        }
        guard names.contains(name) else {
            return names.contains(ownerName) ? .uncertain : .absent
        }
        guard let data = readRegularFile(at: recordFileURL(id: id, origin: origin)) else { return .uncertain }
        guard let record = try? JSONDecoder().decode(DaemonRunRecord.self, from: data),
              record.id == id else { return .uncertain }
        if case .space(let space) = origin, record.space != space { return .uncertain }
        if names.contains(ownerName),
           owner(id: id, origin: origin)?.matches(record) != true { return .uncertain }
        if case .space = origin,
           !names.contains(ownerName) { return .uncertain }
        switch record.state {
        case .completed: return .completed
        case .recoveryRequired: return .recoveryRequired
        default: return .active
        }
    }

    func recordStatus(id: UUID) -> RecordStatus {
        let statuses = ([DaemonRecordOrigin.legacyRoot] + AppSpace.allCases.map { .space($0) })
            .map { recordStatus(id: id, origin: $0) }
            .filter { if case .absent = $0 { return false }; return true }
        guard statuses.count == 1 else { return statuses.isEmpty ? .absent : .uncertain }
        return statuses[0]
    }

    /// One scan for App ownership and Supervisor polling. Quarantined records
    /// never become executable again; their owner sidecars retain the session
    /// lock across launches. Unknown legacy evidence closes new sends globally.
    public func ownershipSnapshot() -> OwnershipSnapshot {
        guard trustedRootStillPresent() else {
            return OwnershipSnapshot(hasActionableRecords: false,
                blockedSessionIdsBySpace: [:], recoverySessionIds: [:],
                hasUnattributedQuarantine: true, unattributedSpaces: [],
                ambiguousRunIDsBySpace: [:])
        }
        let raw = rawLocatedRecords()
        var hasActionable = false
        var blockedBySpace: [AppSpace: Set<UUID>] = [:]
        var recoveries: [AppSpace: Set<UUID>] = [:]
        var unattributed = false
        var unattributedSpaces = Set<AppSpace>()
        var ambiguousRunIDsBySpace: [AppSpace: Set<UUID>] = [:]
        func markUnknown(_ origin: DaemonRecordOrigin) {
            switch origin {
            case .legacyRoot: unattributed = true
            case .space(let space): unattributedSpaces.insert(space)
            }
        }
        func block(_ space: AppSpace, _ sessionID: UUID) {
            blockedBySpace[space, default: []].insert(sessionID)
            recoveries[space, default: []].insert(sessionID)
        }
        let grouped = Dictionary(grouping: raw, by: { SpaceRunKey(space: $0.record.space, id: $0.record.id) })
        for (key, copies) in grouped {
            if copies.count > 1 {
                ambiguousRunIDsBySpace[key.space, default: []].insert(key.id)
                for copy in copies { block(copy.record.space, copy.record.sessionId) }
                continue
            }
            guard let record = copies.first?.record else { continue }
            switch record.state {
            case .completed: break
            case .recoveryRequired: block(record.space, record.sessionId)
            default:
                blockedBySpace[record.space, default: []].insert(record.sessionId)
            }
        }
        if names(in: .legacyRoot) != nil {
            for origin in [DaemonRecordOrigin.legacyRoot] + AppSpace.allCases.map({ .space($0) }) {
                if case .space(let space) = origin {
                    switch spaceDirectoryState(space) {
                    case .absent: continue
                    case .invalid:
                        unattributed = true
                        unattributedSpaces.insert(space)
                        continue
                    case .trusted: break
                    }
                }
                let base = storageDirectory(for: origin)
                if let names = names(in: origin) {
                    func inspect(_ name: String, at url: URL) {
                        let stem = String(name.dropLast(5))
                        guard let id = UUID(uuidString: String(stem.suffix(36))) else {
                            markUnknown(origin)
                            return
                        }
                        let data = readRegularFile(at: url)
                        let decodedRun = name.contains("run-")
                            ? data.flatMap { try? JSONDecoder().decode(DaemonRunRecord.self, from: $0) } : nil
                        let decodedHandoff = name.contains("handoff-")
                            ? data.flatMap { try? JSONDecoder().decode(DaemonHandoff.self, from: $0) } : nil
                        let bodySpace = decodedRun?.space ?? decodedHandoff?.space
                        let bodySession = decodedRun?.sessionId ?? decodedHandoff?.sessionId
                        let candidateOwner = owner(id: id, origin: origin)
                        let identity = candidateOwner?.version == 1 && candidateOwner?.id == id
                            ? candidateOwner : nil
                        if case .space(let pathSpace) = origin,
                           (bodySpace.map { $0 != pathSpace } == true ||
                            identity.map { $0.space != pathSpace } == true) {
                            // A body or sidecar claiming the other space must
                            // synchronously block both spaces, even when the
                            // other directory is not part of a scoped read.
                            unattributed = true
                            ambiguousRunIDsBySpace[pathSpace, default: []].insert(id)
                            if let bodySpace, let bodySession {
                                ambiguousRunIDsBySpace[bodySpace, default: []].insert(id)
                                block(bodySpace, bodySession)
                            }
                            if let identity {
                                ambiguousRunIDsBySpace[identity.space, default: []].insert(id)
                                block(identity.space, identity.sessionId)
                            }
                            return
                        }
                        guard let identity else {
                            if case .space(let space) = origin {
                                ambiguousRunIDsBySpace[space, default: []].insert(id)
                            }
                            markUnknown(origin)
                            return
                        }
                        if (decodedHandoff.map { !identity.matches($0) } == true) ||
                           (decodedRun.map { !identity.matches($0) } == true) {
                            unattributed = true
                            ambiguousRunIDsBySpace[identity.space, default: []].insert(id)
                            block(identity.space, identity.sessionId)
                            if let bodySpace, let bodySession {
                                ambiguousRunIDsBySpace[bodySpace, default: []].insert(id)
                                block(bodySpace, bodySession)
                            }
                            return
                        }
                        ambiguousRunIDsBySpace[identity.space, default: []].insert(id)
                        block(identity.space, identity.sessionId)
                    }
                    // A failed quarantine move leaves malformed evidence here.
                    for name in names where name.hasSuffix(".json") &&
                        (name.hasPrefix("run-") || name.hasPrefix("handoff-")) {
                        if trustedBody(at: base.appendingPathComponent(name), origin: origin) { continue }
                        inspect(name, at: base.appendingPathComponent(name))
                    }
                    // Owner-only after a failed body write is not an empty run.
                    for name in names where name.hasPrefix("owner-") && name.hasSuffix(".json") {
                        let id = UUID(uuidString: String(name.dropLast(5).suffix(36)))
                        if let id, trustedOwner(id: id, origin: origin) { continue }
                        inspect(name, at: base.appendingPathComponent(name))
                    }
                    if names.contains("quarantine") {
                        guard case .trusted = quarantineDirectoryState(for: origin) else {
                            unattributed = true
                            markUnknown(origin)
                            continue
                        }
                        guard let evidence = self.names(in: origin, quarantine: true) else {
                            unattributed = true
                            markUnknown(origin)
                            continue
                        }
                        for name in evidence where name.hasSuffix(".json") &&
                            (name.contains("-run-") || name.contains("-handoff-") || name.contains("-owner-")) {
                            inspect(name, at: base.appendingPathComponent("quarantine", isDirectory: true)
                                .appendingPathComponent(name))
                        }
                    }
                } else {
                    markUnknown(origin)
                }
            }
        } else {
            unattributed = true
        }
        hasActionable = raw.contains { located in
            grouped[SpaceRunKey(space: located.record.space, id: located.record.id)]?.count == 1 &&
                ambiguousRunIDsBySpace[located.record.space]?.contains(located.record.id) != true &&
                !unattributed && !unattributedSpaces.contains(located.record.space) &&
                located.record.state.isActionable
        }
        return OwnershipSnapshot(hasActionableRecords: hasActionable,
            blockedSessionIdsBySpace: blockedBySpace,
            recoverySessionIds: recoveries,
            hasUnattributedQuarantine: unattributed,
            unattributedSpaces: unattributedSpaces,
            ambiguousRunIDsBySpace: ambiguousRunIDsBySpace)
    }

    /// Only malformed active files and preserved quarantine files appear here.
    /// The returned path is for opening the evidence, never for automatic replay.
    func quarantinedEvidence() -> [QuarantinedEvidence] {
        quarantinedEvidence(origins: [DaemonRecordOrigin.legacyRoot] + AppSpace.allCases.map { .space($0) })
    }

    private func owner(id: UUID, baseFD: Int32) -> RecordOwner? {
        guard let data = DaemonDescriptorMutation.read(in: baseFD,
            named: "owner-\(id.uuidString).json") else { return nil }
        return try? JSONDecoder().decode(RecordOwner.self, from: data)
    }

    private func trustedBody(named name: String, baseFD: Int32,
                             origin: DaemonRecordOrigin) -> Bool {
        guard let data = DaemonDescriptorMutation.read(in: baseFD, named: name) else { return false }
        if name.hasPrefix("handoff-") {
            guard origin == .legacyRoot,
                  let handoff = try? JSONDecoder().decode(DaemonHandoff.self, from: data),
                  name == "handoff-\(handoff.id.uuidString).json" else { return false }
            let ownerName = "owner-\(handoff.id.uuidString).json"
            guard let hasOwner = DaemonDescriptorMutation.exists(in: baseFD, named: ownerName) else { return false }
            return !hasOwner || owner(id: handoff.id, baseFD: baseFD)?.matches(handoff) == true
        }
        guard let record = try? JSONDecoder().decode(DaemonRunRecord.self, from: data),
              name == "run-\(record.id.uuidString).json",
              origin == .legacyRoot || origin == .space(record.space) else { return false }
        let ownerName = "owner-\(record.id.uuidString).json"
        guard let hasOwner = DaemonDescriptorMutation.exists(in: baseFD, named: ownerName) else { return false }
        return hasOwner ? owner(id: record.id, baseFD: baseFD)?.matches(record) == true :
            origin == .legacyRoot
    }

    private func trustedOwner(id: UUID, baseFD: Int32,
                              origin: DaemonRecordOrigin) -> Bool {
        let bodyName = "run-\(id.uuidString).json"
        guard trustedBody(named: bodyName, baseFD: baseFD, origin: origin),
              let data = DaemonDescriptorMutation.read(in: baseFD, named: bodyName),
              let record = try? JSONDecoder().decode(DaemonRunRecord.self, from: data) else { return false }
        return owner(id: id, baseFD: baseFD)?.matches(record) == true
    }

    private func quarantinedEvidence(origins: [DaemonRecordOrigin]) -> [QuarantinedEvidence] {
        guard trustedRootStillPresent() else { return [] }
        var result: [QuarantinedEvidence] = []
        for origin in origins {
            guard let pinned = openPinnedOrigin(origin), stillLinked(pinned),
                  let names = DaemonDescriptorMutation.names(in: pinned.baseFD) else { continue }
            let base = storageDirectory(for: origin)
            var files: [(name: String, quarantined: Bool)] = []
            for name in names where name.hasSuffix(".json") &&
                (name.hasPrefix("run-") || name.hasPrefix("handoff-") || name.hasPrefix("owner-")) {
                let id = UUID(uuidString: String(name.dropLast(5).suffix(36)))
                if name.hasPrefix("owner-") {
                    if let id, trustedOwner(id: id, baseFD: pinned.baseFD, origin: origin) { continue }
                } else if trustedBody(named: name, baseFD: pinned.baseFD, origin: origin) {
                    continue
                }
                files.append((name, false))
            }
            let quarantineFD: Int32?
            if names.contains("quarantine") {
                quarantineFD = openChildDirectory("quarantine", in: pinned.baseFD)
                guard let quarantineFD, let evidenceNames = DaemonDescriptorMutation.names(in: quarantineFD) else {
                    if let quarantineFD { close(quarantineFD) }
                    continue
                }
                for name in evidenceNames where name.hasSuffix(".json") &&
                    (name.contains("-run-") || name.contains("-handoff-") || name.contains("-owner-")) {
                    files.append((name, true))
                }
            } else {
                quarantineFD = nil
            }
            defer { if let quarantineFD { close(quarantineFD) } }
            var scoped: [QuarantinedEvidence] = []
            for file in files {
                let sourceFD = file.quarantined ? quarantineFD : pinned.baseFD
                guard let sourceFD,
                      let sourceDigest = DaemonDescriptorMutation.digest(
                        in: sourceFD, named: file.name) else { continue }
                let stem = String(file.name.dropLast(5))
                let id = UUID(uuidString: String(stem.suffix(36)))
                let identity = id.flatMap { owner(id: $0, baseFD: pinned.baseFD) }
                let data = DaemonDescriptorMutation.read(in: sourceFD, named: file.name)
                let bodyMatchesOwner: Bool
                if let identity, let data, file.name.contains("handoff-"),
                   let handoff = try? JSONDecoder().decode(DaemonHandoff.self, from: data) {
                    bodyMatchesOwner = identity.matches(handoff)
                } else if let identity, let data, file.name.contains("run-"),
                          let record = try? JSONDecoder().decode(DaemonRunRecord.self, from: data) {
                    bodyMatchesOwner = identity.matches(record)
                } else {
                    // A truncated body may still have a trustworthy owner sidecar.
                    bodyMatchesOwner = true
                }
                let trusted: RecordOwner?
                if let identity, identity.version == 1, identity.id == id,
                   bodyMatchesOwner,
                   origin == .legacyRoot || origin == .space(identity.space) {
                    trusted = identity
                } else { trusted = nil }
                let url = file.quarantined ? base.appendingPathComponent("quarantine", isDirectory: true)
                    .appendingPathComponent(file.name) : base.appendingPathComponent(file.name)
                scoped.append(QuarantinedEvidence(id: url.path, fileURL: url, origin: origin,
                    recordID: id, space: trusted?.space, sessionID: trusted?.sessionId,
                    assistantMessageID: trusted?.assistantMessageId, taskRunID: trusted?.taskRunID,
                    sourceDigest: sourceDigest))
            }
            guard stillLinked(pinned), quarantineFD == nil ||
                DaemonDescriptorMutation.directoryStillMatchesEntry(parentFD: pinned.baseFD,
                    named: "quarantine", childFD: quarantineFD!) else { continue }
            result.append(contentsOf: scoped)
        }
        return result.sorted { $0.id < $1.id }
    }

    public func quarantinedEvidence(in space: AppSpace) -> [QuarantinedEvidence] {
        quarantinedEvidence(origins: [.legacyRoot, .space(space)]).filter { $0.space == space }
    }

    public func unattributedEvidence(in space: AppSpace) -> [QuarantinedEvidence] {
        quarantinedEvidence(origins: [.space(space)]).filter { $0.space == nil }
    }

    public func unattributedLegacyEvidence() -> [QuarantinedEvidence] {
        quarantinedEvidence(origins: [.legacyRoot]).filter { $0.space == nil }
    }

    /// Produce a private, inert inspection copy after rechecking the exact
    /// scanned bytes. A Finder consumer must never open the live evidence URL.
    public func inspectionCopy(of evidence: QuarantinedEvidence,
                               in space: AppSpace?) -> URL? {
        if let space {
            guard (evidence.origin == .legacyRoot && evidence.space == space) ||
                  (evidence.origin == .space(space) &&
                   (evidence.space == nil || evidence.space == space)) else { return nil }
        } else {
            guard evidence.origin == .legacyRoot, evidence.space == nil else { return nil }
        }
        guard let fingerprint = evidence.sourceDigest,
              let current = quarantinedEvidence(origins: [evidence.origin])
                .first(where: { $0.id == evidence.id }),
              sameEvidence(evidence, current),
              let pinned = openPinnedEvidence(current), stillLinked(pinned),
              let data = DaemonDescriptorMutation.read(in: pinned.sourceFD,
                named: pinned.sourceName, maxBytes: 64 * 1024 * 1024),
              Data(SHA256.hash(data: data)) == fingerprint,
              DaemonDescriptorMutation.digest(in: pinned.sourceFD,
                named: pinned.sourceName) == fingerprint,
              stillLinked(pinned) else { return nil }

        return privateInspectionCopy(data, tag: space?.rawValue ?? "legacy",
            outputName: "evidence.json")
    }

    /// The task center inspects a journal copy instead of following the live
    /// run directory in Finder. A stale or foreign record cannot select it.
    public func inspectionCopy(of located: LocatedDaemonRecord,
                               in space: AppSpace) -> URL? {
        let record = located.record
        guard record.space == space,
              located.origin == .legacyRoot || located.origin == .space(space),
              let pinned = openPinnedOrigin(located.origin), stillLinked(pinned),
              let runData = DaemonDescriptorMutation.read(in: pinned.baseFD,
                named: "run-\(record.id.uuidString).json"),
              let current = try? JSONDecoder().decode(DaemonRunRecord.self, from: runData),
              current.id == record.id, current.space == space else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let currentData = try? encoder.encode(current),
              let expectedData = try? encoder.encode(record),
              currentData == expectedData,
              let hasOwner = DaemonDescriptorMutation.exists(in: pinned.baseFD,
                named: "owner-\(record.id.uuidString).json"),
              (located.origin == .legacyRoot || hasOwner),
              (!hasOwner || owner(id: record.id, baseFD: pinned.baseFD)?.matches(current) == true),
              let journalFD = openChildDirectory("run-\(record.id.uuidString)",
                in: pinned.baseFD) else { return nil }
        defer { close(journalFD) }
        guard let journal = DaemonDescriptorMutation.read(in: journalFD,
                named: "operations.json", maxBytes: 64 * 1024 * 1024),
              OperationJournal.isBoundForInspection(journal,
                to: .init(runID: record.id, space: space)),
              DaemonDescriptorMutation.digest(in: journalFD,
                named: "operations.json") == Data(SHA256.hash(data: journal)),
              stillLinked(pinned),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: pinned.baseFD, named: "run-\(record.id.uuidString)",
                childFD: journalFD) else { return nil }
        return privateInspectionCopy(journal, tag: "journal-\(space.rawValue)",
            outputName: "operations.json")
    }

    private func privateInspectionCopy(_ data: Data, tag: String,
                                       outputName: String) -> URL? {
        let temporaryRoot = fileManager.temporaryDirectory
        let rootFD = open(temporaryRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              rootInfo.st_uid == geteuid(), rootInfo.st_mode & 0o022 == 0 else { return nil }
        let folderName = "AgRoom-evidence-\(tag)-\(UUID().uuidString)"
        guard DaemonDescriptorMutation.safeName(folderName),
              mkdirat(rootFD, folderName, 0o700) == 0 else { return nil }
        let folderFD = openat(rootFD, folderName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderFD >= 0 else {
            _ = unlinkat(rootFD, folderName, AT_REMOVEDIR)
            return nil
        }
        defer { close(folderFD) }
        var folderInfo = stat()
        guard fstat(folderFD, &folderInfo) == 0,
              folderInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              folderInfo.st_uid == geteuid(), fchmod(folderFD, 0o700) == 0,
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: rootFD, named: folderName, childFD: folderFD) else {
            _ = unlinkat(rootFD, folderName, AT_REMOVEDIR)
            return nil
        }
        let outputFD = openat(folderFD, outputName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else {
            _ = unlinkat(rootFD, folderName, AT_REMOVEDIR)
            return nil
        }
        defer { close(outputFD) }
        let wrote = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(outputFD, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wrote, fchmod(outputFD, 0o600) == 0, fsync(outputFD) == 0,
              fsync(folderFD) == 0,
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: rootFD, named: folderName, childFD: folderFD) else {
            _ = unlinkat(folderFD, outputName, 0)
            _ = unlinkat(rootFD, folderName, AT_REMOVEDIR)
            return nil
        }
        return temporaryRoot.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(outputName)
    }

    /// Removing an owner before its conflicting body would make the body
    /// appear valid on the next scan. Require the body to be sealed first.
    private func ownerEvidenceHasBody(_ evidence: QuarantinedEvidence) -> Bool {
        let name = evidence.fileURL.lastPathComponent
        guard name.hasPrefix("owner-") || name.contains("-owner-") else { return false }
        guard let id = evidence.recordID else { return true }
        guard let pinned = openPinnedOrigin(evidence.origin),
              let active = DaemonDescriptorMutation.names(in: pinned.baseFD) else { return true }
        if active.contains("run-\(id.uuidString).json") ||
            active.contains("handoff-\(id.uuidString).json") { return true }
        if active.contains("quarantine") {
            guard let quarantineFD = openChildDirectory("quarantine", in: pinned.baseFD) else { return true }
            defer { close(quarantineFD) }
            guard let quarantined = DaemonDescriptorMutation.names(in: quarantineFD),
                  DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: pinned.baseFD, named: "quarantine", childFD: quarantineFD) else { return true }
            if quarantined.contains(where: { $0.hasSuffix("-run-\(id.uuidString).json") ||
                $0.hasSuffix("-handoff-\(id.uuidString).json") }) { return true }
        }
        return !stillLinked(pinned)
    }

    private func evidenceConflictsWithLiveRecord(_ evidence: QuarantinedEvidence) -> Bool {
        guard let id = evidence.recordID else { return false }
        let relevantSpace: AppSpace?
        if let trusted = evidence.space {
            relevantSpace = trusted
        } else if case .space(let fixedSpace) = evidence.origin {
            relevantSpace = fixedSpace
        } else {
            // An unknown legacy-root body could belong to either space.
            relevantSpace = nil
        }
        // Direct reads are intentionally nonmutating. The normal record scan
        // quarantines malformed files; doing that here could move the exact
        // evidence URL between validation and the manual move below.
        for origin in [DaemonRecordOrigin.legacyRoot] + AppSpace.allCases.map({ .space($0) }) {
            guard let pinned = openPinnedOrigin(origin) else {
                if case .space(let space) = origin,
                   case .absent = spaceDirectoryState(space) { continue }
                return true
            }
            let runName = "run-\(id.uuidString).json"
            let runURL = recordFileURL(id: id, origin: origin)
            if runURL != evidence.fileURL,
               trustedBody(named: runName, baseFD: pinned.baseFD, origin: origin),
               let data = DaemonDescriptorMutation.read(in: pinned.baseFD, named: runName),
               let record = try? JSONDecoder().decode(DaemonRunRecord.self, from: data),
               record.state.isActionable,
               relevantSpace == nil || record.space == relevantSpace { return true }
            if origin == .legacyRoot {
                let handoffName = "handoff-\(id.uuidString).json"
                let handoffURL = directory.appendingPathComponent("handoff-\(id.uuidString).json")
                if handoffURL != evidence.fileURL,
                   trustedBody(named: handoffName, baseFD: pinned.baseFD, origin: origin),
                   let data = DaemonDescriptorMutation.read(in: pinned.baseFD, named: handoffName),
                   let handoff = try? JSONDecoder().decode(DaemonHandoff.self, from: data),
                   relevantSpace == nil || handoff.space == relevantSpace { return true }
            }
            if !stillLinked(pinned) { return true }
        }
        return false
    }

    private func sameEvidence(_ lhs: QuarantinedEvidence, _ rhs: QuarantinedEvidence) -> Bool {
        lhs.id == rhs.id && lhs.fileURL == rhs.fileURL && lhs.origin == rhs.origin &&
            lhs.recordID == rhs.recordID && lhs.space == rhs.space &&
            lhs.sessionID == rhs.sessionID && lhs.assistantMessageID == rhs.assistantMessageID &&
            lhs.taskRunID == rhs.taskRunID && lhs.sourceDigest == rhs.sourceDigest
    }

    private final class PinnedEvidence {
        let origin: PinnedOrigin
        let sourceFD: Int32
        let sourceName: String
        let isQuarantined: Bool

        init(origin: PinnedOrigin, sourceFD: Int32, sourceName: String,
             isQuarantined: Bool) {
            self.origin = origin
            self.sourceFD = sourceFD
            self.sourceName = sourceName
            self.isQuarantined = isQuarantined
        }

        deinit { if sourceFD != origin.baseFD { close(sourceFD) } }
    }

    private func openPinnedEvidence(_ evidence: QuarantinedEvidence) -> PinnedEvidence? {
        guard let pinned = openPinnedOrigin(evidence.origin), stillLinked(pinned) else { return nil }
        let base = storageDirectory(for: evidence.origin)
        let parent = evidence.fileURL.deletingLastPathComponent()
        let name = evidence.fileURL.lastPathComponent
        guard DaemonDescriptorMutation.safeName(name) else { return nil }
        if parent == base {
            return PinnedEvidence(origin: pinned, sourceFD: pinned.baseFD,
                sourceName: name, isQuarantined: false)
        }
        guard parent == base.appendingPathComponent("quarantine", isDirectory: true),
              let quarantineFD = openChildDirectory("quarantine", in: pinned.baseFD) else { return nil }
        return PinnedEvidence(origin: pinned, sourceFD: quarantineFD,
            sourceName: name, isQuarantined: true)
    }

    private func stillLinked(_ evidence: PinnedEvidence) -> Bool {
        stillLinked(evidence.origin) && (!evidence.isQuarantined ||
            DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: evidence.origin.baseFD, named: "quarantine",
                childFD: evidence.sourceFD))
    }

    /// Bind manual resolution to the exact bytes under a pinned origin.
    private func evidenceDigest(_ evidence: QuarantinedEvidence) -> Data? {
        guard let pinned = openPinnedEvidence(evidence), stillLinked(pinned),
              let digest = DaemonDescriptorMutation.digest(in: pinned.sourceFD,
                named: pinned.sourceName), stillLinked(pinned) else { return nil }
        return digest
    }

    private func sidecarDigestIfPresent(id: UUID,
                                        origin: DaemonRecordOrigin) -> (exists: Bool, digest: Data?)? {
        guard let pinned = openPinnedOrigin(origin), stillLinked(pinned) else { return nil }
        let name = "owner-\(id.uuidString).json"
        guard let exists = DaemonDescriptorMutation.exists(in: pinned.baseFD, named: name) else { return nil }
        let digest = exists ? DaemonDescriptorMutation.digest(in: pinned.baseFD, named: name) : nil
        guard !exists || digest != nil, stillLinked(pinned) else { return nil }
        return (exists, digest)
    }

    private func openAbandonedDirectory(in pinned: PinnedOrigin) -> (quarantineFD: Int32, abandonedFD: Int32)? {
        guard stillLinked(pinned),
              let quarantineFD = openChildDirectory("quarantine", in: pinned.baseFD, create: true) else { return nil }
        guard let abandonedFD = openChildDirectory("abandoned", in: quarantineFD, create: true),
              stillLinked(pinned),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: pinned.baseFD, named: "quarantine", childFD: quarantineFD) else {
            close(quarantineFD)
            return nil
        }
        return (quarantineFD, abandonedFD)
    }

    private func moveReviewedEvidence(_ evidence: QuarantinedEvidence,
                                      matching digest: Data,
                                      sidecar: (exists: Bool, digest: Data?)? = nil) -> Bool {
        guard let pinned = openPinnedEvidence(evidence), stillLinked(pinned),
              let target = openAbandonedDirectory(in: pinned.origin) else { return false }
        defer { close(target.abandonedFD); close(target.quarantineFD) }
        guard stillLinked(pinned),
              DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: target.quarantineFD, named: "abandoned",
                childFD: target.abandonedFD),
              DaemonDescriptorMutation.digest(in: pinned.sourceFD,
                named: pinned.sourceName) == digest else { return false }
        let targetName = UUID().uuidString + "-" + pinned.sourceName
        guard DaemonDescriptorMutation.moveRegularFile(from: pinned.sourceFD,
            named: pinned.sourceName, to: target.abandonedFD,
            named: targetName, matching: digest) else { return false }
        if let id = evidence.recordID, let sidecar, sidecar.exists,
           !(pinned.sourceFD == pinned.origin.baseFD &&
             pinned.sourceName == "owner-\(id.uuidString).json") {
            guard let sidecarDigest = sidecar.digest else { return false }
            let ownerName = "owner-\(id.uuidString).json"
            let ownerTarget = UUID().uuidString + "-" + ownerName
            guard stillLinked(pinned),
                  DaemonDescriptorMutation.moveRegularFile(from: pinned.origin.baseFD,
                    named: ownerName, to: target.abandonedFD,
                    named: ownerTarget, matching: sidecarDigest) else { return false }
        }
        return true
    }

    /// Global recovery only: an old record with no trustworthy space may be
    /// abandoned after explicit inspection. This does not touch either space DB.
    public func abandonUnattributedEvidence(_ evidence: QuarantinedEvidence) -> Bool {
        guard evidence.origin == .legacyRoot, evidence.space == nil else { return false }
        return withStoppedDaemon(failure: false) {
            withStoreMutationLock(failure: false) {
                guard let current = quarantinedEvidence(origins: [.legacyRoot]).first(where: { $0.id == evidence.id }),
                      sameEvidence(evidence, current), current.space == nil,
                      let reviewedDigest = current.sourceDigest,
                      evidenceDigest(current) == reviewedDigest,
                      !ownerEvidenceHasBody(current),
                      !evidenceConflictsWithLiveRecord(current) else { return false }
                if moveReviewedEvidence(current, matching: reviewedDigest) {
                    HubLogger.shared.info("Daemon unattributed evidence abandoned after explicit review")
                    return true
                }
                HubLogger.shared.error("Daemon unattributed evidence abandonment failed")
                return false
            }
        }
    }

    /// An unreadable record under a fixed space directory is visible only in
    /// that same space. It cannot be resolved through the legacy global flow.
    public func abandonUnattributedEvidence(_ evidence: QuarantinedEvidence,
                                            in space: AppSpace) -> Bool {
        guard evidence.origin == .space(space), evidence.space == nil else { return false }
        return withStoppedDaemon(failure: false) {
            withStoreMutationLock(failure: false) {
                guard let current = quarantinedEvidence(origins: [.space(space)]).first(where: { $0.id == evidence.id }),
                      sameEvidence(evidence, current), current.space == nil,
                      let reviewedDigest = current.sourceDigest,
                      evidenceDigest(current) == reviewedDigest,
                      !ownerEvidenceHasBody(current),
                      !evidenceConflictsWithLiveRecord(current) else { return false }
                if moveReviewedEvidence(current, matching: reviewedDigest) {
                    HubLogger.shared.info("Daemon scoped unattributed evidence abandoned after explicit review")
                    return true
                }
                HubLogger.shared.error("Daemon scoped evidence abandonment failed")
                return false
            }
        }
    }

    /// Explicit manual abandonment preserves the raw bytes in a separate
    /// folder. It is permitted only after Daemon has stopped and the evidence
    /// is still malformed; moving it removes the execution lock without replay.
    public func abandonQuarantinedEvidence(_ evidence: QuarantinedEvidence,
                                           space: AppSpace, sessionService: SessionService?) async -> Bool {
        guard !isDaemonAlive(),
              (evidence.origin == .legacyRoot || evidence.origin == .space(space)),
              let current = quarantinedEvidence(origins: [evidence.origin]).first(where: { $0.id == evidence.id }),
              sameEvidence(evidence, current),
              current.space == space,
              !ownerEvidenceHasBody(current),
              !evidenceConflictsWithLiveRecord(current),
              let reviewedDigest = current.sourceDigest,
              evidenceDigest(current) == reviewedDigest else { return false }
        let reviewedSidecar: (exists: Bool, digest: Data?)?
        if let id = current.recordID {
            reviewedSidecar = sidecarDigestIfPresent(id: id, origin: current.origin)
            guard reviewedSidecar != nil else { return false }
        } else {
            reviewedSidecar = nil
        }
        if let sessionID = current.sessionID, let messageID = current.assistantMessageID {
            guard let sessionService, current.space == space else { return false }
            do {
                let before = try await sessionService.getMessagesDetailed(id: sessionID)
                guard before.health == .healthy,
                      let message = before.messages.first(where: { $0.id == messageID }),
                      current.taskRunID == nil || message.taskRun?.id == current.taskRunID else { return false }
                let expectedRunID = message.taskRun?.id
                try await sessionService.updateMessage(sessionId: sessionID,
                    messageId: messageID, expectedTaskRunID: expectedRunID,
                    clearPendingForMessage: true) { value in
                    switch value.runStatus {
                    case .succeeded, .incomplete, .failed, .cancelled: break
                    default: value.runStatus = .cancelled
                    }
                }
                let after = try await sessionService.getMessagesDetailed(id: sessionID)
                guard after.health == .healthy,
                      let updated = after.messages.first(where: { $0.id == messageID }),
                      updated.taskRun?.id == expectedRunID,
                      updated.runStatus?.isTerminal == true,
                      after.pendingConfirmation == nil, after.pendingQuestion == nil else { return false }
            } catch {
                HubLogger.shared.error("Daemon quarantine resolution write failed: \(HubLogger.safeErrorSummary(error))")
                return false
            }
        } else if current.sessionID != nil || current.assistantMessageID != nil {
            // Partial ownership is not enough to update the right message.
            return false
        }
        // SessionService above may suspend. Reclaim daemon.lock, then the
        // Store lock, and recheck the complete credential and original bytes.
        return withStoppedDaemon(failure: false) {
            withStoreMutationLock(failure: false) {
                let sidecarUnchanged: Bool
                if let id = current.recordID, let reviewedSidecar,
                   let latestSidecar = sidecarDigestIfPresent(id: id, origin: current.origin) {
                    sidecarUnchanged = latestSidecar.exists == reviewedSidecar.exists &&
                        latestSidecar.digest == reviewedSidecar.digest
                } else {
                    sidecarUnchanged = current.recordID == nil
                }
                guard let latest = quarantinedEvidence(origins: [current.origin]).first(where: { $0.id == current.id }),
                      sameEvidence(current, latest), latest.space == space,
                      evidenceDigest(latest) == reviewedDigest,
                      sidecarUnchanged,
                      !ownerEvidenceHasBody(latest),
                      !evidenceConflictsWithLiveRecord(latest) else { return false }
                if moveReviewedEvidence(latest, matching: reviewedDigest,
                                        sidecar: reviewedSidecar) {
                    HubLogger.shared.info("Daemon quarantined evidence abandoned after explicit review")
                    return true
                }
                HubLogger.shared.error("Daemon quarantine abandonment failed")
                return false
            }
        }
    }

    /// 状态迁移：读记录 → 更新状态与时间 → 原子替换；返回更新后的记录
    @discardableResult
    public func updateState(id: UUID, origin: DaemonRecordOrigin,
                            to state: DaemonRunState) -> DaemonRunRecord? {
        withStoreMutationLock(failure: nil as DaemonRunRecord?) {
            guard var record = locatedRecords().first(where: { $0.record.id == id && $0.origin == origin })?.record else { return nil }
            record.state = state
            record.updatedAt = Date()
            return writeRecordUnlocked(record, origin: origin) ? record : nil
        }
    }

    private struct SpaceRunKey: Hashable {
        let space: AppSpace
        let id: UUID
    }

    private func readLocatedRecords(origin: DaemonRecordOrigin) -> [LocatedDaemonRecord] {
        guard let pinned = openPinnedOrigin(origin), stillLinked(pinned),
              let names = DaemonDescriptorMutation.names(in: pinned.baseFD) else { return [] }
        let decoder = JSONDecoder()
        var result: [LocatedDaemonRecord] = names
            .filter { $0.hasPrefix("run-") && $0.hasSuffix(".json") }
            .compactMap { name -> LocatedDaemonRecord? in
                guard let data = DaemonDescriptorMutation.read(in: pinned.baseFD,
                        named: name),
                      let record = try? decoder.decode(DaemonRunRecord.self, from: data),
                      name == recordFileURL(id: record.id, origin: origin).lastPathComponent,
                      (origin == .legacyRoot || origin == .space(record.space)),
                      let hasOwner = DaemonDescriptorMutation.exists(in: pinned.baseFD,
                        named: "owner-\(record.id.uuidString).json"),
                      (origin == .legacyRoot || hasOwner),
                      (!hasOwner || owner(id: record.id, baseFD: pinned.baseFD)?.matches(record) == true) else {
                    // Keep original bytes in place. A scoped UI read must not
                    // mutate another space; ownershipSnapshot still treats
                    // this active malformed file as unresolved evidence.
                    return nil
                }
                return LocatedDaemonRecord(record: record, origin: origin)
            }
        guard stillLinked(pinned) else { return [] }
        guard origin == .legacyRoot else { return result }
        for handoff in pendingHandoffs() {
            let record = DaemonRunRecord(
                id: handoff.id,
                space: handoff.space,
                sessionId: handoff.sessionId,
                assistantMessageId: handoff.assistantMessageId,
                createdAt: handoff.createdAt,
                updatedAt: handoff.createdAt,
                state: .pending,
                snapshot: handoff.snapshot,
                settings: handoff.settings
            )
            result.append(LocatedDaemonRecord(record: record, origin: .legacyRoot))
        }
        return result
    }

    /// Read both space directories and legacy root. A duplicate within one
    /// space is excluded before Daemon can execute either copy; the files stay
    /// in place for manual reconciliation. Equal UUIDs in different spaces
    /// are independent records.
    private func rawLocatedRecords() -> [LocatedDaemonRecord] {
        readLocatedRecords(origin: .legacyRoot) + AppSpace.allCases.flatMap {
            readLocatedRecords(origin: .space($0))
        }
    }

    public func locatedRecords() -> [LocatedDaemonRecord] {
        let raw = rawLocatedRecords()
        let counts = Dictionary(grouping: raw, by: { SpaceRunKey(space: $0.record.space, id: $0.record.id) })
        let ownership = ownershipSnapshot()
        return raw.filter {
            counts[SpaceRunKey(space: $0.record.space, id: $0.record.id)]?.count == 1 &&
                ownership.ambiguousRunIDsBySpace[$0.record.space]?.contains($0.record.id) != true &&
                !ownership.hasUnattributedQuarantine && !ownership.unattributedSpaces.contains($0.record.space)
        }
            .sorted { $0.record.createdAt < $1.record.createdAt }
    }

    public var actionableLocatedRecords: [LocatedDaemonRecord] {
        locatedRecords().filter { $0.record.state.isActionable }
    }

    public func records(in space: AppSpace) -> [LocatedDaemonRecord] {
        // A space UI enumerates only its own directory and the shared legacy
        // root. The separate global ownership pass is read-only and contributes
        // only fail-closed coordination flags/this space's ambiguous IDs.
        let candidates = (readLocatedRecords(origin: .legacyRoot) +
            readLocatedRecords(origin: .space(space))).filter { $0.record.space == space }
        let counts = Dictionary(grouping: candidates, by: { $0.record.id })
        let ownership = ownershipSnapshot()
        return candidates.filter { located in
            counts[located.record.id]?.count == 1 &&
                ownership.ambiguousRunIDsBySpace[space]?.contains(located.record.id) != true &&
                !ownership.hasUnattributedQuarantine && !ownership.unattributedSpaces.contains(space)
        }.sorted { $0.record.createdAt < $1.record.createdAt }
    }

    /// Process-level coordination only; does not expose cross-space run data.
    public var hasActionableRecords: Bool {
        !actionableLocatedRecords.isEmpty
    }

    /// Explicitly abandon an uncertain run. Preserve its journal and never replay operations.
    public func abandonRecovery(id: UUID, space: AppSpace) -> Bool {
        withStoreMutationLock(failure: false) {
            guard let located = records(in: space).first(where: { $0.record.id == id }),
                  case .recoveryRequired = located.record.state else { return false }
            var record = located.record
            record.state = .completed
            record.updatedAt = Date()
            return writeRecordUnlocked(record, origin: located.origin)
        }
    }

    /// 删除任务记录（含旧移交文件）与该运行的私有目录
    @discardableResult
    public func removeRecord(id: UUID, origin: DaemonRecordOrigin) -> Bool {
        withStoreMutationLock(failure: false) { removeRecordUnlocked(id: id, origin: origin) }
    }

    private func removeRecordUnlocked(id: UUID, origin: DaemonRecordOrigin) -> Bool {
        guard let pinned = openPinnedOrigin(origin), stillLinked(pinned),
              let names = DaemonDescriptorMutation.names(in: pinned.baseFD) else { return false }
        let body = "run-\(id.uuidString).json"
        let handoff = "handoff-\(id.uuidString).json"
        let owner = "owner-\(id.uuidString).json"
        let runDirectory = "run-\(id.uuidString)"
        if origin != .legacyRoot && names.contains(handoff) { return false }

        // Complete preflight precedes the first unlink. Unknown journal children
        // and preserved quarantine evidence retain the entire original group.
        for name in [body, owner] + (origin == .legacyRoot ? [handoff] : [])
            where names.contains(name) {
            guard DaemonDescriptorMutation.regularFileStatus(in: pinned.baseFD,
                named: name) != nil else { return false }
        }
        var journalFD: Int32?
        var hasJournal = false
        if names.contains(runDirectory) {
            guard let fd = openChildDirectory(runDirectory, in: pinned.baseFD) else { return false }
            guard let children = DaemonDescriptorMutation.names(in: fd),
                  children.allSatisfy({ $0 == "operations.json" }),
                  !children.contains("operations.json") ||
                    DaemonDescriptorMutation.regularFileStatus(in: fd,
                        named: "operations.json") != nil else {
                close(fd)
                return false
            }
            journalFD = fd
            hasJournal = children.contains("operations.json")
        }
        defer { if let journalFD { close(journalFD) } }
        if names.contains("quarantine") {
            guard let quarantineFD = openChildDirectory("quarantine", in: pinned.baseFD) else { return false }
            defer { close(quarantineFD) }
            guard let quarantined = DaemonDescriptorMutation.names(in: quarantineFD),
                  !quarantined.contains(where: { $0.hasSuffix("-run-\(id.uuidString).json") ||
                      $0.hasSuffix("-handoff-\(id.uuidString).json") ||
                      $0.hasSuffix("-owner-\(id.uuidString).json") }),
                  DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: pinned.baseFD, named: "quarantine", childFD: quarantineFD) else { return false }
        }
        guard stillLinked(pinned) else { return false }
        if let journalFD {
            guard DaemonDescriptorMutation.directoryStillMatchesEntry(
                parentFD: pinned.baseFD, named: runDirectory, childFD: journalFD) else { return false }
            if hasJournal && !DaemonDescriptorMutation.unlinkRegularFile(
                in: journalFD, named: "operations.json") { return false }
            guard stillLinked(pinned),
                  DaemonDescriptorMutation.directoryStillMatchesEntry(
                    parentFD: pinned.baseFD, named: runDirectory, childFD: journalFD),
                  unlinkat(pinned.baseFD, runDirectory, AT_REMOVEDIR) == 0,
                  fsync(pinned.baseFD) == 0 else { return false }
        }
        for name in [body] + (origin == .legacyRoot ? [handoff] : []) + [owner]
            where names.contains(name) {
            guard stillLinked(pinned),
                  DaemonDescriptorMutation.unlinkRegularFile(in: pinned.baseFD,
                    named: name) else { return false }
        }
        return stillLinked(pinned)
    }

    // MARK: - Daemon Lock（文件描述符排他锁）

    private enum DaemonLockPhase {
        case idle
        case acquiring(UUID, cancelRequested: Bool)
        case held(Int32)
    }
    /// Only the phase and fd identity live under this short lock. File I/O,
    /// flock (including the relay's blocking wait), and READY callbacks run
    /// outside it. The permanent lock inode is never removed.
    private var daemonLockPhase: DaemonLockPhase = .idle
    private let lockStateLock = NSLock()

    /// 守护进程启动抢占单例锁：已有存活实例返回 false（本实例直接退出）。
    ///
    /// 锁文件**不删除**：删除会破坏 flock 语义（新进程会在新 inode 上重新拿到锁）
    public func acquireDaemonLock(waiting: Bool = false,
                                  onReady: (@Sendable () -> Bool)? = nil) -> Bool {
        guard let pinned = openPinnedOrigin(.legacyRoot), stillLinked(pinned) else { return false }
        let ticket = UUID()
        let start = lockStateLock.withLock { () -> Bool? in
            switch daemonLockPhase {
            case .held: return true
            case .acquiring: return false
            case .idle:
                daemonLockPhase = .acquiring(ticket, cancelRequested: false)
                return nil
            }
        }
        if let start { return start }
        func abandon(_ fd: Int32? = nil) -> Bool {
            if let fd { close(fd) }
            lockStateLock.withLock {
                if case .acquiring(let current, _) = daemonLockPhase, current == ticket {
                    daemonLockPhase = .idle
                }
            }
            return false
        }
        let fd = openat(pinned.baseFD, lockFileName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            HubLogger.shared.error("Daemon lock open failed")
            return abandon()
        }
        var opened = stat()
        var linked = stat()
        guard fstat(fd, &opened) == 0,
              fstatat(pinned.baseFD, lockFileName, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_uid == geteuid(), opened.st_nlink == 1,
              opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
              stillLinked(pinned) else { return abandon(fd) }
        if waiting && onReady?() == false { return abandon(fd) }
        while flock(fd, waiting ? LOCK_EX : LOCK_EX | LOCK_NB) != 0 {
            if waiting && errno == EINTR { continue }
            return abandon(fd)
        }
        guard fchmod(fd, 0o600) == 0,
              stillLinked(pinned),
              fstatat(pinned.baseFD, lockFileName, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              linked.st_dev == opened.st_dev, linked.st_ino == opened.st_ino else {
            flock(fd, LOCK_UN)
            return abandon(fd)
        }
        guard ftruncate(fd, 0) == 0 else {
            flock(fd, LOCK_UN)
            return abandon(fd)
        }
        let pidText = "\(ProcessInfo.processInfo.processIdentifier)\n"
        let wrotePID = pidText.withCString { Darwin.write(fd, $0, strlen($0)) }
        guard wrotePID == pidText.utf8.count,
              stillLinked(pinned),
              fstatat(pinned.baseFD, lockFileName, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              linked.st_dev == opened.st_dev, linked.st_ino == opened.st_ino else {
            flock(fd, LOCK_UN)
            return abandon(fd)
        }
        // Keep the phase as acquiring until all fd I/O has finished. A
        // concurrent release marks cancellation rather than closing a fd
        // while this thread still writes to it.
        let accepted = lockStateLock.withLock { () -> Bool in
            guard case .acquiring(let current, let cancelled) = daemonLockPhase,
                  current == ticket, !cancelled else { return false }
            daemonLockPhase = .held(fd)
            return true
        }
        guard accepted else {
            flock(fd, LOCK_UN)
            return abandon(fd)
        }
        return true
    }

    /// 守护进程退出时释放锁（保留锁文件，仅释放 flock）
    public func releaseDaemonLock() {
        let fd = lockStateLock.withLock { () -> Int32? in
            switch daemonLockPhase {
            case .idle: return nil
            case .acquiring(let ticket, _):
                daemonLockPhase = .acquiring(ticket, cancelRequested: true)
                return nil
            case .held(let fd):
                daemonLockPhase = .idle
                return fd
            }
        }
        guard let fd else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// 是否有存活的守护进程实例（跨进程判定）：能拿到排他锁 = 无人持有；拿不到 = 正在运行。
    /// 进程退出（含崩溃）时锁由内核释放，不再依赖可能过期的 PID 文件
    public func isDaemonAlive() -> Bool {
        guard let pinned = openPinnedOrigin(.legacyRoot), stillLinked(pinned) else { return true }
        let localPhase = lockStateLock.withLock { () -> Bool in
            if case .idle = daemonLockPhase { return false }
            return true
        }
        if localPhase { return true }
        let fd = openat(pinned.baseFD, lockFileName, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            // Permission and media errors cannot prove that no process owns
            // the permanent lock. Only a successfully listed absent inode is
            // evidence that an old daemon cannot still hold it.
            guard errno == ENOENT,
                  DaemonDescriptorMutation.exists(in: pinned.baseFD,
                    named: lockFileName) == false,
                  stillLinked(pinned) else { return true }
            return false
        }
        defer { close(fd) }
        var opened = stat()
        var linked = stat()
        guard fstat(fd, &opened) == 0,
              fstatat(pinned.baseFD, lockFileName, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_uid == geteuid(), opened.st_nlink == 1,
              opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
              stillLinked(pinned) else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        // Any failure, including EACCES/EIO, is unsafe for manual abandonment.
        return true
    }

    // MARK: - Quarantine（坏记录隔离）

    /// 既有隔离证据及人工放弃后的封存目录；普通扫描保持纯读，坏件原位保留。
    public var quarantineDirectory: URL {
        quarantineDirectory(for: .legacyRoot)
    }

    public func quarantineDirectory(for origin: DaemonRecordOrigin) -> URL {
        storageDirectory(for: origin).appendingPathComponent("quarantine", isDirectory: true)
    }


}
