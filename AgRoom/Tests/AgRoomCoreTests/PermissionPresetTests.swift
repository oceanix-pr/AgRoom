import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Permission presets")
struct PermissionPresetTests {
    @Test("Auto stays confined, custom is display-only, and defaults never enable Auto")
    func catalogBoundaries() throws {
        #expect(!PermissionPreset.defaultOptions.contains(.autoReview))
        #expect(!PermissionPreset.sessionOptions.contains(.custom))
        #expect(PermissionPreset.custom.configuration == nil)
        for preset in PermissionPreset.defaultOptions {
            #expect(preset.configuration?.autoReviewEnabled == false)
        }
        let auto = try #require(PermissionPreset.autoReview.configuration)
        #expect(auto.mode == .workspaceWrite && auto.autoReviewEnabled)
        let policy = PermissionPolicy(mode: auto.mode, fileAreaPolicy: nil)
        guard case .deny = policy.assess(toolName: "project_build", permissionClass: .codeExecution,
                                        argumentsJSON: "{}", skillWorkspace: nil) else {
            Issue.record("Selecting Auto must not grant host execution")
            return
        }
        for mode in [PermissionMode.readOnly, .dangerFullAccess] {
            let legacy = PermissionConfiguration(mode: mode, autoReviewEnabled: true)
            #expect(legacy.preset == .custom)
            #expect(legacy.mode == mode && legacy.autoReviewEnabled)
        }
        #expect(PermissionPreset.autoReview.requiresAcknowledgement)
        #expect(PermissionPreset.extendedAccess.requiresAcknowledgement)
    }

    @Test("The pair survives reopening without changing messages or the same session in another space")
    func persistenceAndIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("permission-preset-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = try DatabaseQueue(path: root.appendingPathComponent("work.sqlite").path)
        let personal = try DatabaseQueue(path: root.appendingPathComponent("personal.sqlite").path)
        try DatabaseBootstrap.prepareSpace(work)
        try DatabaseBootstrap.prepareSpace(personal)
        let workService = SessionService(databaseQueue: work)
        let personalService = SessionService(databaseQueue: personal)
        var session = ChatSession(title: "Keep history", permissionMode: .dangerFullAccess)
        session.messages = [ChatMessage(role: .user, content: "Existing message")]
        try await workService.save(session)
        try await personalService.save(session)
        try await workService.setPermissionConfiguration(id: session.id,
            configuration: try #require(PermissionPreset.autoReview.configuration))
        let reopened = try DatabaseQueue(path: root.appendingPathComponent("work.sqlite").path)
        let restored = try #require(try await SessionService(databaseQueue: reopened).getSummaries().first)
        #expect(restored.permissionMode == .workspaceWrite && restored.autoReviewEnabled)
        #expect(restored.title == session.title)
        let messages = try await workService.getMessagesDetailed(id: session.id)
        #expect(messages.messages.map(\.content) == ["Existing message"])
        let other = try #require(try await personalService.getSummaries().first)
        #expect(other.permissionMode == .dangerFullAccess && !other.autoReviewEnabled)
    }

    @Test("An aborted database write cannot commit only one knob")
    func failedTransaction() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = SessionService(databaseQueue: queue)
        let session = ChatSession(title: "Before", permissionMode: .readOnly)
        try await service.save(session)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_permission AFTER UPDATE OF permissionMode ON chat_sessions
                BEGIN SELECT RAISE(ABORT, 'preset write fixture'); END
                """)
        }
        do {
            try await service.setPermissionConfiguration(id: session.id,
                configuration: try #require(PermissionPreset.autoReview.configuration))
            Issue.record("Injected write failure must be reported")
        } catch {}
        let saved = try #require(try await service.getSummaries().first)
        #expect(saved.permissionMode == .readOnly && !saved.autoReviewEnabled)
        #expect(saved.title == "Before")
    }

    @Test("Restoring a conversation revokes stale preset writes")
    func staleAfterRestore() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = SessionService(databaseQueue: queue)
        let session = ChatSession(permissionMode: .readOnly)
        try await service.save(session)
        try await service.invalidateRestoredSnapshots(ids: [session.id])
        let configuration = try #require(PermissionPreset.extendedAccess.configuration)
        do {
            try await service.setPermissionConfiguration(id: session.id, configuration: configuration)
            Issue.record("A stale selector must not modify restored permissions")
        } catch {
            #expect(error as? SessionServiceError == .staleAfterRestore)
        }
        let refreshed = try #require(try await service.getSummaries().first)
        #expect(refreshed.permissionMode == .readOnly && !refreshed.autoReviewEnabled)
        try await service.setPermissionConfiguration(id: session.id, configuration: configuration,
                                                    restorationToken: refreshed.restorationToken)
        #expect(try await service.getSummaries().first?.permissionMode == .dangerFullAccess)
    }
}

@Suite("Permission preset host", .serialized)
@MainActor
struct PermissionPresetHostTests {
    private func fixture(_ root: URL, queue: DatabaseQueue) -> ChatViewModel {
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: root.appendingPathComponent("files")))
        return ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil,
                             makeEngine: { _ in throw TaskArtifactError.unavailable })
    }

    @Test("The host publishes committed pairs, blocks overlapping switches and sends, and uses fresh defaults")
    func committedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("permission-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = SessionService(databaseQueue: queue)
        let session = ChatSession(title: "Session", permissionMode: .dangerFullAccess)
        try await service.save(session)
        let model = fixture(root, queue: queue)
        model.sessions = [session]
        model.activeSessionId = session.id
        let task = try #require(model.setPermissionPreset(.autoReview, forSession: session.id))
        #expect(model.isSavingPermission(forSession: session.id))
        #expect(model.permissionConfiguration(forSession: session.id).preset == .extendedAccess)
        #expect(!model.canSwitchMode(forSession: session.id))
        #expect(model.setPermissionPreset(.readOnly, forSession: session.id) == nil)
        model.inputText = "Preserve this draft while saving"
        model.send()
        #expect(model.sessions[0].messages.isEmpty && !model.inputText.isEmpty)
        await task.value
        #expect(!model.isSavingPermission(forSession: session.id))
        #expect(model.permissionConfiguration(forSession: session.id).preset == .autoReview)
        let saved = try #require(try await service.getSummaries().first)
        #expect(saved.permissionMode == .workspaceWrite && saved.autoReviewEnabled)
        #expect(model.setPermissionPreset(.autoReview, forSession: session.id) == nil)
        #expect(model.setPermissionPreset(.custom, forSession: session.id) == nil)
        model.newSession()
        #expect(!model.autoReviewEnabled(forSession: model.activeSessionId))
        #expect(model.permissionMode(forSession: model.activeSessionId) == DispatcherSettings.defaultPermissionMode)
        #expect(model.permissionConfiguration(forSession: session.id).preset == .autoReview)
    }

    @Test("Save failure keeps the entire legacy configuration active and unlocks the selector")
    func failedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("permission-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = SessionService(databaseQueue: queue)
        let session = ChatSession(title: "Legacy", autoReviewEnabled: true, permissionMode: .dangerFullAccess)
        try await service.save(session)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_permission BEFORE UPDATE OF permissionMode ON chat_sessions
                BEGIN SELECT RAISE(ABORT, 'preset write fixture'); END
                """)
        }
        let model = fixture(root, queue: queue)
        model.sessions = [session]
        let task = try #require(model.setPermissionPreset(.readOnly, forSession: session.id))
        await task.value
        #expect(model.permissionConfiguration(forSession: session.id) ==
            PermissionConfiguration(mode: .dangerFullAccess, autoReviewEnabled: true))
        #expect(model.errorMessage != nil && model.canSwitchMode(forSession: session.id))
        let saved = try #require(try await service.getSummaries().first)
        #expect(saved.permissionMode == .dangerFullAccess && saved.autoReviewEnabled)
    }

    @Test("Permission menus and acknowledgement sheets render in three languages and both appearances",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_PERMISSION_SNAPSHOT_DIR"] != nil))
    func rendering() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_PERMISSION_SNAPSHOT_DIR"]))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for dark in [false, true] {
                try await snapshot(PermissionPopover(selected: .autoReview, onSelect: { _ in }, onOpenPermissions: {}),
                    width: 292, height: 260, path: directory.appendingPathComponent("menu-\(language.rawValue)-\(dark).png"), dark: dark)
                for preset in [PermissionPreset.autoReview, .extendedAccess] {
                    try await snapshot(PermissionPresetConfirmation(preset: preset, onConfirm: {}, onCancel: {}),
                        width: 470, height: 370,
                        path: directory.appendingPathComponent("confirm-\(preset.rawValue)-\(language.rawValue)-\(dark).png"), dark: dark)
                }
            }
        }
    }

    private func snapshot<V: View>(_ view: V, width: CGFloat, height: CGFloat, path: URL, dark: Bool) async throws {
        let host = NSHostingView(rootView: view.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}
