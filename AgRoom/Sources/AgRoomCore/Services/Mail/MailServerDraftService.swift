import CryptoKit
import Foundation
import GRDB

public enum MailServerDraftError: String, Error, Sendable {
    case unsupported, folderMissing, changed, conflict, unresolved, missing, invalid, capacity
}
public struct RemoteDraftAppendResult: Sendable, Equatable {
    public let uidValidity: UInt32
    public let uid: UInt32
    public init(uidValidity: UInt32, uid: UInt32) { self.uidValidity = uidValidity; self.uid = uid }
}

public struct MailServerDraftVersion: Codable, Sendable, Equatable {
    public var draft: MailDraft
    public let folder: MailFolder
    public let uidValidity: UInt32
    public var uid: UInt32?
    public let messageID: String
    public let sha256: String
    public let createdAt: Date
}
public struct MailServerDraftRecord: Codable, Sendable, Equatable {
    public let draftID: UUID
    public let account: MailAccount
    public var revision = UUID()
    public var current: MailServerDraftVersion?
    /// Persisted before APPEND. Its presence forbids another upload, even after restart.
    public var pending: MailServerDraftVersion?
    /// Persisted before removal of the old, confirmed copy. Only UID EXPUNGE is used.
    public var previous: MailServerDraftVersion?
    public var abandonedMessageIDs: [String] = []
    public var needsReconciliation = false
    public var retiringAfterSend: Bool? = nil
    public var retiredAt: Date? = nil
    public func validate() throws {
        guard !account.isLocalArchive, abandonedMessageIDs.count <= 64,
              abandonedMessageIDs.allSatisfy(Self.validMessageID) else { throw MailServerDraftError.invalid }
        for value in [current, pending, previous].compactMap({ $0 }) {
            guard value.draft.id == draftID, value.draft.accountId == account.id,
                  value.draft.deliveredAt == nil, value.draft.deliveryState.allowsRetry,
                  value.folder.accountId == account.id, value.folder.role == .drafts, !value.folder.isContainer,
                  !value.folder.path.isEmpty, value.folder.path.utf8.count <= 4096,
                  value.uidValidity > 0, value.uid.map({ $0 > 0 }) != false,
                  value.createdAt.timeIntervalSince1970.isFinite, value.draft.updatedAt.timeIntervalSince1970.isFinite,
                  Self.validMessageID(value.messageID), value.sha256.utf8.count == 64,
                  value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw MailServerDraftError.invalid }
            try MailDraftAttachment.validate(value.draft.attachments)
            guard [value.draft.subject, value.draft.bodyText, value.draft.quotedText].reduce(0, { $0 + $1.utf8.count }) <= MailService.rawMessageByteLimit else { throw MailServerDraftError.capacity }
        }
        guard current?.uid != nil || current == nil, previous?.uid != nil || previous == nil,
              pending?.uid == nil, previous == nil || (current != nil && pending == nil) else { throw MailServerDraftError.invalid }
        guard retiredAt?.timeIntervalSince1970.isFinite != false,
              retiredAt == nil || (current == nil && pending == nil && previous == nil && retiringAfterSend != true),
              retiringAfterSend != true || (current != nil && pending == nil && previous == nil) else { throw MailServerDraftError.invalid }
    }
    static func validMessageID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && value.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e && $0 != 34 && $0 != 92 }
    }
}
public struct MailServerDraftSaveReview: Sendable, Identifiable {
    public let id = UUID()
    fileprivate let queue: DatabaseQueue
    public let record: MailServerDraftRecord
    public let version: MailServerDraftVersion
    fileprivate let raw: Data
    fileprivate let wasExisting: Bool
    public let unchanged: Bool
    public var replacesPrevious: Bool { record.current != nil && !unchanged }
}
public struct MailServerDraftReadReview: Sendable, Identifiable {
    public let id = UUID()
    fileprivate let queue: DatabaseQueue
    public let record: MailServerDraftRecord
    public let version: MailServerDraftVersion
    public var draft: MailDraft { version.draft }
    public var remoteChanged: Bool { record.current?.sha256 != version.sha256 || record.current?.uid != version.uid }
}

extension MailService {
    static let serverDraftRecordByteLimit = 160 * 1024 * 1024
    static func createServerDraftSchema(_ db: Database) throws {
        try db.create(table: "mail_server_drafts", ifNotExists: true) { table in
            table.column("draftID", .text).primaryKey()
            table.column("accountID", .text).notNull().references("mail_accounts", onDelete: .cascade)
            table.column("payload", .blob).notNull()
        }
    }
    public func serverDraftRecord(id: UUID) async throws -> MailServerDraftRecord? {
        try await databaseQueue.read { try Self.serverDraftRecord(id: id, db: $0) }
    }
    static func serverDraftRecord(id: UUID, db: Database) throws -> MailServerDraftRecord? {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM mail_server_drafts WHERE draftID=?", arguments: [id.uuidString]) else { return nil }
        guard data.count <= serverDraftRecordByteLimit else { throw MailServerDraftError.capacity }
        let record = try JSONDecoder().decode(MailServerDraftRecord.self, from: data)
        try record.validate(); return record
    }
    static func sameDraftContent(_ lhs: MailDraft, _ rhs: MailDraft) -> Bool {
        var left = lhs, right = rhs
        left.updatedAt = .distantPast; right.updatedAt = .distantPast
        return left == right
    }
    static func requireEditableServerDraft(_ expected: MailDraft, db: Database) throws {
        guard let draft = try MailDraftRow.fetchOne(db, key: expected.id.uuidString)?.toDraft(),
              draft.deliveredAt == nil, draft.deliveryState.allowsRetry,
              sameDraftContent(draft, expected) else { throw MailServerDraftError.changed }
    }
    func storeServerDraft(_ value: MailServerDraftRecord, replacing expected: MailServerDraftRecord?, local: MailDraft? = nil,
                          adopt draft: MailDraft? = nil, requireDelivered: Bool = false) async throws {
        try value.validate()
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.serverDraftRecordByteLimit else { throw MailServerDraftError.capacity }
        try await databaseQueue.maintenanceWrite { db in
            guard try Self.serverDraftRecord(id: value.draftID, db: db) == expected,
                  let account = try MailAccountRow.fetchOne(db, key: value.account.id.uuidString)?.toAccount(),
                  Self.sameFolderMutationAccount(account, value.account), account.isEnabled else { throw MailServerDraftError.changed }
            try Self.requireNoPendingFolderMutation(account.id, db: db)
            if let local { try Self.requireEditableServerDraft(local, db: db) }
            if requireDelivered {
                guard let delivered = try MailDraftRow.fetchOne(db, key: value.draftID.uuidString)?.toDraft(),
                      delivered.accountId == account.id,
                      delivered.deliveredAt != nil || [.accepted, .localSaveFailed].contains(delivered.deliveryState) else { throw MailServerDraftError.changed }
            }
            if let draft {
                guard let local, draft.id == local.id, draft.accountId == local.accountId else { throw MailServerDraftError.changed }
                var row = try MailDraftRow(from: draft); try row.save(db)
            }
            let total = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(payload)),0) FROM mail_server_drafts WHERE draftID<>?", arguments: [value.draftID.uuidString]) ?? 0
            guard total <= 1024 * 1024 * 1024 - data.count else { throw MailServerDraftError.capacity }
            try db.execute(sql: "INSERT INTO mail_server_drafts(draftID,accountID,payload) VALUES(?,?,?) ON CONFLICT(draftID) DO UPDATE SET payload=excluded.payload", arguments: [value.draftID.uuidString, value.account.id.uuidString, data])
        }
    }
}

/// Explicit server draft actions share account leases with synchronization and SMTP.
/// Recovery only reads the server; unknown APPEND or cleanup is never replayed.
public actor MailServerDraftService {
    private let mail: MailService
    private let accounts: MailAccountService
    private let space: AppSpace
    private let coordinator: MailAccountCoordinator
    private let factory: @Sendable (MailAccount) -> MailProtocolClient
    private let password: @Sendable (UUID) -> String?
    private let budget: MailTimeoutBudget
    init(mail: MailService, accounts: MailAccountService, space: AppSpace, coordinator: MailAccountCoordinator,
         factory: @escaping @Sendable (MailAccount) -> MailProtocolClient,
         password: @escaping @Sendable (UUID) -> String?, budget: MailTimeoutBudget) {
        self.mail = mail; self.accounts = accounts; self.space = space; self.coordinator = coordinator
        self.factory = factory; self.password = password; self.budget = budget
    }
    public func reviewSave(_ draft: MailDraft) async throws -> MailServerDraftSaveReview {
        try await coordinator.withLease(space: space, accountId: draft.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.prepareSave(draft)
        }
    }
    private func prepareSave(_ draft: MailDraft) async throws -> MailServerDraftSaveReview {
        guard draft.deliveredAt == nil, draft.deliveryState.allowsRetry,
              draft.composeKind != .forward || draft.forwardAttachmentsState != .pending else { throw MailServerDraftError.invalid }
        try MailDraftAttachment.validate(draft.attachments)
        let existing = try await mail.serverDraftRecord(id: draft.id)
        guard existing?.pending == nil, existing?.previous == nil, existing?.needsReconciliation != true,
              existing?.retiringAfterSend != true, existing?.retiredAt == nil else { throw MailServerDraftError.unresolved }
        let account = try await context(id: draft.accountId, expected: existing?.account)
        let folders = try await mail.folders(accountId: account.id).filter { $0.role == .drafts && !$0.isContainer }
        guard folders.count == 1, var folder = folders.first else { throw MailServerDraftError.folderMissing }
        let client = factory(account)
        do {
            try await open(client, account)
            guard await client.supportsUIDPlus() else { throw MailServerDraftError.unsupported }
            let validity = try await status(client, folder: folder)
            if let previous = existing?.current { _ = try await exactRemote(previous, client: client) }
            folder.uidValidity = validity
            let date = Date(), messageID = "<draft.\(UUID().uuidString)@agroom.local>"
            let encode = Task.detached { try MailSmtpAdapter.serializedDraft(draft, account: account, messageID: messageID, date: date) }
            let raw = try await withTaskCancellationHandler { try await encode.value } onCancel: { encode.cancel() }
            guard try MailFoundationAdapter.originalMessageID(raw) == messageID else { throw MailServerDraftError.invalid }
            let value = MailServerDraftVersion(draft: draft, folder: folder, uidValidity: validity, uid: nil,
                messageID: messageID, sha256: Self.hash(raw), createdAt: date)
            let record = existing ?? MailServerDraftRecord(draftID: draft.id, account: account)
            var prospective = record; prospective.pending = value
            try prospective.validate()
            guard try JSONEncoder().encode(prospective).count <= MailService.serverDraftRecordByteLimit else { throw MailServerDraftError.capacity }
            try await validateLocal(draft, account: account, folder: folder)
            let unchanged = existing?.current.map { MailService.sameDraftContent($0.draft, draft) } ?? false
            await client.disconnect()
            return .init(queue: mail.databaseQueue, record: record, version: value, raw: raw,
                         wasExisting: existing != nil, unchanged: unchanged)
        } catch { await client.disconnect(); throw error }
    }

    public func save(_ review: MailServerDraftSaveReview) async throws -> MailServerDraftRecord {
        guard review.queue === mail.databaseQueue else { throw MailServerDraftError.changed }
        return try await coordinator.withLease(space: space, accountId: review.record.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performSave(review)
        }
    }
    private func performSave(_ review: MailServerDraftSaveReview) async throws -> MailServerDraftRecord {
        let expected = review.wasExisting ? review.record : nil
        guard try await mail.serverDraftRecord(id: review.record.draftID) == expected else { throw MailServerDraftError.changed }
        let account = try await context(id: review.record.account.id, expected: review.record.account)
        try await validateLocal(review.version.draft, account: account, folder: review.version.folder)
        guard Self.hash(review.raw) == review.version.sha256 else { throw MailServerDraftError.changed }
        let client = factory(account)
        do {
            try await open(client, account)
            guard await client.supportsUIDPlus() else { throw MailServerDraftError.unsupported }
            guard try await status(client, folder: review.version.folder) == review.version.uidValidity else { throw MailServerDraftError.changed }
            if let previous = review.record.current { _ = try await exactRemote(previous, client: client) }
            if review.unchanged { await client.disconnect(); return review.record }
            var pending = review.record; pending.pending = review.version; pending.revision = UUID()
            // This durable claim must succeed before the first APPEND byte.
            try await mail.storeServerDraft(pending, replacing: expected, local: review.version.draft)
            let appended = try await MailDeadline.call(budget.write, label: "appendDraft", client: client) {
                try await client.appendDraft(path: review.version.folder.path, data: review.raw)
            }
            guard appended.uidValidity == review.version.uidValidity, appended.uid > 0 else { throw MailServerDraftError.unresolved }
            var confirmed = review.version; confirmed.uid = appended.uid
            _ = try await exactRemote(confirmed, client: client)
            var committed = pending; committed.pending = nil; committed.previous = pending.current
            committed.current = confirmed; committed.revision = UUID()
            try await mail.storeServerDraft(committed, replacing: pending)
            let result = try await removePrevious(committed, client: client)
            await client.disconnect(); return result
        } catch { await client.disconnect(); throw error }
    }

    /// Read-only reconciliation of an interrupted APPEND or restored receipt.
    /// An absent or ambiguous result keeps the pending receipt intact.
    public func reconcile(draftID: UUID) async throws -> MailServerDraftRecord {
        guard let record = try await mail.serverDraftRecord(id: draftID) else { throw MailServerDraftError.missing }
        return try await coordinator.withLease(space: space, accountId: record.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performReconcile(record)
        }
    }
    private func performReconcile(_ expected: MailServerDraftRecord) async throws -> MailServerDraftRecord {
        guard try await mail.serverDraftRecord(id: expected.draftID) == expected else { throw MailServerDraftError.changed }
        let account = try await context(id: expected.account.id, expected: expected.account), client = factory(account)
        do {
            try await open(client, account)
            var result = expected
            if expected.retiringAfterSend == true, let current = expected.current, let uid = current.uid {
                guard try await status(client, folder: current.folder) == current.uidValidity else { throw MailServerDraftError.changed }
                if try await presence(current, uid: uid, client: client) {
                    _ = try await exactRemote(current, client: client)
                } else {
                    result.current = nil; result.retiringAfterSend = false; result.retiredAt = Date()
                }
            } else if let pending = expected.pending {
                let found = try await locate(pending, client: client)
                guard found.sha256 == pending.sha256 else { throw MailServerDraftError.conflict }
                result.pending = nil; result.previous = expected.current; result.current = found
            } else if let current = expected.current { _ = try await exactRemote(current, client: client) }
            result.needsReconciliation = false; result.revision = UUID()
            try await mail.storeServerDraft(result, replacing: expected)
            await client.disconnect(); return result
        } catch { await client.disconnect(); throw error }
    }

    /// A user may explicitly abandon only the unresolved upload receipt after
    /// verifying the server. Keep its Message-ID as a bounded audit trail.
    public func abandonUpload(_ expected: MailServerDraftRecord) async throws -> MailServerDraftRecord {
        guard let pending = expected.pending, expected.abandonedMessageIDs.count < 64 else { throw MailServerDraftError.unresolved }
        return try await coordinator.withLease(space: space, accountId: expected.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            var result = expected; result.pending = nil; result.needsReconciliation = false
            result.abandonedMessageIDs.append(pending.messageID); result.revision = UUID()
            try await self.mail.storeServerDraft(result, replacing: expected)
            return result
        }
    }

    /// Explicit cleanup retry: never append again, never use unscoped EXPUNGE.
    public func finishCleanup(_ expected: MailServerDraftRecord) async throws -> MailServerDraftRecord {
        return try await coordinator.withLease(space: space, accountId: expected.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performCleanup(expected)
        }
    }

    public func keepPreviousCopy(_ expected: MailServerDraftRecord) async throws -> MailServerDraftRecord {
        guard let previous = expected.previous, expected.pending == nil, expected.abandonedMessageIDs.count < 64 else { throw MailServerDraftError.changed }
        return try await coordinator.withLease(space: space, accountId: expected.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            var result = expected; result.previous = nil; result.abandonedMessageIDs.append(previous.messageID); result.revision = UUID()
            try await self.mail.storeServerDraft(result, replacing: expected)
            return result
        }
    }

    /// Called only by SMTP while already holding the shared account lease, after
    /// durable delivery proof. Never remove a draft on an unknown SMTP outcome.
    func retireAfterDelivery(draftID: UUID) async throws {
        guard let record = try await mail.serverDraftRecord(id: draftID), record.retiredAt == nil else { return }
        _ = try await retireDelivered(record)
    }
    public func finishDeliveredCleanup(_ expected: MailServerDraftRecord) async throws -> MailServerDraftRecord {
        try await coordinator.withLease(space: space, accountId: expected.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.retireDelivered(expected)
        }
    }
    private func retireDelivered(_ expected: MailServerDraftRecord) async throws -> MailServerDraftRecord {
        guard expected.pending == nil, expected.previous == nil, !expected.needsReconciliation,
              let version = expected.current, let uid = version.uid,
              try await mail.serverDraftRecord(id: expected.draftID) == expected else { throw MailServerDraftError.unresolved }
        // A restored/corrupt receipt is never itself delivery authorization.
        try await mail.databaseQueue.read { db in
            guard let delivered = try MailDraftRow.fetchOne(db, key: expected.draftID.uuidString)?.toDraft(),
                  delivered.accountId == expected.account.id,
                  delivered.deliveredAt != nil || [.accepted, .localSaveFailed].contains(delivered.deliveryState) else { throw MailServerDraftError.changed }
        }
        let account = try await context(id: expected.account.id, expected: expected.account), client = factory(account)
        do {
            try await open(client, account)
            guard await client.supportsUIDPlus(), try await status(client, folder: version.folder) == version.uidValidity else { throw MailServerDraftError.changed }
            var claimed = expected
            if expected.retiringAfterSend != true {
                claimed.retiringAfterSend = true; claimed.revision = UUID()
                try await mail.storeServerDraft(claimed, replacing: expected, requireDelivered: true)
            }
            if try await presence(version, uid: uid, client: client) {
                _ = try await exactRemote(version, client: client)
                try await MailDeadline.call(budget.write, label: "retireDeliveredDraft", client: client) {
                    try await client.markDeleted(path: version.folder.path, uid: uid)
                    try await client.expungeUIDs(path: version.folder.path, uids: [uid])
                }
                guard !(try await presence(version, uid: uid, client: client)) else { throw MailServerDraftError.unresolved }
            }
            var result = claimed; result.current = nil; result.retiringAfterSend = false; result.retiredAt = Date(); result.revision = UUID()
            try await mail.storeServerDraft(result, replacing: claimed, requireDelivered: true)
            await client.disconnect(); return result
        } catch { await client.disconnect(); throw error }
    }
    private func presence(_ version: MailServerDraftVersion, uid: UInt32, client: MailProtocolClient) async throws -> Bool {
        let found = try await MailDeadline.call(budget.fetchSummaries, label: "serverDraftPresence", client: client) {
            try await client.fetchSummaries(path: version.folder.path, uids: [uid])
        }
        guard found.allSatisfy({ $0.uid == uid }) else { throw MailServerDraftError.changed }
        return !found.isEmpty
    }
    private func performCleanup(_ expected: MailServerDraftRecord) async throws -> MailServerDraftRecord {
        guard expected.pending == nil, expected.previous != nil, !expected.needsReconciliation,
              try await mail.serverDraftRecord(id: expected.draftID) == expected else { throw MailServerDraftError.changed }
        let account = try await context(id: expected.account.id, expected: expected.account), client = factory(account)
        do {
            try await open(client, account)
            let result = try await removePrevious(expected, client: client)
            await client.disconnect(); return result
        } catch { await client.disconnect(); throw error }
    }
    private func removePrevious(_ expected: MailServerDraftRecord, client: MailProtocolClient) async throws -> MailServerDraftRecord {
        guard let previous = expected.previous, let uid = previous.uid else { return expected }
        guard let current = expected.current else { throw MailServerDraftError.changed }
        _ = try await exactRemote(current, client: client)
        guard await client.supportsUIDPlus(), try await status(client, folder: previous.folder) == previous.uidValidity else { throw MailServerDraftError.changed }
        let all = try await draftUIDs(client, previous)
        if all.contains(uid) {
            _ = try await exactRemote(previous, client: client)
            try await MailDeadline.call(budget.write, label: "deleteOldDraft", client: client) {
                try await client.markDeleted(path: previous.folder.path, uid: uid)
                try await client.expungeUIDs(path: previous.folder.path, uids: [uid])
            }
            let remaining = try await MailDeadline.call(budget.fetchSummaries, label: "oldDraftRemoved", client: client) {
                try await client.fetchSummaries(path: previous.folder.path, uids: [uid])
            }
            guard remaining.isEmpty else { throw MailServerDraftError.unresolved }
        } else {
            // No DRAFT result is insufficient proof of deletion: it may have
            // lost its Draft flag. Query exact UID summaries before clearing.
            let summaries = try await MailDeadline.call(budget.fetchSummaries, label: "oldDraftPresence", client: client) {
                try await client.fetchSummaries(path: previous.folder.path, uids: [uid])
            }
            guard summaries.isEmpty else { throw MailServerDraftError.conflict }
        }
        var result = expected; result.previous = nil; result.revision = UUID()
        try await mail.storeServerDraft(result, replacing: expected)
        return result
    }

    public func reviewRead(draftID: UUID) async throws -> MailServerDraftReadReview {
        guard let record = try await mail.serverDraftRecord(id: draftID), record.pending == nil,
              record.previous == nil, !record.needsReconciliation, record.retiringAfterSend != true,
              let current = record.current else { throw MailServerDraftError.unresolved }
        return try await coordinator.withLease(space: space, accountId: record.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.prepareRead(record, current: current)
        }
    }
    private func prepareRead(_ record: MailServerDraftRecord, current: MailServerDraftVersion) async throws -> MailServerDraftReadReview {
        let account = try await context(id: record.account.id, expected: record.account), client = factory(account)
        do {
            try await open(client, account)
            let version = try await locate(current, client: client)
            guard try await mail.serverDraftRecord(id: record.draftID) == record else { throw MailServerDraftError.changed }
            await client.disconnect(); return .init(queue: mail.databaseQueue, record: record, version: version)
        } catch { await client.disconnect(); throw error }
    }
    public func adopt(_ review: MailServerDraftReadReview, replacing local: MailDraft) async throws -> MailDraft {
        guard review.queue === mail.databaseQueue, review.draft.id == local.id, review.draft.accountId == local.accountId else { throw MailServerDraftError.changed }
        return try await coordinator.withLease(space: space, accountId: local.accountId, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.performAdopt(review, local: local)
        }
    }
    private func performAdopt(_ review: MailServerDraftReadReview, local: MailDraft) async throws -> MailDraft {
        let account = try await context(id: local.accountId, expected: review.record.account), client = factory(account)
        do {
            try await open(client, account)
            _ = try await exactRemote(review.version, client: client)
            var result = review.record; result.current = review.version; result.revision = UUID()
            var draft = review.draft; draft.updatedAt = Date()
            try await mail.storeServerDraft(result, replacing: review.record, local: local, adopt: draft)
            await client.disconnect(); return draft
        } catch { await client.disconnect(); throw error }
    }

    private func context(id: UUID, expected: MailAccount?) async throws -> MailAccount {
        try await mail.requireNoPendingFolderMutation(id)
        guard let account = try await accounts.account(id: id), !account.isLocalArchive, account.isEnabled else { throw MailServerDraftError.changed }
        if let expected { guard MailService.sameFolderMutationAccount(account, expected), account.emailAddress == expected.emailAddress else { throw MailServerDraftError.changed } }
        return account
    }
    private func open(_ client: MailProtocolClient, _ account: MailAccount) async throws {
        guard let password = password(account.id), !password.isEmpty else { throw MailSyncError.missingPassword }
        try await MailDeadline.openSession(client, username: account.username, password: password, budget: budget)
    }
    private func status(_ client: MailProtocolClient, folder: MailFolder) async throws -> UInt32 {
        let current = try await context(id: folder.accountId, expected: nil)
        guard let local = try await mail.folders(accountId: current.id).first(where: { $0.id == folder.id }),
              local.path.utf8.elementsEqual(folder.path.utf8), local.role == .drafts, !local.isContainer else { throw MailServerDraftError.changed }
        let status = try await MailDeadline.call(budget.folderStatus, label: "draftIdentity", client: client) { try await client.folderStatus(path: folder.path) }
        guard let value = status.uidValidity, value > 0,
              local.uidValidity == nil || local.uidValidity == value else { throw MailServerDraftError.changed }
        return value
    }
    private func validateLocal(_ draft: MailDraft, account: MailAccount, folder: MailFolder) async throws {
        try await mail.databaseQueue.read { db in
            try MailService.requireEditableServerDraft(draft, db: db)
            try MailService.requireNoPendingFolderMutation(account.id, db: db)
            guard let current = try MailAccountRow.fetchOne(db, key: account.id.uuidString)?.toAccount(),
                  MailService.sameFolderMutationAccount(account, current), current.emailAddress == account.emailAddress, current.isEnabled,
                  let target = try MailFolderRow.fetchOne(db, key: folder.id.uuidString)?.toFolder(),
                  target.accountId == account.id, target.path.utf8.elementsEqual(folder.path.utf8), target.role == .drafts, !target.isContainer else { throw MailServerDraftError.changed }
        }
    }
    private func draftUIDs(_ client: MailProtocolClient, _ version: MailServerDraftVersion) async throws -> [UInt32] {
        try await MailDeadline.call(budget.fetchSummaries, label: "locateDraft", client: client) {
            try await client.draftUIDs(path: version.folder.path, messageID: version.messageID)
        }
    }
    private func raw(_ version: MailServerDraftVersion, uid: UInt32, client: MailProtocolClient) async throws -> Data {
        guard try await status(client, folder: version.folder) == version.uidValidity else { throw MailServerDraftError.changed }
        let raw = try await MailDeadline.call(budget.fetchBody, label: "readServerDraft", client: client) {
            try await client.fetchRawMessage(path: version.folder.path, uid: uid, maxBytes: MailService.rawMessageByteLimit)
        }
        guard !raw.isEmpty, raw.count <= MailService.rawMessageByteLimit,
              try MailFoundationAdapter.originalMessageID(raw) == version.messageID else { throw MailServerDraftError.conflict }
        return raw
    }
    private func exactRemote(_ version: MailServerDraftVersion, client: MailProtocolClient) async throws -> Data {
        guard let uid = version.uid, (try await draftUIDs(client, version)).contains(uid) else { throw MailServerDraftError.conflict }
        let data = try await raw(version, uid: uid, client: client)
        guard Self.hash(data) == version.sha256 else { throw MailServerDraftError.conflict }
        return data
    }
    private func locate(_ version: MailServerDraftVersion, client: MailProtocolClient) async throws -> MailServerDraftVersion {
        let uids = try await draftUIDs(client, version)
        guard uids.count == 1, let uid = uids.first else { throw MailServerDraftError.unresolved }
        let data = try await raw(version, uid: uid, client: client), digest = Self.hash(data)
        var draft = version.draft
        if digest != version.sha256 {
            let decode = Task.detached { try MailSmtpAdapter.decodedDraft(data, id: version.draft.id, accountID: version.draft.accountId) }
            draft = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
        }
        return .init(draft: draft, folder: version.folder, uidValidity: version.uidValidity, uid: uid,
            messageID: version.messageID, sha256: digest, createdAt: version.createdAt)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
