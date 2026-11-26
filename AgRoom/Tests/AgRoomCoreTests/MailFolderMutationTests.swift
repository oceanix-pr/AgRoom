import CryptoKit
import Foundation
import GRDB
import MailFoundation
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

private typealias MailService = AgRoomCore.MailService
private typealias MailFolder = AgRoomCore.MailFolder

@Suite("Mail folder mutation plans and durable receipts")
struct MailFolderMutationTests {
    private struct Fixture: Sendable {
        let queue: DatabaseQueue
        let mail: MailService
        let account: MailAccount
        let root: MailFolder
        let branch: MailFolder
        let leaf: MailFolder
        let sibling: MailFolder
        let other: MailFolder
        let message: MailMessage
        let raw: Data
    }
    private func fixture(remote: Bool = false) async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue)
        let account: MailAccount
        if remote {
            account = MailAccount(displayName: "Remote fixture", emailAddress: "test@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "fixture")
            try await queue.write { db in var row = MailAccountRow(from: account); try row.insert(db) }
        } else { account = try await mail.createLocalArchive(name: "Archive fixture", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive") }
        let second = try await mail.createLocalArchive(name: "Other account", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let root = MailFolder(accountId: account.id, path: "Projects", name: "Projects", delimiter: "/", isContainer: true)
        let branch = MailFolder(accountId: account.id, path: "Projects/2025", name: "2025", parentPath: root.path, delimiter: "/", isContainer: true)
        let leaf = MailFolder(accountId: account.id, path: "Projects/2025/Reports", name: "Reports", parentPath: branch.path, delimiter: "/", uidValidity: remote ? 41 : nil)
        let sibling = MailFolder(accountId: account.id, path: "Projects-old", name: "Projects-old", delimiter: "/")
        let other = MailFolder(accountId: second.id, path: root.path, name: root.name, delimiter: "/")
        try await mail.upsertFolders([root, branch, leaf, sibling, other])
        let raw = Data("From: source@example.test\r\nTo: recipient@example.test\r\nMessage-ID: <retained@example.test>\r\nSubject: Retained report\r\n\r\nRetained original\r\n".utf8)
        let message = MailMessage(accountId: account.id, folderId: leaf.id, uid: remote ? 11 : MailService.localUIDFloor,
            messageId: "<retained@example.test>", subject: "Retained report", bodyState: .ready)
        try await mail.upsertMessages([message]); try await mail.saveBody(.init(messageId: message.id, textBody: "Retained original"))
        try await mail.saveRawMessage(id: message.id, raw: .init(data: raw, kind: remote ? .received : .imported))
        return .init(queue: queue, mail: mail, account: account, root: root, branch: branch, leaf: leaf, sibling: sibling, other: other, message: message, raw: raw)
    }

    @Test("Local rename preserves IDs, nested paths, raw messages, preferences and saved filters without touching other accounts")
    func localRename() async throws {
        let f = try await fixture()
        try await f.mail.setFolderFavorite(true, folderID: f.leaf.id)
        try await f.mail.setFolderHidden(true, folderID: f.root.id)
        try await f.mail.recordMoveDestination(f.leaf.id)
        let preferences = try await f.mail.folderPreferences()
        let saved = MailSavedSearch(name: "Reports", filter: .init(), location: .folder(f.leaf.id))
        try await f.mail.saveSearch(saved)
        let plan = try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "交付 & Reports")
        #expect(plan.mutation.before.map(\.id) == [f.leaf.id, f.branch.id, f.root.id])
        #expect(plan.mutation.cachedMessageCount == 1)
        #expect(try await f.mail.folders(accountId: f.account.id).contains { $0.id == f.root.id && $0.path == "Projects" })
        let result = try await f.mail.applyLocalFolderMutation(plan)
        #expect(result.state == .complete && Set(result.completedFolderIDs) == [f.leaf.id, f.branch.id, f.root.id])
        let folders = try await f.mail.folders(accountId: f.account.id)
        #expect(folders.first { $0.id == f.root.id }?.path == "交付 & Reports")
        #expect(folders.first { $0.id == f.leaf.id }?.path == "交付 & Reports/2025/Reports")
        #expect(folders.first { $0.id == f.leaf.id }?.parentPath == "交付 & Reports/2025")
        #expect(folders.first { $0.id == f.sibling.id }?.path == f.sibling.path)
        #expect(try await f.mail.allFolders().first { $0.id == f.other.id }?.path == f.other.path)
        #expect(try await f.mail.message(id: f.message.id)?.folderId == f.leaf.id)
        #expect(try await f.mail.rawMessage(id: f.message.id)?.data == f.raw)
        #expect(try await f.mail.body(messageId: f.message.id)?.textBody == "Retained original")
        #expect(try await f.mail.folderPreferences() == preferences)
        #expect(try await f.mail.savedSearches().first?.location == saved.location)
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.applyLocalFolderMutation(plan) }
    }

    @Test("Imported opaque root namespaces and immutable dedup origins survive renaming")
    func importedNamespace() async throws {
        let f = try await fixture()
        let envelope = try MailFoundationAdapter.importedEnvelope(f.raw)
        let candidate = MailImportCandidate(id: UUID(), source: "retained.eml", folder: "客户/报告", envelope: envelope, data: f.raw,
            sha256: SHA256.hash(data: f.raw).map { String(format: "%02x", $0) }.joined())
        let preview = MailImportPreview(candidates: [candidate])
        let batch = try await f.mail.importMessages(preview, archiveID: f.account.id)
        let id = try #require(batch.results.first?.messageID)
        let root = try #require(try await f.mail.folders(accountId: f.account.id).first { $0.path == "import/客户" })
        let plan = try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .rename, folderID: root.id, name: "归档客户")
        _ = try await f.mail.applyLocalFolderMutation(plan)
        #expect(try await f.mail.folders(accountId: f.account.id).first { $0.id == root.id }?.path == "import/归档客户")
        #expect(try await f.mail.importDuplicate(candidate: candidate, archiveID: f.account.id).message.id == id)
        #expect(try await f.mail.importPreview(preview, archiveID: f.account.id).duplicates == [candidate.id])
        #expect(try await f.mail.messageIDs(in: .importBatch(archiveID: f.account.id, batchID: batch.id)) == [id])
    }

    @Test("Local deletion is atomic, includes the reviewed tree only, and refuses new messages or descendants")
    func localDelete() async throws {
        let f = try await fixture()
        try await f.mail.setFolderHidden(true, folderID: f.root.id)
        try await f.mail.setFolderFavorite(true, folderID: f.leaf.id)
        let plan = try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .delete, folderID: f.root.id)
        let newMessage = MailMessage(accountId: f.account.id, folderId: f.leaf.id, uid: MailService.localUIDFloor + 1)
        try await f.mail.upsertMessages([newMessage])
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.applyLocalFolderMutation(plan) }
        #expect(try await f.mail.rawMessage(id: f.message.id)?.data == f.raw)
        try await f.mail.deleteMessage(id: newMessage.id)
        let newFolder = MailFolder(accountId: f.account.id, path: "Projects/New", name: "New", parentPath: f.root.path, delimiter: "/")
        try await f.mail.upsertFolders([newFolder])
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.applyLocalFolderMutation(plan) }
        let fresh = try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .delete, folderID: f.root.id)
        #expect(fresh.mutation.before.count == 4)
        let result = try await f.mail.applyLocalFolderMutation(fresh)
        #expect(result.state == .complete && result.completedFolderIDs.count == 4)
        #expect(try await f.mail.message(id: f.message.id) == nil)
        #expect(try await f.mail.rawMessage(id: f.message.id) == nil)
        #expect(try await f.mail.folderPreferences().isEmpty)
        let remaining = try await f.mail.allFolders()
        #expect(remaining.contains { $0.id == f.sibling.id } && remaining.contains { $0.id == f.other.id })
    }

    @Test("Create and review validation reject unsafe names, collisions, system descendants, stale parents and copied plans")
    func validation() async throws {
        let f = try await fixture()
        for name in ["", " ", ".", "..", "A/B", "Bad\nName", String(repeating: "界", count: 100)] {
            await #expect(throws: MailFolderMutationError.invalidName) { try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .create, name: name) }
        }
        await #expect(throws: MailFolderMutationError.duplicate) { try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .create, name: "Projects") }
        await #expect(throws: MailFolderMutationError.duplicate) { try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Projects-old") }
        let system = try #require(try await f.mail.folders(accountId: f.account.id).first { $0.role == .inbox })
        await #expect(throws: MailFolderMutationError.protectedFolder) { try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .delete, folderID: system.id) }
        let child = MailFolder(accountId: f.account.id, path: "Projects/Sent", name: "Sent", role: .sent, parentPath: f.root.path, delimiter: "/")
        try await f.mail.upsertFolders([child])
        await #expect(throws: MailFolderMutationError.protectedFolder) { try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed") }
        let plan = try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .create, parentID: f.branch.id, name: "新建 & \"folder\"")
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        await #expect(throws: MailFolderMutationError.changed) { try await MailService(databaseQueue: isolated).applyLocalFolderMutation(plan) }
        let created = try await f.mail.applyLocalFolderMutation(plan)
        #expect(created.state == .complete)
        #expect(try await f.mail.folders(accountId: f.account.id).contains { $0.id == plan.mutation.rootID && $0.path == "Projects/2025/新建 & \"folder\"" })
        await #expect(throws: MailFolderMutationError.duplicate) { try await f.mail.applyLocalFolderMutation(plan) }
        let stale = try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .create, parentID: f.branch.id, name: "Another")
        try await f.queue.write { db in try db.execute(sql: "UPDATE mail_folders SET name='Changed parent' WHERE id=?", arguments: [f.branch.id.uuidString]) }
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.applyLocalFolderMutation(stale) }
    }

    @Test("Remote receipts distinguish prepared, sent, unknown and acknowledged states and guard cache reconciliation")
    func remoteJournal() async throws {
        let f = try await fixture(remote: true)
        let plan = try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed")
        #expect(try await f.mail.folderMutationHistory(accountID: f.account.id).isEmpty)
        let began = try await f.mail.beginFolderMutation(plan)
        #expect(began.state == .prepared)
        await #expect(throws: MailFolderMutationError.pending) { try await f.mail.beginFolderMutation(plan) }
        await #expect(throws: MailFolderMutationError.pending) { try await f.mail.upsertFolders([f.sibling]) }
        await #expect(throws: MailFolderMutationError.pending) { try await f.mail.deleteFolders(accountId: f.account.id, keeping: []) }
        let sent = try await f.mail.markFolderMutationSent(id: plan.mutation.id, folderID: f.root.id)
        #expect(sent.state == .sent && sent.activeFolderID == f.root.id)
        let unknown = try await f.mail.failFolderMutation(id: plan.mutation.id, definitelyRejected: false, cancelled: true)
        #expect(unknown.state == .unknown && unknown.error == .unknown)
        #expect(try await f.mail.rawMessage(id: f.message.id)?.data == f.raw)
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.markFolderMutationSent(id: plan.mutation.id, folderID: f.root.id) }
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.commitFolderMutationStep(id: plan.mutation.id) }
        let otherPlan = try await f.mail.reviewFolderMutation(accountID: f.other.accountId, kind: .create, name: "Allowed")
        #expect(try await f.mail.applyLocalFolderMutation(otherPlan).state == .complete)
        let rejected = try await f.mail.failFolderMutation(id: plan.mutation.id, definitelyRejected: true)
        #expect(rejected.state == .unknown)
        let g = try await fixture(remote: true)
        let fresh = try await g.mail.reviewFolderMutation(accountID: g.account.id, kind: .rename, folderID: g.root.id, name: "Renamed")
        _ = try await g.mail.beginFolderMutation(fresh)
        _ = try await g.mail.markFolderMutationSent(id: fresh.mutation.id, folderID: g.root.id)
        let acknowledged = try await g.mail.acknowledgeFolderMutation(id: fresh.mutation.id)
        #expect(acknowledged.state == .acknowledged)
        #expect(try await g.mail.failFolderMutation(id: fresh.mutation.id, definitelyRejected: false).state == .acknowledged)
        let committed = try await g.mail.commitFolderMutationStep(id: fresh.mutation.id)
        #expect(committed.state == .complete)
        #expect(try await g.mail.folders(accountId: g.account.id).first { $0.id == g.leaf.id }?.path == "Renamed/2025/Reports")
        #expect(try await g.mail.message(id: g.message.id)?.uid == g.message.uid)
        #expect(try await g.mail.rawMessage(id: g.message.id)?.data == g.raw)
        try await g.mail.requireNoPendingFolderMutation(g.account.id)
    }

    @Test("Per-folder delete receipts preserve completed steps and durable unknown results across backup and migration")
    func deletionReceiptsAndBackup() async throws {
        let f = try await fixture(remote: true)
        let plan = try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .delete, folderID: f.root.id)
        _ = try await f.mail.beginFolderMutation(plan)
        _ = try await f.mail.markFolderMutationSent(id: plan.mutation.id, folderID: f.leaf.id)
        _ = try await f.mail.acknowledgeFolderMutation(id: plan.mutation.id)
        let first = try await f.mail.commitFolderMutationStep(id: plan.mutation.id)
        #expect(first.state == .prepared && first.completedFolderIDs == [f.leaf.id] && first.nextFolderID == f.branch.id)
        #expect(try await f.mail.message(id: f.message.id) == nil)
        _ = try await f.mail.markFolderMutationSent(id: plan.mutation.id, folderID: f.branch.id)
        let unknown = try await f.mail.failFolderMutation(id: plan.mutation.id, definitelyRejected: false)
        let backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        let store = SpaceDatabaseBackupStore(queue: isolated, space: "work")
        _ = try await store.apply(store.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        let restored = MailService(databaseQueue: isolated)
        #expect(try await restored.folderMutationHistory(accountID: f.account.id).first == unknown)
        await #expect(throws: MailFolderMutationError.pending) { try await restored.deleteFolders(accountId: f.account.id, keeping: []) }
        var invalid = backup
        let index = try #require(invalid.tables.firstIndex { $0.name == "mail_folder_mutations" })
        let payload = try #require(invalid.tables[index].columns.firstIndex(of: "payload"))
        var broken = unknown; broken.completedFolderIDs = [f.root.id]
        invalid.tables[index].rows[0][payload] = .blob(try JSONEncoder().encode(broken))
        await #expect(throws: (any Error).self) { try await store.plan(invalid, sourceSpace: "work") }
        #expect(try await restored.folderMutationHistory(accountID: f.account.id).first == unknown)
        try await isolated.write { db in
            try db.execute(sql: "DROP INDEX mail_folder_mutation_pending")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v18_mail_folder_mutations'")
        }
        try DatabaseBootstrap.prepareSpace(isolated); try DatabaseBootstrap.prepareSpace(isolated)
        #expect(try await restored.folderMutationHistory(accountID: f.account.id).first == unknown)
    }

    @Test("Real adapter CREATE, RENAME and DELETE quote decoded paths exactly once and preserve a server rejection")
    func protocolReplay() async throws {
        let transport = AsyncStreamTransport()
        for response in ["* OK Ready\r\n", "A0001 OK LOGIN completed\r\n", "* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n", "A0003 OK CREATE completed\r\n", "A0004 OK RENAME completed\r\n", "A0005 NO [HASCHILDREN] Cannot delete\r\n"] {
            await transport.yieldIncoming(Array(response.utf8))
        }
        let adapter = MailFoundationAdapter(host: "imap.example.test", port: 143, security: .none) { transport }
        try await adapter.connect(); try await adapter.authenticate(username: "fixture", password: "test")
        let before = ImapMailboxEncoding.encode("项目/交付 & \"C\""), after = ImapMailboxEncoding.encode("项目/更名 & \"D\"")
        try await MailDeadline.call(1_000, label: "create", client: adapter) { try await adapter.createFolder(path: before) }
        try await MailDeadline.call(1_000, label: "rename", client: adapter) { try await adapter.renameFolder(path: before, toPath: after) }
        do { try await MailDeadline.call(1_000, label: "delete", client: adapter) { try await adapter.deleteFolder(path: after) }; Issue.record("Server NO was ignored") }
        catch let error as MailServerDiagnostic { #expect(error.stage == .deleteFolder && error.kind == .serverRejected && error.status == "NO") }
        let sent = await transport.sentSnapshot().map { String(decoding: $0, as: UTF8.self) }.joined()
        let escapedBefore = before.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAfter = after.replacingOccurrences(of: "\"", with: "\\\"")
        #expect(sent.contains("CREATE \"" + escapedBefore + "\"\r\n"))
        #expect(sent.contains("RENAME \"" + escapedBefore + "\" \"" + escapedAfter + "\"\r\n"))
        #expect(sent.contains("DELETE \"" + escapedAfter + "\"\r\n"))
        #expect(!sent.contains(ImapMailboxEncoding.encode(before)))
        await adapter.disconnect()
    }
}
