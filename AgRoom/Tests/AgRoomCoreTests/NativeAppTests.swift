import Foundation
import Testing
import GRDB
import AppKit
import SwiftUI
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Native mini apps")
struct NativeAppTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-app-test-" + UUID().uuidString)
    }

    @MainActor @Test("Conversation-authored app previews need no provider and never install automatically")
    func conversationPreparation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = NativeAppDraftStore(directoryURL: root.appendingPathComponent("personal/drafts"), space: .personal)
        let tool = NativeAppPrepareTool(space: .personal, makeStore: { nil }, publish: { definition, updating in
            try await drafts.save(definition, updatingAppID: updating)
        })
        let definition = try NativeAppTemplates.note()
        let json = String(decoding: try definition.encoded(), as: UTF8.self)
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["definition_json": json]), as: UTF8.self)
        let result = try await tool.execute(argumentsJSON: arguments)
        #expect(result.contains("Nothing was installed"))
        #expect(try await drafts.catalog().drafts.first?.definition == definition)
        let work = NativeAppDraftStore(directoryURL: root.appendingPathComponent("work/drafts"), space: .work)
        #expect(try await work.catalog().drafts.isEmpty)
        #expect(try await NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal).catalog().apps.isEmpty)

        await #expect(throws: LLMError.self) {
            _ = try await tool.execute(argumentsJSON: #"{"requirement":"build a note app"}"#)
        }
        await #expect(throws: NativeAppError.self) {
            _ = try await tool.execute(argumentsJSON: #"{"definition_json":"{}"}"#)
        }
        #expect(try await drafts.catalog().drafts.count == 1)
    }

    @MainActor @Test("Conversation updates preserve app identity and saved data until explicit installation")
    func conversationUpdate() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root, space: .work)
        let original = try NativeAppTemplates.note()
        try await store.install(original, replacing: nil)
        try await store.saveState(["title": .string("Keep this draft")], for: original)
        let drafts = NativeAppDraftStore(directoryURL: root.appendingPathComponent("pending"), space: .work)
        let tool = NativeAppPrepareTool(space: .work, makeStore: { store }, publish: { definition, updating in
            try await drafts.save(definition, updatingAppID: updating)
        })
        func arguments(_ definition: NativeAppDefinition) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: [
                "app_id": original.id, "definition_json": String(decoding: try definition.encoded(), as: UTF8.self)
            ]), as: UTF8.self)
        }
        await #expect(throws: NativeAppError.self) { _ = try await tool.execute(argumentsJSON: arguments(original)) }
        var updated = original
        updated.manifest.version += 1
        var incompatible = updated
        incompatible.state["title"]?.persistent = false
        await #expect(throws: NativeAppError.self) { _ = try await tool.execute(argumentsJSON: arguments(incompatible)) }
        _ = try await tool.execute(argumentsJSON: arguments(updated))
        #expect(try await drafts.catalog().drafts.first?.definition == updated)
        #expect(try await store.load(id: original.id).definition == original)
        #expect(try await store.loadState(for: original)["title"] == .string("Keep this draft"))
    }

    @Test("Untrusted definitions reject broken references, missing translations and excessive trees")
    func validation() throws {
        let note = try NativeAppTemplates.note()
        _ = try NativeAppTemplates.knowledge()
        #expect(try NativeAppDefinition.decode(note.encoded()) == note)
        var missingTranslation = note
        missingTranslation.i18n["zh-Hant"]?.removeValue(forKey: "save")
        #expect(throws: NativeAppError.self) { try missingTranslation.validate() }
        var invalidBinding = note
        invalidBinding.actions["save"]?.values?["title"] = .init(literal: nil, state: "absent", selection: nil)
        #expect(throws: NativeAppError.self) { try invalidBinding.validate() }
        var duplicateID = note
        duplicateID.views.children?[0].id = note.views.id
        #expect(throws: NativeAppError.self) { try duplicateID.validate() }
        var deeplyNested = note
        for index in 0..<15 {
            deeplyNested.views = .init(id: "level-\(index)", type: .vstack, children: [deeplyNested.views])
        }
        #expect(throws: NativeAppError.self) { try deeplyNested.validate() }
        for id in ["../work", "/tmp/app", "a/b", "知识", "-app", "app-", String(repeating: "x", count: 65)] {
            var invalidID = note; invalidID.manifest.id = id
            #expect(throws: NativeAppError.self) { try invalidID.validate() }
        }
        let unsupported = String(decoding: try note.encoded(), as: UTF8.self).replacingOccurrences(of: "saveKnowledge", with: "shell_run")
        #expect(throws: NativeAppError.self) { try NativeAppDefinition.decode(Data(unsupported.utf8)) }
        var withLoadHook = try #require(JSONSerialization.jsonObject(with: note.encoded()) as? [String: Any])
        withLoadHook["onLoad"] = ["tool": "mail_send"]
        #expect(throws: NativeAppError.self) { try NativeAppDefinition.decode(JSONSerialization.data(withJSONObject: withLoadHook)) }
    }

    @Test("Updates are revision-bound, preserve state and keep a recoverable definition")
    func publicationAndIsolation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let work = NativeAppStore(directoryURL: root.appendingPathComponent("work/apps"), space: .work)
        let original = try NativeAppTemplates.note()
        try await personal.install(original, replacing: nil)
        try await work.install(original, replacing: nil)
        try await personal.saveState(["title": .string("Personal draft")], for: original)
        try await work.saveState(["title": .string("Work draft")], for: original)
        let initial = try await personal.load(id: original.id)
        var updated = original; updated.manifest.version += 1
        updated.i18n["en"]?["summary"] = "Updated app"
        try await personal.install(updated, replacing: initial.revision)
        #expect(try await work.load(id: original.id).definition.manifest.version == original.manifest.version)
        #expect(try await personal.loadState(for: updated)["title"] == .string("Personal draft"))
        #expect(try await work.loadState(for: original)["title"] == .string("Work draft"))
        var stale = updated; stale.manifest.version += 1
        await #expect(throws: NativeAppError(.conflict)) { try await personal.install(stale, replacing: initial.revision) }
        var incompatible = stale; incompatible.state["title"]?.persistent = false
        let latest = try await personal.load(id: original.id)
        await #expect(throws: NativeAppError(.incompatibleState)) { try await personal.install(incompatible, replacing: latest.revision) }
        #expect(try await personal.load(id: original.id).definition == updated)
        let restarted = NativeAppStore(directoryURL: personal.directoryURL, space: .personal)
        try await restarted.restore(id: original.id, replacing: latest.revision)
        #expect(try await restarted.load(id: original.id).definition == original)
        #expect(try await restarted.loadState(for: original)["title"] == .string("Personal draft"))
        let restored = try await restarted.load(id: original.id)
        try await restarted.remove(id: original.id, revision: restored.revision)
        #expect(try await restarted.catalog().apps.isEmpty)
        await #expect(throws: NativeAppError.self) { try await restarted.saveState(["title": .string("late")], for: original) }
        #expect(try await work.loadState(for: original)["title"] == .string("Work draft"))
    }

    @Test("Symbolic links cannot redirect app, root or state reads across spaces")
    func symlinksAndCorruption() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let work = NativeAppStore(directoryURL: root.appendingPathComponent("work/apps"), space: .work)
        let note = try NativeAppTemplates.note()
        try await personal.install(note, replacing: nil)
        try FileManager.default.createDirectory(at: work.directoryURL, withIntermediateDirectories: true)
        let personalApp = personal.directoryURL.appendingPathComponent(note.id)
        try FileManager.default.createSymbolicLink(at: work.directoryURL.appendingPathComponent(note.id), withDestinationURL: personalApp)
        await #expect(throws: NativeAppError(.unsafePath)) { _ = try await work.load(id: note.id) }
        #expect(try await work.catalog().invalidIDs == [note.id])
        let linkedRoot = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: personal.directoryURL)
        await #expect(throws: NativeAppError(.unsafePath)) { _ = try await NativeAppStore(directoryURL: linkedRoot, space: .personal).load(id: note.id) }
        let state = personalApp.appendingPathComponent("state.json")
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: personalApp.appendingPathComponent("app.zhiapp.json"))
        await #expect(throws: NativeAppError(.unsafePath)) { _ = try await personal.loadState(for: note) }
        try FileManager.default.removeItem(at: state)
        try Data("broken".utf8).write(to: state)
        await #expect(throws: NativeAppError(.incompatibleState)) { _ = try await personal.loadState(for: note) }
        #expect(try String(contentsOf: state, encoding: .utf8) == "broken")
        let oversized = root.appendingPathComponent("too-big.json")
        try Data(repeating: 32, count: NativeAppDefinition.maximumBytes + 1).write(to: oversized)
        await #expect(throws: NativeAppError(.tooLarge)) { _ = try await NativeAppStore.importDefinition(from: oversized) }
    }

    @Test("Knowledge lists paginate and escape search wildcards; writes require identity-bound approval")
    func resourcesAndCommands() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let knowledge = KnowledgeService(databaseQueue: queue)
        let resources = NativeAppResources(space: .personal, knowledge: knowledge)
        for title in ["100% match", "Other", "Third"] {
            try await knowledge.save(KnowledgeItem(title: title, content: "body"))
        }
        let first = try await resources.queryKnowledge(search: "", offset: 0, limit: 2)
        let second = try await resources.queryKnowledge(search: "", offset: 2, limit: 2)
        #expect(first.items.count == 2 && first.hasMore)
        #expect(second.items.count == 1 && !second.hasMore)
        #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
        #expect(try await resources.queryKnowledge(search: "%", offset: 0, limit: 20).items.map(\.title) == ["100% match"])
        let (engine, call) = try resources.makeSaveCommand(title: "Other", content: "New body")
        guard case .needsConfirmation = try await engine.executeCommand(call) else { Issue.record("Write bypassed confirmation"); return }
        let approvalID = try #require(engine.pendingApprovalID)
        #expect(try await knowledge.getAll().count == 3)
        _ = try await engine.resume(.confirmed(approvalID: UUID(), approved: true, alwaysAllow: false, persistRule: false))
        #expect(try await knowledge.getAll().count == 3)
        guard case .finished(_, _, let trace, _, _, _, _) = try await engine.resume(.confirmed(approvalID: approvalID, approved: true, alwaysAllow: false, persistRule: false)) else {
            Issue.record("A deterministic command requested a model response"); return
        }
        #expect(trace.last?.succeeded == true)
        #expect(try await knowledge.getAll().filter { $0.title == "Other" }.count == 2)
        _ = try await engine.resume(.confirmed(approvalID: approvalID, approved: true, alwaysAllow: false, persistRule: false))
        #expect(try await knowledge.getAll().count == 4)
        let (rejected, rejectedCall) = try resources.makeSaveCommand(title: "Rejected", content: "")
        _ = try await rejected.executeCommand(rejectedCall)
        _ = try await rejected.resume(approved: false)
        #expect(try await knowledge.getAll().count == 4)
    }

    @Test("Direct commands cannot override read-only policy or execute after cancellation")
    func directPolicy() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = KnowledgeService(databaseQueue: queue)
        let tool = KnowledgeSaveTool(service: service)
        let policy = PermissionPolicy(mode: .readOnly, fileAreaPolicy: nil)
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "", permissionPolicy: policy)
        let call = ToolCallRaw(id: UUID().uuidString, name: "knowledge_save", argumentsJSON: #"{"title":"blocked"}"#)
        guard case .finished(_, _, let trace, _, _, _, _) = try await engine.executeCommand(call) else {
            Issue.record("Read-only denial incorrectly offered approval"); return
        }
        #expect(trace.last?.succeeded == false)
        #expect(try await service.getAll().isEmpty)
        let resources = NativeAppResources(space: .work, knowledge: service)
        let (cancelled, pendingCall) = try resources.makeSaveCommand(title: "Cancelled", content: "")
        _ = try await cancelled.executeCommand(pendingCall)
        let id = try #require(cancelled.pendingApprovalID)
        cancelled.revokeTaskAuthorization()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.resume(.confirmed(approvalID: id, approved: true, alwaysAllow: false, persistRule: false))
        }
        #expect(try await service.getAll().isEmpty)
    }

    @MainActor @Test("Preview never writes; suspended windows cannot mutate or retain approval")
    func windowRuntimeIsolation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try NativeAppTemplates.note()
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        try await store.install(note, replacing: nil)
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = KnowledgeService(databaseQueue: queue)
        let resources = NativeAppResources(space: .personal, knowledge: service)
        let cancelled = NativeAppRuntime(definition: note, space: .personal, store: store, resources: resources)
        let activation = Task { @MainActor in
            await Task.yield()
            await cancelled.activate()
        }
        activation.cancel()
        await activation.value
        #expect(!cancelled.isActive && !cancelled.isReady)
        let preview = NativeAppRuntime(definition: note, space: .personal, store: store, resources: resources, preview: true)
        await preview.activate()
        preview.setValue(.string("Preview"), key: "title")
        preview.perform("save")
        #expect(preview.pending == nil && !preview.isDirty)
        #expect(try await store.loadState(for: note).isEmpty)
        #expect(try await service.getAll().isEmpty)
        let model = NativeAppRuntime(definition: note, space: .personal, store: store, resources: resources)
        await model.activate()
        model.setValue(.string("Personal draft"), key: "title")
        model.perform("save")
        for _ in 0..<1000 where model.pending == nil { await Task.yield() }
        let pending = try #require(model.pending)
        model.suspend()
        model.decide(pending, approved: true)
        model.setValue(.string("Wrong space"), key: "title")
        #expect(model.values["title"] == .string("Personal draft"))
        #expect(model.pending == nil && !model.isActive)
        #expect(await model.flush())
        #expect(try await service.getAll().isEmpty)
        let reopened = NativeAppRuntime(definition: note, space: .personal, store: store, resources: resources)
        await reopened.activate()
        #expect(reopened.values["title"] == .string("Personal draft"))
        reopened.suspend(); preview.suspend()
    }

    @MainActor @Test("Native templates render at minimum and default window widths in both appearances")
    func templateRendering() async throws {
        for definition in [try NativeAppTemplates.note(), try NativeAppTemplates.knowledge(), try NativeAppTemplates.textStatistics(), try NativeAppTemplates.calculator(), try NativeAppTemplates.slidingPuzzle()] {
            let model = NativeAppRuntime(definition: definition, space: .personal, preview: true)
            await model.activate()
            if let query = model.queries.values.first, let item = query.items.first { query.select(item.id) }
            for dark in [false, true] {
                for width in [480.0, Double(definition.manifest.width ?? 800)] {
                    let host = NSHostingView(rootView: NativeAppRenderer(model: model)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.close() }
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    // fittingSize is SwiftUI's unconstrained ideal, not its minimum width.
                    // Capture the constrained host so narrow-window layout can be inspected.
                    #expect(host.fittingSize.width.isFinite)
                    #expect(host.fittingSize.height.isFinite)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                    if let directory = ProcessInfo.processInfo.environment["AGROOM_NATIVE_APP_SNAPSHOT_DIR"] {
                        let preview = NSImage(size: host.bounds.size)
                        preview.lockFocus()
                        (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).setFill()
                        host.bounds.fill()
                        if let cg = bitmap.cgImage {
                            NSImage(cgImage: cg, size: host.bounds.size).draw(in: host.bounds, from: .zero, operation: .sourceOver, fraction: 1)
                        }
                        preview.unlockFocus()
                        let tiff = try #require(preview.tiffRepresentation)
                        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                        try png.write(to: URL(fileURLWithPath: directory)
                            .appendingPathComponent("\(definition.id)-\(Int(width))-\(dark ? "dark" : "light").png"))
                    }
                }
            }
            model.suspend()
        }
    }
}
