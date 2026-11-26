import Foundation

// MARK: - Chat Session

/// 消息读取健康态：读取时发现损坏行则非 healthy。
/// 非 healthy 的会话禁止普通覆盖保存（避免用缺内容的数组覆盖库内原行），
/// 只能走显式修复流程
public enum MessageLoadHealth: Equatable, Sendable {
    case healthy
    /// 部分消息行无法解码：已跳过这些行，原始坏行仍保留在库中
    case partiallyCorrupted(skipped: Int)
    /// 旧格式整包 JSON 无法解码
    case corruptLegacyBlob
}

/// 聊天会话（按空间库持久化）
public struct ChatSession: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var messages: [ChatMessage]
    /// 消息是否已载入内存；messageOffset 为零时才包含完整历史。
    public var isMessagesLoaded = true
    /// In-memory page position. Never encoded into a backup or written as conversation data.
    public var messageOffset = 0
    /// Local restore generation; never exported. Old snapshots cannot overwrite restored records.
    public var restorationToken: String?
    /// 消息读取健康态（仅内存运行时状态，不持久化）
    public var messageLoadHealth: MessageLoadHealth = .healthy
    /// 隐藏会话（右键隐藏；列表默认不显示，设置页开启「显示隐藏对话」后可见）
    public var isHidden = false
    /// 置顶会话（右键置顶；列表置顶区优先展示）
    public var isPinned = false
    /// 归档会话（按工作区批量归档；主列表不显示，仅在「已归档对话」入口查看与恢复）。
    /// 独立于 `isHidden`：隐藏是用户主动忽略，归档是收纳入库，两者互不复用
    public var isArchived = false
    /// 所属对话工作区 id（UUID 字符串）：会话列表按此分组，文件类工具写入该工作区目录。
    /// nil 或未知 id = 默认工作区（旧数据兼容）
    public var workspaceId: String?
    /// Last resolved internal workflow, used only as a short-continuation hint. Legacy values decode unchanged.
    public var mode: ChatMode = .chat
    /// 自动审核开关（按会话生效）：开启后由系统审核待确认的工具调用，
    /// 符合明确规则时自动放行；旧数据缺省为关闭
    public var autoReviewEnabled = false
    /// 权限模式（能力上限）：只读 / 工作区内 / 完全权限。
    /// 旧数据缺省为完全权限以保持升级前行为；新会话由 UI 显式设为工作区内。
    public var allowsHostExecution: Bool
    public var dataPolicy: TaskDataPolicy = .configuredServices
    public var permissionMode: PermissionMode = .workspaceWrite
    /// 确认挂起快照（本轮停在需确认的工具调用上时写入；恢复执行/拒绝/停止后清除）
    public var pendingConfirmation: PendingConfirmationSnapshot?
    /// 结构化提问快照（引擎停在 ask_user 表单上时写入；作答/取消/停止后清除）
    public var pendingQuestion: PendingQuestionSnapshot?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        workspaceId: String? = nil,
        mode: ChatMode = .chat,
        autoReviewEnabled: Bool = false,
        permissionMode: PermissionMode = .workspaceWrite,
        dataPolicy: TaskDataPolicy = .configuredServices,
        allowsHostExecution: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.mode = mode
        self.autoReviewEnabled = autoReviewEnabled
        self.allowsHostExecution = allowsHostExecution
        self.dataPolicy = dataPolicy
        self.permissionMode = permissionMode
        self.messages = []
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// 旧数据兼容：isHidden / isPinned / isArchived / workspaceId / mode / autoReviewEnabled 缺省解码
    enum CodingKeys: String, CodingKey {
        case id, title, messages, isMessagesLoaded, isHidden, isPinned, isArchived, workspaceId, mode
        case autoReviewEnabled, permissionMode, dataPolicy, allowsHostExecution
        case pendingConfirmation, pendingQuestion, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        isMessagesLoaded = try c.decodeIfPresent(Bool.self, forKey: .isMessagesLoaded) ?? true
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        mode = try c.decodeIfPresent(ChatMode.self, forKey: .mode) ?? .chat
        autoReviewEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoReviewEnabled) ?? false
        allowsHostExecution = try c.decodeIfPresent(Bool.self, forKey: .allowsHostExecution) ?? true
        dataPolicy = try c.decodeIfPresent(TaskDataPolicy.self, forKey: .dataPolicy) ?? .configuredServices
        permissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
            ?? .dangerFullAccess
        pendingConfirmation = try c.decodeIfPresent(PendingConfirmationSnapshot.self, forKey: .pendingConfirmation)
        pendingQuestion = try c.decodeIfPresent(PendingQuestionSnapshot.self, forKey: .pendingQuestion)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    /// 自动根据第一条用户消息生成标题
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let first = messages.first(where: { $0.role == .user }) {
            let text = first.content.prefix(30)
            return text.count < first.content.count ? "\(text)..." : String(text)
        }
        return ""
    }
}

extension ChatSession {
    /// The caller supplies the loaded prefix, including the old answer for an edited question.
    public func branch(through index: Int? = nil, titleSuffix: String) -> ChatSession? {
        guard isMessagesLoaded, messageOffset == 0, messageLoadHealth == .healthy else { return nil }
        if let index, !messages.indices.contains(index) { return nil }
        var branch = ChatSession(title: displayTitle + titleSuffix, workspaceId: workspaceId, mode: mode,
                                 autoReviewEnabled: autoReviewEnabled, permissionMode: permissionMode,
                                 dataPolicy: dataPolicy, allowsHostExecution: allowsHostExecution)
        let prefix = messages.prefix(index.map { $0 + 1 } ?? messages.count)
        let pairs = prefix.map { (message: $0, newID: UUID()) }
        let ids = Dictionary(pairs.map { ($0.message.id, $0.newID) }, uniquingKeysWith: { first, _ in first })
        guard ids.count == pairs.count else { return nil }
        branch.messages = pairs.map { $0.message.branchCopy(id: $0.newID, identities: ids) }
        return branch
    }
}

// MARK: - Pending Confirmation Snapshot

/// 确认挂起快照：引擎停在 needsConfirmation 时随会话持久化。
/// 只有展示信息，没有调用回执或原引擎的审批句柄；重启后仅供人工核对，不能据此批准或重放。
public struct PendingConfirmationSnapshot: Codable, Equatable, Sendable {
    /// 挂起确认对应的助手消息 id（结果写回目标）
    public let messageId: UUID
    public let toolName: String
    /// 完整参数文本（确认卡片展示）
    public let argumentsDisplay: String
    /// 写类文件工具的变更预览（dry-run diff；旧会话数据无此字段解码为 nil）
    public let changePreview: FileChangePreview?
    /// 确认需求（类型/授权范围/硬确认原因/本轮授权键；旧会话数据解码为 nil，UI 回退为普通确认）
    public let requirement: ConfirmationRequirement?

    public init(
        messageId: UUID,
        toolName: String,
        argumentsDisplay: String,
        changePreview: FileChangePreview? = nil,
        requirement: ConfirmationRequirement? = nil
    ) {
        self.messageId = messageId
        self.toolName = toolName
        self.argumentsDisplay = argumentsDisplay
        self.changePreview = changePreview
        self.requirement = requirement
    }
}

// MARK: - Pending Question Snapshot

/// 结构化提问快照：引擎停在 ask_user 表单上时随会话持久化。
/// 重启后只有展示内容，没有原引擎的恢复句柄；只供人工核对，不能把答案注入新运行。
public struct PendingQuestionSnapshot: Codable, Equatable, Sendable {
    /// 提问对应的助手消息 id（结果写回目标）
    public let messageId: UUID
    /// 表单（QuestionForm 为 Codable，可整体序列化）
    public let form: QuestionForm

    public init(messageId: UUID, form: QuestionForm) {
        self.messageId = messageId
        self.form = form
    }
}

// MARK: - Chat Attachment

/// 对话消息附件：显示名 + 落地路径（图片可出缩略图，点击进图片浏览器）
public enum ChatMediaKind: String, Sendable {
    case image, video, audio, file

    public static func detect(_ source: String) -> Self {
        let path = URL(string: source)?.path ?? source
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"].contains(ext) { return .image }
        if ["mp4", "mov", "m4v", "webm", "mkv", "avi", "mpg", "mpeg", "3gp"].contains(ext) { return .video }
        if AttachmentService.audioExtensions.contains(ext) || ["opus", "caf", "mp4a"].contains(ext) { return .audio }
        return .file
    }
}

public struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
    public var mediaKind: ChatMediaKind {
        isImage ? .image : ChatMediaKind.detect(name) == .file ? ChatMediaKind.detect(path) : ChatMediaKind.detect(name)
    }
    public let id: UUID
    /// 显示用文件名（不含路径）
    public let name: String
    /// 落地后的绝对路径（引擎重试时据此重建消息文本）
    public let path: String
    public let isImage: Bool
    public let importWarning: Bool?
    public let sourceArtifactVersionID: UUID?
    public let sourceArtifactSpace: AppSpace?

    public init(id: UUID = UUID(), name: String, path: String, isImage: Bool, importWarning: Bool? = nil,
                sourceArtifactVersionID: UUID? = nil, sourceArtifactSpace: AppSpace? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.isImage = isImage
        self.importWarning = importWarning
        self.sourceArtifactVersionID = sourceArtifactVersionID
        self.sourceArtifactSpace = sourceArtifactSpace
    }
}

// MARK: - Task Completion Assessment

/// 完成评估状态：`succeeded` 只表示引擎正常结束；「用户要求的任务是否完成」需要额外依据
/// （实际执行回执 + 产物文件校验）。旧数据缺少完成评估时按 `.unassessed` 兼容。
public enum TaskCompletionStatus: String, Codable, Sendable {
    /// 未评估（普通聊天，或旧数据）
    case unassessed
    /// 源码已修改，但没有绑定当前源码版本的成功验证。
    case unverified
    /// 用户要求的任务已完成（声明的产物契约已满足）
    case completed
    /// 任务已开始执行，但缺少必需产物
    case incomplete
}

/// 完成评估：稳定 code + 参数，具体文案由 UI 层三语本地化，Core 不下发成品句子。
public struct TaskCompletionAssessment: Codable, Equatable, Sendable {
    /// 阻塞原因的稳定标识
    public enum Code: String, Codable, Sendable {
        /// 技能脚本执行失败（导入错误、缺依赖、非零退出等）
        case skillScriptFailed
        /// 技能声明的产物未生成
        case skillArtifactMissing
        /// 技能声明的产物不符合契约（不可读/格式不对/缺少必需字段）
        case skillArtifactInvalid
        case codeUnverified
        case codeRevisionChanged
        case codeVerificationFailed
        case codeChecksPassed
        case operationNeedsReview
        case requestedSourceMissing
        case sourceActionIncomplete
        case mailDeliveryUncertain
        case mailDeliveredCheckCopy
        case mailDraftNotSaved
        case mailSelectionAmbiguous
    }

    public let status: TaskCompletionStatus
    public let code: Code?
    /// 相关技能名
    public let skill: String?
    /// 相关路径（脚本相对路径或产物相对路径）
    public let path: String?
    /// 附加细节（如缺失字段名、退出码；不含文件正文）
    public let detail: String?

    public init(
        status: TaskCompletionStatus,
        code: Code? = nil,
        skill: String? = nil,
        path: String? = nil,
        detail: String? = nil
    ) {
        self.status = status
        self.code = code
        self.skill = skill
        self.path = path
        self.detail = detail
    }

    public static let unassessed = TaskCompletionAssessment(status: .unassessed)
    public static let completed = TaskCompletionAssessment(status: .completed)

    public var isIncomplete: Bool { status == .incomplete }
}

// MARK: - Answer Variation

/// 一次问答尝试的完整快照：重试/编辑重发产生多版本，UI 以 ‹ 1/2 › 切换查看。
/// 问句随版本保存——编辑重发后各版本的问句可能不同，切换时问句气泡同步显示对应原文
public struct AnswerVariation: Codable, Equatable, Sendable {
    public var providerTurn: ProviderTurnHistory?
    /// 该次尝试的问句原文
    public var question: String
    public var content: String
    public var attachments: [ChatAttachment]?
    public var trace: [DispatcherTraceEntry]?
    public var thoughts: String?
    public var reasoningTokenUsage: ReasoningTokenUsage?
    public var tokenCount: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var runStatus: TaskRunStatus?
    public var contextReport: RequestContextReport?
    /// 完成评估（可选字段：旧数据解码为 nil = 未评估）
    public var completion: TaskCompletionAssessment?
    public var taskRun: ProductTaskIdentity?
    public var sourceTaskRunID: UUID?

    public init(
        question: String,
        content: String,
        trace: [DispatcherTraceEntry]? = nil,
        thoughts: String? = nil,
        reasoningTokenUsage: ReasoningTokenUsage? = nil,
        tokenCount: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.question = question
        self.content = content
        self.trace = trace
        self.thoughts = thoughts
        self.reasoningTokenUsage = reasoningTokenUsage
        self.tokenCount = tokenCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// 从消息当前显示状态构建快照（question 由调用方提供）
    public init(question: String, message: ChatMessage) {
        self.providerTurn = message.providerTurn
        self.question = question
        self.content = message.content
        self.attachments = message.attachments
        self.trace = message.trace
        self.thoughts = message.thoughts
        self.reasoningTokenUsage = message.reasoningTokenUsage
        self.tokenCount = message.tokenCount
        self.inputTokens = message.inputTokens
        self.outputTokens = message.outputTokens
        self.runStatus = message.runStatus
        self.contextReport = message.contextReport
        self.completion = message.completion
        self.taskRun = message.taskRun
        self.sourceTaskRunID = message.sourceTaskRunID
    }
}

// MARK: - Chat Message

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var providerTurn: ProviderTurnHistory?
    public private(set) var id: UUID
    public private(set) var role: Role
    public var content: String
    public let timestamp: Date
    /// User opt-out survives later rounds so automatic extraction cannot revisit it.
    public var memoryExcluded: Bool?
    /// 调度执行轨迹（仅助手消息，可选字段兼容旧数据）
    public var trace: [DispatcherTraceEntry]?
    /// 本轮消耗的 Token 总数（仅助手消息；可选字段兼容旧数据）
    public var tokenCount: Int?
    /// 本轮输入（提示）Token 数（仅助手消息；可选字段兼容旧数据）
    public var inputTokens: Int?
    /// 本轮输出（补全）Token 数（仅助手消息；可选字段兼容旧数据）
    public var outputTokens: Int?
    /// 模型返回的推理文本与工具循环中间叙述，UI 以可收起区块展示。
    public var thoughts: String?
    /// 服务商上报的推理 Token 及覆盖情况，独立于可见文本长度。
    public var reasoningTokenUsage: ReasoningTokenUsage?
    /// 用户附件或助手生成的图片；旧数据缺省为 nil。
    public var attachments: [ChatAttachment]?
    /// Every answer version remains portable even when it is not currently shown.
    public var allAttachments: [ChatAttachment] {
        (attachments ?? []) + (variations ?? []).flatMap { $0.attachments ?? [] }
    }
    /// 重试/编辑重发的多版本回答记录（nil = 单一版本，无切换 UI）
    public var variations: [AnswerVariation]?
    /// 当前显示的版本序号（variations 非空时有效；content 等字段镜像该版本）
    public var activeVariationIndex: Int
    public var runStatus: TaskRunStatus?
    public var contextReport: RequestContextReport?
    /// 完成评估（可选字段：旧数据缺少时解码为 nil = 未评估，不因缺字段丢弃消息）
    public var completion: TaskCompletionAssessment?
    public var taskRun: ProductTaskIdentity?
    /// A copied answer is context, not another execution of its source task.
    public var sourceTaskRunID: UUID?

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        trace: [DispatcherTraceEntry]? = nil,
        tokenCount: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        thoughts: String? = nil,
        reasoningTokenUsage: ReasoningTokenUsage? = nil,
        attachments: [ChatAttachment]? = nil,
        variations: [AnswerVariation]? = nil,
        activeVariationIndex: Int = 0,
        runStatus: TaskRunStatus? = nil,
        contextReport: RequestContextReport? = nil,
        completion: TaskCompletionAssessment? = nil,
        taskRun: ProductTaskIdentity? = nil,
        sourceTaskRunID: UUID? = nil,
        memoryExcluded: Bool? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.trace = trace
        self.tokenCount = tokenCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughts = thoughts
        self.reasoningTokenUsage = reasoningTokenUsage
        self.attachments = attachments
        self.variations = variations
        self.activeVariationIndex = activeVariationIndex
        self.runStatus = runStatus
        self.contextReport = contextReport
        self.completion = completion
        self.taskRun = taskRun
        self.sourceTaskRunID = sourceTaskRunID
        self.memoryExcluded = memoryExcluded
    }

    public var excludesRoundFromMemory: Bool {
        memoryExcluded == true || contextReport?.resourceContext?.excludesMemory == true ||
            variations?.contains { $0.contextReport?.resourceContext?.excludesMemory == true } == true
    }

    fileprivate func branchCopy(id newID: UUID, identities: [UUID: UUID]) -> ChatMessage {
        func remap(_ original: RequestContextReport?) -> RequestContextReport? {
            guard var report = original else { return nil }
            report.includedHistory = report.includedHistory.compactMap { identities[$0] }
            report.omittedHistory = report.omittedHistory.compactMap { identities[$0] }
            report.truncatedHistory = report.truncatedHistory.compactMap { identities[$0] }
            report.mailAnswerBinding = nil
            return report
        }
        var copy = self
        copy.id = newID
        copy.sourceTaskRunID = taskRun?.id ?? sourceTaskRunID ?? id
        copy.taskRun = nil
        copy.providerTurn = nil
        copy.contextReport = remap(contextReport)
        copy.variations = variations?.map { version in
            var copy = version
            copy.sourceTaskRunID = version.taskRun?.id ?? version.sourceTaskRunID ?? id
            copy.taskRun = nil
            copy.providerTurn = nil
            copy.contextReport = remap(version.contextReport)
            return copy
        }
        return copy
    }

    /// 分支或导出后，所有回答版本仅保留可见记录。
    public mutating func clearProviderHistory() {
        providerTurn = nil
        contextReport?.mailAnswerBinding = nil
        if var versions = variations {
            for index in versions.indices {
                versions[index].providerTurn = nil
                versions[index].contextReport?.mailAnswerBinding = nil
            }
            variations = versions
        }
    }

    /// 将运行中的助手消息转为可恢复的错误消息：保持身份与已有正文，错误附在末尾。
    /// 前台与 daemon 共用，确保失败后仍能按原消息 ID 落盘和重试。
    public func appendingError(_ errorText: String) -> ChatMessage {
        let updatedContent = content.isEmpty
            ? errorText
            : content + "\n\n⚠️ " + errorText
        var replacement = self
        replacement.role = .error
        replacement.content = updatedContent
        replacement.providerTurn = nil
        replacement.runStatus = .failed
        replacement.completion = nil
        if var versions = replacement.variations,
           activeVariationIndex >= 0,
           activeVariationIndex < versions.count {
            versions[activeVariationIndex].content = updatedContent
            versions[activeVariationIndex].providerTurn = nil
            versions[activeVariationIndex].thoughts = thoughts
            versions[activeVariationIndex].reasoningTokenUsage = reasoningTokenUsage
            versions[activeVariationIndex].trace = trace
            versions[activeVariationIndex].runStatus = .failed
            versions[activeVariationIndex].contextReport = contextReport
            replacement.variations = versions
        }
        return replacement
    }

    // MARK: Codable（旧数据兼容：新增字段缺省解码）

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, memoryExcluded
        case trace, tokenCount, inputTokens, outputTokens, thoughts, reasoningTokenUsage, attachments
        case variations, activeVariationIndex, runStatus, contextReport, completion
        case taskRun, sourceTaskRunID, providerTurn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        memoryExcluded = try c.decodeIfPresent(Bool.self, forKey: .memoryExcluded)
        trace = try c.decodeIfPresent([DispatcherTraceEntry].self, forKey: .trace)
        tokenCount = try c.decodeIfPresent(Int.self, forKey: .tokenCount)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        thoughts = try c.decodeIfPresent(String.self, forKey: .thoughts)
        reasoningTokenUsage = try c.decodeIfPresent(ReasoningTokenUsage.self, forKey: .reasoningTokenUsage)
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments)
        variations = try c.decodeIfPresent([AnswerVariation].self, forKey: .variations)
        runStatus = try c.decodeIfPresent(TaskRunStatus.self, forKey: .runStatus)
        contextReport = try c.decodeIfPresent(RequestContextReport.self, forKey: .contextReport)
        completion = try c.decodeIfPresent(TaskCompletionAssessment.self, forKey: .completion)
        taskRun = try c.decodeIfPresent(ProductTaskIdentity.self, forKey: .taskRun)
        sourceTaskRunID = try c.decodeIfPresent(UUID.self, forKey: .sourceTaskRunID)
        providerTurn = try c.decodeIfPresent(ProviderTurnHistory.self, forKey: .providerTurn)
        let decodedIndex = try c.decodeIfPresent(Int.self, forKey: .activeVariationIndex) ?? 0
        // 越界序号（异常数据）回落 0
        if let variations, !variations.isEmpty {
            activeVariationIndex = min(max(decodedIndex, 0), variations.count - 1)
        } else {
            activeVariationIndex = 0
        }
    }

    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case error
    }
}
