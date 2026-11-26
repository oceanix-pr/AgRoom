import CryptoKit
import Foundation
import GRDB
import MailFoundation

public enum MailFolderMutationError: String, Error, Codable, Sendable {
    case unavailable, invalidName, duplicate, protectedFolder, hierarchy, changed, capacity, pending, unknown, unsupported, identityUnavailable
}

public enum MailFolderMutationKind: String, Codable, Sendable { case create, rename, delete }

public struct MailFolderInventory: Codable, Sendable, Equatable {
    public let count: Int
    public let digest: String
}

/// Portable intent and receipts contain no password, external file access grant or
/// executable continuation. Restoring one never replays its remote command.
public struct MailFolderMutation: Codable, Sendable, Equatable {
    public let id: UUID
    public let account: MailAccount
    public let kind: MailFolderMutationKind
    public let rootID: UUID
    public let parent: MailFolder?
    /// Descendants precede their parents, so deletion is explicit and bottom-up.
    public let before: [MailFolder]
    public let after: [MailFolder]
    public let inventories: [UUID: MailFolderInventory]
    public let createdAt: Date
    public var cachedMessageCount: Int {
        inventories.values.reduce(0) { count, item in let sum = count.addingReportingOverflow(item.count); return sum.overflow ? Int.max : sum.partialValue }
    }
    public var completionIDs: Set<UUID> { Set((kind == .create ? after : before).map(\.id)) }
}

public struct MailFolderMutationPlan: Sendable {
    fileprivate let originQueue: DatabaseQueue
    public let mutation: MailFolderMutation
}

public struct MailFolderMutationRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Proof: String, Codable, Sendable { case server, reviewed }
    public enum State: String, Codable, Sendable {
        case prepared, sent, acknowledged, unknown, complete, failed, cancelled
        public var isPending: Bool { self == .prepared || self == .sent || self == .acknowledged || self == .unknown }
    }
    public var id: UUID { mutation.id }
    public let mutation: MailFolderMutation
    public var state: State = .prepared
    public var activeFolderID: UUID?
    public var completedFolderIDs: [UUID] = []
    public var error: MailFolderMutationError?
    public var serverStatuses: [UUID: RemoteFolderStatus]? = nil
    public var resolvedAfter: [MailFolder]? = nil
    public var activeProof: Proof? = nil
    public var completedProofs: [UUID: Proof]? = nil

    public var nextFolderID: UUID? {
        switch mutation.kind {
        case .create, .rename: completedFolderIDs.isEmpty ? mutation.rootID : nil
        case .delete: mutation.before.first { !completedFolderIDs.contains($0.id) }?.id
        }
    }
}

extension MailService {
    static let folderMutationByteLimit = 8 * 1024 * 1024
    static func createFolderMutationSchema(_ db: Database) throws {
        try db.create(table: "mail_folder_mutations", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("accountID", .text).notNull().references("mail_accounts", onDelete: .cascade)
            t.column("createdAt", .datetime).notNull()
            t.column("state", .text).notNull()
            t.column("payload", .blob).notNull()
        }
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS mail_folder_mutation_pending ON mail_folder_mutations(accountID) WHERE state IN ('prepared','sent','acknowledged','unknown')")
    }

    public func reviewFolderMutation(accountID: UUID, kind: MailFolderMutationKind,
                                     folderID: UUID? = nil, parentID: UUID? = nil, name: String = "") async throws -> MailFolderMutationPlan {
        let queue = databaseQueue
        return try await databaseQueue.read { db in
            try Self.requireNoPendingFolderMutation(accountID, db: db)
            guard let account = try MailAccountRow.fetchOne(db, key: accountID.uuidString)?.toAccount() else { throw MailFolderMutationError.unavailable }
            if !account.isLocalArchive && !account.isEnabled { throw MailSyncError.accountDisabled }
            let folders = try MailFolderRow.filter(Column("accountId") == accountID.uuidString).fetchAll(db).compactMap { $0.toFolder() }
            let root = folderID.flatMap { id in folders.first { $0.id == id } }
            let parent: MailFolder?
            var before: [MailFolder] = [], after: [MailFolder] = []
            if kind == .create {
                parent = parentID.flatMap { id in folders.first { $0.id == id } }
                if parentID != nil && parent == nil { throw MailFolderMutationError.changed }
                let separator: String?
                if account.isLocalArchive { separator = "/" }
                else if let parent { separator = parent.delimiter }
                else { separator = Self.commonFolderDelimiter(folders) }
                if parent != nil && separator == nil { throw MailFolderMutationError.hierarchy }
                let leaf = try Self.folderLeaf(name, separator: separator)
                let path = parent.map { $0.path + (separator ?? "") } ?? ""
                let encoded = account.isLocalArchive ? leaf : ImapMailboxEncoding.encode(leaf)
                after = [.init(accountId: accountID, path: path + encoded, name: leaf, parentPath: parent?.path, delimiter: separator)]
            } else {
                guard let root else { throw MailFolderMutationError.unavailable }
                before = try Self.folderSubtree(root, folders: folders)
                guard before.allSatisfy({ $0.role == .other && $0.path.caseInsensitiveCompare("INBOX") != .orderedSame }) else { throw MailFolderMutationError.protectedFolder }
                parent = root.parentPath.flatMap { path in folders.first { $0.path == path } }
                if root.parentPath != nil && parent == nil { throw MailFolderMutationError.hierarchy }
                if kind == .rename {
                    let separator = account.isLocalArchive ? "/" : (root.delimiter ?? Self.commonFolderDelimiter(before))
                    let leaf = try Self.folderLeaf(name, separator: separator)
                    let prefix = try Self.folderRenamePrefix(root, parent: parent, separator: separator)
                    let newPath = prefix + (account.isLocalArchive ? leaf : ImapMailboxEncoding.encode(leaf))
                    guard newPath != root.path else { throw MailFolderMutationError.duplicate }
                    after = try before.map { old in
                        var updated = old
                        if old.id == root.id { updated.path = newPath; updated.name = leaf }
                        else {
                            guard let separator, old.path.hasPrefix(root.path + separator) else { throw MailFolderMutationError.hierarchy }
                            updated.path = newPath + old.path.dropFirst(root.path.count)
                        }
                        if let oldParent = old.parentPath, old.id != root.id {
                            guard oldParent == root.path || (separator.map { oldParent.hasPrefix(root.path + $0) } ?? false) else { throw MailFolderMutationError.hierarchy }
                            updated.parentPath = newPath + oldParent.dropFirst(root.path.count)
                        }
                        return updated
                    }
                }
            }
            let ignored = Set(before.map(\.id))
            guard !after.contains(where: { changed in
                changed.path.caseInsensitiveCompare("INBOX") == .orderedSame || folders.contains { !ignored.contains($0.id) && $0.path == changed.path }
            }) else { throw MailFolderMutationError.duplicate }
            let inventories = try Dictionary(uniqueKeysWithValues: before.map { ($0.id, try Self.folderInventory($0.id, db: db)) })
            let mutation = MailFolderMutation(id: UUID(), account: account, kind: kind, rootID: root?.id ?? after[0].id,
                parent: parent, before: before, after: after, inventories: inventories, createdAt: Date())
            try Self.validateFolderMutation(mutation)
            return MailFolderMutationPlan(originQueue: queue, mutation: mutation)
        }
    }

    /// Local archive edits are one transaction, including deletion's full inventory
    /// check. No credential or protocol client is needed for any local edit.
    public func applyLocalFolderMutation(_ plan: MailFolderMutationPlan) async throws -> MailFolderMutationRecord {
        guard plan.originQueue === databaseQueue, plan.mutation.account.isLocalArchive else { throw MailFolderMutationError.changed }
        try Task.checkCancellation()
        return try await databaseQueue.maintenanceWrite { db in
            try Self.validateFolderMutationCurrent(plan.mutation, db: db, checkInventory: plan.mutation.kind == .delete)
            try Self.applyFolderMutation(plan.mutation, deleting: nil, db: db)
            return MailFolderMutationRecord(mutation: plan.mutation, state: .complete, completedFolderIDs: plan.mutation.completionIDs.sorted { $0.uuidString < $1.uuidString })
        }
    }

    public func folderMutationHistory(accountID: UUID, limit: Int = 50) async throws -> [MailFolderMutationRecord] {
        try await databaseQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id,length(payload) AS bytes FROM mail_folder_mutations WHERE accountID=? ORDER BY createdAt DESC,id LIMIT ?", arguments: [accountID.uuidString, min(max(limit, 1), 100)])
            var result: [MailFolderMutationRecord] = [], bytes = 0
            for row in rows {
                let size: Int = row["bytes"]
                guard size > 0, size <= Self.folderMutationByteLimit, let id = UUID(uuidString: row["id"]) else { throw MailFolderMutationError.changed }
                if size > 16 * 1024 * 1024 - bytes { break }
                let record = try Self.folderMutationRecord(id, db: db)
                guard record.mutation.account.id == accountID else { throw MailFolderMutationError.changed }
                result.append(record); bytes += size
            }
            return result
        }
    }

    func beginFolderMutation(_ plan: MailFolderMutationPlan, serverStatuses: [UUID: RemoteFolderStatus]? = nil) async throws -> MailFolderMutationRecord {
        guard plan.originQueue === databaseQueue, !plan.mutation.account.isLocalArchive else { throw MailFolderMutationError.changed }
        try Task.checkCancellation()
        return try await databaseQueue.maintenanceWrite { db in
            try Self.requireNoPendingFolderMutation(plan.mutation.account.id, db: db)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_folder_mutations WHERE id=?)", arguments: [plan.mutation.id.uuidString]) != true else { throw MailFolderMutationError.changed }
            try Self.validateFolderMutationCurrent(plan.mutation, db: db, checkInventory: false)
            let record = MailFolderMutationRecord(mutation: plan.mutation, serverStatuses: serverStatuses)
            try Self.saveFolderMutation(record, db: db)
            return record
        }
    }

    func markFolderMutationSent(id: UUID, folderID: UUID) async throws -> MailFolderMutationRecord {
        try Task.checkCancellation()
        return try await databaseQueue.maintenanceWrite { db in
            var record = try Self.folderMutationRecord(id, db: db)
            guard record.state == .prepared, record.nextFolderID == folderID else { throw MailFolderMutationError.changed }
            record.activeFolderID = folderID; record.state = .sent; record.error = nil
            try Self.saveFolderMutation(record, db: db); return record
        }
    }

    func acknowledgeFolderMutation(id: UUID, resolvedAfter: [MailFolder]? = nil, proof: MailFolderMutationRecord.Proof = .server) async throws -> MailFolderMutationRecord {
        try await databaseQueue.maintenanceWrite { db in
            var record = try Self.folderMutationRecord(id, db: db)
            guard record.state == .sent || record.state == .acknowledged || (record.state == .unknown && proof == .reviewed) else { throw MailFolderMutationError.changed }
            record.state = .acknowledged
            record.error = nil
            record.activeProof = proof
            if let resolvedAfter { record.resolvedAfter = resolvedAfter }
            try Self.saveFolderMutation(record, db: db); return record
        }
    }

    /// The remote OK has already been durably recorded. Never replay it if local
    /// reconciliation fails; the acknowledged intent remains available to review.
    func commitFolderMutationStep(id: UUID, resetInventories: [UUID: MailFolderInventory] = [:]) async throws -> MailFolderMutationRecord {
        try await databaseQueue.maintenanceWrite { db in
            var record = try Self.folderMutationRecord(id, db: db)
            guard record.state == .acknowledged, let active = record.activeFolderID, active == record.nextFolderID else { throw MailFolderMutationError.changed }
            if !resetInventories.isEmpty {
                guard record.mutation.kind == .rename else { throw MailFolderMutationError.changed }
                for (folderID, expected) in resetInventories {
                    guard record.mutation.before.contains(where: { $0.id == folderID }), try Self.folderInventory(folderID, db: db, serverOnly: true) == expected else { throw MailFolderMutationError.changed }
                }
            }
            if record.mutation.kind == .delete {
                try Self.validateFolderMutationCurrent(record.mutation, db: db, checkInventory: false, completed: Set(record.completedFolderIDs))
                try Self.applyFolderMutation(record.mutation, deleting: active, db: db)
                record.completedFolderIDs.append(active)
                record.completedProofs = (record.completedProofs ?? [:]).merging([active: record.activeProof ?? .reviewed]) { _, new in new }
            } else {
                try Self.validateFolderMutationCurrent(record.mutation, db: db, checkInventory: false)
                try Self.applyFolderMutation(record.mutation, deleting: nil, afterOverride: record.resolvedAfter, db: db)
                for folderID in resetInventories.keys {
                    // Generated originals may already have been matched to a server
                    // UID by normal sync. Preserve them as local copies before reset.
                    let generated = try String.fetchAll(db, sql: "SELECT m.id FROM mail_messages m JOIN mail_raw_messages r ON r.messageID=m.id WHERE m.folderId=? AND m.uid<? AND r.kind=? ORDER BY m.id", arguments: [folderID.uuidString, Int64(Self.localUIDFloor), MailRawKind.generated.rawValue])
                    var next = max(Int64(Self.localUIDFloor) - 1, try Int64.fetchOne(db, sql: "SELECT max(uid) FROM mail_messages WHERE folderId=?", arguments: [folderID.uuidString]) ?? 0)
                    for id in generated {
                        guard next < Int64(UInt32.max) else { throw MailFolderMutationError.capacity }; next += 1
                        try db.execute(sql: "UPDATE mail_messages SET uid=? WHERE id=?", arguments: [next, id])
                        try db.execute(sql: "DELETE FROM mail_pending_flags WHERE messageID=?", arguments: [id])
                    }
                    let messages = try String.fetchAll(db, sql: "SELECT id FROM mail_messages WHERE folderId=? AND uid<?", arguments: [folderID.uuidString, Int64(Self.localUIDFloor)])
                    for message in messages { if let id = UUID(uuidString: message) { try Self.deleteMessageContents(messageId: id, in: db) } }
                    try db.execute(sql: "DELETE FROM mail_messages WHERE folderId=? AND uid<?", arguments: [folderID.uuidString, Int64(Self.localUIDFloor)])
                    try db.execute(sql: "DELETE FROM mail_sync_coverage WHERE folderID=?", arguments: [folderID.uuidString])
                    try db.execute(sql: "UPDATE mail_folders SET uidValidity=NULL,uidNext=NULL,lastSyncAt=NULL,unreadCount=(SELECT count(*) FROM mail_messages WHERE folderId=? AND isRead=0),totalCount=(SELECT count(*) FROM mail_messages WHERE folderId=?) WHERE id=?", arguments: [folderID.uuidString, folderID.uuidString, folderID.uuidString])
                }
                record.completedFolderIDs = record.mutation.completionIDs.sorted { $0.uuidString < $1.uuidString }
                record.completedProofs = Dictionary(uniqueKeysWithValues: record.completedFolderIDs.map { ($0, record.activeProof ?? .reviewed) })
            }
            record.activeFolderID = nil
            record.activeProof = nil
            record.state = record.nextFolderID == nil ? .complete : .prepared
            try Self.saveFolderMutation(record, db: db)
            return record
        }
    }

    func failFolderMutation(id: UUID, definitelyRejected: Bool, cancelled: Bool = false) async throws -> MailFolderMutationRecord {
        try await databaseQueue.maintenanceWrite { db in
            var record = try Self.folderMutationRecord(id, db: db)
            guard record.state.isPending else { return record }
            if record.state == .acknowledged || record.state == .unknown { return record }
            if record.state == .prepared || definitelyRejected {
                record.state = cancelled ? .cancelled : .failed
                record.error = cancelled ? nil : .unavailable
            } else { record.state = .unknown; record.error = .unknown }
            try Self.saveFolderMutation(record, db: db); return record
        }
    }

    func requireNoPendingFolderMutation(_ accountID: UUID) async throws {
        try await databaseQueue.read { try Self.requireNoPendingFolderMutation(accountID, db: $0) }
    }

    func validateFolderMutationPlan(_ plan: MailFolderMutationPlan) async throws {
        guard plan.originQueue === databaseQueue else { throw MailFolderMutationError.changed }
        try await databaseQueue.read { try Self.validateFolderMutationCurrent(plan.mutation, db: $0, checkInventory: plan.mutation.kind == .delete) }
    }

    public func pendingFolderMutation(accountID: UUID) async throws -> MailFolderMutationRecord? {
        try await databaseQueue.read { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT id FROM mail_folder_mutations WHERE accountID=? AND state IN ('prepared','sent','acknowledged','unknown')", arguments: [accountID.uuidString]),
                  let id = UUID(uuidString: raw) else { return nil }
            let record = try Self.folderMutationRecord(id, db: db)
            guard record.mutation.account.id == accountID else { throw MailFolderMutationError.changed }
            return record
        }
    }

    func validateFolderMutationRecordCurrent(_ expected: MailFolderMutationRecord) async throws {
        try await databaseQueue.read { db in
            guard try Self.folderMutationRecord(expected.id, db: db) == expected else { throw MailFolderMutationError.changed }
            try Self.validateFolderMutationCurrent(expected.mutation, db: db, checkInventory: false, completed: Set(expected.completedFolderIDs), allowDisabled: true)
        }
    }

    func folderMutationInventories(_ ids: [UUID], serverOnly: Bool = false) async throws -> [UUID: MailFolderInventory] {
        try await databaseQueue.read { db in try Dictionary(uniqueKeysWithValues: ids.map { ($0, try Self.folderInventory($0, db: db, serverOnly: serverOnly)) }) }
    }

    /// Only an explicit, freshly verified recovery choice may release an unknown
    /// intent. This ends the record without transmitting any command.
    func endFolderMutationReview(_ expected: MailFolderMutationRecord) async throws -> MailFolderMutationRecord {
        try await databaseQueue.maintenanceWrite { db in
            var record = try Self.folderMutationRecord(expected.id, db: db)
            guard record == expected, record.state.isPending else { throw MailFolderMutationError.changed }
            try Self.validateFolderMutationCurrent(record.mutation, db: db, checkInventory: false, completed: Set(record.completedFolderIDs), allowDisabled: true)
            record.state = .cancelled; record.activeFolderID = nil
            record.activeProof = nil
            try Self.saveFolderMutation(record, db: db); return record
        }
    }

    static func requireNoPendingFolderMutation(_ accountID: UUID, db: Database) throws {
        guard try db.tableExists("mail_folder_mutations") else { return }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_folder_mutations WHERE accountID=? AND state IN ('prepared','sent','acknowledged','unknown'))", arguments: [accountID.uuidString]) == true { throw MailFolderMutationError.pending }
    }

    func requireFolderLocation(_ expected: MailFolder) async throws {
        try await databaseQueue.read { try Self.requireFolderLocation(expected, db: $0) }
    }

    /// Check inside each cache transaction as well as before the network read.
    /// Another process may finish a rename while that read is still in flight.
    static func requireFolderLocation(_ expected: MailFolder, db: Database) throws {
        try requireNoPendingFolderMutation(expected.accountId, db: db)
        guard let current = try MailFolderRow.fetchOne(db, key: expected.id.uuidString)?.toFolder(),
              current.accountId == expected.accountId, current.path == expected.path, !current.isContainer else { throw MailFolderMutationError.changed }
    }

    public static func sameFolderMutationAccount(_ lhs: MailAccount, _ rhs: MailAccount) -> Bool {
        lhs.id == rhs.id && lhs.sourceKind == rhs.sourceKind && lhs.imapHost == rhs.imapHost && lhs.imapPort == rhs.imapPort
            && lhs.imapSecurity == rhs.imapSecurity && lhs.username == rhs.username && lhs.authKind == rhs.authKind
    }

    private static func commonFolderDelimiter(_ folders: [MailFolder]) -> String? {
        let delimiters = Set(folders.compactMap(\.delimiter).filter { !$0.isEmpty })
        return delimiters.count == 1 ? delimiters.first : nil
    }

    private static func folderLeaf(_ value: String, separator: String?) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 240, name != ".", name != "..", name.rangeOfCharacter(from: .controlCharacters) == nil,
              !(separator.map { name.contains($0) } ?? false) else { throw MailFolderMutationError.invalidName }
        return name
    }

    private static func folderRenamePrefix(_ root: MailFolder, parent: MailFolder?, separator: String?) throws -> String {
        if let parent {
            guard let separator, root.path.hasPrefix(parent.path + separator) else { throw MailFolderMutationError.hierarchy }
            return parent.path + separator
        }
        // Imported roots carry an opaque "import/" namespace while remaining
        // top-level sidebar nodes. Rename their leaf without dropping that prefix.
        if let separator, let range = root.path.range(of: separator, options: .backwards) { return String(root.path[..<range.upperBound]) }
        return ""
    }

    private static func folderSubtree(_ root: MailFolder, folders: [MailFolder]) throws -> [MailFolder] {
        var result = [root], seen: Set<UUID> = [root.id], index = 0
        let children = Dictionary(grouping: folders) { $0.parentPath }
        while index < result.count {
            for child in children[result[index].path] ?? [] {
                guard seen.insert(child.id).inserted else { throw MailFolderMutationError.hierarchy }
                result.append(child)
                guard result.count <= 2_048 else { throw MailFolderMutationError.capacity }
            }
            index += 1
        }
        if let parent = root.parentPath, result.contains(where: { $0.path == parent }) { throw MailFolderMutationError.hierarchy }
        return Array(result.reversed())
    }

    private static func folderInventory(_ id: UUID, db: Database, serverOnly: Bool = false) throws -> MailFolderInventory {
        let cursor = try Row.fetchCursor(db, sql: "SELECT id,uid,messageId FROM mail_messages WHERE folderId=? AND (?=0 OR (uid<? AND NOT EXISTS(SELECT 1 FROM mail_raw_messages r WHERE r.messageID=mail_messages.id AND r.kind=?))) ORDER BY id", arguments: [id.uuidString, serverOnly, Int64(localUIDFloor), MailRawKind.generated.rawValue])
        var digest = SHA256(), count = 0
        while let row = try cursor.next() {
            let identity: [String?] = [row["id"], String(row["uid"] as Int64), row["messageId"]]
            digest.update(data: try JSONEncoder().encode(identity)); count += 1
        }
        return .init(count: count, digest: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func validateFolderMutation(_ mutation: MailFolderMutation) throws {
        let folders = mutation.before + mutation.after + (mutation.parent.map { [$0] } ?? [])
        guard mutation.createdAt.timeIntervalSince1970.isFinite, mutation.before.count <= 2_048, mutation.after.count <= 2_048,
              folders.allSatisfy({ $0.accountId == mutation.account.id && !$0.path.isEmpty && $0.path.utf8.count <= 8_192 && $0.path.rangeOfCharacter(from: .controlCharacters) == nil }),
              Set(mutation.before.map(\.id)).count == mutation.before.count, Set(mutation.after.map(\.id)).count == mutation.after.count,
              Set(mutation.before.map(\.path)).count == mutation.before.count, Set(mutation.after.map(\.path)).count == mutation.after.count,
              mutation.inventories.keys.allSatisfy({ id in mutation.before.contains { $0.id == id } }),
              mutation.before.allSatisfy({ mutation.inventories[$0.id] != nil }),
              mutation.inventories.values.allSatisfy({ $0.count >= 0 && $0.digest.count == 64 && $0.digest.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) } }) else { throw MailFolderMutationError.changed }
        var count = 0
        for inventory in mutation.inventories.values {
            let sum = count.addingReportingOverflow(inventory.count)
            guard !sum.overflow else { throw MailFolderMutationError.capacity }; count = sum.partialValue
        }
        if mutation.kind != .create {
            guard let root = mutation.before.last, root.id == mutation.rootID, root.parentPath == mutation.parent?.path,
                  Set(try folderSubtree(root, folders: mutation.before).map(\.id)) == Set(mutation.before.map(\.id)) else { throw MailFolderMutationError.hierarchy }
            let positions = Dictionary(uniqueKeysWithValues: mutation.before.enumerated().map { ($0.element.path, $0.offset) })
            for (index, folder) in mutation.before.enumerated() where folder.id != root.id {
                guard let parent = folder.parentPath, let position = positions[parent], position > index else { throw MailFolderMutationError.hierarchy }
            }
        }
        switch mutation.kind {
        case .create:
            guard mutation.before.isEmpty, mutation.after.count == 1, mutation.after[0].id == mutation.rootID, mutation.after[0].role == .other,
                  !mutation.after[0].isContainer, mutation.after[0].parentPath == mutation.parent?.path else { throw MailFolderMutationError.changed }
            let folder = mutation.after[0], separator = folder.delimiter
            if mutation.parent != nil && separator == nil { throw MailFolderMutationError.hierarchy }
            let leaf = try folderLeaf(folder.name, separator: separator)
            let path = (mutation.parent.map { $0.path + (separator ?? "") } ?? "") + (mutation.account.isLocalArchive ? leaf : ImapMailboxEncoding.encode(leaf))
            guard folder.path == path, folder.path.caseInsensitiveCompare("INBOX") != .orderedSame,
                  folder.uidValidity == nil, folder.uidNext == nil, folder.lastSyncAt == nil, folder.totalCount == 0, folder.unreadCount == 0 else { throw MailFolderMutationError.changed }
        case .rename:
            guard !mutation.before.isEmpty, mutation.before.contains(where: { $0.id == mutation.rootID }),
                  Set(mutation.before.map(\.id)) == Set(mutation.after.map(\.id)), mutation.before.allSatisfy({ $0.role == .other && $0.path.caseInsensitiveCompare("INBOX") != .orderedSame }),
                  mutation.after.allSatisfy({ $0.role == .other }) else { throw MailFolderMutationError.protectedFolder }
            guard let root = mutation.before.last, let updatedRoot = mutation.after.first(where: { $0.id == root.id }) else { throw MailFolderMutationError.changed }
            let separator = mutation.account.isLocalArchive ? "/" : (root.delimiter ?? commonFolderDelimiter(mutation.before))
            let leaf = try folderLeaf(updatedRoot.name, separator: separator)
            let path = try folderRenamePrefix(root, parent: mutation.parent, separator: separator) + (mutation.account.isLocalArchive ? leaf : ImapMailboxEncoding.encode(leaf))
            guard path == updatedRoot.path, path != root.path, path.caseInsensitiveCompare("INBOX") != .orderedSame else { throw MailFolderMutationError.changed }
            for previous in mutation.before {
                guard let updated = mutation.after.first(where: { $0.id == previous.id }) else { throw MailFolderMutationError.changed }
                var expected = previous
                if previous.id == root.id { expected.path = path; expected.name = leaf }
                else {
                    guard let separator, previous.path.hasPrefix(root.path + separator), let parent = previous.parentPath,
                          parent == root.path || parent.hasPrefix(root.path + separator) else { throw MailFolderMutationError.hierarchy }
                    expected.path = path + previous.path.dropFirst(root.path.count)
                    expected.parentPath = path + parent.dropFirst(root.path.count)
                }
                guard expected == updated else { throw MailFolderMutationError.changed }
            }
        case .delete:
            guard !mutation.before.isEmpty, mutation.before.contains(where: { $0.id == mutation.rootID }), mutation.after.isEmpty,
                  mutation.before.allSatisfy({ $0.role == .other && $0.path.caseInsensitiveCompare("INBOX") != .orderedSame }) else { throw MailFolderMutationError.protectedFolder }
        }
        guard try JSONEncoder().encode(mutation).count <= 4 * 1024 * 1024 else { throw MailFolderMutationError.capacity }
    }

    static func validateFolderMutationRecord(_ record: MailFolderMutationRecord) throws {
        try validateFolderMutation(record.mutation)
        let completed = Set(record.completedFolderIDs)
        guard !record.mutation.account.isLocalArchive, completed.count == record.completedFolderIDs.count,
              completed.isSubset(of: record.mutation.completionIDs),
              record.activeFolderID.map({ record.mutation.completionIDs.contains($0) && !completed.contains($0) }) ?? true,
              record.state != .complete || completed == record.mutation.completionIDs,
              ![.sent, .acknowledged, .unknown].contains(record.state) || record.activeFolderID != nil else { throw MailFolderMutationError.changed }
        switch record.mutation.kind {
        case .delete:
            guard record.completedFolderIDs == Array(record.mutation.before.map(\.id).prefix(completed.count)) else { throw MailFolderMutationError.changed }
        case .create, .rename:
            guard completed.isEmpty || completed == record.mutation.completionIDs else { throw MailFolderMutationError.changed }
        }
        if record.state == .prepared || record.state == .complete {
            guard record.activeFolderID == nil, record.activeProof == nil, record.error == nil else { throw MailFolderMutationError.changed }
        }
        if let proofs = record.completedProofs { guard Set(proofs.keys).isSubset(of: completed) else { throw MailFolderMutationError.changed } }
        if let statuses = record.serverStatuses {
            guard statuses.allSatisfy({ key, status in record.mutation.before.contains { $0.id == key && !$0.isContainer }
                && status.messageCount >= 0 && status.unreadCount >= 0
                && (status.uidValidity.map { $0 > 0 } ?? true) && (status.uidNext.map { $0 > 0 } ?? true) }) else { throw MailFolderMutationError.changed }
        }
        if let resolved = record.resolvedAfter {
            guard record.mutation.kind != .delete, Set(resolved.map(\.id)) == Set(record.mutation.after.map(\.id)),
                  resolved.count == record.mutation.after.count, Set(resolved.map(\.path)).count == resolved.count else { throw MailFolderMutationError.changed }
            for actual in resolved {
                guard let expected = record.mutation.after.first(where: { $0.id == actual.id }),
                      MailFolderPath.display(actual, isLocalArchive: false) == MailFolderPath.display(expected, isLocalArchive: false),
                      actual.parentPath.map(ImapMailboxEncoding.decode) == expected.parentPath.map(ImapMailboxEncoding.decode) else { throw MailFolderMutationError.changed }
                var normalized = actual; normalized.path = expected.path; normalized.parentPath = expected.parentPath
                guard normalized == expected else { throw MailFolderMutationError.changed }
            }
        }
        if let active = record.activeFolderID, record.state.isPending, active != record.nextFolderID { throw MailFolderMutationError.changed }
    }

    private static func validateFolderMutationCurrent(_ mutation: MailFolderMutation, db: Database, checkInventory: Bool,
                                                       completed: Set<UUID> = [], allowDisabled: Bool = false) throws {
        try validateFolderMutation(mutation)
        guard let account = try MailAccountRow.fetchOne(db, key: mutation.account.id.uuidString)?.toAccount(), sameFolderMutationAccount(account, mutation.account) else { throw MailFolderMutationError.changed }
        if !allowDisabled && !account.isLocalArchive && !account.isEnabled { throw MailSyncError.accountDisabled }
        let folders = try MailFolderRow.filter(Column("accountId") == account.id.uuidString).fetchAll(db).compactMap { $0.toFolder() }
        let snapshots = mutation.before.filter { !completed.contains($0.id) } + (mutation.parent.map { [$0] } ?? [])
        for expected in snapshots {
            guard let current = folders.first(where: { $0.id == expected.id }),
                  current.path == expected.path, current.name == expected.name, current.role == expected.role,
                  current.parentPath == expected.parentPath, current.delimiter == expected.delimiter,
                  current.isContainer == expected.isContainer, current.uidValidity == expected.uidValidity else { throw MailFolderMutationError.changed }
            if checkInventory, let inventory = mutation.inventories[expected.id], try folderInventory(expected.id, db: db) != inventory { throw MailFolderMutationError.changed }
        }
        if mutation.kind != .create {
            guard let root = folders.first(where: { $0.id == mutation.rootID }) else { throw MailFolderMutationError.changed }
            let currentIDs = Set(try folderSubtree(root, folders: folders).map(\.id))
            guard currentIDs == Set(mutation.before.map(\.id)).subtracting(completed) else { throw MailFolderMutationError.changed }
        }
        let ignored = Set(mutation.before.map(\.id))
        guard !mutation.after.contains(where: { target in folders.contains { !ignored.contains($0.id) && ($0.id == target.id || $0.path == target.path) } }) else { throw MailFolderMutationError.duplicate }
    }

    private static func applyFolderMutation(_ mutation: MailFolderMutation, deleting id: UUID?, afterOverride: [MailFolder]? = nil, db: Database) throws {
        let after = afterOverride ?? mutation.after, ignored = Set(mutation.before.map(\.id))
        for folder in after {
            if let existing = try MailFolderRow.filter(Column("accountId") == folder.accountId.uuidString).filter(Column("path") == folder.path).fetchOne(db) {
                guard let id = UUID(uuidString: existing.id) else { throw MailFolderMutationError.changed }
                if !ignored.contains(id) { throw MailFolderMutationError.duplicate }
            }
        }
        switch mutation.kind {
        case .create:
            for folder in after { var row = MailFolderRow(from: folder); try row.insert(db) }
        case .rename:
            for folder in after {
                guard var row = try MailFolderRow.fetchOne(db, key: folder.id.uuidString) else { throw MailFolderMutationError.changed }
                row.path = folder.path; row.name = folder.name; row.parentPath = folder.parentPath; row.delimiter = folder.delimiter
                try row.update(db)
            }
        case .delete:
            for folder in mutation.before where id == nil || id == folder.id {
                // Use the existing content cleanup so retained raw mail, thread links,
                // pending flags and import origins follow their existing cascades.
                let messages = try String.fetchAll(db, sql: "SELECT id FROM mail_messages WHERE folderId=?", arguments: [folder.id.uuidString])
                for message in messages { if let uuid = UUID(uuidString: message) { try deleteMessageContents(messageId: uuid, in: db) } }
                _ = try MailFolderRow.deleteOne(db, key: folder.id.uuidString)
            }
        }
    }

    private static func folderMutationRecord(_ id: UUID, db: Database) throws -> MailFolderMutationRecord {
        guard let row = try Row.fetchOne(db, sql: "SELECT accountID,state,length(payload) AS bytes FROM mail_folder_mutations WHERE id=?", arguments: [id.uuidString]),
              (row["bytes"] as Int) > 0, (row["bytes"] as Int) <= folderMutationByteLimit,
              let data = try Data.fetchOne(db, sql: "SELECT payload FROM mail_folder_mutations WHERE id=?", arguments: [id.uuidString]) else { throw MailFolderMutationError.changed }
        let record = try JSONDecoder().decode(MailFolderMutationRecord.self, from: data)
        try validateFolderMutationRecord(record)
        guard record.id == id, record.mutation.account.id.uuidString == (row["accountID"] as String), record.state.rawValue == (row["state"] as String) else { throw MailFolderMutationError.changed }
        return record
    }

    private static func saveFolderMutation(_ record: MailFolderMutationRecord, db: Database) throws {
        try validateFolderMutationRecord(record)
        let data = try JSONEncoder().encode(record)
        guard data.count <= folderMutationByteLimit else { throw MailFolderMutationError.capacity }
        try db.execute(sql: "INSERT INTO mail_folder_mutations(id,accountID,createdAt,state,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,payload=excluded.payload",
            arguments: [record.id.uuidString, record.mutation.account.id.uuidString, record.mutation.createdAt, record.state.rawValue, data])
        try db.execute(sql: "DELETE FROM mail_folder_mutations WHERE id IN (SELECT id FROM mail_folder_mutations WHERE accountID=? AND state IN ('complete','failed','cancelled') ORDER BY createdAt DESC,id LIMIT -1 OFFSET 50)", arguments: [record.mutation.account.id.uuidString])
    }
}
