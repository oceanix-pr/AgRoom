import Foundation
import Testing
import GRDB
import AppKit
import SwiftUI
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Native app workspaces")
struct NativeAppWorkspaceTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("native-app-data-" + UUID().uuidString)
    }

    @Test("Records survive reopening, use revision checks, and stay separate by app and space")
    func recordsAndIsolation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let work = NativeAppStore(directoryURL: root.appendingPathComponent("work/apps"), space: .work)
        let note = try NativeAppTemplates.note()
        var other = note; other.manifest.id = "another-note"
        try await personal.install(note, replacing: nil)
        try await personal.install(other, replacing: nil)
        try await work.install(note, replacing: nil)
        let first = try await personal.workspace(for: note)
        let second = try await personal.workspace(for: other)
        let third = try await work.workspace(for: note)
        let id = UUID()
        #expect(throws: NativeAppError(.spaceMismatch)) {
            _ = try first.makeSaveFileCommand(space: .work, name: "wrong.txt", data: Data())
        }
        try await first.saveRecord(id: id, collection: "notes", title: "100% private", content: "one",
            fields: ["amount": .number(12.5), "done": .bool(false)], replacing: nil)
        try await second.saveRecord(id: id, collection: "notes", title: "Other app", content: "two", replacing: nil)
        try await third.saveRecord(id: id, collection: "notes", title: "Work", content: "three", replacing: nil)
        let reopened = try await NativeAppStore(directoryURL: personal.directoryURL, space: .personal).workspace(for: note)
        #expect(try await reopened.record(id: id).fields["amount"] == .number(12.5))
        #expect(try await reopened.records(collection: "notes", search: "%").map(\.id) == [id])
        #expect(try await second.record(id: id).content == "two")
        #expect(try await third.record(id: id).content == "three")
        await #expect(throws: NativeAppError(.conflict)) {
            try await reopened.saveRecord(id: id, collection: "notes", title: "stale", content: "", replacing: nil)
        }
        try await reopened.saveRecord(id: id, collection: "notes", title: "Updated", content: "four", replacing: 1)
        await #expect(throws: NativeAppError(.conflict)) { try await first.deleteRecord(id: id, revision: 1) }
        let snapshot = try await personal.load(id: note.id)
        var update = note; update.manifest.version += 1
        update.state["sort"] = .init(initial: .string("date"), persistent: true)
        try await personal.install(update, replacing: snapshot.revision)
        #expect(try await reopened.record(id: id).revision == 2)
        let current = try await personal.load(id: note.id)
        try await personal.remove(id: note.id, revision: current.revision, keepData: true)
        #expect(try await personal.catalog().retainedApps.map(\.id) == [note.id])
        await #expect(throws: NativeAppError(.missing)) { _ = try await first.record(id: id) }
        let retained = try await personal.loadIncludingRetained(id: note.id)
        try await personal.install(update, replacing: retained.revision)
        await #expect(throws: NativeAppError(.conflict)) {
            try await first.saveRecord(id: UUID(), collection: "notes", title: "late", content: "", replacing: nil)
        }
        let restored = try await personal.workspace(for: update)
        #expect(try await restored.record(id: id).content == "four")
    }

    @Test("Files have safe generated paths, attachment references, and recover orphan publication")
    func filesAndReconciliation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let note = try NativeAppTemplates.note()
        try await store.install(note, replacing: nil)
        let workspace = try await store.workspace(for: note)
        let recordID = UUID(), fileID = UUID()
        try await workspace.saveRecord(id: recordID, collection: "notes", title: "With attachment", content: "", replacing: nil)
        let bytes = Data("hello".utf8)
        try await workspace.saveFile(id: fileID, name: "中文 名称.txt", data: bytes, recordID: recordID)
        let file = try #require(try await workspace.files().first)
        #expect(file.relativePath == "files/" + fileID.uuidString.lowercased())
        #expect(try await workspace.fileData(id: fileID) == bytes)
        await #expect(throws: NativeAppError.self) { try await workspace.saveFile(id: UUID(), name: "../outside", data: bytes) }
        await #expect(throws: NativeAppError.self) {
            try await workspace.saveFile(id: UUID(), name: "large", data: Data(repeating: 0, count: NativeAppWorkspace.maximumFileBytes + 1))
        }
        let files = store.directoryURL.appendingPathComponent(note.id).appendingPathComponent("files")
        let orphan = files.appendingPathComponent(UUID().uuidString.lowercased())
        try bytes.write(to: orphan)
        _ = try await workspace.files()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        try await workspace.deleteRecord(id: recordID, revision: 1)
        #expect(try await workspace.files().first?.recordID == nil)
        try Data("wrong".utf8).write(to: files.appendingPathComponent(fileID.uuidString.lowercased()))
        await #expect(throws: NativeAppError(.corruptData)) { _ = try await workspace.fileData(id: fileID) }
        await #expect(throws: NativeAppError(.corruptData)) { _ = try await store.backup(id: note.id, space: .personal) }
        try bytes.write(to: files.appendingPathComponent(fileID.uuidString.lowercased()))
        let failedID = UUID()
        await #expect(throws: (any Error).self) {
            try await workspace.saveFile(id: failedID, name: "unlinked.txt", data: bytes, recordID: UUID())
        }
        #expect(try await workspace.files().count == 1)
        #expect(!FileManager.default.fileExists(atPath: files.appendingPathComponent(failedID.uuidString.lowercased()).path))
        try await workspace.deleteFile(file)
        #expect(try await workspace.files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files.appendingPathComponent(fileID.uuidString.lowercased()).path))
        let database = store.directoryURL.appendingPathComponent(note.id).appendingPathComponent("data.sqlite")
        try FileManager.default.removeItem(at: database)
        let target = root.appendingPathComponent("outside.sqlite")
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: target)
        await #expect(throws: NativeAppError(.unsafePath)) { _ = try await workspace.files() }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test("Portable backups restore records, files and editor drafts with conflict and space checks")
    func backupAndRestore() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NativeAppStore(directoryURL: root.appendingPathComponent("source/personal/apps"), space: .personal)
        let target = NativeAppStore(directoryURL: root.appendingPathComponent("target/personal/apps"), space: .personal)
        let note = try NativeAppTemplates.note()
        try await source.install(note, replacing: nil)
        let workspace = try await source.workspace(for: note)
        let id = UUID(), fileID = UUID()
        try await workspace.saveRecord(id: id, collection: "notes", title: "Original", content: "body", replacing: nil)
        try await workspace.saveFile(id: fileID, name: "attachment.bin", data: Data([1, 2, 3]), recordID: id)
        try await workspace.saveDraft(.init(values: ["title": .string("Unsaved edit")],
            editors: ["notes": .init(id: id, collection: "notes", revision: 1)]), for: note)
        let cache = source.directoryURL.appendingPathComponent(note.id).appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("disposable".utf8).write(to: cache.appendingPathComponent("derived"))
        let archive = try NativeAppBackup.decode(try await source.backup(id: note.id, space: .personal).encoded())
        let plan = try await target.inspectRestore(archive, space: .personal)
        #expect(plan.previousFingerprint == nil)
        #expect(!FileManager.default.fileExists(atPath: target.directoryURL.path))
        await #expect(throws: NativeAppError(.spaceMismatch)) {
            try await target.restore(archive, space: .work, replacing: nil)
        }
        try await target.restore(archive, space: .personal, replacing: plan.previousFingerprint)
        let restored = try await target.workspace(for: note)
        #expect(try await restored.record(id: id).title == "Original")
        #expect(try await restored.fileData(id: fileID) == Data([1, 2, 3]))
        #expect(try await restored.loadDraft(for: note).editors["notes"]?.id == id)
        #expect(try await restored.loadDraft(for: note).values["title"] == .string("Unsaved edit"))
        #expect(!FileManager.default.fileExists(atPath: target.directoryURL.appendingPathComponent(note.id + "/cache/derived").path))
        let oldPlan = try await target.inspectRestore(archive, space: .personal)
        try await restored.saveRecord(id: id, collection: "notes", title: "Changed after preview", content: "", replacing: 1)
        await #expect(throws: NativeAppError(.conflict)) {
            try await target.restore(archive, space: .personal, replacing: oldPlan.previousFingerprint)
        }
        let newPlan = try await target.inspectRestore(archive, space: .personal)
        try await target.restore(archive, space: .personal, replacing: newPlan.previousFingerprint)
        await #expect(throws: NativeAppError(.conflict)) { _ = try await restored.record(id: id) }
        let recovery = try await target.recoveryBackup(id: note.id, space: .personal)
        #expect(recovery.contents.records.first?.title == "Changed after preview")
        var corrupt = try #require(JSONSerialization.jsonObject(with: archive.encoded()) as? [String: Any])
        corrupt["sha256"] = String(repeating: "0", count: 64)
        #expect(throws: NativeAppError(.corruptData)) {
            _ = try NativeAppBackup.decode(JSONSerialization.data(withJSONObject: corrupt))
        }
        let installed = try await target.load(id: note.id)
        try await target.remove(id: note.id, revision: installed.revision, keepData: true)
        let retainedBackup = try await target.backup(id: note.id, space: .personal)
        #expect(!retainedBackup.isInstalled)
        let third = NativeAppStore(directoryURL: root.appendingPathComponent("third/personal/apps"), space: .personal)
        try await third.restore(retainedBackup, space: .personal, replacing: nil)
        #expect(try await third.catalog().apps.isEmpty)
        #expect(try await third.catalog().retainedApps.count == 1)
        let retained = try await third.loadIncludingRetained(id: note.id)
        try await third.install(note, replacing: retained.revision)
        #expect(try await third.workspace(for: note).record(id: id).title == "Original")

        // Recovery remains usable when the current database cannot be parsed.
        let databaseURL = target.directoryURL.appendingPathComponent(note.id + "/data.sqlite")
        let damaged = Data("not a database".utf8)
        try damaged.write(to: databaseURL)
        let damagedPlan = try await target.inspectRestore(archive, space: .personal)
        #expect(damagedPlan.currentDataIsUnreadable)
        try await target.restore(archive, space: .personal, replacing: damagedPlan.previousFingerprint)
        #expect(try await target.workspace(for: note).record(id: id).title == "Original")
        let raw = try await target.rawRecoveryDirectory(id: note.id)
        #expect(try Data(contentsOf: raw.appendingPathComponent("data.sqlite")) == damaged)
        let last = try await target.load(id: note.id)
        try await target.remove(id: note.id, revision: last.revision)
        await #expect(throws: NativeAppError(.missing)) { _ = try await target.rawRecoveryDirectory(id: note.id) }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @MainActor @Test("Private note saving resumes the same editor after restart; publishing remains explicit")
    func noteRuntime() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let note = try NativeAppTemplates.note()
        try await store.install(note, replacing: nil)
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let knowledge = KnowledgeService(databaseQueue: queue)
        let resources = NativeAppResources(space: .personal, knowledge: knowledge)
        let model = NativeAppRuntime(definition: note, space: .personal, store: store, resources: resources)
        await model.activate()
        model.setValue(.string("Private note"), key: "title")
        model.setValue(.string("First body"), key: "body")
        model.perform("local-save")
        try await waitUntil { model.pending != nil }
        let pending = try #require(model.pending)
        #expect(try await store.workspace(for: note).records(collection: "notes").isEmpty)
        model.decide(pending, approved: true)
        try await waitUntil { !model.isBusy }
        #expect(try await knowledge.getAll().isEmpty)
        #expect(await model.flush())
        let record = try #require(try await store.workspace(for: note).records(collection: "notes").first)
        model.suspend()
        let reopened = NativeAppRuntime(definition: note, space: .personal, store: store, resources: resources)
        await reopened.activate()
        #expect(reopened.editors["notes"]?.id == record.id)
        reopened.setValue(.string("Second body"), key: "body")
        reopened.perform("local-save")
        try await waitUntil { reopened.pending != nil }
        reopened.decide(try #require(reopened.pending), approved: true)
        try await waitUntil { !reopened.isBusy }
        #expect(try await store.workspace(for: note).records(collection: "notes").count == 1)
        #expect(try await store.workspace(for: note).record(id: record.id).revision == 2)
        reopened.perform("save")
        try await waitUntil { reopened.pending != nil }
        #expect(try await knowledge.getAll().isEmpty)
        reopened.decide(try #require(reopened.pending), approved: true)
        try await waitUntil { !reopened.isBusy }
        #expect(try await knowledge.getAll().count == 1)
        reopened.perform("new")
        #expect(reopened.editors.isEmpty && reopened.values["title"] == .string(""))
        #expect(await reopened.flush())
        reopened.suspend()
    }

    @MainActor @Test("File import confirmation is revoked when the file manager closes")
    func fileCommandCancellation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let note = try NativeAppTemplates.note()
        try await store.install(note, replacing: nil)
        let workspace = try await store.workspace(for: note)
        let source = root.appendingPathComponent("selected.txt")
        try Data("selected".utf8).write(to: source)
        let nonFileURL = try #require(URL(string: "https://example.invalid" + source.path))
        await #expect(throws: NativeAppError(.unsafePath)) { _ = try await NativeAppWorkspace.readSelectedFile(nonFileURL) }
        let runtime = NativeAppRuntime(definition: note, space: .personal, store: store)
        await runtime.activate()
        #expect(runtime.openFiles())
        let model = try #require(runtime.filesModel)
        model.importFile(source, recordID: nil)
        try await waitUntil { model.pending != nil }
        let pending = try #require(model.pending)
        #expect(try await workspace.files().isEmpty)
        runtime.suspend()
        model.decide(pending, approved: true)
        #expect(try await workspace.files().isEmpty)
        await #expect(throws: CancellationError.self) {
            _ = try await pending.engine.resume(.confirmed(approvalID: pending.id, approved: true, alwaysAllow: false, persistRule: false))
        }
        await runtime.activate()
        #expect(runtime.openFiles())
        let reopened = try #require(runtime.filesModel)
        reopened.importFile(source, recordID: nil)
        try await waitUntil { reopened.pending != nil }
        reopened.decide(try #require(reopened.pending), approved: true)
        try await waitUntil { !reopened.busy }
        let file = try #require(try await workspace.files().first)
        #expect(try await workspace.fileData(id: file.id) == Data("selected".utf8))
        reopened.delete(file)
        try await waitUntil { reopened.pending != nil }
        reopened.decide(try #require(reopened.pending), approved: true)
        try await waitUntil { !reopened.busy }
        #expect(try await workspace.files().isEmpty)
        runtime.suspend()
    }

    @MainActor @Test("Native file confirmation and restore preview remain read-only until approval")
    func workspaceViews() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let note = try NativeAppTemplates.note()
        try await store.install(note, replacing: nil)
        let workspace = try await store.workspace(for: note)
        try await workspace.saveFile(id: UUID(), name: "示例附件.txt", data: Data("Preview data".utf8))
        let source = root.appendingPathComponent("import.txt")
        try Data("New file".utf8).write(to: source)
        let backup = try await store.backup(id: note.id, space: .personal)
        let before = backup.fingerprint

        for dark in [false, true] {
            let files = NativeAppFilesModel(workspace: workspace, space: .personal)
            await files.reload()
            let host = NSHostingView(rootView: NativeAppFilesView(model: files, recordID: nil)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.close() }
            await Task.yield()
            try capture(host, name: "app-files", dark: dark)
            files.importFile(source, recordID: nil)
            try await waitUntil { files.pending != nil }
            try await Task.sleep(for: .milliseconds(30))
            try capture(host, name: "app-file-confirmation", dark: dark)
            #expect(files.pending != nil)
            #expect(try await workspace.files().count == 1)
            files.suspend()

            let restoreHost = NSHostingView(rootView: NativeAppDataRestoreSheet(backup: backup, store: store, space: .personal, onRestore: {})
                .environment(\.colorScheme, dark ? .dark : .light))
            let restoreWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
                styleMask: [.borderless], backing: .buffered, defer: false)
            restoreWindow.isReleasedWhenClosed = false
            restoreWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            restoreWindow.contentView = restoreHost
            defer { restoreWindow.close() }
            try await Task.sleep(for: .milliseconds(100))
            try capture(restoreHost, name: "app-data-restore", dark: dark)
        }
        #expect(try await store.backup(id: note.id, space: .personal).fingerprint == before)
    }

    @MainActor private func capture(_ host: NSView, name: String, dark: Bool) throws {
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        guard let directory = ProcessInfo.processInfo.environment["AGROOM_NATIVE_APP_SNAPSHOT_DIR"] else { return }
        let preview = NSImage(size: host.bounds.size)
        preview.lockFocus()
        (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).setFill()
        host.bounds.fill()
        if let cg = bitmap.cgImage { NSImage(cgImage: cg, size: host.bounds.size).draw(in: host.bounds, from: .zero, operation: .sourceOver, fraction: 1) }
        preview.unlockFocus()
        let tiff = try #require(preview.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
