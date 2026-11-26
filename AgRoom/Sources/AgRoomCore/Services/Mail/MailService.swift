import Foundation
import GRDB

// MARK: - Mail Service (Persistence)

/// 邮件本地持久化服务：绑定单一空间的 DatabaseQueue（空间隔离红线）。
/// **只做本地读写，不做任何网络**（网络在 `MailSyncService` / `MailProtocolClient`）。
///
/// 表结构与迁移：全部表由 `createSchema` 建立，由 `DatabaseBootstrap.prepareSpace`
/// 注册为命名迁移 `v1_mail`；写法对齐 `SessionService.createSchema`。
public final class MailService: @unchecked Sendable {
    let databaseQueue: DatabaseQueue
    /// 正文写入的注入式故障（仅测试用）：非空时 `saveBody` 抛出该错误。
    ///
    /// 存在的理由：「发信已投递但本地副本落库失败」这条路径必须在测试里真实复现，
    /// 否则只能靠人工推断——而它恰恰是「不能报成发送失败」的关键分支。
    var bodyWriteFailureForTesting: Error?

    /// 设置/清除正文写入故障（测试入口，语义见 `bodyWriteFailureForTesting`）。
    public func setBodyWriteFailureForTesting(_ error: Error?) {
        bodyWriteFailureForTesting = error
    }

    /// 本地自产邮件的保留 UID 区间下界。
    ///
    /// 发信成功后的「已发送」副本只在本地落库；草稿专用 APPEND 不用于发送副本。
    /// 服务器 UID 从 1 递增分配，实际不可能逼近该量级，
    /// 因此以该下界划分「服务器 UID / 本地 UID」两段互不干扰的空间：
    /// 本地 UID 不参与增量同步游标（见 `maxUID`），也不会被 UIDVALIDITY 重建清掉。
    public static let localUIDFloor: UInt32 = 4_000_000_000

    /// 正文缓存（`mail_bodies`）总字节上限：超过后按最久未取淘汰。
    ///
    /// 正文是**可重建**数据（需要时按需重新下载），因此不需要无损保留；若不设上限，
    /// 长期浏览大量 HTML 邮件会让库无界增长。淘汰只把对应邮件的 `bodyState` 置回
    /// `.none`，界面据此重新显示「未下载」并允许再次拉取。
    public static let bodyCacheByteLimit = 64 * 1024 * 1024

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    /// 建表 + 建索引（幂等：`ifNotExists`）。由 `DatabaseBootstrap` 集中调用。
    /// 密码/授权码**不在此落库**，只存 Keychain。
    static func createSchema(_ database: Database) throws {
        // 账号元数据（无密码列）
        try database.create(table: "mail_accounts", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("displayName", .text).notNull().defaults(to: "")
            t.column("emailAddress", .text).notNull().defaults(to: "")
            t.column("imapHost", .text).notNull().defaults(to: "")
            t.column("imapPort", .integer).notNull().defaults(to: 993)
            t.column("imapSecurity", .text).notNull().defaults(to: MailSecurity.tls.rawValue)
            t.column("smtpHost", .text).notNull().defaults(to: "")
            t.column("smtpPort", .integer).notNull().defaults(to: 587)
            t.column("smtpSecurity", .text).notNull().defaults(to: MailSecurity.startTLS.rawValue)
            t.column("username", .text).notNull().defaults(to: "")
            t.column("authKind", .text).notNull().defaults(to: MailAuthKind.password.rawValue)
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("sourceKind", .text).notNull().defaults(to: MailAccountSource.imap.rawValue)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        // 文件夹
        try database.create(table: "mail_folders", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("accountId", .text).notNull()
            t.column("path", .text).notNull()
            t.column("name", .text).notNull().defaults(to: "")
            t.column("role", .text).notNull().defaults(to: MailFolderRole.other.rawValue)
            // 层级信息：parentPath 存服务器全路径（path 最后一段是展示名）
            t.column("parentPath", .text)
            t.column("delimiter", .text)
            // \Noselect 容器：只作分组节点，不可 SELECT/FETCH
            t.column("isContainer", .boolean).notNull().defaults(to: false)
            t.column("uidValidity", .integer)
            t.column("uidNext", .integer)
            t.column("lastSyncAt", .datetime)
            t.column("unreadCount", .integer).notNull().defaults(to: 0)
            t.column("totalCount", .integer).notNull().defaults(to: 0)
        }
        try database.create(
            index: "idx_mail_folders_account_path",
            on: "mail_folders",
            columns: ["accountId", "path"],
            options: [.unique, .ifNotExists]
        )

        // 邮件元数据
        try database.create(table: "mail_messages", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("accountId", .text).notNull()
            t.column("folderId", .text).notNull()
            t.column("uid", .integer).notNull()
            t.column("messageId", .text)
            t.column("subject", .text).notNull().defaults(to: "")
            t.column("fromName", .text).notNull().defaults(to: "")
            t.column("fromAddress", .text).notNull().defaults(to: "")
            t.column("replyToJSON", .text).notNull().defaults(to: "[]")
            t.column("toJSON", .text).notNull().defaults(to: "[]")
            t.column("ccJSON", .text).notNull().defaults(to: "[]")
            t.column("references", .text)
            t.column("date", .datetime)
            t.column("isRead", .boolean).notNull().defaults(to: false)
            t.column("isStarred", .boolean).notNull().defaults(to: false)
            t.column("hasAttachments", .boolean).notNull().defaults(to: false)
            t.column("sizeBytes", .integer).notNull().defaults(to: 0)
            t.column("snippet", .text).notNull().defaults(to: "")
            t.column("bodyState", .text).notNull().defaults(to: MailBodyState.none.rawValue)
        }
        try database.create(
            index: "idx_mail_messages_folder_uid",
            on: "mail_messages",
            columns: ["folderId", "uid"],
            options: [.unique, .ifNotExists]
        )
        try database.create(
            index: "idx_mail_messages_folder_date",
            on: "mail_messages",
            columns: ["folderId", "date"],
            options: .ifNotExists
        )
        // Message-ID 去重查询（upsertMessages 的移动后归并）与同文件夹去重都按
        // (folderId, messageId) 命中：缺索引会退化成整文件夹扫描。
        // 注意 Message-ID 可能缺失或重复，此处只提供检索加速，不设唯一约束
        try database.create(
            index: "idx_mail_messages_folder_message_id",
            on: "mail_messages",
            columns: ["folderId", "messageId"],
            options: .ifNotExists
        )
        try database.create(
            index: "idx_mail_messages_account_starred",
            on: "mail_messages",
            columns: ["accountId", "isStarred"],
            options: .ifNotExists
        )

        // 正文（与元数据分表，按需拉取）
        try database.create(table: "mail_bodies", ifNotExists: true) { t in
            t.column("messageId", .text).primaryKey()
            t.column("textBody", .text)
            t.column("htmlBody", .text)
            t.column("rawHeaders", .text)
            t.column("searchText", .text)
            t.column("fetchedAt", .datetime).notNull()
        }

        // 附件元数据
        try database.create(table: "mail_attachments", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("messageId", .text).notNull()
            t.column("filename", .text).notNull().defaults(to: "")
            t.column("mimeType", .text).notNull().defaults(to: "application/octet-stream")
            t.column("sizeBytes", .integer).notNull().defaults(to: 0)
            t.column("contentId", .text)
            t.column("localPath", .text)
            t.column("partID", .text)
            t.column("isInline", .boolean).notNull().defaults(to: false)
        }
        try database.create(
            index: "idx_mail_attachments_message",
            on: "mail_attachments",
            columns: ["messageId"],
            options: .ifNotExists
        )

        // 本地草稿
        try database.create(table: "mail_drafts", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("accountId", .text).notNull()
            t.column("toJSON", .text).notNull().defaults(to: "[]")
            t.column("ccJSON", .text).notNull().defaults(to: "[]")
            t.column("bccJSON", .text).notNull().defaults(to: "[]")
            t.column("subject", .text).notNull().defaults(to: "")
            t.column("bodyText", .text).notNull().defaults(to: "")
            t.column("quotedText", .text).notNull().defaults(to: "")
            t.column("composeKind", .text).notNull().defaults(to: MailComposeKind.new.rawValue)
            t.column("sourceMessageId", .text)
            t.column("inReplyTo", .text)
            t.column("references", .text)
            t.column("updatedAt", .datetime).notNull()
            // 投递凭证：非空表示这封邮件已经投递出去（见 addDraftDeliveryColumns）
            t.column("deliveredAt", .datetime)
            t.column("deliveredMessageId", .text)
            // 投递状态机与稳定 Message-ID（见 addDraftDeliveryColumns）
            t.column("deliveryState", .text)
            t.column("pendingMessageId", .text)
            t.column("attachmentsData", .blob)
            t.column("forwardAttachmentsState", .text)
            t.column("bodyStylesData", .blob)
        }
        try database.create(
            index: "idx_mail_drafts_account",
            on: "mail_drafts",
            columns: ["accountId", "updatedAt"],
            options: .ifNotExists
        )
        try createCoverageSchema(database)
        try createRawSchema(database)
        try createServerDraftSchema(database)
        try createAgentDraftReceiptSchema(database)
    }

    static func createAgentDraftReceiptSchema(_ db: Database) throws {
        try db.create(table: "mail_agent_draft_receipts", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("accountId", .text).notNull().references("mail_accounts", column: "id", onDelete: .cascade)
        }
    }

    /// 草稿表的投递凭证列（v1 建表后新增，故独立迁移）。
    ///
    /// `deliveredAt` 非空表示这封邮件**已经投递出去**：本地记录失败时它是唯一凭证，
    /// 界面据此禁止重发（见 `MailDeliveredLocalSaveError`）。
    public static func addDraftDeliveryColumns(_ db: Database) throws {
        if try !db.columns(in: "mail_drafts").contains(where: { $0.name == "deliveredAt" }) {
            try db.alter(table: "mail_drafts") { t in
                t.add(column: "deliveredAt", .datetime)
            }
        }
        if try !db.columns(in: "mail_drafts").contains(where: { $0.name == "deliveredMessageId" }) {
            try db.alter(table: "mail_drafts") { t in
                t.add(column: "deliveredMessageId", .text)
            }
        }
        // 投递状态机与稳定 Message-ID：进入可能投递的阶段前落盘，
        // 重开 / 重启后据此禁止普通重发（见 MailDeliveryState）
        if try !db.columns(in: "mail_drafts").contains(where: { $0.name == "deliveryState" }) {
            try db.alter(table: "mail_drafts") { t in
                t.add(column: "deliveryState", .text)
            }
        }
        if try !db.columns(in: "mail_drafts").contains(where: { $0.name == "pendingMessageId" }) {
            try db.alter(table: "mail_drafts") { t in
                t.add(column: "pendingMessageId", .text)
            }
        }
    }

    /// 邮件表的回复上下文列（v1 建表后新增，旧库按缺失列幂等补列）。
    ///
    /// `replyToJSON` 来自 ENVELOPE 的 `Reply-To`；`references` 来自正文拉取时解析的
    /// `References` 头。两者共同支撑「回复优先走 Reply-To、线程链保留 References」。
    public static func addReplyContextColumns(_ db: Database) throws {
        if try !db.columns(in: "mail_messages").contains(where: { $0.name == "replyToJSON" }) {
            try db.alter(table: "mail_messages") { t in
                t.add(column: "replyToJSON", .text).notNull().defaults(to: "[]")
            }
        }
        if try !db.columns(in: "mail_messages").contains(where: { $0.name == "references" }) {
            try db.alter(table: "mail_messages") { t in
                t.add(column: "references", .text)
            }
        }
    }

    /// 草稿表的来源与引用列（v1 建表后新增，旧库按缺失列幂等补列）。
    ///
    /// `composeKind` / `sourceMessageId` 固定撰写类型与原邮件身份；
    /// `quotedText` 把「原文引用」与「回复正文」分开保存，旧草稿缺列时为空串，
    /// 按「整段已有正文」处理（不猜测引用边界）。
    public static func addDraftSourceColumns(_ db: Database) throws {
        if try !db.columns(in: "mail_drafts").contains(where: { $0.name == "quotedText" }) {
            try db.alter(table: "mail_drafts") { t in
                t.add(column: "quotedText", .text).notNull().defaults(to: "")
            }
        }
        if try !db.columns(in: "mail_drafts").contains(where: { $0.name == "composeKind" }) {
            try db.alter(table: "mail_drafts") { t in
                t.add(column: "composeKind", .text).notNull().defaults(to: MailComposeKind.new.rawValue)
            }
        }
        if try !db.columns(in: "mail_drafts").contains(where: { $0.name == "sourceMessageId" }) {
            try db.alter(table: "mail_drafts") { t in
                t.add(column: "sourceMessageId", .text)
            }
        }
    }

    /// 文件夹表的层级列（v1 建表后新增，旧库按缺失列幂等补列）。
    /// 以 isContainer=true 保留，参与层级展示但不进 SELECT/FETCH 同步循环。
    public static func addFolderHierarchyColumns(_ db: Database) throws {
        if try !db.columns(in: "mail_folders").contains(where: { $0.name == "parentPath" }) {
            try db.alter(table: "mail_folders") { t in
                t.add(column: "parentPath", .text)
            }
        }
        if try !db.columns(in: "mail_folders").contains(where: { $0.name == "delimiter" }) {
            try db.alter(table: "mail_folders") { t in
                t.add(column: "delimiter", .text)
            }
        }
        if try !db.columns(in: "mail_folders").contains(where: { $0.name == "isContainer" }) {
            try db.alter(table: "mail_folders") { t in
                t.add(column: "isContainer", .boolean).notNull().defaults(to: false)
            }
        }
    }

    // MARK: - Folders

    /// Persistent deletion tombstones reject late writes from other processes as well.
    static func addIntegrityGuards(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS mail_deleted_accounts (accountId TEXT PRIMARY KEY NOT NULL)")
        for table in ["mail_folders", "mail_messages", "mail_drafts"] {
            for event in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS guard_\(table)_\(event) BEFORE \(event) ON \(table)
                    WHEN EXISTS(SELECT 1 FROM mail_deleted_accounts WHERE accountId=NEW.accountId)
                    BEGIN SELECT RAISE(ABORT, 'mail account removed'); END
                    """)
            }
        }
        for table in ["mail_bodies", "mail_attachments"] {
            for event in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS guard_\(table)_\(event) BEFORE \(event) ON \(table)
                    WHEN NOT EXISTS(SELECT 1 FROM mail_messages WHERE id=NEW.messageId)
                    BEGIN SELECT RAISE(ABORT, 'mail message removed'); END
                    """)
            }
        }
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS cascade_mail_account AFTER DELETE ON mail_accounts BEGIN
                INSERT OR IGNORE INTO mail_deleted_accounts VALUES(OLD.id);
                DELETE FROM mail_messages WHERE accountId=OLD.id;
                DELETE FROM mail_folders WHERE accountId=OLD.id;
                DELETE FROM mail_drafts WHERE accountId=OLD.id;
            END;
            CREATE TRIGGER IF NOT EXISTS cascade_mail_message AFTER DELETE ON mail_messages BEGIN
                DELETE FROM mail_bodies WHERE messageId=OLD.id;
                DELETE FROM mail_attachments WHERE messageId=OLD.id;
            END;
            CREATE TRIGGER IF NOT EXISTS cascade_mail_folder AFTER DELETE ON mail_folders BEGIN
                DELETE FROM mail_messages WHERE folderId=OLD.id;
            END;
            CREATE TRIGGER IF NOT EXISTS restore_mail_account AFTER INSERT ON mail_accounts BEGIN
                DELETE FROM mail_deleted_accounts WHERE accountId=NEW.id;
            END;
            """)
    }

    /// 批量写入文件夹（按 `(accountId, path)` 唯一键 upsert，保留既有 id/sync 状态）。
    public func upsertFolders(_ folders: [MailFolder]) async throws {
        try await databaseQueue.maintenanceWrite { db in
            for accountID in Set(folders.map(\.accountId)) { try Self.requireNoPendingFolderMutation(accountID, db: db) }
            for folder in folders {
                if var existing = try MailFolderRow
                    .filter(Column("accountId") == folder.accountId.uuidString)
                    .filter(Column("path") == folder.path)
                    .fetchOne(db) {
                    // 保留既有 id 与同步游标，仅刷新展示信息与角色/层级
                    existing.name = folder.name
                    existing.role = folder.role.rawValue
                    existing.parentPath = folder.parentPath
                    existing.delimiter = folder.delimiter
                    existing.isContainer = folder.isContainer
                    try existing.update(db)
                } else {
                    var row = MailFolderRow(from: folder)
                    try row.insert(db)
                }
            }
        }
    }

    public func folders(accountId: UUID) async throws -> [MailFolder] {
        try await databaseQueue.read { db in
            let local = try MailAccountRow.fetchOne(db, key: accountId.uuidString)?.sourceKind == MailAccountSource.localArchive.rawValue
            return try MailFolderRow
                .filter(Column("accountId") == accountId.uuidString)
                .order(Column("path").asc)
                .fetchAll(db)
                .compactMap { row in
                    guard var folder = row.toFolder() else { return nil }
                    if local {
                        folder.totalCount = try MailMessageRow.filter(Column("folderId") == row.id).fetchCount(db)
                        folder.unreadCount = try MailMessageRow.filter(Column("folderId") == row.id).filter(Column("isRead") == false).fetchCount(db)
                    }
                    return folder
                }
        }
    }

    /// 删除该账号下不在 `keeping` 中的文件夹（含其邮件与正文/附件）。
    public func deleteFolders(accountId: UUID, keeping paths: [String]) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try Self.requireNoPendingFolderMutation(accountId, db: db)
            guard try MailAccountRow.fetchOne(db, key: accountId.uuidString)?.sourceKind != MailAccountSource.localArchive.rawValue else {
                throw MailImportError.localOnly
            }
            let rows = try MailFolderRow
                .filter(Column("accountId") == accountId.uuidString)
                .fetchAll(db)
            for row in rows where !paths.contains(row.path) {
                try Self.deleteFolderContents(folderId: row.id, in: db)
                _ = try MailFolderRow.filter(Column("id") == row.id).deleteAll(db)
            }
        }
    }

    /// 更新文件夹同步游标与计数。
    public func updateFolderSync(
        folderId: UUID,
        uidValidity: UInt32?,
        uidNext: UInt32?,
        unread: Int,
        total: Int,
        at date: Date = Date(),
        expectedFolder: MailFolder? = nil,
        remoteSeen: Set<UInt32>? = nil
    ) async throws {
        try await databaseQueue.maintenanceWrite { db in
            if let expectedFolder {
                guard expectedFolder.id == folderId else { throw MailFolderMutationError.changed }
                try Self.requireFolderLocation(expectedFolder, db: db)
            }
            guard var row = try MailFolderRow.fetchOne(db, key: folderId.uuidString) else { return }
            row.uidValidity = uidValidity.map { Int64($0) }
            row.uidNext = uidNext.map { Int64($0) }
            row.unreadCount = unread
            if let remoteSeen {
                // Account sync can be in flight when the reader opens a message.
                let pending = try Row.fetchAll(db, sql: "SELECT m.uid, p.seen FROM mail_pending_flags p JOIN mail_messages m ON m.id = p.messageID WHERE m.folderId = ? AND p.seen IS NOT NULL", arguments: [row.id])
                for change in pending {
                    let seen: Bool = change["seen"]
                    if let uid = UInt32(exactly: change["uid"] as Int64), seen != remoteSeen.contains(uid) {
                        row.unreadCount += seen ? -1 : 1
                    }
                }
                row.unreadCount = max(0, row.unreadCount)
            }
            row.totalCount = total
            row.lastSyncAt = date
            try row.update(db)
        }
    }

    // MARK: - Messages

    /// 批量写入邮件元数据（按 `(folderId, uid)` 唯一键 upsert，保留本地已读/星标状态）。
    public func upsertMessages(_ messages: [MailMessage], expectedFolder: MailFolder? = nil) async throws {
        try await databaseQueue.maintenanceWrite { db in
            if let expectedFolder {
                guard messages.allSatisfy({ $0.folderId == expectedFolder.id && $0.accountId == expectedFolder.accountId }) else { throw MailFolderMutationError.changed }
                try Self.requireFolderLocation(expectedFolder, db: db)
            }
            // Folders are independent. Preserve input order inside each folder, including repeated UIDs in a batch.
            for (folderID, envelopes) in Dictionary(grouping: messages, by: \.folderId) {
                for start in stride(from: 0, to: envelopes.count, by: 100) {
                    try Task.checkCancellation()
                    let batch = envelopes[start..<min(start + 100, envelopes.count)]
                    try Self.upsertBatch(batch, folderID: folderID, in: db)
                }
            }
        }
    }

    private static func upsertBatch(_ messages: ArraySlice<MailMessage>, folderID: UUID, in db: Database) throws {
        let uids = Set(messages.map { Int64($0.uid) })
        let folder = MailMessageRow.filter(Column("folderId") == folderID.uuidString)
        var rows = try folder.filter(uids.contains(Column("uid"))).fetchAll(db)
        if rows.count < uids.count {
            // A move can free another incoming UID. Prefetch its possible fallback in the same indexed lookup.
            let messageIDs = Set(messages.compactMap(\.messageId).filter { !$0.isEmpty })
            if !messageIDs.isEmpty {
                let moved = try folder.filter(messageIDs.contains(Column("messageId"))).fetchAll(db)
                rows += moved.filter { !uids.contains($0.uid) }
            }
        }
        var byUID = Dictionary(uniqueKeysWithValues: rows.map { ($0.uid, $0) })
        var uidsByID: [String: Set<Int64>] = [:]
        for row in rows { if let id = row.messageId { uidsByID[id, default: []].insert(row.uid) } }

        for message in messages {
            try Task.checkCancellation()
            let uid = Int64(message.uid)
            var existing = byUID[uid]
            if let row = existing, let previous = row.messageId, let incoming = message.messageId, previous != incoming {
                if let id = UUID(uuidString: row.id) { try deleteMessageContents(messageId: id, in: db) }
                _ = try row.delete(db)
                uidsByID[previous]?.remove(uid)
                existing = nil
            } else if existing == nil, let id = message.messageId, !id.isEmpty,
                      let oldUID = uidsByID[id]?.min() {
                existing = byUID.removeValue(forKey: oldUID)
                uidsByID[id]?.remove(oldUID)
            }
            var row: MailMessageRow
            if var current = existing {
                current.uid = uid
                current.messageId = message.messageId ?? current.messageId
                current.subject = message.subject
                current.fromName = message.fromName
                current.fromAddress = message.fromAddress
                current.replyToJSON = MailMessageRow.encodeAddresses(message.replyTo)
                current.toJSON = MailMessageRow.encodeAddresses(message.to)
                current.ccJSON = MailMessageRow.encodeAddresses(message.cc)
                if let references = message.references { current.references = mergeKnownReferences(current.references, references) }
                current.date = message.date
                current.hasAttachments = message.hasAttachments
                current.sizeBytes = message.sizeBytes
                if !message.snippet.isEmpty { current.snippet = message.snippet }
                try current.update(db)
                row = current
            } else {
                row = MailMessageRow(from: message)
                try row.insert(db)
            }
            byUID[uid] = row
            if let id = row.messageId { uidsByID[id, default: []].insert(uid) }
        }
    }

    public func messages(folderId: UUID, limit: Int = 200, offset: Int = 0) async throws -> [MailMessage] {
        try await databaseQueue.read { db in
            try MailMessageRow
                .filter(Column("folderId") == folderId.uuidString)
                .order(Column("date").desc, Column("uid").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
                .compactMap { $0.toMessage() }
        }
    }

    /// 列表分页位置：按 `(date DESC, uid DESC, id DESC)` 稳定排序。
    /// UID 仅在文件夹内唯一，跨文件夹必须携带本地 ID 处理同日期、同 UID 的并列项。
    ///
    /// 用游标而非 `offset`：同步会在用户翻页时插入/删除邮件，`offset` 会漏读或重复读，
    /// 游标锚定在「上一页最后一条」上，插入怎么变都不会让已展示的条目位移。
    public struct MailPageCursor: Sendable, Equatable {
        /// 上一条的日期；`nil` 表示已进入「无日期」区间（排序末尾）。
        public let date: Date?
        /// 上一条的 UID（同日期内的次序锚点）。
        public let uid: UInt32
        public let id: UUID?
        public let order: MailListOrder
        public let sortValue: String?

        public init(date: Date?, uid: UInt32, id: UUID? = nil, order: MailListOrder = .newest, sortValue: String? = nil) {
            self.date = date
            self.uid = uid
            self.id = id
            self.order = order; self.sortValue = sortValue
        }
    }

    public struct MailMessagePage: Sendable {
        public let messages: [MailMessage]
        public let cursor: MailPageCursor?
    }

    /// 游标分页：取严格排在 `cursor` 之后的一页（`cursor` 为 nil 表示从最新开始）。
    ///
    /// 无日期条目排在末尾；同日期按 UID、本地 ID 继续。旧版单文件夹游标可省略 ID。
    public func messages(
        folderId: UUID,
        before cursor: MailPageCursor?,
        limit: Int = 200,
        matching filter: MailListFilter = .init()
    ) async throws -> [MailMessage] {
        try await messages(in: .folder(folderId), before: cursor, limit: limit, matching: filter)
    }

    public func messages(in location: MailQueryLocation, before cursor: MailPageCursor?, limit: Int = 200,
                         matching filter: MailListFilter = .init(), order: MailListOrder = .newest) async throws -> [MailMessage] {
        try await messagePage(in: location, before: cursor, limit: limit, matching: filter, order: order).messages
    }

    public func messagePage(in location: MailQueryLocation, before cursor: MailPageCursor?, limit: Int = 200,
                            matching filter: MailListFilter = .init(), order: MailListOrder = .newest) async throws -> MailMessagePage {
        try Self.validateSearchFilter(filter)
        return try await databaseQueue.read { db in
            var request = Self.listRequest(location: location, filter: filter)
            let ascending = order == .oldest
            let comparison = ascending ? ">" : "<"
            let textExpression: String?
            switch order {
            case .sender: textExpression = "COALESCE(NULLIF(fromName,''),fromAddress,'')"
            case .subject: textExpression = "COALESCE(subject,'')"
            default: textExpression = nil
            }
            if let cursor {
                guard cursor.order == order else { throw MailSearchError.invalidFilter }
                if (location.scope != .folder || textExpression != nil), cursor.id == nil { throw MailSearchError.invalidFilter }
                let tie = cursor.id.map { _ in "(uid \(comparison) ? OR (uid = ? AND id \(comparison) ?))" } ?? "uid \(comparison) ?"
                var values: [DatabaseValueConvertible?] = [Int64(cursor.uid)]
                if let id = cursor.id { values += [Int64(cursor.uid), id.uuidString] }
                let datePredicate: String
                if let date = cursor.date {
                    datePredicate = "(date \(comparison) ? OR (date = ? AND \(tie)) OR date IS NULL)"
                    values = [date, date] + values
                } else { datePredicate = "(date IS NULL AND \(tie))" }
                if let expression = textExpression {
                    guard let value = cursor.sortValue else { throw MailSearchError.invalidFilter }
                    request = request.filter(sql: "(\(expression) COLLATE NOCASE > ? COLLATE NOCASE OR (\(expression) COLLATE NOCASE = ? COLLATE NOCASE AND \(datePredicate)))",
                        arguments: StatementArguments([value, value] + values))
                } else { request = request.filter(sql: datePredicate, arguments: StatementArguments(values)) }
            }
            let ordering: String
            if let expression = textExpression { ordering = expression + " COLLATE NOCASE ASC, date DESC, uid DESC, id DESC" }
            else if ascending { ordering = "date IS NULL ASC, date ASC, uid ASC, id ASC" }
            else { ordering = "date DESC, uid DESC, id DESC" }
            // Keep the raw SQL key; UI header decoding must not alter an anchor.
            let rows = try request.order(sql: ordering).limit(max(limit, 1)).fetchAll(db)
            let messages = rows.compactMap { $0.toMessage() }
            let cursor: MailPageCursor?
            if let last = rows.last, let message = last.toMessage() {
                let value: String?
                switch order {
                case .sender: value = last.fromName.isEmpty ? last.fromAddress : last.fromName
                case .subject: value = last.subject
                default: value = nil
                }
                cursor = .init(date: message.date, uid: message.uid, id: message.id, order: order, sortValue: value)
            } else { cursor = nil }
            return .init(messages: messages, cursor: cursor)
        }
    }

    /// 全部标为已读等文件夹动作先冻结目标，不能仅处理已加载的一页。
    public func messageCount(in location: MailQueryLocation, matching filter: MailListFilter = .init()) async throws -> Int {
        try Self.validateSearchFilter(filter)
        return try await databaseQueue.read { db in try Self.listRequest(location: location, filter: filter).fetchCount(db) }
    }

    public func messageIDs(folderId: UUID, includingDescendants: Bool = false, matching filter: MailListFilter = .init()) async throws -> [UUID] {
        if !includingDescendants { return try await messageIDs(in: .folder(folderId), matching: filter) }
        try Self.validateSearchFilter(filter)
        return try await databaseQueue.read { db in
            guard let root = try MailFolderRow.fetchOne(db, key: folderId.uuidString)?.toFolder() else { throw MailExportError.changed }
            let folders = try MailFolderRow.filter(Column("accountId") == root.accountId.uuidString).fetchAll(db).compactMap { $0.toFolder() }
            let children = Dictionary(grouping: folders.filter { $0.parentPath != nil }, by: { Data($0.parentPath!.utf8) })
            var pending = [root], selected = Set<UUID>(), paths = Set<Data>()
            while let next = pending.popLast() {
                try Task.checkCancellation()
                guard selected.insert(next.id).inserted, paths.insert(Data(next.path.utf8)).inserted,
                      selected.count <= 10_000 else { throw MailExportError.changed }
                pending.append(contentsOf: children[Data(next.path.utf8)] ?? [])
            }
            return try String.fetchAll(db, Self.listRequest(location: .account(root.accountId), filter: filter)
                .filter(selected.map(\.uuidString).contains(Column("folderId")))
                .select(Column("id")).order(Column("date").desc, Column("uid").desc, Column("id").desc)).compactMap(UUID.init(uuidString:))
        }
    }

    /// Freeze every locally matching ID before export, independently of loaded list pages.
    public func messageIDs(in location: MailQueryLocation, matching filter: MailListFilter = .init()) async throws -> [UUID] {
        try Self.validateSearchFilter(filter)
        return try await databaseQueue.read { db in
            try String.fetchAll(db, Self.listRequest(location: location, filter: filter)
                .select(Column("id")).order(Column("date").desc, Column("uid").desc, Column("id").desc))
                .compactMap(UUID.init(uuidString:))
        }
    }

    private static func listRequest(location: MailQueryLocation, filter: MailListFilter) -> QueryInterfaceRequest<MailMessageRow> {
        var request = MailMessageRow.all()
        switch location {
        case .folder(let id): request = request.filter(Column("folderId") == id.uuidString)
        case .account(let id): request = request.filter(Column("accountId") == id.uuidString)
        case .importBatch(let archiveID, let batchID):
            request = request.filter(Column("accountId") == archiveID.uuidString).filter(sql: "EXISTS(SELECT 1 FROM mail_import_origins o WHERE o.messageID=mail_messages.id AND o.accountID=? AND o.batchID=?)", arguments: [archiveID.uuidString, batchID.uuidString])
        case .inbox: request = request.filter(sql: "EXISTS(SELECT 1 FROM mail_folders f WHERE f.id=mail_messages.folderId AND f.accountId=mail_messages.accountId AND f.role=?)", arguments: [MailFolderRole.inbox.rawValue])
        case .space: break
        }
        if !filter.query.isEmpty {
            let pattern = "%\(SQLikeEscaping.escape(filter.query))%"
            var clause = "(subject LIKE ? ESCAPE '\\' OR fromName LIKE ? ESCAPE '\\' OR fromAddress LIKE ? ESCAPE '\\' OR snippet LIKE ? ESCAPE '\\'"
            var arguments = [pattern, pattern, pattern, pattern]
            if filter.includeBody {
                clause += " OR EXISTS(SELECT 1 FROM mail_bodies b WHERE b.messageId=mail_messages.id AND (b.textBody LIKE ? ESCAPE '\\' OR b.searchText LIKE ? ESCAPE '\\'))"
                arguments += [pattern, pattern]
            }
            request = request.filter(sql: clause + ")", arguments: StatementArguments(arguments))
        }
        if !filter.sender.isEmpty {
            request = request.filter(sql: "fromAddress LIKE ? ESCAPE '\\'", arguments: ["%\(SQLikeEscaping.escape(filter.sender))%"])
        }
        if !filter.recipient.isEmpty {
            let value = "%" + SQLikeEscaping.escape(filter.recipient) + "%"
            let clauses = ["toJSON", "ccJSON"].map { column in
                let object = "CASE WHEN r.type='object' THEN r.value ELSE '{}' END"
                return "EXISTS(SELECT 1 FROM json_each(CASE WHEN json_valid(\(column)) THEN \(column) ELSE '[]' END) r WHERE json_extract(\(object),'$.address') LIKE ? ESCAPE '\\' OR json_extract(\(object),'$.name') LIKE ? ESCAPE '\\')"
            }
            request = request.filter(sql: "(" + clauses.joined(separator: " OR ") + ")", arguments: [value, value, value, value])
        }
        if !filter.attachmentName.isEmpty {
            request = request.filter(sql: "EXISTS(SELECT 1 FROM mail_attachments a WHERE a.messageId=mail_messages.id AND a.filename LIKE ? ESCAPE '\\')", arguments: ["%" + SQLikeEscaping.escape(filter.attachmentName) + "%"])
        }
        if let minimum = filter.minBytes { request = request.filter(Column("sizeBytes") >= minimum) }
        if let maximum = filter.maxBytes { request = request.filter(Column("sizeBytes") > 0 && Column("sizeBytes") <= maximum) }
        if filter.unreadOnly { request = request.filter(Column("isRead") == false) }
        if filter.starredOnly { request = request.filter(Column("isStarred") == true) }
        if filter.attachmentsOnly { request = request.filter(Column("hasAttachments") == true) }
        if let after = filter.after { request = request.filter(Column("date") >= after) }
        if let before = filter.before { request = request.filter(Column("date") < before) }
        return request
    }

    public func message(id: UUID) async throws -> MailMessage? {
        try await databaseQueue.read { db in
            try MailMessageRow.fetchOne(db, key: id.uuidString)?.toMessage()
        }
    }

    /// 关键词检索本地邮件（主题 / 发件人名称 / 发件人地址 / 摘要），按日期倒序。
    /// 只覆盖已同步到本地的邮件；供智体 `mail_search` 使用。
    public func searchMessages(
        accountId: UUID,
        query: String,
        limit: Int = 20
    ) async throws -> [MailMessage] {
        // 字面转义 `\` `%` `_`：否则查询里的通配符会扩大命中范围（搜 "50%" 命中一切）
        let pattern = "%\(SQLikeEscaping.escape(query))%"
        return try await databaseQueue.read { db in
            try MailMessageRow
                .filter(Column("accountId") == accountId.uuidString)
                .filter(
                    sql: "(subject LIKE ? ESCAPE '\\' OR fromName LIKE ? ESCAPE '\\' "
                        + "OR fromAddress LIKE ? ESCAPE '\\' OR snippet LIKE ? ESCAPE '\\')",
                    arguments: [pattern, pattern, pattern, pattern]
                )
                .order(Column("date").desc, Column("uid").desc)
                .limit(limit)
                .fetchAll(db)
                .compactMap { $0.toMessage() }
        }
    }

    /// 写入正文时解析出的 `References` 线程链（回复时保留既有链）。
    public func setReferences(messageId: UUID, references: String?) async throws {
        guard let references, !references.isEmpty else { return }
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try MailMessageRow.fetchOne(db, key: messageId.uuidString) else { return }
            row.references = references
            try row.update(db)
        }
    }

    /// 按线程头查找同一账号内的关联邮件（限制封数，供 AI「包含相关往来」使用）。
    ///
    /// 已迁移空间使用精确线程头的传递关联，包含共享缺失父邮件的回复。
    /// 只覆盖本机已知邮件，返回按日期升序；未装配空间迁移的独立库保留旧查询兼容。
    public func threadMessages(
        accountId: UUID,
        messageId: UUID,
        limit: Int = 5
    ) async throws -> [MailMessage] {
        guard let anchor = try await message(id: messageId), anchor.accountId == accountId else { return [] }
        if try await databaseQueue.read({ try $0.tableExists("mail_thread_links") }) {
            return try await conversationMessages(accountID: accountId, anchorID: messageId, limit: max(0, limit), excludingAnchor: true)
        }
        var ids = Self.messageIdTokens(anchor.references)
        if let own = anchor.messageId, !own.isEmpty { ids.append(own) }
        guard !ids.isEmpty else { return [] }

        let uniqueIDs = Array(Set(ids).prefix(24))
        guard !uniqueIDs.isEmpty else { return [] }
        let clause = Array(repeating: "messageId = ?", count: uniqueIDs.count).joined(separator: " OR ")
        // `references` 是 SQLite 关键字：原始 SQL 片段里必须显式加引号
        let likeClause = Array(repeating: "\"references\" LIKE ?", count: uniqueIDs.count)
            .joined(separator: " OR ")
        // 参数顺序与占位符一一对应：`Column` 过滤器的参数由 GRDB 自行绑定，
        // 这里只提供原始 SQL 片段（messageId / references）的参数
        var values: [String] = []
        values.append(contentsOf: uniqueIDs)
        values.append(contentsOf: uniqueIDs.map { "%\(SQLikeEscaping.escape($0))%" })
        let arguments = StatementArguments(values)
        return try await databaseQueue.read { db in
            try MailMessageRow
                .filter(Column("accountId") == accountId.uuidString)
                .filter(Column("id") != anchor.id.uuidString)
                .filter(sql: "(\(clause)) OR (\(likeClause))", arguments: arguments)
                .order(Column("date").asc, Column("uid").asc)
                .limit(limit)
                .fetchAll(db)
                .compactMap { $0.toMessage() }
        }
    }

    /// 从 `References` 头中提取 Message-ID 令牌（`<...>`）。
    private static func messageIdTokens(_ references: String?) -> [String] {
        guard let references, !references.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var inToken = false
        for character in references {
            if character == "<" {
                inToken = true
                current = "<"
            } else if character == ">", inToken {
                current.append(character)
                tokens.append(current)
                current = ""
                inToken = false
            } else if inToken {
                current.append(character)
            }
        }
        return tokens
    }

    /// 已有的最大**服务器** UID（增量同步起点）；无数据返回 nil。
    /// 本地自产副本（UID ≥ `localUIDFloor`）不计入，否则会把同步游标推到未来。
    public func maxUID(folderId: UUID) async throws -> UInt32? {
        try await databaseQueue.read { db in
            let value = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(uid) FROM mail_messages WHERE folderId = ? AND uid < ?",
                arguments: [folderId.uuidString, Int64(Self.localUIDFloor)]
            )
            return value.flatMap { UInt32(exactly: $0) }
        }
    }

    /// 写入一封**本地自产**邮件（如无 IMAP `APPEND` 时的「已发送」副本）。
    ///
    /// UID 由本方法在保留区间内分配，入参 `message.uid` 被忽略。
    /// 落库后追加正文缓存，使详情页可直接渲染。
    @discardableResult
    public func saveLocalMessage(_ message: MailMessage) async throws -> MailMessage {
        let folderId = message.folderId
        let uid = try await databaseQueue.maintenanceWrite { db -> UInt32 in
            let currentMax = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(uid) FROM mail_messages WHERE folderId = ?",
                arguments: [folderId.uuidString]
            ).flatMap { UInt32(exactly: $0) } ?? 0
            // 保留区间下界远高于任何真实服务器 UID，单文件夹耗尽 4e9 个 UID 不现实，
            // 故不做溢出保护（编码为 `UInt32` 而非抛错）。
            let next = max(currentMax + 1, Self.localUIDFloor)
            var row = MailMessageRow(from: message)
            row.uid = Int64(next)
            try row.insert(db)
            return next
        }

        var stored = message
        stored.uid = uid
        return stored
    }

    /// 改写邮件的所属文件夹（远端 MOVE 成功后的本地同步）。
    ///
    /// `uid` 必须传服务器在目标文件夹分配的新 UID：`MOVE`（RFC 6851）不保留源 UID，
    /// 沿用源 UID 会让记录指向另一封邮件并让增量游标错位。服务器没给出目标 UID
    /// 且无法定位时传 nil —— 此时**不改本地归属**（保持原文件夹），由调用方提示
    /// 重新同步，避免在目标文件夹里留下一个永远对不上服务器的假 UID。
    @discardableResult
    public func moveMessage(id: UUID, toFolderId: UUID, uid: UInt32?) async throws -> Bool {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try MailMessageRow.fetchOne(db, key: id.uuidString) else { return false }
            guard let uid else { return false }
            row.folderId = toFolderId.uuidString
            row.uid = Int64(uid)
            try row.update(db)
            return true
        }
    }

    public func messageCount(folderId: UUID) async throws -> Int {
        try await databaseQueue.read { db in
            try MailMessageRow.filter(Column("folderId") == folderId.uuidString).fetchCount(db)
        }
    }

    /// 更新已读/星标（nil 表示不改该项）。
    public func setFlags(messageId: UUID, isRead: Bool? = nil, isStarred: Bool? = nil, pendingRemote: Bool = false) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard let row = try MailMessageRow.fetchOne(db, key: messageId.uuidString) else { return }
            try Self.writeFlags(row, read: isRead, starred: isStarred, pendingRemote: pendingRemote, db: db)
        }
    }

    /// Opening a reader commits the local change even if fetching the body or reaching IMAP fails.
    public func markOpened(_ message: MailMessage) async throws -> Bool {
        try await databaseQueue.maintenanceWrite { db in
            guard let row = try MailMessageRow.fetchOne(db, key: message.id.uuidString), !row.isRead,
                  row.accountId == message.accountId.uuidString, row.folderId == message.folderId.uuidString,
                  row.uid == Int64(message.uid), row.messageId == message.messageId else { return false }
            let account = try MailAccountRow.fetchOne(db, key: row.accountId)
            let remote = message.uid < Self.localUIDFloor && account != nil && account?.sourceKind != MailAccountSource.localArchive.rawValue
            try Self.writeFlags(row, read: true, starred: nil, pendingRemote: remote, db: db)
            return true
        }
    }

    private static func writeFlags(_ stored: MailMessageRow, read: Bool?, starred: Bool?, pendingRemote: Bool, db: Database) throws {
        var row = stored
        if let read, read != row.isRead {
            row.isRead = read
            try db.execute(sql: "UPDATE mail_folders SET unreadCount = MAX(0, unreadCount + ?) WHERE id = ?",
                           arguments: [read ? -1 : 1, row.folderId])
        }
        if let starred { row.isStarred = starred }
        try row.update(db)
        if pendingRemote {
            try db.execute(sql: "INSERT INTO mail_pending_flags (messageID, seen, starred, revision) VALUES (?, ?, ?, ?) ON CONFLICT(messageID) DO UPDATE SET seen = COALESCE(excluded.seen, mail_pending_flags.seen), starred = COALESCE(excluded.starred, mail_pending_flags.starred), revision = excluded.revision", arguments: [row.id, read, starred, UUID().uuidString])
        }
    }

    /// 更新附件标记（摘要阶段无法得知，正文拉取后确定）。
    public func setHasAttachments(messageId: UUID, hasAttachments: Bool) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try MailMessageRow.fetchOne(db, key: messageId.uuidString) else { return }
            row.hasAttachments = hasAttachments
            try row.update(db)
        }
    }

    public func setBodyState(messageId: UUID, state: MailBodyState) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try MailMessageRow.fetchOne(db, key: messageId.uuidString) else { return }
            row.bodyState = state.rawValue
            try row.update(db)
        }
    }

    /// 正文就绪后回填列表预览：仅当当前预览为空时写入，不覆盖已有值。
    public func updateSnippetIfEmpty(messageId: UUID, snippet: String) async throws {
        guard !snippet.isEmpty else { return }
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try MailMessageRow.fetchOne(db, key: messageId.uuidString),
                  row.snippet.isEmpty else { return }
            row.snippet = snippet
            try row.update(db)
        }
    }

    public func deleteMessage(id: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try Self.deleteMessageContents(messageId: id, in: db)
            _ = try MailMessageRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }

    /// 清空指定文件夹的**服务器**邮件（UIDVALIDITY 变更时全量重建用）。
    /// 本地自产副本（UID ≥ `localUIDFloor`，如无 IMAP `APPEND` 时的「已发送」）不在此清除范围。
    public func clearMessages(folderId: UUID, expectedFolder: MailFolder? = nil) async throws {
        try await databaseQueue.maintenanceWrite { db in
            if let expectedFolder {
                guard expectedFolder.id == folderId else { throw MailFolderMutationError.changed }
                try Self.requireFolderLocation(expectedFolder, db: db)
            }
            if let folder = try MailFolderRow.fetchOne(db, key: folderId.uuidString),
               try MailAccountRow.fetchOne(db, key: folder.accountId)?.sourceKind == MailAccountSource.localArchive.rawValue {
                throw MailImportError.localOnly
            }
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM mail_messages WHERE folderId = ? AND uid < ?",
                arguments: [folderId.uuidString, Int64(Self.localUIDFloor)]
            )
            for id in ids {
                try Self.deleteMessageContents(messageId: UUID(uuidString: id) ?? UUID(), in: db)
            }
            _ = try MailMessageRow
                .filter(Column("folderId") == folderId.uuidString)
                .filter(Column("uid") < Int64(Self.localUIDFloor))
                .deleteAll(db)
        }
    }

    /// 删除账号相关的**全部**本地数据：文件夹、邮件（含本地自产副本）、正文、附件与草稿，
    /// 全部在单个写事务内完成。
    ///
    /// 与 `clearMessages` 的区别：后者保留 UID ≥ `localUIDFloor` 的本地自产副本
    /// （UIDVALIDITY 重建用）。账号删除必须连同这些副本一起清掉——否则删号后本地
    /// 仍残留可读取的已发送邮件，等于「删了账号却删不干净」。
    public func purgeAccount(accountId: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try Self.purgeAccountData(accountId: accountId, in: db)
        }
    }

    /// 账号删除：清空该账号的全部本地数据并删除账号行，**在同一个写事务内**完成。
    ///
    /// 分两次事务（先清数据、再删账号）时，第二步失败会留下一个「空账号」——界面仍
    /// 显示该账号却没有任何邮件，且用户无法解释或修复（见 B03）。合并后要么全部生效、
    /// 要么全部回滚，不留中间态。Keychain 密码删除仍在库事务之外由调用方负责。
    public func purgeAccountAndDeleteAccount(accountId: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try Self.purgeAccountData(accountId: accountId, in: db)
            _ = try MailAccountRow.filter(Column("id") == accountId.uuidString).deleteAll(db)
        }
    }

    /// 账号数据的清理主体（不含账号行本身），供两个入口在同一事务约束下复用。
    private static func purgeAccountData(accountId: UUID, in db: Database) throws {
        let folderIds = try String.fetchAll(
            db,
            sql: "SELECT id FROM mail_folders WHERE accountId = ?",
            arguments: [accountId.uuidString]
        )
        for folderId in folderIds {
            try deleteFolderContents(folderId: folderId, in: db)
        }
        _ = try MailFolderRow.filter(Column("accountId") == accountId.uuidString).deleteAll(db)
        _ = try MailDraftRow.filter(Column("accountId") == accountId.uuidString).deleteAll(db)
    }

    // MARK: - Bodies

    public func saveBody(_ body: MailBody) async throws {
        if let bodyWriteFailureForTesting { throw bodyWriteFailureForTesting }
        try await databaseQueue.maintenanceWrite { db in
            var row = MailBodyRow(from: body)
            try row.save(db)
            // 同一事务内裁剪缓存：失败一起回滚，不会留下「写了却超限」的中间态
            try Self.trimBodyCache(in: db, maxBytes: Self.bodyCacheByteLimit)
        }
    }

    /// 把正文缓存裁剪到字节上限内：按 `fetchedAt` 从旧到新淘汰，并把被淘汰邮件的
    /// `bodyState` 置回 `.none`，使界面重新显示「未下载」而不是拿到空正文。
    ///
    /// 只统计正文字段（不含列名/行开销），是近似值；上限是防止无界增长的保护线，
    /// 不需要精确到字节。
    static func trimBodyCache(in db: Database, maxBytes: Int) throws {
        guard maxBytes > 0 else { return }
        let sizeExpression = "LENGTH(CAST(COALESCE(textBody,'') AS BLOB)) + LENGTH(CAST(COALESCE(htmlBody,'') AS BLOB)) "
            + "+ LENGTH(CAST(COALESCE(rawHeaders,'') AS BLOB)) + LENGTH(CAST(COALESCE(searchText,'') AS BLOB))"
        let total = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(\(sizeExpression)), 0) FROM mail_bodies"
        ) ?? 0
        guard total > maxBytes else { return }

        let rows = try Row.fetchAll(
            db,
            sql: "SELECT messageId, \(sizeExpression) AS bytes FROM mail_bodies "
                + "ORDER BY fetchedAt ASC, messageId ASC"
        )
        var remaining = total
        var evicted: [String] = []
        for row in rows {
            guard remaining > maxBytes else { break }
            let messageId: String = row["messageId"]
            let bytes: Int = row["bytes"]
            remaining -= bytes
            evicted.append(messageId)
        }
        guard !evicted.isEmpty else { return }

        // SQLite 主机参数数量有上限，按块删除避免超限
        var index = 0
        while index < evicted.count {
            let end = min(index + 500, evicted.count)
            let chunk = Array(evicted[index..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM mail_bodies WHERE messageId IN (\(placeholders))",
                arguments: StatementArguments(chunk)
            )
            try db.execute(
                sql: "UPDATE mail_messages SET bodyState = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([MailBodyState.none.rawValue] + chunk)
            )
            index = end
        }
    }

    public func body(messageId: UUID) async throws -> MailBody? {
        try await databaseQueue.read { db in
            try MailBodyRow.fetchOne(db, key: messageId.uuidString)?.toBody()
        }
    }

    // MARK: - Attachments

    static func addAttachmentPartColumn(_ db: Database) throws {
        if try !db.columns(in: "mail_attachments").contains(where: { $0.name == "partID" }) {
            try db.alter(table: "mail_attachments") { $0.add(column: "partID", .text) }
        }
    }

    public func replaceAttachments(messageId: UUID, attachments: [MailAttachment]) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try Self.replaceAttachments(messageId: messageId, attachments: attachments, in: db)
        }
    }

    private struct AttachmentIdentity: Hashable {
        let filename: String
        let mimeType: String
        let contentID: String?
        let isInline: Bool
        init(filename: String, mimeType: String, contentID: String?, isInline: Bool) {
            self.filename = filename; self.mimeType = mimeType.lowercased()
            self.contentID = MailService.normalizedAttachmentContentID(contentID); self.isInline = isInline
        }
    }

    static func replaceAttachments(messageId: UUID, attachments: [MailAttachment], in db: Database,
                                   restoringOriginal: Bool = false) throws {
        let existing = try MailAttachmentRow.filter(Column("messageId") == messageId.uuidString).fetchAll(db)
        let existingByPart = Dictionary(grouping: existing.filter { $0.partID != nil }, by: { $0.partID! })
        let previousIdentities = Dictionary(grouping: existing, by: {
            AttachmentIdentity(filename: $0.filename, mimeType: $0.mimeType, contentID: $0.contentId, isInline: $0.isInline)
        })
        let newIdentities = Dictionary(grouping: attachments, by: {
            AttachmentIdentity(filename: $0.filename, mimeType: $0.mimeType, contentID: $0.contentId, isInline: $0.isInline)
        })
        var retainedIDs = Set<String>()
        _ = try MailAttachmentRow.filter(Column("messageId") == messageId.uuidString).deleteAll(db)
        for attachment in attachments {
            var row = MailAttachmentRow(from: attachment)
            var retained = attachment.partID.flatMap { part in existingByPart[part]?.first { !retainedIDs.contains($0.id) } }
            if retained == nil, restoringOriginal {
                let identity = AttachmentIdentity(filename: attachment.filename, mimeType: attachment.mimeType, contentID: attachment.contentId, isInline: attachment.isInline)
                if newIdentities[identity]?.count == 1, let matches = previousIdentities[identity], matches.count == 1,
                   let old = matches.first, !retainedIDs.contains(old.id) {
                    retained = old
                }
            }
            if let old = retained {
                retainedIDs.insert(old.id)
                row.id = old.id; row.localPath = old.localPath
                if row.sizeBytes == 0 { row.sizeBytes = old.sizeBytes }
            }
            try row.save(db)
        }
    }

    static func normalizedAttachmentContentID(_ value: String?) -> String? {
        value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
    }

    /// An autosave must never overwrite SMTP delivery evidence or a newer editor snapshot.
    public func saveEditableDraft(_ draft: MailDraft) async throws {
        try await databaseQueue.maintenanceWrite { db in
            if let current = try MailDraftRow.fetchOne(db, key: draft.id.uuidString)?.toDraft() {
                guard current.deliveredAt == nil, current.deliveryState == .none || current.deliveryState == .prepared else {
                    throw MailSyncError.deliveryStateNotRetryable(current.deliveryState)
                }
                guard current.updatedAt <= draft.updatedAt else { return }
            }
            guard draft.deliveredAt == nil, draft.deliveryState == .none || draft.deliveryState == .prepared else {
                throw MailSyncError.deliveryStateNotRetryable(draft.deliveryState)
            }
            var row = try MailDraftRow(from: draft)
            try row.save(db)
        }
    }

    public func saveAttachments(_ attachments: [MailAttachment]) async throws {
        guard !attachments.isEmpty else { return }
        try await databaseQueue.maintenanceWrite { db in
            for attachment in attachments {
                var row = MailAttachmentRow(from: attachment)
                try row.save(db)
            }
        }
    }

    public func attachments(messageId: UUID) async throws -> [MailAttachment] {
        try await databaseQueue.read { db in
            try MailAttachmentRow
                .filter(Column("messageId") == messageId.uuidString)
                .fetchAll(db)
                .compactMap { $0.toAttachment() }
        }
    }

    // MARK: - Drafts

    static func addDraftAttachmentColumns(_ db: Database) throws {
        let columns = try db.columns(in: "mail_drafts").map(\.name)
        if !columns.contains("attachmentsData") { try db.alter(table: "mail_drafts") { $0.add(column: "attachmentsData", .blob) } }
        if !columns.contains("forwardAttachmentsState") { try db.alter(table: "mail_drafts") { $0.add(column: "forwardAttachmentsState", .text) } }
    }

    public func saveDraft(_ draft: MailDraft) async throws {
        try await databaseQueue.maintenanceWrite { db in
            var row = try MailDraftRow(from: draft)
            try row.save(db)
        }
    }

    /// A retried agent operation must not replace a draft subsequently edited or sent by the user.
    enum AgentDraftResult { case created, existing, removed }

    func insertAgentDraft(_ draft: MailDraft, source: MailMessage?, trackOperation: Bool) async throws -> AgentDraftResult {
        try await databaseQueue.maintenanceWrite { db in
            if try MailDraftRow.fetchOne(db, key: draft.id.uuidString) != nil { return .existing }
            if trackOperation, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_agent_draft_receipts WHERE id = ?)",
                                                 arguments: [draft.id.uuidString]) == true { return .removed }
            if let source {
                guard let current = try MailMessageRow.fetchOne(db, key: source.id.uuidString)?.toMessage(),
                      current.accountId == source.accountId, current.messageId == source.messageId,
                      current.fromAddress == source.fromAddress, current.replyTo == source.replyTo,
                      current.subject == source.subject, current.date == source.date else { throw MailSourceReferenceError.missing }
            }
            var row = try MailDraftRow(from: draft)
            try row.insert(db)
            if trackOperation {
                try db.execute(sql: "INSERT INTO mail_agent_draft_receipts (id, accountId) VALUES (?, ?)",
                               arguments: [draft.id.uuidString, draft.accountId.uuidString])
            }
            return .created
        }
    }

    /// 取单封草稿（发送前查投递凭证、判断是否允许重发用）。
    public func draft(id: UUID) async throws -> MailDraft? {
        try await databaseQueue.read { db in
            try MailDraftRow.fetchOne(db, key: id.uuidString)?.toDraft()
        }
    }

    public func drafts(accountId: UUID) async throws -> [MailDraft] {
        try await databaseQueue.read { db in
            try MailDraftRow
                .filter(Column("accountId") == accountId.uuidString)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
                .compactMap { try $0.toDraft() }
        }
    }

    public func deleteDraft(id: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            _ = try MailDraftRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }

    /// 登记「这封草稿已经投递出去」的凭证（投递成功后立即调用）。
    ///
    /// 这是崩溃/落库失败窗口内唯一能证明邮件已发出的本地依据：副本或清理失败时草稿
    /// 仍在且带此标记，界面据此提示「已发送」并禁止重发（重发会重复投递）。
    /// 返回是否命中记录：发送前一定会先落草稿，返回 `false` 说明「先落草稿」失败过，
    /// 调用方需记 error——投递凭证是已投递的唯一本地依据，不能静默丢掉。
    @discardableResult
    public func markDraftDelivered(id: UUID, messageId: String) async throws -> Bool {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try MailDraftRow.fetchOne(db, key: id.uuidString) else { return false }
            row.deliveredAt = Date()
            row.deliveredMessageId = messageId
            try row.update(db)
            return true
        }
    }

    /// 推进草稿的持久化投递状态（可选同时固定 / 更新本次尝试的 Message-ID）。
    ///
    /// 这是「重开 / 重启后能否普通重发」的唯一依据：进入可能投递的阶段前必须先落盘，
    /// 结果未知时保持非重试态，避免把未知结果当作普通失败反复投递（见 `MailDeliveryState`）。
    /// 返回是否命中记录。
    @discardableResult
    public func markDraftDeliveryState(
        id: UUID,
        state: MailDeliveryState,
        messageId: String? = nil
    ) async throws -> Bool {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try MailDraftRow.fetchOne(db, key: id.uuidString) else { return false }
            row.deliveryState = state.rawValue
            if let messageId { row.pendingMessageId = messageId }
            try row.update(db)
            return true
        }
    }

    /// 原子领取一封草稿用于投递：把「是否可发」判定与「进入投递中」的状态推进
    /// 放进同一个写事务，保证同一封草稿在任意时刻只有一个发送者拿到领取权。
    ///
    /// 「先查是否已投递、再发送」在 await 处可被另一个发送重入，最终造成重复投递
    /// （见 B03）。这里一次性完成：记录不存在则按传入草稿落库，允许重试则推进为
    /// `sending` 并固定 Message-ID；返回领取到的草稿。nil 表示不可领取
    /// （正在投递 / 结果未知 / 已投递）。
    @discardableResult
    public func claimDraftForDelivery(_ draft: MailDraft, messageId: String) async throws -> MailDraft? {
        try await databaseQueue.maintenanceWrite { db in
            let existing = try MailDraftRow.fetchOne(db, key: draft.id.uuidString)
            if let existing, existing.deliveredAt != nil { return nil }
            let state = existing?.deliveryState.flatMap(MailDeliveryState.init(rawValue:)) ?? .none
            guard state.allowsRetry else { return nil }
            var row = try MailDraftRow(from: draft)
            row.deliveryState = MailDeliveryState.sending.rawValue
            row.pendingMessageId = messageId
            try row.save(db)
            return try row.toDraft()
        }
    }

    /// 已投递但草稿仍在本地的记录（用于提示用户核实与清理）。
    public func deliveredDrafts(accountId: UUID) async throws -> [MailDraft] {
        try await databaseQueue.read { db in
            try MailDraftRow
                .filter(Column("accountId") == accountId.uuidString)
                .filter(Column("deliveredAt") != nil)
                .order(Column("deliveredAt").desc)
                .fetchAll(db)
                .compactMap { try $0.toDraft() }
        }
    }

    // MARK: - Private Helpers

    /// 级联删除邮件正文与附件记录。
    static func deleteMessageContents(messageId: UUID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM mail_raw_messages WHERE messageID = ?", arguments: [messageId.uuidString])
        _ = try MailBodyRow.filter(Column("messageId") == messageId.uuidString).deleteAll(db)
        _ = try MailAttachmentRow.filter(Column("messageId") == messageId.uuidString).deleteAll(db)
    }

    /// 级联删除文件夹下全部邮件及其正文/附件。
    private static func deleteFolderContents(folderId: String, in db: Database) throws {
        let ids = try String.fetchAll(
            db,
            sql: "SELECT id FROM mail_messages WHERE folderId = ?",
            arguments: [folderId]
        )
        for id in ids {
            guard let uuid = UUID(uuidString: id) else { continue }
            try deleteMessageContents(messageId: uuid, in: db)
        }
        _ = try MailMessageRow.filter(Column("folderId") == folderId).deleteAll(db)
    }
}

// MARK: - GRDB Rows

struct MailAccountRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "mail_accounts"

    var id: String
    var displayName: String
    var emailAddress: String
    var imapHost: String
    var imapPort: Int
    var imapSecurity: String
    var smtpHost: String
    var smtpPort: Int
    var smtpSecurity: String
    var username: String
    var authKind: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var sourceKind: String?

    init(from account: MailAccount) {
        self.id = account.id.uuidString
        self.displayName = account.displayName
        self.emailAddress = account.emailAddress
        self.imapHost = account.imapHost
        self.imapPort = account.imapPort
        self.imapSecurity = account.imapSecurity.rawValue
        self.smtpHost = account.smtpHost
        self.smtpPort = account.smtpPort
        self.smtpSecurity = account.smtpSecurity.rawValue
        self.username = account.username
        self.authKind = account.authKind.rawValue
        self.isEnabled = account.isEnabled
        self.createdAt = account.createdAt
        self.updatedAt = account.updatedAt
        self.sourceKind = (account.sourceKind ?? .imap).rawValue
    }

    func toAccount() -> MailAccount? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        guard let kind = MailAccountSource(rawValue: sourceKind ?? MailAccountSource.imap.rawValue) else { return nil }
        var account = MailAccount(
            id: uuid,
            displayName: displayName,
            emailAddress: emailAddress,
            imapHost: imapHost,
            imapPort: imapPort,
            imapSecurity: MailSecurity(rawValue: imapSecurity) ?? .tls,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpSecurity: MailSecurity(rawValue: smtpSecurity) ?? .startTLS,
            username: username,
            authKind: MailAuthKind(rawValue: authKind) ?? .password,
            isEnabled: isEnabled,
            sourceKind: kind
        )
        account.createdAt = createdAt
        account.updatedAt = updatedAt
        return account
    }
}

struct MailFolderRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "mail_folders"

    var id: String
    var accountId: String
    var path: String
    var name: String
    var role: String
    var parentPath: String?
    var delimiter: String?
    var isContainer: Bool
    var uidValidity: Int64?
    var uidNext: Int64?
    var lastSyncAt: Date?
    var unreadCount: Int
    var totalCount: Int

    init(from folder: MailFolder) {
        self.id = folder.id.uuidString
        self.accountId = folder.accountId.uuidString
        self.path = folder.path
        self.name = folder.name
        self.role = folder.role.rawValue
        self.parentPath = folder.parentPath
        self.delimiter = folder.delimiter
        self.isContainer = folder.isContainer
        self.uidValidity = folder.uidValidity.map { Int64($0) }
        self.uidNext = folder.uidNext.map { Int64($0) }
        self.lastSyncAt = folder.lastSyncAt
        self.unreadCount = folder.unreadCount
        self.totalCount = folder.totalCount
    }

    func toFolder() -> MailFolder? {
        guard let uuid = UUID(uuidString: id), let accountUUID = UUID(uuidString: accountId) else { return nil }
        return MailFolder(
            id: uuid,
            accountId: accountUUID,
            path: path,
            name: name,
            role: MailFolderRole(rawValue: role) ?? .other,
            parentPath: parentPath,
            delimiter: delimiter,
            isContainer: isContainer,
            uidValidity: uidValidity.flatMap { UInt32(exactly: $0) },
            uidNext: uidNext.flatMap { UInt32(exactly: $0) },
            lastSyncAt: lastSyncAt,
            unreadCount: unreadCount,
            totalCount: totalCount
        )
    }
}

struct MailMessageRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "mail_messages"

    var id: String
    var accountId: String
    var folderId: String
    var uid: Int64
    var messageId: String?
    var subject: String
    var fromName: String
    var fromAddress: String
    var replyToJSON: String
    var toJSON: String
    var ccJSON: String
    var references: String?
    var date: Date?
    var isRead: Bool
    var isStarred: Bool
    var hasAttachments: Bool
    var sizeBytes: Int
    var snippet: String
    var bodyState: String

    init(from message: MailMessage) {
        self.id = message.id.uuidString
        self.accountId = message.accountId.uuidString
        self.folderId = message.folderId.uuidString
        self.uid = Int64(message.uid)
        self.messageId = message.messageId
        self.subject = message.subject
        self.fromName = message.fromName
        self.fromAddress = message.fromAddress
        self.replyToJSON = Self.encodeAddresses(message.replyTo)
        self.toJSON = Self.encodeAddresses(message.to)
        self.ccJSON = Self.encodeAddresses(message.cc)
        self.references = message.references
        self.date = message.date
        self.isRead = message.isRead
        self.isStarred = message.isStarred
        self.hasAttachments = message.hasAttachments
        self.sizeBytes = message.sizeBytes
        self.snippet = message.snippet
        self.bodyState = message.bodyState.rawValue
    }

    func toMessage() -> MailMessage? {
        guard let uuid = UUID(uuidString: id),
              let accountUUID = UUID(uuidString: accountId),
              let folderUUID = UUID(uuidString: folderId),
              let uidValue = UInt32(exactly: uid) else { return nil }
        return MailMessage(
            id: uuid,
            accountId: accountUUID,
            folderId: folderUUID,
            uid: uidValue,
            messageId: messageId,
            // 读取侧解码：协议层已解码新写入的值，这里兜底纠正修复前按原始值入库的历史行。
            // 解码幂等，未编码文本原样返回，重复调用安全。
            subject: MailHeaderText.decoded(subject),
            fromName: MailHeaderText.decoded(fromName),
            fromAddress: fromAddress,
            replyTo: MailHeaderText.decoded(Self.decodeAddresses(replyToJSON)),
            to: MailHeaderText.decoded(Self.decodeAddresses(toJSON)),
            cc: MailHeaderText.decoded(Self.decodeAddresses(ccJSON)),
            references: references,
            date: date,
            isRead: isRead,
            isStarred: isStarred,
            hasAttachments: hasAttachments,
            sizeBytes: sizeBytes,
            snippet: snippet,
            bodyState: MailBodyState(rawValue: bodyState) ?? .none
        )
    }

    static func encodeAddresses(_ addresses: [MailAddress]) -> String {
        guard let data = try? JSONEncoder().encode(addresses),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func decodeAddresses(_ json: String) -> [MailAddress] {
        guard let data = json.data(using: .utf8),
              let addresses = try? JSONDecoder().decode([MailAddress].self, from: data) else { return [] }
        return addresses
    }
}

struct MailBodyRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "mail_bodies"

    var messageId: String
    var textBody: String?
    var htmlBody: String?
    var rawHeaders: String?
    var searchText: String?
    var fetchedAt: Date

    init(from body: MailBody) {
        self.messageId = body.messageId.uuidString
        self.textBody = body.textBody
        self.htmlBody = body.htmlBody
        self.rawHeaders = body.rawHeaders
        self.searchText = MailService.searchableBody(text: body.textBody, html: body.htmlBody)
        self.fetchedAt = body.fetchedAt
    }

    func toBody() -> MailBody? {
        guard let uuid = UUID(uuidString: messageId) else { return nil }
        return MailBody(
            messageId: uuid,
            textBody: textBody,
            htmlBody: htmlBody,
            rawHeaders: rawHeaders,
            fetchedAt: fetchedAt
        )
    }
}

struct MailAttachmentRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "mail_attachments"

    var id: String
    var messageId: String
    var filename: String
    var mimeType: String
    var sizeBytes: Int
    var contentId: String?
    var localPath: String?
    var partID: String?
    var isInline: Bool

    init(from attachment: MailAttachment) {
        self.id = attachment.id.uuidString
        self.messageId = attachment.messageId.uuidString
        self.filename = attachment.filename
        self.mimeType = attachment.mimeType
        self.sizeBytes = attachment.sizeBytes
        self.contentId = attachment.contentId
        self.localPath = attachment.localPath
        self.partID = attachment.partID
        self.isInline = attachment.isInline
    }

    func toAttachment() -> MailAttachment? {
        guard let uuid = UUID(uuidString: id), let messageUUID = UUID(uuidString: messageId) else { return nil }
        return MailAttachment(
            id: uuid,
            messageId: messageUUID,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            contentId: contentId,
            localPath: localPath,
            isInline: isInline,
            partID: partID
        )
    }
}

struct MailDraftRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "mail_drafts"

    var id: String
    var accountId: String
    var toJSON: String
    var ccJSON: String
    var bccJSON: String
    var subject: String
    var bodyText: String
    var quotedText: String
    var composeKind: String
    var sourceMessageId: String?
    var inReplyTo: String?
    var references: String?
    var updatedAt: Date
    /// 非空表示这封邮件已经投递出去（本地留存的投递凭证）
    var deliveredAt: Date?
    var deliveredMessageId: String?
    /// 投递状态机的持久化值（text；旧数据为 nil，映射为 none）
    var deliveryState: String?
    /// 本次尝试的稳定 Message-ID
    var pendingMessageId: String?

    var attachmentsData: Data?
    var bodyStylesData: Data?
    var forwardAttachmentsState: String?

    init(from draft: MailDraft) throws {
        try MailStyleSpan.validate(draft.bodyStyles, text: draft.bodyText)
        bodyStylesData = draft.bodyStyles.isEmpty ? nil : try JSONEncoder().encode(draft.bodyStyles)
        try MailDraftAttachment.validate(draft.attachments)
        self.attachmentsData = try JSONEncoder().encode(draft.attachments)
        guard self.attachmentsData!.count <= MailDraftAttachment.maximumSerializedBytes else { throw MailAttachmentError.capacity }
        self.forwardAttachmentsState = draft.forwardAttachmentsState.rawValue
        self.id = draft.id.uuidString
        self.accountId = draft.accountId.uuidString
        self.toJSON = MailMessageRow.encodeAddresses(draft.to)
        self.ccJSON = MailMessageRow.encodeAddresses(draft.cc)
        self.bccJSON = MailMessageRow.encodeAddresses(draft.bcc)
        self.subject = draft.subject
        self.bodyText = draft.bodyText
        self.quotedText = draft.quotedText
        self.composeKind = draft.composeKind.rawValue
        self.sourceMessageId = draft.sourceMessageId?.uuidString
        self.inReplyTo = draft.inReplyTo
        self.references = draft.references
        self.updatedAt = draft.updatedAt
        self.deliveredAt = draft.deliveredAt
        self.deliveredMessageId = draft.deliveredMessageId
        self.deliveryState = draft.deliveryState.rawValue
        self.pendingMessageId = draft.pendingMessageId
    }

    func toDraft() throws -> MailDraft? {
        let attachments: [MailDraftAttachment]
        if let attachmentsData {
            do {
                guard attachmentsData.count <= MailDraftAttachment.maximumSerializedBytes else { throw MailAttachmentError.capacity }
                attachments = try JSONDecoder().decode([MailDraftAttachment].self, from: attachmentsData)
                try MailDraftAttachment.validate(attachments)
            } catch { throw MailAttachmentError.corrupt }
        } else { attachments = [] }
        if let forwardAttachmentsState, MailForwardAttachmentsState(rawValue: forwardAttachmentsState) == nil { throw MailAttachmentError.corrupt }
        guard let uuid = UUID(uuidString: id), let accountUUID = UUID(uuidString: accountId) else { return nil }
        return MailDraft(
            id: uuid,
            accountId: accountUUID,
            to: MailMessageRow.decodeAddresses(toJSON),
            cc: MailMessageRow.decodeAddresses(ccJSON),
            bcc: MailMessageRow.decodeAddresses(bccJSON),
            subject: subject,
            bodyText: bodyText,
            bodyStyles: try MailStyleSpan.decode(bodyStylesData, text: bodyText),
            quotedText: quotedText,
            composeKind: MailComposeKind(rawValue: composeKind) ?? .new,
            sourceMessageId: sourceMessageId.flatMap(UUID.init(uuidString:)),
            inReplyTo: inReplyTo,
            references: references,
            updatedAt: updatedAt,
            deliveredAt: deliveredAt,
            deliveredMessageId: deliveredMessageId,
            deliveryState: deliveryState.flatMap(MailDeliveryState.init(rawValue:)) ?? .none,
            pendingMessageId: pendingMessageId,
            attachments: attachments,
            forwardAttachmentsState: forwardAttachmentsState.flatMap(MailForwardAttachmentsState.init(rawValue:)) ?? .pending
        )
    }
}
