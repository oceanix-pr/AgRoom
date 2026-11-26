import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Mail folder favorites and recent destinations")
struct MailFolderPreferenceTests {
    private struct Fixture {
        let queue: DatabaseQueue
        let mail: MailService
        let accounts: MailAccountService
        let first: MailAccount
        let second: MailAccount
        let firstFolders: [MailFolder]
        let secondFolder: MailFolder
    }

    private func fixture() async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue), accounts = MailAccountService(databaseQueue: queue, space: .work)
        let first = try await mail.createLocalArchive(name: "Projects", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let second = try await mail.createLocalArchive(name: "Other account", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let folders = (0..<12).map { MailFolder(accountId: first.id, path: "Project-\($0)", name: "Project \($0)") }
        let other = MailFolder(accountId: second.id, path: "Other", name: "Other destination")
        try await mail.upsertFolders(folders + [other])
        return .init(queue: queue, mail: mail, accounts: accounts, first: first, second: second, firstFolders: folders, secondFolder: other)
    }

    @Test("Favorites and recent history survive backups, remain space-bound, and disappear with deleted folders")
    func persistenceAndIsolation() async throws {
        let f = try await fixture(), folder = f.firstFolders[0]
        try await f.mail.setFolderFavorite(true, folderID: folder.id)
        let moved = Date(timeIntervalSince1970: 10)
        try await f.mail.recordMoveDestination(folder.id, at: moved)
        let preferences = try await f.mail.folderPreferences()
        #expect(preferences.count == 1 && preferences[0].isFavorite && preferences[0].lastMovedAt == moved)
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        let personal = MailService(databaseQueue: isolated)
        #expect(try await personal.folderPreferences().isEmpty)
        await #expect(throws: MailSyncError.folderNotFound) { try await personal.setFolderFavorite(true, folderID: folder.id) }
        let backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let target = SpaceDatabaseBackupStore(queue: isolated, space: "work")
        _ = try await target.apply(target.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        #expect(try await personal.folderPreferences() == preferences)
        try await personal.setFolderFavorite(false, folderID: folder.id)
        #expect(try await f.mail.folderPreferences() == preferences)
        try await f.accounts.delete(id: f.first.id)
        #expect(try await f.mail.folderPreferences().isEmpty)
        #expect(try await personal.folderPreferences().first?.lastMovedAt == moved)
        var invalid = backup
        let index = try #require(invalid.tables.firstIndex { $0.name == "mail_folder_preferences" })
        let favorite = try #require(invalid.tables[index].columns.firstIndex(of: "isFavorite"))
        invalid.tables[index].rows[0][favorite] = .integer(2)
        await #expect(throws: (any Error).self) { try await target.plan(invalid, sourceSpace: "work") }
    }

    @Test("Recent history is bounded per account and never discards favorites or accepts stale timestamps")
    func boundedHistory() async throws {
        let f = try await fixture()
        try await f.mail.setFolderFavorite(true, folderID: f.firstFolders[0].id)
        for (index, folder) in f.firstFolders.enumerated() { try await f.mail.recordMoveDestination(folder.id, at: Date(timeIntervalSince1970: Double(index + 10))) }
        try await f.mail.recordMoveDestination(f.secondFolder.id, at: Date(timeIntervalSince1970: 100))
        try await f.mail.recordMoveDestination(f.firstFolders[11].id, at: Date(timeIntervalSince1970: 1))
        let preferences = try await f.mail.folderPreferences()
        #expect(preferences.count == 12)
        #expect(preferences.first { $0.folderID == f.firstFolders[0].id }?.isFavorite == true)
        #expect(preferences.first { $0.folderID == f.firstFolders[0].id }?.lastMovedAt == nil)
        #expect(!preferences.contains { $0.folderID == f.firstFolders[1].id })
        #expect(preferences.first { $0.folderID == f.firstFolders[11].id }?.lastMovedAt == Date(timeIntervalSince1970: 21))
        try await f.mail.setFolderFavorite(false, folderID: f.firstFolders[0].id)
        #expect(try await !f.mail.folderPreferences().contains { $0.folderID == f.firstFolders[0].id })
        let container = MailFolder(accountId: f.first.id, path: "Container", name: "Container", isContainer: true)
        try await f.mail.upsertFolders([container])
        await #expect(throws: MailSyncError.folderNotFound) { try await f.mail.setFolderFavorite(true, folderID: container.id) }
        await #expect(throws: MailSearchError.invalidFilter) { try await f.mail.recordMoveDestination(f.firstFolders[2].id, at: Date(timeIntervalSince1970: .infinity)) }
    }

    @MainActor
    @Test("Only successful explicit moves update history and broad result menus use the message's own account")
    func modelMoves() async throws {
        let f = try await fixture()
        let inboxes = try await f.mail.folders(accountId: f.first.id)
        let inbox = try #require(inboxes.first { $0.role == .inbox })
        let first = MailMessage(accountId: f.first.id, folderId: inbox.id, uid: MailService.localUIDFloor, subject: "First")
        let second = MailMessage(accountId: f.second.id, folderId: f.secondFolder.id, uid: MailService.localUIDFloor, subject: "Second")
        try await f.mail.upsertMessages([first, second])
        try await f.mail.setFolderFavorite(true, folderID: f.firstFolders[0].id)
        try await f.mail.setFolderFavorite(true, folderID: f.secondFolder.id)
        try await f.mail.recordMoveDestination(f.firstFolders[1].id, at: Date(timeIntervalSince1970: 10))
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let model = MailViewModel(hub: hub, space: .work)
        await model.loadIfNeeded(); await model.selectAccount(f.first.id)
        #expect(model.favoriteFolders.map(\.id) == [f.firstFolders[0].id])
        #expect(model.preferredMoveTargets(for: [first.id]).map(\.id) == [f.firstFolders[1].id, f.firstFolders[0].id])
        await model.updateListFilter(.init(), scope: .space)
        #expect(model.preferredMoveTargets(for: [first.id, second.id]).isEmpty)
        #expect(model.preferredMoveTargets(for: [second.id]).isEmpty)
        await model.moveMessage(first, toFolderId: f.secondFolder.id)
        #expect(try await f.mail.message(id: first.id)?.folderId == inbox.id)
        #expect(try await f.mail.folderPreferences().first { $0.folderID == f.secondFolder.id }?.lastMovedAt == nil)
        model.clearError()
        model.performBatch(ids: [first.id], action: .move(f.firstFolders[2].id))
        for _ in 0..<100 where model.isPerformingBatch { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.batchResult?.succeeded == [first.id])
        #expect(try await f.mail.message(id: first.id)?.folderId == f.firstFolders[2].id)
        #expect(model.folderPreferences.first { $0.folderID == f.firstFolders[2].id }?.lastMovedAt != nil)
        #expect(model.preferredMoveTargets(for: [first.id]).first?.id == f.firstFolders[1].id)
        await model.moveMessage(try #require(try await f.mail.message(id: first.id)), toFolderId: f.firstFolders[3].id)
        #expect(model.folderPreferences.first { $0.folderID == f.firstFolders[3].id }?.lastMovedAt != nil)
    }

    @MainActor
    @Test("Saved-filter editor renders its explicit update choice and inline errors in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeFilterEditor() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let view = MailSavedSearchEditor(isEditing: true, name: .constant("Project follow-up"), replaceConditions: .constant(false),
                error: L.string("mail.search.error.changed"), onCancel: {}, onSave: {})
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("mail-filter-editor-\(language.rawValue).png"))
            window.close()
        }
    }
}
