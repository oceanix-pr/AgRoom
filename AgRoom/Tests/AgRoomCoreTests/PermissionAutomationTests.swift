import Foundation
import Testing
import GRDB
@testable import AgRoomCore

private actor PublicationBarrier {
    private var reached = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        reached = true
        await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { while !reached { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Permission automation")
struct PermissionAutomationTests {
    @Test("background admits only workspace-confined read-only shell commands")
    func backgroundReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path,
            approvalPolicy: .scopedBackground)
        let read = #"{"script":"ls ."}"#
        #expect(!tool.requiresHardConfirmation(argumentsJSON: read))
        #expect(tool.approvalRoute(argumentsJSON: read) == .deterministic)
        for args in [#"{"script":"mkdir output"}"#, #"{"script":"ls .."}"#,
                     #"{"script":"ls .","execution_mode":"host"}"#,
                     #"{"script":"ls .","stdout_file":"out"}"#] {
            #expect(tool.requiresHardConfirmation(argumentsJSON: args))
            #expect(tool.approvalRoute(argumentsJSON: args) == .manualOnly)
        }
    }

    @Test("cancellation after recovery preparation cannot publish an edit")
    func cancelledPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileAreaService(baseDirectory: root)
        try service.ensureRoots()
        let file = service.workspaceRoot.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: file)
        let barrier = PublicationBarrier()
        let queue = try DatabaseQueue()
        try await queue.write { try TaskFileRecoveryStore.createSchema($0) }
        let store = TaskFileRecoveryStore(space: .work, databaseQueue: queue)
        var tool = FilesEditTool(service: service, recoveryStore: store, taskID: UUID())
        tool.beforePublication = { await barrier.suspend() }
        let preparedTool = tool
        let digest = ManagedTextSnapshot.digest(Data("old".utf8))
        let task = Task { try await preparedTool.execute(argumentsJSON:
            #"{"path":"\#(file.path)","expected_sha256":"\#(digest)","old_text":"old","new_text":"new"}"#) }
        await barrier.wait()
        #expect(try await store.recoverable().first?.state == .prepared)
        task.cancel()
        await barrier.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
    }

    @Test("handed-off scope keeps restrictions and cannot cross spaces or regain capabilities")
    func handoffScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        func scope(_ space: AppSpace, _ mode: PermissionMode, autoReview: Bool = true, workspaceID: UUID? = nil) -> TaskExecutionScope {
            TaskExecutionScope.make(space: space, sessionID: sessionID, runID: UUID(), parentRunID: nil,
                workspaceID: workspaceID, workspacePath: root.path, readRoots: [root], writeRoots: [root], artifactRoots: [],
                mode: mode, autoReviewEnabled: autoReview, policyVersion: AutoReviewService.ruleVersion, userRequest: "Fix and test this project")
        }
        let original = scope(.work, .workspaceWrite).forHandoff()
        let restored = try original.restored(restrictedTo: scope(.work, .workspaceWrite))
        #expect(restored.id == original.id)
        #expect(restored.expiresAt == original.expiresAt)
        #expect(throws: ToolExecutionFailure.self) { try original.restored(restrictedTo: scope(.personal, .workspaceWrite)) }
        #expect(throws: ToolExecutionFailure.self) { try original.restored(restrictedTo: scope(.work, .readOnly)) }
        #expect(throws: ToolExecutionFailure.self) { try original.restored(restrictedTo: scope(.work, .workspaceWrite, workspaceID: UUID())) }
        #expect(throws: ToolExecutionFailure.self) { try original.restored(restrictedTo: scope(.work, .workspaceWrite), now: Date().addingTimeInterval(90_000)) }
        let manual = scope(.work, .workspaceWrite, autoReview: false).forHandoff()
        #expect(try !manual.restored(restrictedTo: scope(.work, .workspaceWrite)).autoReviewEnabled)
        #expect(try !original.restored(restrictedTo: scope(.work, .workspaceWrite, autoReview: false)).autoReviewEnabled)
        let moved = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: ToolExecutionFailure.self) { try original.restored(restrictedTo: scope(.work, .workspaceWrite)) }
    }

    @Test("task budget handoff includes pending reviewer reservations and retains consumed budget")
    func budgetHandoff() async throws {
        let ledger = ExecutionBudgetLedger(maxTokens: 1000, maxToolCalls: 10)
        let reservation = try await ledger.reserve(inputEstimate: 100, outputCap: 200, purpose: .reviewer)
        try await ledger.recordToolCall()
        let checkpoint = ledger.checkpoint
        #expect(checkpoint.spentTokens == 300)
        let restored = ExecutionBudgetLedger(maxTokens: checkpoint.maxTokens, maxToolCalls: checkpoint.maxToolCalls, restoring: checkpoint)
        #expect(await restored.remaining == 700)
        #expect(await restored.toolCallCount == 1)
        await #expect(throws: BudgetError.tokensExhausted) {
            _ = try await restored.reserve(inputEstimate: 700, outputCap: 1, purpose: .main)
        }
        await ledger.cancel(reservation)
        #expect(ledger.checkpoint.spentTokens == 0)
        #expect(await restored.remaining == 700)
    }
}

@Suite("Persistent workspace access")
@MainActor
struct PersistentWorkspaceAccessTests {
    @Test("real security-scoped bookmark survives a coordinator restart",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SCOPED_BOOKMARKS"] == "1"))
    func systemBookmarks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ChatWorkspace(name: "project", path: folder.path, space: .work)
        let storage = root.appendingPathComponent("access")
        try WorkspaceAccessCoordinator(root: storage).register(folder, workspace: workspace)
        let restored = WorkspaceAccessCoordinator(root: storage)
        #expect(try restored.restore(workspace).path == folder.path)
        restored.releaseAccess(for: .work)
    }

    @Test("a symlink cannot redirect a space's bookmark storage")
    func symlinkedStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let storage = root.appendingPathComponent("access")
        let work = storage.appendingPathComponent("work")
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmarks = WorkspaceAccessCoordinator.Bookmarks(create: { Data($0.path.utf8) },
            resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) })
        let workspace = ChatWorkspace(name: "project", path: folder.path, space: .work)
        let coordinator = WorkspaceAccessCoordinator(root: storage, bookmarks: bookmarks)
        try coordinator.register(folder, workspace: workspace)
        let moved = root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: work, to: moved)
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: moved)
        #expect(throws: (any Error).self) { try coordinator.restore(workspace) }
        #expect(throws: (any Error).self) { try coordinator.register(folder, workspace: workspace) }
    }

    @Test("bookmarks are stored per space and a replacement directory does not inherit access")
    func isolatedBookmarks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("access")
        let bookmarks = WorkspaceAccessCoordinator.Bookmarks(create: { Data($0.path.utf8) },
            resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) })
        let workspace = ChatWorkspace(name: "project", path: folder.path, space: .work)
        try WorkspaceAccessCoordinator(root: storage, bookmarks: bookmarks).register(folder, workspace: workspace)
        let restored = WorkspaceAccessCoordinator(root: storage, bookmarks: bookmarks)
        #expect(try restored.restore(workspace).path == folder.path)
        #expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("work/workspace-access.json").path))
        #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("personal/workspace-access.json").path))
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: WorkspaceAccessCoordinator.AccessError.self) { try restored.restore(workspace) }
        let record = storage.appendingPathComponent("work/workspace-access.json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: record)
        #expect(throws: (any Error).self) { try restored.register(folder, workspace: workspace) }
        #expect(try Data(contentsOf: record) == corrupt)
    }
}
