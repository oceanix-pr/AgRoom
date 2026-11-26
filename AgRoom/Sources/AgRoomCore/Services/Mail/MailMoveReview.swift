import Foundation
import GRDB
import MailFoundation

public enum MailFolderPath {
    public static func display(_ folder: MailFolder, isLocalArchive: Bool) -> String {
        isLocalArchive ? folder.path : ImapMailboxEncoding.decode(folder.path)
    }
}

public enum MailMoveReviewError: String, Error, Sendable {
    case empty, unavailable, mixedAccounts, noDestination, changed
}

/// An owned read-only review. Message flags may change while the chooser is open;
/// message identity, source mailbox and destination identity must still match.
public struct MailMoveReview: Sendable {
    // Ephemeral, never serialized. Even a restored database with identical UUIDs
    // cannot reuse a review created for a different physical space connection.
    fileprivate let originQueue: DatabaseQueue
    public let account: MailAccount
    public let messages: [MailMessage]
    public let folders: [MailFolder]
    public let sources: [MailFolder]
    public let destinations: [MailFolder]
}

extension MailService {
    public func reviewMove(messageIDs: [UUID]) async throws -> MailMoveReview {
        let ids = Array(Set(messageIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { throw MailMoveReviewError.empty }
        let queue = databaseQueue
        return try await databaseQueue.read { db in
            let messages = try ids.map { id in
                guard let message = try MailMessageRow.fetchOne(db, key: id.uuidString)?.toMessage() else { throw MailMoveReviewError.unavailable }
                return message
            }
            let owner = messages[0].accountId
            guard messages.allSatisfy({ $0.accountId == owner }) else { throw MailMoveReviewError.mixedAccounts }
            guard let account = try MailAccountRow.fetchOne(db, key: owner.uuidString)?.toAccount() else { throw MailMoveReviewError.unavailable }
            if !account.isLocalArchive && !account.isEnabled && messages.contains(where: { $0.uid < Self.localUIDFloor }) { throw MailSyncError.accountDisabled }
            let folders = try MailFolderRow.filter(Column("accountId") == owner.uuidString).order(Column("path")).fetchAll(db).compactMap { $0.toFolder() }
            let sourceIDs = Set(messages.map(\.folderId))
            let sources = folders.filter { sourceIDs.contains($0.id) }
            guard sources.count == sourceIDs.count, sources.allSatisfy({ !$0.isContainer }) else { throw MailMoveReviewError.unavailable }
            let destinations = folders.filter { folder in !folder.isContainer && !messages.allSatisfy { $0.folderId == folder.id } }
            guard !destinations.isEmpty else { throw MailMoveReviewError.noDestination }
            return MailMoveReview(originQueue: queue, account: account, messages: messages, folders: folders, sources: sources, destinations: destinations)
        }
    }

    /// Called before submitting the chooser, and again per message inside its account lease.
    public func validateMove(_ review: MailMoveReview, destinationID: UUID, messageID: UUID? = nil) async throws {
        guard review.originQueue === databaseQueue else { throw MailMoveReviewError.changed }
        try await databaseQueue.read { db in
            guard let account = try MailAccountRow.fetchOne(db, key: review.account.id.uuidString)?.toAccount(),
                  account.sourceKind == review.account.sourceKind,
                  account.imapHost == review.account.imapHost, account.imapPort == review.account.imapPort,
                  account.imapSecurity == review.account.imapSecurity, account.username == review.account.username,
                  account.authKind == review.account.authKind,
                  let expectedTarget = review.destinations.first(where: { $0.id == destinationID }),
                  let target = try MailFolderRow.fetchOne(db, key: destinationID.uuidString)?.toFolder(),
                  target.accountId == account.id, !target.isContainer, target.path == expectedTarget.path,
                  target.uidValidity == expectedTarget.uidValidity else { throw MailMoveReviewError.changed }
            let messages = messageID.map { id in review.messages.filter { $0.id == id } } ?? review.messages
            guard !messages.isEmpty else { throw MailMoveReviewError.changed }
            for expected in messages {
                guard let current = try MailMessageRow.fetchOne(db, key: expected.id.uuidString)?.toMessage(),
                      current.accountId == account.id, current.accountId == expected.accountId,
                      current.folderId == expected.folderId, current.uid == expected.uid, current.messageId == expected.messageId,
                      let source = try MailFolderRow.fetchOne(db, key: current.folderId.uuidString)?.toFolder(),
                      let previous = review.sources.first(where: { $0.id == source.id }),
                      source.accountId == account.id, !source.isContainer, source.path == previous.path,
                      source.uidValidity == previous.uidValidity else { throw MailMoveReviewError.changed }
                if !account.isLocalArchive && !account.isEnabled && current.uid < Self.localUIDFloor { throw MailSyncError.accountDisabled }
            }
        }
    }
}
