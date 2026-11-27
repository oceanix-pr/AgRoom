import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
import Vision
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
@Suite("Mail unified inbox and conversation readers")
struct MailInboxConversationModelTests {
    private struct Fixture {
        let queue: DatabaseQueue
        let mail: MailService
        let accounts: MailAccountService
        let hub: Hub
        let remote: [MailAccount]
        let local: MailAccount
        let inboxes: [MailFolder]
        let sent: MailFolder
        let localInbox: MailFolder
        let localArchive: MailFolder
    }

    private func fixture() async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue), accounts = MailAccountService(databaseQueue: queue, space: .work)
        let remote = (0..<3).map { index in
            MailAccount(displayName: "Account \(index)", emailAddress: "\(index)@example.test", imapHost: "imap.example.test",
                smtpHost: "smtp.example.test", username: "\(index)@example.test", isEnabled: index < 2, createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        for account in remote { try await accounts.save(account, password: nil) }
        let inboxes = remote.map { MailFolder(accountId: $0.id, path: "INBOX", name: "Inbox", role: .inbox) }
        let sent = MailFolder(accountId: remote[0].id, path: "Sent", name: "Sent", role: .sent)
        try await mail.upsertFolders(inboxes + [sent])
        let local = try await mail.createLocalArchive(name: "Local archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let localFolders = try await mail.folders(accountId: local.id)
        return .init(queue: queue, mail: mail, accounts: accounts, hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)),
            remote: remote, local: local, inboxes: inboxes, sent: sent,
            localInbox: try #require(localFolders.first { $0.role == .inbox }), localArchive: try #require(localFolders.first { $0.role == .archive }))
    }

    private func summary(_ subject: String = "New mail") -> RemoteMessageSummary {
        .init(uid: 1, messageId: "<new@test>", subject: subject, from: [.init(name: "Sender", address: "sender@test")],
            to: [], cc: [], date: Date(timeIntervalSince1970: 20), isRead: false, isStarred: false, sizeBytes: 100, snippet: "", references: "<parent@test>")
    }

    private func service(_ f: Fixture, clients: [UUID: MockMailClient], missingPassword: UUID? = nil, directory: URL? = nil) -> MailSyncService {
        MailSyncService(accountService: f.accounts, mail: f.mail, space: .work, coordinator: MailAccountCoordinator(), attachmentDirectory: directory,
            clientFactory: { account in clients[account.id]! }, passwordProvider: { $0 == missingPassword ? nil : "fixture" })
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await condition())
    }

    @Test("Opening marks just the reader's message, retains an unread search anchor and queues IMAP Seen offline")
    func openingUnreadMessages() async throws {
        let f = try await fixture(), folder = f.inboxes[0]
        try await f.mail.updateFolderSync(folderId: folder.id, uidValidity: 8, uidNext: 4, unread: 3, total: 3)
        let rows = (1...3).map { uid in
            MailMessage(accountId: folder.accountId, folderId: folder.id, uid: UInt32(uid),
                        messageId: "<\(uid)@test>", subject: "Message \(uid)", references: "<root@test>")
        }
        try await f.mail.upsertMessages(rows)
        try await f.mail.saveBody(.init(messageId: rows[0].id, textBody: "Cached reader body"))
        try await f.mail.setBodyState(messageId: rows[0].id, state: .ready)
        let model = MailViewModel(hub: f.hub, space: .work)
        let summaries = rows.map { row in
            RemoteMessageSummary(uid: row.uid, messageId: row.messageId, subject: row.subject, from: [],
                                 to: [], cc: [], date: nil, isRead: false, isStarred: false, sizeBytes: 100, snippet: "")
        }
        let mock = MockMailClient(statuses: ["INBOX": .init(uidValidity: 8, uidNext: 4, messageCount: 3, unreadCount: 3)],
                                  summaries: ["INBOX": summaries])
        model.makeSyncService = { service(f, clients: [folder.accountId: mock], missingPassword: folder.accountId) }
        await model.loadIfNeeded()
        await model.updateListFilter(.init(unreadOnly: true), scope: .inbox)
        model.setSelection([rows[0].id, rows[1].id])
        await Task.yield()
        #expect(try await f.mail.messageCount(in: .inbox, matching: .init(unreadOnly: true)) == 3)
        await model.selectMessage(rows[0].id)
        #expect(model.currentMessage?.isRead == true && model.body?.textBody == "Cached reader body")
        #expect(model.unifiedInboxUnreadCount == 2 && model.folder(for: rows[0])?.unreadCount == 2)
        await model.reloadMessages()
        #expect(model.currentMessage?.id == rows[0].id)
        #expect(try await f.mail.pendingFlags(folderID: folder.id).map(\.messageID) == [rows[0].id])
        await model.selectMessage(rows[1].id)
        #expect(model.currentMessage?.id == rows[1].id && model.currentMessage?.isRead == true)
        #expect(model.body == nil && model.errorText != nil)
        #expect(!model.messages.contains { $0.id == rows[0].id })
        #expect(try await f.mail.message(id: rows[2].id)?.isRead == false)
        model.cancelPendingWork()
        let online = service(f, clients: [folder.accountId: mock])
        try await online.flushOpenedFolder(rows[1])
        #expect(Set(await mock.flagCalls.filter { $0.add == [.seen] }.map(\.uid)) == [1, 2])
        #expect(try await f.mail.pendingFlags(folderID: folder.id).isEmpty)
        #expect(try await f.mail.markOpened(rows[2]))
        _ = try await online.syncFolder(accountId: folder.accountId, folderId: folder.id)
        #expect(try await f.mail.folders(accountId: folder.accountId).first { $0.id == folder.id }?.unreadCount == 0)
    }

    @Test("Conversation expansion marks its own message, and refresh preserves a manual mark-unread")
    func openingConversationCards() async throws {
        let f = try await fixture(), model = MailViewModel(hub: f.hub, space: .work)
        let rows = (1...3).map {
            MailMessage(accountId: f.local.id, folderId: f.localInbox.id, uid: MailService.localUIDFloor + UInt32($0),
                        messageId: "<card\($0)@test>", references: "<root@test>")
        }
        try await f.mail.upsertMessages(rows)
        await model.loadIfNeeded(); await model.selectAccount(f.local.id)
        model.setConversationVisible(true)
        await model.selectMessage(rows[0].id)
        try await waitUntil { model.conversationMessages.count == 3 }
        #expect(model.conversationMessages.filter(\.isRead).map(\.id) == [rows[0].id])
        await model.markOpened(rows[1])
        await model.toggleRead(try #require(model.messageForActions(rows[1].id)))
        await model.reloadMessages()
        #expect(try await f.mail.message(id: rows[1].id)?.isRead == false)
        #expect(try await f.mail.message(id: rows[2].id)?.isRead == false)
        #expect(try await f.mail.pendingFlags(folderID: f.localInbox.id).isEmpty)
        model.cancelPendingWork()
    }

    @Test("Unified inbox includes only actual local inbox metadata, preserves paging and saved scope, and exits through the retained folder")
    func unifiedLocalQuery() async throws {
        let f = try await fixture()
        let folders = f.inboxes + [f.localInbox]
        var messages: [MailMessage] = []
        for (index, folder) in folders.enumerated() {
            for offset in 0..<3 {
                let uid = folder.accountId == f.local.id ? MailService.localUIDFloor + UInt32(offset) : UInt32(offset + 1)
                let date: Date? = offset == 0 ? nil : Date(timeIntervalSince1970: 10)
                messages.append(MailMessage(accountId: folder.accountId, folderId: folder.id, uid: uid,
                    subject: "Inbox \(index)", date: date, isRead: offset == 2))
            }
        }
        let sent = MailMessage(accountId: f.remote[0].id, folderId: f.sent.id, uid: 1, subject: "Exclude sent")
        let archived = MailMessage(accountId: f.local.id, folderId: f.localArchive.id, uid: MailService.localUIDFloor + 10, subject: "Exclude archive")
        try await f.mail.upsertMessages(messages + [sent, archived])
        var cursor: MailService.MailPageCursor?, ids: [UUID] = []
        repeat {
            let page = try await f.mail.messages(in: .inbox, before: cursor, limit: 2)
            guard let last = page.last else { break }
            ids += page.map(\.id); cursor = .init(date: last.date, uid: last.uid, id: last.id)
        } while ids.count <= messages.count
        #expect(ids.count == messages.count && Set(ids) == Set(messages.map(\.id)))
        #expect(try await f.mail.messageCount(in: .inbox, matching: .init(unreadOnly: true)) == 8)
        let model = MailViewModel(hub: f.hub, space: .work)
        await model.loadIfNeeded(); await model.selectAccount(f.remote[0].id)
        let retainedFolder = try #require(model.selectedFolderId)
        await model.openUnifiedInbox()
        #expect(model.isUnifiedInbox && model.queryLocation == .inbox && model.unifiedInboxUnreadCount == 8 && model.coverage == nil)
        #expect(Set(model.messages.map(\.id)) == Set(messages.map(\.id)))
        #expect(model.sourceLabels.count == messages.count && model.moveTargets(for: Set(messages.map(\.id))).isEmpty)
        #expect(Set(try #require(await model.exportSearchIDs())) == Set(messages.map(\.id)))
        #expect(await model.saveSearch(name: "Unified unread", filter: .init(unreadOnly: true), scope: .inbox))
        let saved = try #require(model.savedSearches.first)
        #expect(saved.location == .inbox)
        await model.selectFolder(retainedFolder)
        #expect(!model.isUnifiedInbox && model.searchScope == .folder && model.messages.count == 3)
        #expect(await model.applySearch(saved) && model.isUnifiedInbox && model.messages.count == 8)
        let localUnread = try #require(model.messages.first { $0.accountId == f.local.id && !$0.isRead })
        await model.toggleRead(localUnread)
        #expect(model.unifiedInboxUnreadCount == 7 && model.messages.count == 7)
        await model.selectAccount(f.remote[0].id)
        #expect(!model.isUnifiedInbox && model.currentAccount?.id == f.remote[0].id)
        let backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let target = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(target)
        let store = SpaceDatabaseBackupStore(queue: target, space: "work")
        _ = try await store.apply(store.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        #expect(try await MailService(databaseQueue: target).savedSearches().first?.location == .inbox)
        #expect(try await MailService(databaseQueue: target).messageCount(in: .inbox) == messages.count)
        model.cancelPendingWork()
    }

    @Test("Unified refresh skips disabled and offline sources, fetches only inboxes, and continues after an account failure")
    func unifiedSyncAndFailures() async throws {
        let f = try await fixture(), model = MailViewModel(hub: f.hub, space: .work)
        await model.loadIfNeeded(); await model.openUnifiedInbox()
        let enabled = model.accounts.filter { $0.isEnabled && !$0.isLocalArchive }
        let fail = enabled[0].id, success = enabled[1].id
        let clients = Dictionary(uniqueKeysWithValues: f.remote.map { account in
            (account.id, MockMailClient(folders: [.init(path: "INBOX", name: "Inbox", role: .inbox), .init(path: "Sent", name: "Sent", role: .sent)],
                statuses: ["INBOX": .init(uidValidity: 1, uidNext: 2, messageCount: 1, unreadCount: 1)], summaries: ["INBOX": [summary()]]))
        })
        model.makeSyncService = { service(f, clients: clients, missingPassword: fail) }
        model.startSync()
        try await waitUntil { model.unifiedSyncFailures == [fail] && !model.isSyncing }
        #expect(await clients[success]?.fetchRequests.map(\.path) == ["INBOX"])
        #expect(await clients[f.remote[2].id]?.connectCount == 0)
        #expect(model.messages.count == 1 && model.messages[0].accountId == success && model.messages[0].references == "<parent@test>")
        #expect(model.errorText?.contains(enabled[0].displayName) == true && model.unifiedInboxUnreadCount == 1)
        #expect(try await f.mail.folders(accountId: success).contains { $0.role == .sent })
        model.cancelPendingWork()
    }

    @Test("Cancelling unified refresh disconnects the current account and does not start later accounts")
    func unifiedCancellation() async throws {
        let f = try await fixture(), model = MailViewModel(hub: f.hub, space: .work)
        await model.loadIfNeeded(); await model.openUnifiedInbox()
        let enabled = model.accounts.filter { $0.isEnabled && !$0.isLocalArchive }
        let clients = Dictionary(uniqueKeysWithValues: f.remote.map { account in
            (account.id, MockMailClient(folders: [.init(path: "INBOX", name: "Inbox", role: .inbox)],
                statuses: ["INBOX": .init(uidValidity: 1, uidNext: 2, messageCount: 1, unreadCount: 1)], hangPoint: .fetchSummaries))
        })
        model.makeSyncService = { service(f, clients: clients) }
        model.startSync()
        try await waitUntil { await clients[enabled[0].id]?.summaryFetchCount == 1 }
        model.cancelSync()
        try await waitUntil { !model.isSyncing }
        #expect(await clients[enabled[0].id]?.disconnectCount ?? 0 > 0)
        #expect(await clients[enabled[1].id]?.connectCount == 0)
        #expect(model.unifiedSyncFailures.isEmpty && model.errorText == nil)
        model.cancelPendingWork()
    }

    @Test("Conversation paging pins the selected anchor without skipping earlier cards, and related actions retain actual ownership")
    func conversationModelAndActions() async throws {
        let f = try await fixture(), model = MailViewModel(hub: f.hub, space: .work)
        let messages: [MailMessage] = (0..<121).map { index -> MailMessage in
            MailMessage(accountId: f.local.id, folderId: f.localInbox.id, uid: MailService.localUIDFloor + UInt32(index),
                messageId: "<\(index)@test>", subject: index == 120 ? "Anchor" : "Other", references: "<root@test>",
                date: Date(timeIntervalSince1970: Double(index)), bodyState: .ready)
        }
        try await f.mail.upsertMessages(messages)
        let anchor = messages[120], related = messages[10]
        try await f.mail.saveBody(.init(messageId: anchor.id, textBody: "Anchor body"))
        await model.loadIfNeeded(); await model.selectAccount(f.remote[0].id)
        await model.updateListFilter(.init(query: "Anchor"), scope: .space)
        model.setConversationVisible(true)
        await model.selectMessage(anchor.id)
        model.refreshConversation(keepingLoaded: false)
        try await waitUntil { !model.isLoadingConversation }
        #expect(model.messages.map(\.id) == [anchor.id] && model.conversationMessages.count == 51 && model.conversationHasMore)
        #expect(model.body == nil && !model.isLoadingBody)
        #expect(model.conversationMessages.last?.id == anchor.id && model.conversationMessages.prefix(50).map(\.id) == messages.prefix(50).map(\.id))
        try await f.mail.setReferences(messageId: anchor.id, references: "<root@test> <learned@test>")
        model.refreshConversation()
        try await waitUntil { !model.isLoadingConversation }
        #expect(model.conversationMessages.count == 51 && model.messageForActions(anchor.id)?.references == "<root@test> <learned@test>")
        while model.conversationHasMore { model.loadMoreConversation(); try await waitUntil { !model.isLoadingConversation } }
        #expect(model.conversationMessages.map(\.id) == messages.map(\.id))
        #expect(model.messageForActions(related.id)?.accountId == f.local.id)
        model.focusConversationMessage(related.id)
        #expect(model.readerActionMessage?.id == related.id && model.readerActionIDs == [related.id])
        #expect(model.moveTargets(for: [related.id]).contains { $0.id == f.localArchive.id })
        #expect(model.replyDraft(for: related).sourceMessageId == related.id && model.replyDraft(for: related).accountId == model.composeAccount?.id)
        model.performBatch(ids: [related.id], action: .move(f.localArchive.id))
        try await waitUntil { !model.isPerformingBatch && !model.isLoadingConversation }
        #expect(model.currentMessage?.id == anchor.id && model.messageForActions(related.id)?.folderId == f.localArchive.id)
        #expect(model.sourceDescription(for: try #require(model.messageForActions(related.id))).contains(f.localArchive.displayName))
        model.refreshConversation()
        await model.updateListFilter(.init(query: "Absent"), scope: .space)
        #expect(model.conversationMessages.isEmpty && model.selectedMessageId == nil && !model.isLoadingConversation)
        model.cancelPendingWork()
    }

    @Test("A card reads only its originating mail and space, releases bytes when collapsed, and rejects changed identity")
    func readerScopeAndLifecycle() async throws {
        let f = try await fixture()
        let first = MailMessage(accountId: f.local.id, folderId: f.localInbox.id, uid: MailService.localUIDFloor, messageId: "<first@test>", bodyState: .ready)
        let second = MailMessage(accountId: f.local.id, folderId: f.localInbox.id, uid: MailService.localUIDFloor + 1, messageId: "<second@test>", bodyState: .ready)
        try await f.mail.upsertMessages([first, second])
        try await f.mail.saveBody(.init(messageId: first.id, textBody: "First card body"))
        try await f.mail.saveBody(.init(messageId: second.id, textBody: "Second card body"))
        let reader = MailConversationReader(hub: f.hub, space: .work, message: first)
        let other = MailConversationReader(hub: f.hub, space: .work, message: second)
        reader.makeSyncService = { Issue.record("Cached card must not connect"); return nil }
        let previous = UserDefaults.standard.object(forKey: SpaceStore.StorageKeys.currentSpace)
        defer { UserDefaults.standard.set(previous, forKey: SpaceStore.StorageKeys.currentSpace) }
        f.hub.spaceStore.switchTo(.personal)
        await reader.load()
        #expect(reader.body?.textBody == "First card body" && other.body == nil && reader.inlineImages?.messageID == first.id)
        reader.cancel()
        #expect(reader.body == nil && reader.inlineImages == nil && reader.attachments.isEmpty && !reader.isLoading)
        await reader.load()
        #expect(reader.body?.textBody == "First card body")
        var changed = first; changed.folderId = f.localArchive.id
        reader.update(changed)
        #expect(reader.body == nil)
        await reader.load()
        #expect(reader.body == nil && reader.error != nil)
        reader.update(first)
        try await f.mail.saveBody(.init(messageId: first.id))
        await reader.load()
        #expect(reader.body?.messageId == first.id && reader.error == nil)
        reader.cancel(); other.cancel()
        let foreign = MailConversationReader(hub: f.hub, space: .personal, message: first)
        await foreign.load()
        #expect(foreign.body == nil && foreign.error != nil)
        foreign.cancel()
    }

    @Test("Collapsing a card cancels its body and attachment network reads, and retry uses the same message")
    func readerNetworkCancellation() async throws {
        let f = try await fixture()
        let message = MailMessage(accountId: f.remote[0].id, folderId: f.inboxes[0].id, uid: 1, messageId: "<remote@test>")
        try await f.mail.upsertMessages([message])
        let reader = MailConversationReader(hub: f.hub, space: .work, message: message)
        let hung = MockMailClient(hangPoint: .fetchBody)
        reader.makeSyncService = { service(f, clients: [f.remote[0].id: hung]) }
        let load = Task { await reader.load() }
        try await waitUntil { await hung.bodyFetchCount == 1 }
        reader.cancel(); await load.value
        #expect(reader.body == nil && reader.error == nil && !reader.isLoading)
        #expect(await hung.disconnectCount > 0)
        let ready = MockMailClient(bodies: [1: .init(textBody: "Retried body", htmlBody: nil, attachments: [
            .init(filename: "file.txt", mimeType: "text/plain", sizeBytes: 16, contentId: nil, isInline: false, partID: "1")])])
        reader.makeSyncService = { service(f, clients: [f.remote[0].id: ready]) }
        await reader.load()
        #expect(reader.body?.textBody == "Retried body" && reader.attachments.count == 1)
        #expect(await ready.bodyFetchCount == 1)
        let part = try #require(reader.attachments.first)
        let attachment = MockMailClient(hangPoint: .fetchAttachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-card-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        reader.makeSyncService = { service(f, clients: [f.remote[0].id: attachment], directory: directory) }
        let download = Task { await reader.download(part) }
        try await waitUntil { await attachment.attachmentDownloadCount == 1 }
        reader.cancel()
        #expect(await download.value == nil)
        #expect(reader.downloading.isEmpty && reader.error == nil)
        #expect(await attachment.disconnectCount > 0)
    }

    @Test("Native unified inbox and conversation cards retain sources and target the clicked card in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeInboxAndConversation() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let f = try await fixture()
        let parent = MailMessage(accountId: f.local.id, folderId: f.localInbox.id, uid: MailService.localUIDFloor, messageId: "<project@test>",
            subject: "Design approval / 设计评审", fromName: "Original sender", fromAddress: "original@example.test", date: Date(timeIntervalSince1970: 10), bodyState: .ready)
        let reply = MailMessage(accountId: f.local.id, folderId: f.localArchive.id, uid: MailService.localUIDFloor + 1, messageId: "<reply@test>",
            subject: "Delivery notes / 交付说明", fromName: "Reply sender", fromAddress: "reply@example.test", references: "<project@test>",
            date: Date(timeIntervalSince1970: 11), bodyState: .ready)
        let foreign = MailMessage(accountId: f.remote[1].id, folderId: f.inboxes[1].id, uid: 1, messageId: "<project@test>",
            subject: "Same ID in another account", fromName: "Another account", fromAddress: "other@example.test", date: Date(timeIntervalSince1970: 12), bodyState: .ready)
        try await f.mail.upsertMessages([parent, reply, foreign])
        for message in [parent, reply, foreign] {
            try await f.mail.saveBody(.init(messageId: message.id, textBody: message.subject + "\n\nSynthetic correspondence for native reader verification."))
        }
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let model = MailViewModel(hub: f.hub, space: .work)
            await model.loadIfNeeded(); await model.openUnifiedInbox(); await model.selectMessage(parent.id)
            let host = NSHostingView(rootView: MailView(hub: f.hub, viewModel: model).frame(width: 1180, height: 760).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            func layout() async throws {
                for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            }
            func snapshot(_ name: String) throws {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("mail-\(name)-\(language.rawValue).png"))
            }
            try await layout()
            #expect(model.messages.count == 2 && model.sourceLabels[parent.id]?.contains(f.local.displayName) == true)
            try snapshot("unified-inbox")
            try #require(try await press(L.string("mail.conversation.open"), in: host))
            try await waitUntil { model.isConversationVisible && model.conversationMessages.count == 2 && !model.isLoadingConversation }
            try await layout()
            try #require(try await press(L.format("mail.conversation.card", parent.displayFrom, parent.subject), visible: parent.displayFrom, in: host))
            try await layout()
            try #require(try await press(L.format("mail.conversation.card", reply.displayFrom, reply.subject), visible: reply.displayFrom, in: host))
            try await layout()
            #expect(model.readerActionMessage?.id == reply.id && model.readerActionIDs == [reply.id] && model.currentMessage?.id == parent.id)
            #expect(!model.conversationMessages.contains { $0.id == foreign.id })
            try snapshot("conversation")
            try #require(try await press(L.string("mail.conversation.single"), in: host))
            try await waitUntil { !model.isConversationVisible && model.body?.messageId == parent.id }
            #expect(model.readerActionIDs == [parent.id])
            model.cancelPendingWork(); window.close()
        }
    }

    private func press(_ title: String, visible: String? = nil, in view: NSView) async throws -> Bool {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject, depth: Int = 0) -> Bool {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return false }
            if let button = object as? NSButton, button.title == title { button.performClick(nil); return true }
            if let button = object as? any NSAccessibilityButton, button.accessibilityLabel() == title,
               button.accessibilityFrame().width > 0, button.accessibilityPerformPress() { return true }
            if let node = object as? any NSAccessibilityProtocol {
                if node.accessibilityRole() == .button, node.isAccessibilityEnabled(),
                   node.accessibilityLabel() == title || node.accessibilityTitle() == title,
                   node.accessibilityFrame().width > 0, node.accessibilityPerformPress() { return true }
                for child in node.accessibilityChildren() ?? [] { if visit(child as AnyObject, depth: depth + 1) { return true } }
            }
            if let native = object as? NSView {
                for child in native.subviews where !child.isHidden { if visit(child, depth: depth + 1) { return true } }
            }
            return false
        }
        if visit(view) { return true }
        // SwiftUI can omit native button nodes in a SwiftPM host. Locate only
        // rendered text in this fixture's own reader column and click its window.
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let language = LanguageManager.shared.activeLanguageCode, label = visible ?? title
        let point = try await Task.detached { () throws -> CGPoint? in
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]
            request.customWords = [label]
            try VNImageRequestHandler(data: data).perform([request])
            return (request.results ?? []).compactMap { observation -> CGPoint? in
                guard let candidate = observation.topCandidates(1).first,
                      let range = candidate.string.range(of: label, options: .caseInsensitive),
                      let box = try? candidate.boundingBox(for: range), box.boundingBox.minX > 0.45 else { return nil }
                return CGPoint(x: box.boundingBox.midX, y: box.boundingBox.midY)
            }.max { $0.y < $1.y }
        }.value
        guard let point, let window = view.window else { return false }
        let location = view.convert(NSPoint(x: point.x * view.bounds.width,
            y: (view.isFlipped ? 1 - point.y : point.y) * view.bounds.height), to: nil)
        try window.sendTestClick(at: location, matching: label)
        return true
    }
}
