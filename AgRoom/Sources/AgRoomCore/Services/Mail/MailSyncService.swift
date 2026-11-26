import Foundation
import MimeFoundation

// MARK: - Mail Sync Error

/// 同步层错误（区分「配置缺失」与「服务器失败」，便于 UI 给出可操作提示）。
public enum MailSyncError: LocalizedError, Equatable {
    case accountNotFound
    case accountDisabled
    case missingPassword
    case folderNotFound
    case messageNotFound
    /// 删除前发现同文件夹还有其他待删（`\Deleted`）邮件，已中止以免连带清除。
    case deletionWouldAffectOthers(count: Int)
    /// 操作中止后未能撤掉刚打上的 `\Deleted` 标记：**这封邮件仍处于待删状态**，
    /// 会在任何客户端触发 EXPUNGE 时被清除。必须让用户知道并自行处理。
    case deletionMarkedButNotRemoved(String)
    /// 删除命令已发出但目标邮件仍在服务器上（结果与意图不符）。
    case deletionIncomplete(String)
    /// 远端已移动，但服务器没给出目标 UID 且按 `Message-ID` 也没能定位：
    /// 本地归属未改，避免留下对不上服务器的假 UID；重新同步即可收敛。
    case moveNotReconciled
    /// 该草稿已带投递凭证（已经发出去过）：拒绝再次发送，否则会重复投递。
    case draftAlreadyDelivered
    /// 该草稿处于「正在投递 / 结果未知 / 已投递」状态：普通重试会造成重复投递。
    ///
    /// 与 `draftAlreadyDelivered` 的区别：这里不一定是「已发出」，而是「无法确认没发出」，
    /// 必须先到服务器核实再显式处置（见 `MailDeliveryState`）。
    case deliveryStateNotRetryable(MailDeliveryState)

    public var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "The mail account was not found."
        case .accountDisabled:
            return "The mail account is disabled."
        case .missingPassword:
            return "The mail account has no stored password or app password."
        case .folderNotFound:
            return "The mail folder was not found."
        case .messageNotFound:
            return "The mail message was not found."
        case .deletionWouldAffectOthers(let count):
            return "Deletion aborted: \(count) other message(s) in this folder are already marked for deletion."
        case .deletionMarkedButNotRemoved(let detail):
            return "Deletion was aborted, but the message is still marked as deleted on the server and "
                + "could be removed by another client: \(detail)"
        case .deletionIncomplete(let detail):
            return "The message is still on the server after the delete command: \(detail)"
        case .moveNotReconciled:
            return "The server moved the message but did not report its new UID; sync this folder again."
        case .draftAlreadyDelivered:
            return "This draft was already delivered; sending it again would duplicate the message."
        case .deliveryStateNotRetryable(let state):
            return "This draft is not retryable (delivery state: \(state.rawValue)); "
                + "verify the result on the server before sending it again."
        }
    }
}

// MARK: - Delivered But Not Archived Locally

/// 邮件**已经投递**，但本地「已发送」副本或草稿清理失败。
///
/// 与「发送失败」严格区分：投递是真实发生的外部副作用，不可撤销。界面必须把它显示为
/// 「已发送（本地记录失败）」并**禁止引导重试**——重试会造成重复投递。草稿连同投递
/// 凭证（时间与 Message-ID）仍在本地，用户可据此到服务器「已发送」核实并手动清理。
public struct MailDeliveredLocalSaveError: LocalizedError, Equatable {
    /// 底层失败原因（已脱敏：只含错误描述，不含正文与地址）。
    public let underlying: String
    public let missingSentFolder: Bool
    public let serverDraftCleanup: Bool

    public init(underlying: String, missingSentFolder: Bool = false, serverDraftCleanup: Bool = false) {
        self.underlying = underlying
        self.missingSentFolder = missingSentFolder
        self.serverDraftCleanup = serverDraftCleanup
    }

    public var errorDescription: String? {
        "The mail was delivered, but saving the local Sent copy failed: \(underlying)"
    }
}

// MARK: - Sync Result

/// 一次账号同步的汇总结果。
public struct MailSyncResult: Sendable, Equatable {
    /// 本次同步的（可选）文件夹数量。
    public let folderCount: Int
    /// 本次新增/刷新的邮件条数。
    public let messageCount: Int

    public init(folderCount: Int, messageCount: Int) {
        self.folderCount = folderCount
        self.messageCount = messageCount
    }
}

// MARK: - Mail Sync Service

/// IMAP 同步编排：文件夹发现、UIDVALIDITY/UIDNEXT 增量拉取、按需正文、标记回写。
///
/// 职责边界：本类型只做「网络 ↔ 本地」的编排；协议细节在 `MailProtocolClient`
/// （生产实现 `MailFoundationAdapter`），本地读写全部委托 `MailService`。
///
/// 连接生命周期：每个顶层操作独立建立连接（connect → authenticate → work →
/// disconnect），不跨操作复用会话，遵守「Hub 不缓存空间内服务」的约束。
///
/// 超时：所有协议调用都经 `MailDeadline` 兜底（预算见 `MailTimeoutBudget`）。
/// 超时会主动断开连接以解开底层读等待，因此**失败路径上连接一定不可再用**，
/// 调用方必须重新建连而不是重试同一连接。
///
/// 冲突策略：**本地读取状态为权威**。服务端摘要只在首次落库时写入 isRead/isStarred，
/// 后续同步保留本地值（见 `MailService.upsertMessages`）。
public actor MailSyncService {
    /// 单次增量拉取的 UID 窗口跨度（分批同步：批间响应取消、限制单次写事务时长）。
    ///
    /// 取 50 而非更大值：单次 `UID FETCH` 越小，企业服务器（如 Coremail）返回越快，
    /// 配合超时竞速（`MailDeadline`）与批间取消检查，进度更均匀、卡死的批次更短。
    /// 代价是同一文件夹的往返次数变多；若后续实测往返成为瓶颈再调大。
    public static let syncBatchSize = 50
    /// 单封邮件正文下载上限（附件不下载，只算头部与文本部件）。
    public static let bodyByteLimit = 4 * 1024 * 1024
    /// 首次同步（本地无记录）只拉最近的 UID 段：
    /// 企业/大账号 UID 历史可达数万，从 UID 1 全量翻页会让首屏长时间空白；
    /// 锚定到最近 1000 的 UID 段后首屏立即可用。锚点以下的历史当前不拉取，
    /// 定向回填尚未实现（见 `docs/wiki/10-改进清单.md`）。
    public static let initialSyncUIDWindow: UInt32 = 1_000

    /// 本服务所属空间；用作账号互斥租约的键（与 `accountId` 一起，保证双空间不互斥）。
    private let attachmentBoundary: URL
    private let attachmentDirectory: URL
    private let space: AppSpace
    /// 账号级异步互斥协调器：actor 在 `await` 处可重入，界面与引擎又各建一份服务，
    /// 因此「查询-判断-处置」这类序列必须靠它跨实例串行化（见 `MailAccountCoordinator`）。
    private let coordinator: MailAccountCoordinator

    private let accountService: MailAccountService
    private let mail: MailService
    /// 协议客户端工厂；注入以便测试用 mock，生产默认使用 MailFoundation。
    private let clientFactory: @Sendable (MailAccount) -> MailProtocolClient
    /// SMTP 发信客户端工厂；与 IMAP 分开注入（SMTP 是独立端点）。
    private let sendClientFactory: @Sendable (MailAccount) -> MailSendClient
    /// 口令来源；生产为 Keychain（经 `MailAccountService`），测试可注入固定口令。
    private let passwordProvider: @Sendable (UUID) -> String?
    /// 网络操作超时预算；测试可压到毫秒级以验证超时路径。
    private let timeoutBudget: MailTimeoutBudget
    /// 分批大小；测试可压小以验证取消与续传。
    private let batchSize: Int
    /// 正文下载上限；测试可压小以验证超限路径。
    private let bodyByteLimit: Int

    public init(
        accountService: MailAccountService,
        mail: MailService,
        space: AppSpace,
        coordinator: MailAccountCoordinator = .shared,
        attachmentDirectory: URL? = nil,
        clientFactory: @escaping @Sendable (MailAccount) -> MailProtocolClient = { account in
            MailFoundationAdapter(
                host: account.imapHost,
                port: account.imapPort,
                security: account.imapSecurity
            )
        },
        sendClientFactory: @escaping @Sendable (MailAccount) -> MailSendClient = { account in
            MailSmtpAdapter(
                host: account.smtpHost,
                port: account.smtpPort,
                security: account.smtpSecurity
            )
        },
        passwordProvider: (@Sendable (UUID) -> String?)? = nil,
        timeoutBudget: MailTimeoutBudget = .default,
        batchSize: Int = MailSyncService.syncBatchSize,
        bodyByteLimit: Int = MailSyncService.bodyByteLimit
    ) {
        self.accountService = accountService
        self.mail = mail
        self.space = space
        let boundary = attachmentDirectory?.standardizedFileURL.resolvingSymlinksInPath()
            ?? FileAreaService.standard.baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent(FileAreaService.defaultChatFolderName).appendingPathComponent(space.rawValue)
        self.attachmentBoundary = boundary
        self.attachmentDirectory = attachmentDirectory?.standardizedFileURL ?? boundary.appendingPathComponent("Mail", isDirectory: true)
        self.coordinator = coordinator
        self.clientFactory = clientFactory
        self.sendClientFactory = sendClientFactory
        self.passwordProvider = passwordProvider ?? { [accountService] accountId in
            accountService.password(for: accountId)
        }
        self.timeoutBudget = timeoutBudget
        self.batchSize = max(1, batchSize)
        self.bodyByteLimit = max(1, bodyByteLimit)
    }

    // MARK: - Deadline Helpers

    public nonisolated func folderOperations() -> MailFolderOperationService {
        MailFolderOperationService(mail: mail, accounts: accountService, space: space, coordinator: coordinator,
            clientFactory: clientFactory, passwordProvider: passwordProvider, budget: timeoutBudget)
    }

    public nonisolated func serverDrafts() -> MailServerDraftService {
        .init(mail: mail, accounts: accountService, space: space, coordinator: coordinator,
              factory: clientFactory, password: passwordProvider, budget: timeoutBudget)
    }

    /// 按预算执行一次协议调用；超时先断开该客户端再抛 `MailProtocolError.timedOut`。
    private func withDeadline<C: MailConnectedClient, T: Sendable>(
        _ milliseconds: Int,
        label: String,
        client: C,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await MailDeadline.call(milliseconds, label: label, client: client, body)
    }

    /// 建连 + 登录（两者各自受预算约束）。
    private func openSession<C: MailConnectedClient>(
        _ client: C,
        account: MailAccount,
        password: String
    ) async throws {
        try await MailDeadline.openSession(
            client,
            username: account.username,
            password: password,
            budget: timeoutBudget
        )
    }

    // MARK: - Account Sync

    public func signatureFolders(account: MailAccount) async throws -> [RemoteMailFolder] {
        try await withSignatureSession(account: account) { client in
            try await MailDeadline.call(self.timeoutBudget.listFolders, label: "signatureFolders", client: client) {
                try await client.listFolders()
            }.filter { $0.isSelectable && ($0.role == .sent || $0.role == .drafts) }
        }
    }

    public func signatureSources(account: MailAccount, folder: RemoteMailFolder) async throws -> [MailSignatureSource] {
        guard folder.isSelectable, folder.role == .sent || folder.role == .drafts else { throw MailSyncError.folderNotFound }
        let database = mail.databaseQueue
        return try await withSignatureSession(account: account) { client in
            let status = try await MailDeadline.call(self.timeoutBudget.folderStatus, label: "signatureFolderStatus", client: client) {
                try await client.folderStatus(path: folder.path)
            }
            guard let validity = status.uidValidity, validity > 0 else { throw MailSignatureImportError.changed }
            let recent = try await MailDeadline.call(self.timeoutBudget.fetchSummaries, label: "signatureSources", client: client) {
                try await client.recentSummaries(path: folder.path, messageCount: status.messageCount, limit: 30)
            }
            return recent.sorted { $0.uid > $1.uid }.prefix(30).map {
                .init(database: database, account: account, folder: folder, uidValidity: validity,
                      id: $0.uid, subject: $0.subject, date: $0.date)
            }
        }
    }

    public func signaturePreview(from source: MailSignatureSource) async throws -> MailSignaturePreview {
        guard source.database === mail.databaseQueue else { throw MailSignatureImportError.changed }
        return try await withSignatureSession(account: source.account) { client in
            let status = try await MailDeadline.call(self.timeoutBudget.folderStatus, label: "signatureIdentity", client: client) {
                try await client.folderStatus(path: source.folder.path)
            }
            guard status.uidValidity == source.uidValidity else { throw MailSignatureImportError.changed }
            let limit = min(self.bodyByteLimit, 1024 * 1024)
            let body = try await MailDeadline.call(self.timeoutBudget.fetchBody, label: "signatureBody", client: client) {
                try await client.fetchBody(path: source.folder.path, uid: source.id, maxBytes: limit)
            }
            guard (body.textBody?.utf8.count ?? 0) <= limit, (body.htmlBody?.utf8.count ?? 0) <= limit else {
                throw MailExportError.tooLarge
            }
            return try MailSignaturePreview(body: body)
        }
    }

    private func withSignatureSession<T: Sendable>(account: MailAccount,
        read: @escaping @Sendable (any MailProtocolClient) async throws -> T) async throws -> T {
        try await coordinator.withLease(space: space, accountId: account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            let context = try await self.prepare(accountId: account.id, expectedAccount: account)
            let client = self.clientFactory(context.account)
            do {
                try await self.openSession(client, account: context.account, password: context.password)
                let result = try await read(client)
                try Task.checkCancellation()
                await client.disconnect()
                return result
            } catch { await client.disconnect(); throw error }
        }
    }

    /// 同步整个账号：发现文件夹 → 逐个文件夹增量拉取（分批，可取消）。
    ///
    /// `progress` 在每个文件夹开始时上报已完成数（供界面显示进度）；
    /// 取消（`Task.cancel`）会结束网络等待，已写入的批次保留，下次同步从游标续传。
    /// 同一账号上的操作（同步 / 标记 / 移动 / 删除 / 发信）共用一把租约，覆盖整个
    /// 跨 `await` 生命周期，避免 actor 在挂起点重入导致交错或重复副作用。
    @discardableResult
    public func syncAccount(
        accountId: UUID,
        onlyRole: MailFolderRole? = nil,
        expectedAccount: MailAccount? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> MailSyncResult {
        try await coordinator.withLease(space: space, accountId: accountId, background: true, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performSyncAccount(accountId: accountId, onlyRole: onlyRole, expectedAccount: expectedAccount, progress: progress)
        }
    }

    /// `syncAccount` 主体；调用方必须已持有该账号的租约。
    private func performSyncAccount(
        accountId: UUID,
        onlyRole: MailFolderRole?,
        expectedAccount: MailAccount?,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MailSyncResult {
        let context = try await prepare(accountId: accountId, expectedAccount: expectedAccount)
        let client = clientFactory(context.account)
        do {
            try await openSession(client, account: context.account, password: context.password)

            let remoteFolders = try await withDeadline(
                timeoutBudget.listFolders,
                label: "listFolders",
                client: client
            ) {
                try await client.listFolders()
            }
            // 容器（\Noselect）保留为层级展示节点；SELECT/FETCH 仅对可选文件夹做。
            // 父子链按 delimiter 从 path 反推，补全缺失的中间节点。
            let hierarchy = Self.buildHierarchy(accountId: accountId, from: remoteFolders)
            try await mail.upsertFolders(hierarchy)
            try await mail.deleteFolders(accountId: accountId, keeping: hierarchy.map(\.path))

            var messageCount = 0
            let stored = try await mail.folders(accountId: accountId)
            // 首屏优先：收件箱排在最前，其余文件夹随后（大账号首次同步能先看到邮件）
            let ordered = stored
                .filter { !$0.isContainer && (onlyRole == nil || $0.role == onlyRole) }
                .sorted { lhs, rhs in
                    (lhs.role == .inbox ? 0 : 1) < (rhs.role == .inbox ? 0 : 1)
                }
            var completed = 0
            if onlyRole != nil, ordered.isEmpty { throw MailSyncError.folderNotFound }
            for folder in ordered {
                progress?(completed, ordered.count)
                messageCount += try await sync(folder: folder, client: client)
                completed += 1
            }
            progress?(completed, ordered.count)
            await client.disconnect()
            return MailSyncResult(folderCount: onlyRole == nil ? stored.count : ordered.count, messageCount: messageCount)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// 同步单个文件夹（供局部刷新使用）。
    @discardableResult
    public func syncFolder(accountId: UUID, folderId: UUID) async throws -> Int {
        try await coordinator.withLease(space: space, accountId: accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performSyncFolder(accountId: accountId, folderId: folderId)
        }
    }

    /// `syncFolder` 主体；调用方必须已持有该账号的租约。
    public func loadEarlier(accountId: UUID, folderId: UUID) async throws -> Int {
        try await coordinator.withLease(space: space, accountId: accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performSyncFolder(accountId: accountId, folderId: folderId, historyBatches: 2)
        }
    }

    public func rebuildFolderCache(accountId: UUID, folderId: UUID) async throws -> Int {
        try await coordinator.withLease(space: space, accountId: accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performSyncFolder(accountId: accountId, folderId: folderId, rebuild: true)
        }
    }

    private func performSyncFolder(accountId: UUID, folderId: UUID, historyBatches: Int = 1, rebuild: Bool = false) async throws -> Int {
        let context = try await prepare(accountId: accountId)
        guard let folder = try await mail.folders(accountId: accountId).first(where: { $0.id == folderId }) else {
            throw MailSyncError.folderNotFound
        }
        let client = clientFactory(context.account)
        do {
            try await openSession(client, account: context.account, password: context.password)
            if rebuild {
                // Never discard an offline flag edit as a side effect of rebuilding cache.
                try await flushPendingFlags(folder: folder, client: client)
                try await mail.clearMessages(folderId: folder.id)
                try await mail.clearCoverage(folderID: folder.id)
            }
            let count = try await sync(folder: folder, client: client, historyBatches: historyBatches)
            await client.disconnect()
            return count
        } catch {
            await client.disconnect()
            throw error
        }
    }

    // MARK: - On-demand Body

    /// 按需拉取正文与附件元数据并落库；成功/失败均更新正文状态。
    @discardableResult
    public func loadBody(messageId: UUID) async throws -> MailBody {
        guard let message = try await mail.message(id: messageId) else {
            throw MailSyncError.messageNotFound
        }
        return try await coordinator.withLease(space: space, accountId: message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performLoadBody(message: message)
        }
    }

    /// `loadBody` 主体；调用方必须已持有该账号的租约。
    private func performLoadBody(message: MailMessage, exportReview: MailExportReview? = nil) async throws -> MailBody {
        let messageId = message.id
        let review: MailExportReview
        if let exportReview { review = exportReview }
        else { review = try await mail.reviewExport(ids: [messageId]) }
        guard let source = review.source(messageId), source.message.accountId == message.accountId,
              source.message.folderId == message.folderId, source.message.uid == message.uid,
              source.message.messageId == message.messageId else { throw MailExportError.changed }
        try await validateExportSource(review, messageID: messageId)
        if let raw = try await mail.rawMessage(id: messageId) {
            let parse = Task.detached { try Task.checkCancellation(); return try MailSmtpAdapter.localBody(raw.data) }
            let remote = try await withTaskCancellationHandler { try await parse.value } onCancel: { parse.cancel() }
            guard (remote.textBody?.utf8.count ?? 0) <= bodyByteLimit,
                  (remote.htmlBody?.utf8.count ?? 0) <= bodyByteLimit else { throw MailExportError.tooLarge }
            try Task.checkCancellation()
            return try await persistBody(remote, messageId: messageId, exportReview: review)
        }
        guard message.uid < MailService.localUIDFloor else { throw MailExportError.incomplete }

        try await validateExportSource(review, messageID: messageId, network: true)
        let context = try await prepare(accountId: message.accountId, expectedAccount: source.account)
        guard let folder = try await mail.folders(accountId: message.accountId)
            .first(where: { $0.id == message.folderId }) else {
            throw MailSyncError.folderNotFound
        }

        let client = clientFactory(context.account)
        do {
            try await validateExportSource(review, messageID: messageId, network: true)
            try await openSession(client, account: context.account, password: context.password)
            if folder.uidValidity != nil {
                let status = try await withDeadline(timeoutBudget.folderStatus, label: "exportBodyIdentity", client: client) {
                    try await client.folderStatus(path: folder.path)
                }
                if let expected = folder.uidValidity, status.uidValidity != expected { throw MailExportError.changed }
            }
            let remote = try await withDeadline(
                timeoutBudget.fetchBody,
                label: "fetchBody",
                client: client
            ) {
                try await client.fetchBody(
                    path: folder.path,
                    uid: message.uid,
                    maxBytes: self.bodyByteLimit
                )
            }
            await client.disconnect()
            try Task.checkCancellation()
            try await validateExportSource(review, messageID: messageId)
            return try await persistBody(remote, messageId: messageId, exportReview: review)
        } catch {
            await client.disconnect()
            // 正文拉取失败要可重试：标记 failed 后下次进入详情会重新拉取
            if exportReview == nil {
                // A changed source must not receive the old request's failure state.
                if (try? await mail.validateExport(review, messageID: messageId)) != nil {
                    try? await mail.setBodyState(messageId: messageId, state: .failed)
                }
            }
            throw error
        }
    }

    /// Export can restore a retained original before considering credentials or
    /// the network, including received messages whose parsed body was evicted.
    public func bodyForExport(messageId: UUID, downloadIfNeeded: Bool, review: MailExportReview) async throws -> MailBody {
        guard let source = review.source(messageId) else { throw MailExportError.changed }
        return try await coordinator.withLease(space: space, accountId: source.message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.validateExportSource(review, messageID: messageId)
            let current = try await self.requireMessage(messageId)
            if let body = try await self.mail.body(messageId: messageId),
               body.textBody != nil || body.htmlBody != nil || current.bodyState == .ready { return body }
            if let raw = try await self.mail.rawMessage(id: messageId) {
                let parse = Task.detached { try Task.checkCancellation(); return try MailSmtpAdapter.localBody(raw.data) }
                let remote = try await withTaskCancellationHandler { try await parse.value } onCancel: { parse.cancel() }
                guard (remote.textBody?.utf8.count ?? 0) <= self.bodyByteLimit,
                      (remote.htmlBody?.utf8.count ?? 0) <= self.bodyByteLimit else { throw MailExportError.tooLarge }
                try Task.checkCancellation()
                try await self.validateExportSource(review, messageID: messageId)
                return try await self.persistBody(remote, messageId: messageId, exportReview: review)
            }
            guard downloadIfNeeded else { throw MailExportError.incomplete }
            return try await self.performLoadBody(message: current, exportReview: review)
        }
    }

    /// One bounded metadata repair per image source. Offline export may reparse
    /// a retained original, but never reads credentials or opens a connection.
    public func refreshInlineImageAttachments(messageId: UUID, downloadIfNeeded: Bool,
                                              exportReview: MailExportReview? = nil, expectedMessage: MailMessage? = nil) async throws {
        let review: MailExportReview
        if let exportReview { review = exportReview }
        else { review = try await mail.reviewExport(ids: [messageId]) }
        guard let source = review.source(messageId) else { throw MailExportError.changed }
        if let expectedMessage {
            guard expectedMessage.id == source.message.id, expectedMessage.accountId == source.message.accountId,
                  expectedMessage.folderId == source.message.folderId, expectedMessage.uid == source.message.uid,
                  expectedMessage.messageId == source.message.messageId else { throw MailExportError.changed }
        }
        try await coordinator.withLease(space: space, accountId: source.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try Task.checkCancellation()
            try await self.validateExportSource(review, messageID: messageId)
            if !downloadIfNeeded, try await self.mail.rawMessage(id: messageId) == nil { throw MailExportError.incomplete }
            _ = try await self.performLoadBody(message: source.message, exportReview: review)
        }
    }

    private func persistBody(_ remote: RemoteMessageBody, messageId: UUID, exportReview: MailExportReview) async throws -> MailBody {
        try await mail.saveExportBody(remote, messageID: messageId, review: exportReview, snippet: Self.snippet(remote.textBody ?? ""))
    }

    /// Read a selected attachment under its account lease. Disabling downloads still
    /// permits cache/local-original recovery, but never opens a connection or reads credentials.
    public func downloadAttachment(messageId: UUID, attachmentID: UUID, downloadIfNeeded: Bool = true,
                                   maxBytes: Int = 25 * 1024 * 1024, exportReview: MailExportReview? = nil,
                                   expectedAttachment: MailAttachment? = nil) async throws -> URL {
        guard maxBytes > 0, maxBytes <= MailDraftAttachment.maximumFileBytes else { throw MailAttachmentError.capacity }
        let message = try await requireMessage(messageId)
        return try await coordinator.withLease(space: space, accountId: message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.validateExportSource(exportReview, messageID: messageId)
            guard var attachment = try await self.mail.attachments(messageId: messageId).first(where: { $0.id == attachmentID }) else {
                throw MailSyncError.messageNotFound
            }
            if let expected = expectedAttachment {
                guard expected.id == attachment.id, expected.messageId == attachment.messageId,
                      Data(expected.filename.utf8) == Data(attachment.filename.utf8), expected.mimeType == attachment.mimeType,
                      expected.partID == attachment.partID, expected.contentId == attachment.contentId,
                      expected.isInline == attachment.isInline else { throw MailExportError.changed }
            }
            let root = self.attachmentDirectory
            let boundaryPath = self.attachmentBoundary.path
            func insideBoundary(_ url: URL) -> Bool {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                return path == boundaryPath || path.hasPrefix(boundaryPath + "/")
            }
            guard insideBoundary(root) else { throw MailProtocolError.invalidResponse("Attachment directory is outside its space.") }
            if let cached = attachment.localPath {
                let url = URL(fileURLWithPath: cached).standardizedFileURL
                if insideBoundary(url),
                   let parent = try? AppDirectory(url: url.deletingLastPathComponent(), create: false),
                   (try? parent.checkRegular(url.lastPathComponent, missingOK: false, limit: maxBytes)) != nil {
                    return url
                }
            }
            if let data = try await self.retainedAttachment(attachment, maxBytes: maxBytes) {
                try Task.checkCancellation()
                try await self.validateExportSource(exportReview, messageID: messageId)
                return try await self.cacheAttachment(data, attachment: attachment, exportReview: exportReview)
            }
            guard message.uid < MailService.localUIDFloor else { throw MailExportError.incomplete }
            guard downloadIfNeeded else { throw MailExportError.incomplete }
            try await self.validateExportSource(exportReview, messageID: messageId, network: true)
            if attachment.partID == nil || attachment.partID?.hasPrefix("local:") == true {
                // Received originals can be evicted after offline body recovery.
                // Refresh server part identities before fetching an uncached part.
                _ = try await self.performLoadBody(message: message, exportReview: exportReview)
                let matches = try await self.mail.attachments(messageId: messageId).filter {
                    $0.filename == attachment.filename && $0.mimeType == attachment.mimeType && $0.partID != nil
                        && MailService.normalizedAttachmentContentID($0.contentId) == MailService.normalizedAttachmentContentID(attachment.contentId)
                        && $0.isInline == attachment.isInline
                }
                guard matches.count == 1 else { throw MailProtocolError.invalidResponse("Reload the message to select this attachment.") }
                attachment = matches[0]
                // The fallback may have just recovered a complete original.
                if let data = try await self.retainedAttachment(attachment, maxBytes: maxBytes) {
                    try Task.checkCancellation()
                    try await self.validateExportSource(exportReview, messageID: messageId)
                    return try await self.cacheAttachment(data, attachment: attachment, exportReview: exportReview)
                }
            }
            guard let partID = attachment.partID, attachment.sizeBytes <= maxBytes else {
                throw MailProtocolError.messageTooLarge("Attachment exceeds the download limit.")
            }
            let context = try await self.prepare(accountId: message.accountId, expectedAccount: exportReview?.source(messageId)?.account)
            guard let folder = try await self.mail.folders(accountId: message.accountId).first(where: { $0.id == message.folderId }) else { throw MailSyncError.folderNotFound }
            let client = self.clientFactory(context.account)
            do {
                try await self.validateExportSource(exportReview, messageID: messageId, network: true)
                try await self.openSession(client, account: context.account, password: context.password)
                if exportReview != nil {
                    let status = try await self.withDeadline(self.timeoutBudget.folderStatus, label: "exportAttachmentIdentity", client: client) {
                        try await client.folderStatus(path: folder.path)
                    }
                    if let expected = folder.uidValidity, status.uidValidity != expected { throw MailExportError.changed }
                }
                let data = try await self.withDeadline(self.timeoutBudget.fetchBody, label: "fetchAttachment", client: client) {
                    try await client.fetchAttachment(path: folder.path, uid: message.uid, partID: partID, maxBytes: maxBytes)
                }
                await client.disconnect()
                try Task.checkCancellation()
                guard data.count <= maxBytes else { throw MailProtocolError.messageTooLarge("Attachment exceeds the download limit.") }
                try await self.validateExportSource(exportReview, messageID: messageId)
                return try await self.cacheAttachment(data, attachment: attachment, exportReview: exportReview)
            } catch { await client.disconnect(); throw error }
        }
    }

    private func retainedAttachment(_ selected: MailAttachment, maxBytes: Int) async throws -> Data? {
        guard let raw = try await mail.rawMessage(id: selected.messageId) else { return nil }
        let parse = Task.detached {
            try Task.checkCancellation()
            let parts = try MailSmtpAdapter.localBody(raw.data).attachments
            let matches = parts.filter {
                $0.filename == selected.filename && $0.mimeType.caseInsensitiveCompare(selected.mimeType) == .orderedSame
                    && MailService.normalizedAttachmentContentID($0.contentId) == MailService.normalizedAttachmentContentID(selected.contentId)
                    && $0.isInline == selected.isInline
            }
            let localPart: RemoteAttachment?
            if let partID = selected.partID, partID.hasPrefix("local:") { localPart = matches.first { $0.partID == partID } }
            else { localPart = matches.count == 1 ? matches.first : nil }
            guard let partID = localPart?.partID, let index = Int(partID.dropFirst(6)) else { throw MailAttachmentError.corrupt }
            return try MailSmtpAdapter.localAttachment(raw.data, index: index, filename: selected.filename, mimeType: selected.mimeType)
        }
        let data = try await withTaskCancellationHandler { try await parse.value } onCancel: { parse.cancel() }
        guard data.count <= maxBytes else { throw MailProtocolError.messageTooLarge("Attachment exceeds the download limit.") }
        return data
    }

    private func cacheAttachment(_ data: Data, attachment: MailAttachment, exportReview: MailExportReview? = nil) async throws -> URL {
        guard data.count <= MailDraftAttachment.maximumFileBytes else { throw MailAttachmentError.capacity }
        let resolved = attachmentDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let boundary = attachmentBoundary.path
        guard resolved == boundary || resolved.hasPrefix(boundary + "/") else { throw MailAttachmentError.corrupt }
        let root = try AppDirectory(url: attachmentDirectory, create: true)
        let child = try root.child(attachment.id.uuidString, create: true)
        let filename = Self.attachmentFilename(attachment)
        try child.checkRegular(filename, limit: MailDraftAttachment.maximumFileBytes)
        try child.write(data, name: filename)
        try root.verifyIdentity(at: attachmentDirectory)
        let url = try child.kernelURL().appendingPathComponent(filename).standardizedFileURL
        var cached = attachment; cached.localPath = url.path; cached.sizeBytes = data.count
        if let exportReview { try await mail.saveExportAttachment(cached, review: exportReview) }
        else { try await mail.saveAttachments([cached]) }
        return url
    }

    /// 先按字符串取末段；空路径不能交给 URL 解析，否则会解析为进程工作目录。
    private static func attachmentFilename(_ attachment: MailAttachment) -> String {
        let name = String(attachment.filename.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false).last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != ".", name != "..",
           name.rangeOfCharacter(from: .controlCharacters) == nil {
            return name
        }
        // 保留可识别的扩展名，让没有文件名的 PDF 等附件也能原生预览。
        let suffix = MimeTypeRegistry.default.extensionFor(mimeType: attachment.mimeType) ?? ""
        return "attachment" + suffix
    }

    // MARK: - Send

    /// 发送草稿：SMTP 投递 → 落本地「已发送」副本 → 删除草稿。
    ///
    /// 时序（每一处顺序都是有意的）：
    /// 1. **先远端投递**，成功后才写本地，避免「本地显示已发送但实际未发出」；
    /// 2. 投递成功后立刻把投递凭证（时间 + Message-ID）登记回草稿记录——这是崩溃窗口
    ///    内唯一能证明「这封邮件已经出去了」的依据，用户据此不会被引导重发；
    /// 3. **先落「已发送」副本，再删草稿**：副本落库失败时草稿连同投递凭证仍在，
    ///    不会出现「已投递但本地无任何痕迹」；
    /// 4. 副本落库失败抛 `MailDeliveredLocalSaveError`，与「未投递」严格区分——
    ///    界面据此提示「已投递但本地保存失败」，绝不引导用户重试（会重复投递）。
    ///
    /// 投递状态机（见 `MailDeliveryState`）：进入可能投递的阶段前把状态原子地落为
    /// `sending` 并固定 Message-ID；超时 / 二义失败落 `unknown`，持久化地阻止普通重发；
    /// 只有服务器**明确拒收**（确定未投递）才回落为可重试的 `prepared`。
    /// 状态与「是否允许重发」的判定（`claimDraftForDelivery`）在同一写事务里完成，
    /// 因此同草稿并发发送只有一个领取者，不会重复投递。
    @discardableResult
    public func send(draft: MailDraft, expectedAccount: MailAccount? = nil) async throws -> MailMessage? {
        try await coordinator.withLease(space: space, accountId: draft.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performSend(draft: draft, expectedAccount: expectedAccount)
        }
    }

    /// `send` 主体；调用方必须已持有该账号的租约（保证「查是否已投递 → 领取 → 投递」
    /// 的整段序列独占，同草稿并发发送只有一个领取者）。
    private func performSend(draft: MailDraft, expectedAccount: MailAccount?) async throws -> MailMessage? {
        let context = try await prepare(accountId: draft.accountId)
        let account = context.account
        guard expectedAccount == nil || expectedAccount == account else {
            throw ToolExecutionFailure(message: "The sending account changed. Request a fresh confirmation.")
        }
        let fromAddress = account.emailAddress.isEmpty ? account.username : account.emailAddress

        // 快速拒绝：已投递或处于不可重试状态时，连连接都不建。
        let existing = try await mail.draft(id: draft.id)
        if let existing {
            if existing.deliveredAt != nil {
                throw MailSyncError.draftAlreadyDelivered
            }
            if !existing.deliveryState.allowsRetry {
                throw MailSyncError.deliveryStateNotRetryable(existing.deliveryState)
            }
        }
        try MailDraftAttachment.validate(draft.attachments)
        guard draft.composeKind != .forward || draft.forwardAttachmentsState != .pending else { throw MailAttachmentError.sourceNotReady }
        try await mail.saveEditableDraft(draft)
        // 同一次投递尝试沿用同一 Message-ID，便于到服务器核对同一封信。
        // 注意：它只是身份标识，服务器不保证按它去重，不能当作幂等键。
        let messageId = existing?.pendingMessageId ?? Self.generatedMessageId(from: fromAddress)
        var outgoing = OutgoingMail(
            from: MailAddress(name: account.displayName, address: fromAddress),
            to: draft.to,
            cc: draft.cc,
            bcc: draft.bcc,
            subject: draft.subject,
            // 发送时组装「回复正文 + 原文引用」；草稿行仍分开保存两部分
            bodyText: draft.assembledBody,
            htmlBody: try draft.formattedHTML(),
            inReplyTo: draft.inReplyTo,
            references: draft.references,
            messageId: messageId,
            attachments: draft.attachments
        )
        outgoing.serializedData = try MailSmtpAdapter.serializedMessage(outgoing, date: Date())
        guard outgoing.serializedData!.count <= MailService.rawMessageByteLimit else { throw MailAttachmentError.capacity }
        let preparedOutgoing = outgoing

        // 建连 / 登录失败：确定没有投递出去，草稿保持可重试（顺带固定本次 Message-ID）。
        let client = sendClientFactory(account)
        do {
            try await openSession(client, account: account, password: context.password)
        } catch {
            await client.disconnect()
            _ = try? await mail.markDraftDeliveryState(id: draft.id, state: .prepared, messageId: messageId)
            throw error
        }

        // 原子领取：把「是否可发」判定与「进入投递中」的状态推进放进同一个写事务。
        // 这是「不能普通重发」的分界点，必须在发起 SMTP 之前落盘；写失败即中止，不投递。
        guard let claimed = try await mail.claimDraftForDelivery(draft, messageId: messageId) else {
            await client.disconnect()
            let current = try? await mail.draft(id: draft.id)
            throw MailSyncError.deliveryStateNotRetryable(current?.deliveryState ?? .sending)
        }
        // 领取成功：库中内容即本次要投递的内容（claim 已用传入草稿写入），
        // Message-ID 也已固定，`outgoing` 可直接使用。
        do {
            do {
                try await withDeadline(timeoutBudget.send, label: "send", client: client) {
                    try await client.send(preparedOutgoing)
                }
            } catch let error as MailProtocolError where error.isTimeout {
                // 投递超时是「结果未知」：服务器可能已经收下这封邮件。持久化为 unknown，
                // 重开 / 重启后继续阻止普通重发，由用户核实后显式处置。
                _ = try? await mail.markDraftDeliveryState(id: draft.id, state: .unknown, messageId: messageId)
                throw MailProtocolError.sendResultUnknown(
                    "SMTP delivery did not return within \(timeoutBudget.send) ms"
                )
            } catch let error as MailProtocolError where Self.isDefinitelyNotDelivered(error) {
                // 服务器明确拒收（MAIL FROM / RCPT TO / DATA 被拒）：确定未投递，回到可重试态。
                _ = try? await mail.markDraftDeliveryState(id: draft.id, state: .prepared, messageId: messageId)
                throw error
            } catch {
                // 其余情况无法判断服务器是否已收下 DATA：一律按结果未知处理，禁止普通重发。
                _ = try? await mail.markDraftDeliveryState(id: draft.id, state: .unknown, messageId: messageId)
                throw error
            }
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()

        // 投递已成功：先登记投递凭证，此后任何失败都不能再报「发送失败」。
        // 这一步本身失败也**不能**当成发送失败——SMTP 已经收了这封信；
        // 只是「本地无凭证」的风险升高，如实记日志后继续（副本成功即可消除）。
        do {
            let recorded = try await mail.markDraftDelivered(id: draft.id, messageId: messageId)
            if !recorded {
                // 领取时已落库，正常必命中；未命中说明草稿在发送期间被移除，
                // 这会让「已投递」失去唯一本地凭证，必须留痕以便排查。
                HubLogger.shared.error(
                    "Mail delivered but the draft record was missing when recording delivery proof: "
                        + "draft \(draft.id)"
                )
            }
        } catch {
            HubLogger.shared.error(
                "Mail delivered but recording the delivery proof failed: \(HubLogger.safeErrorSummary(error))"
            )
        }
        // accepted 晚于凭证登记：若中间崩溃，状态仍是 sending（不可重试，安全方向）。
        _ = try? await mail.markDraftDeliveryState(id: draft.id, state: .accepted, messageId: messageId)

        var serverCleanupFailed = false
        do { try await serverDrafts().retireAfterDelivery(draftID: draft.id) }
        catch { serverCleanupFailed = true; HubLogger.shared.warning("Delivered mail server draft needs checking: " + HubLogger.safeErrorSummary(error)) }

        do {
            let stored = try await saveSentCopy(of: claimed, outgoing: outgoing, messageId: messageId)
            if serverCleanupFailed { throw MailDeliveredLocalSaveError(underlying: "Server draft cleanup requires verification", serverDraftCleanup: true) }
            // 副本落库成功后才清理草稿：草稿是「已投递」的唯一本地凭证
            do {
                try await mail.deleteDraft(id: draft.id)
            } catch {
                HubLogger.shared.warning(
                    "Mail delivered and archived, but the draft could not be removed: "
                        + HubLogger.safeErrorSummary(error)
                )
            }
            return stored
        } catch {
            if let delivered = error as? MailDeliveredLocalSaveError, delivered.serverDraftCleanup { throw delivered }
            HubLogger.shared.error(
                "Mail delivered but the local Sent copy failed: \(HubLogger.safeErrorSummary(error))"
            )
            // 已投递但本地副本失败：持久化为 localSaveFailed（同样禁止普通重发）。
            _ = try? await mail.markDraftDeliveryState(id: draft.id, state: .localSaveFailed, messageId: messageId)
            throw MailDeliveredLocalSaveError(underlying: error.localizedDescription, missingSentFolder: (error as? MailSyncError) == .folderNotFound)
        }
    }

    /// 只有服务器**明确拒收**（确定未投递）的协议错误才允许回落为可重试状态。
    ///
    /// `sendFailed` 由 SMTP 适配器仅在 MAIL FROM / RCPT TO / DATA 被服务器明确拒绝时给出
    /// （见 `MailFoundationAdapter.sendError`）；连接中断、超时、`sendResultUnknown`
    /// 都无法排除「服务器已收下」，绝不能当作可重试失败。
    private static func isDefinitelyNotDelivered(_ error: MailProtocolError) -> Bool {
        switch error {
        case .notConnected, .authenticationFailed, .connectionFailed, .tlsUnsupported,
             .invalidResponse, .sendFailed, .messageTooLarge:
            return true
        case .timedOut, .sendResultUnknown:
            return false
        }
    }

    // MARK: - Move / Delete

    /// 移动邮件：先远端 MOVE，成功后按**目标文件夹的新 UID** 改本地归属。
    ///
    /// `MOVE`（RFC 6851）会在目标文件夹分配新 UID，源 UID 不再有效；沿用源 UID 会让
    /// 记录指向另一封邮件，并让增量游标错位。这里按优先级取正确 UID：
    /// 1. 服务器 `COPYUID` 给出的目标 UID；
    /// 2. 否则在目标文件夹按 `Message-ID` 重抓一次；
    /// 3. 都拿不到时只在本地按目标文件夹分配序号并标记未对账（下次同步按 `Message-ID` 归并）。
    public func moveMessage(messageId: UUID, toFolderId: UUID, review: MailMoveReview? = nil) async throws {
        let message = try await requireMessage(messageId)
        try await coordinator.withLease(space: space, accountId: message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            if let review { try await self.mail.validateMove(review, destinationID: toFolderId, messageID: messageId) }
            let current = try await self.requireMessage(messageId)
            guard current.accountId == message.accountId else { throw MailMoveReviewError.changed }
            try await self.performMoveMessage(message: current, toFolderId: toFolderId)
        }
    }

    /// `moveMessage` 主体；调用方必须已持有该账号的租约。
    private func performMoveMessage(message: MailMessage, toFolderId: UUID) async throws {
        let messageId = message.id
        guard let target = try await mail.folders(accountId: message.accountId)
            .first(where: { $0.id == toFolderId && !$0.isContainer }) else {
            throw MailSyncError.folderNotFound
        }
        if message.folderId == target.id { return }

        // 本地自产副本在服务器上没有对应物，直接改归属（UID 保持本地保留区间）
        guard message.uid < MailService.localUIDFloor else {
            try await mail.moveMessage(id: messageId, toFolderId: toFolderId, uid: message.uid)
            return
        }

        let context = try await prepare(accountId: message.accountId)
        guard let source = try await mail.folders(accountId: message.accountId)
            .first(where: { $0.id == message.folderId }) else {
            throw MailSyncError.folderNotFound
        }
        let client = clientFactory(context.account)
        do {
            try await openSession(client, account: context.account, password: context.password)
            let result = try await withDeadline(
                timeoutBudget.write,
                label: "moveMessage",
                client: client
            ) {
                try await client.moveMessage(path: source.path, uid: message.uid, toPath: target.path)
            }
            // 目标 UID 未知时在同一连接内按 Message-ID 重抓，避免再建一次连接
            var uid = result.uid
            if uid == nil {
                uid = try? await locateMovedMessage(
                    client: client,
                    target: target,
                    messageId: message.messageId
                )
            }
            await client.disconnect()
            try await applyMove(
                messageId: messageId,
                target: target,
                result: result,
                uid: uid
            )
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// 永久删除一封邮件：只影响这一封，并对账实际删除结果。
    ///
    /// 安全删除的顺序（不带 UID 的 `EXPUNGE` 会删掉该文件夹里**所有**已标 `\Deleted`
    /// 的邮件，见 RFC 3501 §6.4.3，因此必须先证明没有别的待删邮件）：
    /// 1. 取该文件夹里已标 `\Deleted` 的 UID 集合；
    /// 2. 目标已在其中 → 说明上次已标记未清除，继续走清除；
    /// 3. 集合里有其他 UID → 标记目标并尝试 `UID EXPUNGE`（只删目标，需 UIDPLUS）；
    ///    不支持时**中止并明确报错**，绝不退化成全量 EXPUNGE；
    /// 4. 集合为空 → 标记目标后 `EXPUNGE`，此时该文件夹只有这一封待删；
    /// 5. 清除后用搜索对账，目标仍在则报「删除未完成」，本地记录保留。
    public func deleteMessage(messageId: UUID) async throws {
        let message = try await requireMessage(messageId)
        try await coordinator.withLease(space: space, accountId: message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performDeleteMessage(message: message)
        }
    }

    /// `deleteMessage` 主体；调用方必须已持有该账号的租约。
    private func performDeleteMessage(message: MailMessage) async throws {
        let messageId = message.id

        // 本地自产副本没有服务器对应物，直接删本地
        guard message.uid < MailService.localUIDFloor else {
            try await mail.deleteMessage(id: messageId)
            return
        }

        let context = try await prepare(accountId: message.accountId)
        guard let folder = try await mail.folders(accountId: message.accountId)
            .first(where: { $0.id == message.folderId }) else {
            throw MailSyncError.folderNotFound
        }
        let client = clientFactory(context.account)
        do {
            try await openSession(client, account: context.account, password: context.password)
            let deleted = try await withDeadline(
                timeoutBudget.write,
                label: "deleteMessage",
                client: client
            ) {
                try await self.safeDelete(folder: folder, uid: message.uid, client: client)
            }
            await client.disconnect()
            guard deleted else {
                throw MailSyncError.deletionIncomplete("UID \(message.uid) is still marked deleted on the server")
            }
            try await mail.deleteMessage(id: messageId)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// 安全删除的主体：返回目标 UID 是否确实已从服务器消失。
    private func safeDelete(folder: MailFolder, uid: UInt32, client: MailProtocolClient) async throws -> Bool {
        let pending = try await withDeadline(timeoutBudget.write, label: "searchDeleted", client: client) {
            try await client.searchUIDs(path: folder.path, flag: .deleted)
        }
        let others = pending.filter { $0 != uid }
        let targetIsMarked = pending.contains(uid)

        if !targetIsMarked {
            try await withDeadline(timeoutBudget.write, label: "markDeleted", client: client) {
                try await client.markDeleted(path: folder.path, uid: uid)
            }
        }

        do {
            if others.isEmpty {
                // 该文件夹只有这一封待删，全量 EXPUNGE 等价于只删它
                try await withDeadline(timeoutBudget.write, label: "expunge", client: client) {
                    try await client.expungeAllDeleted(path: folder.path)
                }
            } else {
                // 有其他待删邮件：只允许 UID EXPUNGE
                try await withDeadline(timeoutBudget.write, label: "uidExpunge", client: client) {
                    try await client.expungeUIDs(path: folder.path, uids: [uid])
                }
            }
        } catch {
            // 清除失败：把刚打上的标记撤掉，避免邮件留在「待删」态被别的客户端清掉。
            // 只有「本来就是这个标记」的情况才不需要撤销（那不是我们造成的）。
            if !targetIsMarked {
                do {
                    try await withDeadline(timeoutBudget.write, label: "unmarkDeleted", client: client) {
                        try await client.unmarkDeleted(path: folder.path, uid: uid)
                    }
                } catch {
                    // 撤销也失败：邮件真的还处于待删状态，必须如实上报，不能报成「已中止、什么都没变」
                    HubLogger.shared.error(
                        "Mail delete aborted but the \\Deleted flag could not be cleared: "
                            + HubLogger.safeErrorSummary(error)
                    )
                    throw MailSyncError.deletionMarkedButNotRemoved(error.localizedDescription)
                }
            }
            if !others.isEmpty {
                throw MailSyncError.deletionWouldAffectOthers(count: others.count)
            }
            throw error
        }

        // 对账：清除后目标必须真的不在待删集合里
        let remaining = try await withDeadline(timeoutBudget.write, label: "verifyDelete", client: client) {
            try await client.searchUIDs(path: folder.path, flag: .deleted)
        }
        return !remaining.contains(uid)
    }

    /// 按 `Message-ID` 在目标文件夹回看最近一批，定位移动后的新 UID。
    ///
    /// 服务器不回 `COPYUID` 时的回落：目标 UID 未知就不能沿用源 UID，否则本地记录
    /// 会指向另一封邮件。`Message-ID` 缺失或对不上时返回 nil，由调用方按「未对账」处理。
    private func locateMovedMessage(
        client: MailProtocolClient,
        target: MailFolder,
        messageId: String?
    ) async throws -> UInt32? {
        guard let messageId, !messageId.isEmpty else { return nil }
        let recent = try await withDeadline(
            timeoutBudget.fetchSummaries,
            label: "locateMoved",
            client: client
        ) {
            try await client.fetchSummaries(path: target.path, sinceUID: nil, limit: self.batchSize)
        }
        return recent.last { $0.messageId == messageId }?.uid
    }

    /// 把远端移动结果落到本地：UID 与 UIDVALIDITY 都按服务器实际值写回。
    private func applyMove(
        messageId: UUID,
        target: MailFolder,
        result: RemoteMoveResult,
        uid: UInt32?
    ) async throws {
        guard let uid else {
            // 拿不到目标 UID：不改本地归属，保持记录可解释（远端已移动，重同步收敛）
            HubLogger.shared.warning(
                "Mail move succeeded but the target UID could not be resolved; target folder needs a re-sync"
            )
            throw MailSyncError.moveNotReconciled
        }
        // 目标文件夹 UID 空间已重建：本地缓存整体失效，先清空再写入
        if let remoteValidity = result.uidValidity,
           let localValidity = target.uidValidity,
           remoteValidity != localValidity {
            try await mail.clearMessages(folderId: target.id)
        }
        try await mail.moveMessage(id: messageId, toFolderId: target.id, uid: uid)
    }

    // MARK: - Flag Write-back

    public func rawMessage(messageId: UUID, downloadIfNeeded: Bool, exportReview: MailExportReview? = nil) async throws -> MailRawMessage {
        let message = try await requireMessage(messageId)
        return try await coordinator.withLease(space: space, accountId: message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.validateExportSource(exportReview, messageID: messageId)
            let current = try await self.requireMessage(messageId)
            if let cached = try await self.mail.rawMessage(id: messageId) { return cached }
            // Old local Sent copies have no server counterpart. Export a clearly
            // labelled reconstruction, never silently substitute one for a server original.
            if current.uid >= MailService.localUIDFloor {
                if try await self.accountService.account(id: current.accountId)?.isLocalArchive == true {
                    throw MailExportError.incomplete
                }
                guard !current.hasAttachments, let body = try await self.mail.body(messageId: messageId),
                      let text = body.textBody else { throw MailExportError.incomplete }
                let data = try MailSmtpAdapter.serializedMessage(.init(from: .init(name: current.fromName, address: current.fromAddress),
                    to: current.to, cc: current.cc, subject: current.subject, bodyText: text,
                    references: current.references, messageId: current.messageId), date: current.date ?? Date())
                let raw = MailRawMessage(data: data, kind: .generated)
                try await self.mail.saveRawMessage(id: messageId, raw: raw, expected: current)
                return raw
            }
            guard downloadIfNeeded else { throw MailExportError.incomplete }
            try await self.validateExportSource(exportReview, messageID: messageId, network: true)
            let context = try await self.prepare(accountId: current.accountId, expectedAccount: exportReview?.source(messageId)?.account)
            guard let folder = try await self.mail.folders(accountId: current.accountId).first(where: { $0.id == current.folderId }) else { throw MailSyncError.folderNotFound }
            let client = self.clientFactory(context.account)
            do {
                try await self.validateExportSource(exportReview, messageID: messageId, network: true)
                try await self.openSession(client, account: context.account, password: context.password)
                let status = try await self.withDeadline(self.timeoutBudget.folderStatus, label: "rawIdentity", client: client) {
                    try await client.folderStatus(path: folder.path)
                }
                if let expected = folder.uidValidity, status.uidValidity != expected { throw MailExportError.changed }
                let data = try await self.withDeadline(self.timeoutBudget.fetchBody, label: "fetchRaw", client: client) {
                    try await client.fetchRawMessage(path: folder.path, uid: current.uid, maxBytes: MailService.rawMessageByteLimit)
                }
                await client.disconnect()
                try Task.checkCancellation()
                guard data.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
                if let expected = current.messageId, !expected.isEmpty {
                    guard try MailFoundationAdapter.originalMessageID(data) == expected else { throw MailExportError.changed }
                }
                let raw = MailRawMessage(data: data, kind: .received)
                try await self.validateExportSource(exportReview, messageID: messageId)
                try await self.mail.saveRawMessage(id: messageId, raw: raw, expected: current)
                return raw
            } catch { await client.disconnect(); throw error }
        }
    }

    /// 每封复用原有账号租约与安全写入。取消保留已完成回执，不重放结果未知的写操作。
    public func applyBatch(messageIDs: [UUID], action: MailBatchAction, moveReview: MailMoveReview? = nil,
                           progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async -> MailBatchResult {
        var seen = Set<UUID>()
        let ids = messageIDs.filter { seen.insert($0).inserted }
        var result = MailBatchResult()
        var undoEntries: [MailOperationUndoEntry] = []
        for (index, id) in ids.enumerated() {
            if Task.isCancelled { result.unprocessed = Array(ids[index...]); break }
            do {
                if let entry = try await performRecordedBatchItem(id, action: action, review: moveReview) { undoEntries.append(entry) }
                result.succeeded.append(id)
            } catch {
                result.failures.append(.init(messageID: id, error: error))
                if error is CancellationError {
                    result.unprocessed = Array(ids.dropFirst(index + 1))
                    break
                }
            }
            await progress(result.succeeded.count + result.failures.count, ids.count)
        }
        if !undoEntries.isEmpty { result.undoReceipt = .init(originQueue: mail.databaseQueue, entries: undoEntries) }
        return result
    }

    private func performRecordedBatchItem(_ id: UUID, action: MailBatchAction, review: MailMoveReview?) async throws -> MailOperationUndoEntry? {
        let message = try await requireMessage(id)
        return try await coordinator.withLease(space: space, accountId: message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try Task.checkCancellation()
            let before = try await self.mail.operationSnapshot(id)
            guard before.account.id == message.accountId else { throw MailMoveReviewError.changed }
            switch action {
            case .read(let value): try await self.performSetRead(before.message, value: value)
            case .star(let value): try await self.performSetStar(before.message, value: value)
            case .move(let target):
                if let review { try await self.mail.validateMove(review, destinationID: target, messageID: id) }
                try await self.performMoveMessage(message: before.message, toFolderId: target)
            case .moveToRole(let role):
                guard let target = try await self.mail.folders(accountId: message.accountId).first(where: { $0.role == role && !$0.isContainer }) else { throw MailSyncError.folderNotFound }
                try await self.performMoveMessage(message: before.message, toFolderId: target.id)
            case .permanentlyDelete:
                guard before.folder.role == .trash else { throw MailSyncError.folderNotFound }
                try await self.performDeleteMessage(message: before.message)
                return nil
            }
            // Failure to capture an optional undo proof cannot turn an already
            // acknowledged operation into a retryable failure.
            let after: MailOperationSnapshot
            do { after = try await self.mail.operationSnapshot(id) } catch { return nil }
            guard MailService.sameFolderMutationAccount(before.account, after.account),
                  after.message.accountId == before.message.accountId, after.message.messageId == before.message.messageId else { return nil }
            if after.message.uid < MailService.localUIDFloor,
               before.folder.uidValidity == nil || after.folder.uidValidity == nil { return nil }
            let changed: Bool
            switch action {
            case .read: changed = before.message.isRead != after.message.isRead
            case .star: changed = before.message.isStarred != after.message.isStarred
            default: changed = before.message.folderId != after.message.folderId
            }
            return changed ? .init(before: before, after: after, action: action) : nil
        }
    }

    public func undoBatch(_ review: MailOperationUndoReview,
                          progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async -> MailBatchResult {
        var result = MailBatchResult()
        guard review.receipt.originQueue === mail.databaseQueue else {
            result.failures = review.entries.map { .init(messageID: $0.id, error: MailMoveReviewError.changed) }; return result
        }
        for (index, entry) in review.entries.enumerated() {
            if Task.isCancelled { result.unprocessed = review.entries[index...].map(\.id); break }
            do {
                try await coordinator.withLease(space: space, accountId: entry.after.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
                    try Task.checkCancellation()
                    try await self.mail.validateOperationUndo(entry)
                    guard await review.receipt.claims.claim(entry.id) else { throw MailMoveReviewError.changed }
                    let current = try await self.requireMessage(entry.id)
                    if current.uid >= MailService.localUIDFloor {
                        try await self.mail.undoLocalOperation(entry)
                        return
                    }
                    switch entry.action {
                    case .read: try await self.performSetRead(current, value: entry.before.message.isRead)
                    case .star: try await self.performSetStar(current, value: entry.before.message.isStarred)
                    case .move, .moveToRole: try await self.performMoveMessage(message: current, toFolderId: entry.before.folder.id)
                    case .permanentlyDelete: throw MailMoveReviewError.changed
                    }
                }
                result.succeeded.append(entry.id)
            } catch { result.failures.append(.init(messageID: entry.id, error: error)) }
            await progress(index + 1, review.entries.count)
        }
        return result
    }

    private func performSetRead(_ message: MailMessage, value: Bool) async throws {
        let remote = message.uid < MailService.localUIDFloor
        try await mail.setFlags(messageId: message.id, isRead: value, pendingRemote: remote)
        if remote { await pushFlags(for: message) }
    }

    private func performSetStar(_ message: MailMessage, value: Bool) async throws {
        let remote = message.uid < MailService.localUIDFloor
        try await mail.setFlags(messageId: message.id, isStarred: value, pendingRemote: remote)
        if remote { await pushFlags(for: message) }
    }

    /// 本地写入已读状态并尽力回写 IMAP `\Seen`。
    public func setRead(messageId: UUID, isRead: Bool) async throws {
        // 邮件不存在时保持静默无操作（与 `MailService.setFlags` 的语义一致）。
        guard let message = try await mail.message(id: messageId) else { return }
        try await coordinator.withLease(space: space, accountId: message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            let current = try await self.requireMessage(messageId)
            guard current.accountId == message.accountId else { throw MailMoveReviewError.changed }
            try await self.performSetRead(current, value: isRead)
        }
    }

    /// 本地写入星标状态并尽力回写 IMAP `\Flagged`。
    public func setStarred(messageId: UUID, isStarred: Bool) async throws {
        guard let message = try await mail.message(id: messageId) else { return }
        try await coordinator.withLease(space: space, accountId: message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            let current = try await self.requireMessage(messageId)
            guard current.accountId == message.accountId else { throw MailMoveReviewError.changed }
            try await self.performSetStar(current, value: isStarred)
        }
    }

    /// Flush the latest queued values, including a manual mark-unread made after opening.
    public func flushOpenedFolder(_ message: MailMessage) async throws {
        try await coordinator.withLease(space: space, accountId: message.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            guard try await !self.mail.pendingFlags(folderID: message.folderId).isEmpty else { return }
            await self.pushFlags(for: message, requireValidity: true)
        }
    }

    private func pushFlags(for message: MailMessage, requireValidity: Bool = false) async {
        do { try await mail.requireNoPendingFolderMutation(message.accountId) }
        catch { HubLogger.shared.warning("Mail flags remain queued while a folder operation requires review"); return }
        guard
              let account = try? await accountService.account(id: message.accountId),
              account.isEnabled, !account.isLocalArchive,
              let folder = try? await mail.folders(accountId: message.accountId)
                  .first(where: { $0.id == message.folderId }),
              !requireValidity || folder.uidValidity != nil,
              let password = passwordProvider(message.accountId), !password.isEmpty else {
            return
        }

        let client = clientFactory(account)
        do {
            try await openSession(client, account: account, password: password)
            if requireValidity || folder.uidValidity != nil {
                let status = try await withDeadline(timeoutBudget.folderStatus, label: "flagIdentity", client: client) {
                    try await client.folderStatus(path: folder.path)
                }
                guard let validity = folder.uidValidity, validity == status.uidValidity else {
                    await client.disconnect()
                    return
                }
            }
            try await flushPendingFlags(folder: folder, client: client)
            await client.disconnect()
        } catch {
            await client.disconnect()
            HubLogger.shared.warning("Mail flag write-back failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    // MARK: - Private Helpers

    /// 取出可用账号与口令（口令只在 Keychain，始终在内存中短暂使用）。
    private func prepare(accountId: UUID, allowsPendingFolderMutation: Bool = false, expectedAccount: MailAccount? = nil) async throws -> (account: MailAccount, password: String) {
        guard let account = try await accountService.account(id: accountId) else {
            throw MailSyncError.accountNotFound
        }
        if let expectedAccount, !MailService.sameFolderMutationAccount(account, expectedAccount) { throw MailExportError.changed }
        guard !account.isLocalArchive else { throw MailImportError.localOnly }
        guard account.isEnabled else { throw MailSyncError.accountDisabled }
        if !allowsPendingFolderMutation { try await mail.requireNoPendingFolderMutation(accountId) }
        guard let password = passwordProvider(accountId), !password.isEmpty else {
            throw MailSyncError.missingPassword
        }
        return (account, password)
    }

    private func validateExportSource(_ review: MailExportReview?, messageID: UUID, network: Bool = false) async throws {
        guard let review else { return }
        try await mail.validateExport(review, messageID: messageID)
        if network, review.source(messageID)?.allowsNetwork != true { throw MailExportError.incomplete }
    }

    /// 按 id 取出邮件，不存在即抛错。
    private func requireMessage(_ messageId: UUID) async throws -> MailMessage {
        guard let message = try await mail.message(id: messageId) else {
            throw MailSyncError.messageNotFound
        }
        return message
    }

    /// 发信成功后落本地「已发送」副本（无 `role == .sent` 文件夹时跳过并记日志）。
    ///
    /// 起因：上游 `MailFoundation` 无 IMAP `APPEND`，副本无法回写服务器，只能本地留存。
    /// UID 由 `MailService.saveLocalMessage` 在保留区间分配。
    private func saveSentCopy(
        of draft: MailDraft,
        outgoing: OutgoingMail,
        messageId: String
    ) async throws -> MailMessage? {
        guard let sent = try await mail.folders(accountId: draft.accountId)
            .first(where: { $0.role == .sent }) else {
            throw MailSyncError.folderNotFound
        }

        let stored = try await mail.saveLocalMessage(
            MailMessage(
                accountId: draft.accountId,
                folderId: sent.id,
                uid: 0,
                messageId: messageId,
                subject: draft.subject,
                fromName: outgoing.from.name,
                fromAddress: outgoing.from.address,
                to: draft.to,
                cc: draft.cc,
                references: outgoing.references,
                date: Date(),
                isRead: true,
                hasAttachments: !outgoing.attachments.isEmpty,
                sizeBytes: outgoing.serializedData?.count ?? outgoing.bodyText.utf8.count,
                snippet: Self.snippet(outgoing.bodyText),
                bodyState: .ready
            )
        )
        try await mail.saveBody(
            MailBody(messageId: stored.id, textBody: outgoing.bodyText, htmlBody: outgoing.htmlBody)
        )
        guard let serialized = outgoing.serializedData else { throw MailAttachmentError.corrupt }
        try await mail.saveRawMessage(id: stored.id, raw: .init(data: serialized, kind: .generated), expected: stored)
        try await mail.saveAttachments(outgoing.attachments.enumerated().map { index, attachment in
            MailAttachment(messageId: stored.id, filename: attachment.filename, mimeType: attachment.mimeType,
                           sizeBytes: attachment.data.count, partID: "local:\(index)")
        })
        return stored
    }

    /// 本地生成 Message-ID（落副本与投递凭证共用，便于用户到服务器核对）。
    private static func generatedMessageId(from address: String) -> String {
        let host = address.split(separator: "@").last.map(String.init) ?? "agroom.local"
        return "<\(UUID().uuidString.lowercased())@\(host)>"
    }

    /// 正文摘要（列表展示用）：折叠空白并截断。
    private static func snippet(_ text: String, limit: Int = 120) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit))
    }

    /// 单个文件夹的增量同步：分批拉取、逐批落库，批间响应取消。
    ///
    /// 返回本次拉取的条数。取消发生在批间：已写入的批次保留（游标＝该批最大 UID），
    /// 下次同步从游标续传，不会重复也不会丢。
    private func sync(folder: MailFolder, client: MailProtocolClient, historyBatches: Int = 1) async throws -> Int {
        try await mail.requireFolderLocation(folder)
        let status = try await withDeadline(
            timeoutBudget.folderStatus,
            label: "folderStatus",
            client: client
        ) {
            try await client.folderStatus(path: folder.path)
        }

        // UIDVALIDITY 变化表示 UID 空间已重建，本地数据必须整体丢弃
        if let remoteValidity = status.uidValidity,
           let localValidity = folder.uidValidity,
           remoteValidity != localValidity {
            try await mail.clearMessages(folderId: folder.id, expectedFolder: folder)
            try await mail.clearCoverage(folderID: folder.id, expectedFolder: folder)
        }

        let previouslyCached = try await mail.cachedServerUIDs(folderID: folder.id)
        let remoteUIDs = try await withDeadline(timeoutBudget.fetchSummaries, label: "allUIDs", client: client) {
            try await client.allUIDs(path: folder.path)
        }.filter { $0 > 0 && $0 < MailService.localUIDFloor }.sorted()
        let remoteSet = Set(remoteUIDs)

        // 游标按 **UID 窗口上界** 推进，而不是按「本批返回条数」判定结束。
        //
        // 旧实现把「返回数量少于一整批」当作同步结束，与适配器的 `limit`（UID 区间上界）
        // 含义不同：服务器只剩 UID 1 与 900 时，第一批 `1:500` 只返回一封、数量少于一批，
        // 同步就此结束，UID 900 永远不会被同步。改为用 `UIDNEXT` 推出已存在 UID 的上界，
        // 窗口按 UID 推进——窗口内实际有几封邮件、中间是否有空洞，都不影响继续扫描。
        let maxLocalUID = try await mail.maxUID(folderId: folder.id)
        // UIDNEXT 是「下一个将分配的 UID」，故已存在 UID 的上界是 uidNext - 1。
        var highestUID: UInt32? = (status.uidNext ?? 0) >= 2 ? status.uidNext! - 1 : nil
        if status.uidNext == nil {
            // 服务器不提供 UIDNEXT 时，用 `UID SEARCH ALL` 取真实 UID 上界。
            // 不能以「本批返回条数少于一批」推断扫描尽头：UID 稀疏（如 {1, 900}）时
            // 第一批只回一封就被判定结束，UID 900 会被永久跳过。
            highestUID = remoteUIDs.last
        }
        // 首次同步锚定到最近 UID 段：大账号从 UID 1 翻页会让首屏长时间空白，
        // 且企业服务器（如 Coremail）在早期大 UID 段上 SELECT/FETCH 极慢。
        // 已知取舍：**锚点以下的历史邮件本次不拉取**，首屏只覆盖最近一个窗口；
        // Subsequent syncs and the explicit history action backfill exact older UID batches.
        let isFirstSync = maxLocalUID == nil
        var cursor: UInt32
        if isFirstSync, let highestUID, highestUID > Self.initialSyncUIDWindow {
            cursor = highestUID - Self.initialSyncUIDWindow
        } else {
            cursor = maxLocalUID ?? 0
        }
        var fetched = 0
        while true {
            try Task.checkCancellation()
            if let highestUID, cursor >= highestUID { break }

            try await coordinator.yieldLease(space: space, accountId: folder.accountId)
            _ = try await prepare(accountId: folder.accountId)
            try await mail.requireFolderLocation(folder)
            let since: UInt32? = cursor == 0 ? nil : cursor
            let batch = try await withDeadline(
                timeoutBudget.fetchSummaries,
                label: "fetchSummaries",
                client: client
            ) {
                try await client.fetchSummaries(
                    path: folder.path,
                    sinceUID: since,
                    limit: self.batchSize
                )
            }

            if !batch.isEmpty {
                try Task.checkCancellation()
                try await mail.upsertMessages(
                    batch.map {
                        Self.message(from: $0, accountId: folder.accountId, folderId: folder.id)
                    }, expectedFolder: folder
                )
                fetched += batch.count
            }

            // 游标按 **窗口跨度** 前进（不是按本批最大 UID，也不是按返回条数）：
            // 窗口内一封都没有（UID 空洞）时同样前进，否则会原地打转或漏掉后面的 UID。
            let advanced = UInt64(cursor) + UInt64(batchSize)
            guard advanced <= UInt64(UInt32.max) else { break }
            let nextCursor = UInt32(advanced)
            if let highestUID {
                // 本窗口已覆盖到（或越过）上界：扫描完成
                if nextCursor >= highestUID { break }
                cursor = nextCursor
            } else {
                // 既无 UIDNEXT 又搜不到任何 UID（空文件夹）：没有可推进的目标，结束
                if maxLocalUID == nil && batch.isEmpty { break }
                cursor = nextCursor
                if batch.count < batchSize { break }
            }
        }

        // Backfill by actual UIDs, not numeric windows: sparse UID spaces must not
        // require thousands of empty requests to reach older messages.
        if !isFirstSync || historyBatches > 1 {
            let cached = try await mail.cachedServerUIDs(folderID: folder.id)
            let missing = remoteUIDs.filter { !cached.contains($0) }.suffix(batchSize * min(max(historyBatches, 1), 4))
            for start in stride(from: 0, to: missing.count, by: batchSize) {
                try Task.checkCancellation()
                try await coordinator.yieldLease(space: space, accountId: folder.accountId)
                _ = try await prepare(accountId: folder.accountId)
                try await mail.requireFolderLocation(folder)
                let ids = Array(missing.dropFirst(start).prefix(batchSize))
                let batch = try await withDeadline(timeoutBudget.fetchSummaries, label: "history", client: client) {
                    try await client.fetchSummaries(path: folder.path, uids: ids)
                }
                try await mail.upsertMessages(batch.filter { remoteSet.contains($0.uid) }.map { Self.message(from: $0, accountId: folder.accountId, folderId: folder.id) }, expectedFolder: folder)
                fetched += batch.count
            }
        }

        // A server omitting UIDVALIDITY cannot establish UID identity. Refresh the
        // cached identities so reused UIDs cannot retain an unrelated cached body.
        if status.uidValidity == nil {
            let ids = previouslyCached.intersection(remoteSet).sorted()
            for start in stride(from: 0, to: ids.count, by: batchSize) {
                try Task.checkCancellation()
                let chunk = Array(ids.dropFirst(start).prefix(batchSize))
                let batch = try await withDeadline(timeoutBudget.fetchSummaries, label: "identity", client: client) {
                    try await client.fetchSummaries(path: folder.path, uids: chunk)
                }
                try await mail.upsertMessages(batch.map { Self.message(from: $0, accountId: folder.accountId, folderId: folder.id) }, expectedFolder: folder)
            }
        }
        let changedSeen = try await flushPendingFlags(folder: folder, client: client)
        let seen = try await withDeadline(timeoutBudget.fetchSummaries, label: "seen", client: client) {
            try await client.searchUIDs(path: folder.path, flag: .seen)
        }
        let starred = try await withDeadline(timeoutBudget.fetchSummaries, label: "starred", client: client) {
            try await client.searchUIDs(path: folder.path, flag: .flagged)
        }
        try await mail.reconcile(folderID: folder.id, previouslyCached: previouslyCached, remote: remoteSet, seen: Set(seen), starred: Set(starred), expectedFolder: folder)

        try await mail.updateFolderSync(
            folderId: folder.id,
            uidValidity: status.uidValidity ?? folder.uidValidity,
            uidNext: status.uidNext,
            unread: changedSeen ? remoteSet.subtracting(seen).count : status.unreadCount,
            total: status.messageCount,
            expectedFolder: folder,
            remoteSeen: Set(seen)
        )
        return fetched
    }

    @discardableResult
    private func flushPendingFlags(folder: MailFolder, client: MailProtocolClient) async throws -> Bool {
        let changes = try await mail.pendingFlags(folderID: folder.id)
        for pending in changes {
            try Task.checkCancellation()
            try await mail.requireFolderLocation(folder)
            try await withDeadline(timeoutBudget.write, label: "storeFlags", client: client) {
                try await client.storeFlags(path: folder.path, uid: pending.uid, add: pending.add, remove: pending.remove)
            }
            try await mail.acknowledgeFlags(pending, expectedFolder: folder)
        }
        return changes.contains { $0.seen != nil }
    }

    /// 把 `RemoteMailFolder` 列表整理成带父子链的 `MailFolder` 集合：
    ///
    /// - 保留容器节点（`\Noselect`）作为层级展示；
    /// - 用 `delimiter` 从 path 反推 parentPath；
    /// - 若父节点不在远端列表里（例如父路径是 `.` 开头的特殊路径），按路径
    ///   递归合成虚拟父节点，保证树形展示不断链。
    static func buildHierarchy(accountId: UUID, from remoteFolders: [RemoteMailFolder]) -> [MailFolder] {
        var byPath: [String: MailFolder] = [:]
        for folder in remoteFolders {
            let parent = parentPath(of: folder.path, delimiter: folder.delimiter)
            byPath[folder.path] = MailFolder(
                accountId: accountId,
                path: folder.path,
                name: folder.name,
                role: folder.role,
                parentPath: parent,
                delimiter: folder.delimiter,
                isContainer: !folder.isSelectable
            )
        }

        // 补全缺失的中间父节点：按 delimiter 逐级向上截断，直到顶层
        for folder in remoteFolders where folder.delimiter != nil {
            var current = parentPath(of: folder.path, delimiter: folder.delimiter)
            while let parent = current, byPath[parent] == nil {
                let grandparent = parentPath(of: parent, delimiter: folder.delimiter)
                byPath[parent] = MailFolder(
                    accountId: accountId,
                    path: parent,
                    name: MailFoundationAdapter.sessionMailbox(from: lastComponent(parent, delimiter: folder.delimiter)),
                    role: .other,
                    parentPath: grandparent,
                    delimiter: folder.delimiter,
                    isContainer: true
                )
                current = grandparent
            }
        }

        return byPath.values.sorted { $0.path < $1.path }
    }

    private static func parentPath(of path: String, delimiter: String?) -> String? {
        guard let delimiter, !delimiter.isEmpty, path.contains(delimiter) else { return nil }
        return path.components(separatedBy: delimiter).dropLast().joined(separator: delimiter)
    }

    private static func lastComponent(_ path: String, delimiter: String?) -> String {
        guard let delimiter, !delimiter.isEmpty else { return path }
        return path.components(separatedBy: delimiter).last ?? path
    }

    /// 服务器摘要 → 本地邮件记录（正文与附件待按需拉取）。
    private static func message(
        from summary: RemoteMessageSummary,
        accountId: UUID,
        folderId: UUID
    ) -> MailMessage {
        let sender = summary.from.first
        return MailMessage(
            accountId: accountId,
            folderId: folderId,
            uid: summary.uid,
            messageId: summary.messageId,
            subject: summary.subject,
            fromName: sender?.name ?? "",
            fromAddress: sender?.address ?? "",
            replyTo: summary.replyTo,
            to: summary.to,
            cc: summary.cc,
            references: summary.references,
            date: summary.date,
            isRead: summary.isRead,
            isStarred: summary.isStarred,
            hasAttachments: false,
            sizeBytes: summary.sizeBytes,
            snippet: summary.snippet,
            bodyState: .none
        )
    }
}
