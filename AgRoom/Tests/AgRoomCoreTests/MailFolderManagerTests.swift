import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
import Vision
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
@Suite("Native folder management and confirmation")
struct MailFolderManagerTests {
    private struct Fixture {
        let queue: DatabaseQueue
        let hub: Hub
        let mail: MailService
        let archive: MailAccount
        let root: MailFolder
        let leaf: MailFolder
        let message: MailMessage
    }
    private func fixture() async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue)
        let archive = try await mail.createLocalArchive(name: "Managed archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let root = MailFolder(accountId: archive.id, path: "Projects", name: "Projects", delimiter: "/", isContainer: true)
        let leaf = MailFolder(accountId: archive.id, path: "Projects/Reports", name: "Reports", parentPath: root.path, delimiter: "/")
        try await mail.upsertFolders([root, leaf])
        let message = MailMessage(accountId: archive.id, folderId: leaf.id, uid: MailService.localUIDFloor, subject: "Retained folder report", bodyState: .ready)
        try await mail.upsertMessages([message]); try await mail.saveBody(.init(messageId: message.id, textBody: "Retained report body"))
        return .init(queue: queue, hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), mail: mail, archive: archive, root: root, leaf: leaf, message: message)
    }
    private func waitUntil(_ label: String = "condition", _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition(), "Timed out waiting for \(label)")
    }

    @Test("Local management reviews before writes, preserves rename identity, cancels deletion and keeps preferences in the source space")
    func localModel() async throws {
        let f = try await fixture()
        var changes = 0
        let model = MailFolderManagerModel(hub: f.hub, space: .work, accountID: f.archive.id, folderID: f.root.id, onChanged: { changes += 1 })
        await model.load()
        model.openRename(); model.editor?.name = "Delivered"
        model.prepareEditor(); try await waitUntil { !model.busy }
        #expect(model.editor?.review?.mutation.before.count == 2)
        #expect(try await f.mail.folders(accountId: f.archive.id).contains { $0.path == f.root.path })
        model.executeEditor(); try await waitUntil { !model.busy }
        #expect(model.editor == nil && model.result?.state == .complete)
        #expect(try await f.mail.folders(accountId: f.archive.id).first { $0.id == f.leaf.id }?.path == "Delivered/Reports")
        #expect(try await f.mail.message(id: f.message.id)?.folderId == f.leaf.id)
        model.openCreate(parentID: f.root.id); model.editor?.name = "New child"
        model.prepareEditor(); try await waitUntil { !model.busy }
        let createdID = try #require(model.editor?.review?.mutation.rootID)
        model.executeEditor(); try await waitUntil { !model.busy }
        #expect(try await f.mail.folders(accountId: f.archive.id).contains { $0.id == createdID && $0.path == "Delivered/New child" })
        model.selectedID = f.root.id
        model.setHidden(true, folderID: f.root.id); try await waitUntil { !model.busy }
        #expect(model.visibility.hidden.contains(f.leaf.id))
        model.openDelete(); try await waitUntil { !model.busy }
        #expect(model.editor?.review?.mutation.cachedMessageCount == 1)
        model.dismissEditor()
        #expect(try await f.mail.message(id: f.message.id) != nil)
        model.openDelete(); try await waitUntil { !model.busy }; model.executeEditor(); try await waitUntil { !model.busy }
        #expect(model.result?.state == .complete && model.result?.completedFolderIDs.count == 3)
        #expect(try await f.mail.message(id: f.message.id) == nil)
        #expect(changes == 4)
        model.cancelPendingWork(); model.openCreate(parentID: nil)
        #expect(model.editor == nil && model.createReason != nil)
    }

    @Test("A changed local delete scope returns to review and protects newly added messages")
    func staleDelete() async throws {
        let f = try await fixture()
        let model = MailFolderManagerModel(hub: f.hub, space: .work, accountID: f.archive.id, folderID: f.root.id, initialAction: .delete)
        await model.load(); try await waitUntil { !model.busy }
        #expect(model.editor?.review != nil)
        let added = MailMessage(accountId: f.archive.id, folderId: f.leaf.id, uid: MailService.localUIDFloor + 1, subject: "Arrived after review")
        try await f.mail.upsertMessages([added])
        model.executeEditor(); try await waitUntil { !model.busy }
        #expect(model.editor?.review == nil && model.editor?.error == L.string("mail.folder.edit.error.changed"))
        #expect(try await f.mail.message(id: f.message.id) != nil)
        #expect(try await f.mail.message(id: added.id) != nil)
        model.prepareEditor(); try await waitUntil { !model.busy }
        #expect(model.editor?.review?.mutation.cachedMessageCount == 2)
        model.cancelPendingWork()
    }

    @Test("Pending results are inspectable in the manager, cache reset needs explicit acknowledgment, and closing cancels late publication")
    func remoteManagerRecovery() async throws {
        let f = try await MailFolderOperationTests().fixture(ownServerUID: true)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let model = MailFolderManagerModel(hub: hub, space: .work, accountID: f.account.id, folderID: f.root.id)
        model.makeOperations = { f.service }
        await model.load(); model.openRename(); model.editor?.name = "Recovered"
        model.prepareEditor(); try await waitUntil { !model.busy }
        await f.server.configureFolderOperations(failure: .afterApply, kind: .rename)
        model.executeEditor(); try await waitUntil { !model.busy }
        #expect(model.pending?.state == .unknown && model.editor?.review == nil)
        model.inspectFromEditor(); try await waitUntil { !model.busy }
        #expect(model.editor == nil && model.recovery?.disposition == .resetCache && !model.resetAcknowledged)
        model.finishRecovery(); #expect(!model.busy)
        #expect(try await f.mail.message(id: f.cached.id) != nil)
        model.resetAcknowledged = true; model.finishRecovery(); try await waitUntil { !model.busy }
        #expect(model.recovery == nil && model.pending == nil && model.result?.state == .complete)
        #expect(await f.server.folderMutationCalls.count == 1)
        #expect(try await f.mail.message(id: f.cached.id) == nil)
        #expect(try await f.mail.message(id: f.own.id)?.uid ?? 0 >= MailService.localUIDFloor)
        model.cancelPendingWork(); model.inspectPending()
        #expect(!model.busy && model.recovery == nil)
    }

    @Test("Native folder manager creates, renames, cancels deletion and confirms with the keyboard in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeLocalWorkflow() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let f = try await fixture(), model = MailFolderManagerModel(hub: f.hub, space: .work, accountID: f.archive.id, folderID: f.root.id)
            let window = makeWindow(model)
            defer { model.cancelPendingWork(); window.close() }
            try await waitUntil { !model.busy && model.account != nil }; try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-folder-manager-\(language.rawValue).png"))
            try await press(L.string("mail.folder.edit.new"), in: window)
            try await waitUntil { model.editor?.kind == .create }; try await layout(window)
            try await enter("Native Folder", placeholder: L.string("mail.folder.edit.name"), current: "", in: window)
            try await press(L.string("mail.folder.edit.preview"), in: window)
            try await waitUntil { !model.busy && model.editor?.review != nil }; try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-folder-create-\(language.rawValue).png"))
            let created = try #require(model.editor?.review?.mutation.rootID)
            try await press(L.string("mail.folder.edit.confirm.create"), in: window)
            try await waitUntil { !model.busy && model.editor == nil }; try await layout(window)
            try await press("Native Folder", in: window)
            try await waitUntil { model.selectedID == created }
            try await press(L.string("mail.folder.edit.rename"), in: window)
            try await waitUntil { model.editor?.kind == .rename }; try await layout(window)
            try await enter("Renamed Native", placeholder: L.string("mail.folder.edit.name"), current: "Native Folder", in: window)
            try await press(L.string("mail.folder.edit.preview"), in: window)
            try await waitUntil { !model.busy && model.editor?.review != nil }; try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-folder-rename-\(language.rawValue).png"))
            try await press(L.string("mail.folder.edit.confirm.rename"), in: window)
            try await waitUntil { !model.busy && model.editor == nil }; try await layout(window)
            try await press("Renamed Native", in: window)
            try await waitUntil { model.selectedID == created }
            try await press(L.string("mail.folder.edit.delete"), in: window)
            try await waitUntil { !model.busy && model.editor?.review != nil }; try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-folder-delete-\(language.rawValue).png"))
            #expect(try await f.mail.folders(accountId: f.archive.id).contains { $0.id == created })
            try await press(L.string("common.cancel"), in: window)
            try await waitUntil { model.editor == nil }; try await layout(window)
            #expect(try await f.mail.folders(accountId: f.archive.id).contains { $0.id == created })
            try await press(L.string("mail.folder.edit.delete"), in: window)
            try await waitUntil { !model.busy && model.editor?.review != nil }; try await layout(window)
            try await press(L.string("mail.folder.edit.confirm.delete"), in: window, keyboardDefault: true)
            try await waitUntil("confirmed local deletion") { !model.busy && model.editor == nil }
            #expect(try await !f.mail.folders(accountId: f.archive.id).contains { $0.id == created })
            #expect(try await f.mail.message(id: f.message.id)?.folderId == f.leaf.id)
            model.cancelPendingWork(); window.close()
        }
    }

    @Test("The production sidebar opens management, applies a reviewed create and dismisses on leaving its space",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeSidebarEntry() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let previous = LanguageManager.shared.currentLanguage
        let previousSpace = UserDefaults.standard.object(forKey: SpaceStore.StorageKeys.currentSpace)
        defer {
            LanguageManager.shared.currentLanguage = previous
            if let previousSpace { UserDefaults.standard.set(previousSpace, forKey: SpaceStore.StorageKeys.currentSpace) }
            else { UserDefaults.standard.removeObject(forKey: SpaceStore.StorageKeys.currentSpace) }
        }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let f = try await fixture(), reader = MailViewModel(hub: f.hub, space: .work)
            await reader.loadIfNeeded(); await reader.selectAccount(f.archive.id); await reader.selectFolder(f.leaf.id)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MailView(hub: f.hub, viewModel: reader).frame(width: 1100, height: 680).background(Color(nsColor: .windowBackgroundColor)))
            window.makeKeyAndOrderFront(nil)
            defer { reader.cancelPendingWork(); window.close() }
            try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-folder-entry-\(language.rawValue).png"))
            try await press(L.string("mail.folder.edit.manage"), in: window)
            try await waitUntil("production manager sheet") { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet); sheet.makeKeyAndOrderFront(nil); try await layout(sheet)
            try await press(L.string("mail.folder.edit.new"), in: sheet); try await layout(sheet)
            try await enter("Sidebar Created", placeholder: L.string("mail.folder.edit.name"), current: "", in: sheet)
            try await press(L.string("mail.folder.edit.preview"), in: sheet); try await layout(sheet)
            #expect(try await !f.mail.folders(accountId: f.archive.id).contains { $0.path == "Sidebar Created" })
            try await press(L.string("mail.folder.edit.confirm.create"), in: sheet)
            try await waitUntil("source reader reload") { reader.folders.contains { $0.path == "Sidebar Created" } }
            try await layout(sheet)
            try snapshot(sheet, at: directory.appendingPathComponent("mail-folder-entry-result-\(language.rawValue).png"))
            try await press(L.string("common.close"), in: sheet)
            try await waitUntil("manager close") { window.attachedSheet == nil }; try await layout(window)
            try await press(L.string("mail.folder.edit.manage"), in: window)
            try await waitUntil("manager reopen") { window.attachedSheet != nil }
            f.hub.spaceStore.switchTo(.personal)
            try await waitUntil("space change closes manager") { window.attachedSheet == nil }
            #expect(try await f.mail.message(id: f.message.id) != nil)
            reader.cancelPendingWork(); window.close()
        }
    }

    @Test("Native recovery requires acknowledgment before keyboard confirmation can reset server caches",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeRecoveryWorkflow() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let f = try await MailFolderOperationTests().fixture(ownServerUID: true)
            let model = MailFolderManagerModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue)), space: .work, accountID: f.account.id, folderID: f.root.id)
            model.makeOperations = { f.service }
            await model.load(); model.openRename(); model.editor?.name = "Recovered"
            model.prepareEditor(); try await waitUntil { !model.busy }
            await f.server.configureFolderOperations(failure: .afterApply, kind: .rename)
            model.executeEditor(); try await waitUntil { !model.busy }
            model.dismissEditor()
            let window = makeWindow(model)
            defer { model.cancelPendingWork(); window.close() }
            try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-folder-pending-\(language.rawValue).png"))
            try await press(L.string("mail.folder.edit.inspect"), in: window)
            try await waitUntil("recovery inspection") { !model.busy && model.recovery != nil }; try await layout(window)
            #expect(model.recovery?.disposition == .resetCache && !model.resetAcknowledged)
            try snapshot(window, at: directory.appendingPathComponent("mail-folder-recovery-\(language.rawValue).png"))
            _ = try sendReturn(in: window)
            try await layout(window)
            #expect(model.recovery?.disposition == .resetCache && !model.resetAcknowledged && !model.busy)
            #expect(try await f.mail.message(id: f.cached.id) != nil)
            try await press(L.string("mail.folder.edit.resetAcknowledge"), in: window)
            try snapshot(window, at: directory.appendingPathComponent("mail-folder-recovery-click-\(language.rawValue).png"))
            try await waitUntil("reset acknowledgment") { model.resetAcknowledged }; try await layout(window)
            try await press(L.string("mail.folder.edit.recoverConfirm.resetCache"), in: window, keyboardDefault: true)
            try await layout(window)
            try snapshot(window, at: directory.appendingPathComponent("mail-folder-recovery-result-\(language.rawValue).png"))
            try await waitUntil("recovery completion") { !model.busy && model.recovery == nil && model.pending == nil }
            #expect(await f.server.folderMutationCalls.count == 1)
            #expect(try await f.mail.message(id: f.cached.id) == nil)
            #expect(try await f.mail.rawMessage(id: f.own.id)?.kind == .generated)
            model.cancelPendingWork(); window.close()
        }
    }

    private func makeWindow(_ model: MailFolderManagerModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: MailFolderManagerView(model: model)); window.makeKeyAndOrderFront(nil)
        return window
    }
    private func layout(_ window: NSWindow) async throws {
        for _ in 0..<12 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    private func snapshot(_ window: NSWindow, at url: URL) throws {
        let view = try #require(window.contentView), bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    private func enter(_ value: String, placeholder: String, current: String, in window: NSWindow) async throws {
        let view = try #require(window.contentView)
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, field.placeholderString == placeholder { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        if let field = find(view) { window.makeFirstResponder(field) }
        else { try await press(current.isEmpty ? placeholder : current, in: window, exact: true) }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil); editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await layout(window)
    }
    private func press(_ title: String, in window: NSWindow, exact: Bool = false, keyboardDefault: Bool = false) async throws {
        let view = try #require(window.contentView)
        if !keyboardDefault, let control = accessibleControl(title, in: view), title != L.string("mail.folder.edit.new") {
            if control.accessibilityRole() == .checkBox, control.accessibilityPerformPress() { return }
            let frame = control.accessibilityFrame()
            try window.sendTestClick(at: window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)), matching: title)
            return
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:])), language = LanguageManager.shared.activeLanguageCode
        let point = try await Task.detached { () throws -> CGPoint in
            try autoreleasepool {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]; request.customWords = [title]
                try VNImageRequestHandler(data: data).perform([request])
                for observation in (request.results ?? []).sorted(by: { $0.boundingBox.midY < $1.boundingBox.midY }) {
                    guard let text = observation.topCandidates(1).first else { continue }
                    let indices = text.string.indices.filter { !text.string[$0].isWhitespace }
                    let compact = String(indices.map { text.string[$0] })
                    let target = String((title.hasSuffix("…") ? String(title.dropLast()) : title).filter { !$0.isWhitespace })
                    if exact && compact.compare(target, options: [.caseInsensitive, .widthInsensitive]) != .orderedSame { continue }
                    guard let match = compact.range(of: target, options: [.caseInsensitive, .widthInsensitive]), !match.isEmpty else { continue }
                    let start = compact.distance(from: compact.startIndex, to: match.lowerBound), end = compact.distance(from: compact.startIndex, to: match.upperBound)
                    let range = indices[start]..<text.string.index(after: indices[end - 1])
                    if let box = try? text.boundingBox(for: range) { return .init(x: box.boundingBox.midX, y: box.boundingBox.midY) }
                }
                throw ControlNotFound(title: title, visible: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
            }
        }.value
        let location = view.convert(NSPoint(x: point.x * view.bounds.width, y: (view.isFlipped ? 1 - point.y : point.y) * view.bounds.height), to: nil)
        if keyboardDefault {
            try #require(try sendReturn(in: window), "Visible confirmation must respond to its default keyboard action: \(title)")
            return
        }
        try window.sendTestClick(at: location, matching: title)
    }
    private func sendReturn(in window: NSWindow) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        return window.performKeyEquivalent(with: event)
    }
    private func accessibleControl(_ title: String, in view: NSView) -> (any NSAccessibilityProtocol)? {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let node = object as? any NSAccessibilityProtocol {
                if (node.accessibilityRole() == .button || node.accessibilityRole() == .checkBox), node.isAccessibilityEnabled(),
                   node.accessibilityLabel() == title || node.accessibilityTitle() == title,
                   node.accessibilityFrame().width > 0 { return node }
                for child in node.accessibilityChildren() ?? [] { if let match = visit(child as AnyObject, depth: depth + 1) { return match } }
            }
            if let native = object as? NSView {
                for child in native.subviews where !child.isHidden { if let match = visit(child, depth: depth + 1) { return match } }
            }
            return nil
        }
        return visit(view)
    }
    private struct ControlNotFound: Error, CustomStringConvertible {
        let title: String
        let visible: [String]
        var description: String { "Visible control not found: \(title). Rendered: \(visible.joined(separator: " | "))" }
    }
}
