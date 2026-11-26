import Foundation
import Testing
import GRDB
import AppKit
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Explicit app installation", .serialized)
struct NativeAppInstallationTests {
    @MainActor @Test("App host labels resolve from the runtime bundle, including under the SwiftPM test helper")
    func runtimeLocalization() {
        for key in ["apps.record.editing", "apps.files.title", "apps.preview.sample.title",
                    "apps.preview.sample.body", "apps.drafts.title", "jobs.history.failed"] {
            #expect(L.string(key) != key)
        }
    }

    @MainActor @Test("Preview keeps the catalog empty; explicit installation opens and reuses a native window")
    func installAndOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = try NativeAppTemplates.note()
        let store = NativeAppStore(directoryURL: root, space: .personal)
        let model = NativeAppInstallation(definition: definition, store: store)
        await model.load()
        #expect(model.ready && model.error == nil)
        #expect(try await store.catalog().apps.isEmpty)
        let snapshot = try await model.confirmInstallation()
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let resources = NativeAppResources(space: .personal, knowledge: KnowledgeService(databaseQueue: queue))
        _ = NSApplication.shared
        let coordinator = NativeAppWindowCoordinator()
        let window = try coordinator.open(snapshot: snapshot, space: .personal, store: store,
                                          resources: resources, currentSpace: { .personal })
        defer { coordinator.discard(space: .personal, id: definition.id) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.isVisible && window.contentView != nil)
        #expect(try coordinator.open(snapshot: snapshot, space: .personal, store: store,
                                     resources: resources, currentSpace: { .personal }) === window)
        #expect(throws: NativeAppError.self) {
            try coordinator.open(snapshot: snapshot, space: .personal, store: store,
                                 resources: resources, currentSpace: { .work })
        }
        #expect(await coordinator.saveAll())
    }

    @MainActor @Test("Installing after another publisher changed the catalog fails and preserves its definition")
    func concurrentInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root, space: .work)
        let original = try NativeAppTemplates.note()
        let preview = NativeAppInstallation(definition: original, store: store)
        await preview.load()
        var other = original; other.manifest.version += 1
        try await store.install(other, replacing: nil)
        await #expect(throws: NativeAppError.self) { try await preview.confirmInstallation() }
        #expect(preview.error != nil)
        #expect(try await store.load(id: original.id).definition == other)
    }
}
