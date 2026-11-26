import Foundation
import GRDB

// MARK: - Mail Connection Probe

/// 连接测试结果（IMAP 已验证登录，SMTP 验证连通/TLS）。
public struct MailConnectionProbe: Sendable, Equatable {
    public let folderCount: Int
    public let smtpReachable: Bool

    public init(folderCount: Int, smtpReachable: Bool) {
        self.folderCount = folderCount
        self.smtpReachable = smtpReachable
    }
}

// MARK: - Mail Account Service

/// 邮箱账号服务：账号元数据入库（空间库），密码/授权码只进 Keychain。
/// 沿用 LLM Provider 的「元数据入库、密钥入 Keychain」模式；
/// Keychain account 名带空间前缀，确保双空间同 UUID 不撞键。
public final class MailAccountService: @unchecked Sendable {
    private let databaseQueue: DatabaseQueue
    /// 空间标识（personal / work），用于 Keychain 键隔离
    private let space: String

    public init(databaseQueue: DatabaseQueue, space: AppSpace) {
        self.databaseQueue = databaseQueue
        self.space = space.rawValue
    }

    // MARK: - CRUD

    /// 保存账号；`password` 非 nil 时先落 Keychain，失败则整体报错
    /// （避免库内出现「有账号、无凭据」的半可用状态）。
    public func save(_ account: MailAccount, password: String?) async throws {
        guard !account.isLocalArchive, try await self.account(id: account.id)?.isLocalArchive != true else { throw MailImportError.localOnly }
        try MailServerConfiguration.validate(account)
        if let password {
            try KeychainService.saveMailPassword(password, space: space, accountId: account.id)
        }
        try await databaseQueue.maintenanceWrite { db in
            var row = MailAccountRow(from: account)
            try row.save(db)
        }
        HubLogger.shared.info("Mail account saved: \(account.id.uuidString)")
    }

    public func getAll() async throws -> [MailAccount] {
        try await databaseQueue.read { db in
            try MailAccountRow
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .compactMap { $0.toAccount() }
        }
    }

    /// Resolve the sender for a synchronous confirmation snapshot. No credentials are read.
    func sendingAccount(forApproval rawID: String) throws -> MailAccount {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let account: MailAccount? = try databaseQueue.read { db in
            if id.isEmpty {
                return try MailAccountRow.order(Column("createdAt").asc, Column("id").asc)
                    .fetchAll(db).compactMap { $0.toAccount() }.first { !$0.isLocalArchive }
            }
            guard let uuid = UUID(uuidString: id) else { return nil }
            return try MailAccountRow.fetchOne(db, key: uuid.uuidString)?.toAccount()
        }
        guard let account, !account.isLocalArchive else {
            throw ToolExecutionFailure(message: "Choose a sending account in this space before requesting confirmation.")
        }
        return account
    }

    public func account(id: UUID) async throws -> MailAccount? {
        try await databaseQueue.read { db in
            try MailAccountRow.fetchOne(db, key: id.uuidString)?.toAccount()
        }
    }

    /// 删除账号：在单个事务内清空该账号的全部本地数据（文件夹、邮件含本地自产副本、
    /// 正文、附件与草稿），再从库中删账号并移除 Keychain 密码。
    /// Keychain 删除失败只告警不回滚（库内数据已清理）。
    public func delete(id: UUID) async throws {
        guard let appSpace = AppSpace(rawValue: space) else { throw CancellationError() }
        await MailAccountCoordinator.shared.invalidate(space: appSpace, accountId: id)
        try await MailAccountCoordinator.shared.withLease(space: appSpace, accountId: id, maintenanceKey: databaseQueue.maintenanceKey) {
            try await self.deleteUnderLease(id: id)
        }
    }

    private func deleteUnderLease(id: UUID) async throws {
        let local = try await account(id: id)?.isLocalArchive == true
        let mail = MailService(databaseQueue: databaseQueue)
        // 清数据 + 删账号行在**同一个写事务**内完成：分两步时第二步失败会留下空账号。
        // 用 purgeAccount 的合并入口（而非逐文件夹 clearMessages）：后者保留本地自产副本
        // （UID ≥ localUIDFloor 的「已发送」），账号删除后不得残留。
        try await mail.purgeAccountAndDeleteAccount(accountId: id)
        if local { return }
        do {
            try KeychainService.deleteMailPassword(space: space, accountId: id)
        } catch {
            HubLogger.shared.warning("Failed to remove mail password from Keychain: \(HubLogger.safeErrorSummary(error))")
        }
        HubLogger.shared.info("Mail account deleted: \(id.uuidString)")
    }

    public func password(for accountId: UUID) -> String? {
        KeychainService.loadMailPassword(space: space, accountId: accountId)
    }

    public func hasPassword(for accountId: UUID) -> Bool {
        !(password(for: accountId) ?? "").isEmpty
    }

    // MARK: - Connection Test

    /// 真实连接测试：IMAP 连接 + 登录（并列出文件夹验证会话可用），
    /// 随后探测 SMTP 连通性（EHLO，必要时 STARTTLS）。
    ///
    /// 各段都受超时预算约束：这是用户在配置页同步等待的操作，
    /// 不能按上游会话默认的 120 秒去等一个无响应的服务器。
    public func testConnection(
        account: MailAccount,
        password: String,
        timeoutBudget: MailTimeoutBudget = .default
    ) async -> Result<MailConnectionProbe, Error> {
        guard !account.isLocalArchive else { return .failure(MailImportError.localOnly) }
        do { try MailServerConfiguration.validate(account) }
        catch { return .failure(error) }
        var stage = MailConnectionTestError.Stage.imap
        let adapter = MailFoundationAdapter(
            host: account.imapHost,
            port: account.imapPort,
            security: account.imapSecurity
        )
        return await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await MailDeadline.openSession(
                    adapter,
                    username: account.username,
                    password: password,
                    budget: timeoutBudget
                )
                stage = .folders
                let folders = try await MailDeadline.call(
                    timeoutBudget.listFolders,
                    label: "listFolders",
                    client: adapter
                ) {
                    try await adapter.listFolders()
                }
                await adapter.disconnect()

                var smtpReachable = false
                if !account.smtpHost.isEmpty {
                    stage = .smtp
                    do {
                        try await MailFoundationAdapter.probeSMTP(
                            host: account.smtpHost,
                            port: account.smtpPort,
                            security: account.smtpSecurity,
                            timeoutMilliseconds: timeoutBudget.connect
                        )
                        smtpReachable = true
                    } catch {
                        // IMAP 已通过，SMTP 失败单独回报（收信可用、发信待修）
                        return .failure(MailConnectionTestError(stage: .smtp, underlying: error))
                    }
                }
                return .success(MailConnectionProbe(folderCount: folders.count, smtpReachable: smtpReachable))
            } catch {
                await adapter.disconnect()
                return .failure(MailConnectionTestError(stage: stage, underlying: error))
            }
        } onCancel: { Task { await adapter.disconnect() } }
    }
}
