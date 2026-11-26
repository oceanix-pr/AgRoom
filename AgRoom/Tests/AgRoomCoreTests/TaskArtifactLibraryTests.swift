import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Artifact library and preview cleanup")
struct TaskArtifactLibraryTests: Sendable {
    private struct Fixture {
        let root: URL
        let queue: DatabaseQueue
        let store: TaskArtifactStore
        init(_ space: AppSpace = .work) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-library-" + UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
            store = TaskArtifactStore(databaseQueue: queue, space: space, previewRoot: root.appendingPathComponent("previews"))
        }
        func output(_ name: String, text: String = "Result", session: UUID? = nil, operation: String = UUID().uuidString) async throws -> TaskArtifact {
            let file = root.appendingPathComponent(name); try Data(text.utf8).write(to: file)
            return try await store.capture(file, root: root, logicalPath: nil,
                origin: .init(space: store.space, sessionID: session, runID: UUID(), workspaceID: nil, operationID: operation, tool: "python_execute"))
        }
    }

    @Test("Metadata paging handles tied dates, literal search, hidden sources and unsaved conversation results")
    func pagingAndOrphans() async throws {
        let f = try Fixture(), other = try Fixture(.personal)
        defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: other.root) }
        var hidden = ChatSession(title: "Hidden source"); hidden.isHidden = true
        try await SessionService(databaseQueue: f.queue).save(hidden)
        let missingSession = UUID()
        for index in 0..<83 { _ = try await f.output("report_\(index).txt", session: index < 2 ? hidden.id : missingSession) }
        _ = try await f.output("literal_%_name.txt")
        try await f.queue.write { try $0.execute(sql: "UPDATE artifact_versions SET createdAt='2026-01-01 00:00:00.000'") }
        var cursor: TaskArtifactLibraryPage.Cursor?, found: [TaskArtifactVersion] = []
        repeat {
            let page = try await f.store.libraryPage(before: cursor, limit: 17)
            found += page.items; cursor = page.next
        } while cursor != nil
        #expect(found.count == 82 && Set(found.map(\.id)).count == found.count)
        let all = try await f.store.libraryPage(limit: 1000, includeHidden: true)
        #expect(all.items.count == 84 && all.next == nil)
        #expect(try await f.store.libraryPage(search: "%_").items.map(\.artifact.name) == ["literal_%_name.txt"])
        #expect(try await f.store.libraryPage(search: "report_82.txt").items.count == 1)
        #expect(try await other.store.libraryPage().items.isEmpty)
        let orphan = try #require(found.first { $0.sessionID == missingSession })
        #expect(try await f.store.sourceSessionExists(for: orphan) == false)
        let hiddenRecord = try #require(all.items.first { $0.sessionID == hidden.id })
        #expect(try await f.store.sourceSessionExists(for: hiddenRecord))
        #expect(try await other.store.sourceSessionExists(for: hiddenRecord) == false)
        let summary = try await f.store.librarySummary()
        #expect(summary.versions == 84 && summary.retainedVersions == 84 && summary.retainedBytes == 84 * 6)
    }

    @Test("Removing retained contents preserves source files, provenance, other versions and future version ordinals")
    func removeContents() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.output("report.txt", text: "First")
        let second = try await f.output("report.txt", text: "Second")
        let copy = try await f.store.materialize(first)
        try await f.store.removeRetainedContents([first])
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(try String(contentsOfFile: second.path, encoding: .utf8) == "Second")
        let versions = try await f.store.versions(of: second)
        #expect(versions.count == 2 && versions.last?.artifact.retentionReason == .removedByUser && versions.last?.artifact.contentRetained == false)
        let references = try await f.store.libraryPage(filter: .referenceOnly)
        #expect(references.items.map(\.id) == [first.versionID!])
        #expect(try await f.store.libraryPage(filter: .retained).items.map(\.id) == [second.versionID!])
        await #expect(throws: TaskArtifactError.unavailable) { _ = try await f.store.materialize(first) }
        try await f.store.removeRetainedContents([first])
        let third = try await f.output("report.txt", text: "Third")
        #expect(third.version == 3)
        let summary = try await f.store.librarySummary()
        #expect(summary.versions == 3 && summary.retainedVersions == 2 && summary.retainedBytes == 11)
        let archive = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let other = try Fixture(.personal); defer { try? FileManager.default.removeItem(at: other.root) }
        let restore = SpaceDatabaseBackupStore(queue: other.queue, space: "personal")
        let plan = try await restore.plan(archive, sourceSpace: "work")
        let applied = try await restore.apply(plan, willCommit: { _ in })
        try await restore.verify(applied)
        let imported = try await other.store.libraryPage(filter: .referenceOnly)
        #expect(imported.items.first?.artifact.retentionReason == .removedByUser)
        #expect(try await other.store.librarySummary().retainedBytes == 11)
    }

    @Test("Long absolute path searches keep the distinguishing file name instead of matching only a folder prefix")
    func longPathSearch() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let folder = String(repeating: "d", count: 160)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent(folder), withIntermediateDirectories: true)
        let first = try await f.output(folder + "/" + String(repeating: "x", count: 180) + "-first.txt")
        _ = try await f.output(folder + "/" + String(repeating: "x", count: 180) + "-second.txt")
        #expect(first.path.count > 200)
        let matches = try await f.store.libraryPage(search: first.path)
        #expect(matches.items.map(\.artifact.path) == [first.path])
    }

    @Test("Cleanup approval binds exact versions and a mixed stale request rolls back all metadata changes")
    func staleSelection() async throws {
        let f = try Fixture(), other = try Fixture(.personal)
        defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: other.root) }
        let a = try await f.output("a.txt"), b = try await f.output("b.txt"), foreign = try await other.output("private.txt")
        var changed = b; changed.sha256 = "stale"
        await #expect(throws: TaskArtifactError.changedFile) { try await f.store.removeRetainedContents([a, changed]) }
        #expect(try await f.store.librarySummary().retainedVersions == 2)
        await #expect(throws: TaskArtifactError.unavailable) { try await f.store.removeRetainedContents([a, foreign]) }
        #expect(try await f.store.librarySummary().retainedVersions == 2)
        #expect(try await other.store.librarySummary().retainedVersions == 1)
    }

    @Test("Active preview pins prevent cleanup across store instances until the last user releases them")
    func previewPins() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let artifact = try await f.output("report.txt"), copy = try await f.store.materialize(artifact)
        let another = TaskArtifactStore(databaseQueue: f.queue, space: .work, previewRoot: f.root.appendingPathComponent("previews"))
        var pin: TaskArtifactPreviewPin? = try f.store.pinPreview(artifact, at: copy)
        await #expect(throws: TaskArtifactError.previewInUse) { try await another.clearPreviewCache() }
        await #expect(throws: TaskArtifactError.previewInUse) { try await another.removeRetainedContents([artifact]) }
        #expect(try await f.store.librarySummary().retainedVersions == 1)
        withExtendedLifetime(pin) {}; pin = nil
        try await another.clearPreviewCache()
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(try await f.store.previewCacheSummary().files == 0)
        let regenerated = try await f.store.materialize(artifact)
        #expect(try String(contentsOf: regenerated, encoding: .utf8) == "Result")
    }

    @Test("Orphan pruning removes deleted-session previews and cache cleanup unlinks external links without following them")
    func orphanAndLinkCleanup() async throws {
        let f = try Fixture(), outside = try Fixture(.personal)
        defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: outside.root) }
        let session = UUID(), orphan = try await f.output("gone.txt", session: session), live = try await f.output("live.txt")
        let removed = try await f.store.materialize(orphan), kept = try await f.store.materialize(live)
        try await SessionService(databaseQueue: f.queue).delete(id: session)
        try await f.store.pruneOrphanedPreviews()
        #expect(!FileManager.default.fileExists(atPath: removed.path) && FileManager.default.fileExists(atPath: kept.path))
        let secret = outside.root.appendingPathComponent("secret.txt"); try Data("Private content".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("previews/external"), withDestinationURL: outside.root)
        #expect(try await f.store.previewCacheSummary().bytes == 6)
        try await f.store.clearPreviewCache()
        #expect(try String(contentsOf: secret, encoding: .utf8) == "Private content")
        #expect(try await f.store.librarySummary().retainedVersions == 1)
    }

    @Test("A cache cleanup failure reports committed history removal and retries without changing the working file")
    func partialCleanup() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let artifact = try await f.output("result.txt"); _ = try await f.store.materialize(artifact)
        let cache = f.root.appendingPathComponent("previews")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cache.path)
        await #expect(throws: TaskArtifactError.cacheCleanupPending) { try await f.store.removeRetainedContents([artifact]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        #expect(try await f.store.librarySummary().retainedVersions == 0)
        #expect(try String(contentsOfFile: artifact.path, encoding: .utf8) == "Result")
        try await f.store.removeRetainedContents([artifact])
        #expect(try await f.store.previewCacheSummary().files == 0)
    }

    @Test("Preview generation and history removal respect another task's exclusive space maintenance lease")
    func maintenanceBoundary() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let artifact = try await f.output("result.txt")
        try await ResourceMaintenance.withExclusive([f.queue.maintenanceKey]) {
            await #expect(throws: MaintenanceError.self) { _ = try await Task.detached { try await f.store.materialize(artifact) }.value }
            await #expect(throws: MaintenanceError.self) { try await Task.detached { try await f.store.removeRetainedContents([artifact]) }.value }
        }
        #expect(try await f.store.librarySummary().retainedVersions == 1)
    }

    @Test("Restore undo protects the user's later decision to remove an imported historical copy")
    func restoreUndoProtectsCleanup() async throws {
        let source = try Fixture(), target = try Fixture(.personal)
        defer { try? FileManager.default.removeItem(at: source.root); try? FileManager.default.removeItem(at: target.root) }
        _ = try await source.output("portable.txt")
        let archive = try await SpaceDatabaseBackupStore(queue: source.queue, space: "work").export()
        let backup = SpaceDatabaseBackupStore(queue: target.queue, space: "personal")
        let plan = try await backup.plan(archive, sourceSpace: "work")
        let applied = try await backup.apply(plan, willCommit: { _ in })
        let page = try await target.store.libraryPage()
        let record = try #require(page.items.first)
        try await target.store.removeRetainedContents([record.artifact])
        await #expect(throws: (any Error).self) { try await backup.rollback(applied) }
        let remaining = try await target.store.currentArtifacts([record.id])
        #expect(remaining.first?.contentRetained == false && remaining.first?.retentionReason == .removedByUser)
    }
}
