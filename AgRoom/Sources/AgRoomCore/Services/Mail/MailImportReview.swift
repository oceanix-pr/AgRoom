import CryptoKit
import Foundation
import GRDB

public struct MailImportIdentity: Codable, Sendable, Equatable {
    public let folder: String
    public let sha256: String
    public let byteCount: Int
    public init(folder: String, sha256: String, byteCount: Int) {
        self.folder = folder; self.sha256 = sha256; self.byteCount = byteCount
    }
}

public enum MailImportDuplicateMatch: Sendable, Equatable { case existing(UUID), candidate(UUID) }

public struct MailImportBatchContext: Sendable, Equatable {
    public let id: UUID
    public let accountID: UUID
    public let createdAt: Date
}

public struct MailImportResolvedMessage: Sendable {
    public let message: MailMessage
    public let folder: MailFolder
    public let archiveName: String
    public let data: Data
}

public struct MailImportInspection: Sendable {
    public let envelope: MailImportedEnvelope
    public let body: RemoteMessageBody
}

extension MailImportReader {
    /// Parse an owned original for a read-only preview. No database, credentials,
    /// attachment files or external resources are accessed here.
    public static func inspect(_ data: Data) throws -> MailImportInspection {
        try Task.checkCancellation()
        let envelope = try MailFoundationAdapter.importedEnvelope(data)
        let body = try MailFoundationAdapter.importedBody(data)
        try Task.checkCancellation()
        return .init(envelope: envelope, body: body)
    }
}

extension MailService {
    static func createImportReviewSchema(_ db: Database) throws {
        try db.create(index: "mail_import_origin_batch", on: "mail_import_origins", columns: ["accountID", "batchID", "messageID"], options: .ifNotExists)
    }

    static func validateImportIdentity(_ identity: MailImportIdentity?) throws {
        guard let identity else { return }
        guard identity.folder.utf8.count <= 8192, !identity.folder.contains("\0"),
              identity.sha256.count == 64, identity.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              identity.byteCount > 0, identity.byteCount <= rawMessageByteLimit else { throw MailImportError.invalidMessage }
    }

    public func importBatchContext(batchID: UUID, archiveID: UUID) async throws -> MailImportBatchContext {
        try await databaseQueue.read { db in
            guard try MailAccountRow.fetchOne(db, key: archiveID.uuidString)?.sourceKind == MailAccountSource.localArchive.rawValue,
                  let row = try Row.fetchOne(db, sql: "SELECT createdAt FROM mail_import_batches WHERE id=? AND accountID=?", arguments: [batchID.uuidString, archiveID.uuidString]) else { throw MailImportError.changed }
            return .init(id: batchID, accountID: archiveID, createdAt: row["createdAt"])
        }
    }

    public func importDuplicate(candidate: MailImportCandidate, archiveID: UUID) async throws -> MailImportResolvedMessage {
        try await importDuplicate(candidate: candidate.metadata, archiveID: archiveID)
    }

    public func importDuplicate(candidate: MailImportMetadata, archiveID: UUID) async throws -> MailImportResolvedMessage {
        let identity = candidate.identity
        try Self.validateImportIdentity(identity)
        return try await databaseQueue.read { db in
            guard let id = try String.fetchOne(db, sql: "SELECT messageID FROM mail_import_origins WHERE accountID=? AND folderPath=? AND sha256=?", arguments: [archiveID.uuidString, identity.folder, identity.sha256]).flatMap(UUID.init(uuidString:)) else { throw MailImportError.changed }
            return try Self.resolveImportMessage(id, archiveID: archiveID, identity: identity, createdIn: nil, db: db)
        }
    }

    public func importResultMessage(batchID: UUID, archiveID: UUID, itemID: UUID) async throws -> MailImportResolvedMessage {
        try await databaseQueue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM mail_import_batches WHERE id=? AND accountID=?", arguments: [batchID.uuidString, archiveID.uuidString]) else { throw MailImportError.changed }
            let batch = try JSONDecoder().decode(MailImportBatch.self, from: data)
            guard batch.id == batchID, batch.accountID == archiveID else { throw MailImportError.changed }
            var result = batch.results.first { $0.id == itemID }
            if batch.state == .running || batch.state == .interrupted,
               let entry = try Data.fetchOne(db, sql: "SELECT payload FROM mail_import_entries WHERE batchID=? AND id=?", arguments: [batchID.uuidString, itemID.uuidString]) {
                result = try JSONDecoder().decode(MailImportResult.self, from: entry)
            }
            guard let result, result.id == itemID, let id = result.messageID,
                  result.status == .imported || (result.status == .duplicate && result.originalIdentity != nil) else { throw MailImportError.changed }
            return try Self.resolveImportMessage(id, archiveID: archiveID, identity: result.originalIdentity,
                createdIn: result.status == .imported ? batchID : nil, db: db)
        }
    }

    private static func resolveImportMessage(_ id: UUID, archiveID: UUID, identity: MailImportIdentity?, createdIn batchID: UUID?, db: Database) throws -> MailImportResolvedMessage {
        try validateImportIdentity(identity)
        guard let archive = try MailAccountRow.fetchOne(db, key: archiveID.uuidString), archive.sourceKind == MailAccountSource.localArchive.rawValue,
              let message = try MailMessageRow.fetchOne(db, key: id.uuidString)?.toMessage(), message.accountId == archiveID,
              let folder = try MailFolderRow.fetchOne(db, key: message.folderId.uuidString)?.toFolder(), folder.accountId == archiveID,
              let origin = try Row.fetchOne(db, sql: "SELECT folderPath,sha256,batchID FROM mail_import_origins WHERE messageID=? AND accountID=?", arguments: [id.uuidString, archiveID.uuidString]),
              let raw = try Row.fetchOne(db, sql: "SELECT data FROM mail_raw_messages WHERE messageID=? AND kind=?", arguments: [id.uuidString, MailRawKind.imported.rawValue]) else { throw MailImportError.changed }
        let data: Data = raw["data"], hash: String = origin["sha256"], path: String = origin["folderPath"]
        guard !data.isEmpty, data.count <= rawMessageByteLimit,
              batchID.map({ (origin["batchID"] as String) == $0.uuidString }) ?? true,
              identity.map({ $0.folder == path && $0.sha256 == hash && $0.byteCount == data.count }) ?? true,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { throw MailImportError.changed }
        return .init(message: message, folder: folder, archiveName: archive.displayName, data: data)
    }
}
