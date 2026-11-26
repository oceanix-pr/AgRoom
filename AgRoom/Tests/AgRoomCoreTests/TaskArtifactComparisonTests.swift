import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Saved artifact comparisons")
struct TaskArtifactComparisonTests: Sendable {
    private struct Fixture {
        let root: URL
        let queue: DatabaseQueue
        let store: TaskArtifactStore
        let files: FileAreaService
        let session = UUID()
        let workspaceID = UUID()
        func scope(_ run: UUID) -> TaskArtifactEditScope {
            .init(sessionID: session, runID: run, workspace: .init(id: workspaceID, name: "Fixture", path: root.path, space: store.space))
        }
        init(_ space: AppSpace = .work) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-diff-" + UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
            store = TaskArtifactStore(databaseQueue: queue, space: space, previewRoot: root.appendingPathComponent("previews"))
            files = FileAreaService(baseDirectory: root, additionalRoots: [root])
        }
        func execute(_ tool: any DispatcherTool, arguments: [String: String], run: UUID) async throws -> TaskArtifact {
            let args = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
            let capture = ToolArtifactCapture(store: store, origin: .init(space: store.space, sessionID: session,
                runID: run, workspaceID: workspaceID.uuidString, operationID: UUID().uuidString, tool: tool.definition.name,
                writeRootIdentities: [root.path: try TaskDirectoryIdentity.capture(root)]))
            _ = try await ToolArtifactCapture.$current.withValue(capture) { try await tool.execute(argumentsJSON: args) }
            return try #require(capture.artifacts.first)
        }
        func edit(_ file: URL, old: String, new: String, run: UUID) async throws -> TaskArtifact {
            let tool = FilesEditTool(service: files, space: store.space,
                recoveryStore: TaskFileRecoveryStore(space: store.space, databaseQueue: queue), taskID: run)
            return try await execute(tool, arguments: ["path": file.path, "old_text": old, "new_text": new,
                "expected_sha256": ManagedTextSnapshot.digest(try Data(contentsOf: file))], run: run)
        }
    }

    @Test("A result undoes just its own edits and creations, preflights every file, and remembers completion")
    func undoResult() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("answer.swift"), run = UUID()
        try Data("let value = 0\n".utf8).write(to: file)
        _ = try await f.edit(file, old: "0", new: "1", run: UUID())
        let first = try await f.edit(file, old: "1", new: "2", run: run)
        let last = try await f.edit(file, old: "2", new: "3", run: run)
        let created = try await f.execute(FilesWriteTool(service: f.files, space: .work),
            arguments: ["path": file.path, "content": "new\nfile\n"], run: run)
        let newFile = URL(fileURLWithPath: created.path)
        #expect(newFile != file)
        let result = [last, created], scope = f.scope(run)
        #expect(try await f.store.undoStatus(for: result, scope: scope) == .available)
        #expect(try await f.store.undoStatus(for: [first], scope: scope) == .unavailable)
        #expect(try await f.store.undoStatus(for: result, scope: f.scope(UUID())) == .unavailable)
        try Data("my changes".utf8).write(to: newFile)
        await #expect(throws: TaskArtifactUndoError.changed(created.path)) { try await f.store.undoEdits(result, scope: scope) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 3\n")
        #expect(try String(contentsOf: newFile, encoding: .utf8) == "my changes")
        try Data("new\nfile\n".utf8).write(to: newFile)
        try await f.store.undoEdits(result, scope: scope)
        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 1\n")
        #expect(!FileManager.default.fileExists(atPath: newFile.path))
        let reloaded = TaskArtifactStore(databaseQueue: f.queue, space: .work, previewRoot: f.root.appendingPathComponent("previews"))
        #expect(try await reloaded.undoStatus(for: result, scope: scope) == .undone)
        #expect(try await reloaded.comparison(of: created).added == 2)
        let records = try await TaskFileRecoveryStore(space: .work, databaseQueue: f.queue).recoveries(taskID: run)
        #expect(records.count == 2 && records.allSatisfy { $0.state == .reverted })
        try Data("new user file".utf8).write(to: newFile)
        try await reloaded.undoEdits(result, scope: scope)
        #expect(try String(contentsOf: newFile, encoding: .utf8) == "new user file")
    }

    @Test("An interrupted receipt can be finalized without replaying the filesystem edit")
    func undoRetry() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let run = UUID(), file = f.root.appendingPathComponent("old.txt")
        try Data("old".utf8).write(to: file)
        let edit = try await f.edit(file, old: "old", new: "new", run: run)
        try await f.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER stop_undo BEFORE UPDATE ON artifact_edit_receipts BEGIN SELECT RAISE(ABORT,'test failure'); END")
        }
        await #expect(throws: TaskArtifactUndoError.interrupted(path: file.path, completed: 0)) {
            try await f.store.undoEdits([edit], scope: f.scope(run))
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        try await f.queue.write { try $0.execute(sql: "DROP TRIGGER stop_undo") }
        try await f.store.undoEdits([edit], scope: f.scope(run))
        #expect(try await f.store.undoStatus(for: [edit], scope: f.scope(run)) == .undone)
    }

    @Test("A replaced workspace at the same path cannot receive an older undo")
    func replacedUndoRoot() async throws {
        let f = try Fixture(), original = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-previous-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: original) }
        let run = UUID(), file = f.root.appendingPathComponent("sample.txt")
        try Data("old".utf8).write(to: file)
        let edit = try await f.edit(file, old: "old", new: "new", run: run)
        try FileManager.default.moveItem(at: f.root, to: original)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: file)
        await #expect(throws: TaskArtifactUndoError.unavailable) { try await f.store.undoEdits([edit], scope: f.scope(run)) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    }

    @Test("A first managed edit has a baseline even though its artifact ordinal is one")
    func firstEditAndHistoricalContents() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("RootView.swift")
        try Data("let mode = 1\n".utf8).write(to: file)
        let artifact = try await f.edit(file, old: "1", new: "2", run: UUID())
        #expect(artifact.version == 1 && artifact.change?.kind == .modified)
        try FileManager.default.removeItem(at: file)
        let comparison = try await f.store.comparison(of: artifact)
        #expect(comparison.state == .available && comparison.added == 1 && comparison.removed == 1)
        #expect(comparison.hunks.flatMap(\.lines).contains { $0.kind == .removal && $0.text == "let mode = 1" && $0.oldLine == 1 })
        #expect(comparison.hunks.flatMap(\.lines).contains { $0.kind == .addition && $0.text == "let mode = 2" && $0.newLine == 1 })
        let other = try Fixture(.personal); defer { try? FileManager.default.removeItem(at: other.root) }
        await #expect(throws: TaskArtifactError.unsafeFile) { _ = try await other.store.comparison(of: artifact) }
    }

    @Test("A run compares first-before to selected-after, independently of later runs and live edits")
    func runAggregation() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("code.swift"), run = UUID()
        try Data("let value = 1\n".utf8).write(to: file)
        let first = try await f.edit(file, old: "1", new: "2", run: run)
        let last = try await f.edit(file, old: "2", new: "3", run: run)
        let next = try await f.edit(file, old: "3", new: "4", run: UUID())
        try Data("User's later edit".utf8).write(to: file)
        let old = try await f.store.comparison(of: first), combined = try await f.store.comparison(of: last)
        let newer = try await f.store.comparison(of: next)
        #expect(old.hunks.flatMap(\.lines).contains { $0.kind == .addition && $0.text == "let value = 2" })
        #expect(combined.added == 1 && combined.removed == 1 && !combined.interleaved)
        #expect(combined.hunks.flatMap(\.lines).contains { $0.kind == .removal && $0.text == "let value = 1" })
        #expect(combined.hunks.flatMap(\.lines).contains { $0.kind == .addition && $0.text == "let value = 3" })
        #expect(newer.hunks.flatMap(\.lines).contains { $0.kind == .removal && $0.text == "let value = 3" })
    }

    @Test("Intervening edits break aggregation rather than being attributed to the AI")
    func externalChanges() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("code.swift"), run = UUID()
        try Data("let value = 1\n".utf8).write(to: file)
        _ = try await f.edit(file, old: "1", new: "2", run: run)
        try Data("// User comment\nlet value = 2\n".utf8).write(to: file)
        let artifact = try await f.edit(file, old: "2", new: "3", run: run)
        let comparison = try await f.store.comparison(of: artifact)
        #expect(comparison.interleaved && comparison.added == 1 && comparison.removed == 1)
        #expect(try await f.store.undoStatus(for: [artifact], scope: f.scope(run)) == .unavailable)
        #expect(!comparison.hunks.flatMap(\.lines).contains { $0.kind == .addition && $0.text.contains("User comment") })
    }

    @Test("Creating a file is distinct from editing an empty existing file")
    func absentVersusEmpty() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let artifact = try await f.execute(FilesWriteTool(service: f.files, space: .work),
            arguments: ["path": f.root.appendingPathComponent("new.swift").path, "content": "let value = 1"], run: UUID())
        #expect(artifact.change?.kind == .created)
        let created = try await f.store.comparison(of: artifact)
        #expect(created.kind == .created && created.added == 1 && created.removed == 0)
        let file = f.root.appendingPathComponent("empty.swift")
        try Data().write(to: file)
        let edited = try await f.store.capture(file, root: f.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "empty", tool: "files_edit"), baseline: .existing(Data()))
        let empty = try await f.store.comparison(of: edited)
        #expect(empty.kind == .modified && empty.state == .unchanged)
    }

    @Test("Unknown originals and binary files never become an empty text baseline")
    func unsupportedContents() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("output.bin")
        try Data([0, 1, 255]).write(to: file)
        let origin = TaskArtifactStore.Origin(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "shell", tool: "shell_run")
        let observed = try await f.store.capture(file, root: f.root, logicalPath: nil, origin: origin, observedChange: true)
        #expect(try await f.store.comparison(of: observed).state == .baselineMissing)
        let binary = try await f.store.capture(file, root: f.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "binary", tool: "fixture"), baseline: .existing(Data([0, 3])))
        #expect(try await f.store.comparison(of: binary).state == .binary)
        await #expect(throws: TaskArtifactError.changedFile) {
            _ = try await f.store.capture(file, root: f.root, logicalPath: nil,
                origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "race", tool: "fixture"),
                baseline: .existing(Data()), expectedContents: Data("Different published bytes".utf8))
        }
    }

    @Test("Comparison contents survive packed backup, cross-space restore and tamper checks")
    func portableBaseline() async throws {
        let f = try Fixture(), target = try Fixture(.personal)
        defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: target.root) }
        let file = f.root.appendingPathComponent("code.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        let artifact = try await f.edit(file, old: "1", new: "2", run: UUID())
        let blobs = SpaceBackupBlobs(root: f.root.appendingPathComponent("blobs"))
        let source = SpaceDatabaseBackupStore(queue: f.queue, space: "work", blobs: blobs)
        let archive = try await source.export()
        #expect(!archive.tables.contains { $0.name == "artifact_edit_receipts" })
        let table = try #require(archive.tables.firstIndex { $0.name == "artifact_versions" })
        let column = try #require(archive.tables[table].columns.firstIndex(of: "beforeContents"))
        guard case .blobFile = archive.tables[table].rows[0][column] else { Issue.record("Baseline was not packed"); return }
        let backup = SpaceDatabaseBackupStore(queue: target.queue, space: "personal", blobs: blobs)
        let plan = try await backup.plan(archive, sourceSpace: "work")
        let applied = try await backup.apply(plan, willCommit: { _ in })
        try await backup.verify(applied)
        let versionID = try #require(artifact.versionID)
        let restored = try #require(try await target.store.version(id: versionID))
        let restoredDiff = try await target.store.comparison(of: restored.artifact)
        let originalDiff = try await f.store.comparison(of: artifact)
        #expect(restoredDiff == originalDiff)
        var damaged = archive
        damaged.tables[table].rows[0][column] = .blob(Data("Forged baseline".utf8))
        let invalid = damaged
        await #expect(throws: TaskArtifactError.changedFile) { _ = try await backup.plan(invalid, sourceSpace: "work") }
    }

    @Test("An open review protects both sides; explicit cleanup removes both and updates statistics")
    func cleanup() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("code.swift"), old = "let value = 1\n"
        try Data(old.utf8).write(to: file)
        let artifact = try await f.edit(file, old: "1", new: "2", run: UUID())
        #expect(try await f.store.librarySummary().retainedBytes == Int64(old.utf8.count * 2))
        let pin = try f.store.pinComparison()
        await #expect(throws: TaskArtifactError.previewInUse) { try await f.store.removeRetainedContents([artifact]) }
        pin.release()
        try await f.store.removeRetainedContents([artifact])
        #expect(try await f.store.librarySummary().retainedBytes == 0)
        #expect(try await f.store.comparison(of: artifact).state == .contentUnavailable)
    }

    @Test("Existing databases gain a nullable baseline column without inventing history")
    func legacyMigration() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("legacy.txt")
        try Data("Legacy result".utf8).write(to: file)
        let artifact = try await f.store.capture(file, root: f.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "legacy", tool: "fixture"))
        try await f.queue.write { db in
            try db.execute(sql: "ALTER TABLE artifact_versions DROP COLUMN beforeContents")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v3_artifact_comparisons'")
        }
        try DatabaseBootstrap.prepareSpace(f.queue)
        #expect(try await f.store.comparison(of: artifact).state == .baselineMissing)
        let changed = try await f.edit(file, old: "Legacy", new: "Revised", run: UUID())
        #expect(try await f.store.comparison(of: changed).state == .available)
    }

    @Test("A real batch edit retains the separate before contents of every output")
    func batchBaselines() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let run = UUID(), files = [f.root.appendingPathComponent("a.swift"), f.root.appendingPathComponent("b.swift")]
        for file in files { try Data("let value = 1\n".utf8).write(to: file) }
        let reader = try RepositoryReader(root: f.root, service: f.files, space: .work)
        let tool = FilesApplyChangesTool(reader: reader, recoveryStore: .init(space: .work, databaseQueue: f.queue), space: .work, taskID: run)
        let changes: [[String: Any]] = try files.map { file in
            ["path": file.path, "expected_sha256": ManagedTextSnapshot.digest(try Data(contentsOf: file)),
             "edits": [["old_text": "1", "new_text": "2"]]]
        }
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["changes": changes]), as: UTF8.self)
        let capture = ToolArtifactCapture(store: f.store, origin: .init(space: .work, sessionID: f.session,
            runID: run, workspaceID: "fixture", operationID: "batch", tool: "files_apply_changes"))
        _ = try await ToolArtifactCapture.$current.withValue(capture) { try await tool.execute(argumentsJSON: args) }
        #expect(capture.artifacts.count == 2)
        for artifact in capture.artifacts {
            let diff = try await f.store.comparison(of: artifact)
            #expect(diff.state == .available && diff.added == 1 && diff.removed == 1 && diff.kind == .modified)
        }
    }

    @Test("Hunk line numbers and split rows stay aligned across distant changes")
    @MainActor func lineAlignment() throws {
        let old = (1...80).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 3\n", with: "line three\nextra\n").replacingOccurrences(of: "line 70\n", with: "line seventy\n")
        let comparison = TaskArtifactComparison.compare(before: Data(old.utf8), after: Data(new.utf8), kind: .modified, interleaved: false)
        #expect(comparison.hunks.count == 2)
        let change = try #require(comparison.hunks.last?.lines.first { $0.kind == .addition })
        #expect(change.newLine == 71 && change.text == "line seventy")
        let rows = comparison.hunks.flatMap { ArtifactDiffView.alignedLines($0.lines) }
        #expect(rows.contains { $0.0 == nil && $0.1?.text == "extra" })
        #expect(rows.contains { $0.0?.text == "line 70" && $0.1?.text == "line seventy" })
        let newline = TaskArtifactComparison.compare(before: Data("end".utf8), after: Data("end\n".utf8),
            kind: .modified, interleaved: false)
        #expect(newline.added == 1 && newline.removed == 1)
        let ending = try #require(newline.hunks.first).lines
        #expect(ending.first?.kind == .removal && ending.first?.lacksFinalNewline == true)
        #expect(ending.last?.kind == .addition && ending.last?.lacksFinalNewline == false)
    }
}
