import Foundation
import CryptoKit

// MARK: - Mail Tool Factory
//
// 邮箱智体工具：全部复用功能页同一批空间服务（MailAccountService / MailService /
// MailSyncService），不新增第二套装配、连接或安全策略。
//
// 确认分级（与 DispatcherTool 协议对齐）：
// - 读类（accounts/folders/list/search/read）：免确认，`.readOnly`；
//   `mail_read` 在正文未缓存时会经同步服务按需拉取（只写本地缓存，幂等）。
// - `mail_mark`（已读/星标）：免确认，`.idempotentWrite`（推送 IMAP 标记，重复执行结果一致）。
// - `mail_save_draft`：需确认，`.idempotentWrite`。
// - `mail_send`：需确认，`.nonIdempotentWrite`（真实投递，绝不自动重放）。
// - `mail_delete`：硬确认（逐次必问），`.nonIdempotentWrite`（服务器上不可恢复）。
//
// 空间隔离：服务绑定当前空间的 DatabaseQueue，工具拿不到其他空间的账号或邮件。
public enum MailToolFactory {

    /// 工具返回文本的截断上限（沿用既有 `truncated` 模式）。
    static let maxOutputLength = 6_000

    public static func build(
        accountService: MailAccountService,
        mailService: MailService,
        syncService: MailSyncService
    ) -> [any DispatcherTool] {
        [
            MailAccountsListTool(accountService: accountService),
            MailFoldersListTool(accountService: accountService, mailService: mailService),
            MailListTool(accountService: accountService, mailService: mailService),
            MailReadTool(mailService: mailService, syncService: syncService),
            MailSearchTool(accountService: accountService, mailService: mailService),
            MailMarkTool(mailService: mailService, syncService: syncService),
            MailSaveDraftTool(accountService: accountService, mailService: mailService),
            MailSendTool(accountService: accountService, syncService: syncService, mailService: mailService),
            MailDeleteTool(mailService: mailService, syncService: syncService)
        ]
    }
}

// MARK: - Shared Helpers

/// 输出截断：保留头部并明确标注被截断，避免模型以为看全了。
private func truncated(_ text: String) -> String {
    guard text.count > MailToolFactory.maxOutputLength else { return text }
    return String(text.prefix(MailToolFactory.maxOutputLength))
        + "\n… [output truncated at \(MailToolFactory.maxOutputLength) characters]"
}

/// 解析目标账号：显式 `accountId` 优先，缺失时取空间内第一个账号。
private func requireAccount(id raw: String, service: MailAccountService, forSending: Bool = false) async throws -> MailAccount {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        guard let uuid = UUID(uuidString: trimmed) else {
            throw LLMError.configurationError(reason: "'\(trimmed)' is not a valid account id.")
        }
        guard let account = try await service.account(id: uuid) else {
            throw LLMError.configurationError(reason: "No mail account found with id \(trimmed).")
        }
        guard !forSending || !account.isLocalArchive else {
            throw LLMError.configurationError(reason: "A local archive cannot send mail or own a sending draft. Choose a sending account in this space.")
        }
        return account
    }
    guard let account = try await service.getAll().first(where: { !forSending || !$0.isLocalArchive }) else {
        throw LLMError.configurationError(
            reason: forSending
                ? "No sending account is configured in this space. Ask the user to add one in the Mail tab."
                : "No mail account is configured in this space. Ask the user to add one in the Mail tab."
        )
    }
    return account
}

/// 解析目标文件夹：显式 `folderId` → 该账号的收件箱 → 第一个可邮件文件夹。
private func requireFolder(id raw: String, accountId: UUID, mailService: MailService) async throws -> MailFolder {
    let folders = try await mailService.folders(accountId: accountId)
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        guard let uuid = UUID(uuidString: trimmed),
              let folder = folders.first(where: { $0.id == uuid && !$0.isContainer }) else {
            throw LLMError.configurationError(reason: "No mail folder found with id \(trimmed) in this account.")
        }
        return folder
    }
    // 容器节点不可选，需排除；无收件箱时回落到第一个可邮件文件夹
    let selectable = folders.filter { !$0.isContainer }
    guard let folder = selectable.first(where: { $0.role == .inbox }) ?? selectable.first else {
        throw LLMError.configurationError(
            reason: "This account has no folders synced yet. Ask the user to run a mail sync first."
        )
    }
    return folder
}

/// 按 id 取邮件，不存在或 id 非法即抛错。
private func requireMessage(id raw: String, mailService: MailService) async throws -> MailMessage {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let uuid = UUID(uuidString: trimmed) else {
        throw LLMError.configurationError(reason: "'\(trimmed)' is not a valid message id.")
    }
    if let capture = ToolArtifactCapture.current, let target = capture.mailTarget {
        guard case .message(let url) = target, let ref = try? MailSourceReference(url: url), ref.messageID == uuid else {
            throw ToolExecutionFailure(message: "The requested mail does not match the user's selection.")
        }
        return try await mailService.resolveSourceReference(ref, in: capture.origin.space)
    }
    guard let message = try await mailService.message(id: uuid) else {
        throw LLMError.configurationError(reason: "No mail message found with id \(trimmed).")
    }
    return message
}

private func mailIdentity(_ data: Data) -> UUID {
    var bytes = Array(SHA256.hash(data: data).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
}

/// 解析逗号/分号/换行分隔的地址串，支持 `名称 <地址>` 与纯地址。
private func parseAddresses(_ raw: String) -> [MailAddress] {
    raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { value in
            guard let open = value.lastIndex(of: "<"),
                  let close = value.lastIndex(of: ">"),
                  open < close else {
                return MailAddress(name: "", address: value)
            }
            let address = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let name = value[..<open]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return MailAddress(name: name, address: address)
        }
}

private func formatAddresses(_ addresses: [MailAddress]) -> String {
    addresses.map(\.display).joined(separator: ", ")
}

/// 读取布尔参数（接受 JSON 布尔或字符串形式）。
private func boolArgument(_ args: [String: Any], _ key: String) -> Bool? {
    if let value = args[key] as? Bool { return value }
    guard let raw = args[key] as? String else { return nil }
    switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
    case "true", "yes", "1": return true
    case "false", "no", "0": return false
    default: return nil
    }
}

/// 空串转 nil（用于可选字符串参数）。
private func nilIfEmpty(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// 截断到分钟的时间戳（工具输出用，避免暴露本地化格式差异）。
private func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

/// 邮件列表行（列表类工具共用）。
private func messageLine(_ message: MailMessage, folderPath: String?) -> String {
    var flags = message.isRead ? "" : "[unread] "
    if message.isStarred { flags += "[starred] " }
    let date = message.date.map { "\(timestamp($0)) " } ?? ""
    let folder = folderPath.map { " @\($0)" } ?? ""
    let sender = message.fromAddress.isEmpty ? message.displayFrom : message.fromAddress
    return "- \(flags)\(message.id.uuidString)\(folder) | \(date)\(sender) | \(message.displaySubject)"
}

private func mailListing(header: String, messages: [MailMessage], accountID: UUID,
                         folderPaths: [UUID: String] = [:], partialCoverage: Bool) -> String {
    let space = ToolArtifactCapture.current?.origin.space
    var output = String(header.prefix(3_000))
    var links: [URL] = []
    var clipped = false
    for message in messages {
        let link = space.map { MailSourceReference(message: message, space: $0).url }
        let row = String(messageLine(message, folderPath: folderPaths[message.folderId]).prefix(800))
            + (link.map { " | " + $0.absoluteString } ?? "")
        guard output.count + row.count + 2 < MailToolFactory.maxOutputLength - 64 else {
            clipped = true
            break
        }
        output += "\n" + row
        if let link { links.append(link) }
    }
    if clipped { output += "\n[More matches omitted. Narrow the query.]" }
    let status: ToolSourceReceipt.Status = partialCoverage || clipped ? .partial : (messages.isEmpty ? .noMatches : .found)
    ToolArtifactCapture.recordSource(.init(.mail, status, references: links, accountID: accountID))
    return output
}

// MARK: - Read Tools

/// 列出当前空间的邮箱账号（后续工具的 `accountId` 来源）。
struct MailAccountsListTool: DispatcherTool {
    let accountService: MailAccountService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail_accounts_list",
            description: "List the email accounts configured in the current space. "
                + "Call this first to get the accountId used by the other mail tools.",
            parametersSchemaJSON: #"{"type":"object","properties":{}}"#
        )
    }
    let requiresConfirmation = false
    let sideEffectClass = ToolSideEffectClass.readOnly

    func execute(argumentsJSON: String) async throws -> String {
        let accounts = try await accountService.getAll()
        guard !accounts.isEmpty else {
            return "No email account is configured in this space."
        }
        let lines = accounts.map { account -> String in
            let address = account.emailAddress.isEmpty ? account.username : account.emailAddress
            let name = account.displayName.isEmpty ? "(unnamed)" : account.displayName
            if account.isLocalArchive { return "- \(account.id.uuidString) | \(name) [local archive; offline; cannot send]" }
            return "- \(account.id.uuidString) | \(name) <\(address)>" + (account.isEnabled ? "" : " (disabled)")
        }
        return truncated("Email accounts:\n" + lines.joined(separator: "\n"))
    }
}

/// 列出账号下的文件夹（收件箱 / 已发送等，含未读计数）。
struct MailFoldersListTool: DispatcherTool {
    let accountService: MailAccountService
    let mailService: MailService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail_folders_list",
            description: "List the mail folders of an account (INBOX, Sent, Archive, ...) with unread "
                + "and total counts. Folders come from the last sync; ask the user to sync if empty.",
            parametersSchemaJSON: #"{"type":"object","properties":{"accountId":{"type":"string","description":"Optional account id from mail_accounts_list; defaults to the first account"}}}"#
        )
    }
    let requiresConfirmation = false
    let sideEffectClass = ToolSideEffectClass.readOnly

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let account = try await requireAccount(
            id: ToolArguments.string(args, "accountId"),
            service: accountService
        )
        let folders = try await mailService.folders(accountId: account.id)
        guard !folders.isEmpty else {
            return "No folders are synced for this account yet. Ask the user to run a mail sync first."
        }
        let lines = folders.map { folder in
            "- \(folder.id.uuidString) | \(folder.role.rawValue) | \(folder.path) "
                + "| unread \(folder.unreadCount), total \(folder.totalCount)"
        }
        return truncated("Mail folders:\n" + lines.joined(separator: "\n"))
    }
}

/// 列出文件夹内的邮件（默认收件箱，按日期倒序）。
struct MailListTool: DispatcherTool {
    let accountService: MailAccountService
    let mailService: MailService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail_list",
            description: "List recent messages in a mail folder (defaults to INBOX), newest first. "
                + "Returns message ids for mail_read / mail_mark / mail_delete. "
                + "When showing a list, link each message to its supplied agroom-mail URL so later selections follow the displayed order. "
                + "Only locally synced messages appear; ask the user to sync for fresh mail.",
            parametersSchemaJSON: #"{"type":"object","properties":{"accountId":{"type":"string","description":"Optional account id"},"folderId":{"type":"string","description":"Optional folder id from mail_folders_list; defaults to INBOX"},"limit":{"type":"integer","description":"Max messages to return (1-100, default 20)"}}}"#
        )
    }
    let requiresConfirmation = false
    let sideEffectClass = ToolSideEffectClass.readOnly

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let account = try await requireAccount(
            id: ToolArguments.string(args, "accountId"),
            service: accountService
        )
        let folder = try await requireFolder(
            id: ToolArguments.string(args, "folderId"),
            accountId: account.id,
            mailService: mailService
        )
        let limit = min(max(Int(ToolArguments.string(args, "limit")) ?? 20, 1), 100)
        let messages = try await mailService.messages(folderId: folder.id, limit: limit)
        let coverage = try await mailService.coverage(folderID: folder.id)
        let partial = !account.isLocalArchive && (coverage.checkedAt == nil || !coverage.isComplete)
        let header = messages.isEmpty ? "No messages in \(folder.path)." : "Messages in \(folder.path):"
        return mailListing(header: header + (partial ? " Local sync coverage is incomplete." : ""),
                           messages: messages, accountID: account.id, partialCoverage: partial)
    }
}

/// 读取一封邮件：头部 + 正文（未缓存时按需拉取）+ 附件元数据。
struct MailReadTool: DispatcherTool {
    let mailService: MailService
    let syncService: MailSyncService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail_read",
            description: "Read one mail message: headers, plain-text body and attachment metadata. "
                + "Fetches the body from the IMAP server on demand if it is not cached yet. "
                + "Attachment contents are not returned, only their names and sizes.",
            parametersSchemaJSON: #"{"type":"object","properties":{"messageId":{"type":"string","description":"Message id from mail_list or mail_search"}},"required":["messageId"]}"#
        )
    }
    let requiresConfirmation = false
    let sideEffectClass = ToolSideEffectClass.readOnly

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let message = try await requireMessage(
            id: ToolArguments.string(args, "messageId"),
            mailService: mailService
        )

        var lines = [
            "Subject: \(message.displaySubject)",
            "From: \(message.fromName.isEmpty ? message.fromAddress : message.fromName)"
                + (message.fromAddress.isEmpty ? "" : " <\(message.fromAddress)>"),
            "To: \(formatAddresses(message.to))"
        ]
        if !message.cc.isEmpty {
            lines.append("Cc: \(formatAddresses(message.cc))")
        }
        if !message.replyTo.isEmpty { lines.append("Reply-To: " + formatAddresses(message.replyTo)) }
        if let date = message.date {
            lines.append("Date: \(timestamp(date))")
        }
        if let messageId = message.messageId {
            lines.append("Message-ID: \(messageId)")
        }
        lines.append("Status: \(message.isRead ? "read" : "unread")\(message.isStarred ? ", starred" : "")")

        // 正文未缓存时按需拉取（只写本地缓存，幂等；失败则回落提示）
        let body: MailBody?
        if message.bodyState == .ready {
            body = try? await mailService.body(messageId: message.id)
        } else {
            body = try? await syncService.loadBody(messageId: message.id)
        }
        let hasBody = body?.textBody?.isEmpty == false || body?.htmlBody?.isEmpty == false
        let link = ToolArtifactCapture.current.map { MailSourceReference(message: message, space: $0.origin.space).url }
        if let link { lines.insert("Source: " + link.absoluteString, at: 0) }
        if let text = body?.textBody, !text.isEmpty {
            lines.append("")
            lines.append(text)
        } else if let html = body?.htmlBody, !html.isEmpty {
            lines.append("")
            lines.append("[HTML-only body, raw markup follows]")
            lines.append(html)
        } else {
            lines.append("")
            lines.append("[Body unavailable; the message may be empty or the server could not be reached.]")
        }

        let attachments = (try? await mailService.attachments(messageId: message.id)) ?? []
        if !attachments.isEmpty {
            lines.append("")
            lines.append("Attachments:")
            lines.append(contentsOf: attachments.map { attachment in
                let name = attachment.filename.isEmpty ? attachment.mimeType : attachment.filename
                return "- \(name) (\(attachment.sizeBytes) bytes)"
            })
        }
        let output = lines.joined(separator: "\n")
        if let link {
            ToolArtifactCapture.recordSource(.init(.mail, hasBody && output.count <= MailToolFactory.maxOutputLength ? .found : .partial,
                references: [link], accountID: message.accountId, hasMailBody: hasBody))
        }
        return truncated(output)
    }
}

/// 关键词检索本地已同步邮件（主题 / 发件人 / 摘要）。
struct MailSearchTool: DispatcherTool {
    let accountService: MailAccountService
    let mailService: MailService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail_search",
            description: "Search locally synced mail by keyword across subject, sender name, sender address "
                + "and body snippet. Use when the user asks to find a message. Only synced mail is searched. "
                + "When showing a list, link each message to its supplied agroom-mail URL in the order you actually present.",
            parametersSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Keyword to match"},"accountId":{"type":"string","description":"Optional account id"},"limit":{"type":"integer","description":"Max results (1-50, default 20)"}},"required":["query"]}"#
        )
    }
    let requiresConfirmation = false
    let sideEffectClass = ToolSideEffectClass.readOnly

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let query = ToolArguments.string(args, "query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw LLMError.configurationError(reason: "'query' cannot be empty.")
        }
        let account = try await requireAccount(
            id: ToolArguments.string(args, "accountId"),
            service: accountService
        )
        let limit = min(max(Int(ToolArguments.string(args, "limit")) ?? 20, 1), 50)
        let matches = try await mailService.searchMessages(accountId: account.id, query: query, limit: limit)
        let folders = try await mailService.folders(accountId: account.id)
        var coverageLines: [String] = []
        var partial = !account.isLocalArchive && folders.allSatisfy(\.isContainer)
        for folder in folders where !folder.isContainer {
            let coverage = try await mailService.coverage(folderID: folder.id)
            if !account.isLocalArchive, coverage.checkedAt == nil || !coverage.isComplete { partial = true }
            let state = coverage.checkedAt == nil ? "not checked" : coverage.isComplete ? "complete at last sync" : "partial; older mail may be missing"
            let range = coverage.oldestDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
            coverageLines.append("\(folder.name): \(coverage.cachedCount)/\(coverage.remoteCount.map(String.init) ?? "unknown") cached; \(state); oldest cached date \(range)")
        }
        let coverageNote = "Search scope: local subject, sender and cached snippets only, not a full-body or remote search.\n" + coverageLines.joined(separator: "\n") + "\n"
        guard !matches.isEmpty else {
            ToolArtifactCapture.recordSource(.init(.mail, partial ? .partial : .noMatches, accountID: account.id))
            return truncated(coverageNote + "No synced message matches '\(query)'. Missing local results do not prove absence on the server. Use Mail's earlier-history action if coverage is partial.")
        }
        // 容器节点无邮件，不参与路径映射
        let pathById = Dictionary(uniqueKeysWithValues: folders.filter { !$0.isContainer }.map { ($0.id, $0.path) })
        return mailListing(header: coverageNote + "Matches for '\(query)':", messages: matches,
                           accountID: account.id, folderPaths: pathById, partialCoverage: partial)
    }
}

// MARK: - Write Tools

/// 标记已读 / 星标（本地立即生效并尽力回写 IMAP）。
struct MailMarkTool: DispatcherTool {
    let mailService: MailService
    let syncService: MailSyncService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail_mark",
            description: "Mark a message as read/unread and/or starred. Idempotent and safe to retry; "
                + "provide at least one of 'read' or 'starred'.",
            parametersSchemaJSON: #"{"type":"object","properties":{"messageId":{"type":"string","description":"Message id from mail_list or mail_search"},"read":{"type":"boolean","description":"Set the read flag"},"starred":{"type":"boolean","description":"Set the starred flag"}},"required":["messageId"]}"#
        )
    }
    let requiresConfirmation = false
    let sideEffectClass = ToolSideEffectClass.idempotentWrite

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let message = try await requireMessage(
            id: ToolArguments.string(args, "messageId"),
            mailService: mailService
        )
        let read = boolArgument(args, "read")
        let starred = boolArgument(args, "starred")
        guard read != nil || starred != nil else {
            throw LLMError.configurationError(reason: "Provide at least one of 'read' or 'starred'.")
        }

        var applied: [String] = []
        if let read {
            try await syncService.setRead(messageId: message.id, isRead: read)
            applied.append("read=\(read)")
        }
        if let starred {
            try await syncService.setStarred(messageId: message.id, isStarred: starred)
            applied.append("starred=\(starred)")
        }
        return "Updated \(message.id.uuidString): \(applied.joined(separator: ", "))."
    }
}

/// 存草稿（不发送）。
struct MailSaveDraftTool: DispatcherTool {
    let accountService: MailAccountService
    let mailService: MailService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail_save_draft",
            description: "Save a draft locally without sending it. The draft shows up in the user's Mail tab. "
                + "Requires user confirmation.",
            parametersSchemaJSON: #"{"type":"object","properties":{"accountId":{"type":"string","description":"Optional sending account id"},"sourceMessageId":{"type":"string","description":"Local message UUID from mail_read for a reply to a selected message"},"to":{"type":"string","description":"Recipients, comma separated"},"cc":{"type":"string"},"bcc":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string","description":"Plain-text body"},"inReplyTo":{"type":"string","description":"Original Internet Message-ID when available"}},"required":["to","subject","body"]}"#
        )
    }
    let requiresConfirmation = true
    let sideEffectClass = ToolSideEffectClass.idempotentWrite

    func validateArguments(argumentsJSON: String) throws {
        if ToolArguments.parse(argumentsJSON)["sourceMessageId"] != nil {
            _ = try MailSendTool.Submission.resolve(argumentsJSON, accounts: accountService, mail: mailService)
        }
    }

    func executionAuthorizationKey(argumentsJSON: String) -> String? {
        guard let (submission, _, source) = try? MailSendTool.Submission.resolve(argumentsJSON, accounts: accountService, mail: mailService),
              let digest = ProviderTurnHistory.digest(submission) else { return nil }
        return "mail_save_draft#" + digest + (source?.id.uuidString ?? "")
    }

    func execute(argumentsJSON: String) async throws -> String {
        let (submission, _, source) = try MailSendTool.Submission.resolve(argumentsJSON, accounts: accountService, mail: mailService, forDraft: true)
        struct Identity: Encodable {
            let runID: UUID
            let account: UUID
            let source: UUID?
            let submission: MailSendTool.Submission?
        }
        let id: UUID
        if let origin = ToolArtifactCapture.current?.origin {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // One requested reply per selected source in a run, even when a retry rephrases the body.
            id = mailIdentity(try encoder.encode(Identity(runID: origin.runID, account: submission.accountID,
                source: source?.id, submission: source == nil ? submission : nil)))
        } else { id = UUID() }
        let draft = submission.draft(id: id, source: source)
        guard !draft.to.isEmpty else {
            throw LLMError.configurationError(reason: "'to' must contain at least one recipient.")
        }
        switch try await mailService.insertAgentDraft(draft, source: source, trackOperation: ToolArtifactCapture.current != nil) {
        case .existing:
            ToolArtifactCapture.current?.evidence = .init(savedMailDraftID: draft.id)
            return "This request already saved draft \(draft.id.uuidString). Its current contents were preserved."
        case .removed:
            return "This request already saved draft \(draft.id.uuidString). It is no longer in drafts and was not recreated."
        case .created:
            ToolArtifactCapture.current?.evidence = .init(savedMailDraftID: draft.id)
            return "Draft saved for \(formatAddresses(draft.to)) with id \(draft.id.uuidString)."
        }
    }
}

/// 发送邮件（SMTP 投递，成功后落本地「已发送」副本）。
struct MailSendTool: DispatcherTool {
    let accountService: MailAccountService
    let syncService: MailSyncService
    var mailService: MailService? = nil

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail_send",
            description: "Send an email through the account's SMTP server. This really delivers the message "
                + "and cannot be undone, so always confirm the recipients and content with the user first. "
                + "A copy is kept in the local Sent folder.",
            parametersSchemaJSON: #"{"type":"object","properties":{"accountId":{"type":"string","description":"Optional account id"},"to":{"type":"string","description":"Recipients, comma separated"},"cc":{"type":"string"},"bcc":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string","description":"Plain-text body"},"inReplyTo":{"type":"string","description":"Optional original Message-ID when replying"},"sourceMessageId":{"type":"string","description":"Local mail UUID for a reply to a selected message"},"references":{"type":"string","description":"Optional References header when replying"}},"required":["to","subject","body"]}"#
        )
    }
    let requiresConfirmation = true
    let sideEffectClass = ToolSideEffectClass.nonIdempotentWrite

    /// 单次投递收件人上限（to + cc + bcc）：可解释的批量上限，
    /// 避免一次调用借已有授权群发大量收件人。
    static let maxRecipientCount = 50

    /// 外发不可撤销（收件人可能已经收到）：无视「本轮始终允许」，逐次必问。
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { true }
    func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .irreversible }

    /// 禁用整工具的本轮授权：一次批准只对当次的收件人/抄送/密送/正文生效，
    /// 后续调用（换账号、换收件人、换正文）都必须重新确认。
    func roundAuthorizationKey(argumentsJSON: String) -> String? { nil }

    func validateArguments(argumentsJSON: String) throws {
        if ToolArguments.parse(argumentsJSON)["sourceMessageId"] != nil { _ = try prepared(argumentsJSON) }
    }

    fileprivate struct Submission: Encodable {
        let accountID: UUID
        let to, cc, bcc: [MailAddress]
        let subject, body: String
        let inReplyTo, references: String?

        init(_ args: [String: Any], account: MailAccount) {
            accountID = account.id
            to = parseAddresses(ToolArguments.string(args, "to"))
            cc = parseAddresses(ToolArguments.string(args, "cc"))
            bcc = parseAddresses(ToolArguments.string(args, "bcc"))
            subject = ToolArguments.string(args, "subject")
            body = ToolArguments.string(args, "body")
            inReplyTo = nilIfEmpty(ToolArguments.string(args, "inReplyTo"))
            references = nilIfEmpty(ToolArguments.string(args, "references"))
        }

        static func resolve(_ json: String, accounts: MailAccountService, mail: MailService?, forDraft: Bool = false) throws -> (Self, MailAccount, MailMessage?) {
            var args = ToolArguments.parse(json)
            var source: MailMessage?
            if let supplied = args["sourceMessageId"] {
                guard let raw = supplied as? String, let id = UUID(uuidString: raw), let mail else { throw MailSourceReferenceError.invalid }
                let message = try mail.replySource(id: id)
                if let header = nilIfEmpty(ToolArguments.string(args, "inReplyTo")), header != message.messageId {
                    throw ToolExecutionFailure(message: "The reply header does not match the selected message.")
                }
                args["inReplyTo"] = message.messageId
                source = message
            }
            let sender = nilIfEmpty(ToolArguments.string(args, "accountId")) ?? source?.accountId.uuidString ?? ""
            let account: MailAccount
            do { account = try accounts.sendingAccount(forApproval: sender) }
            catch let failure as ToolExecutionFailure where forDraft {
                throw LLMError.configurationError(reason: failure.message)
            }
            let submission = Self(args, account: account)
            if let source {
                let replyAddresses = Set(source.replyRecipients.map { $0.address.lowercased() })
                guard submission.to.contains(where: { replyAddresses.contains($0.address.lowercased()) }) else {
                    throw ToolExecutionFailure(message: "The recipients do not include the selected message's Reply-To or sender. Read the selected message before replying.")
                }
            }
            return (submission, account, source)
        }

        func draft(id: UUID, source: MailMessage?) -> MailDraft {
            var result = MailDraft(id: id, accountId: accountID, to: to, cc: cc, bcc: bcc, subject: subject,
                      bodyText: body, inReplyTo: inReplyTo, references: references)
            result.sourceMessageId = source?.id
            if source != nil { result.composeKind = .reply }
            return result
        }
    }

    func prepared(_ json: String) throws -> (account: MailAccount, draft: MailDraft, key: String) {
        let (submission, account, source) = try Submission.resolve(json, accounts: accountService, mail: mailService)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(submission)
        let id = mailIdentity(bytes)
        let binding = SHA256.hash(data: try encoder.encode(account) + bytes + Data((source?.id.uuidString ?? "").utf8))
        return (account, submission.draft(id: id, source: source), "mail_send#" + binding.map { String(format: "%02x", $0) }.joined())
    }

    func executionAuthorizationKey(argumentsJSON: String) -> String? { try? prepared(argumentsJSON).key }

    func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        guard let prepared = try? prepared(argumentsJSON) else { return nil }
        let sender = prepared.account.emailAddress.isEmpty ? prepared.account.username : prepared.account.emailAddress
        let draft = prepared.draft
        return .init(executionKind: .other, resourceAccess: .init(verified: true),
                     network: .init(allowed: true), childProcesses: .init(allowed: false),
                     reasonCode: "mail_delivery", constraintSources: ["space"],
                     executionDetails: ["From: " + sender, "SMTP: " + prepared.account.smtpHost,
                                        "To: " + formatAddresses(draft.to), "Cc: " + formatAddresses(draft.cc),
                                        "Bcc: " + formatAddresses(draft.bcc), "Subject: " + draft.subject])
    }

    func execute(argumentsJSON: String) async throws -> String {
        try await execute(argumentsJSON: argumentsJSON, authorizationKey: executionAuthorizationKey(argumentsJSON: argumentsJSON))
    }

    func execute(argumentsJSON: String, authorizationKey: String?) async throws -> String {
        let plan = try prepared(argumentsJSON)
        guard plan.key == authorizationKey else {
            throw ToolExecutionFailure(message: "The sending account or message changed. Request a fresh confirmation.")
        }
        let draft = plan.draft
        guard !draft.to.isEmpty else {
            throw LLMError.configurationError(reason: "'to' must contain at least one recipient.")
        }
        let recipientCount = draft.to.count + draft.cc.count + draft.bcc.count
        guard recipientCount <= Self.maxRecipientCount else {
            throw LLMError.configurationError(
                reason: "Too many recipients (\(recipientCount)); one send is limited to "
                    + "\(Self.maxRecipientCount) addresses. Ask the user before splitting into "
                    + "multiple confirmed sends."
            )
        }

        let stored: MailMessage?
        do {
            stored = try await syncService.send(draft: draft, expectedAccount: plan.account)
        } catch let error as MailDeliveredLocalSaveError {
            ToolArtifactCapture.current?.evidence = .init(requiresManualRecovery: true, sourceReceipt: .init(.mail, .partial))
            // 邮件已经发出去了：绝不能报成发送失败，否则模型会重发造成重复投递
            throw LLMError.configurationError(
                reason: "The mail WAS delivered, but the local Sent copy could not be saved: "
                    + "\(error.underlying). Do not send it again. Tell the user it was delivered and "
                    + "that they should check the server's Sent folder."
            )
        } catch MailProtocolError.sendResultUnknown(let reason) {
            ToolArtifactCapture.current?.evidence = .init(requiresManualRecovery: true, sourceReceipt: .init(.mail, .unknown))
            throw MailProtocolError.sendResultUnknown(reason)
        } catch {
            // SMTP may already have accepted the message. Consult the durable delivery state
            // before allowing another action, even if the model changes the arguments.
            if let mailService {
                do {
                    if let saved = try await mailService.draft(id: draft.id), !saved.deliveryState.allowsRetry {
                        ToolArtifactCapture.current?.evidence = .init(requiresManualRecovery: true,
                            sourceReceipt: .init(.mail, [.accepted, .localSaveFailed].contains(saved.deliveryState) ? .found : .unknown))
                    }
                } catch {
                    ToolArtifactCapture.current?.evidence = .init(requiresManualRecovery: true, sourceReceipt: .init(.mail, .unknown))
                }
            }
            throw error
        }
        let recipients = formatAddresses(draft.to + draft.cc + draft.bcc)
        guard let stored else {
            return "Sent to \(recipients). No Sent folder was found, so no local copy was kept."
        }
        return "Sent to \(recipients). Local copy stored as message \(stored.id.uuidString)."
    }
}

/// 删除邮件（服务器上永久删除，不可恢复）。
///
/// 只影响目标邮件：实现先检查该文件夹里是否还有其他已标 `\Deleted` 的邮件，
/// 有则只在服务器支持 `UID EXPUNGE`（RFC 4315）时继续，否则中止并说明原因——
/// 不带 UID 的 `EXPUNGE` 会连带清空其他客户端的待删邮件。
struct MailDeleteTool: DispatcherTool {
    let mailService: MailService
    let syncService: MailSyncService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail_delete",
            description: "Permanently delete a message from the server. This cannot be undone and always "
                + "requires explicit user confirmation. Only the given message is affected; if other "
                + "messages in the folder are already marked for deletion and the server lacks UIDPLUS, "
                + "the tool refuses instead of deleting them too — suggest moving the message to Trash "
                + "instead.",
            parametersSchemaJSON: #"{"type":"object","properties":{"messageId":{"type":"string","description":"Message id from mail_list or mail_search"}},"required":["messageId"]}"#
        )
    }
    let requiresConfirmation = true
    let sideEffectClass = ToolSideEffectClass.nonIdempotentWrite

    /// 删除不可恢复：无视「本轮始终允许」，逐次必问。
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { true }
    func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .irreversible }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let message = try await requireMessage(
            id: ToolArguments.string(args, "messageId"),
            mailService: mailService
        )
        do {
            try await syncService.deleteMessage(messageId: message.id)
        } catch MailSyncError.deletionWouldAffectOthers(let count) {
            throw LLMError.configurationError(
                reason: "Not deleted: \(count) other message(s) in this folder are already marked for "
                    + "deletion, and this server does not support UID EXPUNGE, so a folder-wide expunge "
                    + "would delete them too. Suggest moving this message to the Trash folder instead, or "
                    + "ask the user to clear the other pending deletions in their mail client first."
            )
        }
        return "Deleted \"\(message.displaySubject)\" (\(message.id.uuidString))."
    }
}
