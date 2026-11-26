import AppKit
import Foundation
import GRDB
import Observation
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Mail search ranges and saved filters")
struct MailSearchTests {
    @MainActor @Observable final class SearchControls { var text = "Shared" }
    private struct SearchHost: View {
        let hub: Hub
        let model: MailViewModel
        let controls: SearchControls
        var body: some View {
            MailView(hub: hub, viewModel: model)
                .environment(\.globalSearchText, controls.text)
                .environment(\.setGlobalSearch) { controls.text = $0 }
        }
    }
    private struct Fixture {
        let queue: DatabaseQueue
        let mail: MailService
        let accounts: MailAccountService
        let first: MailAccount
        let second: MailAccount
        let inbox: MailFolder
        let other: MailFolder
        let secondTrash: MailFolder
    }
    private func fixture() async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue), accounts = MailAccountService(databaseQueue: queue, space: .work)
        let first = MailAccount(displayName: "First", emailAddress: "first@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "first@example.test")
        let second = MailAccount(displayName: "Second", emailAddress: "second@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "second@example.test")
        try await accounts.save(first, password: nil); try await accounts.save(second, password: nil)
        let inbox = MailFolder(accountId: first.id, path: "INBOX", name: "Inbox", role: .inbox)
        let other = MailFolder(accountId: first.id, path: "Other", name: "Other")
        let secondTrash = MailFolder(accountId: second.id, path: "Trash", name: "Trash", role: .trash)
        try await mail.upsertFolders([inbox, other, secondTrash,
            .init(accountId: first.id, path: "Trash", name: "Trash", role: .trash),
            .init(accountId: second.id, path: "Archive", name: "Archive", role: .archive)])
        return .init(queue: queue, mail: mail, accounts: accounts, first: first, second: second, inbox: inbox, other: other, secondTrash: secondTrash)
    }

    @Test("Search covers readable cached bodies, recipients, attachment names and byte ranges using literal query text")
    func contentAndFields() async throws {
        #expect(MailAIContextService.htmlToText("<p>&copy; &#128; &amp;lt; &#0; tail</p>") == "© € &lt; � tail")
        #expect(MailAIContextService.htmlToText("<p>&frac12; &sup2; &#x1F600;</p>") == "½ ² 😀")
        let f = try await fixture()
        let first = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: 1, subject: "Subject", fromAddress: "from@example.test",
            to: [.init(name: "A quoted recipient", address: "quoted\\name@example.test")], hasAttachments: true, sizeBytes: 4096)
        let other = MailMessage(accountId: f.first.id, folderId: f.other.id, uid: 1, subject: "Other", sizeBytes: 0)
        let foreign = MailMessage(accountId: f.second.id, folderId: f.secondTrash.id, uid: 1, subject: "Foreign", cc: [.init(name: "CC", address: "foreign@example.test")], sizeBytes: 8192)
        try await f.mail.upsertMessages([first, other, foreign])
        try await f.mail.saveBody(.init(messageId: first.id, htmlBody: "<style>.hiddenneedle { color: red }</style><p>&#x9879;&#30446; &amp; 50%_\\</p>"))
        try await f.mail.saveBody(.init(messageId: other.id, textBody: "项目 & 50%_\\"))
        try await f.mail.saveBody(.init(messageId: foreign.id, textBody: "项目 & 50%_\\"))
        try await f.mail.saveAttachments([.init(messageId: first.id, filename: "进度_50%.pdf", mimeType: "application/pdf")])
        let filter = MailListFilter(query: "项目 & 50%_\\", recipient: "quoted\\name", attachmentName: "进度_50%", minBytes: 4096, maxBytes: 4096)
        #expect(try await f.mail.messages(in: .space, before: nil, matching: filter).map(\.id) == [first.id])
        #expect(try await f.mail.messages(in: .space, before: nil, matching: .init(query: "hiddenneedle")).isEmpty)
        #expect(try await f.mail.messages(in: .space, before: nil, matching: .init(query: "项目", includeBody: false)).isEmpty)
        #expect(try await f.mail.messages(in: .account(f.first.id), before: nil, matching: .init(query: "项目")).count == 2)
        #expect(try await f.mail.messages(in: .folder(f.other.id), before: nil, matching: .init(query: "项目")).map(\.id) == [other.id])
        #expect(try await f.mail.messages(in: .folder(f.inbox.id), before: nil, matching: .init(recipient: "foreign@example.test")).isEmpty)
        #expect(try await f.mail.messages(in: .space, before: nil, matching: .init(query: "50XYZ")).isEmpty)
        #expect(try await f.mail.messages(in: .space, before: nil, matching: .init(maxBytes: 8192)).count == 2)
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        #expect(try await MailService(databaseQueue: isolated).messages(in: .space, before: nil, matching: .init(query: "项目")).isEmpty)
    }

    @Test("Cross-folder cursors retain every equal-date equal-UID message, including undated messages")
    func cursorTies() async throws {
        let f = try await fixture()
        let folders = [f.inbox, f.other, f.secondTrash]
        var all: [MailMessage] = []
        for folder in folders {
            for uid in 1...4 {
                all.append(.init(accountId: folder.accountId, folderId: folder.id, uid: UInt32(uid), subject: "Tie", date: uid <= 2 ? nil : Date(timeIntervalSince1970: 10)))
            }
        }
        try await f.mail.upsertMessages(all)
        var cursor: MailService.MailPageCursor?, ids: [UUID] = []
        repeat {
            let page = try await f.mail.messages(in: .space, before: cursor, limit: 2)
            if page.isEmpty { break }
            ids += page.map(\.id)
            let last = try #require(page.last)
            cursor = .init(date: last.date, uid: last.uid, id: last.id)
        } while ids.count <= all.count
        #expect(ids.count == all.count && Set(ids) == Set(all.map(\.id)))
        await #expect(throws: MailSearchError.self) { try await f.mail.messages(in: .space, before: .init(date: nil, uid: 2), limit: 2) }
    }

    @Test("Readable HTML search text shares the byte budget and disappears with evicted cached bodies")
    func searchCacheBudget() async throws {
        let f = try await fixture()
        let message = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: 1)
        let html = "<p>" + String(repeating: "项", count: 16) + "</p>"
        try await f.mail.upsertMessages([message]); try await f.mail.saveBody(.init(messageId: message.id, htmlBody: html))
        #expect(try await f.mail.messages(in: .space, before: nil, matching: .init(query: "项")).count == 1)
        try await f.queue.write { db in try MailService.trimBodyCache(in: db, maxBytes: html.utf8.count) }
        #expect(try await f.mail.body(messageId: message.id) == nil)
        #expect(try await f.mail.messages(in: .space, before: nil, matching: .init(query: "项")).isEmpty)
        #expect(MailService.searchableBody(text: "Pure text", html: nil).isEmpty)
    }

    @Test("Saved filters are space-bound, survive backup, and rebuild body search for old backup columns")
    func savedAndBackup() async throws {
        let f = try await fixture()
        let message = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: 1, subject: "Metadata")
        try await f.mail.upsertMessages([message]); try await f.mail.saveBody(.init(messageId: message.id, htmlBody: "<p>Cached &amp; restored</p>"))
        let filter = MailListFilter(query: "Cached & restored", recipient: "", minBytes: 1024)
        let saved = MailSavedSearch(name: "Review", filter: filter, location: .folder(f.inbox.id))
        try await f.mail.saveSearch(saved)
        #expect(try await f.mail.savedSearches() == [saved])
        await #expect(throws: MailSearchError.duplicateName) { try await f.mail.saveSearch(.init(name: "review", filter: filter, location: .space)) }
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        #expect(try await MailService(databaseQueue: isolated).savedSearches().isEmpty)
        var backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let index = try #require(backup.tables.firstIndex { $0.name == "mail_bodies" })
        let table = backup.tables[index], column = try #require(table.columns.firstIndex(of: "searchText"))
        backup.tables[index] = .init(name: table.name, columns: table.columns.enumerated().filter { $0.offset != column }.map(\.element), primaryKey: table.primaryKey,
            rows: table.rows.map { row in row.enumerated().filter { $0.offset != column }.map(\.element) })
        let store = SpaceDatabaseBackupStore(queue: isolated, space: "work")
        _ = try await store.apply(store.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        let restored = MailService(databaseQueue: isolated)
        #expect(try await restored.savedSearches() == [saved])
        #expect(try await restored.messages(in: .space, before: nil, matching: .init(query: "Cached & restored")).map(\.id) == [message.id])
        try await f.accounts.delete(id: f.first.id)
        await #expect(throws: MailSearchError.unavailable) { try await f.mail.searchContext(for: saved.location) }
        try await f.mail.deleteSearch(id: saved.id)
        #expect(try await f.mail.savedSearches().isEmpty)
    }

    @Test("Search migration rebuilds existing HTML bodies without changing their content")
    func migration() async throws {
        let f = try await fixture()
        let message = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: 1)
        let html = "<p>Only cached body &amp; &#x9879;&#30446;</p>"
        try await f.mail.upsertMessages([message]); try await f.mail.saveBody(.init(messageId: message.id, htmlBody: html))
        try await f.queue.write { db in
            try db.execute(sql: "ALTER TABLE mail_bodies DROP COLUMN searchText")
            try db.execute(sql: "DROP TABLE mail_saved_searches")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v13_mail_search'")
        }
        try DatabaseBootstrap.prepareSpace(f.queue); try DatabaseBootstrap.prepareSpace(f.queue)
        #expect(try await f.mail.body(messageId: message.id)?.htmlBody == html)
        #expect(try await f.mail.messages(in: .space, before: nil, matching: .init(query: "body & 项目")).map(\.id) == [message.id])
    }

    @MainActor
    @Test("Saved-filter edits retain identity and criteria unless explicitly replaced, and stale edits cannot overwrite or resurrect a filter")
    func editSavedFilters() async throws {
        let f = try await fixture()
        let model = MailViewModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue)), space: .work)
        await model.loadIfNeeded(); await model.selectAccount(f.first.id)
        #expect(await model.saveSearch(name: "Original", filter: .init(query: "Old", starredOnly: true), scope: .folder))
        let original = try #require(model.savedSearches.first)
        #expect(await !model.saveSearch(name: "Original", filter: .init(query: "Duplicate"), scope: .space))
        #expect(model.searchSaveError == L.string("mail.search.error.duplicateName") && model.errorText == nil)
        #expect(await model.saveSearch(name: "Renamed", filter: .init(query: "Ignored"), scope: .space, replacing: original, updateConditions: false))
        let renamed = try #require(model.savedSearches.first)
        #expect(renamed.id == original.id && renamed.name == "Renamed" && renamed.filter == original.filter && renamed.location == original.location)
        await #expect(throws: MailSearchError.changed) { try await f.mail.saveSearch(original, replacing: original) }
        #expect(await model.saveSearch(name: "Updated", filter: .init(query: "New", recipient: "peer@example.test"), scope: .space, replacing: renamed))
        let updated = try #require(model.savedSearches.first)
        #expect(updated.id == original.id && updated.filter.query == "New" && updated.filter.recipient == "peer@example.test" && updated.location == .space)
        try await f.mail.deleteSearch(id: updated.id)
        await #expect(throws: MailSearchError.changed) { try await f.mail.saveSearch(updated, replacing: updated) }
        #expect(try await f.mail.savedSearches().isEmpty)
        try await f.mail.saveSearch(original)
        try await f.accounts.delete(id: f.first.id)
        var deadSource = original; deadSource.name = "Kept name"
        try await f.mail.saveSearch(deadSource, replacing: original)
        await #expect(throws: MailSearchError.unavailable) { try await f.mail.searchContext(for: deadSource.location) }
    }

    @MainActor
    @Test("Broad result actions use the message owner, not the account currently shown in the sidebar")
    func modelAndActionOwners() async throws {
        let f = try await fixture()
        let first = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: 1, subject: "Shared", isRead: true, isStarred: true)
        let second = MailMessage(accountId: f.second.id, folderId: f.secondTrash.id, uid: 1, subject: "Shared")
        try await f.mail.upsertMessages([first, second])
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let model = MailViewModel(hub: hub, space: .work)
        await model.loadIfNeeded(); await model.selectAccount(f.first.id)
        await model.updateListFilter(.init(query: "Shared"), scope: .space)
        #expect(Set(model.messages.map(\.id)) == [first.id, second.id])
        #expect(model.readTargets(true, in: [first.id, second.id]) == [second.id])
        #expect(model.readTargets(false, in: [first.id, second.id]) == [first.id])
        await model.selectMessage(second.id)
        #expect(model.currentAccount?.id == f.first.id && model.currentMessage?.accountId == f.second.id)
        #expect(model.allInTrash([second.id]) && !model.allInTrash([first.id, second.id]))
        #expect(model.hasTarget(.archive, ids: [second.id]) && !model.hasTarget(.archive, ids: [first.id]))
        #expect(model.moveTargets(for: [first.id, second.id]).isEmpty)
        #expect(model.moveTargets(for: [second.id]).allSatisfy { $0.accountId == f.second.id })
        #expect(model.sourceLabels[second.id]?.contains("Second") == true)
        #expect(model.readTargets(true, in: [first.id, second.id]).isEmpty)
        #expect(model.readTargets(false, in: [first.id, second.id]) == [first.id, second.id])
        #expect(model.starTargets(true, in: [first.id, second.id]) == [second.id])
        #expect(model.starTargets(false, in: [first.id, second.id]) == [first.id])
        let reply = model.replyDraft(for: second)
        #expect(reply.accountId == f.second.id && model.senderDescription(accountID: reply.accountId).contains("second@example.test"))
        #expect(await model.saveSearch(name: "All", filter: .init(query: "Shared"), scope: .space))
        let saved = try #require(model.savedSearches.first)
        await model.updateListFilter(.init(query: "Absent"), scope: .folder)
        #expect(await model.applySearch(saved))
        #expect(model.searchScope == .space && model.messages.count == 2)
        await model.openSearchSource(second.id, isCurrent: { true })
        #expect(model.searchScope == .folder && model.listFilter == .init())
        #expect(model.currentAccount?.id == f.second.id && model.selectedFolderId == f.secondTrash.id && model.currentMessage?.id == second.id)
        #expect(model.sourceLabels.isEmpty)
    }

    @MainActor
    @Test("The broad mailbox model pages through duplicate UIDs and keeps loaded pages after refresh")
    func modelPagination() async throws {
        let f = try await fixture()
        var messages: [MailMessage] = []
        for folder in [f.inbox, f.other, f.secondTrash] {
            for uid in 1...120 {
                messages.append(.init(accountId: folder.accountId, folderId: folder.id, uid: UInt32(uid), subject: "Shared", date: Date(timeIntervalSince1970: 10)))
            }
        }
        try await f.mail.upsertMessages(messages)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let model = MailViewModel(hub: hub, space: .work)
        await model.loadIfNeeded(); await model.updateListFilter(.init(query: "Shared"), scope: .space)
        #expect(model.messages.count == 200 && model.hasMoreMessages)
        #expect(try #require(await model.exportSearchIDs()).count == 360)
        await model.loadMoreMessages()
        #expect(model.messages.count == 360 && Set(model.messages.map(\.id)) == Set(messages.map(\.id)))
        await model.reloadMessages()
        #expect(model.messages.count == 360 && !model.hasMoreMessages)
    }

    @MainActor
    @Test("Native cross-account results show their source and bind menus to the clicked message",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeSearchWorkflow() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let f = try await fixture()
        let first = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: 1, subject: "Shared · 项目评审", fromAddress: "peer@example.test", date: Date(timeIntervalSince1970: 10), isRead: true, isStarred: true, bodyState: .ready)
        let second = MailMessage(accountId: f.second.id, folderId: f.secondTrash.id, uid: 1, subject: "Shared · 附件交付", fromAddress: "other@example.test", date: Date(timeIntervalSince1970: 11), bodyState: .ready)
        try await f.mail.upsertMessages([first, second])
        for message in [first, second] { try await f.mail.saveBody(.init(messageId: message.id, textBody: "Synthetic body for cross-account search.")) }
        let archive = try #require(try await f.mail.folders(accountId: f.second.id).first { $0.role == .archive })
        try await f.mail.setFolderFavorite(true, folderID: f.other.id)
        try await f.mail.setFolderFavorite(true, folderID: archive.id)
        try await f.mail.recordMoveDestination(archive.id)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            // The previous run opened this message in its source folder.
            try await f.mail.setFlags(messageId: second.id, isRead: false)
            let model = MailViewModel(hub: hub, space: .work)
            await model.loadIfNeeded(); await model.selectAccount(f.first.id)
            await model.updateListFilter(.init(query: "Shared"), scope: .space)
            let controls = SearchControls()
            let host = NSHostingView(rootView: SearchHost(hub: hub, model: model, controls: controls).frame(width: 1100, height: 680).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            func tables(_ view: NSView) -> [NSTableView] {
                (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
            }
            let table = try #require(tables(host).first { $0.numberOfRows == 2 })
            let sidebar = try #require(tables(host).first { $0 !== table && $0.numberOfRows > 3 })
            sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            for _ in 0..<50 where model.selectedFolderId != f.other.id { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.selectedFolderId == f.other.id)
            await model.selectFolder(f.inbox.id)
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let index = try #require(model.messages.firstIndex { $0.id == second.id })
            let point = table.convert(NSPoint(x: 30, y: table.rect(ofRow: index).midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let menu = try #require(table.menu(for: event)); menu.update()
            #expect(menu.items.contains { $0.title == L.string("mail.action.permanentDelete") })
            #expect(!menu.items.contains { $0.title == L.string("mail.action.trash") })
            #expect(menu.items.first { $0.title == L.string("mail.action.archive") }?.isEnabled == true)
            #expect(model.favoriteFolders.map(\.id) == [f.other.id])
            #expect(model.preferredMoveTargets(for: [second.id]).map(\.id) == [archive.id])
            #expect(menu.items.contains { $0.title == L.string("mail.action.markRead") })
            #expect(!menu.items.contains { $0.title == L.string("mail.action.markUnread") })
            #expect(menu.items.contains { $0.title == L.string("mail.action.star") })
            #expect(!menu.items.contains { $0.title == L.string("mail.action.unstar") })
            table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
            for _ in 0..<30 where model.selectedMessageIDs.count != 2 { try await Task.sleep(for: .milliseconds(20)) }
            let mixedMenu = try #require(table.menu(for: event)); mixedMenu.update()
            for key in ["mail.action.markRead", "mail.action.markUnread", "mail.action.star", "mail.action.unstar"] {
                #expect(mixedMenu.items.contains { $0.title == L.format("mail.action.affectedCount", L.string(key), 1) })
            }
            #expect(!mixedMenu.items.contains { $0.title == L.string("mail.action.reply") })
            await model.selectMessage(second.id)
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("mail-search-space-\(language.rawValue).png"))
            let saved = MailSavedSearch(name: "Shared", filter: .init(query: "Shared"), location: .space)
            await model.updateListFilter(.init(query: "Absent"), scope: .folder)
            _ = await model.applySearch(saved)
            for _ in 0..<50 where controls.text != "Shared" || model.messages.count != 2 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(controls.text == "Shared" && model.messages.count == 2 && model.searchScope == .space)
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let currentTable = try #require(tables(host).first { $0.numberOfRows == 2 })
            let currentIndex = try #require(model.messages.firstIndex { $0.id == second.id })
            let currentPoint = currentTable.convert(NSPoint(x: 30, y: currentTable.rect(ofRow: currentIndex).midY), to: nil)
            let revealEvent = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: currentPoint, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
            let revealMenu = try #require(currentTable.menu(for: revealEvent)); revealMenu.update()
            let reveal = try #require(revealMenu.items.firstIndex { $0.title == L.string("mail.action.showInFolder") })
            revealMenu.performActionForItem(at: reveal)
            for _ in 0..<100 where !controls.text.isEmpty || model.searchScope != .folder || model.selectedMessageId != second.id { try await Task.sleep(for: .milliseconds(20)) }
            #expect(controls.text.isEmpty && model.searchScope == .folder && model.currentAccount?.id == f.second.id && model.selectedMessageId == second.id)
            #expect(try await f.mail.message(id: second.id)?.isRead == true)
            model.cancelPendingWork(); window.close()
        }
    }
}
