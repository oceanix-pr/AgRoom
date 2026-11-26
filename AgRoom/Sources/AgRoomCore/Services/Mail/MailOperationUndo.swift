import Foundation
import GRDB

struct MailOperationSnapshot: Sendable {
    let account: MailAccount
    let message: MailMessage
    let folder: MailFolder
}

struct MailOperationUndoEntry: Sendable {
    let before: MailOperationSnapshot
    let after: MailOperationSnapshot
    let action: MailBatchAction
    var id: UUID { after.message.id }
}

actor MailOperationUndoClaims {
    private var claimed = Set<UUID>()
    func snapshot() -> Set<UUID> { claimed }
    func claim(_ id: UUID) -> Bool { claimed.insert(id).inserted }
}

/// Session-only success receipts cannot be restored or transferred to another
/// database. Each reversal can be claimed once, including an unknown outcome.
public struct MailOperationUndoReceipt: Sendable, Identifiable {
    public let id = UUID()
    public var count: Int { entries.count }
    let originQueue: DatabaseQueue
    let entries: [MailOperationUndoEntry]
    let claims = MailOperationUndoClaims()
}

public struct MailOperationUndoReview: Sendable, Identifiable {
    public struct Change: Sendable, Identifiable {
        public let id: UUID
        public let title: String
        public let action: MailBatchAction
        public let destination: String?
    }
    public let id = UUID()
    public var count: Int { entries.count }
    public var receiptID: UUID { receipt.id }
    public var changes: [Change] {
        entries.map { entry in
            let action: MailBatchAction
            switch entry.action {
            case .read: action = .read(entry.before.message.isRead)
            case .star: action = .star(entry.before.message.isStarred)
            default: action = .move(entry.before.folder.id)
            }
            return .init(id: entry.id, title: entry.after.message.subject, action: action,
                destination: entry.before.folder.id == entry.after.folder.id ? nil : MailFolderPath.display(entry.before.folder, isLocalArchive: entry.before.account.isLocalArchive))
        }
    }
    public let skipped: Int
    let receipt: MailOperationUndoReceipt
    let entries: [MailOperationUndoEntry]
}

extension MailService {
    func operationSnapshot(_ id: UUID) async throws -> MailOperationSnapshot {
        try await databaseQueue.read { db in
            guard let message = try MailMessageRow.fetchOne(db, key: id.uuidString)?.toMessage(),
                  let account = try MailAccountRow.fetchOne(db, key: message.accountId.uuidString)?.toAccount(),
                  let folder = try MailFolderRow.fetchOne(db, key: message.folderId.uuidString)?.toFolder(),
                  folder.accountId == account.id else { throw MailMoveReviewError.changed }
            return .init(account: account, message: message, folder: folder)
        }
    }

    public func previewOperationUndo(_ receipt: MailOperationUndoReceipt) async throws -> MailOperationUndoReview {
        guard receipt.originQueue === databaseQueue else { throw MailMoveReviewError.changed }
        let claimed = await receipt.claims.snapshot()
        return try await databaseQueue.read { db in
            var eligible: [MailOperationUndoEntry] = []
            for entry in receipt.entries where !claimed.contains(entry.id) {
                try Task.checkCancellation()
                do { try Self.validateOperationUndo(entry, db: db); eligible.append(entry) }
                catch MailMoveReviewError.changed { continue }
            }
            return .init(skipped: receipt.entries.count - eligible.count, receipt: receipt, entries: eligible)
        }
    }

    func validateOperationUndo(_ entry: MailOperationUndoEntry) async throws {
        try await databaseQueue.read { db in try Self.validateOperationUndo(entry, db: db) }
    }

    func undoLocalOperation(_ entry: MailOperationUndoEntry) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try Task.checkCancellation()
            try Self.validateOperationUndo(entry, db: db)
            guard entry.after.message.uid >= Self.localUIDFloor,
                  var row = try MailMessageRow.fetchOne(db, key: entry.id.uuidString) else { throw MailMoveReviewError.changed }
            switch entry.action {
            case .read: row.isRead = entry.before.message.isRead
            case .star: row.isStarred = entry.before.message.isStarred
            case .move, .moveToRole: row.folderId = entry.before.folder.id.uuidString
            case .permanentlyDelete: throw MailMoveReviewError.changed
            }
            try row.update(db)
        }
    }

    private static func validateOperationUndo(_ entry: MailOperationUndoEntry, db: Database) throws {
        let expected = entry.after
        guard let current = try MailMessageRow.fetchOne(db, key: entry.id.uuidString)?.toMessage(),
              let account = try MailAccountRow.fetchOne(db, key: expected.account.id.uuidString)?.toAccount(),
              sameFolderMutationAccount(account, expected.account),
              current.accountId == expected.message.accountId, current.folderId == expected.message.folderId,
              current.uid == expected.message.uid, current.messageId == expected.message.messageId,
              current.subject == expected.message.subject, current.fromAddress == expected.message.fromAddress,
              current.date == expected.message.date else { throw MailMoveReviewError.changed }
        if current.uid < localUIDFloor {
            guard account.isEnabled, entry.before.folder.uidValidity != nil, entry.after.folder.uidValidity != nil,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_folder_mutations WHERE accountID=? AND state IN ('prepared','sent','acknowledged','unknown'))", arguments: [account.id.uuidString]) != true else { throw MailMoveReviewError.changed }
        }
        for expectedFolder in [entry.before.folder, entry.after.folder] {
            guard let folder = try MailFolderRow.fetchOne(db, key: expectedFolder.id.uuidString)?.toFolder(),
                  folder.accountId == account.id, !folder.isContainer,
                  Data(folder.path.utf8) == Data(expectedFolder.path.utf8), folder.uidValidity == expectedFolder.uidValidity else { throw MailMoveReviewError.changed }
        }
        switch entry.action {
        case .read: guard current.isRead == expected.message.isRead else { throw MailMoveReviewError.changed }
        case .star: guard current.isStarred == expected.message.isStarred else { throw MailMoveReviewError.changed }
        case .move, .moveToRole: break
        case .permanentlyDelete: throw MailMoveReviewError.changed
        }
    }
}
