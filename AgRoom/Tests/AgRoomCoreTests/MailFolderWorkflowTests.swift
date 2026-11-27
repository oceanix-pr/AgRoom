import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
import Vision
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
@Suite("Mail sidebar visibility and reviewed moves")
struct MailFolderWorkflowTests {
    private struct Fixture {
        let queue: DatabaseQueue
        let mail: MailService
        let hub: Hub
        let archive: MailAccount
        let parent: MailFolder
        let first: MailFolder
        let second: MailFolder
        let outside: MailFolder
        let other: MailFolder
        let messages: [MailMessage]
    }
    private func fixture() async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue)
        let archive = try await mail.createLocalArchive(name: "Project mail", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let otherAccount = try await mail.createLocalArchive(name: "Other account", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let parent = MailFolder(accountId: archive.id, path: "Projects", name: "Projects", delimiter: "/", isContainer: true)
        let first = MailFolder(accountId: archive.id, path: "Projects/2024/Reports", name: "Reports", parentPath: "Projects/2024", delimiter: "/")
        let second = MailFolder(accountId: archive.id, path: "Projects/2025/Reports", name: "Reports", parentPath: "Projects/2025", delimiter: "/")
        let outside = MailFolder(accountId: archive.id, path: "Projects-old/Reports", name: "Reports", delimiter: "/")
        let other = MailFolder(accountId: otherAccount.id, path: "Projects/2025/Reports", name: "Reports", delimiter: "/")
        try await mail.upsertFolders([parent, first, second, outside, other] + ["2024", "2025"].map {
            MailFolder(accountId: archive.id, path: "Projects/" + $0, name: $0, parentPath: parent.path, delimiter: "/", isContainer: true)
        })
        let messages = [MailMessage(accountId: archive.id, folderId: first.id, uid: MailService.localUIDFloor, messageId: "<first@example.test>", subject: "First report", bodyState: .ready),
                        MailMessage(accountId: archive.id, folderId: first.id, uid: MailService.localUIDFloor + 1, messageId: "<second@example.test>", subject: "Second report", bodyState: .ready),
                        MailMessage(accountId: otherAccount.id, folderId: other.id, uid: MailService.localUIDFloor, subject: "Other space-bound owner", bodyState: .ready)]
        try await mail.upsertMessages(messages)
        for message in messages { try await mail.saveBody(.init(messageId: message.id, textBody: "Retained report body")) }
        return .init(queue: queue, mail: mail, hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), archive: archive, parent: parent, first: first, second: second, outside: outside, other: other, messages: messages)
    }
    private func reader(_ f: Fixture) async -> MailViewModel {
        let model = MailViewModel(hub: f.hub, space: .work)
        await model.loadIfNeeded(); await model.selectAccount(f.archive.id); await model.selectFolder(f.first.id)
        return model
    }
    private func waitUntil(_ label: String = "condition", _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition(), "Timed out waiting for \(label)")
    }

    @Test("Hiding a parent affects only its sidebar subtree, preserves the current mail, search and destinations")
    func hiddenSubtree() async throws {
        let f = try await fixture(), model = await reader(f)
        await model.selectMessage(f.messages[0].id)
        await model.setFavorite(true, folderID: f.second.id)
        await model.setHidden(true, folderID: f.parent.id)
        #expect(model.currentFolder?.id == f.first.id && model.selectedMessageId == f.messages[0].id)
        #expect(!model.sidebarFolders.contains { $0.id == f.first.id || $0.id == f.second.id || $0.id == f.parent.id })
        #expect(model.sidebarFolders.contains { $0.id == f.outside.id } && model.favoriteFolders.isEmpty)
        #expect(model.folderVisibility.hiddenAncestor[f.second.id] == f.parent.id)
        #expect(!model.folderVisibility.hidden.contains(f.other.id))
        #expect(model.moveTargets(for: [f.messages[0].id]).contains { $0.id == f.second.id })
        #expect(try await f.mail.messageIDs(in: .account(f.archive.id)).count == 2)
        #expect(try await f.mail.body(messageId: f.messages[0].id)?.textBody == "Retained report body")
        model.showHiddenFolders = true
        #expect(model.sidebarFolders.contains { $0.id == f.second.id } && model.favoriteFolders.map(\.id) == [f.second.id])
        await model.setHidden(true, folderID: f.second.id)
        await model.setHidden(false, folderID: f.parent.id)
        model.showHiddenFolders = false
        #expect(model.sidebarFolders.contains { $0.id == f.first.id } && !model.sidebarFolders.contains { $0.id == f.second.id })
        await model.setHidden(false, folderID: f.second.id)
        #expect(!model.hasHiddenFolders && model.favoriteFolders.map(\.id) == [f.second.id])
        model.cancelPendingWork()
    }

    @Test("Visibility survives recent-history cleanup, backups, legacy restore and migration, with space isolation")
    func visibilityPersistence() async throws {
        let f = try await fixture()
        try await f.mail.setFolderHidden(true, folderID: f.parent.id)
        try await f.mail.setFolderHidden(true, folderID: f.second.id)
        try await f.mail.setFolderFavorite(true, folderID: f.second.id)
        try await f.mail.setFolderFavorite(false, folderID: f.second.id)
        try await f.mail.recordMoveDestination(f.outside.id)
        #expect(try await f.mail.folderPreferences().filter(\.isHidden).count == 2)
        let backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        let target = SpaceDatabaseBackupStore(queue: isolated, space: "work"), mail = MailService(databaseQueue: isolated)
        await #expect(throws: MailSyncError.folderNotFound) { try await mail.setFolderHidden(true, folderID: f.parent.id) }
        _ = try await target.apply(target.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        #expect(try await mail.folderPreferences() == f.mail.folderPreferences())
        var corrupt = backup
        let index = try #require(corrupt.tables.firstIndex { $0.name == "mail_folder_preferences" })
        let hidden = try #require(corrupt.tables[index].columns.firstIndex(of: "isHidden"))
        corrupt.tables[index].rows[0][hidden] = .integer(2)
        await #expect(throws: (any Error).self) { try await target.plan(corrupt, sourceSpace: "work") }
        var legacy = backup
        var oldColumns = legacy.tables[index].columns; oldColumns.remove(at: hidden)
        let oldRows = legacy.tables[index].rows.map { row in var old = row; old.remove(at: hidden); return old }
        legacy.tables[index] = .init(name: legacy.tables[index].name, columns: oldColumns, primaryKey: legacy.tables[index].primaryKey, rows: oldRows)
        _ = try await target.apply(target.plan(legacy, sourceSpace: "work"), willCommit: { _ in })
        #expect(try await !mail.folderPreferences().contains(where: \.isHidden))
        #expect(try await f.mail.folderPreferences().filter(\.isHidden).count == 2)
        try await isolated.write { db in
            try db.execute(sql: "ALTER TABLE mail_folder_preferences DROP COLUMN isHidden")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v17_mail_folder_visibility'")
        }
        try DatabaseBootstrap.prepareSpace(isolated); try DatabaseBootstrap.prepareSpace(isolated)
        #expect(try await !mail.folderPreferences().contains(where: \.isHidden))
        #expect(try await mail.message(id: f.messages[0].id)?.folderId == f.first.id)
    }

    @Test("Move reviews reject mixed owners, stale source and target identity, while allowing flag edits")
    func moveIdentity() async throws {
        let f = try await fixture()
        await #expect(throws: MailMoveReviewError.empty) { try await f.mail.reviewMove(messageIDs: []) }
        await #expect(throws: MailMoveReviewError.mixedAccounts) { try await f.mail.reviewMove(messageIDs: [f.messages[0].id, f.messages[2].id]) }
        let review = try await f.mail.reviewMove(messageIDs: [f.messages[0].id, f.messages[0].id])
        #expect(review.messages.count == 1 && !review.destinations.contains { $0.id == f.first.id || $0.isContainer || $0.accountId != f.archive.id })
        try await f.mail.setFlags(messageId: f.messages[0].id, isRead: true)
        try await f.mail.validateMove(review, destinationID: f.second.id)
        let clone = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(clone)
        let backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let restored = SpaceDatabaseBackupStore(queue: clone, space: "work")
        _ = try await restored.apply(restored.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        #expect(try await MailService(databaseQueue: clone).message(id: f.messages[0].id)?.folderId == f.first.id)
        await #expect(throws: MailMoveReviewError.changed) { try await MailService(databaseQueue: clone).validateMove(review, destinationID: f.second.id) }
        await #expect(throws: MailMoveReviewError.changed) { try await f.mail.validateMove(review, destinationID: f.other.id) }
        await #expect(throws: MailMoveReviewError.changed) { try await f.mail.validateMove(review, destinationID: f.parent.id) }
        try await f.queue.write { db in try db.execute(sql: "UPDATE mail_folders SET uidValidity=43 WHERE id=?", arguments: [f.second.id.uuidString]) }
        await #expect(throws: MailMoveReviewError.changed) { try await f.mail.validateMove(review, destinationID: f.second.id) }
        try await f.queue.write { db in try db.execute(sql: "UPDATE mail_folders SET uidValidity=NULL WHERE id=?", arguments: [f.second.id.uuidString]) }
        try await f.mail.moveMessage(id: f.messages[0].id, toFolderId: f.outside.id, uid: f.messages[0].uid)
        await #expect(throws: MailMoveReviewError.changed) { try await f.mail.validateMove(review, destinationID: f.second.id) }
        let service = try #require(f.hub.makeMailSyncService(for: .work))
        let result = await service.applyBatch(messageIDs: [f.messages[0].id], action: .move(f.second.id), moveReview: review)
        #expect(result.succeeded.isEmpty && result.failures.first?.error as? MailMoveReviewError == .changed)
        #expect(try await f.mail.message(id: f.messages[0].id)?.folderId == f.outside.id)
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        await #expect(throws: MailMoveReviewError.changed) { try await MailService(databaseQueue: isolated).validateMove(review, destinationID: f.second.id) }
        let encoded = MailFolder(accountId: UUID(), path: "&ZeVnLIqe-/Reports", name: "Reports")
        #expect(MailFolderPath.display(encoded, isLocalArchive: false) == "日本語/Reports")
        #expect(MailFolderPath.display(encoded, isLocalArchive: true) == encoded.path)
    }

    @Test("Reviewed batches recheck each message inside the lease and preserve earlier successes")
    func perItemReview() async throws {
        let f = try await fixture(), service = try #require(f.hub.makeMailSyncService(for: .work))
        let first = f.messages[0], second = f.messages[1]
        let review = try await f.mail.reviewMove(messageIDs: [first.id, second.id])
        let result = await service.applyBatch(messageIDs: [first.id, second.id], action: .move(f.second.id), moveReview: review) { done, _ in
            if done == 1 {
                do { _ = try await f.mail.moveMessage(id: second.id, toFolderId: f.outside.id, uid: second.uid) }
                catch { Issue.record(error) }
            }
        }
        #expect(result.succeeded == [first.id] && result.failures.first?.messageID == second.id)
        #expect(result.failures.first?.error as? MailMoveReviewError == .changed)
        #expect(try await f.mail.message(id: first.id)?.folderId == f.second.id)
        #expect(try await f.mail.message(id: second.id)?.folderId == f.outside.id)
        #expect(!MailBatchAction.move(f.second.id).allowsDirectRetry)
    }

    @Test("The chooser filters full paths, retains favorites and hidden destinations, freezes IDs and cancels submission")
    func chooserModel() async throws {
        let f = try await fixture(), reader = await reader(f)
        try await f.mail.setFolderHidden(true, folderID: f.parent.id)
        try await f.mail.setFolderFavorite(true, folderID: f.second.id)
        var submitted: Set<UUID> = []
        let model = MailMovePickerModel(hub: f.hub, space: .work, messageIDs: [f.messages[0].id]) { review, folder in
            submitted = Set(review.messages.map(\.id)); reader.performBatch(ids: submitted, action: .move(folder), moveReview: review); return true
        }
        await model.load()
        #expect(model.preferred.first?.id == f.second.id && model.isHidden(f.second))
        model.query = "2025 Reports"
        #expect(model.filtered.map(\.id) == [f.second.id])
        model.selectedID = f.second.id
        model.query = "no-such-folder"
        #expect(model.filtered.isEmpty && model.selectedID == nil)
        model.query = "2025"; model.selectedID = f.second.id
        await reader.selectMessage(f.messages[1].id)
        #expect(await model.submit())
        try await waitUntil { !reader.isPerformingBatch }
        #expect(submitted == [f.messages[0].id] && reader.batchResult?.succeeded == [f.messages[0].id])
        #expect(try await f.mail.message(id: f.messages[1].id)?.folderId == f.first.id)
        #expect(reader.folderPreferences.first { $0.folderID == f.second.id }?.lastMovedAt != nil)
        model.cancel(); #expect(await !model.submit())
        let cancelled = MailMovePickerModel(hub: f.hub, space: .work, messageIDs: [f.messages[1].id]) { _, _ in Issue.record("Cancelled chooser submitted"); return true }
        let loading = Task { await cancelled.load() }; loading.cancel(); await loading.value
        #expect(cancelled.review == nil && !cancelled.busy)
        await cancelled.load(); cancelled.selectedID = f.second.id; cancelled.cancel()
        #expect(await !cancelled.submit())
        reader.cancelPendingWork()
    }

    @Test("Queued moves validate after acquiring the account lease, and connection edits invalidate an open review")
    func queuedMoveAndConnectionChange() async throws {
        let f = try await fixture(), coordinator = MailAccountCoordinator()
        let accountService = try #require(f.hub.makeMailAccountService(for: .work))
        let service = MailSyncService(accountService: accountService, mail: f.mail, space: .work, coordinator: coordinator)
        let review = try await f.mail.reviewMove(messageIDs: [f.messages[0].id])
        let (started, announce) = AsyncStream<Void>.makeStream(), (released, release) = AsyncStream<Void>.makeStream()
        let blocker = Task {
            try await coordinator.withLease(space: .work, accountId: f.archive.id) {
                announce.yield(())
                for await _ in released { break }
            }
        }
        for await _ in started { break }
        let moving = Task { try await service.moveMessage(messageId: f.messages[0].id, toFolderId: f.second.id, review: review) }
        try await waitUntil { await coordinator.waitingCount == 1 }
        _ = try await f.mail.moveMessage(id: f.messages[0].id, toFolderId: f.outside.id, uid: f.messages[0].uid)
        release.yield(()); release.finish(); announce.finish()
        try await blocker.value
        await #expect(throws: MailMoveReviewError.changed) { try await moving.value }
        #expect(try await f.mail.message(id: f.messages[0].id)?.folderId == f.outside.id)

        let remote = MailAccount(displayName: "Remote review", emailAddress: "review@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "review")
        try await accountService.save(remote, password: nil)
        let inbox = MailFolder(accountId: remote.id, path: "INBOX", name: "Inbox", role: .inbox, uidValidity: 11)
        let destination = MailFolder(accountId: remote.id, path: "Reports", name: "Reports", uidValidity: 22)
        try await f.mail.upsertFolders([inbox, destination])
        let message = MailMessage(accountId: remote.id, folderId: inbox.id, uid: 1)
        try await f.mail.upsertMessages([message])
        let remoteReview = try await f.mail.reviewMove(messageIDs: [message.id])
        try await f.queue.write { db in try db.execute(sql: "UPDATE mail_accounts SET imapHost='other.example.test' WHERE id=?", arguments: [remote.id.uuidString]) }
        await #expect(throws: MailMoveReviewError.changed) { try await f.mail.validateMove(remoteReview, destinationID: destination.id) }
        try await f.queue.write { db in
            try db.execute(sql: "UPDATE mail_accounts SET imapHost=? WHERE id=?", arguments: [remote.imapHost, remote.id.uuidString])
            try db.execute(sql: "UPDATE mail_folders SET path='Renamed' WHERE id=?", arguments: [inbox.id.uuidString])
        }
        await #expect(throws: MailMoveReviewError.changed) { try await f.mail.validateMove(remoteReview, destinationID: destination.id) }
    }

    @Test("Unavailable actions explain missing roles, mixed owners, disabled accounts and active work")
    func disabledReasons() async throws {
        let f = try await fixture(), model = await reader(f)
        await model.updateListFilter(.init(), scope: .space)
        #expect(model.moveBlockReason([f.messages[0].id, f.messages[2].id]) == L.string("mail.move.error.mixedAccounts"))
        #expect(model.roleBlockReason(.junk, ids: [f.messages[0].id]) == L.format("mail.action.unavailable.role", L.string("mail.folder.junk")))
        #expect(model.moveBlockReason([UUID()]) == L.string("mail.move.error.unavailable"))
        #expect(model.moveBlockReason([]) == L.string("mail.move.error.empty"))
        model.performBatch(ids: [f.messages[0].id], action: .read(true))
        #expect(model.moveBlockReason([f.messages[0].id]) == L.string("mail.action.unavailable.busy"))
        try await waitUntil { !model.isPerformingBatch }
        let remote = MailAccount(displayName: "Disabled", emailAddress: "test@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "test", isEnabled: false)
        try await f.hub.makeMailAccountService(for: .work)?.save(remote, password: nil)
        let inbox = MailFolder(accountId: remote.id, path: "INBOX", name: "Inbox", role: .inbox)
        let dest = MailFolder(accountId: remote.id, path: "Reports", name: "Reports")
        try await f.mail.upsertFolders([inbox, dest])
        let message = MailMessage(accountId: remote.id, folderId: inbox.id, uid: 1)
        try await f.mail.upsertMessages([message]); await model.reloadAccounts()
        await model.updateListFilter(.init(query: "test"), scope: .space); await model.updateListFilter(.init(), scope: .space)
        #expect(model.moveBlockReason([message.id]) == L.string("mail.error.accountDisabled"))
        await #expect(throws: MailSyncError.accountDisabled) { try await f.mail.reviewMove(messageIDs: [message.id]) }
        model.cancelPendingWork()
    }

    @Test("Native chooser search, selection and move work in three languages; hidden mail remains readable",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeWorkflow() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let f = try await fixture(), reader = await reader(f)
            await reader.setFavorite(true, folderID: f.second.id); await reader.setHidden(true, folderID: f.parent.id)
            await reader.selectMessage(f.messages[0].id)
            let model = MailMovePickerModel(hub: f.hub, space: .work, messageIDs: [f.messages[0].id]) { review, folder in
                reader.performBatch(ids: Set(review.messages.map(\.id)), action: .move(folder), moveReview: review); return true
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: MailMovePicker(model: model)); window.makeKeyAndOrderFront(nil)
            defer { model.cancel(); reader.cancelPendingWork(); window.close() }
            try await waitUntil("chooser preparation") { model.review != nil }; try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-move-picker-\(language.rawValue).png"))
            try await press(f.second.path, in: window)
            try await waitUntil("unfiltered target selection") { model.selectedID == f.second.id }
            try await press(L.string("mail.move.search"), in: window)
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.insertText("2025", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-move-input-\(language.rawValue).png"))
            try await waitUntil("query entry") { model.query == "2025" }; try await layout(window)
            try await press(f.second.path, in: window)
            try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-move-selection-\(language.rawValue).png"))
            try await waitUntil("target selection") { model.selectedID == f.second.id }; try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-move-search-\(language.rawValue).png"))
            try await press(L.string("mail.action.move"), in: window, maxY: 0.15)
            try await waitUntil("move receipt") { reader.batchResult != nil && !reader.isPerformingBatch }
            #expect(reader.batchResult?.succeeded == [f.messages[0].id])
            #expect(try await f.mail.message(id: f.messages[0].id)?.folderId == f.second.id)
            model.cancel(); window.close()
            await reader.selectFolder(f.second.id); await reader.selectMessage(f.messages[0].id)
            let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            main.isReleasedWhenClosed = false
            main.contentView = NSHostingView(rootView: MailView(hub: f.hub, viewModel: reader).frame(width: 1100, height: 680).background(Color(nsColor: .windowBackgroundColor)))
            defer { main.close() }
            try await layout(main)
            try snapshot(main, at: directory.appendingPathComponent("mail-hidden-sidebar-\(language.rawValue).png"))
            #expect(reader.currentFolder?.id == f.second.id && reader.currentMessage?.id == f.messages[0].id)
            #expect(reader.sidebarFolders.allSatisfy { $0.id != f.second.id })
            // Exercise the production detail entry and modal dismissal, in addition
            // to the chooser's own native interaction above.
            main.contentView = NSHostingView(rootView: MailView(hub: f.hub, viewModel: reader).frame(width: 1500, height: 680).background(Color(nsColor: .windowBackgroundColor)))
            main.setContentSize(NSSize(width: 1500, height: 680)); main.makeKeyAndOrderFront(nil)
            try await layout(main)
            try snapshot(main, at: directory.appendingPathComponent("mail-move-entry-\(language.rawValue).png"))
            if !pressAccessible(L.string("mail.move.title"), in: try #require(main.contentView)) { try await press(L.string("mail.action.move"), in: main) }
            try await waitUntil("production move sheet") { main.attachedSheet != nil }
            let sheet = try #require(main.attachedSheet); try await layout(sheet)
            sheet.makeKeyAndOrderFront(nil)
            try await press(L.string("mail.move.search"), in: sheet)
            let searchEditor = try #require(sheet.firstResponder as? NSTextView)
            searchEditor.insertText("2024", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await layout(sheet)
            try await press(f.first.path, in: sheet); try await layout(sheet)
            try snapshot(sheet, at: directory.appendingPathComponent("mail-move-production-selection-\(language.rawValue).png"))
            try await press(L.string("mail.action.move"), in: sheet, maxY: 0.15)
            try await layout(main)
            try snapshot(main.attachedSheet ?? main, at: directory.appendingPathComponent("mail-move-production-after-\(language.rawValue).png"))
            try await waitUntil("production move and dismissal") {
                let message = try? await f.mail.message(id: f.messages[0].id)
                return message?.folderId == f.first.id && main.attachedSheet == nil && !reader.isPerformingBatch
            }
            reader.cancelPendingWork(); main.close()
        }
    }

    private func layout(_ window: NSWindow) async throws {
        for _ in 0..<12 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    private func snapshot(_ window: NSWindow, at url: URL) throws {
        let view = try #require(window.contentView), bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    private func press(_ title: String, in window: NSWindow, maxY: CGFloat = 1) async throws {
        let view = try #require(window.contentView), bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let language = LanguageManager.shared.activeLanguageCode
        let point = try await Task.detached { () throws -> CGPoint in
            try autoreleasepool {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]; request.customWords = [title]
                try VNImageRequestHandler(data: data).perform([request])
                for observation in request.results ?? [] where observation.boundingBox.midY <= maxY {
                    guard let text = observation.topCandidates(1).first else { continue }
                    let indices = text.string.indices.filter { !text.string[$0].isWhitespace }
                    let compact = String(indices.map { text.string[$0] })
                    let label = title.hasSuffix("…") ? String(title.dropLast()) : title
                    let target = String(label.filter { !$0.isWhitespace })
                    guard let match = compact.range(of: target, options: [.caseInsensitive, .widthInsensitive]), !match.isEmpty else { continue }
                    let start = compact.distance(from: compact.startIndex, to: match.lowerBound), end = compact.distance(from: compact.startIndex, to: match.upperBound)
                    let range = indices[start]..<text.string.index(after: indices[end - 1])
                    if let box = try? text.boundingBox(for: range) { return .init(x: box.boundingBox.midX, y: box.boundingBox.midY) }
                }
                throw NativeControlError(title: title, visible: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
            }
        }.value
        let location = view.convert(NSPoint(x: point.x * view.bounds.width, y: (view.isFlipped ? 1 - point.y : point.y) * view.bounds.height), to: nil)
        try window.sendTestClick(at: location, matching: title)
    }
    private struct NativeControlError: Error, CustomStringConvertible {
        let title: String
        let visible: [String]
        var description: String { "Visible control not found: \(title). Rendered text: \(visible.joined(separator: " | "))" }
    }
    private func pressAccessible(_ title: String, in view: NSView) -> Bool {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject, depth: Int = 0) -> Bool {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return false }
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
        return visit(view)
    }
}
