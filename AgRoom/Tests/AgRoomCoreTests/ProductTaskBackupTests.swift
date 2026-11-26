import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Task history backup and undo")
@MainActor
struct ProductTaskBackupTests {
    private struct Stack {
        let queue: DatabaseQueue
        let area: FileAreaService
        let registry: WorkspaceRegistry
        let backup: BackupService
        var sessions: SessionService { .init(databaseQueue: queue) }
        var history: ProductTaskRunStore { .init(databaseQueue: queue) }
    }
    private func stack(_ root: URL) throws -> Stack {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let area = FileAreaService(baseDirectory: root.appendingPathComponent("file-area"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"), fileAreaService: area)
        let skills = SkillStore(directoryURL: root.appendingPathComponent("skills"))
        let backup = BackupService(sessionService: .init(databaseQueue: queue), memoryService: .init(databaseQueue: queue),
            skillStore: skills, spaceName: "work", workspacesProvider: { await registry.workspaces(for: .work) },
            fileAreaService: area, adoptWorkspaces: { try await registry.adoptRestored($0, in: .work) },
            removeWorkspaces: { try await registry.removeRestored($0, in: .work) })
        return .init(queue: queue, area: area, registry: registry, backup: backup)
    }

    @Test("Imported run provenance follows restored files; undo preserves unrelated runs and their later metrics")
    func provenanceAndLaterHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let workspace = try #require(source.registry.defaultWorkspace(for: .work))
        let output = workspace.url.appendingPathComponent("report.txt")
        try Data("Actual report".utf8).write(to: output)
        let runID = UUID()
        var session = ChatSession(title: "Report", workspaceId: workspace.id.uuidString)
        session.messages = [.init(role: .user, content: "Make report"), .init(role: .assistant, content: "Saved report",
            trace: [.init(toolName: "files_write", argumentsPreview: "", resultPreview: "", artifact: TaskArtifact(path: output.path), duration: 0.1, succeeded: true)],
            runStatus: .succeeded, taskRun: .init(id: runID))]
        try await source.sessions.save(session)
        let original = try #require(try await source.history.run(id: runID))
        let zip = root.appendingPathComponent("tasks.zip")
        _ = try await source.backup.export(to: zip)
        let result = try await target.backup.restore(from: zip)
        let imported = try #require(try await target.history.run(id: runID))
        let importedSession = try #require(try await target.sessions.fetch(id: session.id))
        #expect(imported.workspaceID == importedSession.workspaceId)
        #expect(imported.artifacts.first?.path == importedSession.messages.last?.trace?.first?.artifact?.path)
        #expect(imported.artifacts.first?.path != output.path)
        #expect(imported.startedAt == original.startedAt)
        // Saving a restored conversation cannot round its execution timestamp or duplicate metrics.
        try await target.sessions.save(importedSession)
        #expect(try await target.history.run(id: runID)?.startedAt == original.startedAt)
        let laterID = UUID()
        var later = ChatSession(title: "Unrelated later task")
        later.messages = [.init(role: .user, content: "Separate request"), .init(role: .assistant, content: "Later answer", runStatus: .succeeded, taskRun: .init(id: laterID))]
        try await target.sessions.save(later)
        try await target.backup.undoRestorePoint(id: #require(result.restorePointID))
        #expect(try await target.history.run(id: runID) == nil)
        #expect(try await target.history.run(id: laterID)?.answer == "Later answer")
        #expect(try await target.sessions.fetch(id: later.id)?.messages.last?.content == "Later answer")
        let metrics = try await ProductPreferencesService(databaseQueue: target.queue).metrics()
        #expect(metrics.tasksStarted == 1 && metrics.tasksCompleted == 1 && metrics.restoresVerified == 1)
    }

    @Test("Pre-history backups rebuild old answers, preserve the saved result, and do not fabricate executions")
    func rebuildLegacyBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-task-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        var session = ChatSession(title: "Old answer")
        session.messages = [.init(role: .user, content: "Original request"), .init(role: .assistant, content: "Older saved result")]
        try await source.sessions.save(session)
        try await source.queue.write { try $0.execute(sql: "DROP TABLE product_task_runs") }
        let zip = root.appendingPathComponent("old.zip")
        _ = try await source.backup.export(to: zip)
        let plan = try await target.backup.inspect(from: zip)
        #expect(plan.warnings.contains(.taskHistoryRebuilt))
        _ = try await target.backup.restore(from: zip, expectedFingerprint: plan.packageFingerprint)
        let summaries = try await target.history.summaries()
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        let run = try #require(try await target.history.run(id: summary.id))
        #expect(run.isLegacy && run.answer == "Older saved result" && run.finishedAt == nil)
        #expect(try await ProductPreferencesService(databaseQueue: target.queue).metrics().tasksStarted == 0)
    }

    @Test("Job receipts restore into the destination space, interrupt live snapshots, and undo preserves later jobs")
    func jobReceiptRestore() async throws {
        let source = try DatabaseQueue(), target = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(source); try DatabaseBootstrap.prepareSpace(target)
        let sourceJobs = ProductJobRunStore(databaseQueue: source, space: .work)
        var completed = BackgroundJob(name: "Export", kind: "backup-export", space: .work, origin: "settings")
        completed.state = .succeeded; completed.resultText = "Archived result"; completed.finishedAt = Date()
        completed.resultPath = "/original/result.zip"
        try sourceJobs.saveCompleted([completed])
        var active = BackgroundJob(name: "Unfinished", kind: "test", space: .work)
        active.state = .running
        try await sourceJobs.recordStarted(active)
        var reviewed = BackgroundJob(name: "Reviewed interruption", kind: "test", space: .work)
        reviewed.state = .interrupted
        try sourceJobs.saveCompleted([reviewed])
        _ = try await sourceJobs.acknowledgeInterruption(id: reviewed.id)
        let archive = try await SpaceDatabaseBackupStore(queue: source, space: "work").export()
        let targetBackup = SpaceDatabaseBackupStore(queue: target, space: "personal")
        let plan = try await targetBackup.plan(archive, sourceSpace: "work", pathMappings: ["/original/result.zip": "/restored/result.zip"])
        let applied = try await targetBackup.apply(plan, willCommit: { _ in })
        try await targetBackup.verify(applied)
        let targetJobs = ProductJobRunStore(databaseQueue: target, space: .personal)
        let imported = try #require(try await targetJobs.run(id: completed.id))
        #expect(imported.space == .personal && imported.resultText == "Archived result" && imported.resultPath == "/restored/result.zip")
        let interrupted = try #require(try await targetJobs.run(id: active.id))
        #expect(interrupted.state == .interrupted && interrupted.finishedAt == nil)
        #expect(try await targetJobs.run(id: reviewed.id)?.state == .interruptionAcknowledged)
        var later = BackgroundJob(name: "Later unrelated job", kind: "test", space: .personal)
        later.state = .succeeded; later.finishedAt = Date()
        try targetJobs.saveCompleted([later])
        try await targetBackup.rollback(applied)
        #expect(try await targetJobs.run(id: completed.id) == nil)
        #expect(try await targetJobs.run(id: active.id) == nil)
        #expect(try await targetJobs.run(id: reviewed.id) == nil)
        #expect(try await targetJobs.run(id: later.id)?.state == .succeeded)
    }

    @Test("Cleared task identities follow backups while undo preserves later local clears")
    func clearedTaskHistoryRestore() async throws {
        let source = try DatabaseQueue(), target = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(source); try DatabaseBootstrap.prepareSpace(target)
        let sourceJobs = ProductJobRunStore(databaseQueue: source, space: .work)
        var completed = BackgroundJob(name: "Cleared export", kind: "test", space: .work)
        completed.state = .succeeded; completed.resultText = "Preserved source result"
        try sourceJobs.saveCompleted([completed])
        #expect(try await ProductTaskCenterStore(databaseQueue: source, space: .work).clearFinished() == 1)
        let archive = try await SpaceDatabaseBackupStore(queue: source, space: "work").export()
        #expect(archive.count("product_task_center_cleared") == 1)
        let backup = SpaceDatabaseBackupStore(queue: target, space: "personal")
        let plan = try await backup.plan(archive, sourceSpace: "work")
        let applied = try await backup.apply(plan, willCommit: { _ in })
        try await backup.verify(applied)
        let center = ProductTaskCenterStore(databaseQueue: target, space: .personal)
        let jobs = ProductJobRunStore(databaseQueue: target, space: .personal)
        #expect(try await center.page().items.isEmpty)
        #expect(try await jobs.run(id: completed.id)?.resultText == "Preserved source result")
        var later = BackgroundJob(name: "Later local job", kind: "test", space: .personal)
        later.state = .succeeded
        try jobs.saveCompleted([later])
        #expect(try await center.clearFinished() == 1)
        try await backup.rollback(applied)
        #expect(try await center.page().items.isEmpty)
        #expect(try await jobs.run(id: later.id) != nil)
        #expect(try await jobs.run(id: completed.id) == nil)
        #expect(try await target.read { try String.fetchAll($0, sql: "SELECT id FROM product_task_center_cleared") } == ["job:" + later.id.uuidString])
        // Imported clear markers accept only canonical source identities and dates.
        let tableIndex = try #require(archive.tables.firstIndex { $0.name == "product_task_center_cleared" })
        for (column, value): (String, SpaceBackupValue) in [("id", .text("unknown:" + UUID().uuidString)), ("clearedAt", .text("invalid"))] {
            var invalid = archive
            let columnIndex = try #require(invalid.tables[tableIndex].columns.firstIndex(of: column))
            invalid.tables[tableIndex].rows[0][columnIndex] = value
            await #expect(throws: ProductTaskHistoryError.self) { _ = try await backup.plan(invalid, sourceSpace: "work") }
        }
    }
}
