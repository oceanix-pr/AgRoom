import CryptoKit
import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Explicit server draft lifecycle")
struct MailServerDraftTests {
    @Test("Draft MIME preserves the stable identifier selected before the server claim")
    func serializedIdentity() throws {
        let account = MailAccount(displayName: "Synthetic", emailAddress: "sender@example.test", imapHost: "imap.example.test",
            smtpHost: "smtp.example.test", username: "sender@example.test")
        let draft = MailDraft(accountId: account.id, subject: "Identity", bodyText: "Owned text",
            attachments: [.init(filename: "identity.bin", mimeType: "application/octet-stream", data: Data([0, 255, 128]))])
        let id = "<draft.\(UUID().uuidString)@agroom.local>"
        let bytes = try MailSmtpAdapter.serializedDraft(draft, account: account, messageID: id, date: Date())
        #expect(try MailFoundationAdapter.originalMessageID(bytes) == id)
        #expect(try MailFoundationAdapter.importedEnvelope(bytes).messageID == id)
    }
    struct Fixture: Sendable {
        let queue: DatabaseQueue
        let mail: MailService
        let account: MailAccount
        let folder: MailFolder
        let draft: MailDraft
        let client: MockMailClient
        let sender: MockSendClient
        let sync: MailSyncService
        var service: MailServerDraftService { sync.serverDrafts() }
    }
    func fixture(uidPlus: Bool = true, noopDelete: Bool = false, sendClient: MockSendClient = MockSendClient(),
                 budget: MailTimeoutBudget = .default) async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let account = MailAccount(displayName: "Synthetic sender", emailAddress: "sender@example.test",
            imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "sender@example.test")
        try await queue.write { db in var row = MailAccountRow(from: account); try row.insert(db) }
        let mail = MailService(databaseQueue: queue)
        let folder = MailFolder(accountId: account.id, path: "Drafts", name: "Drafts", role: .drafts, uidValidity: 41)
        let sent = MailFolder(accountId: account.id, path: "Sent", name: "Sent", role: .sent, uidValidity: 42)
        try await mail.upsertFolders([folder, sent])
        let draft = MailDraft(accountId: account.id, to: [.init(name: "Recipient", address: "to@example.test")],
            bcc: [.init(name: "Private", address: "private@example.test")], subject: "Synthetic draft", bodyText: "User body", quotedText: "> original",
            attachments: [.init(filename: "proof.bin", mimeType: "application/octet-stream", data: Data([0, 128, 255, 13, 10]))], forwardAttachmentsState: .omitted)
        try await mail.saveEditableDraft(draft)
        let other = RemoteMessageSummary(uid: 99, messageId: "<unrelated@example.test>", subject: "Other pending deletion",
            from: [], to: [], cc: [], date: nil, isRead: false, isStarred: false, sizeBytes: 10, snippet: "")
        let client = MockMailClient(statuses: [folder.path: .init(uidValidity: 41, uidNext: 100, messageCount: 1, unreadCount: 1)],
            summaries: [folder.path: [other]], supportsUIDPlus: uidPlus, expungeNoop: noopDelete)
        await client.markDeletedOnServer(path: folder.path, uids: [99])
        let sender = sendClient
        let sync = MailSyncService(accountService: MailAccountService(databaseQueue: queue, space: .work), mail: mail,
            space: .work, coordinator: MailAccountCoordinator(), clientFactory: { _ in client }, sendClientFactory: { _ in sender },
            passwordProvider: { _ in "synthetic" }, timeoutBudget: budget)
        return .init(queue: queue, mail: mail, account: account, folder: folder, draft: draft, client: client, sender: sender, sync: sync)
    }

    @Test("Review writes nothing, repeat saves append once, replacement removes only the exact prior UID")
    func replacement() async throws {
        let f = try await fixture()
        let review = try await f.service.reviewSave(f.draft)
        #expect(await f.client.draftAppendCount == 0)
        #expect(try await f.mail.serverDraftRecord(id: f.draft.id) == nil)
        let first = try await f.service.save(review), old = try #require(first.current)
        #expect(first.pending == nil && first.previous == nil && old.uid == 100)
        let stored = try await f.client.fetchRawMessage(path: f.folder.path, uid: 100, maxBytes: MailService.rawMessageByteLimit)
        let decoded = try MailSmtpAdapter.decodedDraft(stored, id: f.draft.id, accountID: f.account.id)
        #expect(decoded.bcc == f.draft.bcc && decoded.attachments.first?.data == f.draft.attachments.first?.data)
        let again = try await f.service.reviewSave(f.draft)
        #expect(again.unchanged)
        _ = try await f.service.save(again)
        #expect(await f.client.draftAppendCount == 1)
        await #expect(throws: MailServerDraftError.changed) { try await f.service.save(review) }
        var edited = f.draft; edited.bodyText = "Updated body"; edited.updatedAt = Date()
        try await f.mail.saveEditableDraft(edited)
        let next = try await f.service.reviewSave(edited)
        #expect(next.replacesPrevious)
        let result = try await f.service.save(next)
        #expect(result.current?.uid == 101 && result.previous == nil && result.pending == nil)
        #expect(await f.client.draftAppendCount == 2)
        #expect(await f.client.expungeUIDCalls.map(\.uids) == [[100]])
        #expect(await f.client.searchDeleted(path: f.folder.path) == [99])
        #expect(await f.client.expungeAllCalls.isEmpty)
    }

    @Test("Lost APPEND response persists a claim across service recreation; reconciliation never uploads again")
    func unknownAppend() async throws {
        let f = try await fixture(), review = try await f.service.reviewSave(f.draft)
        await f.client.configureDraftFailure(.afterAppend)
        await #expect(throws: MailProtocolError.self) { try await f.service.save(review) }
        let unknown = try #require(try await f.mail.serverDraftRecord(id: f.draft.id))
        #expect(unknown.pending != nil && unknown.current == nil)
        await #expect(throws: MailServerDraftError.unresolved) { try await f.service.reviewSave(f.draft) }
        let recovered = try await f.sync.serverDrafts().reconcile(draftID: f.draft.id)
        #expect(recovered.pending == nil && recovered.current?.uid == 100)
        let appendCount = await f.client.draftAppendCount
        let expungeCalls = await f.client.expungeUIDCalls
        #expect(appendCount == 1 && expungeCalls.isEmpty)
        let before = try await fixture(), untouched = try await before.service.reviewSave(before.draft)
        await before.client.configureDraftFailure(.beforeAppend)
        await #expect(throws: MailProtocolError.self) { try await before.service.save(untouched) }
        await #expect(throws: MailServerDraftError.unresolved) { try await before.service.reconcile(draftID: before.draft.id) }
        let pending = try #require(try await before.mail.serverDraftRecord(id: before.draft.id))
        let abandoned = try await before.service.abandonUpload(pending)
        #expect(abandoned.pending == nil && abandoned.abandonedMessageIDs == [pending.pending!.messageID])
        #expect(await before.client.draftAppendCount == 1)
        let model = await MailComposeViewModel(draft: before.draft, space: .work,
            hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: before.queue)),
            fromDescription: before.account.emailAddress, isAIPanelVisible: false)
        await model.loadIfNeeded()
        #expect(await model.serverDraftStatusKey == "mail.serverDraft.localOnly")
        await model.onWindowClosed()
    }

    @Test("Remote edits and stale local previews block writes; explicit remote adoption preserves all recipients and attachments")
    func conflictsAndRead() async throws {
        let f = try await fixture(), first = try await f.service.save(f.service.reviewSave(f.draft))
        let version = try #require(first.current)
        var local = f.draft; local.bodyText = "Local edit"; local.updatedAt = Date()
        try await f.mail.saveEditableDraft(local)
        let review = try await f.service.reviewSave(local)
        var external = f.draft; external.bodyText = "External edit"
        let bytes = try MailSmtpAdapter.serializedDraft(external, account: f.account, messageID: version.messageID, date: version.createdAt)
        await f.client.changeDraftRaw(uid: version.uid!, data: bytes)
        await #expect(throws: MailServerDraftError.conflict) { try await f.service.save(review) }
        #expect(await f.client.draftAppendCount == 1)
        let read = try await f.service.reviewRead(draftID: f.draft.id)
        #expect(read.remoteChanged && read.draft.bodyText.contains("External edit") && read.draft.bcc == external.bcc)
        #expect(read.draft.attachments.first?.data == external.attachments.first?.data)
        var newer = local; newer.bodyText = "Newer local edit"; newer.updatedAt = Date()
        try await f.mail.saveEditableDraft(newer)
        await #expect(throws: MailServerDraftError.changed) { try await f.service.adopt(read, replacing: local) }
        let refreshed = try await f.service.reviewRead(draftID: f.draft.id)
        let adopted = try await f.service.adopt(refreshed, replacing: newer)
        #expect(adopted.bodyText.contains("External edit"))
        #expect(try await f.mail.draft(id: f.draft.id)?.bodyText == adopted.bodyText)
        #expect(await f.client.draftAppendCount == 1)
    }

    @Test("A retained old version has a separate cleanup receipt and can be explicitly kept")
    func incompleteCleanup() async throws {
        let f = try await fixture(noopDelete: true)
        _ = try await f.service.save(f.service.reviewSave(f.draft))
        var next = f.draft; next.bodyText = "Next"; next.updatedAt = Date()
        try await f.mail.saveEditableDraft(next)
        let review = try await f.service.reviewSave(next)
        await #expect(throws: MailServerDraftError.unresolved) { try await f.service.save(review) }
        let record = try #require(try await f.mail.serverDraftRecord(id: f.draft.id))
        #expect(record.current?.uid == 101 && record.previous?.uid == 100 && record.pending == nil)
        await #expect(throws: MailServerDraftError.unresolved) { try await f.service.reviewSave(next) }
        let kept = try await f.service.keepPreviousCopy(record)
        #expect(kept.previous == nil && kept.abandonedMessageIDs == [record.previous!.messageID])
        let appendCount = await f.client.draftAppendCount
        let expungeCalls = await f.client.expungeAllCalls
        #expect(appendCount == 2 && expungeCalls.isEmpty)
    }

    @Test("UIDPLUS, originating database, account changes and independent delivery proof gate server writes")
    func boundaries() async throws {
        let unsupported = try await fixture(uidPlus: false)
        await #expect(throws: MailServerDraftError.unsupported) { try await unsupported.service.reviewSave(unsupported.draft) }
        #expect(await unsupported.client.draftAppendCount == 0)
        let f = try await fixture(), review = try await f.service.reviewSave(f.draft), other = try await fixture()
        await #expect(throws: MailServerDraftError.changed) { try await other.service.save(review) }
        let saved = try await f.service.save(review)
        await #expect(throws: MailServerDraftError.changed) { try await f.service.finishDeliveredCleanup(saved) }
        #expect(await f.client.expungeUIDCalls.isEmpty)
        try await f.queue.write { db in try db.execute(sql: "UPDATE mail_accounts SET imapHost='changed.example.test' WHERE id=?", arguments: [f.account.id.uuidString]) }
        await #expect(throws: MailServerDraftError.changed) { try await f.service.reviewRead(draftID: f.draft.id) }
        #expect(await f.client.draftAppendCount == 1)
    }

    @Test("Confirmed SMTP delivery removes only its linked draft and never leaks the private draft Bcc header")
    func delivery() async throws {
        let f = try await fixture()
        _ = try await f.service.save(f.service.reviewSave(f.draft))
        _ = try await f.sync.send(draft: f.draft)
        let record = try #require(try await f.mail.serverDraftRecord(id: f.draft.id))
        #expect(record.retiredAt != nil && record.current == nil && record.retiringAfterSend == false)
        #expect(try await f.mail.draft(id: f.draft.id) == nil)
        let sent = try #require(await f.sender.sent.first)
        #expect(sent.bcc == f.draft.bcc)
        let bytes = try #require(sent.serializedData)
        let decoded = try MailSmtpAdapter.decodedDraft(bytes, id: f.draft.id, accountID: f.account.id)
        #expect(decoded.bcc.isEmpty && decoded.attachments.first?.data == f.draft.attachments.first?.data)
        #expect(await f.client.expungeUIDCalls.map(\.uids) == [[100]])
        #expect(await f.client.searchDeleted(path: f.folder.path) == [99])
    }

    @Test("Unknown SMTP delivery never retires the linked server draft or permits ordinary resend")
    func unknownDeliveryKeepsDraft() async throws {
        let f = try await fixture(sendClient: MockSendClient(hangsOnSend: true), budget: .init(send: 40))
        _ = try await f.service.save(f.service.reviewSave(f.draft))
        await #expect(throws: MailProtocolError.self) { try await f.sync.send(draft: f.draft) }
        let retained = try #require(try await f.mail.draft(id: f.draft.id))
        #expect(retained.deliveryState == .unknown)
        let receipt = try #require(try await f.mail.serverDraftRecord(id: f.draft.id))
        #expect(receipt.current?.uid == 100 && receipt.retiringAfterSend != true && receipt.retiredAt == nil)
        #expect(await f.client.expungeUIDCalls.isEmpty)
        await #expect(throws: MailSyncError.self) { try await f.sync.send(draft: f.draft) }
    }

    @Test("Post-delivery cleanup failure retains delivery proof and Sent copy and cannot trigger a second SMTP send")
    func deliveredCleanupFailure() async throws {
        let f = try await fixture(noopDelete: true)
        _ = try await f.service.save(f.service.reviewSave(f.draft))
        do {
            _ = try await f.sync.send(draft: f.draft)
            Issue.record("Expected cleanup verification failure after confirmed delivery")
        } catch let error as MailDeliveredLocalSaveError { #expect(error.serverDraftCleanup) }
        let retained = try #require(try await f.mail.draft(id: f.draft.id))
        #expect(retained.deliveredAt != nil && retained.deliveryState == .accepted)
        let receipt = try #require(try await f.mail.serverDraftRecord(id: f.draft.id))
        #expect(receipt.retiringAfterSend == true && receipt.current?.uid == 100)
        #expect(try await f.mail.messageCount(in: .account(f.account.id)) == 1)
        await #expect(throws: MailSyncError.draftAlreadyDelivered) { try await f.sync.send(draft: f.draft) }
        #expect(await f.sender.sent.count == 1)
    }

    @Test("Backup receipts require reconciliation and never overwrite target receipts")
    func backup() async throws {
        let f = try await fixture()
        let saved = try await f.service.save(f.service.reviewSave(f.draft))
        let source = SpaceDatabaseBackupStore(queue: f.queue, space: "work"), backup = try await source.export()
        let targetQueue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(targetQueue)
        let target = SpaceDatabaseBackupStore(queue: targetQueue, space: "work")
        _ = try await target.apply(target.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        let restored = try #require(try await MailService(databaseQueue: targetQueue).serverDraftRecord(id: f.draft.id))
        #expect(restored.needsReconciliation && restored.current?.sha256 == saved.current?.sha256)
        _ = try await source.apply(source.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        #expect(try await f.mail.serverDraftRecord(id: f.draft.id) == saved)
    }
}
