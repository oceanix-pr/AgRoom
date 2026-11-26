import Foundation
import GRDB

public struct MailSyncCoverage: Sendable, Equatable {
    public let cachedCount: Int
    public let remoteCount: Int?
    public let oldestDate: Date?
    public let newestDate: Date?
    public let checkedAt: Date?
    public let isComplete: Bool
}

public struct MailLocalSourceSummary: Sendable, Equatable {
    public let enabledAccounts: Int
    public let syncedMessages: Int

    public init(enabledAccounts: Int, syncedMessages: Int) {
        self.enabledAccounts = enabledAccounts
        self.syncedMessages = syncedMessages
    }
}

struct PendingMailFlags: Sendable {
    let messageID: UUID
    let uid: UInt32
    let seen: Bool?
    let starred: Bool?
    let revision: String
    var add: [MailFlag] { (seen == true ? [.seen] : []) + (starred == true ? [.flagged] : []) }
    var remove: [MailFlag] { (seen == false ? [.seen] : []) + (starred == false ? [.flagged] : []) }
}

extension MailService {
    /// Readiness is a local snapshot, not a connection probe or a promise that
    /// every remote message/body has been synchronized.
    public func localSourceSummary() async throws -> MailLocalSourceSummary {
        try await databaseQueue.read { db in
            try MailLocalSourceSummary(
                enabledAccounts: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_accounts WHERE isEnabled=1") ?? 0,
                syncedMessages: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_messages m JOIN mail_accounts a ON a.id=m.accountId WHERE a.isEnabled=1 AND m.uid < ?", arguments: [Int64(Self.localUIDFloor)]) ?? 0)
        }
    }

    static func createCoverageSchema(_ db: Database) throws {
        try db.create(table: "mail_sync_coverage", ifNotExists: true) { table in
            table.column("folderID", .text).primaryKey().references("mail_folders", onDelete: .cascade)
            table.column("remoteCount", .integer).notNull()
            table.column("complete", .boolean).notNull()
            table.column("checkedAt", .datetime).notNull()
        }
        try db.create(table: "mail_pending_flags", ifNotExists: true) { table in
            table.column("messageID", .text).primaryKey().references("mail_messages", onDelete: .cascade)
            table.column("seen", .boolean)
            table.column("starred", .boolean)
            table.column("revision", .text).notNull()
        }
    }

    public func coverage(folderID: UUID) async throws -> MailSyncCoverage {
        try await databaseQueue.read { db in
            let totals = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS count, MIN(date) AS oldest, MAX(date) AS newest FROM mail_messages WHERE folderId = ? AND uid < ?", arguments: [folderID.uuidString, Int64(Self.localUIDFloor)])
            let checked = try Row.fetchOne(db, sql: "SELECT * FROM mail_sync_coverage WHERE folderID = ?", arguments: [folderID.uuidString])
            return MailSyncCoverage(cachedCount: totals?["count"] ?? 0, remoteCount: checked?["remoteCount"],
                oldestDate: totals?["oldest"], newestDate: totals?["newest"], checkedAt: checked?["checkedAt"], isComplete: checked?["complete"] ?? false)
        }
    }

    func cachedServerUIDs(folderID: UUID) async throws -> Set<UInt32> {
        try await databaseQueue.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT uid FROM mail_messages WHERE folderId = ? AND uid < ?", arguments: [folderID.uuidString, Int64(Self.localUIDFloor)]).compactMap(UInt32.init(exactly:)))
        }
    }

    func pendingFlags(folderID: UUID) async throws -> [PendingMailFlags] {
        try await databaseQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT p.*, m.uid FROM mail_pending_flags p JOIN mail_messages m ON m.id = p.messageID WHERE m.folderId = ? AND m.uid < ?", arguments: [folderID.uuidString, Int64(Self.localUIDFloor)]).compactMap { row in
                guard let id = UUID(uuidString: row["messageID"]), let uid = UInt32(exactly: row["uid"] as Int64) else { return nil }
                return PendingMailFlags(messageID: id, uid: uid, seen: row["seen"], starred: row["starred"], revision: row["revision"])
            }
        }
    }

    func acknowledgeFlags(_ pending: PendingMailFlags, expectedFolder: MailFolder? = nil) async throws {
        try await databaseQueue.maintenanceWrite { db in
            if let expectedFolder { try Self.requireFolderLocation(expectedFolder, db: db) }
            try db.execute(sql: "DELETE FROM mail_pending_flags WHERE messageID = ? AND revision = ?", arguments: [pending.messageID.uuidString, pending.revision])
        }
    }

    func clearCoverage(folderID: UUID, expectedFolder: MailFolder? = nil) async throws {
        try await databaseQueue.maintenanceWrite { db in
            if let expectedFolder {
                guard expectedFolder.id == folderID else { throw MailFolderMutationError.changed }
                try Self.requireFolderLocation(expectedFolder, db: db)
            }
            try db.execute(sql: "DELETE FROM mail_sync_coverage WHERE folderID = ?", arguments: [folderID.uuidString])
        }
    }

    /// Apply one authoritative remote UID/flag snapshot in a transaction. New messages
    /// arriving after that snapshot are retained; unacknowledged local flag edits win.
    func reconcile(folderID: UUID, previouslyCached: Set<UInt32>, remote: Set<UInt32>, seen: Set<UInt32>, starred: Set<UInt32>, expectedFolder: MailFolder? = nil) async throws {
        try await databaseQueue.maintenanceWrite { db in
            if let expectedFolder {
                guard expectedFolder.id == folderID else { throw MailFolderMutationError.changed }
                try Self.requireFolderLocation(expectedFolder, db: db)
            }
            let rows = try Row.fetchAll(db, sql: "SELECT m.id, m.uid, p.seen AS pendingSeen, p.starred AS pendingStarred FROM mail_messages m LEFT JOIN mail_pending_flags p ON p.messageID = m.id WHERE m.folderId = ? AND m.uid < ?", arguments: [folderID.uuidString, Int64(Self.localUIDFloor)])
            for row in rows {
                guard let uid = UInt32(exactly: row["uid"] as Int64) else { continue }
                let id: String = row["id"]
                if previouslyCached.contains(uid), !remote.contains(uid) {
                    if let uuid = UUID(uuidString: id) { try Self.deleteMessageContents(messageId: uuid, in: db) }
                    try db.execute(sql: "DELETE FROM mail_messages WHERE id = ?", arguments: [id])
                } else if remote.contains(uid) {
                    let pendingSeen: Bool? = row["pendingSeen"], pendingStarred: Bool? = row["pendingStarred"]
                    if pendingSeen == nil { try db.execute(sql: "UPDATE mail_messages SET isRead = ? WHERE id = ?", arguments: [seen.contains(uid), id]) }
                    if pendingStarred == nil { try db.execute(sql: "UPDATE mail_messages SET isStarred = ? WHERE id = ?", arguments: [starred.contains(uid), id]) }
                }
            }
            let cached = Set(try Int64.fetchAll(db, sql: "SELECT uid FROM mail_messages WHERE folderId = ? AND uid < ?", arguments: [folderID.uuidString, Int64(Self.localUIDFloor)]).compactMap(UInt32.init(exactly:)))
            try db.execute(sql: "INSERT INTO mail_sync_coverage (folderID, remoteCount, complete, checkedAt) VALUES (?, ?, ?, ?) ON CONFLICT(folderID) DO UPDATE SET remoteCount = excluded.remoteCount, complete = excluded.complete, checkedAt = excluded.checkedAt", arguments: [folderID.uuidString, remote.count, remote.isSubset(of: cached), Date()])
        }
    }
}
