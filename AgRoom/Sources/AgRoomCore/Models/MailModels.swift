import Foundation

/// 所选范围内的本地查询。所有过滤都在数据库分页前执行。
public struct MailListFilter: Codable, Sendable, Equatable {
    public var query: String
    public var unreadOnly: Bool
    public var starredOnly: Bool
    public var attachmentsOnly: Bool
    public var sender: String
    public var after: Date?
    public var before: Date?
    public var includeBody: Bool = true
    public var recipient: String = ""
    public var attachmentName: String = ""
    public var minBytes: Int? = nil
    public var maxBytes: Int? = nil

    public init(query: String = "", unreadOnly: Bool = false, starredOnly: Bool = false,
                attachmentsOnly: Bool = false, sender: String = "", after: Date? = nil, before: Date? = nil,
                includeBody: Bool = true, recipient: String = "", attachmentName: String = "", minBytes: Int? = nil, maxBytes: Int? = nil) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.unreadOnly = unreadOnly; self.starredOnly = starredOnly; self.attachmentsOnly = attachmentsOnly
        self.sender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        self.after = after; self.before = before
        self.includeBody = includeBody; self.recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        self.attachmentName = attachmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minBytes = minBytes; self.maxBytes = maxBytes
    }
}

public enum MailSearchScope: String, Codable, CaseIterable, Sendable { case folder, account, inbox, space, importBatch }

public enum MailQueryLocation: Codable, Sendable, Equatable {
    case folder(UUID), account(UUID), inbox, space
    case importBatch(archiveID: UUID, batchID: UUID)
    public var scope: MailSearchScope {
        switch self { case .folder: .folder; case .account: .account; case .inbox: .inbox; case .space: .space; case .importBatch: .importBatch }
    }
}

public struct MailSavedSearch: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var filter: MailListFilter
    public var location: MailQueryLocation
    public var updatedAt: Date
    public init(id: UUID = UUID(), name: String, filter: MailListFilter, location: MailQueryLocation, updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.filter = filter; self.location = location; self.updatedAt = updatedAt
    }
}

public enum MailSearchError: String, Error, Sendable { case invalidFilter, invalidName, duplicateName, unavailable, capacity, changed }

public enum MailBatchAction: Sendable, Equatable {
    case read(Bool), star(Bool), move(UUID), moveToRole(MailFolderRole), permanentlyDelete

    /// 只有设置标记可直接重试。移动/删除发生传输错误时需先核实服务器结果。
    public var allowsDirectRetry: Bool {
        switch self { case .read, .star: true; default: false }
    }
}

public struct MailBatchFailure: Sendable {
    public let messageID: UUID
    public let error: any Error
}

public struct MailBatchResult: Sendable {
    public var succeeded: [UUID] = []
    public var failures: [MailBatchFailure] = []
    public var unprocessed: [UUID] = []
    public var undoReceipt: MailOperationUndoReceipt? = nil
    public init() {}
}

// MARK: - Mail Account Enums

/// 账号认证方式。v1 仅支持密码/授权码；`oauth2` 为扩展点预留。
public enum MailAuthKind: String, Codable, Sendable, CaseIterable {
    case password
    case oauth2
}

/// 连接加密方式。远程明文（`none`）仅用于本机调试，UI 需明确警示。
public enum MailSecurity: String, Codable, Sendable, CaseIterable {
    /// 明文连接（无 TLS）。
    case none
    /// 连接后经 STARTTLS 升级加密。
    case startTLS
    /// 隐式 TLS（IMAPS 993 / SMTPS 465）。
    case tls
}

/// Shared by the configuration UI, connection tests and live protocol adapters.
public enum MailServerConfiguration {
    public enum ProtocolKind: String, Sendable { case imap, smtp }

    public static func validate(port: Int, security: MailSecurity, protocolKind: ProtocolKind) throws {
        guard (1...65535).contains(port) else { throw MailConfigurationError.invalidPort(protocolKind) }
        if (protocolKind == .smtp && port == 465 || protocolKind == .imap && port == 993), security != .tls {
            throw MailConfigurationError.implicitTLSRequired(protocolKind, port)
        }
    }

    public static func validate(_ account: MailAccount) throws {
        try validate(port: account.imapPort, security: account.imapSecurity, protocolKind: .imap)
        if !account.smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try validate(port: account.smtpPort, security: account.smtpSecurity, protocolKind: .smtp)
        }
    }
}

public enum MailConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidPort(MailServerConfiguration.ProtocolKind)
    case implicitTLSRequired(MailServerConfiguration.ProtocolKind, Int)
    public var errorDescription: String? {
        switch self {
        case .invalidPort(let kind): return "Invalid \(kind.rawValue.uppercased()) port; use a number between 1 and 65535."
        case .implicitTLSRequired(let kind, let port): return "\(kind.rawValue.uppercased()) port \(port) requires implicit SSL/TLS, not STARTTLS or plaintext."
        }
    }
}

public struct MailConnectionTestError: Error, Sendable {
    public enum Stage: String, Sendable { case imap, folders, smtp }
    public let stage: Stage
    public let underlying: any Error
    public init(stage: Stage, underlying: any Error) { self.stage = stage; self.underlying = underlying }
}

/// 文件夹语义角色（用于本地归类与默认选中）。
public enum MailFolderRole: String, Codable, Sendable, CaseIterable {
    case inbox
    case sent
    case drafts
    case trash
    case junk
    case archive
    case other
}

/// 邮件正文的本地缓存状态（正文按需拉取）。
public enum MailBodyState: String, Codable, Sendable {
    /// 仅元数据，正文未拉取。
    case none
    /// 正文已就绪。
    case ready
    /// 正文拉取失败。
    case failed
}

// MARK: - Address

/// 邮件的收发件人（名称 + 地址）。
public struct MailAddress: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }

    /// 展示用：有名称时「名称 <地址>」，否则仅地址。
    public var isValid: Bool {
        guard name.rangeOfCharacter(from: .controlCharacters) == nil,
              address.rangeOfCharacter(from: .controlCharacters) == nil,
              address.count <= 254, !address.contains(where: { $0.isWhitespace || $0.isNewline }),
              !address.contains(".."), !address.contains("<"), !address.contains(">") else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64,
              !parts[0].hasPrefix("."), !parts[0].hasSuffix(".") else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
    }

    public var display: String {
        name.isEmpty ? address : "\(name) <\(address)>"
    }
}

// MARK: - Account

public enum MailAccountSource: String, Codable, Sendable {
    case imap, localArchive
}

/// 邮箱账号元数据。**不含密码**：密码/授权码只存 Keychain。
public struct MailAccount: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var emailAddress: String
    public var imapHost: String
    public var imapPort: Int
    public var imapSecurity: MailSecurity
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpSecurity: MailSecurity
    public var username: String
    public var authKind: MailAuthKind
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Missing in legacy serialized accounts; nil has the same meaning as IMAP.
    public var sourceKind: MailAccountSource?
    public var isLocalArchive: Bool { sourceKind == .localArchive }

    public init(
        id: UUID = UUID(),
        displayName: String,
        emailAddress: String,
        imapHost: String,
        imapPort: Int = 993,
        imapSecurity: MailSecurity = .tls,
        smtpHost: String,
        smtpPort: Int = 587,
        smtpSecurity: MailSecurity = .startTLS,
        username: String,
        authKind: MailAuthKind = .password,
        isEnabled: Bool = true,
        sourceKind: MailAccountSource = .imap,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapSecurity = imapSecurity
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        self.username = username
        self.authKind = authKind
        self.isEnabled = isEnabled
        self.sourceKind = sourceKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Folder

/// 账号下的邮箱文件夹（IMAP mailbox）。
public struct MailFolder: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var accountId: UUID
    /// 服务器上的完整路径（如 `INBOX`、`Archive/2024`）。
    public var path: String
    /// 展示名（路径最后一段）。
    public var name: String
    public var role: MailFolderRole
    /// 父文件夹的服务器路径（nil 表示顶层）。
    public var parentPath: String?
    /// 层级分隔符（如 `/`、`.`）；nil 表示服务器未提供层级。
    public var delimiter: String?
    /// `\Noselect` 容器节点：只作分组展示，不可 SELECT/FETCH。
    public var isContainer: Bool
    /// IMAP UIDVALIDITY：变更表示该文件夹需全量重建。
    public var uidValidity: UInt32?
    /// IMAP UIDNEXT：增量拉取的起点。
    public var uidNext: UInt32?
    public var lastSyncAt: Date?
    public var unreadCount: Int
    public var totalCount: Int

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        path: String,
        name: String,
        role: MailFolderRole = .other,
        parentPath: String? = nil,
        delimiter: String? = nil,
        isContainer: Bool = false,
        uidValidity: UInt32? = nil,
        uidNext: UInt32? = nil,
        lastSyncAt: Date? = nil,
        unreadCount: Int = 0,
        totalCount: Int = 0
    ) {
        self.id = id
        self.accountId = accountId
        self.path = path
        self.name = name
        self.role = role
        self.parentPath = parentPath
        self.delimiter = delimiter
        self.isContainer = isContainer
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.lastSyncAt = lastSyncAt
        self.unreadCount = unreadCount
        self.totalCount = totalCount
    }
}

// MARK: - Message

/// 邮件元数据（列表中展示所需字段，不含正文）。
public struct MailMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var accountId: UUID
    public var folderId: UUID
    /// IMAP UID（在 folder + UIDVALIDITY 内唯一）。
    public var uid: UInt32
    public var messageId: String?
    public var subject: String
    public var fromName: String
    public var fromAddress: String
    /// `Reply-To`（ENVELOPE 提供）：回复时优先使用，缺失时回落到 `From`。
    public var replyTo: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    /// 已知线程引用（References 与 In-Reply-To）：回复保留祖先链，摘要只补充直接父邮件。
    public var references: String?
    public var date: Date?
    public var isRead: Bool
    public var isStarred: Bool
    public var hasAttachments: Bool
    public var sizeBytes: Int
    public var snippet: String
    public var bodyState: MailBodyState

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        folderId: UUID,
        uid: UInt32,
        messageId: String? = nil,
        subject: String = "",
        fromName: String = "",
        fromAddress: String = "",
        replyTo: [MailAddress] = [],
        to: [MailAddress] = [],
        cc: [MailAddress] = [],
        references: String? = nil,
        date: Date? = nil,
        isRead: Bool = false,
        isStarred: Bool = false,
        hasAttachments: Bool = false,
        sizeBytes: Int = 0,
        snippet: String = "",
        bodyState: MailBodyState = .none
    ) {
        self.id = id
        self.accountId = accountId
        self.folderId = folderId
        self.uid = uid
        self.messageId = messageId
        self.subject = subject
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.references = references
        self.date = date
        self.isRead = isRead
        self.isStarred = isStarred
        self.hasAttachments = hasAttachments
        self.sizeBytes = sizeBytes
        self.snippet = snippet
        self.bodyState = bodyState
    }

    /// 回复收件人：优先 `Reply-To`，其次 `From`。
    public var replyRecipients: [MailAddress] {
        if !replyTo.isEmpty { return replyTo }
        guard !fromAddress.isEmpty else { return [] }
        return [MailAddress(name: fromName, address: fromAddress)]
    }

    /// 全部回复按地址去重，排除当前账号自己的地址，密送不会从原邮件推导。
    public func replyAllRecipients(excluding ownAddresses: Set<String>) -> (to: [MailAddress], cc: [MailAddress]) {
        func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var used = Set(ownAddresses.map(normalized))
        func unique(_ addresses: [MailAddress]) -> [MailAddress] {
            addresses.filter { !$0.address.isEmpty && used.insert(normalized($0.address)).inserted }
        }
        let recipients = unique(replyRecipients + to)
        return (recipients, unique(cc))
    }

    /// 展示标题：空主题回落占位符。
    public var displaySubject: String {
        subject.isEmpty ? "(no subject)" : subject
    }

    /// 展示发件人：有名称时取名称，否则取地址。
    public var displayFrom: String {
        fromName.isEmpty ? fromAddress : fromName
    }
}

// MARK: - Body

/// 邮件正文缓存（与元数据分表，按需拉取）。
public struct MailBody: Sendable, Equatable {
    /// 对应 `mail_messages.id`。
    public var messageId: UUID
    public var textBody: String?
    public var htmlBody: String?
    public var rawHeaders: String?
    public var fetchedAt: Date

    public init(
        messageId: UUID,
        textBody: String? = nil,
        htmlBody: String? = nil,
        rawHeaders: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.messageId = messageId
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.rawHeaders = rawHeaders
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Attachment

/// 邮件附件元数据（附件二进制落受管文件区）。
public struct MailAttachment: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var messageId: UUID
    public var filename: String
    public var mimeType: String
    public var sizeBytes: Int
    public var contentId: String?
    public var localPath: String?
    public var partID: String?
    public var isInline: Bool

    public init(
        id: UUID = UUID(),
        messageId: UUID,
        filename: String,
        mimeType: String = "application/octet-stream",
        sizeBytes: Int = 0,
        contentId: String? = nil,
        localPath: String? = nil,
        isInline: Bool = false,
        partID: String? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.contentId = contentId
        self.localPath = localPath
        self.partID = partID
        self.isInline = isInline
    }
}

// MARK: - Draft

/// 草稿的投递状态机：把「是否可能已经投出去」持久化。
///
/// 只有确定未投递的状态才允许普通重试；一旦进入可能投递的阶段（sending）或结果
/// 不确定（unknown），重开 / 重启后都必须先核实，禁止普通重发（会造成重复投递）。
public enum MailDeliveryState: String, Codable, Sendable {
    /// 尚未进入投递流程
    case none
    /// 已准备（已生成 Message-ID 并落盘草稿），尚未开始 SMTP 投递
    case prepared
    /// 已进入可能投递的阶段（SMTP 已开始）；崩溃 / 重启后不得按普通草稿重发
    case sending
    /// 服务器已接受（投递确定成功）
    case accepted
    /// 投递结果未知（超时 / 连接中断）：必须核实后显式处置，禁止普通重试
    case unknown
    /// 已投递，但本地「已发送」副本保存失败
    case localSaveFailed

    /// 是否允许普通重试发送（只有确定未投递的状态允许）
    public var allowsRetry: Bool {
        switch self {
        case .none, .prepared: return true
        case .sending, .accepted, .unknown, .localSaveFailed: return false
        }
    }
}

/// 撰写类型：决定回复头与「原文引用」的组装方式。
public enum MailComposeKind: String, Codable, Sendable, CaseIterable {
    case new
    case reply
    case forward

    /// 回复类撰写（含回复与转发引用），需要绑定原邮件身份。
    public var hasSource: Bool { self != .new }
}

/// 本地草稿。
public struct MailDraft: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var accountId: UUID
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    public var attachments: [MailDraftAttachment]
    public var forwardAttachmentsState: MailForwardAttachmentsState
    /// 用户正在书写的正文（回复场景下**不含**原文引用）。
    public var bodyText: String
    public var bodyStyles: [MailStyleSpan]
    /// 原文引用（引用块）；空串表示没有引用部分。
    ///
    /// 与 `bodyText` 分开保存：AI 候选只作用于回复正文，引用原文继续保留，发送时再组装。
    public var quotedText: String
    /// 撰写类型（新写 / 回复 / 转发）。
    public var composeKind: MailComposeKind
    /// 被回复 / 被转发的原邮件本地 ID（固定身份，不依赖界面当前选中项）。
    public var sourceMessageId: UUID?
    public var inReplyTo: String?
    public var references: String?
    public var updatedAt: Date
    /// 非空表示这封草稿已经**投递出去**（本地留存的投递凭证）。
    ///
    /// 用途只有一个：投递成功但「已发送」副本或草稿清理失败时，证明邮件确实已发出，
    /// 使界面能提示「已发送（本地记录失败）」而不是引导用户重发（重发会重复投递）。
    public var deliveredAt: Date?
    /// 投递时本地生成的 Message-ID（与「已发送」副本一致，便于到服务器核对）。
    public var deliveredMessageId: String?
    /// 持久化的投递状态（决定重开 / 重启后能否普通重试）。
    /// 可选字段兼容旧数据：旧草稿解码后为 `.none`
    public var deliveryState: MailDeliveryState
    /// 本次投递尝试选定的 Message-ID（稳定身份；结果确定前不更换，便于核对同一封信）
    public var pendingMessageId: String?

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        to: [MailAddress] = [],
        cc: [MailAddress] = [],
        bcc: [MailAddress] = [],
        subject: String = "",
        bodyText: String = "",
        bodyStyles: [MailStyleSpan] = [],
        quotedText: String = "",
        composeKind: MailComposeKind = .new,
        sourceMessageId: UUID? = nil,
        inReplyTo: String? = nil,
        references: String? = nil,
        updatedAt: Date = Date(),
        deliveredAt: Date? = nil,
        deliveredMessageId: String? = nil,
        deliveryState: MailDeliveryState = .none,
        pendingMessageId: String? = nil,
        attachments: [MailDraftAttachment] = [],
        forwardAttachmentsState: MailForwardAttachmentsState = .pending
    ) {
        self.id = id
        self.accountId = accountId
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyText = bodyText
        self.bodyStyles = bodyStyles
        self.quotedText = quotedText
        self.composeKind = composeKind
        self.sourceMessageId = sourceMessageId
        self.inReplyTo = inReplyTo
        self.references = references
        self.updatedAt = updatedAt
        self.deliveredAt = deliveredAt
        self.deliveredMessageId = deliveredMessageId
        self.deliveryState = deliveryState
        self.pendingMessageId = pendingMessageId
        self.attachments = attachments; self.forwardAttachmentsState = forwardAttachmentsState
    }

    /// 发送时的完整正文：回复正文 + 原文引用。
    public var assembledBody: String {
        guard !quotedText.isEmpty else { return bodyText }
        guard !bodyText.isEmpty else { return quotedText }
        return bodyText + "\n\n" + quotedText
    }

    // 旧数据缺少新字段：解码缺省为兼容值，保证升级后旧草稿仍可读、仍可发送
    private enum CodingKeys: String, CodingKey {
        case id, accountId, to, cc, bcc, subject, bodyText, bodyStyles
        case quotedText, composeKind, sourceMessageId
        case inReplyTo, references, updatedAt, deliveredAt, deliveredMessageId
        case deliveryState, pendingMessageId
        case attachments, forwardAttachmentsState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        accountId = try c.decode(UUID.self, forKey: .accountId)
        to = try c.decodeIfPresent([MailAddress].self, forKey: .to) ?? []
        cc = try c.decodeIfPresent([MailAddress].self, forKey: .cc) ?? []
        bcc = try c.decodeIfPresent([MailAddress].self, forKey: .bcc) ?? []
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        bodyText = try c.decodeIfPresent(String.self, forKey: .bodyText) ?? ""
        bodyStyles = try c.decodeIfPresent([MailStyleSpan].self, forKey: .bodyStyles) ?? []
        try MailStyleSpan.validate(bodyStyles, text: bodyText)
        attachments = try c.decodeIfPresent([MailDraftAttachment].self, forKey: .attachments) ?? []
        forwardAttachmentsState = try c.decodeIfPresent(MailForwardAttachmentsState.self, forKey: .forwardAttachmentsState) ?? .pending
        try MailDraftAttachment.validate(attachments)
        quotedText = try c.decodeIfPresent(String.self, forKey: .quotedText) ?? ""
        composeKind = try c.decodeIfPresent(MailComposeKind.self, forKey: .composeKind) ?? .new
        sourceMessageId = try c.decodeIfPresent(UUID.self, forKey: .sourceMessageId)
        inReplyTo = try c.decodeIfPresent(String.self, forKey: .inReplyTo)
        references = try c.decodeIfPresent(String.self, forKey: .references)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        deliveredAt = try c.decodeIfPresent(Date.self, forKey: .deliveredAt)
        deliveredMessageId = try c.decodeIfPresent(String.self, forKey: .deliveredMessageId)
        deliveryState = try c.decodeIfPresent(MailDeliveryState.self, forKey: .deliveryState) ?? .none
        pendingMessageId = try c.decodeIfPresent(String.self, forKey: .pendingMessageId)
    }
}
