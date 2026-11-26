import Foundation
import GRDB

public struct MailInboxObservation: Sendable {
    public let folderID: UUID
    public let uidValidity: UInt32?
    public let highestUID: UInt32
    public let newUnreadCount: Int
}

extension MailService {
    public func observeInbox(accountID: UUID, since: [UUID: UInt32]) async throws -> [MailInboxObservation] {
        try await databaseQueue.read { db in
            guard let account = try MailAccountRow.fetchOne(db, key: accountID.uuidString)?.toAccount(), !account.isLocalArchive else { throw MailSyncError.accountNotFound }
            let folders = try MailFolderRow.filter(Column("accountId") == accountID.uuidString)
                .filter(Column("role") == MailFolderRole.inbox.rawValue).fetchAll(db).compactMap { $0.toFolder() }
            return try folders.filter { !$0.isContainer }.map { folder in
                let largest = try Int64.fetchOne(db, sql: "SELECT MAX(uid) FROM mail_messages WHERE folderId=? AND uid<?", arguments: [folder.id.uuidString, Int64(Self.localUIDFloor)]) ?? 0
                let count: Int
                if let after = since[folder.id] {
                    count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_messages WHERE folderId=? AND uid>? AND uid<? AND isRead=0",
                        arguments: [folder.id.uuidString, Int64(after), Int64(Self.localUIDFloor)]) ?? 0
                } else { count = 0 }
                return .init(folderID: folder.id, uidValidity: folder.uidValidity, highestUID: UInt32(clamping: largest), newUnreadCount: count)
            }
        }
    }
}
