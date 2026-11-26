import Foundation

// MARK: - Mail Failure Diagnosis

/// 邮件操作阶段（诊断与界面提示用，说明失败发生在哪一步）。
public enum MailOperationStage: String, Sendable, Equatable, CaseIterable {
    case connect
    case authenticate
    case listFolders
    case createFolder
    case renameFolder
    case deleteFolder
    case folderStatus
    case select
    case fetchSummaries
    case fetchBody
    case fetchAttachment
    case search
    case storeFlags
    case move
    case delete
    case send
    case appendDraft
}

/// 失败类别：区分「服务器拒绝」「响应缺失/无法解析」「超时」「连接关闭」等，
/// 避免把「服务器回 OK 但数据不可用」误报成服务器拒绝。
public enum MailFailureKind: String, Sendable, Equatable {
    /// 服务器明确拒绝请求（`NO` / `BAD`）。
    case serverRejected
    /// 服务器回了 `OK` 但没有可解析的有效数据，或响应形态无法解读。
    case malformedResponse
    /// 超时（连接已被主动断开）。
    case timedOut
    /// 连接被关闭。
    case connectionClosed
    /// 会话状态不正确（如未认证/未选中就发命令）。
    case invalidState
    /// 其他底层连接/传输失败。
    case transport
}

/// 邮件服务器诊断信息（项目自有类型，不暴露具体协议库）。
///
/// 保留「操作阶段 + 服务器状态 + 脱敏原文 + 失败类别 + 文件夹上下文」，
/// 供界面指出失败位置与下一步动作；`errorDescription` 为脱敏英文，供日志与智体使用。
///
/// 脱敏约定：`detail` 只保留服务器说明原文的截断（不含密码/授权码/邮件正文/完整协议流量）；
/// `folder` 只带显示名（末段），不带完整原始路径。
public struct MailServerDiagnostic: Error, LocalizedError, Sendable, Equatable {
    public let stage: MailOperationStage
    /// 服务器状态（`NO` / `BAD` / `OK`）；缺失为 nil。
    public let status: String?
    /// 服务器说明原文（已脱敏与限长）。
    public let detail: String
    public let kind: MailFailureKind
    /// 失败所在文件夹的显示名（脱敏）。
    public let folder: String?

    public init(
        stage: MailOperationStage,
        status: String?,
        detail: String,
        kind: MailFailureKind,
        folder: String?
    ) {
        self.stage = stage
        self.status = status
        self.detail = detail
        self.kind = kind
        self.folder = folder
    }

    /// 日志/智体用英文描述（用户可见文案由 UI 经 `MailErrorText` 三语映射）。
    public var errorDescription: String? {
        var parts = ["Mail \(stage.rawValue) failed"]
        if let folder { parts.append("folder=\(folder)") }
        if let status { parts.append("status=\(status)") }
        return parts.joined(separator: " ") + ": \(detail) [\(kind.rawValue)]"
    }
}

// MARK: - Mail Protocol Error

/// 邮件协议层错误（与具体协议库解耦）。
public enum MailProtocolError: LocalizedError, Equatable {
    case notConnected
    case authenticationFailed(String)
    case connectionFailed(String)
    case tlsUnsupported
    case invalidResponse(String)
    case sendFailed(String)
    /// 操作在预算内没有返回，连接已被主动断开（`label` 为出超时的操作名）。
    case timedOut(String)
    /// SMTP 投递超时：服务器可能已经收下这封邮件，也可能没有。
    ///
    /// 与 `timedOut` 分开是因为调用方必须区别对待——不能按失败提示用户重发，
    /// 否则会造成重复投递（见 `MailSyncService.send`）。
    case sendResultUnknown(String)
    /// 邮件正文超出单封上限：不下载，直接给出可操作提示（换用网页端或提高上限）。
    case messageTooLarge(String)

    /// 是否为超时类失败（含「投递结果未知」）。
    ///
    /// 调用方用它把超时与其他失败分开处理——超时意味着连接已被主动断开，
    /// 且对写操作而言远端状态可能已经改变。
    public var isTimeout: Bool {
        switch self {
        case .timedOut, .sendResultUnknown:
            return true
        default:
            return false
        }
    }

    /// 面向模型与日志的英文描述。
    ///
    /// 注意：这是**用户可见文案的兜底**，UI 必须经 `MailErrorText` 映射为三语；
    /// 只有日志与智体工具输出才直接使用本属性。
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the mail server."
        case .authenticationFailed(let detail):
            return "Mail authentication failed: \(detail)"
        case .connectionFailed(let detail):
            return "Mail connection failed: \(detail)"
        case .tlsUnsupported:
            return "This encryption mode is not supported for the mail connection."
        case .invalidResponse(let detail):
            return "Unexpected mail server response: \(detail)"
        case .sendFailed(let detail):
            return "Sending the mail failed: \(detail)"
        case .timedOut(let label):
            return "The mail operation timed out: \(label)"
        case .sendResultUnknown(let detail):
            return "The delivery result is unknown (the server may have accepted the message): \(detail)"
        case .messageTooLarge(let detail):
            return "The message body is too large to download: \(detail)"
        }
    }
}

// MARK: - Remote Folder

/// 服务器侧文件夹（协议层 DTO，未落库）。
public struct RemoteMailFolder: Sendable, Equatable {
    /// 服务器上的完整路径，为 `LIST` 返回时的**原始字节名**（Modified UTF-7 可能仍处于编码态）。
    ///
    /// 该值原样落库并作为文件夹身份使用；**不得**直接提交给协议命令——
    /// 具体实现负责在调用边界把它转换为协议要求的形态（见
    /// `MailFoundationAdapter.sessionMailbox(from:)`）。
    public let path: String
    /// 展示名（路径最后一段）。
    public let name: String
    /// 推断出的语义角色。
    public let role: MailFolderRole
    /// 层级分隔符（如 `/`、`.`）。
    public let delimiter: String?
    /// 是否可选（`\Noselect` 的容器不可选）。
    public let isSelectable: Bool

    public init(
        path: String,
        name: String,
        role: MailFolderRole = .other,
        delimiter: String? = nil,
        isSelectable: Bool = true
    ) {
        self.path = path
        self.name = name
        self.role = role
        self.delimiter = delimiter
        self.isSelectable = isSelectable
    }
}

// MARK: - Remote Status / Summaries / Body

/// 文件夹状态（SELECT/STATUS 结果，用于增量同步游标）。
public struct RemoteFolderStatus: Codable, Sendable, Equatable {
    /// UIDVALIDITY：变化表示本地该文件夹需全量重建。
    public let uidValidity: UInt32?
    /// 下一封新邮件的 UID（增量拉取上界）。
    public let uidNext: UInt32?
    public let messageCount: Int
    public let unreadCount: Int

    public init(uidValidity: UInt32?, uidNext: UInt32?, messageCount: Int, unreadCount: Int) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.messageCount = messageCount
        self.unreadCount = unreadCount
    }
}

/// 移动结果：目标文件夹里的新 UID。
///
/// `MOVE`（RFC 6851）会在目标文件夹重新分配 UID，源 UID 不再有效。服务器支持
/// `UIDPLUS`（RFC 4315）时回 `COPYUID` 响应码给出目标 UID；不支持时 `uid` 为 nil，
/// 调用方必须重新抓取目标邮件来获得正确 UID，不能沿用源 UID。
public struct RemoteMoveResult: Sendable, Equatable {
    /// 目标文件夹中的新 UID；nil = 服务器未回 `COPYUID`。
    public let uid: UInt32?
    /// 目标文件夹的 UIDVALIDITY（服务器回 `COPYUID` 时才有）；与本地不一致表示 UID 空间已重建。
    public let uidValidity: UInt32?

    public init(uid: UInt32?, uidValidity: UInt32?) {
        self.uid = uid
        self.uidValidity = uidValidity
    }

    /// 服务器没有给出目标 UID（需要重新抓取目标文件夹）。
    public static let unknown = RemoteMoveResult(uid: nil, uidValidity: nil)
}

/// 服务器侧邮件摘要（协议层 DTO，未落库）。
public struct RemoteMessageSummary: Sendable, Equatable {
    public let uid: UInt32
    public let messageId: String?
    public let subject: String
    public let from: [MailAddress]
    /// ENVELOPE 的 `Reply-To`（回复时优先使用；空表示回落到 `From`）。
    public let replyTo: [MailAddress]
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let date: Date?
    public let isRead: Bool
    public let isStarred: Bool
    public let sizeBytes: Int
    public let snippet: String
    public let references: String?

    public init(
        uid: UInt32,
        messageId: String?,
        subject: String,
        from: [MailAddress],
        replyTo: [MailAddress] = [],
        to: [MailAddress],
        cc: [MailAddress],
        date: Date?,
        isRead: Bool,
        isStarred: Bool,
        sizeBytes: Int,
        snippet: String,
        references: String? = nil
    ) {
        self.uid = uid
        self.messageId = messageId
        self.subject = subject
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.date = date
        self.isRead = isRead
        self.isStarred = isStarred
        self.sizeBytes = sizeBytes
        self.snippet = snippet
        self.references = references
    }
}

/// 服务器侧附件元数据（v1 只记录元数据，不落二进制）。
public struct RemoteAttachment: Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int
    public let contentId: String?
    public let isInline: Bool
    public let partID: String?

    public init(filename: String, mimeType: String, sizeBytes: Int, contentId: String?, isInline: Bool, partID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.contentId = contentId
        self.isInline = isInline
        self.partID = partID
    }
}

/// 邮件正文与附件（解析 MIME 后）。
public struct RemoteMessageBody: Sendable, Equatable {
    public let textBody: String?
    public let htmlBody: String?
    /// 头部解析出的 `References` 线程链（缺失为 nil）；回复时保留既有链。
    public let references: String?
    public let attachments: [RemoteAttachment]
    /// Complete original retained only by the bounded whole-message fallback.
    /// Its attachments use local part IDs and must be committed with these bytes.
    public let rawMessage: Data?

    public init(
        textBody: String?,
        htmlBody: String?,
        references: String? = nil,
        attachments: [RemoteAttachment],
        rawMessage: Data? = nil
    ) {
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.references = references
        self.attachments = attachments
        self.rawMessage = rawMessage
    }
}

/// 可写回的 IMAP 系统标记（v1 用到的子集）。
public enum MailFlag: String, Sendable, CaseIterable {
    case seen
    case flagged
    case deleted
}

// MARK: - Outgoing Mail

/// 待发送邮件（协议层 DTO）。
///
/// 只承载「语义字段」，RFC 5322 / MIME 的序列化由实现方负责（MailFoundation +
/// MimeFoundation），从而让上层不依赖具体 MIME 库。
public struct OutgoingMail: Sendable, Equatable {
    /// 发件人（`From` 信封与头部）。
    public let from: MailAddress
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let bcc: [MailAddress]
    public let subject: String
    /// Always provide a plain alternative, including for styled messages.
    public let bodyText: String
    public let htmlBody: String?
    /// 回复所用 `In-Reply-To`（原始 Message-ID）。
    public let inReplyTo: String?
    /// 回复所用 `References`（原始 References + Message-ID）。
    public let references: String?

    /// 本次投递使用的 `Message-ID`。
    ///
    /// 由调用方生成后**贯穿** SMTP 报文、本地「已发送」副本与投递凭证，使三者身份一致：
    /// 若报文头部由 MIME/SMTP 层另行生成，凭证里的 ID 就与收件方收到的 ID 不同，
    /// 用户拿凭证去服务器核对时会对不上。
    public let messageId: String?
    public let attachments: [MailDraftAttachment]
    public var serializedData: Data?

    public init(
        from: MailAddress,
        to: [MailAddress],
        cc: [MailAddress] = [],
        bcc: [MailAddress] = [],
        subject: String,
        bodyText: String,
        htmlBody: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil,
        messageId: String? = nil,
        attachments: [MailDraftAttachment] = [],
        serializedData: Data? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyText = bodyText
        self.htmlBody = htmlBody
        self.inReplyTo = inReplyTo
        self.references = references
        self.messageId = messageId
        self.attachments = attachments; self.serializedData = serializedData
    }

    /// 信封收件人（`To` + `Cc` + `Bcc`，Bcc 不进头部）。
    public var recipients: [MailAddress] {
        to + cc + bcc
    }
}

// MARK: - Shared Connection Lifecycle

/// IMAP / SMTP 客户端共有的连接生命周期。
///
/// 抽出它只是为了让「建连 + 登录」与超时守卫（`MailDeadline`）能同时作用于两类
/// 客户端，不新增任何能力：两个协议各自的方法声明保持不变，实现方无需改动。
public protocol MailConnectedClient: Sendable {
    /// 建立连接（按账号加密方式处理隐式 TLS / STARTTLS）。
    func connect() async throws

    /// 使用用户名 + 密码/授权码登录。
    func authenticate(username: String, password: String) async throws

    /// 断开连接（幂等）。
    func disconnect() async
}

// MARK: - Mail Protocol Client

/// 邮件协议客户端边界：仅暴露本项目自定的最小接口，
/// 具体协议库（MailFoundation）只在 `MailFoundationAdapter` 中被引用，
/// 便于日后替换实现或降级为自研 `Network.framework` 客户端。
///
/// 生命周期：`connect` → `authenticate` → 操作 → `disconnect`。
/// 文件夹操作按 `folderPath` 定位；实现方负责在需要时选中（select）该文件夹。
///
/// **路径契约**：协议方法收到的 `path` / `toPath` 都是 `listFolders()` 返回并已落库的
/// **原始路径**。实现方必须在协议调用边界完成到线路格式的转换（例如 Modified UTF-7
/// 解码后交由协议库编码），不得要求上层先转换，也不得假设路径已是最终线路形态。
/// 本协议可抛出的失败除 `MailProtocolError` 外还包括 `MailServerDiagnostic`
/// （保留阶段、服务器状态、脱敏说明与失败类别），上层应优先按诊断展示。
public protocol MailProtocolClient: MailConnectedClient {
    /// 建立连接（按账号加密方式处理隐式 TLS / STARTTLS）。
    func connect() async throws

    /// 使用用户名 + 密码/授权码登录。
    func authenticate(username: String, password: String) async throws

    /// 发现账号下全部文件夹。
    func listFolders() async throws -> [RemoteMailFolder]
    func createFolder(path: String) async throws
    func renameFolder(path: String, toPath: String) async throws
    func deleteFolder(path: String) async throws

    /// 读取文件夹状态（UIDVALIDITY / UIDNEXT / 计数）。
    func folderStatus(path: String) async throws -> RemoteFolderStatus

    /// 拉取一批邮件摘要；`sinceUID` 非空时只取 UID 大于它的增量。
    ///
    /// 单次调用最多返回 `limit` 条，调用方循环取批以便在批间响应取消与上报进度
    /// （一次 `UID FETCH 1:*` 在大文件夹上既不可中断也不可观察）。
    func fetchSummaries(
        path: String,
        sinceUID: UInt32?,
        limit: Int
    ) async throws -> [RemoteMessageSummary]

    /// Exact UID batches avoid scanning huge empty UID ranges during history backfill.
    func fetchSummaries(path: String, uids: [UInt32]) async throws -> [RemoteMessageSummary]
    func recentSummaries(path: String, messageCount: Int, limit: Int) async throws -> [RemoteMessageSummary]

    /// 拉取一封邮件的正文与附件元数据。
    ///
    /// 实现方**不得下载附件二进制**（附件只落元数据）并应遵守 `maxBytes` 上限：
    /// 超限时抛 `MailProtocolError.messageTooLarge`，而不是把超大邮件读进内存。
    func fetchBody(
        path: String,
        uid: UInt32,
        maxBytes: Int
    ) async throws -> RemoteMessageBody

    func fetchAttachment(path: String, uid: UInt32, partID: String, maxBytes: Int) async throws -> Data

    /// Bounded BODY.PEEK[] fetch for a portable original, including all MIME parts.
    func fetchRawMessage(path: String, uid: UInt32, maxBytes: Int) async throws -> Data

    /// 是否存在指定标记的邮件 UID（升序）；标记回滚与删除对账用。
    func searchUIDs(path: String, flag: MailFlag) async throws -> [UInt32]

    /// 文件夹内全部邮件的 UID（升序）。
    ///
    /// 供服务器不提供 `UIDNEXT` 时推断已存在 UID 的真实上界：稀疏 UID 下不能靠
    /// 「本批返回条数少于一批」判断扫描尽头，否则会漏掉后面的邮件（见 `MailSyncService.sync`）。
    func allUIDs(path: String) async throws -> [UInt32]

    /// 增删标记（已读/星标/删除）。
    func storeFlags(path: String, uid: UInt32, add: [MailFlag], remove: [MailFlag]) async throws

    /// 移动到另一文件夹（IMAP UID MOVE；服务器不支持 MOVE 时实现方可回落 COPY + DELETE）。
    ///
    /// 返回目标文件夹的新 UID（服务器支持 `UIDPLUS` 时由 `COPYUID` 给出）。
    func moveMessage(path: String, uid: UInt32, toPath: String) async throws -> RemoteMoveResult

    /// 服务器是否支持 `UIDPLUS`（RFC 4315）。
    ///
    /// 支持时可用 `UID EXPUNGE <uid>` 只删除目标邮件；不支持时调用方必须自行
    /// 保护同文件夹内其他已标 `\Deleted` 的邮件（见 `MailSyncService.deleteMessage`）。
    func supportsUIDPlus() async -> Bool
    func appendDraft(path: String, data: Data) async throws -> RemoteDraftAppendResult
    /// Exact Message-ID search restricted to messages still marked as drafts.
    func draftUIDs(path: String, messageID: String) async throws -> [UInt32]

    /// 仅标记 `\Deleted`，**不执行 EXPUNGE**。
    ///
    /// 不在这里 EXPUNGE 是有意的：不带 UID 的 `EXPUNGE` 会删掉该文件夹里所有已标
    /// `\Deleted` 的邮件（RFC 3501 §6.4.3），单个删除会连带清空其他客户端的待删邮件。
    /// 真正的清除由调用方在选定安全方式后执行。
    func markDeleted(path: String, uid: UInt32) async throws

    /// 清除指定 UID 的 `\Deleted` 标记（删除失败时的回滚）。
    func unmarkDeleted(path: String, uid: UInt32) async throws

    /// 删除该文件夹内**只有这些 UID** 的 `\Deleted` 邮件（`UID EXPUNGE`，需 `UIDPLUS`）。
    func expungeUIDs(path: String, uids: [UInt32]) async throws

    /// 清除该文件夹内**所有**已标 `\Deleted` 的邮件（不带 UID 的 `EXPUNGE`）。
    ///
    /// 破坏性最强的一条命令，调用方必须先确认没有其他待删邮件。
    func expungeAllDeleted(path: String) async throws

    /// 断开连接（幂等）。
    func disconnect() async
}

// MARK: - Mail Send Client

/// 发信协议边界（SMTP）。
///
/// 与 `MailProtocolClient`（IMAP）分开：账号的 SMTP 是独立端点，可指向不同主机；
/// 生命周期同样为 `connect` → `authenticate` → `send` → `disconnect`。
///
/// 已发送副本仍由上层 `MailSyncService` 落到本地缓存；APPEND 的本地补丁
/// 仅服务于显式服务器草稿，不自动上传「已发送」副本。
public protocol MailSendClient: MailConnectedClient {
    /// 建立连接（按加密方式处理隐式 TLS / STARTTLS）。
    func connect() async throws

    /// 使用用户名 + 密码/授权码登录。
    func authenticate(username: String, password: String) async throws

    /// 发送一封邮件（实现方负责 MIME 序列化与信封地址）。
    func send(_ message: OutgoingMail) async throws

    /// 断开连接（幂等）。
    func disconnect() async
}
public extension MailProtocolClient {
    func recentSummaries(path: String, messageCount: Int, limit: Int) async throws -> [RemoteMessageSummary] {
        guard messageCount > 0, limit > 0 else { return [] }
        let recent = try await allUIDs(path: path).sorted().suffix(limit)
        return try await fetchSummaries(path: path, uids: Array(recent))
    }
    func appendDraft(path: String, data: Data) async throws -> RemoteDraftAppendResult { throw MailServerDraftError.unsupported }
    func draftUIDs(path: String, messageID: String) async throws -> [UInt32] { throw MailServerDraftError.unsupported }
    func createFolder(path: String) async throws { throw MailFolderMutationError.unsupported }
    func renameFolder(path: String, toPath: String) async throws { throw MailFolderMutationError.unsupported }
    func deleteFolder(path: String) async throws { throw MailFolderMutationError.unsupported }

    func fetchRawMessage(path: String, uid: UInt32, maxBytes: Int) async throws -> Data {
        throw MailExportError.incomplete
    }
    func fetchSummaries(path: String, uids: [UInt32]) async throws -> [RemoteMessageSummary] {
        var result: [RemoteMessageSummary] = []
        for uid in Set(uids).sorted() where uid > 0 {
            try Task.checkCancellation()
            result += try await fetchSummaries(path: path, sinceUID: uid == 1 ? nil : uid - 1, limit: 1)
                .filter { $0.uid == uid }
        }
        return result
    }

    func fetchAttachment(path: String, uid: UInt32, partID: String, maxBytes: Int) async throws -> Data {
        throw MailProtocolError.invalidResponse("Attachment download is not supported by this client.")
    }
}
