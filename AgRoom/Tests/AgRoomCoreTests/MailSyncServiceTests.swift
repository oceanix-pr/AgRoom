import Testing
import Foundation
import GRDB
@testable import AgRoomCore

// MARK: - Mock Protocol Client

/// 内存版 `MailProtocolClient`：记录调用并按预置数据应答，用于验证同步编排。
actor MockMailClient: MailProtocolClient {
    enum DraftFailure: Sendable { case none, beforeAppend, afterAppend }
    private var draftFailure = DraftFailure.none
    private var draftMembers: [String: Set<UInt32>] = [:]
    private(set) var draftAppendCount = 0
    func configureDraftFailure(_ value: DraftFailure) { draftFailure = value }
    func changeDraftRaw(uid: UInt32, data: Data) { rawMessages[uid] = data }
    func clearDraftFlag(path: String, uid: UInt32) { draftMembers[path]?.remove(uid) }
    func replaceSummarySnapshot(path: String, values: [RemoteMessageSummary], status: RemoteFolderStatus) {
        summaries[path] = values; statuses[path] = status
    }
    func appendDraft(path: String, data: Data) async throws -> RemoteDraftAppendResult {
        draftAppendCount += 1
        if draftFailure == .beforeAppend { throw MailProtocolError.connectionFailed("synthetic pre-append disconnect") }
        let uid = ((summaries[path] ?? []).map(\.uid).max() ?? 0) + 1
        let envelope = try MailFoundationAdapter.importedEnvelope(data)
        summaries[path, default: []].append(.init(uid: uid, messageId: envelope.messageID, subject: envelope.subject,
            from: [envelope.from], to: envelope.to, cc: envelope.cc, date: envelope.date,
            isRead: false, isStarred: false, sizeBytes: data.count, snippet: ""))
        rawMessages[uid] = data; draftMembers[path, default: []].insert(uid)
        if draftFailure == .afterAppend { throw MailProtocolError.connectionFailed("synthetic lost APPEND response") }
        return .init(uidValidity: statuses[path]?.uidValidity ?? 1, uid: uid)
    }
    func draftUIDs(path: String, messageID: String) async throws -> [UInt32] {
        (summaries[path] ?? []).filter { summary in
            guard draftMembers[path, default: []].contains(summary.uid), let raw = rawMessages[summary.uid] else { return false }
            return (try? MailFoundationAdapter.originalMessageID(raw)) == messageID
        }.map(\.uid).sorted()
    }
    enum FolderFailureMode: Sendable { case none, reject, afterApply, hangAfterApply }
    struct FolderMutationCall: Sendable, Equatable {
        let kind: MailFolderMutationKind
        let path: String
        let destination: String?
    }
    private var folderFailure: FolderFailureMode = .none
    private var folderFailureKind: MailFolderMutationKind?
    private var renamedValidity: UInt32?
    private(set) var folderMutationCalls: [FolderMutationCall] = []
    struct FlagCall: Sendable, Equatable {
        let path: String
        let uid: UInt32
        let add: [MailFlag]
        let remove: [MailFlag]
    }

    /// 需要「挂起到调用方断开连接」的操作，用于验证超时守卫。
    ///
    /// 之所以挂在 `disconnect()` 上而不是定时返回：真实实现里能让阻塞中的读
    /// 立即收尾的正是关闭套接字，mock 必须复现这个因果关系，否则测不出
    /// 「超时会主动断链」这条行为。
    enum HangPoint: Sendable {
        case connect
        case authenticate
        case listFolders
        case folderStatus
        case fetchSummaries
        case fetchBody
        case fetchAttachment
        case storeFlags
    }

    /// 模拟服务器的一个文件夹状态：UID 空间 + 已标 `\Deleted` 的 UID 集合。
    ///
    /// `\Deleted` 集合必须由 mock 自己维护，才能验证「删除只影响目标邮件」——
    /// 旧实现的破坏性正是来自服务器上这些标记的实际语义。
    private var deletedUIDs: [String: Set<UInt32>] = [:]
    /// 服务器认可的 UIDPLUS（决定 `expungeUIDs` 是否可用）
    private let supportsUIDPlus: Bool
    /// 非空时 EXPUNGE 不清除任何东西（模拟「命令成功但目标仍在」）
    private let expungeNoop: Bool

    private var folders: [RemoteMailFolder]
    private var statuses: [String: RemoteFolderStatus]
    private var summaries: [String: [RemoteMessageSummary]]
    private var bodies: [UInt32: RemoteMessageBody]
    private var rawMessages: [UInt32: Data] = [:]
    private(set) var rawFetchCount = 0
    private let bodyFailure: String?
    private let hangPoint: HangPoint?
    /// 挂起中的调用；由 `disconnect()` 统一唤醒。
    private var hungContinuations: [CheckedContinuation<Void, Error>] = []

    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var authenticatedUser: String?
    private(set) var fetchRequests: [(path: String, sinceUID: UInt32?)] = []
    private(set) var fetchLimits: [Int] = []
    private(set) var summaryFetchCount = 0
    private(set) var flagCalls: [FlagCall] = []
    private(set) var moveCalls: [(path: String, uid: UInt32, toPath: String)] = []
    private(set) var deleteCalls: [(path: String, uid: UInt32)] = []
    private(set) var expungeAllCalls: [String] = []
    /// 让标记搜索返回不可解读的应答（模拟服务器回本层不认识的 ESEARCH 形态）
    private var searchUnreadable: Bool
    private(set) var expungeUIDCalls: [(path: String, uids: [UInt32])] = []
    /// 每次 `fetchBody` 请求携带的字节上限
    private(set) var bodyLimits: [Int] = []
    private(set) var bodyFetchCount = 0
    private(set) var attachmentDownloadCount = 0
    /// 并发探针（可选）：在 `listFolders` 进入/退出时登记，用于验证账号级互斥
    private let concurrencyProbe: MailConcurrencyProbe?
    private let summaryReadGate: (@Sendable () async -> Void)?

    /// 非空时 `moveMessage` / `deleteMessage` 抛错（验证远端失败不改本地）。
    private let mutationFailure: String?
    /// 目标文件夹分配的新 UID（模拟 RFC 6851 的重新编号）；nil = 服务器不回 COPYUID
    private let moveDestinationUID: UInt32?

    init(
        folders: [RemoteMailFolder] = [],
        statuses: [String: RemoteFolderStatus] = [:],
        summaries: [String: [RemoteMessageSummary]] = [:],
        bodies: [UInt32: RemoteMessageBody] = [:],
        bodyFailure: String? = nil,
        mutationFailure: String? = nil,
        hangPoint: HangPoint? = nil,
        supportsUIDPlus: Bool = false,
        expungeNoop: Bool = false,
        searchUnreadable: Bool = false,
        moveDestinationUID: UInt32? = nil,
        concurrencyProbe: MailConcurrencyProbe? = nil,
        summaryReadGate: (@Sendable () async -> Void)? = nil
    ) {
        self.folders = folders
        self.statuses = statuses
        self.summaries = summaries
        self.bodies = bodies
        self.bodyFailure = bodyFailure
        self.mutationFailure = mutationFailure
        self.hangPoint = hangPoint
        self.supportsUIDPlus = supportsUIDPlus
        self.expungeNoop = expungeNoop
        self.searchUnreadable = searchUnreadable
        self.moveDestinationUID = moveDestinationUID
        self.concurrencyProbe = concurrencyProbe
        self.summaryReadGate = summaryReadGate
    }

    /// 预置服务器上已标 `\Deleted` 的 UID（模拟其他客户端留下的待删邮件）。
    func markDeletedOnServer(path: String, uids: [UInt32]) {
        deletedUIDs[path, default: []].formUnion(uids)
    }

    func setSearchUnreadable(_ value: Bool) { searchUnreadable = value }
    func configureFolderOperations(failure: FolderFailureMode = .none, kind: MailFolderMutationKind? = nil, renamedValidity: UInt32? = nil) {
        folderFailure = failure; folderFailureKind = kind; self.renamedValidity = renamedValidity
    }
    func setFolderSnapshot(_ folders: [RemoteMailFolder]) { self.folders = folders }
    func folderSnapshot() -> [RemoteMailFolder] { folders }

    private func rejectFolderMutation(_ kind: MailFolderMutationKind, stage: MailOperationStage) throws {
        if folderFailure == .reject && (folderFailureKind == nil || folderFailureKind == kind) {
            throw MailServerDiagnostic(stage: stage, status: "NO", detail: "Synthetic rejection", kind: .serverRejected, folder: nil)
        }
    }
    private func finishFolderMutation(_ kind: MailFolderMutationKind) async throws {
        guard folderFailureKind == nil || folderFailureKind == kind else { return }
        if folderFailure == .afterApply { throw MailProtocolError.connectionFailed("Synthetic folder response lost") }
        if folderFailure == .hangAfterApply {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in hungContinuations.append(continuation) }
        }
    }
    func createFolder(path: String) async throws {
        folderMutationCalls.append(.init(kind: .create, path: path, destination: nil))
        try rejectFolderMutation(.create, stage: .createFolder)
        guard !folders.contains(where: { $0.path == path }) else { throw MailFolderMutationError.duplicate }
        let leaf = String(path.split(separator: "/").last ?? Substring(path))
        folders.append(.init(path: path, name: MailFoundationAdapter.sessionMailbox(from: leaf), role: .other, delimiter: "/", isSelectable: true))
        statuses[path] = .init(uidValidity: 500, uidNext: 1, messageCount: 0, unreadCount: 0)
        try await finishFolderMutation(.create)
    }
    func renameFolder(path: String, toPath: String) async throws {
        folderMutationCalls.append(.init(kind: .rename, path: path, destination: toPath))
        try rejectFolderMutation(.rename, stage: .renameFolder)
        guard folders.contains(where: { $0.path == path }), !folders.contains(where: { $0.path == toPath }) else { throw MailFolderMutationError.changed }
        let separator = folders.first { $0.path == path }?.delimiter ?? "/"
        let affected = folders.filter { $0.path == path || $0.path.hasPrefix(path + separator) }
        let replacements = affected.map { old -> RemoteMailFolder in
            let changed = toPath + old.path.dropFirst(path.count)
            let leaf = changed.components(separatedBy: separator).last ?? changed
            return .init(path: changed, name: MailFoundationAdapter.sessionMailbox(from: leaf), role: old.role, delimiter: old.delimiter, isSelectable: old.isSelectable)
        }
        for (old, new) in zip(affected, replacements) {
            if let status = statuses.removeValue(forKey: old.path) {
                statuses[new.path] = .init(uidValidity: renamedValidity ?? status.uidValidity, uidNext: status.uidNext, messageCount: status.messageCount, unreadCount: status.unreadCount)
            }
            if let values = summaries.removeValue(forKey: old.path) { summaries[new.path] = values }
        }
        let paths = Set(affected.map(\.path)); folders.removeAll { paths.contains($0.path) }; folders.append(contentsOf: replacements)
        try await finishFolderMutation(.rename)
    }
    func deleteFolder(path: String) async throws {
        folderMutationCalls.append(.init(kind: .delete, path: path, destination: nil))
        try rejectFolderMutation(.delete, stage: .deleteFolder)
        guard let folder = folders.first(where: { $0.path == path }) else { throw MailFolderMutationError.changed }
        if let separator = folder.delimiter, folders.contains(where: { $0.path.hasPrefix(path + separator) }) {
            throw MailServerDiagnostic(stage: .deleteFolder, status: "NO", detail: "HASCHILDREN", kind: .serverRejected, folder: nil)
        }
        folders.removeAll { $0.path == path }; statuses.removeValue(forKey: path); summaries.removeValue(forKey: path)
        try await finishFolderMutation(.delete)
    }
    func setRaw(_ value: Data, uid: UInt32) { rawMessages[uid] = value }
    func fetchRawMessage(path: String, uid: UInt32, maxBytes: Int) async throws -> Data {
        rawFetchCount += 1
        guard let data = rawMessages[uid] else { throw MailExportError.incomplete }
        guard data.count <= maxBytes else { throw MailExportError.tooLarge }
        return data
    }

    /// 在两次同步之间改写服务器侧数据（模拟新邮件 / UIDVALIDITY 变更）。
    func configure(
        statuses: [String: RemoteFolderStatus]? = nil,
        summaries: [String: [RemoteMessageSummary]]? = nil
    ) {
        if let statuses { self.statuses = statuses }
        if let summaries { self.summaries = summaries }
    }

    /// 命中挂起点时一直等待，直到 `disconnect()` 唤醒（对应关闭套接字）。
    private func hangIfNeeded(_ point: HangPoint) async throws {
        guard hangPoint == point else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            hungContinuations.append(continuation)
        }
    }

    func connect() async throws {
        connectCount += 1
        try await hangIfNeeded(.connect)
    }

    func authenticate(username: String, password: String) async throws {
        try await hangIfNeeded(.authenticate)
        authenticatedUser = username
    }

    func listFolders() async throws -> [RemoteMailFolder] {
        await concurrencyProbe?.enter()
        do {
            try await hangIfNeeded(.listFolders)
        } catch {
            await concurrencyProbe?.exit()
            throw error
        }
        await concurrencyProbe?.exit()
        return folders
    }

    func folderStatus(path: String) async throws -> RemoteFolderStatus {
        try await hangIfNeeded(.folderStatus)
        return statuses[path] ?? RemoteFolderStatus(uidValidity: nil, uidNext: nil, messageCount: 0, unreadCount: 0)
    }

    func fetchSummaries(
        path: String,
        sinceUID: UInt32?,
        limit: Int
    ) async throws -> [RemoteMessageSummary] {
        summaryFetchCount += 1
        try await hangIfNeeded(.fetchSummaries)
        fetchRequests.append((path, sinceUID))
        fetchLimits.append(limit)
        guard limit > 0 else { return [] }
        // 与真实适配器一致：`limit` 是 UID 区间跨度（`lower:upper`），不是「返回条数」上限。
        // 若按「实际邮件数量分页」，UID 有空洞时的行为会与真实协议不同，测不出提前结束。
        let all = summaries[path] ?? []
        let lower: UInt32 = sinceUID.map { $0 &+ 1 } ?? 1
        let offset = UInt32(clamping: limit - 1)
        let upper = lower.addingReportingOverflow(offset)
        let window = upper.overflow
            ? all.filter { $0.uid >= lower }                       // "lower:*"
            : all.filter { $0.uid >= lower && $0.uid <= upper.partialValue }
        let snapshot = window.sorted { $0.uid < $1.uid }
        await summaryReadGate?()
        return snapshot
    }

    func fetchBody(
        path: String,
        uid: UInt32,
        maxBytes: Int
    ) async throws -> RemoteMessageBody {
        bodyFetchCount += 1
        try await hangIfNeeded(.fetchBody)
        bodyLimits.append(maxBytes)
        if let bodyFailure { throw MailProtocolError.invalidResponse(bodyFailure) }
        return bodies[uid] ?? RemoteMessageBody(textBody: nil, htmlBody: nil, attachments: [])
    }

    func fetchAttachment(path: String, uid: UInt32, partID: String, maxBytes: Int) async throws -> Data {
        attachmentDownloadCount += 1
        try await hangIfNeeded(.fetchAttachment)
        return Data("attachment bytes".utf8)
    }

    func searchUIDs(path: String, flag: MailFlag) async throws -> [UInt32] {
        if searchUnreadable {
            throw MailProtocolError.invalidResponse("unreadable search response")
        }
        switch flag {
        case .deleted: return (deletedUIDs[path] ?? []).sorted()
        case .seen: return (summaries[path] ?? []).filter(\.isRead).map(\.uid).sorted()
        case .flagged: return (summaries[path] ?? []).filter(\.isStarred).map(\.uid).sorted()
        }
    }

    func allUIDs(path: String) async throws -> [UInt32] {
        if searchUnreadable {
            throw MailProtocolError.invalidResponse("unreadable search response")
        }
        return (summaries[path] ?? []).map(\.uid).sorted()
    }

    func fetchSummaries(path: String, uids: [UInt32]) async throws -> [RemoteMessageSummary] {
        try await hangIfNeeded(.fetchSummaries)
        let ids = Set(uids)
        return (summaries[path] ?? []).filter { ids.contains($0.uid) }
    }

    func storeFlags(path: String, uid: UInt32, add: [MailFlag], remove: [MailFlag]) async throws {
        try await hangIfNeeded(.storeFlags)
        flagCalls.append(FlagCall(path: path, uid: uid, add: add, remove: remove))
        if add.contains(.deleted) { deletedUIDs[path, default: []].insert(uid) }
        if remove.contains(.deleted) { deletedUIDs[path, default: []].remove(uid) }
        summaries[path] = (summaries[path] ?? []).map { summary in
            guard summary.uid == uid else { return summary }
            return RemoteMessageSummary(uid: summary.uid, messageId: summary.messageId, subject: summary.subject,
                from: summary.from, replyTo: summary.replyTo, to: summary.to, cc: summary.cc, date: summary.date,
                isRead: add.contains(.seen) ? true : remove.contains(.seen) ? false : summary.isRead,
                isStarred: add.contains(.flagged) ? true : remove.contains(.flagged) ? false : summary.isStarred,
                sizeBytes: summary.sizeBytes, snippet: summary.snippet)
        }
    }

    func moveMessage(path: String, uid: UInt32, toPath: String) async throws -> RemoteMoveResult {
        if let mutationFailure { throw MailProtocolError.invalidResponse(mutationFailure) }
        moveCalls.append((path: path, uid: uid, toPath: toPath))
        // 目标文件夹会分配新 UID：源 UID 不再有效（RFC 6851）
        guard let summary = (summaries[path] ?? []).first(where: { $0.uid == uid }) else {
            return .unknown
        }
        summaries[path] = (summaries[path] ?? []).filter { $0.uid != uid }
        guard let destination = moveDestinationUID else {
            // 没给 COPYUID：邮件确实到了目标文件夹，但调用方必须自己重新定位
            summaries[toPath, default: []].append(
                RemoteMessageSummary(
                    uid: (summaries[toPath] ?? []).map(\.uid).max().map { $0 + 1 } ?? uid,
                    messageId: summary.messageId,
                    subject: summary.subject,
                    from: summary.from,
                    to: summary.to,
                    cc: summary.cc,
                    date: summary.date,
                    isRead: summary.isRead,
                    isStarred: summary.isStarred,
                    sizeBytes: summary.sizeBytes,
                    snippet: summary.snippet
                )
            )
            return .unknown
        }
        summaries[toPath, default: []].append(
            RemoteMessageSummary(
                uid: destination,
                messageId: summary.messageId,
                subject: summary.subject,
                from: summary.from,
                to: summary.to,
                cc: summary.cc,
                date: summary.date,
                isRead: summary.isRead,
                isStarred: summary.isStarred,
                sizeBytes: summary.sizeBytes,
                snippet: summary.snippet
            )
        )
        return RemoteMoveResult(uid: destination, uidValidity: 1)
    }

    func supportsUIDPlus() async -> Bool { supportsUIDPlus }

    /// 测试辅助：服务器当前已标 `\Deleted` 的 UID
    func searchDeleted(path: String) -> [UInt32] {
        (deletedUIDs[path] ?? []).sorted()
    }

    /// 测试辅助：某文件夹当前的服务器摘要
    func summaries(path: String) -> [RemoteMessageSummary] {
        (summaries[path] ?? []).sorted { $0.uid < $1.uid }
    }


    func markDeleted(path: String, uid: UInt32) async throws {
        if let mutationFailure { throw MailProtocolError.invalidResponse(mutationFailure) }
        deleteCalls.append((path: path, uid: uid))
        deletedUIDs[path, default: []].insert(uid)
    }

    func unmarkDeleted(path: String, uid: UInt32) async throws {
        deletedUIDs[path, default: []].remove(uid)
    }

    func expungeUIDs(path: String, uids: [UInt32]) async throws {
        expungeUIDCalls.append((path: path, uids: uids))
        guard supportsUIDPlus else {
            throw MailProtocolError.invalidResponse("UID EXPUNGE unsupported")
        }
        guard !expungeNoop else { return }
        for uid in uids { deletedUIDs[path, default: []].remove(uid) }
        let ownedDrafts = Set(uids).intersection(draftMembers[path] ?? [])
        summaries[path]?.removeAll { ownedDrafts.contains($0.uid) }
        draftMembers[path]?.subtract(ownedDrafts)
    }

    func expungeAllDeleted(path: String) async throws {
        expungeAllCalls.append(path)
        guard !expungeNoop else { return }
        deletedUIDs[path] = []
    }

    func disconnect() async {
        disconnectCount += 1
        // 关闭连接会唤醒所有挂起中的调用（真实实现里读会以错误返回）
        let pending = hungContinuations
        hungContinuations = []
        for continuation in pending {
            continuation.resume(throwing: MailProtocolError.connectionFailed("connection closed"))
        }
    }
}

/// 测试用故障：模拟本地落库失败。
enum MailServiceTestError: Error, Equatable {
    case writeFailed
}

// MARK: - Concurrency Probe

/// 并发探针：记录「同时在内」的最大数量，用于验证账号租约把同一账号上的
/// 网络操作真正串行化（`enter` 里故意停顿以放大重叠窗口）。
actor MailConcurrencyProbe {
    private var active = 0
    private(set) var maxActive = 0
    private let holdNanoseconds: UInt64

    init(holdNanoseconds: UInt64 = 0) {
        self.holdNanoseconds = holdNanoseconds
    }

    func enter() async {
        active += 1
        maxActive = max(maxActive, active)
        if holdNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: holdNanoseconds)
        }
    }

    func exit() {
        active -= 1
    }
}

// MARK: - Mock Send Client

/// 内存版 `MailSendClient`：记录 SMTP 投递内容，用于验证发信编排与本地已发送副本。
actor MockSendClient: MailSendClient {
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var authenticatedUser: String?
    private(set) var sent: [OutgoingMail] = []

    /// 非空时 `send` 抛错（验证投递失败不删草稿、不落本地副本）。
    private let failure: String?
    /// 为真时 `send` 挂起，直到 `disconnect()` 唤醒（验证「结果未知」语义）。
    private let hangsOnSend: Bool
    private var hungContinuations: [CheckedContinuation<Void, Error>] = []

    init(failure: String? = nil, hangsOnSend: Bool = false) {
        self.failure = failure
        self.hangsOnSend = hangsOnSend
    }

    func connect() async throws { connectCount += 1 }

    func authenticate(username: String, password: String) async throws {
        authenticatedUser = username
    }

    func send(_ message: OutgoingMail) async throws {
        if hangsOnSend {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                hungContinuations.append(continuation)
            }
        }
        if let failure { throw MailProtocolError.sendFailed(failure) }
        sent.append(message)
    }

    func disconnect() async {
        disconnectCount += 1
        let pending = hungContinuations
        hungContinuations = []
        for continuation in pending {
            continuation.resume(throwing: MailProtocolError.connectionFailed("connection closed"))
        }
    }
}

// MARK: - Helpers

private func makeSyncDatabase() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    // Body reads now reuse the same source review and atomic publish boundary
    // as export, including folder-operation state from the space migrations.
    try DatabaseBootstrap.prepareSpace(queue)
    return queue
}

private func syncAccountFixture() -> MailAccount {
    MailAccount(
        displayName: "工作邮箱",
        emailAddress: "user@example.com",
        imapHost: "imap.example.com",
        imapPort: 993,
        imapSecurity: .tls,
        smtpHost: "smtp.example.com",
        smtpPort: 587,
        smtpSecurity: .startTLS,
        username: "user@example.com"
    )
}

private func remoteSummary(uid: UInt32, isRead: Bool = false) -> RemoteMessageSummary {
    RemoteMessageSummary(
        uid: uid,
        messageId: "<\(uid)@example.com>",
        subject: "主题 \(uid)",
        from: [MailAddress(name: "发件人", address: "sender@example.com")],
        to: [MailAddress(name: "收件人", address: "user@example.com")],
        cc: [],
        date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
        isRead: isRead,
        isStarred: false,
        sizeBytes: 2048,
        snippet: "摘要 \(uid)"
    )
}

/// 组装「同步服务 + 本地服务 + 账号服务」，口令由闭包提供以避免触碰 Keychain。
private func makeSyncStack(
    mock: MockMailClient,
    sender: MockSendClient = MockSendClient(),
    password: String? = "secret",
    timeoutBudget: MailTimeoutBudget = .default,
    batchSize: Int = MailSyncService.syncBatchSize,
    bodyByteLimit: Int = MailSyncService.bodyByteLimit,
    space: AppSpace = .personal,
    attachmentDirectory: URL? = nil,
    coordinator: MailAccountCoordinator = MailAccountCoordinator()
) throws -> (
    service: MailSyncService,
    mail: MailService,
    accounts: MailAccountService,
    sender: MockSendClient
) {
    let queue = try makeSyncDatabase()
    let accounts = MailAccountService(databaseQueue: queue, space: space)
    let mail = MailService(databaseQueue: queue)
    let service = MailSyncService(
        accountService: accounts,
        mail: mail,
        space: space,
        coordinator: coordinator,
        attachmentDirectory: attachmentDirectory,
        clientFactory: { _ in mock },
        sendClientFactory: { _ in sender },
        passwordProvider: { _ in password },
        timeoutBudget: timeoutBudget,
        batchSize: batchSize,
        bodyByteLimit: bodyByteLimit
    )
    return (service, mail, accounts, sender)
}

private let inboxStatus = RemoteFolderStatus(uidValidity: 10, uidNext: 4, messageCount: 3, unreadCount: 1)

/// 含 INBOX / Sent / Archive 的服务器侧夹具（写操作测试用）。
private func writeFixtureMock(
    mutationFailure: String? = nil,
    supportsUIDPlus: Bool = false,
    expungeNoop: Bool = false,
    searchUnreadable: Bool = false,
    moveDestinationUID: UInt32? = nil
) -> MockMailClient {
    MockMailClient(
        folders: [
            RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox),
            RemoteMailFolder(path: "Sent", name: "Sent", role: .sent),
            RemoteMailFolder(path: "Archive", name: "Archive", role: .archive)
        ],
        statuses: [
            "INBOX": inboxStatus,
            "Sent": RemoteFolderStatus(uidValidity: 30, uidNext: 1, messageCount: 0, unreadCount: 0),
            "Archive": RemoteFolderStatus(uidValidity: 40, uidNext: 1, messageCount: 0, unreadCount: 0)
        ],
        summaries: ["INBOX": [remoteSummary(uid: 1)], "Sent": [], "Archive": []],
        mutationFailure: mutationFailure,
        supportsUIDPlus: supportsUIDPlus,
        expungeNoop: expungeNoop,
        searchUnreadable: searchUnreadable,
        moveDestinationUID: moveDestinationUID
    )
}

/// 移动测试用：服务器的 `MOVE` 会在目标文件夹分配新 UID（如 77）。
private func moveFixtureMock(destinationUID: UInt32?) -> MockMailClient {
    writeFixtureMock(moveDestinationUID: destinationUID)
}

// MARK: - Account Sync

@Suite("Mail sync")
struct MailSyncServiceTests {

    @Test("Sparse older mail can be loaded and coverage becomes complete")
    func sparseHistoryCoverage() async throws {
        let account = syncAccountFixture()
        let summaries = [remoteSummary(uid: 1), remoteSummary(uid: 10_000), remoteSummary(uid: 10_001)]
        let mock = MockMailClient(folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": RemoteFolderStatus(uidValidity: 10, uidNext: 10_002, messageCount: 3, unreadCount: 3)],
            summaries: ["INBOX": summaries])
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        let partial = try await stack.mail.coverage(folderID: folder.id)
        #expect(partial.cachedCount == 2 && partial.remoteCount == 3 && !partial.isComplete)
        _ = try await stack.service.loadEarlier(accountId: account.id, folderId: folder.id)
        let complete = try await stack.mail.coverage(folderID: folder.id)
        #expect(complete.isComplete && complete.cachedCount == 3)
        #expect(try await stack.mail.messages(folderId: folder.id).map(\.uid).contains(1))
    }

    @Test("Remote deletes and flags converge while an offline local edit remains authoritative until acknowledged")
    func remoteReconciliationAndPendingEdits() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": RemoteFolderStatus(uidValidity: 10, uidNext: 3, messageCount: 2, unreadCount: 2)],
            summaries: ["INBOX": [remoteSummary(uid: 1), remoteSummary(uid: 2)]])
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        await mock.configure(statuses: ["INBOX": RemoteFolderStatus(uidValidity: 10, uidNext: 3, messageCount: 1, unreadCount: 0)],
            summaries: ["INBOX": [remoteSummary(uid: 2, isRead: true)]])
        _ = try await stack.service.syncFolder(accountId: account.id, folderId: folder.id)
        let messages = try await stack.mail.messages(folderId: folder.id)
        #expect(messages.count == 1 && messages.first?.isRead == true)
        let message = try #require(messages.first)
        try await stack.mail.setFlags(messageId: message.id, isRead: false, pendingRemote: true)
        try await stack.mail.reconcile(folderID: folder.id, previouslyCached: [2], remote: [2], seen: [2], starred: [])
        #expect(try await stack.mail.message(id: message.id)?.isRead == false)
        _ = try await stack.service.syncFolder(accountId: account.id, folderId: folder.id)
        #expect(try await stack.mail.pendingFlags(folderID: folder.id).isEmpty)
        #expect(try await stack.mail.message(id: message.id)?.isRead == false)
        await mock.configure(summaries: ["INBOX": [remoteSummary(uid: 2, isRead: true)]])
        _ = try await stack.service.syncFolder(accountId: account.id, folderId: folder.id)
        #expect(try await stack.mail.message(id: message.id)?.isRead == true)
    }

    @Test("首次同步：发现文件夹、全量拉取并写入同步游标")
    func firstSyncFetchesEverything() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": inboxStatus],
            summaries: ["INBOX": [remoteSummary(uid: 1), remoteSummary(uid: 2), remoteSummary(uid: 3)]]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)

        let result = try await stack.service.syncAccount(accountId: account.id)

        #expect(result.folderCount == 1)
        #expect(result.messageCount == 3)

        let folders = try await stack.mail.folders(accountId: account.id)
        #expect(folders.count == 1)
        #expect(folders.first?.uidValidity == 10)
        #expect(folders.first?.uidNext == 4)
        #expect(folders.first?.unreadCount == 1)
        #expect(folders.first?.lastSyncAt != nil)

        let messages = try await stack.mail.messages(folderId: try #require(folders.first).id)
        #expect(messages.count == 3)
        #expect(messages.first?.uid == 3)

        // 首次同步本地无游标 → 全量（sinceUID 为 nil）
        let requests = await mock.fetchRequests
        #expect(requests.count == 1)
        #expect(requests.first?.sinceUID == nil)
        #expect(requests.first?.path == "INBOX")
    }

    @Test("RFC 2047 编码字解码：中文主题与显示名，非编码文本原样")
    func decodedHeaderHandlesRfc2047() {
        // Base64 编码的 UTF-8 中文
        #expect(MailHeaderText.decoded("=?UTF-8?B?5L2g5aW9?=") == "你好")
        // Quoted-Printable 编码的 ISO-8859-1
        #expect(MailHeaderText.decoded("=?ISO-8859-1?Q?Andr=E9?=") == "André")
        // 未编码的普通文本原样返回
        #expect(MailHeaderText.decoded("Plain subject") == "Plain subject")
        #expect(MailHeaderText.decoded("") == "")
        // 幂等：已解码文本再次解码不变（读取侧兜底依赖此性质）
        #expect(MailHeaderText.decoded(MailHeaderText.decoded("=?UTF-8?B?5L2g5aW9?=")) == "你好")
    }

    @Test("正文归一化：纯文本槽里的 HTML 源码提升为 HTML 呈现")
    func normalizedBodiesPromotesHTMLText() {
        let htmlSource = "<!DOCTYPE html><html><body><div>hi</div></body></html>"
        #expect(MailFoundationAdapter.normalizedBodies(text: htmlSource, html: nil).html == htmlSource)
        // 已有 HTML 部件时保持原样
        let kept = MailFoundationAdapter.normalizedBodies(text: "plain", html: "<p>x</p>")
        #expect(kept.text == "plain")
        #expect(kept.html == "<p>x</p>")
        // 普通文本不提升
        #expect(MailFoundationAdapter.normalizedBodies(text: "Hello, world", html: nil).html == nil)
        // 以 "<" 开头但并非 HTML 文档的内容不提升
        #expect(MailFoundationAdapter.looksLikeHTML("<not html") == false)
        #expect(MailFoundationAdapter.looksLikeHTML("  <html><body>x</body></html>"))
    }

    @Test("首次同步只锚定最近 UID 窗口，不回扫全部历史")
    func firstSyncAnchorsToRecentUIDWindow() async throws {
        let account = syncAccountFixture()
        let allUIDs = (1...3000).map { UInt32($0) }
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": RemoteFolderStatus(uidValidity: 10, uidNext: 3001, messageCount: 3000, unreadCount: 0)],
            summaries: ["INBOX": allUIDs.map { remoteSummary(uid: $0) }]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)

        let result = try await stack.service.syncAccount(accountId: account.id)

        // 首屏只覆盖最近一个窗口（UID 2001...3000），不回扫 1...2000
        #expect(result.messageCount == 1000)
        let requests = await mock.fetchRequests
        #expect(requests.first?.sinceUID == 2000)

        let folders = try await stack.mail.folders(accountId: account.id)
        let messages = try await stack.mail.messages(folderId: try #require(folders.first).id, limit: 5000)
        #expect(messages.count == 1000)
        #expect(messages.map(\.uid).min() == 2001)
    }

    @Test("非可选择文件夹（\\Noselect 容器）保留为层级节点，但不进同步循环")
    func nonSelectableFoldersAreRetainedAsContainers() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [
                RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox),
                RemoteMailFolder(path: "Archive", name: "Archive", role: .archive, isSelectable: false),
                RemoteMailFolder(path: "Archive/2024", name: "2024", role: .other, delimiter: "/", isSelectable: true)
            ],
            statuses: [
                "INBOX": inboxStatus,
                "Archive/2024": RemoteFolderStatus(uidValidity: 50, uidNext: 1, messageCount: 0, unreadCount: 0)
            ],
            summaries: ["INBOX": [remoteSummary(uid: 1)], "Archive/2024": []]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)

        _ = try await stack.service.syncAccount(accountId: account.id)

        let folders = try await stack.mail.folders(accountId: account.id)
        let paths = folders.map(\.path).sorted()
        #expect(paths == ["Archive", "Archive/2024", "INBOX"])
        // 容器节点不参与同步循环，只有可邮件文件夹发起 fetch
        let requests = await mock.fetchRequests
        #expect(requests.map(\.path).sorted() == ["Archive/2024", "INBOX"])
    }

    @Test("层级父子链：按 delimiter 反推 parentPath，补全缺失中间节点")
    func folderHierarchyIsReconstructedFromDelimiter() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [
                RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox),
                RemoteMailFolder(path: "Groups/Work/2024", name: "2024", role: .other, delimiter: "/", isSelectable: true)
            ],
            statuses: [
                "INBOX": inboxStatus,
                "Groups/Work/2024": RemoteFolderStatus(uidValidity: 60, uidNext: 1, messageCount: 0, unreadCount: 0)
            ],
            summaries: ["INBOX": [remoteSummary(uid: 1)], "Groups/Work/2024": []]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)

        _ = try await stack.service.syncAccount(accountId: account.id)

        let folders = try await stack.mail.folders(accountId: account.id)
        // 服务器只报了 Groups/Work/2024；中间层 Groups、Groups/Work 由 buildHierarchy 合成
        let paths = folders.map(\.path).sorted()
        #expect(paths == ["Groups", "Groups/Work", "Groups/Work/2024", "INBOX"])
        let leaf = folders.first { $0.path == "Groups/Work/2024" }
        #expect(leaf?.parentPath == "Groups/Work")
        #expect(leaf?.delimiter == "/")
        let mid = folders.first { $0.path == "Groups/Work" }
        #expect(mid?.parentPath == "Groups")
        #expect(mid?.isContainer == true)
        let root = folders.first { $0.path == "Groups" }
        #expect(root?.parentPath == nil)
        #expect(root?.isContainer == true)
    }

    @Test("增量同步：第二次以本地最大 UID 为起点，仅请求新邮件")
    func incrementalSyncUsesLocalMaxUID() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": inboxStatus],
            summaries: ["INBOX": [remoteSummary(uid: 1), remoteSummary(uid: 2), remoteSummary(uid: 3)]]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)

        _ = try await stack.service.syncAccount(accountId: account.id)
        // 服务器新增一封（UID 4），并推进 UIDNEXT
        await mock.configure(
            statuses: ["INBOX": RemoteFolderStatus(uidValidity: 10, uidNext: 5, messageCount: 4, unreadCount: 2)],
            summaries: ["INBOX": [1, 2, 3, 4].map { remoteSummary(uid: UInt32($0)) }]
        )
        let second = try await stack.service.syncAccount(accountId: account.id)

        #expect(second.messageCount == 1)
        let requests = await mock.fetchRequests
        #expect(requests.last?.sinceUID == 3)

        let folders = try await stack.mail.folders(accountId: account.id)
        let messages = try await stack.mail.messages(folderId: try #require(folders.first).id)
        #expect(messages.count == 4)
    }

    @Test("UIDVALIDITY 变更：清空本地该文件夹后全量重建")
    func uidValidityChangeResetsFolder() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": inboxStatus],
            summaries: ["INBOX": [remoteSummary(uid: 1), remoteSummary(uid: 2), remoteSummary(uid: 3)]]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)

        _ = try await stack.service.syncAccount(accountId: account.id)

        // UID 空间重建：UIDVALIDITY 变化，服务器只剩 2 封
        await mock.configure(
            statuses: ["INBOX": RemoteFolderStatus(uidValidity: 99, uidNext: 3, messageCount: 2, unreadCount: 0)],
            summaries: ["INBOX": [remoteSummary(uid: 1), remoteSummary(uid: 2)]]
        )
        _ = try await stack.service.syncAccount(accountId: account.id)

        let folders = try await stack.mail.folders(accountId: account.id)
        let folder = try #require(folders.first)
        #expect(folder.uidValidity == 99)
        let messages = try await stack.mail.messages(folderId: folder.id)
        #expect(messages.count == 2)

        // 重建后重新全量拉取
        let requests = await mock.fetchRequests
        #expect(requests.last?.sinceUID == nil)
    }

    @Test("账号缺少口令：抛出 missingPassword 且不发起连接")
    func missingPasswordFailsWithoutConnecting() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient()
        let stack = try makeSyncStack(mock: mock, password: nil)
        try await stack.accounts.save(account, password: nil)

        await #expect(throws: MailSyncError.missingPassword) {
            try await stack.service.syncAccount(accountId: account.id)
        }
        #expect(await mock.connectCount == 0)
    }

    @Test("账号不存在：抛出 accountNotFound")
    func unknownAccountFails() async throws {
        let mock = MockMailClient()
        let stack = try makeSyncStack(mock: mock)

        await #expect(throws: MailSyncError.accountNotFound) {
            try await stack.service.syncAccount(accountId: UUID())
        }
    }

    // MARK: - Body

    @Test("附件名为空或包含路径时仍保存为独立文件，并可复用缓存", arguments: [
        ("", "application/pdf", "attachment.pdf"),
        ("   ", "application/pdf", "attachment.pdf"),
        (".", "application/pdf", "attachment.pdf"),
        ("..", "application/pdf", "attachment.pdf"),
        ("/", "application/pdf", "attachment.pdf"),
        ("\\", "application/pdf", "attachment.pdf"),
        ("folder/", "application/pdf", "attachment.pdf"),
        ("\u{0000}", "application/pdf", "attachment.pdf"),
        ("../../报表.pdf", "application/pdf", "报表.pdf"),
        ("C:\\reports\\报表.pdf", "application/pdf", "报表.pdf"),
        ("", "application/x-unknown", "attachment")
    ])
    func attachmentFilenameDownload(filename: String, mimeType: String, expectedName: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = MockMailClient()
        let stack = try makeSyncStack(mock: mock, attachmentDirectory: directory)
        let account = syncAccountFixture()
        try await stack.accounts.save(account, password: nil)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox")
        try await stack.mail.upsertFolders([folder])
        let message = MailMessage(accountId: account.id, folderId: folder.id, uid: 1)
        try await stack.mail.upsertMessages([message])
        let attachment = MailAttachment(messageId: message.id, filename: filename, mimeType: mimeType, partID: "2")
        try await stack.mail.saveAttachments([attachment])

        let url = try await stack.service.downloadAttachment(messageId: message.id, attachmentID: attachment.id)
        #expect(url.lastPathComponent == expectedName)
        #expect(url.deletingLastPathComponent() == directory.appendingPathComponent(attachment.id.uuidString, isDirectory: true))
        #expect(try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
        #expect(try Data(contentsOf: url) == Data("attachment bytes".utf8))
        #expect(try await stack.mail.attachments(messageId: message.id).first?.localPath == url.path)
        let cached = try await stack.service.downloadAttachment(messageId: message.id, attachmentID: attachment.id)
        #expect(cached == url)
        #expect(await mock.attachmentDownloadCount == 1)
    }

    @Test("缓存路径指向目录时重新下载，不能把目录作为附件预览")
    func attachmentCacheRequiresFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = MockMailClient()
        let stack = try makeSyncStack(mock: mock, attachmentDirectory: directory)
        let account = syncAccountFixture()
        try await stack.accounts.save(account, password: nil)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox")
        try await stack.mail.upsertFolders([folder])
        let message = MailMessage(accountId: account.id, folderId: folder.id, uid: 1)
        try await stack.mail.upsertMessages([message])
        var attachment = MailAttachment(messageId: message.id, filename: "report.pdf", mimeType: "application/pdf", partID: "2")
        let cachedDirectory = directory.appendingPathComponent(attachment.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cachedDirectory, withIntermediateDirectories: true)
        attachment.localPath = cachedDirectory.path
        try await stack.mail.saveAttachments([attachment])

        let url = try await stack.service.downloadAttachment(messageId: message.id, attachmentID: attachment.id)
        #expect(url.lastPathComponent == "report.pdf")
        #expect(try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
        #expect(try Data(contentsOf: url) == Data("attachment bytes".utf8))
        #expect(await mock.attachmentDownloadCount == 1)
    }

    @Test("Whole-message fallback commits originals with local image parts, rejects wrong identity, and recovers evicted originals",
          arguments: [false, true])
    func fallbackInlineOriginalPersistence(_ wrongIdentity: Bool) async throws {
        let account = syncAccountFixture(), imageBytes = Data([0, 1, 2, 3])
        let original = Data([
            "From: sender@example.test", "Message-ID: <\(wrongIdentity ? "wrong" : "1")@example.com>", "MIME-Version: 1.0",
            "Content-Type: multipart/related; boundary=original", "", "--original",
            "Content-Type: text/html; charset=utf-8", "", "<img src='cid:logo@example.test'>",
            "--original", "Content-Type: image/png", "Content-Disposition: inline; filename=logo.png",
            "Content-ID: <logo@example.test>", "Content-Transfer-Encoding: base64", "", imageBytes.base64EncodedString(), "--original--", ""
        ].joined(separator: "\r\n").utf8)
        let parsed = try MailSmtpAdapter.localBody(original)
        let remote = RemoteMessageBody(textBody: parsed.textBody, htmlBody: parsed.htmlBody, attachments: parsed.attachments, rawMessage: original)
        let mock = MockMailClient(folders: [.init(path: "INBOX", name: "Inbox", role: .inbox)],
            statuses: ["INBOX": inboxStatus], summaries: ["INBOX": [remoteSummary(uid: 1)]], bodies: [1: remote])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stack = try makeSyncStack(mock: mock, attachmentDirectory: root)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        let message = try #require(try await stack.mail.messages(folderId: folder.id).first)
        if wrongIdentity {
            await #expect(throws: MailExportError.changed) { try await stack.service.loadBody(messageId: message.id) }
            #expect(try await stack.mail.rawMessage(id: message.id) == nil)
            #expect(try await stack.mail.body(messageId: message.id) == nil)
            #expect(try await stack.mail.attachments(messageId: message.id).isEmpty)
            return
        }
        _ = try await stack.service.loadBody(messageId: message.id)
        #expect(try await stack.mail.rawMessage(id: message.id)?.data == original)
        var part = try #require(try await stack.mail.attachments(messageId: message.id).first)
        #expect(part.partID == "local:0" && part.isInline)
        let url = try await stack.service.downloadAttachment(messageId: message.id, attachmentID: part.id, downloadIfNeeded: false)
        #expect(try MailAttachmentFile.read(url) == imageBytes)
        #expect(await mock.attachmentDownloadCount == 0)
        // Simulate both original and attachment cache eviction. A fresh whole-
        // message fallback must be usable in this very same download request.
        try FileManager.default.removeItem(at: url)
        try await stack.mail.databaseQueue.write { db in
            try db.execute(sql: "DELETE FROM mail_raw_messages WHERE messageID=?", arguments: [message.id.uuidString])
        }
        part = try #require(try await stack.mail.attachments(messageId: message.id).first)
        let recovered = try await stack.service.downloadAttachment(messageId: message.id, attachmentID: part.id)
        #expect(try MailAttachmentFile.read(recovered) == imageBytes)
        #expect(await mock.bodyFetchCount == 2)
        #expect(await mock.attachmentDownloadCount == 0)
    }

    @Test("按需正文：成功落库正文/附件并置 ready")
    func loadBodyPersistsAndMarksReady() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": inboxStatus],
            summaries: ["INBOX": [remoteSummary(uid: 1)]],
            bodies: [
                1: RemoteMessageBody(
                    textBody: "纯文本正文",
                    htmlBody: "<p>HTML 正文</p>",
                    attachments: [
                        RemoteAttachment(
                            filename: "报表.pdf",
                            mimeType: "application/pdf",
                            sizeBytes: 12345,
                            contentId: nil,
                            isInline: false
                        )
                    ]
                )
            ]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        let message = try #require(try await stack.mail.messages(folderId: folder.id).first)

        let body = try await stack.service.loadBody(messageId: message.id)

        #expect(body.textBody == "纯文本正文")
        #expect(body.htmlBody == "<p>HTML 正文</p>")

        let stored = try #require(try await stack.mail.body(messageId: message.id))
        #expect(stored.textBody == "纯文本正文")

        let attachments = try await stack.mail.attachments(messageId: message.id)
        #expect(attachments.map(\.filename) == ["报表.pdf"])

        let refreshed = try #require(try await stack.mail.message(id: message.id))
        #expect(refreshed.hasAttachments)
        #expect(refreshed.bodyState == .ready)
    }

    @Test("按需正文：失败时置 failed 并向上抛错")
    func loadBodyFailureMarksFailed() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": inboxStatus],
            summaries: ["INBOX": [remoteSummary(uid: 1)]],
            bodyFailure: "server exploded"
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        let message = try #require(try await stack.mail.messages(folderId: folder.id).first)

        await #expect(throws: MailProtocolError.invalidResponse("server exploded")) {
            try await stack.service.loadBody(messageId: message.id)
        }
        let refreshed = try #require(try await stack.mail.message(id: message.id))
        #expect(refreshed.bodyState == .failed)
    }

    // MARK: - Flag Write-back

    @Test("已读回写：本地立即生效并推送 \\Seen")
    func setReadWritesLocalAndRemote() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": inboxStatus],
            summaries: ["INBOX": [remoteSummary(uid: 1)]]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        let message = try #require(try await stack.mail.messages(folderId: folder.id).first)
        #expect(!message.isRead)

        try await stack.service.setRead(messageId: message.id, isRead: true)

        let refreshed = try #require(try await stack.mail.message(id: message.id))
        #expect(refreshed.isRead)

        let calls = await mock.flagCalls
        #expect(calls.count == 1)
        #expect(calls.first?.uid == 1)
        #expect(calls.first?.path == "INBOX")
        #expect(calls.first?.add == [.seen])
        #expect(calls.first?.remove.isEmpty == true)
    }

    @Test("星标回写：取消星标时推送 -FLAGS \\Flagged")
    func setStarredRemovesFlag() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": inboxStatus],
            summaries: ["INBOX": [remoteSummary(uid: 2)]]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        let message = try #require(try await stack.mail.messages(folderId: folder.id).first)

        try await stack.service.setStarred(messageId: message.id, isStarred: true)
        try await stack.service.setStarred(messageId: message.id, isStarred: false)

        let refreshed = try #require(try await stack.mail.message(id: message.id))
        #expect(!refreshed.isStarred)

        let calls = await mock.flagCalls
        #expect(calls.count == 2)
        #expect(calls.first?.add == [.flagged])
        #expect(calls.last?.remove == [.flagged])
    }
}

// MARK: - Send / Move / Delete

@Suite("Mail write operations")
struct MailWriteOperationTests {
    @Test("Raw export checks identity, preserves bytes and reuses the current space cache")
    func rawExportIdentityAndCache() async throws {
        let mock = writeFixtureMock(), stack = try makeSyncStack(mock: mock), account = syncAccountFixture()
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        let folder = try #require(try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox })
        let message = try #require(try await stack.mail.messages(folderId: folder.id).first)
        await #expect(throws: MailExportError.self) { try await stack.service.rawMessage(messageId: message.id, downloadIfNeeded: false) }
        #expect(await mock.rawFetchCount == 0)
        await mock.configure(statuses: [folder.path: .init(uidValidity: 999, uidNext: 4, messageCount: 3, unreadCount: 1)])
        await #expect(throws: MailExportError.self) { try await stack.service.rawMessage(messageId: message.id, downloadIfNeeded: true) }
        #expect(await mock.rawFetchCount == 0)
        await mock.configure(statuses: [folder.path: inboxStatus])
        await mock.setRaw(Data("Message-ID: <wrong@example.com>\r\n\r\nWrong body".utf8), uid: message.uid)
        await #expect(throws: MailExportError.self) { try await stack.service.rawMessage(messageId: message.id, downloadIfNeeded: true) }
        #expect(try await stack.mail.rawMessage(id: message.id) == nil)
        let data = Data("Message-ID: \(message.messageId!)\r\nX-Unknown: preserve\r\n\r\nOriginal\r\n".utf8)
        await mock.setRaw(data, uid: message.uid)
        let exported = try await stack.service.rawMessage(messageId: message.id, downloadIfNeeded: true)
        #expect(exported.kind == .received && exported.data == data)
        _ = try await stack.service.rawMessage(messageId: message.id, downloadIfNeeded: false)
        #expect(await mock.rawFetchCount == 2)
    }

    @Test("Batch moves retain failures, deduplicate IDs and never fall back to permanent deletion")
    func batchMoveToTrashAndMissingTarget() async throws {
        let mock = MockMailClient(), stack = try makeSyncStack(mock: mock), account = syncAccountFixture()
        try await stack.accounts.save(account, password: nil)
        let inbox = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox", role: .inbox)
        let trash = MailFolder(accountId: account.id, path: "Trash", name: "Trash", role: .trash)
        try await stack.mail.upsertFolders([inbox, trash])
        let first = try await stack.mail.saveLocalMessage(.init(accountId: account.id, folderId: inbox.id, uid: 0, subject: "one"))
        let second = try await stack.mail.saveLocalMessage(.init(accountId: account.id, folderId: inbox.id, uid: 0, subject: "two"))
        let outsideTrash = await stack.service.applyBatch(messageIDs: [first.id], action: .permanentlyDelete)
        #expect(outsideTrash.succeeded.isEmpty && outsideTrash.failures.count == 1)
        #expect(try await stack.mail.message(id: first.id) != nil)
        let missing = UUID()
        let result = await stack.service.applyBatch(messageIDs: [first.id, missing, second.id, first.id], action: .moveToRole(.trash))
        #expect(result.succeeded == [first.id, second.id] && result.failures.map(\.messageID) == [missing])
        #expect(try await stack.mail.message(id: first.id)?.folderId == trash.id)
        #expect(try await stack.mail.message(id: second.id)?.folderId == trash.id)
        #expect(await mock.deleteCalls.isEmpty)
        #expect(await mock.moveCalls.isEmpty)
        let absent = await stack.service.applyBatch(messageIDs: [first.id], action: .moveToRole(.archive))
        #expect(absent.failures.count == 1 && absent.succeeded.isEmpty)
        #expect(try await stack.mail.message(id: first.id)?.folderId == trash.id)
        let deleted = await stack.service.applyBatch(messageIDs: [first.id], action: .permanentlyDelete)
        #expect(deleted.succeeded == [first.id])
        #expect(try await stack.mail.message(id: first.id) == nil)
    }

    @Test("Cancelled batches preserve completed work and flagging local copies avoids IMAP")
    func cancelledBatchAndLocalFlags() async throws {
        let mock = MockMailClient(), stack = try makeSyncStack(mock: mock), account = syncAccountFixture()
        try await stack.accounts.save(account, password: nil)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox", role: .inbox)
        try await stack.mail.upsertFolders([folder])
        let first = try await stack.mail.saveLocalMessage(.init(accountId: account.id, folderId: folder.id, uid: 0))
        let second = try await stack.mail.saveLocalMessage(.init(accountId: account.id, folderId: folder.id, uid: 0))
        let task = Task {
            await stack.service.applyBatch(messageIDs: [first.id, second.id], action: .read(true)) { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await task.value
        #expect(result.succeeded == [first.id] && result.unprocessed == [second.id])
        #expect(try await stack.mail.message(id: first.id)?.isRead == true)
        #expect(try await stack.mail.message(id: second.id)?.isRead == false)
        #expect(await mock.connectCount == 0)
        #expect(!MailBatchAction.moveToRole(.trash).allowsDirectRetry)
        #expect(!MailBatchAction.permanentlyDelete.allowsDirectRetry)
    }

    @Test("发送草稿：SMTP 投递成功后删除草稿并落本地已发送副本")
    func sendDeliversAndStoresLocalCopy() async throws {
        let account = syncAccountFixture()
        let sender = MockSendClient()
        let stack = try makeSyncStack(mock: writeFixtureMock(), sender: sender)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let draft = MailDraft(
            accountId: account.id,
            to: [MailAddress(name: "收件人", address: "rcpt@example.com")],
            cc: [MailAddress(name: "", address: "cc@example.com")],
            bcc: [MailAddress(name: "", address: "bcc@example.com")],
            subject: "你好",
            bodyText: "正文内容"
        )
        try await stack.mail.saveDraft(draft)

        let sent = try #require(try await stack.service.send(draft: draft))

        // SMTP 投递：信封含 To+Cc+Bcc，From 取账号地址
        let delivered = try #require(await sender.sent.first)
        #expect(delivered.from.address == "user@example.com")
        #expect(delivered.recipients.map(\.address) == ["rcpt@example.com", "cc@example.com", "bcc@example.com"])
        #expect(delivered.subject == "你好")
        #expect(await sender.authenticatedUser == "user@example.com")

        // 草稿已删除
        #expect(try await stack.mail.drafts(accountId: account.id).isEmpty)

        // 本地副本：落在 Sent、UID 属保留区间、正文可渲染
        let sentFolder = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .sent }
        )
        #expect(sent.folderId == sentFolder.id)
        #expect(sent.uid >= MailService.localUIDFloor)
        #expect(sent.bodyState == .ready)
        #expect(try await stack.mail.body(messageId: sent.id)?.textBody == "正文内容")

        // 本地副本不污染服务器增量游标
        #expect(try await stack.mail.maxUID(folderId: sentFolder.id) == nil)
    }

    @Test("发送失败：草稿保留且不写本地副本")
    func sendFailureKeepsDraft() async throws {
        let account = syncAccountFixture()
        let sender = MockSendClient(failure: "relay denied")
        let stack = try makeSyncStack(mock: writeFixtureMock(), sender: sender)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let draft = MailDraft(
            accountId: account.id,
            to: [MailAddress(name: "", address: "rcpt@example.com")],
            subject: "失败",
            bodyText: "x"
        )
        try await stack.mail.saveDraft(draft)

        await #expect(throws: MailProtocolError.sendFailed("relay denied")) {
            _ = try await stack.service.send(draft: draft)
        }

        #expect(try await stack.mail.drafts(accountId: account.id).count == 1)
        let sentFolder = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .sent }
        )
        #expect(try await stack.mail.messageCount(folderId: sentFolder.id) == 0)
    }

    @Test("移动邮件：远端 MOVE 成功后本地改归属")
    func moveMessageMovesRemotelyAndLocally() async throws {
        let account = syncAccountFixture()
        let mock = writeFixtureMock()
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let folders = try await stack.mail.folders(accountId: account.id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let archive = try #require(folders.first { $0.role == .archive })
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        try await stack.service.moveMessage(messageId: message.id, toFolderId: archive.id)

        let calls = await mock.moveCalls
        #expect(calls.count == 1)
        #expect(calls.first?.path == "INBOX")
        #expect(calls.first?.uid == message.uid)
        #expect(calls.first?.toPath == "Archive")

        let moved = try #require(try await stack.mail.message(id: message.id))
        #expect(moved.folderId == archive.id)
        #expect(try await stack.mail.messageCount(folderId: inbox.id) == 0)
    }

    @Test("移动失败：本地归属不变（可重试）")
    func moveFailureKeepsLocalFolder() async throws {
        let account = syncAccountFixture()
        let mock = writeFixtureMock(mutationFailure: "no move support")
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let folders = try await stack.mail.folders(accountId: account.id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let archive = try #require(folders.first { $0.role == .archive })
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        await #expect(throws: MailProtocolError.invalidResponse("no move support")) {
            try await stack.service.moveMessage(messageId: message.id, toFolderId: archive.id)
        }

        let unchanged = try #require(try await stack.mail.message(id: message.id))
        #expect(unchanged.folderId == inbox.id)
    }

    @Test("删除邮件：远端删除成功后本地记录移除")
    func deleteMessageRemovesRemotelyAndLocally() async throws {
        let account = syncAccountFixture()
        let mock = writeFixtureMock()
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        try await stack.service.deleteMessage(messageId: message.id)

        let calls = await mock.deleteCalls
        #expect(calls.count == 1)
        #expect(calls.first?.path == "INBOX")
        #expect(calls.first?.uid == message.uid)
        #expect(try await stack.mail.message(id: message.id) == nil)
    }

    @Test("删除：同文件夹有其他待删邮件且服务器无 UIDPLUS 时中止，其他邮件不受影响")
    func deleteBlocksWhenOtherMessagesArePending() async throws {
        let account = syncAccountFixture()
        // 服务器上 UID 2 已被其他客户端标记删除；本机没有 UIDPLUS 可用
        let mock = writeFixtureMock(supportsUIDPlus: false)
        await mock.markDeletedOnServer(path: "INBOX", uids: [2])
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        await #expect(throws: MailSyncError.deletionWouldAffectOthers(count: 1)) {
            try await stack.service.deleteMessage(messageId: message.id)
        }

        // 关键：没有退化成不带 UID 的 EXPUNGE，否则 UID 2 会被连带永久删除
        #expect(await mock.expungeAllCalls.isEmpty)
        #expect(await mock.searchDeleted(path: "INBOX") == [2])
        // 本地记录保留，用户可改用「移动到垃圾箱」或先清理其他待删邮件
        #expect(try await stack.mail.message(id: message.id) != nil)
    }

    @Test("删除：只有目标邮件待删时执行 EXPUNGE 并移除本地记录")
    func deleteExpungesWhenOnlyTargetIsPending() async throws {
        let account = syncAccountFixture()
        let mock = writeFixtureMock()
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        try await stack.service.deleteMessage(messageId: message.id)

        #expect(await mock.expungeAllCalls == ["INBOX"])
        #expect(await mock.searchDeleted(path: "INBOX").isEmpty)
        #expect(try await stack.mail.message(id: message.id) == nil)
    }

    @Test("删除：清除命令成功但目标仍在服务器上时报「删除未完成」，本地记录保留")
    func deleteReconcilesActualResult() async throws {
        let account = syncAccountFixture()
        // EXPUNGE 不生效：命令成功，但目标邮件还在（服务器异常 / 权限不足）
        let mock = writeFixtureMock(expungeNoop: true)
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        await #expect(throws: MailSyncError.self) {
            try await stack.service.deleteMessage(messageId: message.id)
        }
        // 本地不能显示「已删除」，否则用户以为删掉了、服务器上还留着
        #expect(try await stack.mail.message(id: message.id) != nil)
    }

    @Test("删除：标记搜索不可解读时报错，绝不按「没有其他待删邮件」执行 EXPUNGE")
    func deleteRefusesWhenSearchIsUnreadable() async throws {
        let account = syncAccountFixture()
        let mock = writeFixtureMock()
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)
        await mock.setSearchUnreadable(true)
        await #expect(throws: MailProtocolError.self) {
            try await stack.service.deleteMessage(messageId: message.id)
        }
        // 关键：一次 EXPUNGE 都没发出（无法确认安全就不能清除）
        #expect(await mock.expungeAllCalls.isEmpty)
        #expect(try await stack.mail.message(id: message.id) != nil)
    }

    @Test("删除：UIDPLUS 可用时走 UID EXPUNGE，只清目标 UID")
    func deleteUsesUIDExpungeWhenAvailable() async throws {
        let account = syncAccountFixture()
        let mock = writeFixtureMock(supportsUIDPlus: true)
        await mock.markDeletedOnServer(path: "INBOX", uids: [2])
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        try await stack.service.deleteMessage(messageId: message.id)

        let calls = await mock.expungeUIDCalls
        #expect(calls.count == 1)
        #expect(calls.first?.uids == [message.uid])
        #expect(await mock.expungeAllCalls.isEmpty)
        // 其他客户端的待删邮件仍在（UID EXPUNGE 只影响指定 UID）
        #expect(await mock.searchDeleted(path: "INBOX") == [2])
    }

    @Test("移动：服务器分配新 UID 时本地 UID 必须跟着换（不能用源 UID）")
    func moveWritesServerAssignedUID() async throws {
        let account = syncAccountFixture()
        let mock = moveFixtureMock(destinationUID: 77)
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let folders = try await stack.mail.folders(accountId: account.id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let archive = try #require(folders.first { $0.role == .archive })
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)
        let sourceUID = message.uid

        try await stack.service.moveMessage(messageId: message.id, toFolderId: archive.id)

        let moved = try #require(try await stack.mail.message(id: message.id))
        #expect(moved.folderId == archive.id)
        #expect(moved.uid == 77)
        #expect(moved.uid != sourceUID)
    }

    @Test("移动：服务器不回 COPYUID 时按 Message-ID 重抓目标 UID")
    func moveResolvesDestinationByMessageID() async throws {
        let account = syncAccountFixture()
        let mock = moveFixtureMock(destinationUID: nil)
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let folders = try await stack.mail.folders(accountId: account.id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let archive = try #require(folders.first { $0.role == .archive })
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        try await stack.service.moveMessage(messageId: message.id, toFolderId: archive.id)

        let moved = try #require(try await stack.mail.message(id: message.id))
        #expect(moved.folderId == archive.id)
        // 本地 UID 必须等于服务器在目标文件夹实际分配的 UID
        let targetSummaries = await mock.summaries(path: "Archive")
        let serverUID = try #require(targetSummaries.first?.uid)
        #expect(moved.uid == serverUID)
    }

    @Test("同步：按批拉取并在批间可取消，已写入的批保留")
    func syncFetchesInBatches() async throws {
        let account = syncAccountFixture()
        let summaries = (1...5).map { remoteSummary(uid: UInt32($0)) }
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": RemoteFolderStatus(uidValidity: 1, uidNext: 6, messageCount: 5, unreadCount: 0)],
            summaries: ["INBOX": summaries]
        )
        let stack = try makeSyncStack(mock: mock, batchSize: 2)
        try await stack.accounts.save(account, password: nil)

        _ = try await stack.service.syncAccount(accountId: account.id)

        // 5 封 / 每批 2 封 → 至少 3 次请求，单次请求不再覆盖整个文件夹
        let limits = await mock.fetchLimits
        #expect(limits.allSatisfy { $0 == 2 })
        #expect(limits.count >= 3)
        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        #expect(try await stack.mail.messageCount(folderId: inbox.id) == 5)
    }

    @Test("同步：UID 存在空洞时不会因「本批不足一批」而提前结束")
    func syncDoesNotStopEarlyWhenUIDsHaveGaps() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": RemoteFolderStatus(uidValidity: 1, uidNext: 6, messageCount: 2, unreadCount: 0)],
            // UID 1 与 5 之间存在空洞（2..4 不存在）：区间扫描必须能跨过空洞取到 5
            summaries: ["INBOX": [remoteSummary(uid: 1), remoteSummary(uid: 5)]]
        )
        let stack = try makeSyncStack(mock: mock, batchSize: 2)
        try await stack.accounts.save(account, password: nil)

        _ = try await stack.service.syncAccount(accountId: account.id)

        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        // 旧实现把「返回数量 < batchSize」当成同步结束，会在第一批后停在 UID 1，漏掉 UID 5
        let uids = try await stack.mail.messages(folderId: inbox.id).map(\.uid).sorted()
        #expect(uids == [1, 5])
    }

    @Test("同步：服务器不提供 UIDNEXT 时用 UID 搜索取真实上界，稀疏 UID 不漏")
    func syncUsesUIDSearchWhenUIDNextMissing() async throws {
        let account = syncAccountFixture()
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            // UIDNEXT 缺失：不能靠「本批不足一批」推断尾部
            statuses: ["INBOX": RemoteFolderStatus(uidValidity: 1, uidNext: nil, messageCount: 2, unreadCount: 0)],
            summaries: ["INBOX": [remoteSummary(uid: 1), remoteSummary(uid: 900)]]
        )
        let stack = try makeSyncStack(mock: mock)
        try await stack.accounts.save(account, password: nil)

        _ = try await stack.service.syncAccount(accountId: account.id)

        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        // 旧实现在无 UIDNEXT 时以「本窗未填满」结束，第一批只回 UID 1 就停止，漏掉 UID 900
        let uids = try await stack.mail.messages(folderId: inbox.id).map(\.uid).sorted()
        #expect(uids == [1, 900])
    }

    @Test("正文：拉取时把字节上限传给协议层（不再整封下载）")
    func loadBodyPassesByteLimit() async throws {
        let account = syncAccountFixture()
        let mock = writeFixtureMock()
        let stack = try makeSyncStack(mock: mock, bodyByteLimit: 4096)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let inbox = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)
        _ = try await stack.service.loadBody(messageId: message.id)

        #expect(await mock.bodyLimits == [4096])
    }

    @Test("发信：已投递但本地副本落库失败时，草稿保留并带投递凭证")
    func sendKeepsDraftWhenLocalCopyFails() async throws {
        let account = syncAccountFixture()
        let sender = MockSendClient()
        let stack = try makeSyncStack(mock: writeFixtureMock(), sender: sender)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let draft = MailDraft(
            accountId: account.id,
            to: [MailAddress(name: "", address: "rcpt@example.com")],
            subject: "已投递",
            bodyText: "正文"
        )
        try await stack.mail.saveDraft(draft)
        // 让本地副本落库失败（模拟写盘/落库故障），但 SMTP 投递照常成功
        await stack.mail.setBodyWriteFailureForTesting(MailServiceTestError.writeFailed)

        await #expect(throws: MailDeliveredLocalSaveError.self) {
            _ = try await stack.service.send(draft: draft)
        }

        // 投递确实发生了
        #expect(await sender.sent.count == 1)
        // 草稿被保留，且带上投递凭证：界面据此提示「已发出，不要重发」
        let remaining = try await stack.mail.drafts(accountId: account.id)
        #expect(remaining.count == 1)
        #expect(remaining.first?.deliveredAt != nil)
        #expect(remaining.first?.deliveredMessageId?.isEmpty == false)
        #expect(try await stack.mail.deliveredDrafts(accountId: account.id).count == 1)
    }

    @Test("发信：已投递草稿再次发送被拒绝，且不发起 SMTP 投递")
    func sendRefusesAlreadyDeliveredDraft() async throws {
        let account = syncAccountFixture()
        let sender = MockSendClient()
        let stack = try makeSyncStack(mock: writeFixtureMock(), sender: sender)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        // 带投递凭证的草稿：证明这封邮件已经出去过
        let draft = MailDraft(
            accountId: account.id,
            to: [MailAddress(name: "", address: "rcpt@example.com")],
            subject: "已投递",
            bodyText: "正文",
            deliveredAt: Date(),
            deliveredMessageId: "<proof@example.com>"
        )
        try await stack.mail.saveDraft(draft)

        await #expect(throws: MailSyncError.draftAlreadyDelivered) {
            _ = try await stack.service.send(draft: draft)
        }
        // 关键：一次 SMTP 投递都不能发出（重复投递不可撤销）
        #expect(await sender.sent.isEmpty)
    }

    @Test("发信：未预先落库的草稿在投递后也会留下凭证")
    func sendRegistersProofForUnsavedDraft() async throws {
        let account = syncAccountFixture()
        let sender = MockSendClient()
        let stack = try makeSyncStack(mock: writeFixtureMock(), sender: sender)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        // 新邮件直接撰写发送：调用方从未 saveDraft
        let draft = MailDraft(
            accountId: account.id,
            to: [MailAddress(name: "", address: "rcpt@example.com")],
            subject: "直接发送",
            bodyText: "正文"
        )
        // 本地「已发送」副本落库失败 → 草稿（含凭证）被保留，可据此断言凭证已登记
        await stack.mail.setBodyWriteFailureForTesting(MailServiceTestError.writeFailed)

        await #expect(throws: MailDeliveredLocalSaveError.self) {
            _ = try await stack.service.send(draft: draft)
        }

        #expect(await sender.sent.count == 1)
        let remaining = try await stack.mail.drafts(accountId: account.id)
        #expect(remaining.count == 1)
        // 发送前先落草稿，凭证才有落点；否则这里会是 0 条、凭证被丢掉
        #expect(remaining.first?.deliveredAt != nil)
        #expect(remaining.first?.deliveredMessageId?.isEmpty == false)
    }

    @Test("发信：SMTP 报文与本地副本使用同一个 Message-ID")
    func sendUsesStableMessageIdOnWireAndCopy() async throws {
        let account = syncAccountFixture()
        let sender = MockSendClient()
        let stack = try makeSyncStack(mock: writeFixtureMock(), sender: sender)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let draft = MailDraft(
            accountId: account.id,
            to: [MailAddress(name: "", address: "rcpt@example.com")],
            subject: "身份",
            bodyText: "正文"
        )
        let sent = try #require(try await stack.service.send(draft: draft))
        let wire = try #require(await sender.sent.first)

        #expect(wire.messageId?.isEmpty == false)
        // 收件方收到的 Message-ID 必须与本地「已发送」副本一致，否则无法到服务器核对
        #expect(sent.messageId == wire.messageId)
    }

    @Test("删除账号：连本地已发送副本一并清除")
    func deleteAccountPurgesLocalSentCopies() async throws {
        let account = syncAccountFixture()
        let stack = try makeSyncStack(mock: writeFixtureMock(), sender: MockSendClient())
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        // 发一封邮件，产生 UID ≥ localUIDFloor 的本地自产副本
        let draft = MailDraft(
            accountId: account.id,
            to: [MailAddress(name: "", address: "rcpt@example.com")],
            subject: "本地副本",
            bodyText: "x"
        )
        let sent = try #require(try await stack.service.send(draft: draft))
        #expect(sent.uid >= MailService.localUIDFloor)
        try await stack.mail.saveDraft(MailDraft(accountId: account.id, subject: "草稿"))

        try await stack.accounts.delete(id: account.id)

        #expect(try await stack.accounts.getAll().isEmpty)
        #expect(try await stack.mail.folders(accountId: account.id).isEmpty)
        #expect(try await stack.mail.drafts(accountId: account.id).isEmpty)
        // 关键：本地自产副本（旧实现被 clearMessages 的 uid 下限保留）也必须清掉
        #expect(try await stack.mail.message(id: sent.id) == nil)
        #expect(try await stack.mail.body(messageId: sent.id) == nil)
    }

    @Test("本地已发送副本：移动不发起网络请求")
    func localCopyMutationsSkipNetwork() async throws {
        let account = syncAccountFixture()
        let mock = writeFixtureMock()
        let stack = try makeSyncStack(mock: mock, sender: MockSendClient())
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let draft = MailDraft(
            accountId: account.id,
            to: [MailAddress(name: "", address: "rcpt@example.com")],
            subject: "本地副本",
            bodyText: "x"
        )
        let sent = try #require(try await stack.service.send(draft: draft))
        let archive = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .archive }
        )

        try await stack.service.moveMessage(messageId: sent.id, toFolderId: archive.id)

        #expect(await mock.moveCalls.isEmpty)
        #expect(try await stack.mail.message(id: sent.id)?.folderId == archive.id)
    }
}

// MARK: - Agent Tools

@Suite("Mail agent tools")
struct MailAgentToolTests {

    /// 组装工具面 + 服务栈（工具与功能页共用同一批服务）。
    private func makeToolStack(
        mock: MockMailClient,
        sender: MockSendClient = MockSendClient()
    ) async throws -> (
        tools: [any DispatcherTool],
        mail: MailService,
        sender: MockSendClient,
        account: MailAccount
    ) {
        let account = syncAccountFixture()
        let stack = try makeSyncStack(mock: mock, sender: sender)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        let tools = MailToolFactory.build(
            accountService: stack.accounts,
            mailService: stack.mail,
            syncService: stack.service
        )
        return (tools, stack.mail, sender, account)
    }

    @Test("工具面完整：9 个工具且确认分级与副作用分类符合计划表")
    func toolFaceMatchesPlan() async throws {
        let stack = try await makeToolStack(mock: writeFixtureMock())
        let names = Set(stack.tools.map(\.definition.name))
        #expect(stack.tools.count == 9)
        #expect(names == [
            "mail_accounts_list", "mail_folders_list", "mail_list", "mail_read", "mail_search",
            "mail_mark", "mail_save_draft", "mail_send", "mail_delete"
        ])

        // 读类：免确认、只读
        for name in ["mail_accounts_list", "mail_folders_list", "mail_list", "mail_read", "mail_search"] {
            let tool = try #require(stack.tools.first { $0.definition.name == name })
            #expect(tool.requiresConfirmation == false)
            #expect(tool.sideEffectClass == ToolSideEffectClass.readOnly)
        }

        // 标记已读/星标：免确认、幂等写
        let mark = try #require(stack.tools.first { $0.definition.name == "mail_mark" })
        #expect(mark.requiresConfirmation == false)
        #expect(mark.sideEffectClass == ToolSideEffectClass.idempotentWrite)
        #expect(mark.requiresHardConfirmation(argumentsJSON: #"{"messageId":"x"}"#) == false)

        // 存草稿：需确认、幂等写
        let saveDraft = try #require(stack.tools.first { $0.definition.name == "mail_save_draft" })
        #expect(saveDraft.requiresConfirmation == true)
        #expect(saveDraft.sideEffectClass == ToolSideEffectClass.idempotentWrite)

        // 发信：需确认、非幂等写
        let send = try #require(stack.tools.first { $0.definition.name == "mail_send" })
        #expect(send.requiresConfirmation == true)
        #expect(send.sideEffectClass == ToolSideEffectClass.nonIdempotentWrite)

        // 删除：需确认 + 逐次硬确认、非幂等写
        let delete = try #require(stack.tools.first { $0.definition.name == "mail_delete" })
        #expect(delete.requiresConfirmation == true)
        #expect(delete.sideEffectClass == ToolSideEffectClass.nonIdempotentWrite)
        #expect(delete.requiresHardConfirmation(argumentsJSON: #"{"messageId":"x"}"#) == true)
    }

    @Test("mail_accounts_list：空空间给出可操作的提示而非抛错")
    func accountsListOnEmptySpace() async throws {
        let queue = try makeSyncDatabase()
        let tools = MailToolFactory.build(
            accountService: MailAccountService(databaseQueue: queue, space: .personal),
            mailService: MailService(databaseQueue: queue),
            syncService: MailSyncService(
                accountService: MailAccountService(databaseQueue: queue, space: .personal),
                mail: MailService(databaseQueue: queue),
                space: .personal
            )
        )
        let list = try #require(tools.first { $0.definition.name == "mail_accounts_list" })
        let output = try await list.execute(argumentsJSON: "{}")
        #expect(output.contains("No email account"))
    }

    @Test("mail_list / mail_read：列出并可读回已同步邮件（正文按需拉取）")
    func listAndReadMessages() async throws {
        let stack = try await makeToolStack(mock: writeFixtureMock())
        let list = try #require(stack.tools.first { $0.definition.name == "mail_list" })
        let read = try #require(stack.tools.first { $0.definition.name == "mail_read" })

        let listOutput = try await list.execute(argumentsJSON: #"{"limit":10}"#)
        #expect(listOutput.contains("Messages in INBOX"))
        #expect(listOutput.contains("主题 1"))
        #expect(listOutput.contains("[unread]"))

        let inbox = try #require(
            try await stack.mail.folders(accountId: stack.account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        let readOutput = try await read.execute(
            argumentsJSON: #"{"messageId":"\#(message.id.uuidString)"}"#
        )
        #expect(readOutput.contains("Subject: 主题 1"))
        #expect(readOutput.contains("Status: unread"))
    }

    @Test("mail_search：按关键词命中本地邮件，未命中给出空结果说明")
    func searchMessages() async throws {
        let stack = try await makeToolStack(mock: writeFixtureMock())
        let search = try #require(stack.tools.first { $0.definition.name == "mail_search" })

        let hit = try await search.execute(argumentsJSON: #"{"query":"主题"}"#)
        #expect(hit.contains("Matches for '主题'"))
        #expect(hit.contains("主题 1"))

        let miss = try await search.execute(argumentsJSON: #"{"query":"不存在的关键词"}"#)
        #expect(miss.contains("No synced message matches"))
    }

    @Test("mail_mark：免确认执行，本地生效并回写 IMAP 标记")
    func markToolWritesFlags() async throws {
        let mock = writeFixtureMock()
        let stack = try await makeToolStack(mock: mock)
        let mark = try #require(stack.tools.first { $0.definition.name == "mail_mark" })
        let inbox = try #require(
            try await stack.mail.folders(accountId: stack.account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        let output = try await mark.execute(
            argumentsJSON: #"{"messageId":"\#(message.id.uuidString)","read":true,"starred":true}"#
        )
        #expect(output.contains("read=true"))
        #expect(output.contains("starred=true"))

        let updated = try #require(try await stack.mail.message(id: message.id))
        #expect(updated.isRead)
        #expect(updated.isStarred)

        let calls = await mock.flagCalls
        #expect(calls.count == 2)
        #expect(calls.contains { $0.add == [.seen] })
        #expect(calls.contains { $0.add == [.flagged] })
    }

    @Test("mail_save_draft：落本地草稿但绝不投递")
    func saveDraftToolNeverSends() async throws {
        let stack = try await makeToolStack(mock: writeFixtureMock())
        let saveDraft = try #require(stack.tools.first { $0.definition.name == "mail_save_draft" })

        let output = try await saveDraft.execute(
            argumentsJSON: #"{"to":"收件 <rcpt@example.com>","subject":"草稿","body":"内容"}"#
        )
        #expect(output.contains("Draft saved"))
        #expect(await stack.sender.sent.isEmpty)

        let drafts = try await stack.mail.drafts(accountId: stack.account.id)
        #expect(drafts.count == 1)
        #expect(drafts.first?.to.first?.address == "rcpt@example.com")
        #expect(drafts.first?.subject == "草稿")
    }

    @Test("A reordered quotation list grounds a reply draft; late retries preserve edits and never send")
    func groundedReplyWorkflow() async throws {
        let stack = try await makeToolStack(mock: writeFixtureMock())
        let inbox = try #require(try await stack.mail.folders(accountId: stack.account.id).first { $0.role == .inbox })
        let older = MailMessage(accountId: stack.account.id, folderId: inbox.id, uid: 7, messageId: "<old@example.com>",
            subject: "客户报价", fromAddress: "a@example.com", date: Date(timeIntervalSince1970: 1_000))
        let newer = MailMessage(accountId: stack.account.id, folderId: inbox.id, uid: 8, messageId: "<new@example.com>",
            subject: "客户报价", fromAddress: "b@example.com", replyTo: [.init(name: "", address: "reply-b@example.com")],
            date: Date(timeIntervalSince1970: 2_000))
        try await stack.mail.upsertMessages([older, newer])
        for message in [older, newer] {
            let body = message.id == newer.id ? String(repeating: "报价正文", count: 2_000) : "报价正文"
            try await stack.mail.saveBody(.init(messageId: message.id, textBody: body))
            try await stack.mail.setBodyState(messageId: message.id, state: .ready)
        }
        let links = [older, newer].map { MailSourceReference(message: $0, space: .personal).url }
        let resource = RunResourceContext(space: .personal, workspaceID: UUID())
        let sid = UUID(), run = UUID()
        let wire = HarnessProtocolTests(), firstHost = UUID().uuidString + ".invalid", secondHost = UUID().uuidString + ".invalid"
        defer { HarnessProtocolStub.remove(host: firstHost); HarnessProtocolStub.remove(host: secondHost) }
        func scope(_ run: UUID, _ request: String, _ target: MailTurnTarget? = nil) -> TaskExecutionScope {
            .init(space: .personal, sessionID: sid, runID: run, parentRunID: nil, workspaceID: resource.workspaceID,
                workspacePath: "", workspaceIdentity: nil, writeRootIdentities: [:], permissionMode: .workspaceWrite,
                approvalPolicyVersion: "fixture", autoReviewEnabled: false, readRoots: [], writeRoots: [],
                artifactRoots: [], capabilities: [.read, .write], constraints: TaskConstraintExtractor.detect(in: request),
                userRequest: request, mailTarget: target)
        }
        func engine(_ host: String, _ replies: [String], _ scope: TaskExecutionScope) -> DispatcherEngine {
            let engine = DispatcherEngine(provider: wire.provider(host: host, replies: replies), tools: stack.tools + [AskUserTool()],
                systemPrompt: scope.systemPromptSection(), maxSteps: 12,
                executionContext: .init(space: .personal, sessionID: sid, runID: scope.runID, permissionPolicy: nil, taskScope: scope))
            engine.setResourceContext(resource)
            return engine
        }
        let display = "1. [客户 A 报价](\(links[0]))\n2. [客户 B 报价](\(links[1]))"
        let initial = "查邮箱里的客户报价"
        let listing = engine(firstHost, [try wire.toolCall("list", "mail_search", #"{"query":"报价"}"#), try wire.answer(display)], scope(run, initial))
        guard case .finished(_, _, let trace, _, _, _, _) = try await listing.run(userMessage: initial, history: []) else {
            Issue.record("Expected mail list"); return
        }
        #expect(trace.first?.evidence?.sourceReceipt?.references == Array(links.reversed()))
        let answer = ChatMessage(role: .assistant, content: display, trace: trace, runStatus: .succeeded,
                                 contextReport: listing.requestReport, taskRun: .init(id: run))
        let history = CodingHistory.messages([answer], limit: 8, tokenBudget: 2_000)
        let query = "给刚才第二封报价邮件写回复，存成草稿，先别发"
        let target = DisplayedMailReferences.target(query: query, history: history, scope: resource, sessionID: sid)
        #expect(target == .message(links[1]))
        #expect(DisplayedMailReferences.target(query: "不是第二封，改成第一封", history: history, scope: resource, sessionID: sid) == .message(links[0]))
        #expect(DisplayedMailReferences.target(query: query, history: history, scope: resource, sessionID: UUID()) == .needsClarification)
        #expect(DisplayedMailReferences.target(query: query, history: history, scope: .init(space: .work, workspaceID: resource.workspaceID), sessionID: sid) == .needsClarification)
        var changed = answer
        changed.content = String(display.reversed())
        #expect(CodingHistory.messages([changed], limit: 1, tokenBudget: 2_000).first?.displayedMailReferences == nil)
        changed.clearProviderHistory()
        #expect(changed.contextReport?.mailAnswerBinding == nil)
        var ambiguous = answer
        ambiguous.content = display + "\n另一组\n1. [客户 A 报价](\(links[0]))"
        ambiguous.contextReport?.mailAnswerBinding = .init(sessionID: sid, runID: run, displayDigest: ResponsesContextWindow.digest(ambiguous.content))
        #expect(DisplayedMailReferences.target(query: query, history: CodingHistory.messages([ambiguous], limit: 1, tokenBudget: 2_000),
            scope: resource, sessionID: sid) == .needsClarification)

        let follow = scope(UUID(), query, target)
        #expect(!follow.allowsTool(named: "mail_send") && follow.allowsTool(named: "mail_save_draft"))
        let args = #"{"to":"reply-b@example.com","subject":"Re: 客户报价","body":"已收到","sourceMessageId":"\#(newer.id)"}"#
        let second = engine(secondHost, [
            try wire.toolCall("bad-read", "mail_read", #"{"messageId":"\#(older.id)"}"#),
            try wire.toolCall("read", "mail_read", #"{"messageId":"\#(newer.id)"}"#),
            try wire.toolCall("send", "mail_send", args), try wire.toolCall("save", "mail_save_draft", args),
            try wire.answer("草稿已保存。")
        ], follow)
        guard case .needsConfirmation(let name, _, _, _) = try await second.run(userMessage: query, history: history) else {
            Issue.record("Expected draft approval. Trace: \(second.takeSnapshot().trace.map { ($0.toolName, $0.resultPreview) })"); return
        }
        #expect(name == "mail_save_draft")
        #expect(try await stack.mail.drafts(accountId: stack.account.id).isEmpty)
        guard case .finished(_, _, let actions, _, _, _, let completion) = try await second.resume(approved: true) else {
            Issue.record("Expected completed draft"); return
        }
        #expect(!completion.isIncomplete)
        #expect(actions.filter { $0.toolName == "mail_read" }.map(\.succeeded) == [false, true])
        #expect(actions.contains { $0.toolName == "mail_read" && $0.evidence?.sourceReceipt?.hasMailBody == true && $0.evidence?.sourceReceipt?.status == .partial })
        #expect(!actions.contains { $0.toolName == "mail_send" && $0.succeeded })
        let saved = try await stack.mail.drafts(accountId: stack.account.id)
        #expect(saved.count == 1)
        var draft = try #require(saved.first)
        #expect(draft.sourceMessageId == newer.id && draft.inReplyTo == newer.messageId && draft.composeKind == .reply)
        #expect(draft.to.map(\.address) == ["reply-b@example.com"])
        draft.bodyText = "用户手动修改"
        try await stack.mail.saveDraft(draft)
        let save = try #require(stack.tools.first { $0.definition.name == "mail_save_draft" })
        let capture = ToolArtifactCapture(store: nil, origin: .init(space: .personal, sessionID: sid, runID: follow.runID,
            workspaceID: resource.workspaceID.uuidString, operationID: "different-call-id", tool: "mail_save_draft"), mailTarget: target)
        try await ToolArtifactCapture.$current.withValue(capture) {
            let rewritten = args.replacingOccurrences(of: "已收到", with: "已经收到")
            _ = try await save.execute(argumentsJSON: rewritten)
            let retained = try await stack.mail.drafts(accountId: stack.account.id)
            #expect(retained.count == 1 && retained.first?.bodyText == "用户手动修改")
            try await stack.mail.deleteDraft(id: draft.id)
            let result = try await save.execute(argumentsJSON: rewritten)
            #expect(result.contains("not recreated"))
            #expect(try await stack.mail.drafts(accountId: stack.account.id).isEmpty)
        }
        #expect(await stack.sender.sent.isEmpty)
        let clarificationHost = UUID().uuidString + ".invalid"
        defer { HarnessProtocolStub.remove(host: clarificationHost) }
        let clarify = engine(clarificationHost, [try wire.toolCall("which", "ask_user",
            #"{"title":"选择邮件","prompt":"请粘贴邮件链接","fields":[{"id":"link","label":"邮件链接","type":"long_text"}]}"#),
            try wire.toolCall("selected", "mail_read", #"{"messageId":"\#(newer.id)"}"#), try wire.answer("已读取。")],
            scope(UUID(), "读取第二封邮件", .needsClarification))
        guard case .waitingForInput(let form) = try await clarify.run(userMessage: "读取第二封邮件", history: []) else {
            Issue.record("Expected clarification"); return
        }
        let response = QuestionFormAnswer(values: ["link": .text(links[1].absoluteString)]).encodedJSON()
        #expect(MailTurnTarget.clarificationAnswer(response, form: form, space: .work) == nil)
        guard case .finished(_, _, let clarified, _, _, _, let assessment) = try await clarify.resume(.answered(response)) else {
            Issue.record("Expected a verified read after the user answered"); return
        }
        #expect(!assessment.isIncomplete)
        #expect(clarified.last?.evidence?.sourceReceipt?.references == [links[1]])
    }

    @Test("mail_send：SMTP 真实投递并落本地已发送副本")
    func sendToolDelivers() async throws {
        let sender = MockSendClient()
        let stack = try await makeToolStack(mock: writeFixtureMock(), sender: sender)
        let send = try #require(stack.tools.first { $0.definition.name == "mail_send" })

        let output = try await send.execute(
            argumentsJSON: #"{"to":"收件 <rcpt@example.com>","cc":"cc@example.com","subject":"问候","body":"正文"}"#
        )

        let delivered = try #require(await sender.sent.first)
        #expect(delivered.from.address == "user@example.com")
        #expect(delivered.recipients.map(\.address) == ["rcpt@example.com", "cc@example.com"])
        #expect(delivered.subject == "问候")
        #expect(output.contains("rcpt@example.com"))

        let sentFolder = try #require(
            try await stack.mail.folders(accountId: stack.account.id).first { $0.role == .sent }
        )
        #expect(try await stack.mail.messageCount(folderId: sentFolder.id) == 1)
    }

    @Test("Uncertain delivery or a lost Sent copy stops a changed second submission",
          arguments: ["unknown", "delivered"])
    func uncertainSendDoesNotReroute(mode: String) async throws {
        let account = syncAccountFixture(), sender = MockSendClient(hangsOnSend: mode == "unknown")
        let stack = try makeSyncStack(mock: writeFixtureMock(), sender: sender, timeoutBudget: fastTimeoutBudget)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)
        if mode == "delivered" {
            stack.mail.setBodyWriteFailureForTesting(ToolExecutionFailure(message: "Synthetic local storage failure"))
        }
        let wire = HarnessProtocolTests(), host = UUID().uuidString + ".invalid"
        defer { HarnessProtocolStub.remove(host: host) }
        let args = #"{"to":"rcpt@example.com","subject":"报价","body":"已收到"}"#
        let replies = [try wire.toolCall("original", "mail_send", args),
                       try wire.toolCall("resend", "mail_send", args.replacingOccurrences(of: "已收到", with: "收到报价")),
                       try wire.answer("Done")]
        let tools = MailToolFactory.build(accountService: stack.accounts, mailService: stack.mail, syncService: stack.service)
        let engine = DispatcherEngine(provider: wire.provider(host: host, replies: replies), tools: tools, systemPrompt: "fixture", maxSteps: 5)
        guard case .needsConfirmation = try await engine.run(userMessage: "发送报价邮件", history: []) else {
            Issue.record("Expected SMTP approval"); return
        }
        guard case .finished(let text, _, let trace, _, _, _, let completion) = try await engine.resume(approved: true) else {
            Issue.record("A second delivery must not reach approval"); return
        }
        #expect(text.isEmpty)
        #expect(completion.code == (mode == "unknown" ? .mailDeliveryUncertain : .mailDeliveredCheckCopy))
        #expect(trace.contains { $0.evidence?.sourceReceipt?.status == (mode == "unknown" ? .unknown : .partial) })
        #expect(await sender.connectCount == 1)
        #expect(await sender.sent.count == (mode == "unknown" ? 0 : 1))
        #expect(engine.requestReport.toolDiscoveryRecoveryCount == nil)
    }

    @Test("mail_delete：远端删除成功且本地记录移除；本地不存在时报可读错误")
    func deleteToolRemovesMessage() async throws {
        let mock = writeFixtureMock()
        let stack = try await makeToolStack(mock: mock)
        let delete = try #require(stack.tools.first { $0.definition.name == "mail_delete" })
        let inbox = try #require(
            try await stack.mail.folders(accountId: stack.account.id).first { $0.role == .inbox }
        )
        let message = try #require(try await stack.mail.messages(folderId: inbox.id).first)

        let output = try await delete.execute(
            argumentsJSON: #"{"messageId":"\#(message.id.uuidString)"}"#
        )
        #expect(output.contains("Deleted"))
        #expect(await mock.deleteCalls.count == 1)
        #expect(try await stack.mail.message(id: message.id) == nil)

        await #expect(throws: LLMError.self) {
            try await delete.execute(argumentsJSON: #"{"messageId":"\#(message.id.uuidString)"}"#)
        }
    }
}

// MARK: - Timeouts

/// 超时预算压到 150 ms：验证超时路径而不真正等待秒级。
private let fastTimeoutBudget = MailTimeoutBudget(
    connect: 150,
    authenticate: 150,
    listFolders: 150,
    folderStatus: 150,
    fetchSummaries: 150,
    fetchBody: 150,
    write: 150,
    send: 150
)

/// 单个文件夹的服务器夹具（超时用例只需一个可选文件夹）。
private func singleInboxMock(
    summaries: [RemoteMessageSummary] = [],
    hangPoint: MockMailClient.HangPoint? = nil
) -> MockMailClient {
    MockMailClient(
        folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
        statuses: ["INBOX": inboxStatus],
        summaries: ["INBOX": summaries],
        hangPoint: hangPoint
    )
}

@Suite("Mail timeouts")
struct MailTimeoutTests {

    @Test("同步：服务器不响应文件夹状态时按预算抛超时，并主动断开连接")
    func syncTimesOutOnFolderStatus() async throws {
        let account = syncAccountFixture()
        let mock = singleInboxMock(summaries: [remoteSummary(uid: 1)], hangPoint: .folderStatus)
        let stack = try makeSyncStack(mock: mock, timeoutBudget: fastTimeoutBudget)
        try await stack.accounts.save(account, password: nil)

        await #expect(throws: MailProtocolError.timedOut("folderStatus")) {
            try await stack.service.syncAccount(accountId: account.id)
        }

        // 超时必须主动断链——这是让阻塞中的读立即收尾的唯一手段
        #expect(await mock.disconnectCount >= 1)
        // 文件夹发现已落库，但邮件没有写进来（超时点之后的步骤全部跳过）
        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        #expect(try await stack.mail.messageCount(folderId: folder.id) == 0)
    }

    @Test("登录：认证无响应时按预算抛超时（握手与认证分别计时）")
    func authenticationTimesOut() async throws {
        let account = syncAccountFixture()
        let mock = singleInboxMock(hangPoint: .authenticate)
        let stack = try makeSyncStack(mock: mock, timeoutBudget: fastTimeoutBudget)
        try await stack.accounts.save(account, password: nil)

        await #expect(throws: MailProtocolError.timedOut("authenticate")) {
            try await stack.service.syncAccount(accountId: account.id)
        }
        #expect(await mock.disconnectCount >= 1)
    }

    @Test("按需正文：拉取超时置为 failed 且不写正文，可重试")
    func bodyFetchTimesOutAndStaysRetryable() async throws {
        let account = syncAccountFixture()
        let mock = singleInboxMock(summaries: [remoteSummary(uid: 1)], hangPoint: .fetchBody)
        let stack = try makeSyncStack(mock: mock, timeoutBudget: fastTimeoutBudget)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        let message = try #require(try await stack.mail.messages(folderId: folder.id).first)

        await #expect(throws: MailProtocolError.timedOut("fetchBody")) {
            try await stack.service.loadBody(messageId: message.id)
        }

        // failed 状态落库：下次进入详情会重新拉取，而不是永久卡在「不可用」
        #expect(try await stack.mail.message(id: message.id)?.bodyState == .failed)
        #expect(try await stack.mail.body(messageId: message.id) == nil)
    }

    @Test("发信：SMTP 无响应按「结果未知」上报，草稿保留且不落本地副本")
    func sendTimeoutReportsUnknownResult() async throws {
        let account = syncAccountFixture()
        let sender = MockSendClient(hangsOnSend: true)
        let stack = try makeSyncStack(
            mock: writeFixtureMock(),
            sender: sender,
            timeoutBudget: fastTimeoutBudget
        )
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let draft = MailDraft(
            accountId: account.id,
            to: [MailAddress(name: "", address: "rcpt@example.com")],
            subject: "超时",
            bodyText: "正文"
        )
        try await stack.mail.saveDraft(draft)

        var caught: (any Error)?
        do {
            _ = try await stack.service.send(draft: draft)
        } catch {
            caught = error
        }
        let error = try #require(caught as? MailProtocolError)
        guard case .sendResultUnknown = error else {
            Issue.record("投递超时必须报「结果未知」，实际为 \(error)")
            return
        }

        // 结果未知 → 草稿保留、不写本地副本：用户需先到服务器核实再决定是否重发
        #expect(try await stack.mail.drafts(accountId: account.id).count == 1)
        #expect(await sender.sent.isEmpty)
        let sentFolder = try #require(
            try await stack.mail.folders(accountId: account.id).first { $0.role == .sent }
        )
        #expect(try await stack.mail.messageCount(folderId: sentFolder.id) == 0)
    }

    @Test("Cancelling SMTP after its persistent claim keeps the draft locked against ordinary resend")
    func cancelledSendKeepsDeliveryLock() async throws {
        let account = syncAccountFixture(), sender = MockSendClient(hangsOnSend: true)
        let stack = try makeSyncStack(mock: writeFixtureMock(), sender: sender)
        try await stack.accounts.save(account, password: nil)
        let draft = MailDraft(accountId: account.id, to: [.init(name: "", address: "recipient@example.test")], subject: "Cancel fixture", bodyText: "Body")
        let task = Task { try await stack.service.send(draft: draft) }
        for _ in 0..<300 {
            if try await stack.mail.draft(id: draft.id)?.deliveryState == .sending { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await stack.mail.draft(id: draft.id)?.deliveryState == .sending)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let retained = try #require(try await stack.mail.draft(id: draft.id))
        #expect(!retained.deliveryState.allowsRetry)
        await #expect(throws: (any Error).self) { try await stack.service.send(draft: draft) }
        #expect(await sender.connectCount == 1)
        #expect(await sender.sent.isEmpty)
    }

    @Test("A disabled deadline still responds to explicit cancellation of a blocked read")
    func unlimitedReadCancellation() async throws {
        let client = MockMailClient(hangPoint: .folderStatus)
        let task = Task {
            try await MailDeadline.call(0, label: "read", client: client) { try await client.folderStatus(path: "INBOX") }
        }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        for _ in 0..<100 {
            if await client.disconnectCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.disconnectCount > 0)
    }

    @Test("标记回写超时不冒泡：本地状态已生效，界面不受网络影响")
    func flagWriteBackTimeoutDoesNotThrow() async throws {
        let account = syncAccountFixture()
        let mock = singleInboxMock(summaries: [remoteSummary(uid: 1)], hangPoint: .storeFlags)
        let stack = try makeSyncStack(mock: mock, timeoutBudget: fastTimeoutBudget)
        try await stack.accounts.save(account, password: nil)
        _ = try await stack.service.syncAccount(accountId: account.id)

        let folder = try #require(try await stack.mail.folders(accountId: account.id).first)
        let message = try #require(try await stack.mail.messages(folderId: folder.id).first)

        // 本地为权威、远端尽力回写：超时只告警，不向调用方抛错
        try await stack.service.setRead(messageId: message.id, isRead: true)

        #expect(try await stack.mail.message(id: message.id)?.isRead == true)
        #expect(await mock.flagCalls.isEmpty)
    }

    @Test("账号协调器：UI 与引擎两实例在同一账号上不会交错执行")
    func sharedCoordinatorSerializesCrossInstanceSync() async throws {
        let account = syncAccountFixture()
        // 放大重叠窗口：不互斥时两个 listFolders 会同时在内，maxActive 会到 2
        let probe = MailConcurrencyProbe(holdNanoseconds: 30_000_000)
        let mock = MockMailClient(
            folders: [RemoteMailFolder(path: "INBOX", name: "INBOX", role: .inbox)],
            statuses: ["INBOX": inboxStatus],
            summaries: ["INBOX": [remoteSummary(uid: 1)]],
            concurrencyProbe: probe
        )
        let queue = try makeSyncDatabase()
        let accounts = MailAccountService(databaseQueue: queue, space: .personal)
        let mail = MailService(databaseQueue: queue)
        try await accounts.save(account, password: nil)

        // 与生产一致：界面与引擎各自现建服务，但共享同一个账号级协调器
        let coordinator = MailAccountCoordinator()
        func makeService() -> MailSyncService {
            MailSyncService(
                accountService: accounts,
                mail: mail,
                space: .personal,
                coordinator: coordinator,
                clientFactory: { _ in mock },
                sendClientFactory: { _ in MockSendClient() },
                passwordProvider: { _ in "secret" }
            )
        }
        let ui = makeService()
        let engine = makeService()

        async let uiResult = ui.syncAccount(accountId: account.id)
        async let engineResult = engine.syncAccount(accountId: account.id)
        _ = try await (uiResult, engineResult)

        #expect(await probe.maxActive == 1)
    }

    @Test("账号协调器：同一键上的并发调用被串行化")
    func coordinatorSerializesSameKey() async throws {
        let coordinator = MailAccountCoordinator()
        let accountId = UUID()
        let recorder = MailConcurrencyProbe(holdNanoseconds: 10_000_000)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await coordinator.withLease(space: .personal, accountId: accountId) {
                        await recorder.enter()
                        await recorder.exit()
                    }
                }
            }
        }
        #expect(await recorder.maxActive == 1)
    }

    @Test("账号协调器：取消后可靠释放，后续调用不被永久阻塞")
    func coordinatorReleasesLeaseOnCancellation() async throws {
        let coordinator = MailAccountCoordinator()
        let accountId = UUID()
        let blocked = Task {
            try await coordinator.withLease(space: .personal, accountId: accountId) {
                // 长睡眠：取消会立刻抛出 CancellationError，从而触发 defer 释放租约
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        blocked.cancel()
        _ = try? await blocked.value

        // 若租约未被释放，这里会永久挂起；能返回即证明取消路径已释放
        let acquired = try await coordinator.withLease(space: .personal, accountId: accountId) { true }
        #expect(acquired)
    }
}

// MARK: - Encryption Constraints

private actor MockImplicitTLSChannel: MailImplicitTLSChannel {
    enum Mode: Sendable { case normal, rejectTLS, noGreeting, noEHLO, badGreeting }
    nonisolated let incoming: AsyncStream<[UInt8]>
    nonisolated let secureStarts: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let mode: Mode
    private var secure = false
    private(set) var certificateChecks: [Bool] = []
    private(set) var commands: [String] = []
    private(set) var stopped = false

    init(mode: Mode = .normal) {
        self.mode = mode
        let starts = AsyncStream<Void>.makeStream()
        secureStarts = starts.stream
        startContinuation = starts.continuation
        let pair = AsyncStream<[UInt8]>.makeStream()
        incoming = pair.stream
        continuation = pair.continuation
    }

    func startSecure(validateCertificate: Bool) async throws {
        certificateChecks.append(validateCertificate)
        startContinuation.yield(())
        if mode == .rejectTLS { throw MailProtocolError.connectionFailed("Untrusted certificate") }
        secure = true
        if mode == .normal || mode == .noEHLO { continuation.yield(Array("220 Test SMTP ready\r\n".utf8)) }
        if mode == .badGreeting { continuation.yield(Array("421 Service unavailable\r\n".utf8)) }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard secure, !stopped else { throw MailProtocolError.notConnected }
        let command = String(decoding: bytes, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        commands.append(command.trimmingCharacters(in: .whitespacesAndNewlines))
        if command == "EHLO", mode != .noEHLO {
            continuation.yield(Array("250-test.local\r\n250 AUTH PLAIN\r\n".utf8))
        } else if command == "AUTH" {
            continuation.yield(Array("235 Authentication successful\r\n".utf8))
        }
    }

    func stop() async { stopped = true; secure = false; continuation.finish() }
}

@Suite("Mail encryption constraints")
struct MailEncryptionConstraintTests {
    @Test("SMTP 465 validates TLS before EHLO and authentication")
    func smtpImplicitTLS() async throws {
        let channel = MockImplicitTLSChannel()
        let adapter = MailSmtpAdapter(host: "test.invalid", port: 465, security: .tls, implicitTLSChannel: channel)
        try await adapter.connect()
        try await adapter.authenticate(username: "test@example.com", password: "test-password")
        #expect(await channel.certificateChecks == [true])
        #expect(await channel.commands == ["EHLO", "AUTH"])
        await adapter.disconnect()
        #expect(await channel.stopped)
    }

    @Test("TLS rejection never falls back to plaintext or sends authentication")
    func tlsFailureDoesNotDowngrade() async throws {
        let channel = MockImplicitTLSChannel(mode: .rejectTLS)
        let adapter = MailSmtpAdapter(host: "test.invalid", port: 465, security: .tls, implicitTLSChannel: channel)
        await #expect(throws: MailProtocolError.self) { try await adapter.connect() }
        #expect(await channel.certificateChecks == [true])
        #expect(await channel.commands.isEmpty)
        #expect(await channel.stopped)
    }

    @Test("SMTP probe uses implicit TLS without authenticating or sending a message")
    func smtpProbeTLS() async throws {
        let channel = MockImplicitTLSChannel()
        try await MailFoundationAdapter.probeSMTP(host: "test.invalid", port: 465, security: .tls,
                                                   timeoutMilliseconds: 5_000, implicitTLSChannel: channel)
        #expect(await channel.certificateChecks == [true])
        #expect(await channel.commands == ["EHLO"])
        #expect(await channel.stopped)
    }

    @Test("Silent SMTP greetings and EHLO are actively interrupted on deadline", arguments: [false, true])
    func smtpInFlightTimeout(ehlo: Bool) async throws {
        let channel = MockImplicitTLSChannel(mode: ehlo ? .noEHLO : .noGreeting)
        let adapter = MailSmtpAdapter(host: "test.invalid", port: 465, security: .tls, implicitTLSChannel: channel)
        let started = ContinuousClock.now
        await #expect(throws: MailProtocolError.timedOut("connect")) {
            try await MailDeadline.call(100, label: "connect", client: adapter) { try await adapter.connect() }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await channel.stopped)
    }

    @Test("Cancelling an in-flight connection immediately closes its TLS channel")
    func cancelInFlightConnection() async throws {
        let channel = MockImplicitTLSChannel(mode: .noGreeting)
        let adapter = MailSmtpAdapter(host: "test.invalid", port: 465, security: .tls, implicitTLSChannel: channel)
        let task = Task { try await adapter.connect() }
        for await _ in channel.secureStarts { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await channel.stopped)
    }

    @Test("Probe deadlines close a channel still awaiting the server greeting")
    func probeInFlightTimeout() async throws {
        let channel = MockImplicitTLSChannel(mode: .noGreeting)
        await #expect(throws: MailProtocolError.timedOut("smtpProbe")) {
            try await MailFoundationAdapter.probeSMTP(host: "test.invalid", port: 465, security: .tls,
                                                       timeoutMilliseconds: 100, implicitTLSChannel: channel)
        }
        #expect(await channel.stopped)
    }

    @Test("Non-220 greetings never become a successful probe")
    func badGreeting() async throws {
        let channel = MockImplicitTLSChannel(mode: .badGreeting)
        await #expect(throws: MailProtocolError.self) {
            try await MailFoundationAdapter.probeSMTP(host: "test.invalid", port: 465, security: .tls,
                                                       timeoutMilliseconds: 500, implicitTLSChannel: channel)
        }
        #expect(await channel.commands.isEmpty)
    }

    @Test("Port and security mismatches fail before network access")
    func invalidConfigurations() async throws {
        for security in [MailSecurity.startTLS, .none] {
            let adapter = MailSmtpAdapter(host: "test.invalid", port: 465, security: security)
            await #expect(throws: MailConfigurationError.implicitTLSRequired(.smtp, 465)) { try await adapter.connect() }
            await #expect(throws: MailConfigurationError.implicitTLSRequired(.smtp, 465)) {
                try await MailFoundationAdapter.probeSMTP(host: "test.invalid", port: 465, security: security)
            }
        }
        for port in [0, -1, 65536] {
            #expect(throws: MailConfigurationError.invalidPort(.smtp)) {
                try MailServerConfiguration.validate(port: port, security: .tls, protocolKind: .smtp)
            }
        }
        try MailServerConfiguration.validate(port: 465, security: .tls, protocolKind: .smtp)
        try MailServerConfiguration.validate(port: 587, security: .startTLS, protocolKind: .smtp)
        try MailServerConfiguration.validate(port: 2525, security: .tls, protocolKind: .smtp)
    }

    @Test("Optional real SMTP TLS probe uses no account credentials", .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SMTP_HOST"] != nil))
    func liveSMTPProbe() async throws {
        let host = try #require(ProcessInfo.processInfo.environment["AGROOM_TEST_SMTP_HOST"])
        try await MailFoundationAdapter.probeSMTP(host: host, port: 465, security: .tls, timeoutMilliseconds: 10_000)
        let adapter = MailSmtpAdapter(host: host, port: 465, security: .tls)
        try await MailDeadline.call(10_000, label: "connect", client: adapter) { try await adapter.connect() }
        await adapter.disconnect()
    }
}
