import Foundation
import AppKit
import SwiftUI
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

/// Explicit opt-in: uses the selected provider and Keychain, with synthetic data and temporary stores.
/// Nothing in this test installs into the user's application catalog or exports credentials.
@Suite("Configured-provider native app flow", .serialized)
struct NativeAppProviderFlowTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_NATIVE_APP_PROVIDER"] == "1"))
    func generationPreviewInstallOpen() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGROOM_APP_FLOW_ARTIFACTS"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("agroom-app-flow-" + UUID().uuidString).path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let globalURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgRoom/global.sqlite")
        var dbConfig = Configuration(); dbConfig.readonly = true
        let global = try DatabaseQueue(path: globalURL.path, configuration: dbConfig)
        let configurations = try await ProviderConfigService(databaseQueue: global).getAll().filter(\.isEnabled)
        let preferred = UserDefaults(suiteName: "com.agroom.app")?.string(forKey: "agroom.chat.providerId")
        let selected = try #require(configurations.first { $0.id.uuidString == preferred } ?? configurations.first,
                                    "No enabled provider is configured")
        let key = KeychainService.loadAPIKey(for: selected.id) ?? ""
        #expect(!key.isEmpty || URL(string: selected.endpoint)?.host == "localhost" || URL(string: selected.endpoint)?.host == "127.0.0.1",
                "The configured provider key is unavailable to this test process")
        guard !key.isEmpty || ["localhost", "127.0.0.1", "::1"].contains(URL(string: selected.endpoint)?.host ?? "") else { return }

        let database = try DatabaseQueue(path: root.appendingPathComponent("personal.sqlite").path)
        try DatabaseBootstrap.prepareSpace(database)
        let usage = UsageService(databaseQueue: database), sessionID = UUID()
        let provider = CloudProvider(config: selected, apiKey: key,
            usageRecorder: ProviderUsageRecorder(service: usage, source: "native-app-flow", sessionID: sessionID))
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let drafts = NativeAppDraftStore(directoryURL: root.appendingPathComponent("personal/app-drafts"), space: .personal)
        let schema = NativeAppSchemaTool(space: .personal, makeStore: { store })
        let prepare = NativeAppPrepareTool(space: .personal, makeStore: { store }, publish: { definition, updating in
            try await drafts.save(definition, sourceSessionID: sessionID, updatingAppID: updating)
        })
        let policy = PermissionPolicy(mode: .readOnly, fileAreaPolicy: nil)
        let engine = DispatcherEngine(provider: provider, tools: [schema, prepare],
            systemPrompt: "You create AgRoom native mini apps through apps_schema and apps_prepare. Read the schema, author the JSON yourself, correct validation errors if needed, and prepare a draft. Never claim installation. After a successful preparation, give a short reply.",
            config: LLMConfig(modelName: selected.model, maxTokens: 8192, temperature: 0.2), maxSteps: 6,
            permissionPolicy: policy, executionContext: ExecutionContext(space: .personal, permissionPolicy: policy))
        let outcome = try await generate(engine, userMessage: "请创建一个名叫‘出行清单’的原生小应用，id 为 flow-check-20261031。可以输入行程标题和多行清单正文，在本应用私有 records 中保存、浏览、选择编辑、新建和删除记录。提供简体中文、繁体中文和英文。使用支持的 DSL 和 apps_prepare 提交可安装预览，不要安装，也不要生成 Swift 工程。")
        guard case .finished(_, _, let trace, _, _, _, _) = outcome else {
            Issue.record("Generation did not finish with a prepared draft"); return
        }
        let pending = try #require(try await drafts.catalog().drafts.first, "The model did not prepare a valid draft")
        #expect(pending.definition.id == "flow-check-20261031")
        #expect(trace.contains { $0.toolName == "apps_schema" })
        #expect(trace.contains { $0.toolName == "apps_prepare" })
        #expect(try await store.catalog().apps.isEmpty)
        try pending.definition.encoded().write(to: root.appendingPathComponent("generated-app.json"), options: .atomic)
        let restored = NativeAppDraftStore(directoryURL: drafts.directoryURL, space: .personal)
        #expect(try await restored.catalog().drafts.first == pending)

        _ = NSApplication.shared
        let preview = NSHostingView(rootView: NativeAppPreview(definition: pending.definition, space: .personal))
        let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 460),
            styleMask: [.titled], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false; previewWindow.contentView = preview
        defer { previewWindow.close() }
        previewWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        try capture(preview, to: root.appendingPathComponent("preview.png"))
        let installer = NativeAppInstallation(definition: pending.definition, store: store)
        await installer.load()
        #expect(installer.ready && installer.error == nil)
        #expect(try await store.catalog().apps.isEmpty) // Loading preview cannot install.
        let installed = try await installer.confirmInstallation() // Explicit synthetic test action.
        try await restored.discard(id: pending.id)
        #expect(try await restored.catalog().drafts.isEmpty)
        let restarted = NativeAppStore(directoryURL: store.directoryURL, space: .personal)
        let reloaded = try await restarted.load(id: installed.definition.id)
        #expect(reloaded.definition == pending.definition)

        let resources = NativeAppResources(space: .personal, knowledge: KnowledgeService(databaseQueue: database))
        let windows = NativeAppWindowCoordinator()
        let window = try windows.open(snapshot: reloaded, space: .personal, store: restarted,
                                      resources: resources, currentSpace: { .personal })
        defer { windows.discard(space: .personal, id: reloaded.definition.id) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.isVisible)
        #expect(window.title.contains(pending.definition.text(pending.definition.manifest.nameKey,
            language: LanguageManager.shared.activeLanguageCode)))
        try capture(try #require(window.contentView), to: root.appendingPathComponent("opened.png"))
        #expect(await windows.saveAll())
        let stats = try await usage.getStats()
        #expect(stats.totalRequests >= 3 && stats.totalTokens > 0)
        let report: [String: Any] = ["model": selected.model, "appID": reloaded.definition.id,
            "generated": true, "draftRestored": true, "previewRendered": true, "installed": true,
            "opened": window.isVisible, "requests": stats.totalRequests, "inputTokens": stats.totalInputTokens,
            "outputTokens": stats.totalOutputTokens, "missingUsageRequests": stats.unreportedRequests]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("flow-report.json"), options: .atomic)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_NATIVE_APP_DEFINITION"] != nil))
    func generatedDefinitionInteractions() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["AGROOM_TEST_NATIVE_APP_DEFINITION"])
        let definition = try NativeAppDefinition.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let installer = NativeAppInstallation(definition: definition, store: store)
        await installer.load()
        #expect(try await store.catalog().apps.isEmpty)
        let installed = try await installer.confirmInstallation()
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let resources = NativeAppResources(space: .personal, knowledge: KnowledgeService(databaseQueue: queue))
        let save = try #require(definition.actions.first { $0.value.type == .saveRecord })
        let source = try #require(save.value.source)
        let titleKey = try #require(save.value.values?["title"]?.state)
        let bodyKey = try #require(save.value.values?["content"]?.state)
        let collection = try #require(definition.dataSources[source]).collection ?? source
        let runtime = NativeAppRuntime(definition: definition, space: .personal, store: store, resources: resources)
        await runtime.activate()
        #expect(runtime.isReady && runtime.error == nil)
        let workspace = try #require(runtime.workspace)
        runtime.setValue(.string("上海出差"), key: titleKey)
        runtime.setValue(.string("☐ 机票与酒店\n☐ 身份证\n☐ 电脑和充电器"), key: bodyKey)
        runtime.perform(save.key)
        try await waitUntil { runtime.pending != nil || runtime.error != nil }
        let denied = try #require(runtime.pending)
        #expect(try await workspace.records(collection: collection).isEmpty)
        runtime.decide(denied, approved: false)
        try await waitUntil { !runtime.isBusy }
        #expect(try await workspace.records(collection: collection).isEmpty)
        runtime.perform(save.key)
        try await waitUntil { runtime.pending != nil || runtime.error != nil }
        runtime.decide(try #require(runtime.pending), approved: true)
        try await waitUntil { !runtime.isBusy }
        let first = try #require(try await workspace.records(collection: collection).first)
        #expect(first.title == "上海出差" && first.revision == 1)
        #expect(await runtime.flush())
        runtime.suspend()

        let reopened = NativeAppRuntime(definition: definition, space: .personal, store: store, resources: resources)
        await reopened.activate()
        #expect(reopened.error == nil && reopened.values[titleKey] == .string(first.title))
        #expect(reopened.editors[source]?.id == first.id)
        reopened.setValue(.string(first.content + "\n☐ 行程单"), key: bodyKey)
        reopened.perform(save.key)
        try await waitUntil { reopened.pending != nil || reopened.error != nil }
        reopened.decide(try #require(reopened.pending), approved: true)
        try await waitUntil { !reopened.isBusy }
        let updated = try await workspace.records(collection: collection)
        #expect(updated.count == 1 && updated.first?.id == first.id && updated.first?.revision == 2)
        #expect(updated.first?.content.hasSuffix("☐ 行程单") == true)
        #expect(await reopened.flush())
        reopened.suspend()

        _ = NSApplication.shared
        let preview = NSHostingView(rootView: NativeAppPreview(definition: definition, space: .personal))
        let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false; previewWindow.appearance = NSAppearance(named: .aqua)
        previewWindow.contentView = preview; previewWindow.makeKeyAndOrderFront(nil)
        defer { previewWindow.close() }
        try await Task.sleep(for: .milliseconds(150))
        try capture(preview, to: root.appendingPathComponent("preview.png"))
        let windows = NativeAppWindowCoordinator()
        let window = try windows.open(snapshot: installed, space: .personal, store: store,
                                      resources: resources, currentSpace: { .personal })
        window.appearance = NSAppearance(named: .aqua)
        defer { windows.discard(space: .personal, id: definition.id) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.isVisible)
        try capture(try #require(window.contentView), to: root.appendingPathComponent("opened.png"))
        #expect(await windows.saveAll())
        windows.discard(space: .personal, id: definition.id)

        let deleting = NativeAppRuntime(definition: definition, space: .personal, store: store, resources: resources)
        await deleting.activate()
        let query = try #require(deleting.queries[source])
        try await waitUntil { !query.items.isEmpty || query.error != nil }
        query.select(first.id)
        try await waitUntil { query.selectedRecord != nil || query.error != nil }
        let delete = try #require(definition.actions.first { $0.value.type == .deleteRecord && $0.value.source == source })
        deleting.perform(delete.key)
        try await waitUntil { deleting.pending != nil || deleting.error != nil }
        let confirmation = try #require(deleting.pending)
        #expect(try await workspace.records(collection: collection).count == 1)
        deleting.decide(confirmation, approved: true)
        try await waitUntil { !deleting.isBusy }
        #expect(try await workspace.records(collection: collection).isEmpty)
        #expect(await deleting.flush())
        deleting.suspend()
        let report: [String: Any] = ["appID": definition.id, "previewRendered": true, "opened": true,
            "saveRequiresApproval": true, "deniedSavePreservedData": true, "saved": true,
            "reopenedDraft": true, "editUpdatedSameRecord": true, "deleteRequiresApproval": true, "deleted": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("runtime-report.json"), options: .atomic)
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Native app interaction did not reach the expected state")
        throw CancellationError()
    }

    private struct GenerationTimedOut: Error {}

    /// Human Keychain authorization is setup; only the model loop consumes this timeout.
    private func generate(_ engine: DispatcherEngine, userMessage: String) async throws -> DispatcherOutcome {
        try await withThrowingTaskGroup(of: DispatcherOutcome.self) { group in
            group.addTask { try await engine.run(userMessage: userMessage, history: []) }
            group.addTask {
                try await Task.sleep(for: .seconds(600))
                throw GenerationTimedOut()
            }
            defer { group.cancelAll() }
            guard let outcome = try await group.next() else { throw CancellationError() }
            return outcome
        }
    }

    @MainActor private func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Hosting views are transparent; composite the actual window background so black text
        // remains visible when a PNG viewer displays transparency against a dark canvas.
        let rendered = NSImage(size: view.bounds.size)
        rendered.lockFocus()
        (view.window?.backgroundColor ?? NSColor.windowBackgroundColor).setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        if let cg = bitmap.cgImage {
            NSImage(cgImage: cg, size: view.bounds.size).draw(in: NSRect(origin: .zero, size: view.bounds.size))
        }
        rendered.unlockFocus()
        let tiff = try #require(rendered.tiffRepresentation)
        let image = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try image.write(to: url, options: .atomic)
    }
}
