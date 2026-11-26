import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Complete backup workflows")
@MainActor
struct CompleteBackupWorkflowTests {
    private struct Stack {
        let root: URL
        let queue: DatabaseQueue
        let area: FileAreaService
        let registry: WorkspaceRegistry
        let skills: SkillStore
        let backup: BackupService
        var sessions: SessionService { .init(databaseQueue: queue) }
        var knowledge: KnowledgeService { .init(databaseQueue: queue) }
        var preferences: ProductPreferencesService { .init(databaseQueue: queue) }
        var apps: NativeAppStore { .init(directoryURL: root.appendingPathComponent("apps"), space: .work) }
    }

    private func stack(_ root: URL) throws -> Stack {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let area = FileAreaService(baseDirectory: root.appendingPathComponent("file-area"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"), fileAreaService: area)
        let skills = SkillStore(directoryURL: root.appendingPathComponent("skills"))
        let backup = BackupService(sessionService: .init(databaseQueue: queue), memoryService: .init(databaseQueue: queue),
            skillStore: skills, spaceName: "work", workspacesProvider: { await registry.workspaces(for: .work) },
            attachmentsDirectory: root.appendingPathComponent("attachments"), audioDirectory: root.appendingPathComponent("audio"),
            fileAreaService: area, adoptWorkspaces: { try await registry.adoptRestored($0, in: .work) },
            removeWorkspaces: { try await registry.removeRestored($0, in: .work) })
        return Stack(root: root, queue: queue, area: area, registry: registry, skills: skills, backup: backup)
    }

    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("complete-backup-" + UUID().uuidString) }

    @Test("Whole-space restore rebuilds projects and WAL databases, verifies apps, and can undo without erasing later metrics")
    func completeRoundTripAndUndo() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let workspace = try #require(source.registry.defaultWorkspace(for: .work))
        let report = workspace.url.appendingPathComponent("report.txt")
        try Data("finished report".utf8).write(to: report)
        try FileManager.default.createDirectory(at: workspace.url.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external-project")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("external project".utf8).write(to: external.appendingPathComponent("external.txt"))
        _ = try source.registry.addExistingWorkspace(path: external.path, for: .work)
        try FileManager.default.createSymbolicLink(at: workspace.url.appendingPathComponent("linked-secret"), withDestinationURL: external.appendingPathComponent("external.txt"))
        var session = ChatSession(title: "Report", workspaceId: workspace.id.uuidString)
        let project = try await WorkspaceProjectStore(databaseQueue: source.queue, space: .work).save(
            .init(instructions: "RETAIN PROJECT RULES", knowledgeBaseIDs: [], preferredSkillNames: ["review"]), workspaceID: workspace.id, expectedRevision: nil)
        var contextReport = RequestContextReport()
        contextReport.resourceContext = RunResourceContext(space: .work, workspaceID: workspace.id, project: project, excludesMemory: true)
        session.messages = [.init(role: .assistant, content: "Report ready", trace: [.init(toolName: "files_write", argumentsPreview: "", resultPreview: "",
            artifact: TaskArtifact(path: report.path), duration: 0.1, succeeded: true)], runStatus: .succeeded, contextReport: contextReport, taskRun: .init(), memoryExcluded: true)]
        session.messages[0].variations = [AnswerVariation(question: "Retain choices", message: session.messages[0])]
        try await source.sessions.save(session)
        let item = KnowledgeItem(title: "Evidence", content: "archived evidence")
        try await source.knowledge.save(item)
        var originalItem = item; originalItem.content = "destination evidence"
        try await target.knowledge.save(originalItem)
        let note = try NativeAppTemplates.note()
        try await source.apps.install(note, replacing: nil)
        let sourceApp = try await source.apps.workspace(for: note)
        let recordID = UUID(), fileID = UUID()
        try await sourceApp.saveRecord(id: recordID, collection: "notes", title: "Archived", content: "app content", replacing: nil)
        try await sourceApp.saveFile(id: fileID, name: "inside.txt", data: Data("app file".utf8), recordID: recordID)
        try await target.apps.install(note, replacing: nil)
        let oldApp = try await target.apps.workspace(for: note)
        let originalRecordID = UUID()
        try await oldApp.saveRecord(id: originalRecordID, collection: "notes", title: "Destination", content: "keep on undo", replacing: nil)
        let drafts = NativeAppDraftStore(directoryURL: source.root.appendingPathComponent("app-drafts"), space: .work)
        _ = try await drafts.save(note, sourceSessionID: session.id)
        let databaseDir = source.root.appendingPathComponent("databases")
        try FileManager.default.createDirectory(at: databaseDir, withIntermediateDirectories: true)
        let live = try DatabaseQueue(path: databaseDir.appendingPathComponent("user.sqlite").path)
        try await live.writeWithoutTransaction {
            try $0.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE evidence (body TEXT); INSERT INTO evidence VALUES ('committed WAL value')")
        }
        #expect(FileManager.default.fileExists(atPath: databaseDir.appendingPathComponent("user.sqlite-wal").path))
        let zip = root.appendingPathComponent("complete.zip")
        let exported = try await source.backup.export(to: zip)
        #expect(exported.coverage.first(where: { $0.kind == "omittedWorkspaces" })?.records == 1)
        #expect(exported.coverage.first(where: { $0.kind == "omittedLinks" })?.records == 1)
        let plan = try await target.backup.inspect(from: zip)
        #expect(plan.corruptSections.isEmpty && plan.packageFingerprint.count == 64)
        let restored = try await target.backup.restore(from: zip, expectedFingerprint: plan.packageFingerprint)
        #expect(restored.verificationSucceeded && restored.restorePointID != nil)
        let restoredSession = try #require(try await target.sessions.fetch(id: session.id))
        let restoredContext = try #require(restoredSession.messages.first?.contextReport?.resourceContext)
        #expect(restoredContext.isValid && restoredContext.excludesMemory && restoredContext.workspaceID.uuidString == restoredSession.workspaceId)
        #expect(restoredSession.messages.first?.memoryExcluded == true)
        #expect(restoredSession.messages.first?.variations?.first?.contextReport?.resourceContext == restoredContext)
        #expect(try await WorkspaceProjectStore(databaseQueue: target.queue, space: .work).project(workspaceID: restoredContext.workspaceID)?.configuration == project.configuration)
        #expect(try await ProductTaskRunStore(databaseQueue: target.queue).run(id: #require(session.messages.first?.taskRun?.id))?.resourceContext == restoredContext)
        let restoredReport = try #require(restoredSession.messages.first?.trace?.first?.artifact?.path)
        #expect(restoredReport.hasPrefix(target.area.defaultChatRoot(for: .work).path + "/Restored/"))
        #expect(try String(contentsOfFile: restoredReport, encoding: .utf8) == "finished report")
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: restoredReport).deletingLastPathComponent().appendingPathComponent("empty").path))
        #expect(try await target.knowledge.get(id: item.id)?.content == item.content)
        let restoredApp = try await target.apps.workspace(for: note)
        #expect(try await restoredApp.record(id: recordID).content == "app content")
        #expect(try await restoredApp.fileData(id: fileID) == Data("app file".utf8))
        let databases = try FileManager.default.contentsOfDirectory(at: target.root.appendingPathComponent("databases"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "sqlite" }
        let restoredDatabase = try DatabaseQueue(path: #require(databases.first).path)
        #expect(try await restoredDatabase.read { try String.fetchOne($0, sql: "SELECT body FROM evidence") } == "committed WAL value")
        #expect(try await target.preferences.metrics().restoresVerified == 1)
        try await target.preferences.record(.manualIntervention)
        let points = try await target.backup.restorePoints()
        #expect(points.count == 1)
        try await target.backup.undoRestorePoint(id: #require(points.first).id)
        #expect(try await target.knowledge.get(id: item.id)?.content == originalItem.content)
        #expect(try await target.sessions.fetch(id: session.id) == nil)
        #expect(try await WorkspaceProjectStore(databaseQueue: target.queue, space: .work).project(workspaceID: restoredContext.workspaceID) == nil)
        #expect(!FileManager.default.fileExists(atPath: restoredReport))
        let recoveredApp = try await target.apps.workspace(for: note)
        #expect(try await recoveredApp.record(id: originalRecordID).content == "keep on undo")
        #expect(try await target.preferences.metrics().manualInterventions == 1)
        #expect(try await target.backup.restorePoints().isEmpty)
        #expect(try String(contentsOf: report, encoding: .utf8) == "finished report")
    }

    @Test("Failure after asset publication restores all original datasets and app data")
    func midRestoreFailure() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let workspace = try #require(source.registry.defaultWorkspace(for: .work))
        try Data("new report".utf8).write(to: workspace.url.appendingPathComponent("new.txt"))
        try await source.sessions.save(ChatSession(title: "New", workspaceId: workspace.id.uuidString))
        let item = KnowledgeItem(title: "New", content: "new")
        try await source.knowledge.save(item)
        var old = item; old.content = "before"
        try await target.knowledge.save(old)
        let note = try NativeAppTemplates.note()
        try await source.apps.install(note, replacing: nil)
        try await target.apps.install(note, replacing: nil)
        let original = try await target.apps.backup(id: note.id, space: .work)
        try await target.queue.write { try $0.execute(sql: "CREATE TRIGGER reject_restore BEFORE INSERT ON chat_sessions BEGIN SELECT RAISE(FAIL, 'injected write failure'); END") }
        let zip = root.appendingPathComponent("failure.zip")
        _ = try await source.backup.export(to: zip)
        do { _ = try await target.backup.restore(from: zip); Issue.record("Restore should fail") }
        catch let error as BackupError { guard case .rolledBack = error else { Issue.record("Expected complete rollback: \(error)"); return } }
        #expect(try await target.knowledge.get(id: item.id)?.content == "before")
        #expect(try await target.apps.backup(id: note.id, space: .work).fingerprint == original.fingerprint)
        #expect(try await target.sessions.getAll().isEmpty)
        #expect(try await target.backup.restorePoints().isEmpty)
        #expect(try await target.preferences.metrics().restoresAttempted == 1)
        #expect(try await target.preferences.metrics().restoresVerified == 0)
    }

    @Test("Confirmed package identity and later user edits are protected before any restore or undo writes")
    func stalePackageAndLaterEdits() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let item = KnowledgeItem(title: "Evidence", content: "archive")
        try await source.knowledge.save(item)
        let zip = root.appendingPathComponent("snapshot.zip")
        _ = try await source.backup.export(to: zip)
        let plan = try await target.backup.inspect(from: zip)
        await #expect(throws: BackupError.self) { _ = try await target.backup.restore(from: zip, expectedFingerprint: String(repeating: "0", count: 64)) }
        #expect(try await target.knowledge.get(id: item.id) == nil)
        let summary = try await target.backup.restore(from: zip, expectedFingerprint: plan.packageFingerprint)
        var edited = item; edited.content = "edited after restore"
        try await target.knowledge.save(edited)
        await #expect(throws: (any Error).self) { try await target.backup.undoRestorePoint(id: #require(summary.restorePointID)) }
        #expect(try await target.knowledge.get(id: item.id)?.content == edited.content)
        #expect(try await target.backup.restorePoints().count == 1)
    }

    @Test("A committed restore is finalized after restart and is never mistaken for an interrupted write")
    func committedRecovery() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let item = KnowledgeItem(title: "Committed", content: "verified data")
        try await source.knowledge.save(item)
        let zip = root.appendingPathComponent("committed.zip")
        _ = try await source.backup.export(to: zip)
        let blockedDirectory = target.root.appendingPathComponent("restore-points")
        try Data("unavailable directory".utf8).write(to: blockedDirectory)
        let result = try await target.backup.restore(from: zip)
        #expect(result.verificationSucceeded && result.warnings.contains(.restorePointPending))
        #expect(try await target.knowledge.get(id: item.id)?.content == item.content)
        try FileManager.default.removeItem(at: blockedDirectory)
        try await target.backup.recoverInterruptedRestoreIfNeeded()
        #expect(try await target.knowledge.get(id: item.id)?.content == item.content)
        #expect(try await target.backup.restorePoints().count == 1)
        #expect(try await target.preferences.metrics().restoresVerified == 1)
    }

    @Test("App data crosses spaces only through explicit backup consent; ordinary app APIs remain space bound")
    func explicitCrossSpaceAppRestore() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let note = try NativeAppTemplates.note(), recordID = UUID()
        try await source.apps.install(note, replacing: nil)
        let sourceApp = try await source.apps.workspace(for: note)
        try await sourceApp.saveRecord(id: recordID, collection: "notes", title: "Work", content: "explicitly transferred", replacing: nil)
        let personalApps = NativeAppStore(directoryURL: target.root.appendingPathComponent("apps"), space: .personal)
        let raw = try await source.apps.backup(id: note.id, space: .work)
        await #expect(throws: NativeAppError(.spaceMismatch)) { try await personalApps.restore(raw, space: .personal, replacing: nil) }
        let personal = BackupService(sessionService: target.sessions, memoryService: .init(databaseQueue: target.queue),
            skillStore: target.skills, spaceName: "personal", fileAreaService: target.area)
        let zip = root.appendingPathComponent("transfer.zip")
        _ = try await source.backup.export(to: zip)
        let plan = try await personal.inspect(from: zip)
        #expect(plan.spaceMismatch)
        await #expect(throws: BackupError.self) { _ = try await personal.restore(from: zip, expectedFingerprint: plan.packageFingerprint) }
        #expect(try await personalApps.catalog().apps.isEmpty)
        _ = try await personal.restore(from: zip, allowCrossSpace: true, expectedFingerprint: plan.packageFingerprint)
        let personalApp = try await personalApps.workspace(for: note)
        #expect(try await personalApp.record(id: recordID).content == "explicitly transferred")
        #expect(try await sourceApp.record(id: recordID).content == "explicitly transferred")
    }

    @Test("Private skill history is portable and same-name replacement can be undone with its original files")
    func skillHistoryRoundTrip() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let name = "report-skill"
        let sourceSkill = try source.skills.folderURL(for: name), targetSkill = try target.skills.folderURL(for: name)
        for folder in [sourceSkill, targetSkill] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let markdown = "---\nname: report-skill\ndescription: Report workflow\n---\n"
        try (markdown + "Archived instructions").write(to: sourceSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try (markdown + "Destination instructions").write(to: targetSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        _ = try source.skills.snapshotVersion(name: name)
        let before = try String(contentsOf: targetSkill.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let zip = root.appendingPathComponent("skills.zip")
        let exported = try await source.backup.export(to: zip)
        #expect((exported.coverage.first(where: { $0.kind == "skillHistory" })?.files ?? 0) > 0)
        let summary = try await target.backup.restore(from: zip)
        #expect(try target.skills.listVersions(name: name).count == 1)
        #expect(try String(contentsOf: targetSkill.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("Archived instructions"))
        try await target.backup.undoRestorePoint(id: #require(summary.restorePointID))
        #expect(try String(contentsOf: targetSkill.appendingPathComponent("SKILL.md"), encoding: .utf8) == before)
        #expect(try target.skills.listVersions(name: name).isEmpty)
    }

    @Test("Unrelated database and app writes fail during maintenance while the owner can complete backup work")
    func maintenanceWriters() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let stack = try stack(root)
        let note = try NativeAppTemplates.note()
        try await stack.apps.install(note, replacing: nil)
        let keys = [stack.queue.maintenanceKey, ResourceMaintenance.directoryKey(stack.apps.directoryURL)]
        let knowledge = stack.knowledge, apps = stack.apps
        try await ResourceMaintenance.withExclusive(keys) { @Sendable in
            let blocked = await Task.detached { () -> Bool in
                do { try await knowledge.save(KnowledgeItem(title: "Blocked", content: "")); return false }
                catch MaintenanceError.busy { return true }
                catch { return false }
            }.value
            #expect(blocked)
            let blockedApp = await Task.detached { () -> Bool in
                do { try await apps.setIconColor(.rose, id: note.id); return false }
                catch MaintenanceError.busy { return true }
                catch { return false }
            }.value
            #expect(blockedApp)
            try await knowledge.save(KnowledgeItem(title: "Owner", content: "permitted"))
        }
        #expect(try await stack.knowledge.getAll().count == 1)
    }

    @Test("Portable backups do not transfer pending confirmations or restart unfinished tasks")
    func executionAuthorityIsNotPortable() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        var session = ChatSession(title: "Waiting", autoReviewEnabled: true)
        let message = ChatMessage(role: .assistant, content: "Review required", runStatus: .waitingForConfirmation)
        session.messages = [message]
        session.pendingConfirmation = .init(messageId: message.id, toolName: "shell", argumentsDisplay: "nonportable approval input")
        try await source.sessions.save(session)
        let zip = root.appendingPathComponent("without-authority.zip")
        _ = try await source.backup.export(to: zip)
        #expect(try await source.sessions.fetch(id: session.id)?.pendingConfirmation != nil)
        _ = try await target.backup.restore(from: zip)
        let restored = try #require(try await target.sessions.fetch(id: session.id))
        #expect(restored.pendingConfirmation == nil && restored.pendingQuestion == nil && !restored.autoReviewEnabled)
        #expect(restored.messages.first?.runStatus == .recoveryRequired)
    }
}
