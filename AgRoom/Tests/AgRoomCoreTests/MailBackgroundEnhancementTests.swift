import AppKit
import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor @Suite("Mail preparation queue and automatic inbox polling", .serialized)
struct MailBackgroundEnhancementTests {
    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition())
    }
    @Test("Paused attachment requests coalesce, cancellation releases every waiter, and stale source retries keep their original proof")
    func attachmentQueue() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue), accounts = MailAccountService(databaseQueue: queue, space: .work)
        let account = try await mail.createLocalArchive(name: "Attachment archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let folders = try await mail.folders(accountId: account.id)
        let inbox = try #require(folders.first { $0.role == .inbox }), archive = try #require(folders.first { $0.role == .archive })
        let file = MailDraftAttachment(filename: "owned.bin", mimeType: "application/octet-stream", data: Data([0, 255, 128, 13, 10]))
        let raw = try MailSmtpAdapter.serializedMessage(.init(from: .init(name: "", address: "sender@example.test"),
            to: [], subject: "Owned attachment", bodyText: "Body", messageId: "<attachment@test>", attachments: [file]), date: Date())
        let message = MailMessage(accountId: account.id, folderId: inbox.id, uid: MailService.localUIDFloor,
            messageId: "<attachment@test>", subject: "Owned attachment", hasAttachments: true, bodyState: .ready)
        try await mail.upsertMessages([message])
        try await mail.saveRawMessage(id: message.id, raw: .init(data: raw, kind: .imported))
        let attachment = MailAttachment(messageId: message.id, filename: file.filename, mimeType: file.mimeType,
            sizeBytes: file.data.count, partID: "local:0")
        try await mail.saveAttachments([attachment])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = MailAttachmentQueue(hub: hub, space: .work)
        model.makeSyncService = { MailSyncService(accountService: accounts, mail: mail, space: .work,
            attachmentDirectory: directory, clientFactory: { _ in MockMailClient() }, passwordProvider: { _ in nil }) }
        model.togglePaused()
        let first = Task { await model.request(attachment, source: message) }
        let second = Task { await model.request(attachment, source: message) }
        try await waitUntil { model.entries.count == 1 && model.activeCount == 1 }
        #expect(model.entries.first?.state == .queued)
        model.togglePaused()
        let url = try #require(await first.value), otherURL = try #require(await second.value)
        #expect(url == otherURL && model.entries.count == 1 && model.entries.first?.state == .complete)
        #expect(try Data(contentsOf: url) == file.data && model.entries.first?.bytes == file.data.count)
        model.clearFinished()
        #expect(model.entries.isEmpty && FileManager.default.fileExists(atPath: url.path))
        model.togglePaused()
        let cancelled = Task { await model.request(attachment, source: message) }
        try await waitUntil { model.entries.count == 1 }
        model.cancelAll()
        #expect(await cancelled.value == nil && model.entries.first?.state == .cancelled)
        model.clearFinished()
        let stale = Task { await model.request(attachment, source: message) }
        try await waitUntil { model.entries.count == 1 }
        try await mail.moveMessage(id: message.id, toFolderId: archive.id, uid: message.uid)
        model.togglePaused()
        #expect(await stale.value == nil)
        #expect(model.entries.first?.state == .failed)
        let id = try #require(model.entries.first?.id)
        model.retry(id)
        try await waitUntil { model.entries.count == 2 && model.entries.last?.state == .failed }
        #expect(model.entries.allSatisfy { $0.source.folderId == inbox.id })
        model.cancelAll()
    }

    @Test("Automatic sync suppresses historical mail, announces only later unread inbox mail, and resets after UIDVALIDITY changes")
    func automaticInbox() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue), accounts = MailAccountService(databaseQueue: queue, space: .work)
        let account = MailAccount(displayName: "Synthetic", emailAddress: "reader@example.test", imapHost: "imap.example.test",
            smtpHost: "smtp.example.test", username: "reader@example.test")
        var disabled = account; disabled.id = UUID(); disabled.isEnabled = false
        let stoppedAccount = disabled
        try await queue.write { db in
            var row = MailAccountRow(from: account); try row.insert(db)
            var stopped = MailAccountRow(from: stoppedAccount); try stopped.insert(db)
        }
        _ = try await mail.createLocalArchive(name: "Offline", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let inbox = RemoteMailFolder(path: "INBOX", name: "Inbox", role: .inbox), sent = RemoteMailFolder(path: "Sent", name: "Sent", role: .sent)
        func summary(_ uid: UInt32, read: Bool = false) -> RemoteMessageSummary {
            .init(uid: uid, messageId: "<\(uid)@example.test>", subject: "Synthetic \(uid)", from: [], to: [], cc: [], date: nil,
                isRead: read, isStarred: false, sizeBytes: 100, snippet: "")
        }
        let initial = summary(1)
        let client = MockMailClient(folders: [inbox, sent], statuses: ["INBOX": .init(uidValidity: 41, uidNext: 2, messageCount: 1, unreadCount: 1),
            "Sent": .init(uidValidity: 42, uidNext: 2, messageCount: 1, unreadCount: 1)],
            summaries: ["INBOX": [initial], "Sent": [summary(1)]])
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), prefs = try #require(hub.makeProductPreferencesService(for: .work))
        var settings = MailAutoSyncSettings(); settings.enabled = true; settings.notifications = true
        try await prefs.save(settings, key: "mail.autoSync")
        var notices: [Int] = []
        func pass() async throws {
            let model = MailAutoSyncController(hub: hub, space: .work)
            model.makeSyncService = { MailSyncService(accountService: accounts, mail: mail, space: .work,
                coordinator: MailAccountCoordinator(), clientFactory: { _ in client }, passwordProvider: { _ in "synthetic" }) }
            model.notificationSink = { notices.append($0) }
            let task = Task { await model.monitor() }
            try await waitUntil { model.lastSynced != nil && !model.isSyncing }
            #expect(model.failures.isEmpty && model.error == nil)
            task.cancel(); await task.value
        }
        try await pass()
        #expect(notices.isEmpty)
        #expect(try await mail.messageCount(in: .account(account.id)) == 1)
        #expect(await client.fetchRequests.allSatisfy { $0.path == "INBOX" })
        await client.replaceSummarySnapshot(path: "INBOX", values: [initial, summary(2), summary(3, read: true)],
            status: .init(uidValidity: 41, uidNext: 4, messageCount: 3, unreadCount: 2))
        try await pass()
        #expect(notices == [1])
        await client.replaceSummarySnapshot(path: "INBOX", values: [summary(20)],
            status: .init(uidValidity: 99, uidNext: 21, messageCount: 1, unreadCount: 1))
        try await pass()
        #expect(notices == [1])
        let baseline = try #require(try await prefs.load(MailAutoSyncBaseline.self, key: "mail.autoSync.baseline"))
        #expect(baseline.stamps.count == 1 && baseline.stamps.values.first?.uidValidity == 99)
        let backup = try await SpaceDatabaseBackupStore(queue: queue, space: "work").export()
        let targetQueue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(targetQueue)
        let target = SpaceDatabaseBackupStore(queue: targetQueue, space: "work")
        _ = try await target.apply(target.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        let restoredPrefs = ProductPreferencesService(databaseQueue: targetQueue)
        let restored = try #require(try await restoredPrefs.load(MailAutoSyncSettings.self, key: "mail.autoSync"))
        #expect(!restored.enabled && !restored.notifications)
        #expect(try await restoredPrefs.load(MailAutoSyncBaseline.self, key: "mail.autoSync.baseline")?.stamps.isEmpty == true)
    }
}
