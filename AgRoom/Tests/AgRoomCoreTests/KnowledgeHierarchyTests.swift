import Foundation
import GRDB
import Testing
import Observation
import Synchronization
@testable import AgRoomCore
@testable import AgRoomUI

private struct HierarchyTestEmbedder: KnowledgeEmbeddingProvider {
    let indexIdentity = "hierarchy-fixture-v1"
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        texts.map { _ in [1] + Array(repeating: Float(0), count: 1023) }
    }
}

private final class KnowledgeNavigationDefaults: UserDefaults, @unchecked Sendable {
    let writeCount = Mutex(0)

    override func set(_ value: Any?, forKey defaultName: String) {
        writeCount.withLock { $0 += 1 }
        super.set(value, forKey: defaultName)
    }
}

@Suite("Knowledge hierarchy")
struct KnowledgeHierarchyTests {
    private func database(path: String? = nil) throws -> DatabaseQueue {
        let queue = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return queue
    }

    @MainActor @Test("Restoring saved knowledge navigation never writes defaults during view construction")
    func navigationRestorationDoesNotWrite() throws {
        let suite = "knowledge-read-only-restore-\(UUID())"
        let preferences = try #require(KnowledgeNavigationDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let initial = KnowledgeBrowserModel(service: nil, space: .work, preferences: preferences)
        initial.selection = .unfiled
        initial.includeDescendants = false
        let expanded = KnowledgeNodeID.base(UUID())
        initial.toggle(expanded)
        preferences.writeCount.withLock { $0 = 0 }

        for _ in 0..<10 {
            let restored = KnowledgeBrowserModel(service: nil, space: .work, preferences: preferences)
            #expect(restored.selection == .unfiled)
            #expect(!restored.includeDescendants)
            #expect(restored.expanded == [expanded])
        }
        #expect(preferences.writeCount.withLock { $0 } == 0)
    }

    @MainActor @Test("Constructing knowledge services from a healthy space does not invalidate the navigation view")
    func healthyServiceLookupDoesNotPublish() async throws {
        let queue = try database()
        let global = try DatabaseQueue()
        let store = SpaceStore(current: .work) { file in .success(.init(queue: file == AppSpace.work.databaseFileName ? queue : global, cipher: .plaintext)) }
        _ = await store.prepare(.work)
        let notified = Mutex(false)
        withObservationTracking {
            _ = store.databaseIssue
        } onChange: {
            notified.withLock { $0 = true }
        }
        for _ in 0..<10 { #expect(store.queue(for: .work) === queue) }
        #expect(!notified.withLock { $0 })

        store.setIssueForTesting(.init(fileName: "work.sqlite", path: "/fixture/work.sqlite", reason: "Temporary failure"), for: .work)
        notified.withLock { $0 = false }
        withObservationTracking { _ = store.databaseIssue } onChange: { notified.withLock { $0 = true } }
        #expect(store.queue(for: .work) == nil)
        #expect(!notified.withLock { $0 })
        _ = await store.retryCurrentDatabase()
        #expect(notified.withLock { $0 })
        #expect(store.databaseIssue == nil)
    }

    @MainActor @Test("Knowledge startup failures and cancellation leave a retryable page instead of a stuck spinner")
    func browserStartupRecovery() async throws {
        let suite = "knowledge-startup-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var availableService: KnowledgeService?
        let model = KnowledgeBrowserModel(space: .work, preferences: preferences, makeService: { availableService })
        await model.reload()
        #expect(!model.isLoading && model.loadFailed)
        availableService = KnowledgeService(databaseQueue: try database())
        model.errorMessage = nil
        await model.reload()
        #expect(!model.isLoading && !model.loadFailed)
        #expect(model.revision == 1)
        let cancelled = Task { await model.reload() }
        cancelled.cancel()
        await cancelled.value
        #expect(!model.isLoading)
    }

    @Test("Knowledge JSON without ordering remains readable")
    func legacyModelDecoding() throws {
        let base = KnowledgeBase(name: "Base")
        let folder = KnowledgeFolder(baseId: base.id, name: "Folder")
        let item = KnowledgeItem(title: "Entry", baseId: base.id, folderId: folder.id)
        func withoutOrder<T: Codable>(_ value: T) throws -> T {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            object.removeValue(forKey: "sortOrder")
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(try withoutOrder(base).sortOrder == 0)
        #expect(try withoutOrder(folder).parentId == nil)
        #expect(try withoutOrder(item).folderId == folder.id)
    }

    @Test("An already migrated knowledge database gains ordering without losing its original hierarchy or body")
    func legacyMigration() async throws {
        let queue = try DatabaseQueue()
        let base = UUID(), folder = UUID(), item = UUID()
        try await queue.write { db in
            try KnowledgeService.createSchema(db)
            try KnowledgeRetrievalService.createSchema(db)
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1_knowledge'), ('v2_knowledge_embeddings')")
            try db.execute(sql: "INSERT INTO knowledge_bases VALUES (?, 'Legacy', ?, ?)", arguments: [base.uuidString, Date(), Date()])
            try db.execute(sql: "INSERT INTO knowledge_folders VALUES (?, ?, NULL, 'Folder', ?, ?)", arguments: [folder.uuidString, base.uuidString, Date(), Date()])
            try db.execute(sql: """
                INSERT INTO knowledge_items (id,title,content,baseId,folderId,createdAt,updatedAt)
                VALUES (?, 'Original', 'Original body', ?, ?, ?, ?)
                """, arguments: [item.uuidString, base.uuidString, folder.uuidString, Date(), Date()])
        }
        try DatabaseBootstrap.prepareSpace(queue)
        try DatabaseBootstrap.prepareSpace(queue)
        let service = KnowledgeService(databaseQueue: queue)
        let snapshot = try await service.browserSnapshot()
        #expect(snapshot.bases.first?.sortOrder == 0)
        #expect(snapshot.folders.first?.id == folder)
        #expect(snapshot.items.first?.folderId == folder)
        #expect(try await service.get(id: item)?.content == "Original body")
        let migrationCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v3_knowledge_hierarchy'")
        }
        #expect(migrationCount == 1)
    }

    @Test("Folder writes reject missing and foreign parents and cycles; entry placement must match its base")
    func placementValidation() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        let first = KnowledgeBase(name: "First"), second = KnowledgeBase(name: "Second")
        try await service.saveBase(first); try await service.saveBase(second)
        let parent = KnowledgeFolder(baseId: first.id, name: "Parent")
        try await service.saveFolder(parent)
        let child = KnowledgeFolder(baseId: first.id, parentId: parent.id, name: "Child")
        try await service.saveFolder(child)
        await #expect(throws: KnowledgeOrganizationError.invalidParent) {
            try await service.saveFolder(KnowledgeFolder(baseId: second.id, parentId: parent.id, name: "Invalid"))
        }
        await #expect(throws: KnowledgeOrganizationError.folderMissing) {
            try await service.saveFolder(KnowledgeFolder(baseId: first.id, parentId: UUID(), name: "Invalid"))
        }
        var cyclic = parent; cyclic.parentId = child.id
        let candidate = cyclic
        await #expect(throws: KnowledgeOrganizationError.cycle) { try await service.saveFolder(candidate) }
        await #expect(throws: KnowledgeOrganizationError.cycle) {
            try await service.move(.folder(parent.id), toBase: first.id, folder: child.id)
        }
        await #expect(throws: KnowledgeOrganizationError.invalidParent) {
            try await service.save(KnowledgeItem(title: "Invalid", baseId: second.id, folderId: child.id))
        }
        #expect(try await service.browserSnapshot().foldersByID[parent.id]?.parentId == nil)
    }

    @Test("Cross-base subtree moves are atomic, preserve IDs and bodies, and do not invalidate unchanged vectors")
    func subtreeMove() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        let first = KnowledgeBase(name: "First"), second = KnowledgeBase(name: "Second")
        try await service.saveBase(first); try await service.saveBase(second)
        let parent = KnowledgeFolder(baseId: first.id, name: "Parent")
        let child = KnowledgeFolder(baseId: first.id, parentId: parent.id, name: "Child")
        try await service.saveFolder(parent); try await service.saveFolder(child)
        let item = KnowledgeItem(title: "Entry", content: "Original body", baseId: first.id, folderId: child.id)
        try await service.save(item)
        let index = KnowledgeRetrievalService(service: service, provider: HierarchyTestEmbedder())
        try await index.synchronize()
        try await service.move(.folder(parent.id), toBase: second.id, folder: nil)
        let snapshot = try await service.browserSnapshot()
        #expect(snapshot.foldersByID[parent.id]?.baseId == second.id)
        #expect(snapshot.foldersByID[child.id]?.baseId == second.id)
        #expect(snapshot.itemsByID[item.id]?.baseId == second.id)
        #expect(snapshot.itemsByID[item.id]?.folderId == child.id)
        #expect(try snapshot.scopedItems(.base(first.id)).isEmpty)
        #expect(try snapshot.scopedItems(.folder(parent.id, includeDescendants: true)).map(\.id) == [item.id])
        #expect(try snapshot.scopedItems(.folder(parent.id, includeDescendants: false)).isEmpty)
        #expect(try await service.get(id: item.id)?.content == item.content)
        #expect(try await index.indexStatus().indexed == 1)
    }

    @Test("Removing a folder can promote its contents; a conflicting promotion rolls back earlier changes")
    func promotionAndRollback() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        let base = KnowledgeBase(name: "Base")
        try await service.saveBase(base)
        let parent = KnowledgeFolder(baseId: base.id, name: "Parent")
        try await service.saveFolder(parent)
        let first = KnowledgeFolder(baseId: base.id, parentId: parent.id, name: "A")
        let second = KnowledgeFolder(baseId: base.id, parentId: parent.id, name: "Conflict")
        try await service.saveFolder(first); try await service.saveFolder(second)
        let conflict = KnowledgeFolder(baseId: base.id, name: "Conflict")
        try await service.saveFolder(conflict)
        let item = KnowledgeItem(title: "Entry", content: "Body", baseId: base.id, folderId: parent.id)
        try await service.save(item)
        await #expect(throws: KnowledgeOrganizationError.duplicateFolder) {
            try await service.deleteFolder(id: parent.id, keepingContents: true)
        }
        let failed = try await service.browserSnapshot()
        #expect(failed.foldersByID[first.id]?.parentId == parent.id)
        #expect(failed.itemsByID[item.id]?.folderId == parent.id)
        try await service.deleteFolder(id: conflict.id)
        try await service.deleteFolder(id: parent.id, keepingContents: true)
        let promoted = try await service.browserSnapshot()
        #expect(promoted.foldersByID[parent.id] == nil)
        #expect(promoted.foldersByID[first.id]?.parentId == nil)
        #expect(promoted.foldersByID[second.id]?.parentId == nil)
        #expect(promoted.itemsByID[item.id]?.folderId == nil)
        #expect(try await service.get(id: item.id)?.content == "Body")
    }

    @Test("Folder deletion cleans descendants and derived indexes without touching identical IDs in another space")
    func cascadeIsolation() async throws {
        let first = KnowledgeService(databaseQueue: try database()), second = KnowledgeService(databaseQueue: try database())
        let base = KnowledgeBase(name: "Base")
        let parent = KnowledgeFolder(baseId: base.id, name: "Parent")
        let child = KnowledgeFolder(baseId: base.id, parentId: parent.id, name: "Child")
        let item = KnowledgeItem(title: "Entry", content: "Body", baseId: base.id, folderId: child.id)
        for service in [first, second] {
            try await service.saveBase(base); try await service.saveFolder(parent)
            try await service.saveFolder(child); try await service.save(item)
        }
        let index = KnowledgeRetrievalService(service: first, provider: HierarchyTestEmbedder())
        try await index.synchronize()
        try await first.deleteFolder(id: parent.id)
        #expect(try await first.browserSnapshot().folders.isEmpty)
        #expect(try await first.get(id: item.id) == nil)
        #expect(try await index.indexStatus().indexed == 0)
        #expect(try await second.get(id: item.id)?.content == "Body")
        #expect(try await second.browserSnapshot().folders.count == 2)
    }

    @Test("Order persists across reopening and content edits do not undo a move or revive a deleted entry")
    func persistenceAndStaleEditor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-hierarchy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("space.sqlite").path
        let base = KnowledgeBase(name: "Base")
        let a = KnowledgeFolder(baseId: base.id, name: "A"), b = KnowledgeFolder(baseId: base.id, name: "B")
        let item = KnowledgeItem(title: "Entry", content: "Before", baseId: base.id, folderId: a.id)
        do {
            let service = KnowledgeService(databaseQueue: try database(path: path))
            try await service.saveBase(base); try await service.saveFolder(a); try await service.saveFolder(b)
            try await service.save(item)
            try await service.reorder(.folder(b.id), earlier: true)
            try await service.move(.item(item.id), toBase: base.id, folder: b.id)
            var edited = item; edited.content = "After"
            try await service.updateContent(edited)
        }
        let service = KnowledgeService(databaseQueue: try database(path: path))
        #expect(try await service.getFolders(baseId: base.id).map(\.id) == [b.id, a.id])
        #expect(try await service.get(id: item.id)?.folderId == b.id)
        #expect(try await service.get(id: item.id)?.content == "After")
        try await service.delete(id: item.id)
        await #expect(throws: KnowledgeOrganizationError.itemMissing) { try await service.updateContent(item) }
        #expect(try await service.get(id: item.id) == nil)
    }

    @Test("Keyword and semantic retrieval respect recursive scope and reject unknown scope instead of widening it")
    func scopedRetrieval() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        let base = KnowledgeBase(name: "Base")
        try await service.saveBase(base)
        let parent = KnowledgeFolder(baseId: base.id, name: "Parent")
        let child = KnowledgeFolder(baseId: base.id, parentId: parent.id, name: "Child")
        try await service.saveFolder(parent); try await service.saveFolder(child)
        let inside = KnowledgeItem(title: "Shared topic", content: "Stored knowledge", baseId: base.id, folderId: child.id)
        let outside = KnowledgeItem(title: "Shared topic", content: "Other knowledge", baseId: base.id)
        try await service.save(inside); try await service.save(outside)
        let lexical = KnowledgeRetrievalService(service: service)
        let scope = KnowledgeSearchScope.folder(parent.id, includeDescendants: true)
        #expect(try await lexical.search(query: "Shared", scope: scope).passages.map(\.itemID) == [inside.id])
        #expect(try await lexical.search(query: "Shared", scope: .folder(parent.id, includeDescendants: false)).passages.isEmpty)
        let semantic = KnowledgeRetrievalService(service: service, provider: HierarchyTestEmbedder())
        try await semantic.synchronize()
        #expect(try await semantic.search(query: "synonym", scope: scope).passages.map(\.itemID) == [inside.id])
        await #expect(throws: KnowledgeOrganizationError.folderMissing) {
            try await semantic.search(query: "Shared", scope: .folder(UUID(), includeDescendants: true))
        }
        let tool = KnowledgeSearchTool(service: service)
        await #expect(throws: LLMError.self) {
            try await tool.execute(argumentsJSON: #"{"query":"Shared","folder_id":"invalid"}"#)
        }
    }

    @Test("Knowledge tools expose directory IDs, disambiguate identical titles and clear foreign folder membership")
    func toolOrganization() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        let first = KnowledgeBase(name: "First"), second = KnowledgeBase(name: "Second")
        try await service.saveBase(first); try await service.saveBase(second)
        let folder = KnowledgeFolder(baseId: first.id, name: "Folder")
        try await service.saveFolder(folder)
        let a = KnowledgeItem(title: "Same", content: "First body", baseId: first.id, folderId: folder.id)
        let b = KnowledgeItem(title: "Same", content: "Second body", baseId: second.id)
        try await service.save(a); try await service.save(b)
        let save = KnowledgeSaveTool(service: service)
        _ = try await save.execute(argumentsJSON: #"{"title":"Same","content":"Edited second","base":"Second"}"#)
        #expect(try await service.get(id: a.id)?.content == "First body")
        #expect(try await service.get(id: b.id)?.content == "Edited second")
        await #expect(throws: LLMError.self) {
            try await save.execute(argumentsJSON: #"{"title":"Same","content":"Ambiguous"}"#)
        }
        let list = KnowledgeListTool(service: service)
        let listing = try await list.execute(argumentsJSON: "{\"folder_id\":\"\(folder.id)\"}")
        #expect(listing.contains("First / Folder"))
        #expect(listing.contains(a.id.uuidString))
        #expect(!listing.contains(b.id.uuidString))
        let catalog = try await list.execute(argumentsJSON: "{}")
        #expect(catalog.contains("folder_id: \(folder.id)"))
        _ = try await save.execute(argumentsJSON: "{\"id\":\"\(a.id)\",\"title\":\"Moved\",\"base\":\"Second\"}")
        #expect(try await service.get(id: a.id)?.baseId == second.id)
        #expect(try await service.get(id: a.id)?.folderId == nil)
        #expect(save.requiresConfirmation)
    }

    @Test("Legacy cyclic and orphaned parents remain browsable without changing original data")
    func corruptTreeProjection() async throws {
        let queue = try database(), service = KnowledgeService(databaseQueue: queue)
        let base = KnowledgeBase(name: "Base")
        try await service.saveBase(base)
        let a = KnowledgeFolder(baseId: base.id, name: "A"), b = KnowledgeFolder(baseId: base.id, name: "B")
        let orphan = KnowledgeFolder(baseId: base.id, name: "Orphan")
        for folder in [a, b, orphan] { try await service.saveFolder(folder) }
        try await queue.write { db in
            try db.execute(sql: "UPDATE knowledge_folders SET parentId = ? WHERE id = ?", arguments: [b.id.uuidString, a.id.uuidString])
            try db.execute(sql: "UPDATE knowledge_folders SET parentId = ? WHERE id = ?", arguments: [a.id.uuidString, b.id.uuidString])
            try db.execute(sql: "UPDATE knowledge_folders SET parentId = ? WHERE id = ?", arguments: [UUID().uuidString, orphan.id.uuidString])
        }
        let snapshot = try await service.browserSnapshot()
        #expect(snapshot.childFolders(baseID: base.id, parentID: nil).count == 2)
        #expect(snapshot.ancestors(of: a.id).count <= 2)
        #expect(snapshot.ancestors(of: b.id).count <= 2)
        #expect(snapshot.foldersByID[orphan.id]?.parentId != nil)
        #expect(snapshot.parents[orphan.id] == nil)
    }

    @Test("Tree navigation restores per-space state, aggregates children, and shows newly unfiled entries")
    @MainActor func browserNavigation() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        let suite = "knowledge-navigation-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = KnowledgeBase(name: "Base")
        let parent = KnowledgeFolder(baseId: base.id, name: "Parent")
        let child = KnowledgeFolder(baseId: base.id, parentId: parent.id, name: "Child")
        let item = KnowledgeItem(title: "Entry", content: "Body", baseId: base.id, folderId: child.id)
        try await service.saveBase(base); try await service.saveFolder(parent); try await service.saveFolder(child)
        try await service.save(item)
        let model = KnowledgeBrowserModel(service: service, space: .work, preferences: defaults)
        await model.reload()
        model.selection = .folder(parent.id)
        #expect(model.scopedItems.map(\.id) == [item.id])
        model.includeDescendants = false
        #expect(model.scopedItems.isEmpty)
        model.selection = .item(item.id)
        #expect(model.visibleRows.contains { $0.selection == .item(item.id) })
        await model.loadSelectedItem()
        #expect(model.selectedItem?.content == "Body")
        let restored = KnowledgeBrowserModel(service: service, space: .work, preferences: defaults)
        await restored.reload()
        #expect(restored.selection == .item(item.id))
        #expect(restored.includeDescendants == false)
        let personal = KnowledgeBrowserModel(service: KnowledgeService(databaseQueue: try database()), space: .personal, preferences: defaults)
        #expect(personal.selection == .all)
        let unfiled = KnowledgeItem(title: "Unfiled", content: "Tool-created")
        try await service.save(unfiled)
        await model.reload()
        model.selection = .unfiled
        #expect(model.scopedItems.map(\.id) == [unfiled.id])
    }
}
