import CryptoKit
import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Mail folder operation lifecycle")
struct MailFolderOperationTests {
    struct Fixture: Sendable {
        let queue: DatabaseQueue
        let mail: MailService
        let accounts: MailAccountService
        let account: MailAccount
        let root: MailFolder
        let leaf: MailFolder
        let sibling: MailFolder
        let cached: MailMessage
        let own: MailMessage
        let raw: Data
        let server: MockMailClient
        let service: MailFolderOperationService
    }

    func fixture(ownServerUID: Bool = false) async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue), accounts = MailAccountService(databaseQueue: queue, space: .work)
        let account = MailAccount(displayName: "Managed mailbox", emailAddress: "mail@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "fixture")
        try await queue.write { db in var row = MailAccountRow(from: account); try row.insert(db) }
        let root = MailFolder(accountId: account.id, path: "Projects", name: "Projects", delimiter: "/", isContainer: true)
        let leaf = MailFolder(accountId: account.id, path: "Projects/Reports", name: "Reports", parentPath: root.path, delimiter: "/", uidValidity: 41)
        let sibling = MailFolder(accountId: account.id, path: "Projects-old", name: "Projects-old", delimiter: "/", uidValidity: 51)
        try await mail.upsertFolders([root, leaf, sibling])
        let cached = MailMessage(accountId: account.id, folderId: leaf.id, uid: 1, messageId: "<cached@example.test>", subject: "Server report", bodyState: .ready)
        let own = MailMessage(accountId: account.id, folderId: leaf.id, uid: ownServerUID ? 2 : MailService.localUIDFloor, messageId: "<own@example.test>", subject: "Owned original", bodyState: .ready)
        try await mail.upsertMessages([cached, own])
        for message in [cached, own] { try await mail.saveBody(.init(messageId: message.id, textBody: message.subject)) }
        let raw = Data("From: test@example.test\r\nMessage-ID: <cached@example.test>\r\nSubject: Server report\r\n\r\nRetained original\r\n".utf8)
        try await mail.saveRawMessage(id: cached.id, raw: .init(data: raw, kind: .received))
        try await mail.saveRawMessage(id: own.id, raw: .init(data: Data("Message-ID: <own@example.test>\r\n\r\nOwned original\r\n".utf8), kind: .generated))
        let folders = [root, leaf, sibling].map { RemoteMailFolder(path: $0.path, name: $0.name, role: $0.role, delimiter: $0.delimiter, isSelectable: !$0.isContainer) }
        let server = MockMailClient(folders: folders, statuses: [leaf.path: .init(uidValidity: 41, uidNext: 3, messageCount: 2, unreadCount: 1), sibling.path: .init(uidValidity: 51, uidNext: 1, messageCount: 0, unreadCount: 0)])
        let sync = MailSyncService(accountService: accounts, mail: mail, space: .work, coordinator: MailAccountCoordinator(), clientFactory: { _ in server }, passwordProvider: { _ in "fixture" })
        return .init(queue: queue, mail: mail, accounts: accounts, account: account, root: root, leaf: leaf, sibling: sibling, cached: cached, own: own, raw: raw, server: server, service: sync.folderOperations())
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }

    @Test("Create, rename and tree deletion use the reviewed paths, preserve rename associations, and never use message EXPUNGE")
    func normalLifecycle() async throws {
        let f = try await fixture()
        try await f.mail.setFolderFavorite(true, folderID: f.leaf.id)
        let create = try await f.service.review(accountID: f.account.id, kind: .create, name: "New folder")
        #expect(try await f.mail.folderMutationHistory(accountID: f.account.id).isEmpty)
        #expect(try await f.mail.folders(accountId: f.account.id).count == 3)
        let created = try await f.service.execute(create)
        #expect(created.state == .complete)
        let rename = try await f.service.review(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed")
        #expect(rename.serverMessageCount == 2 && rename.mutation.cachedMessageCount == 2)
        let renamed = try await f.service.execute(rename)
        #expect(renamed.state == .complete && renamed.completedProofs?[f.leaf.id] == .server)
        #expect(try await f.mail.folders(accountId: f.account.id).first { $0.id == f.leaf.id }?.path == "Renamed/Reports")
        #expect(try await f.mail.message(id: f.cached.id)?.folderId == f.leaf.id)
        #expect(try await f.mail.rawMessage(id: f.cached.id)?.data == f.raw)
        #expect(try await f.mail.folderPreferences().first?.isFavorite == true)
        let deletion = try await f.service.review(accountID: f.account.id, kind: .delete, folderID: f.root.id)
        let deleted = try await f.service.execute(deletion)
        #expect(deleted.state == .complete && Set(deleted.completedFolderIDs) == [f.root.id, f.leaf.id])
        #expect(await f.server.folderMutationCalls.filter { $0.kind == .delete }.map(\.path) == ["Renamed/Reports", "Renamed"])
        #expect(await f.server.expungeAllCalls.isEmpty)
        #expect(await f.server.expungeUIDCalls.isEmpty)
        #expect(try await f.mail.message(id: f.cached.id) == nil)
        #expect(try await f.mail.message(id: f.own.id) == nil)
        #expect(try await f.mail.folders(accountId: f.account.id).contains { $0.id == f.sibling.id })
        #expect(try await f.mail.pendingFolderMutation(accountID: f.account.id) == nil)
    }

    @Test("A server rejection preserves cache, a duplicate submission does not replay, and a newly discovered child requires another review")
    func rejectionAndChangedScope() async throws {
        let f = try await fixture()
        let review = try await f.service.review(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed")
        await f.server.configureFolderOperations(failure: .reject, kind: .rename)
        await #expect(throws: MailServerDiagnostic.self) { try await f.service.execute(review) }
        #expect(try await f.mail.folderMutationHistory(accountID: f.account.id).first?.state == .failed)
        #expect(try await f.mail.rawMessage(id: f.cached.id)?.data == f.raw)
        await #expect(throws: MailFolderMutationError.changed) { try await f.service.execute(review) }
        #expect(await f.server.folderMutationCalls.count == 1)
        await f.server.configureFolderOperations()
        let deletion = try await f.service.review(accountID: f.account.id, kind: .delete, folderID: f.root.id)
        let before = await f.server.folderSnapshot()
        await f.server.setFolderSnapshot(before + [.init(path: "Projects/New", name: "New", role: .other, delimiter: "/", isSelectable: true)])
        await #expect(throws: MailFolderMutationError.changed) { try await f.service.execute(deletion) }
        #expect(await f.server.folderMutationCalls.count == 1)
        #expect(try await f.mail.message(id: f.cached.id) != nil)
    }

    @Test("Unknown rename recovery reads only, requires explicit cache-reset consent, and preserves generated originals even with a server UID")
    func unknownRenameRecovery() async throws {
        let f = try await fixture(ownServerUID: true)
        try await f.mail.setFlags(messageId: f.cached.id, isRead: true, pendingRemote: true)
        try await f.mail.setFlags(messageId: f.own.id, isRead: true, pendingRemote: true)
        let review = try await f.service.review(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed")
        await f.server.configureFolderOperations(failure: .afterApply, kind: .rename)
        await #expect(throws: MailProtocolError.self) { try await f.service.execute(review) }
        #expect(try await f.mail.pendingFolderMutation(accountID: f.account.id)?.state == .unknown)
        await #expect(throws: MailFolderMutationError.pending) { try await f.service.refresh(accountID: f.account.id) }
        let recovery = try await f.service.inspectPending(accountID: f.account.id)
        #expect(recovery.disposition == .resetCache && recovery.resetMessageCount == 1)
        await #expect(throws: MailFolderMutationError.changed) { try await f.service.finishRecovery(recovery) }
        #expect(try await f.mail.rawMessage(id: f.cached.id)?.data == f.raw)
        let completed = try await f.service.finishRecovery(recovery, resetCacheConfirmed: true)
        #expect(completed.state == .complete && completed.completedProofs?[f.root.id] == .reviewed)
        #expect(await f.server.folderMutationCalls.count == 1)
        #expect(try await f.mail.message(id: f.cached.id) == nil)
        let own = try #require(try await f.mail.message(id: f.own.id))
        #expect(own.uid >= MailService.localUIDFloor && own.folderId == f.leaf.id && own.isRead)
        #expect(try await f.mail.rawMessage(id: own.id)?.kind == .generated)
        #expect(try await f.mail.body(messageId: own.id)?.textBody == "Owned original")
        #expect(try await f.mail.pendingFlags(folderID: f.leaf.id).isEmpty)
        try await f.service.refresh(accountID: f.account.id)
        #expect(try await f.mail.folders(accountId: f.account.id).first { $0.id == f.leaf.id }?.path == "Renamed/Reports")
    }

    @Test("A known rename ACK with changed UIDVALIDITY keeps cache protected until explicit recovery and rejects stale recovery inventories")
    func changedIdentityRecovery() async throws {
        let f = try await fixture()
        let review = try await f.service.review(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed")
        await f.server.configureFolderOperations(renamedValidity: 999)
        await #expect(throws: MailFolderMutationError.identityUnavailable) { try await f.service.execute(review) }
        #expect(try await f.mail.pendingFolderMutation(accountID: f.account.id)?.state == .acknowledged)
        let recovery = try await f.service.inspectPending(accountID: f.account.id)
        #expect(recovery.disposition == .resetCache)
        let arrived = MailMessage(accountId: f.account.id, folderId: f.leaf.id, uid: 4, messageId: "<late@example.test>")
        try await f.mail.upsertMessages([arrived])
        await #expect(throws: MailFolderMutationError.changed) { try await f.service.finishRecovery(recovery, resetCacheConfirmed: true) }
        #expect(try await f.mail.message(id: f.cached.id) != nil)
        #expect(try await f.mail.message(id: arrived.id) != nil)
        let fresh = try await f.service.inspectPending(accountID: f.account.id)
        #expect(fresh.resetMessageCount == 2)
        _ = try await f.service.finishRecovery(fresh, resetCacheConfirmed: true)
        #expect(await f.server.folderMutationCalls.count == 1)
        #expect(try await f.mail.message(id: f.own.id)?.uid == f.own.uid)
    }

    @Test("Repeated read-only inspections of unchanged mailboxes do not invalidate an earlier recovery review")
    func stableRecoveryReview() async throws {
        for _ in 0..<12 {
            let f = try await fixture()
            let plan = try await f.service.review(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed")
            await f.server.configureFolderOperations(failure: .afterApply, kind: .rename)
            await #expect(throws: MailProtocolError.self) { try await f.service.execute(plan) }
            let first = try await f.service.inspectPending(accountID: f.account.id)
            for _ in 0..<3 {
                let fresh = try await f.service.inspectPending(accountID: f.account.id)
                #expect(fresh.record == first.record && fresh.disposition == first.disposition)
            }
            let result = try await f.service.finishRecovery(first, resetCacheConfirmed: true)
            #expect(result.state == .complete)
            #expect(await f.server.folderMutationCalls.count == 1)
            #expect(try await f.mail.rawMessage(id: f.own.id)?.kind == .generated)
        }
    }

    @Test("Cache writes from an older directory snapshot cannot change a folder after it has been renamed")
    func staleCacheTransactions() async throws {
        let f = try await fixture()
        try await f.mail.setFlags(messageId: f.cached.id, isRead: true, pendingRemote: true)
        let pending = try #require(try await f.mail.pendingFlags(folderID: f.leaf.id).first)
        let plan = try await f.service.review(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed")
        _ = try await f.service.execute(plan)
        let late = MailMessage(accountId: f.account.id, folderId: f.leaf.id, uid: 3, subject: "Stale summary")
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.upsertMessages([late], expectedFolder: f.leaf) }
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.clearMessages(folderId: f.leaf.id, expectedFolder: f.leaf) }
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.clearCoverage(folderID: f.leaf.id, expectedFolder: f.leaf) }
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.reconcile(folderID: f.leaf.id, previouslyCached: [1], remote: [], seen: [], starred: [], expectedFolder: f.leaf) }
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.updateFolderSync(folderId: f.leaf.id, uidValidity: 999, uidNext: 4, unread: 0, total: 0, expectedFolder: f.leaf) }
        await #expect(throws: MailFolderMutationError.changed) { try await f.mail.acknowledgeFlags(pending, expectedFolder: f.leaf) }
        #expect(try await f.mail.message(id: late.id) == nil)
        #expect(try await f.mail.rawMessage(id: f.cached.id)?.data == f.raw)
        #expect(try await f.mail.pendingFlags(folderID: f.leaf.id).count == 1)
        #expect(try await f.mail.folders(accountId: f.account.id).first { $0.id == f.leaf.id }?.uidValidity == 41)
    }

    @Test("An independent sync reading before a rename rejects its late summaries at the cache transaction")
    func independentSyncDuringRename() async throws {
        let f = try await fixture()
        let (released, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let summary = RemoteMessageSummary(uid: 3, messageId: "<stale@example.test>", subject: "Late old-path result", from: [], to: [], cc: [], date: nil, isRead: false, isStarred: false, sizeBytes: 1, snippet: "")
        let client = MockMailClient(statuses: [f.leaf.path: .init(uidValidity: 41, uidNext: 4, messageCount: 2, unreadCount: 2)],
            summaries: [f.leaf.path: [summary]], summaryReadGate: {
                for await _ in released { break }
            })
        // Independent coordinators model another process's read already in flight.
        let sync = MailSyncService(accountService: f.accounts, mail: MailService(databaseQueue: f.queue), space: .work,
            coordinator: MailAccountCoordinator(), clientFactory: { _ in client }, passwordProvider: { _ in "fixture" })
        let reading = Task { try await sync.syncFolder(accountId: f.account.id, folderId: f.leaf.id) }
        defer { reading.cancel(); release.finish() }
        try await waitUntil { await client.summaryFetchCount == 1 }
        let rename = try await f.service.review(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed")
        _ = try await f.service.execute(rename)
        release.yield(()); release.finish()
        await #expect(throws: MailFolderMutationError.changed) { try await reading.value }
        #expect(try await f.mail.messages(folderId: f.leaf.id).allSatisfy { $0.uid != summary.uid })
        #expect(try await f.mail.rawMessage(id: f.cached.id)?.data == f.raw)
        #expect(try await f.mail.folders(accountId: f.account.id).first { $0.id == f.leaf.id }?.path == "Renamed/Reports")
    }

    @Test("Cancelling after a server delete preserves an unknown step; recovery settles that step without deleting its parent")
    func cancelledDeleteRecovery() async throws {
        let f = try await fixture()
        let review = try await f.service.review(accountID: f.account.id, kind: .delete, folderID: f.root.id)
        await f.server.configureFolderOperations(failure: .hangAfterApply, kind: .delete)
        let task = Task { try await f.service.execute(review) }
        try await waitUntil { await f.server.folderMutationCalls.count == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await f.mail.pendingFolderMutation(accountID: f.account.id)?.state == .unknown)
        let recovery = try await f.service.inspectPending(accountID: f.account.id)
        #expect(recovery.disposition == .applyObserved)
        let settled = try await f.service.finishRecovery(recovery)
        #expect(settled.state == .cancelled && settled.completedFolderIDs == [f.leaf.id])
        #expect(await f.server.folderMutationCalls.count == 1)
        #expect(await f.server.folderSnapshot().contains { $0.path == f.root.path })
        #expect(try await f.mail.folders(accountId: f.account.id).contains { $0.id == f.root.id })
        #expect(try await f.mail.pendingFolderMutation(accountID: f.account.id) == nil)
    }

    @Test("Prepared intents can be ended without credentials, and recovery cannot be reused against an identically restored database")
    func originAndUnsubmitted() async throws {
        let f = try await fixture()
        let plan = try await f.mail.reviewFolderMutation(accountID: f.account.id, kind: .rename, folderID: f.root.id, name: "Renamed")
        _ = try await f.mail.beginFolderMutation(plan)
        let review = try await f.service.inspectPending(accountID: f.account.id)
        #expect(review.disposition == .keepOriginal)
        #expect(await f.server.connectCount == 0)
        let backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let clone = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(clone)
        let store = SpaceDatabaseBackupStore(queue: clone, space: "work")
        _ = try await store.apply(store.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        let foreign = MailSyncService(accountService: MailAccountService(databaseQueue: clone, space: .work), mail: MailService(databaseQueue: clone), space: .work,
            clientFactory: { _ in f.server }, passwordProvider: { _ in "fixture" }).folderOperations()
        await #expect(throws: MailFolderMutationError.changed) { try await foreign.finishRecovery(review) }
        let ended = try await f.service.finishRecovery(review)
        #expect(ended.state == .cancelled && ended.completedFolderIDs.isEmpty)
        #expect(await f.server.folderMutationCalls.isEmpty)
        #expect(try await f.mail.rawMessage(id: f.cached.id)?.data == f.raw)
    }
}
