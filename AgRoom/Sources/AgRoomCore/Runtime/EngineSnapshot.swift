import Foundation

// MARK: - Engine Message Snapshot

/// 引擎消息快照（Codable DTO）：EngineMessage 本体未做 Codable，
/// 退出移交守护进程时经此 DTO 序列化（角色/文本/工具调用/配对 id/图片）
public struct EngineMessageSnapshot: Codable, Sendable, Equatable {

    public enum Role: String, Codable, Sendable {
        case system, user, assistant, toolResult
    }

    /// 一次工具调用的最小序列化（id/名称/参数 JSON）
    public struct ToolCallSnapshot: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let argumentsJSON: String

        public init(id: String, name: String, argumentsJSON: String) {
            self.id = id
            self.name = name
            self.argumentsJSON = argumentsJSON
        }
    }

    /// 多模态图片（data 以 Base64 编码进 JSON）
    public struct ImageSnapshot: Codable, Sendable, Equatable {
        public let data: Data
        public let mimeType: String

        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    public let role: Role
    public let text: String
    public let toolCalls: [ToolCallSnapshot]
    public let toolCallId: String?
    public let images: [ImageSnapshot]
    public let continuation: EngineContinuation?
    public var hostToolDiscovery: Bool?

    public init(role: Role, text: String, toolCalls: [ToolCallSnapshot] = [], toolCallId: String? = nil, images: [ImageSnapshot] = [], continuation: EngineContinuation? = nil) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.images = images
        self.continuation = continuation
    }

    /// EngineMessage → 快照
    init(message: EngineMessage) {
        let role: Role
        switch message.role {
        case .system: role = .system
        case .user: role = .user
        case .assistant: role = .assistant
        case .toolResult: role = .toolResult
        }
        self.role = role
        self.text = message.text
        self.continuation = message.continuation
        self.hostToolDiscovery = message.hostToolDiscovery
        self.toolCalls = message.toolCalls.map {
            ToolCallSnapshot(id: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON)
        }
        self.toolCallId = message.toolCallId
        self.images = message.images.map {
            ImageSnapshot(data: $0.data, mimeType: $0.mimeType)
        }
    }

    /// 快照 → EngineMessage（守护进程恢复）
    var toEngineMessage: EngineMessage {
        let role: EngineMessage.Role
        switch self.role {
        case .system: role = .system
        case .user: role = .user
        case .assistant: role = .assistant
        case .toolResult: role = .toolResult
        }
        var message = EngineMessage(
            role: role,
            text: text,
            toolCalls: toolCalls.map {
                ToolCallRaw(id: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON)
            },
            toolCallId: toolCallId,
            images: images.map {
                EngineImage(data: $0.data, mimeType: $0.mimeType)
            },
            continuation: continuation
        )
        message.hostToolDiscovery = hostToolDiscovery
        return message
    }
}

// MARK: - Engine Run Snapshot

/// 引擎运行快照：消息上下文 + 轮内累计状态（思维链/轨迹/计数器/步数预算）+ 工具批检查点。
/// 恢复后从上次完整的消息边界继续工具循环——已执行的工具调用不会重跑；
/// 被打断的那次模型请求作废，由接管方重新发起。
///
/// 兼容性：后加字段缺失时仍可解码；旧记录中的未配对调用或挂起占位
/// 必须由恢复入口判为需人工核实，不能因缺少新字段而自动续跑。
public struct EngineRunSnapshot: Codable, Sendable {
    /// Older releases wrote this exact text as a tool result before the inner
    /// operation had completed. Keep the marker stable for legacy recovery.
    static let suspensionPlaceholder =
        "[This tool call is paused waiting for the user's confirmation. Its final result will replace this message once the user decides.]"
    public var messages: [EngineMessageSnapshot]
    public var thoughts: [String]
    public var trace: [DispatcherTraceEntry]
    public var stepsUsed: Int
    public var totalTokens: Int
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    /// Nil on legacy snapshots, whose thought transcript contained narration only.
    public var reasoningTokenUsage: ReasoningTokenUsage?
    public var codingRepairAttempts: Int?
    /// A metadata-only recovery may run once per user turn, including across handoffs.
    public var toolDiscoveryRecoveryAttempts: Int?
    var requestedReadSource: ToolSourceReceipt.Source?
    var rejectedOperations: Set<String>?
    var clarifiedMailURL: URL?
    var expectsSavedMailDraft: Bool?
    /// 重复调用指纹计数（防死循环检测的累计状态）
    public var callFingerprintCounts: [String: Int]
    public var consecutiveFailedRounds: Int
    /// skill_load 收敛后的工具白名单（轮内激活技能时）
    public var restrictedToolNames: Set<String>?
    /// 激活技能声明的工作区（写范围收敛）
    public var activeSkillWorkspace: String?
    /// 激活技能名（用于按名称重新解析范围，避免只信任快照里的旧路径）
    public var activeSkillName: String?
    /// 激活技能工作区声明无效时的原因（禁止写，而不是回退）
    public var activeSkillWorkspaceError: String?
    /// 当前子任务写范围（Worker 内执行时）
    public var subtaskWriteRoots: [URL]?
    public var loopNoticeInjected: Bool
    /// 本轮已放行的工具名（外部预授权，如子代理技能脚本）
    public var preApprovedTools: Set<String>
    /// **工具批检查点**：快照落下时正在执行的模型工具调用 id。
    ///
    /// 消息快照只能停在完整的消息边界，因此「助手消息已写入、工具结果尚未写回」这段
    /// 会表现为「有 toolCalls 无 toolResult」。仅凭消息无法区分「这些调用还没有结果」
    /// 和「结果已被压缩掉」，接管方就可能整批重放。这个字段把批边界显式记下来：
    /// 非空即表示有副作用调用处于结果未定状态，必须交人工判定而不是重放。
    public var pendingToolCallIds: [String]
    /// In-memory tool suspensions cannot be rebuilt from a serialized result.
    /// This marker survives checkpoints and is independent of an active batch.
    public var suspendedToolCallIds: [String]
    /// 本轮曾因副作用日志写不进磁盘而拒绝执行有副作用的工具（恢复时转人工）
    public var contextReport: RequestContextReport?
    public var journalUnavailable: Bool
    /// 本轮权限模式（旧快照缺省 = danger-full-access，保持旧行为）。
    /// 仅作恢复审计；实际执行仍以会话设置与 EngineAssembly 组装结果为准。
    public var permissionMode: String?
    /// 本轮完成评估（旧快照缺失时按「未评估」兼容）：
    /// 恢复提交时据此落库未完成状态，不把缺少产物的运行当成成功。
    public var completion: TaskCompletionAssessment?
    var skillScriptReceipts: [DispatcherEngine.SkillScriptReceipt]?
    /// Aggregate evidence from snapshots that predate per-step receipts.
    var legacyCompletion: TaskCompletionAssessment?
    var childCheckpoints: [ChildRunCheckpoint]?
    public var inputArtifactVersionIDs: [UUID]?
    /// The exact wire schemas accompanying the first opaque/signed continuation.
    /// Execution always uses the current registry and permission policy.
    public var signedToolFace: [ToolDefinition]?
    /// Stable schemas selected by per-run intent routing; contains no execution authority.
    public var deferredToolFace: [ToolDefinition]?
    /// Retains lazily activated engineering checks across an automatic-workflow handoff.
    public var codingTaskActive: Bool?
    public var pinnedUserDigest: String?
    public var completedProviderTurn: ProviderTurnHistory?

    public init(
        messages: [EngineMessageSnapshot],
        thoughts: [String],
        trace: [DispatcherTraceEntry],
        stepsUsed: Int,
        totalTokens: Int,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        callFingerprintCounts: [String: Int],
        consecutiveFailedRounds: Int,
        restrictedToolNames: Set<String>?,
        activeSkillWorkspace: String?,
        activeSkillName: String? = nil,
        activeSkillWorkspaceError: String? = nil,
        subtaskWriteRoots: [URL]? = nil,
        loopNoticeInjected: Bool,
        preApprovedTools: Set<String>,
        pendingToolCallIds: [String] = [],
        suspendedToolCallIds: [String] = [],
        journalUnavailable: Bool = false,
        contextReport: RequestContextReport? = nil,
        permissionMode: String? = nil,
        completion: TaskCompletionAssessment? = nil,
        inputArtifactVersionIDs: [UUID]? = nil,
        reasoningTokenUsage: ReasoningTokenUsage? = nil,
        codingRepairAttempts: Int? = nil,
        signedToolFace: [ToolDefinition]? = nil,
        deferredToolFace: [ToolDefinition]? = nil,
        codingTaskActive: Bool? = nil,
        pinnedUserDigest: String? = nil
    ) {
        self.messages = messages
        self.thoughts = thoughts
        self.trace = trace
        self.stepsUsed = stepsUsed
        self.totalTokens = totalTokens
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.reasoningTokenUsage = reasoningTokenUsage
        self.codingRepairAttempts = codingRepairAttempts
        self.signedToolFace = signedToolFace
        self.deferredToolFace = deferredToolFace
        self.codingTaskActive = codingTaskActive
        self.pinnedUserDigest = pinnedUserDigest
        self.callFingerprintCounts = callFingerprintCounts
        self.consecutiveFailedRounds = consecutiveFailedRounds
        self.restrictedToolNames = restrictedToolNames
        self.activeSkillWorkspace = activeSkillWorkspace
        self.activeSkillName = activeSkillName
        self.activeSkillWorkspaceError = activeSkillWorkspaceError
        self.subtaskWriteRoots = subtaskWriteRoots
        self.loopNoticeInjected = loopNoticeInjected
        self.preApprovedTools = preApprovedTools
        self.pendingToolCallIds = pendingToolCallIds
        self.suspendedToolCallIds = suspendedToolCallIds
        self.journalUnavailable = journalUnavailable
        self.contextReport = contextReport
        self.permissionMode = permissionMode
        self.completion = completion
        self.inputArtifactVersionIDs = inputArtifactVersionIDs
    }

    /// 手写解码：后加字段缺失时按默认值处理。
    ///
    /// 用合成解码器会让旧记录整体解码失败。当前 Store 会隔离该记录并要求人工核对，
    /// 不能把缺少后来新增字段的旧任务误判为损坏而停止正常续跑。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decode([EngineMessageSnapshot].self, forKey: .messages)
        thoughts = try c.decode([String].self, forKey: .thoughts)
        trace = try c.decode([DispatcherTraceEntry].self, forKey: .trace)
        stepsUsed = try c.decode(Int.self, forKey: .stepsUsed)
        totalTokens = try c.decode(Int.self, forKey: .totalTokens)
        totalInputTokens = try c.decode(Int.self, forKey: .totalInputTokens)
        totalOutputTokens = try c.decode(Int.self, forKey: .totalOutputTokens)
        reasoningTokenUsage = try c.decodeIfPresent(ReasoningTokenUsage.self, forKey: .reasoningTokenUsage)
        codingRepairAttempts = try c.decodeIfPresent(Int.self, forKey: .codingRepairAttempts)
        toolDiscoveryRecoveryAttempts = try c.decodeIfPresent(Int.self, forKey: .toolDiscoveryRecoveryAttempts)
        requestedReadSource = try c.decodeIfPresent(ToolSourceReceipt.Source.self, forKey: .requestedReadSource)
        rejectedOperations = try c.decodeIfPresent(Set<String>.self, forKey: .rejectedOperations)
        clarifiedMailURL = try c.decodeIfPresent(URL.self, forKey: .clarifiedMailURL)
        expectsSavedMailDraft = try c.decodeIfPresent(Bool.self, forKey: .expectsSavedMailDraft)
        callFingerprintCounts = try c.decode([String: Int].self, forKey: .callFingerprintCounts)
        consecutiveFailedRounds = try c.decode(Int.self, forKey: .consecutiveFailedRounds)
        restrictedToolNames = try c.decodeIfPresent(Set<String>.self, forKey: .restrictedToolNames)
        activeSkillWorkspace = try c.decodeIfPresent(String.self, forKey: .activeSkillWorkspace)
        activeSkillName = try c.decodeIfPresent(String.self, forKey: .activeSkillName)
        activeSkillWorkspaceError = try c.decodeIfPresent(String.self, forKey: .activeSkillWorkspaceError)
        subtaskWriteRoots = try c.decodeIfPresent([URL].self, forKey: .subtaskWriteRoots)
        loopNoticeInjected = try c.decode(Bool.self, forKey: .loopNoticeInjected)
        preApprovedTools = try c.decode(Set<String>.self, forKey: .preApprovedTools)
        pendingToolCallIds = try c.decodeIfPresent([String].self, forKey: .pendingToolCallIds) ?? []
        suspendedToolCallIds = try c.decodeIfPresent([String].self, forKey: .suspendedToolCallIds) ?? []
        journalUnavailable = try c.decodeIfPresent(Bool.self, forKey: .journalUnavailable) ?? false
        contextReport = try c.decodeIfPresent(RequestContextReport.self, forKey: .contextReport)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        completion = try c.decodeIfPresent(TaskCompletionAssessment.self, forKey: .completion)
        skillScriptReceipts = try c.decodeIfPresent([DispatcherEngine.SkillScriptReceipt].self, forKey: .skillScriptReceipts)
        legacyCompletion = try c.decodeIfPresent(TaskCompletionAssessment.self, forKey: .legacyCompletion)
        childCheckpoints = try c.decodeIfPresent([ChildRunCheckpoint].self, forKey: .childCheckpoints)
        inputArtifactVersionIDs = try c.decodeIfPresent([UUID].self, forKey: .inputArtifactVersionIDs)
        signedToolFace = try c.decodeIfPresent([ToolDefinition].self, forKey: .signedToolFace)
        deferredToolFace = try c.decodeIfPresent([ToolDefinition].self, forKey: .deferredToolFace)
        codingTaskActive = try c.decodeIfPresent(Bool.self, forKey: .codingTaskActive)
        pinnedUserDigest = try c.decodeIfPresent(String.self, forKey: .pinnedUserDigest)
        completedProviderTurn = try c.decodeIfPresent(ProviderTurnHistory.self, forKey: .completedProviderTurn)
    }

    /// A complete model boundary has one result for each call. A pending ordinary
    /// approval may use this shape while live, but a restarted engine must never
    /// infer that it was already executed. Legacy suspended snapshots are caught
    /// by the unchanged placeholder even when the new field is absent.
    public var requiresManualToolRecovery: Bool {
        guard childCheckpoints?.isEmpty != false else { return true }
        guard pendingToolCallIds.isEmpty, suspendedToolCallIds.isEmpty else { return true }
        var calls: [String: Int] = [:]
        var results: [String: Int] = [:]
        for message in messages {
            if message.role == .assistant {
                for call in message.toolCalls { calls[call.id, default: 0] += 1 }
            } else if message.role == .toolResult {
                if message.text == Self.suspensionPlaceholder { return true }
                guard let id = message.toolCallId else { return true }
                results[id, default: 0] += 1
            }
        }
        return calls != results
    }

    public var hasSuspensionPlaceholder: Bool {
        messages.contains { $0.role == .toolResult && $0.text == Self.suspensionPlaceholder }
    }

    /// Providers may reuse a call ID in a later user turn. Only exclude a historical
    /// prefix when the recorded boundary agrees with the exact pinned user input.
    private var currentTurnMessages: ArraySlice<EngineMessageSnapshot> {
        guard let count = contextReport?.initialHistoryMessageCount, count > 0,
              let first = messages.firstIndex(where: { $0.role != .system }),
              count < messages.count - first, let pinnedUserDigest else { return messages[...] }
        let start = first + count
        guard messages[start].role == .user, ResponsesContextWindow.digest(messages[start].text) == pinnedUserDigest
        else { return messages[...] }
        return messages[start...]
    }

    var completedToolSteps: [DispatcherTraceEntry] {
        trace.filter { $0.resultFull != Self.suspensionPlaceholder }
    }

    /// Reconcile only a complete single delegation. Both disk writes are idempotent:
    /// after a crash between them the same child receipt can be paired again.
    public func reconcilingFinishedChild(journal: OperationJournal, binding: OperationJournal.Binding,
                                         sessionID: UUID) -> Self? {
        guard !journalUnavailable, childCheckpoints?.count == 1, let child = childCheckpoints?.first, child.formatVersion == 1,
              child.parent == binding, child.parentSessionID == sessionID, child.parentStep == stepsUsed,
              child.childRunID != binding.runID, let result = child.result,
              result.childRunID == child.childRunID, result.agentID == child.agentID,
              result.stopReason == .modelFinished,
              result.status == DelegatedRunResult.status(reason: .modelFinished, completion: result.completion,
                  steps: child.snapshot.completedToolSteps, hasVersions: !result.artifactVersionIDs.isEmpty),
              !child.snapshot.journalUnavailable, !child.snapshot.requiresManualToolRecovery,
              child.snapshot.completion == result.completion,
              pendingToolCallIds == [child.parentCallID], suspendedToolCallIds.isEmpty,
              journal.acceptsEngine(runID: binding.runID, space: binding.space),
              journal.unresolvedOperationIDs().allSatisfy({ $0 == child.parentCallID }),
              let index = messages.lastIndex(where: { $0.role == .assistant }),
              messages[index].toolCalls.count == 1, let original = messages[index].toolCalls.first,
              original.id == child.parentCallID, original.name == child.wireToolName,
              currentTurnMessages.flatMap(\.toolCalls).filter({ $0.id == original.id }).count == 1,
              let text = try? result.modelText() else { return nil }
        let raw = ToolCallRaw(id: original.id, name: original.name, argumentsJSON: original.argumentsJSON)
        let wire = OperationJournal.CallIdentity(binding: binding, modelStep: stepsUsed, toolName: raw.name,
            argumentsJSON: raw.argumentsJSON)
        let call = ToolCatalog.invocationTarget(raw) ?? raw
        let identity = OperationJournal.CallIdentity(binding: binding, modelStep: stepsUsed,
            toolName: call.name, argumentsJSON: call.argumentsJSON)
        guard wire.argumentDigest == child.wireArgumentsDigest, call.name == child.parentToolName,
              identity.argumentDigest == child.parentArgumentsDigest else { return nil }
        let tail = messages.suffix(from: index + 1)
        guard tail.count <= 1, tail.allSatisfy({ $0.role == .toolResult && $0.toolCallId == call.id
            && ($0.text == Self.suspensionPlaceholder || $0.text == text) }) else { return nil }

        let succeeded = result.status == .finished
        let evidence = ToolExecutionEvidence(delegation: result)
        var paired = self
        paired.childCheckpoints = nil
        paired.pendingToolCallIds = []
        paired.messages = Array(messages.prefix(index + 1)) + [.init(role: .toolResult, text: text, toolCallId: call.id)]
        if !trace.contains(where: { $0.toolName == call.name && $0.evidence == evidence }) {
            paired.trace.append(.init(toolName: call.name, argumentsPreview: DispatcherEngine.preview(call.argumentsJSON),
                resultPreview: DispatcherEngine.preview(text), argumentsFull: DispatcherEngine.fullText(call.argumentsJSON),
                resultFull: DispatcherEngine.fullText(text), duration: 0, succeeded: succeeded, evidence: evidence))
            if tail.isEmpty {
                paired.callFingerprintCounts[DispatcherEngine.fingerprint(of: call), default: 0] += 1
            }
            paired.consecutiveFailedRounds = succeeded ? 0 : consecutiveFailedRounds + 1
        }
        guard !paired.requiresManualToolRecovery else { return nil }
        switch journal.cachedOutcome(operationID: call.id, identity: identity) {
        case .unresolved:
            guard journal.recordReceipt(operationID: call.id, result: text, succeeded: succeeded, evidence: evidence) else { return nil }
        case .saved(_, let savedSuccess):
            guard savedSuccess == succeeded, journal.evidence(operationID: call.id, identity: identity) == evidence else { return nil }
        default: return nil
        }
        return paired
    }

    /// A live daemon may persist a top-level ask_user form without attempting to
    /// resume its serialized placeholder. Inner agent suspensions are excluded.
    public var isLiveTopLevelQuestion: Bool {
        guard pendingToolCallIds.isEmpty, suspendedToolCallIds.count == 1,
              let id = suspendedToolCallIds.first else { return false }
        let matchingCalls = currentTurnMessages.flatMap(\.toolCalls).filter { $0.id == id }
        let placeholders = messages.filter {
            $0.role == .toolResult && $0.toolCallId == id && $0.text == Self.suspensionPlaceholder
        }
        guard matchingCalls.count == 1, matchingCalls[0].name == "ask_user",
              placeholders.count == 1 else { return false }
        var calls: [String: Int] = [:]
        var results: [String: Int] = [:]
        for message in messages {
            if message.role == .assistant {
                for call in message.toolCalls { calls[call.id, default: 0] += 1 }
            } else if message.role == .toolResult {
                guard let callID = message.toolCallId else { return false }
                if message.text == Self.suspensionPlaceholder && callID != id { return false }
                results[callID, default: 0] += 1
            }
        }
        return calls == results
    }
}
