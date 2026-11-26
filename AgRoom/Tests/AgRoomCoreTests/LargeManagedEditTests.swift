import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Large managed edits", .serialized)
struct LargeManagedEditTests {
    @Test("Preview budgets reject huge line counts and oversized grapheme excerpts without fabricated totals")
    func previewBudgets() {
        let manyLines = String(repeating: "a\n", count: 100_001)
        let large = FileChangePreviewBuilder.unifiedDiff(old: manyLines, new: "changed\n" + manyLines)
        #expect(large.text == nil && large.added == nil && large.removed == nil)
        let combining = String(repeating: "\u{301}", count: 40_000)
        let single = FileChangePreviewBuilder.unifiedDiff(old: "e" + combining, new: "f" + combining)
        #expect(single.text == nil && single.added == 1 && single.removed == 1)
        let crlf = FileChangePreviewBuilder.unifiedDiff(old: "a\r\nold\r\nz\r\n", new: "a\r\nnew\r\nz\r\n")
        #expect(crlf.added == 1 && crlf.removed == 1)
        #expect(crlf.text?.contains("-old\r\n") == true && crlf.text?.contains("+new\r\n") == true)
    }

    private struct Fixture {
        let base: URL
        let service: FileAreaService
        let reader: RepositoryReader
        let queue: DatabaseQueue
        var recovery: TaskFileRecoveryStore { TaskFileRecoveryStore(space: .work, databaseQueue: queue) }
        var tasks: CodingTaskStore { CodingTaskStore(databaseQueue: queue) }

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("large-managed-edit-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            let broad = FileAreaService(baseDirectory: base, additionalRoots: [base])
            try broad.ensureRoots()
            service = broad.scoped(to: [broad.workspaceRoot])
            reader = try RepositoryReader(root: broad.workspaceRoot, service: service, space: .work)
            queue = try DatabaseQueue(path: base.appendingPathComponent("task.sqlite").path)
            try DatabaseBootstrap.prepareSpace(queue)
        }

        func catalog() throws -> (URL, String) {
            let padding = String(repeating: "p", count: 990)
            let line = "    \"padding\": \"\(padding)\",\n"
            let original = "{\n" + String(repeating: line, count: 7_400)
                + "    \"value\": \"Old label\"\n}\n"
            #expect(original.utf8.count > 7 * 1024 * 1024)
            let file = reader.root.appendingPathComponent("Localizable.xcstrings")
            try Data(original.utf8).write(to: file)
            return (file, original)
        }
    }

    private func arguments(path: String, digest: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": path,
            "expected_sha256": digest,
            "old_text": "\"value\": \"Old label\"",
            "new_text": "\"value\": \"New label\"",
        ]), as: UTF8.self)
    }

    @Test("A seven MiB catalog is edited through the scoped engine and restored from task review")
    func scopedEditAndTaskReviewRestore() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let (file, original) = try fixture.catalog()
        let originalDigest = ManagedTextSnapshot.digest(Data(original.utf8))
        let args = try arguments(path: file.path, digest: originalDigest)
        let runID = UUID()
        let sessionID = UUID()
        let runtime = CodingTaskRuntime(store: fixture.tasks, reader: fixture.reader,
            sessionID: sessionID, runID: runID)
        try await runtime.begin(request: "Update the unique localized value")

        let preview = try #require(FileChangePreviewBuilder.build(
            toolName: "files_edit", argumentsJSON: args, service: fixture.service))
        #expect(preview.addedLines == 1 && preview.removedLines == 1)
        #expect(preview.diff?.contains("-    \"value\": \"Old label\"") == true)
        #expect(preview.diff?.contains("+    \"value\": \"New label\"") == true)
        #expect(preview.diff?.contains("@@ -7400,") == true)

        let edit = FilesEditTool(service: fixture.service, space: .work,
            recoveryStore: fixture.recovery, taskID: runID)
        let search = RepositorySearchTool(reader: fixture.reader)
        let read = FilesReadRangeTool(reader: fixture.reader)
        let area = FileAreaPolicy(service: fixture.service, defaultWriteRoots: [fixture.reader.root])
        let policy = PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: area)
        let scope = TaskExecutionScope.make(space: .work, sessionID: sessionID, runID: runID,
            parentRunID: nil, workspaceID: nil, workspacePath: fixture.reader.root.path,
            readRoots: [fixture.reader.root], writeRoots: [fixture.reader.root], artifactRoots: [],
            mode: .workspaceWrite, autoReviewEnabled: true, policyVersion: AutoReviewService.ruleVersion,
            userRequest: "Update the unique localized value")
        let context = ExecutionContext(space: .work, sessionID: sessionID, runID: runID,
            permissionPolicy: policy, taskScope: scope)
        let engine = DispatcherEngine(tools: [search, read, edit], systemPrompt: "fixture",
            fileAreaPolicy: area, executionContext: context, codingTask: runtime)
        #expect(!engine.requestReport.toolNames.contains("shell_run"))
        guard case .finished(_, _, let trace, _, _, _, _) = try await engine.executeCommand(
            ToolCallRaw(id: "large-edit", name: "files_edit", argumentsJSON: args)) else {
            Issue.record("The scoped managed edit unexpectedly requested confirmation")
            return
        }
        #expect(trace.first?.succeeded == true && engine.pendingApprovalID == nil)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"value\": \"New label\""))
        let points = try await fixture.recovery.recoveries(taskID: runID)
        #expect(points.count == 1 && points.first?.state == .applied)
        #expect(points.first?.oldData?.count == original.utf8.count)

        let review = try CodingTaskReviewService(store: fixture.tasks, service: fixture.service,
            space: .work, root: fixture.reader.root, sessionID: sessionID)
        let entry = try #require(try await review.load().1.first)
        #expect(entry.canRestore && entry.matchesRecordedVersion)
        #expect(entry.diff?.contains("New label") == true)
        try await review.restore(path: file.path, expectedDigest: try #require(entry.digest), space: .work)
        #expect(ManagedTextSnapshot.digest(try Data(contentsOf: file)) == originalDigest)
    }

    @Test("A seven MiB edit recovery point restores the previous bytes")
    func recoveryPointRestore() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let (file, original) = try fixture.catalog()
        let taskID = UUID()
        let edit = FilesEditTool(service: fixture.service, space: .work,
            recoveryStore: fixture.recovery, taskID: taskID)
        _ = try await edit.execute(argumentsJSON: arguments(
            path: file.path, digest: ManagedTextSnapshot.digest(Data(original.utf8))))
        let point = try #require(try await fixture.recovery.recoveries(taskID: taskID).first)
        #expect(point.state == .applied)
        let restore = TaskFileRecoveryService(store: fixture.recovery, service: fixture.service)
        let reverted = try await restore.restore(point)
        #expect(reverted.state == .reverted)
        #expect(try Data(contentsOf: file) == Data(original.utf8))
    }
}
