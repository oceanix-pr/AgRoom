import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Artifact result grouping")
struct TaskArtifactGroupingTests {
    @Test("Repeated receipts collapse by full path and default to the newest supplied revision")
    func latestSuppliedRevision() throws {
        let path = "/workspace/Sources/Report.swift"
        let first = TaskArtifact(path: path, versionID: UUID(), version: 1, sourceSpace: .work)
        let second = TaskArtifact(path: path, versionID: UUID(), version: 2, sourceSpace: .work)
        let third = TaskArtifact(path: path, versionID: UUID(), version: 3, sourceSpace: .work, contentRetained: true)
        let other = TaskArtifact(path: "/workspace/Tests/Report.swift", sourceSpace: .work)
        var refreshed = third; refreshed.contentRetained = false
        let groups = TaskArtifactGroup.collect([third, other, first, second, refreshed])
        #expect(groups.count == 2)
        let group = try #require(groups.first)
        #expect(group.newest == refreshed)
        #expect(group.revisions.map(\.version) == [3, 2, 1])
        #expect(groups.last?.newest == other)
        #expect(TaskArtifactGroup.collect([first]).first?.newest == first)
    }

    @Test("Identical filenames, distinct directories, and different source spaces keep separate cards")
    func distinctFileIdentities() {
        let work = TaskArtifact(path: "/workspace/result.txt", versionID: UUID(), version: 1, sourceSpace: .work)
        let personal = TaskArtifact(path: work.path, versionID: UUID(), version: 2, sourceSpace: .personal)
        let nested = TaskArtifact(path: "/workspace/nested/result.txt", sourceSpace: .work)
        #expect(TaskArtifactGroup.collect([work, personal, nested]).map(\.newest) == [work, personal, nested])
    }

    @Test("A failed final recording stays visible instead of silently selecting an older saved result")
    func failedFinalRevision() throws {
        let saved = TaskArtifact(path: "/workspace/result.txt", versionID: UUID(), version: 4, createdAt: Date(), sourceSpace: .work, contentRetained: true)
        let failed = TaskArtifact(path: saved.path, sourceSpace: .work, recordingFailed: true)
        let group = try #require(TaskArtifactGroup.collect([saved, failed]).first)
        #expect(group.newest == failed && group.revisions.count == 2)
    }
}

@Suite("Actual artifact versions and provenance")
struct TaskArtifactVersionTests: Sendable {
    private struct Stack {
        let root: URL
        let queue: DatabaseQueue
        let store: TaskArtifactStore
        let files: FileAreaService
    }
    private func stack(_ space: AppSpace = .work) throws -> Stack {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-versions-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        return .init(root: root, queue: queue, store: TaskArtifactStore(databaseQueue: queue, space: space, previewRoot: root.appendingPathComponent("previews")),
            files: FileAreaService(baseDirectory: root, additionalRoots: [root]))
    }
    private func json(_ values: [String: String]) throws -> String { String(decoding: try JSONEncoder().encode(values), as: UTF8.self) }
    private func execute(_ tool: any DispatcherTool, args: String, stack: Stack, session: UUID, run: UUID = UUID(), operation: String = UUID().uuidString,
                         journal: OperationJournal? = nil, inputs: [UUID] = []) async throws -> [DispatcherTraceEntry] {
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "", executionContext: ExecutionContext(space: .work, sessionID: session, runID: run, permissionPolicy: nil),
            artifactStore: stack.store, inputArtifactVersionIDs: inputs)
        engine.operationJournal = journal
        var result = try await engine.executeCommand(.init(id: operation, name: tool.definition.name, argumentsJSON: args))
        if case .needsConfirmation = result {
            let approval = try #require(engine.pendingApprovalID)
            result = try await engine.resume(.confirmed(approvalID: approval, approved: true, alwaysAllow: false, persistRule: false))
        }
        guard case .finished(_, _, let trace, _, _, _, _) = result else { throw TaskArtifactError.unavailable }
        return trace
    }

    @Test("Real file writes retain both contents and logical versions after original files change or disappear")
    func immutableFileVersions() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let path = s.root.appendingPathComponent("report.md").path, session = UUID(), run = UUID()
        let tool = FilesWriteTool(service: s.files, space: .work)
        let firstTrace = try await execute(tool, args: json(["path": path, "content": "First result"]), stack: s, session: session, run: run)
        let first = try #require(firstTrace.last?.allArtifacts.first)
        let nextTrace = try await execute(tool, args: json(["path": path, "content": "Revised result"]), stack: s, session: session)
        let next = try #require(nextTrace.last?.allArtifacts.first)
        #expect(first.version == 1 && next.version == 2 && first.id != next.id && first.path != next.path)
        #expect(first.sourceTool == "files_write" && first.sourceSpace == .work && first.contentRetained == true)
        try Data("Unrelated later edit".utf8).write(to: URL(fileURLWithPath: first.path))
        try FileManager.default.removeItem(atPath: next.path)
        let firstCopy = try await s.store.materialize(first), nextCopy = try await s.store.materialize(next)
        #expect(firstCopy.lastPathComponent.contains("(v1)") && nextCopy.lastPathComponent.contains("(v2)"))
        #expect(try String(contentsOf: firstCopy, encoding: .utf8) == "First result")
        #expect(try String(contentsOf: nextCopy, encoding: .utf8) == "Revised result")
        let modes = try FileManager.default.attributesOfItem(atPath: firstCopy.path)[.posixPermissions] as? NSNumber
        #expect(modes?.intValue == 0o400)
        let history = try await s.store.versions(of: first)
        #expect(history.count == 2 && history.last?.runID == run && history.last?.sessionID == session)
        let legacy = try JSONDecoder().decode(TaskArtifact.self, from: Data(#"{"path":"/old/result.txt"}"#.utf8))
        #expect(legacy.versionID == nil && legacy.id == legacy.path)
    }

    @Test("The dispatcher rejects invented file receipts and replays saved metadata without repeating a real write")
    func trustedReceiptsAndJournal() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let invented = try await execute(InventedReceipt(), args: "{}", stack: s, session: UUID())
        #expect(invented.last?.allArtifacts.isEmpty == true)
        let tool = FilesWriteTool(service: s.files, space: .work), run = UUID(), session = UUID(), operation = UUID().uuidString
        let args = try json(["path": s.root.appendingPathComponent("once.txt").path, "content": "Only once"])
        let journal = OperationJournal(directory: s.root.appendingPathComponent("journal"))
        let first = try await execute(tool, args: args, stack: s, session: session, run: run, operation: operation, journal: journal)
        let replay = try await execute(tool, args: args, stack: s, session: session, run: run, operation: operation, journal: journal)
        #expect(first.last?.allArtifacts == replay.last?.allArtifacts && first.last?.allArtifacts.count == 1)
        #expect(!FileManager.default.fileExists(atPath: s.root.appendingPathComponent("once 2.txt").path))
    }

    @Test("Python output discovery keeps nested binary files and excludes symlinks and hardlinks without leaking their content")
    func outputDirectoryDiscovery() async throws {
        let s = try stack(), outside = try stack(.personal)
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: outside.root) }
        let output = s.root.appendingPathComponent("output"), nested = output.appendingPathComponent("charts")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let binary = Data([0, 1, 2, 255]), note = output.appendingPathComponent("note.txt")
        try binary.write(to: nested.appendingPathComponent("result.bin")); try Data("Actual note".utf8).write(to: note)
        let secret = outside.root.appendingPathComponent("private.txt"); try Data("Other space data".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("link"), withDestinationURL: secret)
        try FileManager.default.linkItem(at: secret, to: output.appendingPathComponent("hardlink"))
        let capture = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: UUID(), runID: UUID(), workspaceID: nil, operationID: "python", tool: "python_execute"))
        let skipped = try await ToolArtifactCapture.$current.withValue(capture) { try await ToolArtifactCapture.recordDirectory(output) }
        #expect(skipped == 2 && capture.artifacts.count == 2)
        let artifact = try #require(capture.artifacts.first { $0.name == "result.bin" })
        let copy = try await s.store.materialize(artifact)
        #expect(try Data(contentsOf: copy) == binary)
        #expect(try await outside.store.versions(of: artifact).isEmpty)
        await #expect(throws: TaskArtifactError.self) { _ = try await outside.store.materialize(artifact) }
    }

    @Test("Published shell stdout is a real version and cannot be replaced by text printed to the model",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"] != nil))
    func shellOutputReceipt() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let capture = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "shell", tool: "shell_run"))
        let tool = ShellRunTool(defaultWorkingDirectory: s.root.path, workspaceRoot: s.root.path,
            ruleStore: ShellApprovalRuleStore(fileURL: s.root.appendingPathComponent("rules.json")),
            sandboxBackend: .injected(try ScriptAppSandboxTests().runner()))
        let args = #"{"program":"printf","arguments":["%s","Exact output bytes"],"stdout_file":"result.txt"}"#
        _ = try await ToolArtifactCapture.$current.withValue(capture) { try await tool.execute(argumentsJSON: args) }
        let result = try #require(capture.artifacts.first)
        #expect(result.sourceTool == "shell_run" && capture.artifacts.count == 1)
        let url = try await s.store.materialize(result)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Exact output bytes")
    }

    @Test("A backend without signed stream support neither executes nor invents an output artifact")
    func unavailableShellBackend() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let capture = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "unavailable", tool: "shell_run"))
        let tool = ShellRunTool(defaultWorkingDirectory: s.root.path, workspaceRoot: s.root.path, sandboxBackend: .compatibility)
        await #expect(throws: ScriptIsolationError.self) {
            _ = try await ToolArtifactCapture.$current.withValue(capture) {
                try await tool.execute(argumentsJSON: #"{"program":"printf","arguments":["%s","Never published"],"stdout_file":"absent.txt"}"#)
            }
        }
        #expect(capture.artifacts.isEmpty && !FileManager.default.fileExists(atPath: s.root.appendingPathComponent("absent.txt").path))
    }

    @Test("Shell discovery retains only observed changes, excludes private and linked files, and keeps partial outputs")
    func shellObservedChanges() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let unchanged = s.root.appendingPathComponent("input.txt"), changed = s.root.appendingPathComponent("changed.txt")
        let secretRoot = s.root.appendingPathComponent("private"), secret = secretRoot.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: secretRoot, withIntermediateDirectories: true)
        try Data("Input only".utf8).write(to: unchanged); try Data("Before".utf8).write(to: changed)
        try Data("Private data".utf8).write(to: secret)
        let capture = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "observed", tool: "shell_run"))
        let observation = try await ToolArtifactCapture.$current.withValue(capture) {
            try await ShellArtifactObservation.prepare(directory: s.root, args: [:], denied: [secretRoot], readOnly: false)
        }
        let baseline = try #require(observation)
        try Data("After".utf8).write(to: changed)
        try Data("Changed private data".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: s.root.appendingPathComponent("link"), withDestinationURL: secret)
        try FileManager.default.linkItem(at: secret, to: s.root.appendingPathComponent("hardlink"))
        let binary = Data([0,255,4]); try binary.write(to: s.root.appendingPathComponent("partial.bin"))
        let diagnostic = try await ToolArtifactCapture.$current.withValue(capture) {
            try await baseline.finish(.init(outcome: .exited(7), stdout: "", stderr: "Failed after writing", duration: 0.1))
        }
        #expect(Set(capture.artifacts.map(\.name)) == ["changed.txt", "partial.bin"])
        #expect(capture.artifacts.allSatisfy { $0.observedChange == true && $0.sourceTool == "shell_run" })
        #expect(diagnostic.contains("excluded"))
        let artifact = try #require(capture.artifacts.first { $0.name == "partial.bin" })
        let url = try await s.store.materialize(artifact)
        #expect(try Data(contentsOf: url) == binary)
    }

    @Test("Shell discovery preflights bounds, respects explicit output scope, and never freezes uncertain executions")
    func shellDiscoveryBounds() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        var deep = s.root
        for _ in 0..<26 { deep.appendPathComponent("deep") }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let capture = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "bounded", tool: "shell_run"))
        await #expect(throws: ToolExecutionFailure.self) {
            _ = try await ToolArtifactCapture.$current.withValue(capture) {
                try await ShellArtifactObservation.prepare(directory: s.root, args: [:], denied: [], readOnly: false)
            }
        }
        let observation = try await ToolArtifactCapture.$current.withValue(capture) {
            try await ShellArtifactObservation.prepare(directory: s.root, args: ["artifact_paths": ["results"]], denied: [], readOnly: false)
        }
        let baseline = try #require(observation)
        let results = s.root.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try Data("Known output".utf8).write(to: results.appendingPathComponent("report.txt"))
        _ = try await ToolArtifactCapture.$current.withValue(capture) {
            try await baseline.finish(.init(outcome: .indeterminate("Still running"), stdout: "", stderr: "", duration: 0.1))
        }
        #expect(capture.artifacts.isEmpty)
        _ = try await ToolArtifactCapture.$current.withValue(capture) {
            try await baseline.finish(.init(outcome: .exited(0), stdout: "", stderr: "", duration: 0.1))
        }
        #expect(capture.artifacts.map(\.name) == ["report.txt"])
        await #expect(throws: TaskArtifactError.self) {
            _ = try await ToolArtifactCapture.$current.withValue(capture) {
                try await ShellArtifactObservation.prepare(directory: s.root, args: ["artifact_paths": ["../escape"]], denied: [], readOnly: false)
            }
        }
    }

    @Test("A real signed Shell command discovers direct writes, including files written before a nonzero exit",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"] != nil))
    func signedShellFileChanges() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let bytes = Data([0,255,13,10]); try bytes.write(to: s.root.appendingPathComponent("input.bin"))
        let destination = s.root.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let tool = ShellRunTool(defaultWorkingDirectory: s.root.path, workspaceRoot: s.root.path,
            sandboxBackend: .injected(try ScriptAppSandboxTests().runner()))
        let run = UUID(), session = UUID()
        let trace = try await execute(tool, args: #"{"program":"/bin/cp","arguments":["input.bin","results/output.bin"],"artifact_paths":["results"]}"#,
            stack: s, session: session, run: run)
        let output = try #require(trace.last?.allArtifacts.first)
        #expect(trace.last?.allArtifacts.count == 1 && output.observedChange == true)
        let url = try await s.store.materialize(output)
        #expect(try Data(contentsOf: url) == bytes)
        let partial = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: session, runID: UUID(), workspaceID: nil, operationID: "partial-shell", tool: "shell_run"))
        await #expect(throws: ToolExecutionFailure.self) {
            _ = try await ToolArtifactCapture.$current.withValue(partial) {
                try await tool.execute(argumentsJSON: #"{"program":"/bin/cp","arguments":["input.bin","absent.bin","results"],"artifact_paths":["results"]}"#)
            }
        }
        #expect(partial.artifacts.map(\.name) == ["input.bin"])
        let partialArtifact = try #require(partial.artifacts.first)
        let copy = try await s.store.materialize(partialArtifact)
        #expect(try Data(contentsOf: copy) == bytes)
    }

    @Test("An operation's cumulative retention limit keeps honest references and resets for the next operation")
    func aggregateRetentionLimit() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let limited = TaskArtifactStore(databaseQueue: s.queue, space: .work, previewRoot: s.root.appendingPathComponent("bounded-previews"), operationSnapshotLimit: 10)
        let run = UUID()
        var artifacts: [TaskArtifact] = []
        for name in ["a", "b", "c"] {
            let file = s.root.appendingPathComponent(name); try Data("123456".utf8).write(to: file)
            artifacts.append(try await limited.capture(file, root: s.root, logicalPath: nil,
                origin: .init(space: .work, sessionID: nil, runID: run, workspaceID: nil, operationID: "one", tool: "shell_run")))
        }
        #expect(artifacts.filter { $0.contentRetained == true }.count == 1)
        #expect(artifacts.suffix(2).allSatisfy { $0.contentRetained == false && $0.retentionReason == .operationLimit && $0.byteCount == 6 })
        let next = try await limited.capture(s.root.appendingPathComponent("c"), root: s.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: run, workspaceID: nil, operationID: "two", tool: "shell_run"))
        #expect(next.contentRetained == true && next.retentionReason == nil)
        await #expect(throws: TaskArtifactError.self) { _ = try await limited.materialize(artifacts[1]) }
    }

    @Test("Continued results retain attached-version ancestry without granting access to missing or foreign IDs")
    func continuationAncestry() async throws {
        let s = try stack(), other = try stack(.personal)
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: other.root) }
        let originalFile = s.root.appendingPathComponent("original.md"), originalSession = UUID()
        try Data("Original result".utf8).write(to: originalFile)
        let original = try await s.store.capture(originalFile, root: s.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: originalSession, runID: UUID(), workspaceID: nil, operationID: "original", tool: "python_execute"))
        let id = try #require(original.versionID)
        let tool = FilesWriteTool(service: s.files, space: .work)
        let trace = try await execute(tool, args: json(["path": s.root.appendingPathComponent("revised.md").path, "content": "Continued result"]),
            stack: s, session: UUID(), inputs: [UUID(), id, id])
        let result = try #require(trace.last?.allArtifacts.first)
        #expect(result.inputVersionIDs == [id] && result.version == 1)
        #expect(try await s.store.inputs(of: result).map(\.id) == [id])
        #expect(try await other.store.inputs(of: result).isEmpty)
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "", artifactStore: s.store, inputArtifactVersionIDs: [id])
        let snapshot = engine.takeSnapshot()
        let decoded = try JSONDecoder().decode(EngineRunSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.inputArtifactVersionIDs == [id])
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        old.removeValue(forKey: "inputArtifactVersionIDs")
        let oldDecoded = try JSONDecoder().decode(EngineRunSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(oldDecoded.inputArtifactVersionIDs == nil)
        try await SessionService(databaseQueue: s.queue).delete(id: originalSession)
        #expect(try await s.store.inputs(of: result).isEmpty)
        let copy = try await s.store.materialize(result)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "Continued result")
    }

    @Test("Batch edits publish versions only after applying, and a version-save failure never rolls back successful edits")
    func batchArtifactBoundary() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let file = s.root.appendingPathComponent("source.swift"); try Data("let value = 1".utf8).write(to: file)
        let reader = try RepositoryReader(root: s.root, service: s.files, space: .work)
        let recovery = TaskFileRecoveryStore(space: .work, databaseQueue: s.queue)
        let tool = FilesApplyChangesTool(reader: reader, recoveryStore: recovery, space: .work, taskID: UUID(), leases: TeamLeaseCenter())
        let changes: [[String: Any]] = [["path": file.path, "expected_sha256": ManagedTextSnapshot.digest(try Data(contentsOf: file)),
            "edits": [["old_text": "= 1", "new_text": "= 2"]]]]
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["changes": changes]), as: UTF8.self)
        let trace = try await execute(tool, args: args, stack: s, session: UUID())
        let output = try #require(trace.last?.allArtifacts.first)
        #expect(output.sourceTool == "files_apply_changes" && output.contentRetained == true)
        try await s.queue.write { try $0.execute(sql: "CREATE TRIGGER fail_artifact BEFORE INSERT ON artifact_versions BEGIN SELECT RAISE(FAIL,'injected'); END") }
        let nextChanges: [[String: Any]] = [["path": file.path, "expected_sha256": ManagedTextSnapshot.digest(try Data(contentsOf: file)),
            "edits": [["old_text": "= 2", "new_text": "= 3"]]]]
        let nextArgs = String(decoding: try JSONSerialization.data(withJSONObject: ["changes": nextChanges]), as: UTF8.self)
        let failed = try await execute(tool, args: nextArgs, stack: s, session: UUID())
        #expect(failed.last?.succeeded == false && failed.last?.allArtifacts.first?.recordingFailed == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 3")
        #expect(try await recovery.recoveries(taskID: tool.taskID).allSatisfy { $0.state == .applied })
    }

    @Test("Real signed Python execution discovers every supported output and preserves its binary contents",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"] != nil))
    func signedPythonOutputs() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let capture = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: UUID(), runID: UUID(), workspaceID: nil, operationID: "real-python", tool: "python_execute"))
        let executor = try ScriptAppSandboxTests().makeExecutor(root: s.root.appendingPathComponent("python"))
        let tool = PythonExecuteTool(executor: executor)
        let code = "from pathlib import Path\nPath('report.txt').write_text('Real Python report')\nPath('charts').mkdir()\nPath('charts/raw.bin').write_bytes(bytes([0,255,1]))\nprint('Written 1 characters to /invented.txt')"
        _ = try await ToolArtifactCapture.$current.withValue(capture) { try await tool.execute(argumentsJSON: json(["code": code])) }
        #expect(capture.artifacts.count == 2 && !capture.artifacts.contains { $0.path == "/invented.txt" })
        let binary = try #require(capture.artifacts.first { $0.name == "raw.bin" })
        let url = try await s.store.materialize(binary)
        #expect(try Data(contentsOf: url) == Data([0,255,1]))
        let partial = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "failed-python", tool: "python_execute"))
        await #expect(throws: ToolExecutionFailure.self) {
            _ = try await ToolArtifactCapture.$current.withValue(partial) {
                try await tool.execute(argumentsJSON: json(["code": "from pathlib import Path\nPath('partial.txt').write_text('Partial output')\nraise SystemExit(7)"]))
            }
        }
        let partialArtifact = try #require(partial.artifacts.first { $0.name == "partial.txt" })
        let partialURL = try await s.store.materialize(partialArtifact)
        #expect(try String(contentsOf: partialURL, encoding: .utf8) == "Partial output")
    }

    @Test("The installed managed interpreter produces a retained artifact without changing any user environment",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"] != nil && PythonRuntimeManager.shared.status().pythonPath != nil))
    func managedPythonOutputs() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let runtime = PythonRuntimeManager.shared.status()
        let executor = PythonExecutor(workspaceRoot: s.root.appendingPathComponent("managed-runtime-test"),
            sandboxRunner: try ScriptAppSandboxTests().runner(), runtime: runtime)
        let capture = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "managed-python", tool: "python_execute"))
        _ = try await ToolArtifactCapture.$current.withValue(capture) {
            try await PythonExecuteTool(executor: executor).execute(argumentsJSON: json(["code": "from pathlib import Path\nPath('managed.txt').write_text('Managed runtime output')"]))
        }
        let artifact = try #require(capture.artifacts.first)
        let url = try await s.store.materialize(artifact)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Managed runtime output")
    }

    @Test("Copy, rename and move receipts keep real file versions and preserve lineage across repeated relocation")
    func fileOperations() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let source = s.root.appendingPathComponent("source"), destination = s.root.appendingPathComponent("destination"), moved = s.root.appendingPathComponent("moved")
        for folder in [source, destination, moved] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("Report".utf8).write(to: source.appendingPathComponent("note.txt")); try Data([0,255]).write(to: source.appendingPathComponent("data.bin"))
        let session = UUID()
        let copy = try await execute(FilesCopyTool(service: s.files), args: json(["source": source.path, "destination_dir": destination.path]), stack: s, session: session)
        #expect(copy.last?.allArtifacts.count == 2)
        let copied = destination.appendingPathComponent("source"), renamed = destination.appendingPathComponent("renamed")
        let rename = try await execute(FilesRenameTool(service: s.files), args: json(["path": copied.path, "new_name": "renamed"]), stack: s, session: session)
        let renamedNote = try #require(rename.last?.allArtifacts.first { $0.name == "note.txt" })
        #expect(renamedNote.version == 2)
        let move = try await execute(FilesMoveTool(service: s.files), args: json(["source": renamed.appendingPathComponent("note.txt").path, "destination_dir": moved.path]), stack: s, session: session)
        let final = try #require(move.last?.allArtifacts.first)
        #expect(final.version == 3 && final.path == moved.appendingPathComponent("note.txt").path)
        #expect(try await s.store.versions(of: final).count == 3)
        let oldCopy = try #require(copy.last?.allArtifacts.first { $0.name == "note.txt" })
        let oldContents = try await s.store.materialize(oldCopy)
        #expect(try String(contentsOf: oldContents, encoding: .utf8) == "Report")
    }

    @Test("A nested engine retains the bound artifact store after leaving its parent call and resuming approval")
    func storeSurvivesApprovalBoundary() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let session = UUID()
        let capture = ToolArtifactCapture(store: s.store, origin: .init(space: .work, sessionID: session, runID: UUID(), workspaceID: "parent-workspace", operationID: "parent", tool: "agent"))
        let tool = FilesWriteTool(service: s.files, space: .work)
        let engine = ToolArtifactCapture.$current.withValue(capture) {
            DispatcherEngine(tools: [tool], systemPrompt: "", executionContext: ExecutionContext(space: .work, permissionPolicy: nil))
        }
        #expect(ToolArtifactCapture.current == nil)
        let args = try json(["path": s.root.appendingPathComponent("resumed.txt").path, "content": "Produced after approval"])
        _ = try await engine.executeCommand(.init(id: "child", name: "files_write", argumentsJSON: args))
        let approval = try #require(engine.pendingApprovalID)
        let outcome = try await engine.resume(.confirmed(approvalID: approval, approved: true, alwaysAllow: false, persistRule: false))
        guard case .finished(_, _, let trace, _, _, _, _) = outcome else { throw TaskArtifactError.unavailable }
        let artifact = try #require(trace.last?.allArtifacts.first)
        #expect(artifact.versionID != nil && capture.artifacts.isEmpty)
        let history = try await s.store.versions(of: artifact)
        #expect(history.count == 1 && history.first?.sessionID == session && history.first?.workspaceID == "parent-workspace")
    }

    @Test("Concurrent calls keep their own provenance; oversized files retain an honest reference without reading them into memory")
    func concurrentAndBounded() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let session = UUID(), a = UUID(), b = UUID(), tool = FilesWriteTool(service: s.files, space: .work)
        let firstArgs = try json(["path": s.root.appendingPathComponent("a.txt").path, "content": "A"])
        let secondArgs = try json(["path": s.root.appendingPathComponent("b.txt").path, "content": "B"])
        async let first = execute(tool, args: firstArgs, stack: s, session: session, run: a, operation: "a")
        async let second = execute(tool, args: secondArgs, stack: s, session: session, run: b, operation: "b")
        _ = try await (first, second)
        #expect(try await s.store.artifacts(runID: a, operationID: "a").map(\.name) == ["a.txt"])
        #expect(try await s.store.artifacts(runID: b, operationID: "b").map(\.name) == ["b.txt"])
        let large = s.root.appendingPathComponent("large.bin")
        #expect(FileManager.default.createFile(atPath: large.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(TaskArtifactStore.maximumSnapshotBytes + 1)); try handle.close()
        let artifact = try await s.store.capture(large, root: s.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: session, runID: UUID(), workspaceID: nil, operationID: "large", tool: "shell_run"))
        #expect(artifact.contentRetained == false && artifact.byteCount == TaskArtifactStore.maximumSnapshotBytes + 1 && artifact.sha256 == nil)
        await #expect(throws: TaskArtifactError.self) { _ = try await s.store.materialize(artifact) }
        try await SessionService(databaseQueue: s.queue).delete(id: session)
        #expect(try await s.store.versions(of: artifact).isEmpty)
    }

    @Test("Artifact snapshots cross spaces only through a verified backup and undo preserves later versions")
    func portableSnapshotsAndUndo() async throws {
        let s = try stack(), target = try stack(.personal)
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: target.root) }
        let file = s.root.appendingPathComponent("original.txt")
        try Data("Portable historical bytes".utf8).write(to: file)
        let run = UUID(), session = UUID()
        let original = try await s.store.capture(file, root: s.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: session, runID: run, workspaceID: "old-workspace", operationID: "write", tool: "files_write"))
        let originalID = try #require(original.versionID)
        let revisedFile = s.root.appendingPathComponent("revised.txt"); try Data("Continued portable result".utf8).write(to: revisedFile)
        let revised = try await s.store.capture(revisedFile, root: s.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: session, runID: run, workspaceID: "old-workspace", operationID: "revision", tool: "python_execute", inputVersionIDs: [originalID]))
        let sourceBackup = SpaceDatabaseBackupStore(queue: s.queue, space: "work")
        let archive = try await sourceBackup.export()
        try FileManager.default.removeItem(at: file)
        let destination = target.root.appendingPathComponent("restored.txt").path
        let targetBackup = SpaceDatabaseBackupStore(queue: target.queue, space: "personal")
        let plan = try await targetBackup.plan(archive, sourceSpace: "work", pathMappings: [file.path: destination], workspaceMappings: ["old-workspace": "new-workspace"])
        let applied = try await targetBackup.apply(plan, willCommit: { _ in })
        try await targetBackup.verify(applied)
        let records = try await target.store.artifacts(runID: run, operationID: "write")
        let restored = try #require(records.first)
        #expect(restored.versionID == original.versionID && restored.sourceSpace == .personal && restored.path == destination)
        let copy = try await target.store.materialize(restored)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "Portable historical bytes")
        #expect(try await target.store.versions(of: restored).first?.workspaceID == "new-workspace")
        let restoredRevisions = try await target.store.artifacts(runID: run, operationID: "revision")
        let restoredRevision = try #require(restoredRevisions.first)
        #expect(restoredRevision.versionID == revised.versionID && restoredRevision.inputVersionIDs == [originalID])
        #expect(try await target.store.inputs(of: restoredRevision).first?.artifact.sourceSpace == .personal)
        let laterFile = target.root.appendingPathComponent("later.txt"); try Data("Later result".utf8).write(to: laterFile)
        let later = try await target.store.capture(laterFile, root: target.root, logicalPath: nil,
            origin: .init(space: .personal, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "later", tool: "python_execute"))
        try await targetBackup.rollback(applied)
        #expect(try await target.store.versions(of: restored).isEmpty)
        #expect(try await target.store.versions(of: later).count == 1)
        let table = try #require(archive.tables.firstIndex { $0.name == "artifact_versions" })
        let content = try #require(archive.tables[table].columns.firstIndex(of: "contents"))
        var damaged = archive; damaged.tables[table].rows[0][content] = .blob(Data("Tampered bytes".utf8))
        let rejected = damaged
        await #expect(throws: (any Error).self) { _ = try await targetBackup.plan(rejected, sourceSpace: "work") }
    }

    @Test("Version storage failure reports the produced file without rerunning or pretending it has a historical snapshot")
    func storageFailure() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await s.queue.write { try $0.execute(sql: "CREATE TRIGGER fail_artifact BEFORE INSERT ON artifact_versions BEGIN SELECT RAISE(FAIL,'injected'); END") }
        let path = s.root.appendingPathComponent("real.txt")
        let trace = try await execute(FilesWriteTool(service: s.files, space: .work), args: json(["path": path.path, "content": "Already produced"]), stack: s, session: UUID())
        #expect(trace.last?.succeeded == false && trace.last?.allArtifacts.first?.recordingFailed == true)
        #expect(try String(contentsOf: path, encoding: .utf8) == "Already produced")
        #expect(trace.last?.allArtifacts.first?.versionID == nil)
    }

    private struct InventedReceipt: DispatcherTool {
        let definition = ToolDefinition(name: "files_write", description: "fixture", parametersSchemaJSON: "{}")
        let requiresConfirmation = false
        let sideEffectClass = ToolSideEffectClass.readOnly
        func execute(argumentsJSON: String) async throws -> String { "Written 10 characters to /invented.txt" }
    }
}
