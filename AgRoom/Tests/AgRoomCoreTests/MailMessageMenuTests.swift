import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
import Vision
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
@Suite("Mail contextual action groups")
struct MailMessageMenuTests {
    private struct Fixture {
        let mail: MailService
        let hub: Hub
        let first: MailAccount
        let inbox: MailFolder
        let firstRead: MailMessage
        let firstUnread: MailMessage
        let other: MailMessage
    }

    private func fixture() async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue)
        let first = try await mail.createLocalArchive(name: "Menu archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let second = try await mail.createLocalArchive(name: "Other archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let inbox = try #require(try await mail.folders(accountId: first.id).first { $0.role == .inbox })
        let trash = try #require(try await mail.folders(accountId: second.id).first { $0.role == .trash })
        let firstRead = MailMessage(accountId: first.id, folderId: inbox.id, uid: MailService.localUIDFloor, messageId: "<menu-read@example.test>",
            subject: "Menu read report", fromAddress: "read@example.test", date: Date(timeIntervalSince1970: 1), isRead: true, isStarred: true, bodyState: .ready)
        let firstUnread = MailMessage(accountId: first.id, folderId: inbox.id, uid: MailService.localUIDFloor + 1, messageId: "<menu-unread@example.test>",
            subject: "Menu unread report", fromAddress: "unread@example.test", date: Date(timeIntervalSince1970: 2), bodyState: .ready)
        let other = MailMessage(accountId: second.id, folderId: trash.id, uid: MailService.localUIDFloor, messageId: "<menu-other@example.test>",
            subject: "Menu other report", fromAddress: "other@example.test", date: Date(timeIntervalSince1970: 3), hasAttachments: true, bodyState: .ready)
        try await mail.upsertMessages([firstRead, firstUnread, other])
        for message in [firstRead, firstUnread, other] {
            let body = "Owned menu body " + message.id.uuidString
            try await mail.saveBody(.init(messageId: message.id, textBody: body))
            let headers = "From: \(message.fromAddress)\r\nMessage-ID: \(message.messageId ?? "")\r\nSubject: \(message.subject)\r\n"
            let source = message.id == other.id
                ? headers + "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=menu-parts\r\n\r\n--menu-parts\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n--menu-parts\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=menu-local.bin\r\nContent-Transfer-Encoding: base64\r\n\r\nc3ludGhldGlj\r\n--menu-parts--\r\n"
                : headers + "\r\n\(body)\r\n"
            let raw = Data(source.utf8)
            try await mail.saveRawMessage(id: message.id, raw: .init(data: raw, kind: .imported))
        }
        try await mail.saveAttachments([.init(messageId: other.id, filename: "menu-local.bin", sizeBytes: 9, partID: "2")])
        return .init(mail: mail, hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), first: first, inbox: inbox,
            firstRead: firstRead, firstUnread: firstUnread, other: other)
    }

    private func host(_ fixture: Fixture) async throws -> (MailViewModel, NSWindow) {
        let model = MailViewModel(hub: fixture.hub, space: .work)
        await model.loadIfNeeded(); await model.selectAccount(fixture.first.id)
        await model.updateListFilter(.init(), scope: .space)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MailView(hub: fixture.hub, viewModel: model).frame(width: 1100, height: 680)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.makeKeyAndOrderFront(nil); try await layout(window)
        return (model, window)
    }

    @Test("Native single-message menus keep common actions first and advanced source actions retain the clicked message",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeSingleMenu() async throws {
        _ = NSApplication.shared
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let f = try await fixture(), (model, window) = try await host(f)
            defer { model.cancelPendingWork(); window.close() }
            let selected: Set<UUID> = [f.firstRead.id, f.firstUnread.id]
            try await select(selected, model: model, window: window)
            let context = try menu(for: f.other.id, model: model, window: window)
            #expect(model.selectedMessageIDs == selected && model.body == nil)
            #expect(Array(context.items.filter { !$0.isSeparatorItem }.prefix(3).map(\.title)) ==
                ["mail.action.reply", "mail.action.replyAll", "mail.action.forward"].map(L.string))
            #expect(!context.items.contains { $0.title == L.string("mail.action.copy") || $0.title == L.string("mail.action.aiReply") || $0.title == L.string("mail.source.original") })
            #expect(context.items.contains { $0.title == L.string("mail.action.showInFolder") })
            #expect(context.items.contains { $0.title == L.string("mail.action.permanentDelete") })
            let more = try submenu(context, title: L.string("mail.action.more"))
            #expect(more.items.contains { $0.title == L.string("mail.action.aiReply") })
            #expect(!more.items.contains { $0.title == L.string("mail.action.showInFolder") })
            let copies = try submenu(more, title: L.string("mail.action.copy"))
            #expect(Set(copies.items.map(\.title)) == Set(["mail.copy.sender", "mail.copy.subject", "mail.copy.messageID", "mail.reference.copy"].map(L.string)))
            #expect(more.items.contains { $0.title == L.string("mail.drag.title") })
            for headersOnly in [false, true] {
                let current = try menu(for: f.other.id, model: model, window: window)
                try perform(submenu(current, title: L.string("mail.action.more")), title: L.string(headersOnly ? "mail.source.headers" : "mail.source.original"))
                try await waitUntil("source sheet") { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet)
                try await waitUntil("source text") {
                    textViews(try #require(sheet.contentView)).contains { $0.string.contains("<menu-other@example.test>") }
                }
                let source = textViews(try #require(sheet.contentView)).map(\.string).joined()
                #expect(source.contains("Owned menu body " + f.other.id.uuidString) == !headersOnly)
                #expect(!source.contains("<menu-read@example.test>"))
                try await closeSheet(window)
            }
            try perform(menu(for: f.other.id, model: model, window: window), title: L.string("mail.action.permanentDelete"))
            try await waitUntil("delete confirmation") { window.attachedSheet != nil }
            #expect(try await f.mail.message(id: f.other.id)?.folderId == f.other.folderId)
            try await closeSheet(window)
            #expect(try await f.mail.message(id: f.other.id)?.folderId == f.other.folderId)
            let current = try menu(for: f.other.id, model: model, window: window)
            try perform(submenu(current, title: L.string("mail.action.more")), title: L.string("mail.search.sender"))
            try await waitUntil("clicked sender filter") { model.listFilter.sender == f.other.fromAddress && model.messages.map(\.id) == [f.other.id] }
            #expect(try await f.mail.message(id: f.other.id)?.isRead == false)
            await model.selectMessage(f.other.id)
            try await waitUntil("offline attachment metadata") { model.attachments.count == 1 }; try await layout(window)
            try await expectRendered(L.string("mail.attachment.preparePreview"), in: window, name: "mail-menu-local-attachment-" + language.rawValue)
            #expect(model.attachments[0].localPath == nil)
            model.cancelPendingWork(); window.close()
        }
    }

    @Test("Native batch menus show their scope, explain disabled actions during work and freeze affected IDs",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeBatchMenu() async throws {
        _ = NSApplication.shared
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let f = try await fixture(), (model, window) = try await host(f)
            defer { model.cancelPendingWork(); window.close() }
            let sameAccount: Set<UUID> = [f.firstRead.id, f.firstUnread.id]
            try await select(sameAccount, model: model, window: window)
            let batch = try menu(for: f.firstUnread.id, model: model, window: window)
            #expect(batch.items.contains { $0.title == L.format("mail.selection.count", 2) })
            for key in ["mail.action.archive", "mail.move.title", "mail.action.trash", "mail.export.title"] {
                #expect(batch.items.contains { $0.title == L.format("mail.action.affectedCount", L.string(key), 2) })
            }
            #expect(!batch.items.contains { $0.title == L.string("mail.action.more") || $0.title == L.string("mail.action.reply") })
            let readTitle = L.format("mail.action.affectedCount", L.string("mail.action.markRead"), 1)
            #expect(batch.items.contains { $0.title == readTitle })
            // The native menu owns its original subset even if the reader changes.
            await model.selectMessage(f.other.id); try await layout(window)
            try perform(batch, title: readTitle)
            #expect(model.isPerformingBatch)
            let busy = try menu(for: f.other.id, model: model, window: window)
            let whyItem = try #require(busy.items.first { $0.title == L.string("mail.action.unavailable.title") })
            #expect(whyItem.isEnabled)
            let why = try #require(whyItem.submenu); why.update()
            #expect(why.items.filter { $0.title == L.string("mail.action.unavailable.busy") }.count == 1)
            #expect(busy.items.first { $0.title == L.string("mail.move.title") }?.isEnabled == false)
            #expect(!busy.items.contains { $0.title == L.string("mail.action.unavailable.busy") })
            try await waitUntil("frozen flag batch") { !model.isPerformingBatch && model.batchResult != nil }
            #expect(model.batchResult?.succeeded == [f.firstUnread.id])
            #expect(try await f.mail.message(id: f.firstUnread.id)?.isRead == true)
            #expect(try await f.mail.message(id: f.other.id)?.isRead == false)
            try await layout(window)
            try await select([f.firstRead.id, f.other.id], model: model, window: window)
            let mixed = try menu(for: f.other.id, model: model, window: window)
            let mixedWhy = try submenu(mixed, title: L.string("mail.action.unavailable.title"))
            #expect(mixedWhy.items.contains { $0.title == L.string("mail.move.error.mixedAccounts") })
            #expect(mixed.items.first { $0.title == L.format("mail.action.affectedCount", L.string("mail.move.title"), 2) }?.isEnabled == false)
            try perform(mixed, title: L.format("mail.action.affectedCount", L.string("mail.export.title"), 2))
            try await waitUntil("export preview") { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet); sheet.makeKeyAndOrderFront(nil)
            try await waitUntil("visible export sheet") { sheet.isVisible }
            try await layout(sheet)
            try await expectRendered(L.format("mail.export.count", 2), in: sheet, name: "mail-menu-export-" + language.rawValue)
            #expect(try await f.mail.messageCount(in: .space) == 3)
            try await closeSheet(window)
            model.cancelPendingWork(); window.close()
        }
    }

    private func waitUntil(_ label: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(try await condition(), "Timed out waiting for \(label)")
    }
    private func layout(_ window: NSWindow) async throws {
        for _ in 0..<12 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    private func table(model: MailViewModel, window: NSWindow) throws -> NSTableView {
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
        let view = try #require(window.contentView)
        return try #require(tables(view).first { $0.numberOfRows == model.messages.count })
    }
    private func select(_ ids: Set<UUID>, model: MailViewModel, window: NSWindow) async throws {
        let table = try table(model: model, window: window)
        table.selectRowIndexes(IndexSet(model.messages.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil }), byExtendingSelection: false)
        try await waitUntil("native selection") { model.selectedMessageIDs == ids }; try await layout(window)
    }
    private func menu(for id: UUID, model: MailViewModel, window: NSWindow) throws -> NSMenu {
        let table = try table(model: model, window: window), row = try #require(model.messages.firstIndex { $0.id == id })
        let point = table.convert(NSPoint(x: 30, y: table.rect(ofRow: row).midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try #require(table.menu(for: event)); menu.update(); return menu
    }
    private func submenu(_ menu: NSMenu, title: String) throws -> NSMenu {
        let submenu = try #require(menu.items.first { $0.title == title }?.submenu); submenu.update(); return submenu
    }
    private func perform(_ menu: NSMenu, title: String) throws {
        let index = try #require(menu.items.firstIndex { $0.title == title })
        try #require(menu.items[index].isEnabled, "Menu action must be available: \(title)")
        menu.performActionForItem(at: index)
    }
    private func closeSheet(_ parent: NSWindow) async throws {
        let sheet = try #require(parent.attachedSheet)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        try #require(sheet.performKeyEquivalent(with: escape), "The sheet must offer a native cancel or close action")
        try await waitUntil("sheet close") { parent.attachedSheet == nil }; try await layout(parent)
    }
    private func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
    private func expectRendered(_ title: String, in window: NSWindow, name: String) async throws {
        let view = try #require(window.contentView), bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // The native sheet paints its backdrop outside the content view. Keep
        // the captured glyphs and composite them over that background for OCR.
        let surface = NSImage(size: bitmap.size)
        let foreground = NSImage(size: bitmap.size); foreground.addRepresentation(bitmap)
        surface.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bitmap.size).fill()
            foreground.draw(in: NSRect(origin: .zero, size: bitmap.size), from: .zero, operation: .sourceOver, fraction: 1)
        }
        surface.unlockFocus()
        let tiff = try #require(surface.tiffRepresentation)
        let opaque = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(opaque.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        let language = LanguageManager.shared.activeLanguageCode
        let visible = try await Task.detached {
            try autoreleasepool {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]
                try VNImageRequestHandler(data: data).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            }
        }.value
        #expect(String(visible.filter { !$0.isWhitespace }).contains(String(title.filter { !$0.isWhitespace })))
    }
}
