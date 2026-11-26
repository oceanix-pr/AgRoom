import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Task execution scope")
struct TaskExecutionScopeTests {
    private func workspace() throws -> (base: URL, workspace: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-scope-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (base, workspace)
    }

    private func scope(
        workspace: URL,
        userRequest: String = "Fix the project in this workspace.",
        mode: PermissionMode = .workspaceWrite
    ) -> TaskExecutionScope {
        TaskExecutionScope.make(
            space: .work,
            sessionID: UUID(),
            runID: UUID(),
            parentRunID: nil,
            workspaceID: UUID(),
            workspacePath: workspace.path,
            readRoots: [workspace],
            writeRoots: [workspace],
            artifactRoots: [workspace],
            mode: mode,
            autoReviewEnabled: true,
            policyVersion: AutoReviewService.ruleVersion,
            userRequest: userRequest
        )
    }

    @Test("explicit analysis-only instruction removes write and code capabilities")
    func analysisOnly() throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let value = scope(workspace: fixture.workspace, userRequest: "只分析这个项目，不要修改。")
        #expect(value.constraints.contains(.noWrites))
        #expect(value.constraints.contains(.noCodeExecution))
        #expect(!value.capabilities.contains(.write))
        #expect(!value.capabilities.contains(.script))
        #expect(!value.allows(.workspaceMutation))
        #expect(!value.allows(.confinedCodeExecution))
        #expect(value.allows(.readOnly))
    }

    @Test("same path with a replaced directory invalidates the task scope")
    func directoryReplacement() throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let value = scope(workspace: fixture.workspace)
        #expect(value.isActive())
        let moved = fixture.base.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.workspace, to: moved)
        try FileManager.default.createDirectory(at: fixture.workspace, withIntermediateDirectories: true)
        #expect(!value.isActive())
    }

    @Test("a write target outside the task roots is rejected")
    func writeTarget() throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let value = scope(workspace: fixture.workspace)
        #expect(value.containsWriteTargets([fixture.workspace.appendingPathComponent("a.txt").path]))
        #expect(!value.containsWriteTargets([fixture.base.appendingPathComponent("outside.txt").path]))
    }
}

@Suite("Task file recovery")
struct TaskFileRecoveryTests {
    private func fixture() throws -> (base: URL, service: FileAreaService, queue: DatabaseQueue, store: TaskFileRecoveryStore) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let service = FileAreaService(baseDirectory: base)
        try service.ensureRoots()
        let queue = try DatabaseQueue()
        try queue.write { db in
            try TaskFileRecoveryStore.createSchema(db)
        }
        let store = TaskFileRecoveryStore(space: .work, databaseQueue: queue)
        return (base, service, queue, store)
    }

    @Test("files_edit saves a recovery point, writes, and restores the prior bytes")
    func editAndRestore() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let file = fixture.service.workspaceRoot.appendingPathComponent("notes.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: file)
        let digest = before.sha256
        let taskID = UUID()
        let tool = FilesEditTool(
            service: fixture.service,
            space: .work,
            recoveryStore: fixture.store,
            taskID: taskID
        )
        #expect(tool.approvalRoute(argumentsJSON: "{}") == .deterministic)
        #expect(tool.autoReviewEvidence(argumentsJSON: "{}")["recovery_store"] == "true")
        _ = try await tool.execute(argumentsJSON: #"{"path":"\#(file.path)","expected_sha256":"\#(digest)","old_text":"before","new_text":"after"}"#)
        #expect(try String(contentsOf: file, encoding: .utf8) == "after\n")
        let records = try await fixture.store.recoverable()
        let record = try #require(records.first)
        #expect(record.state == .applied)
        #expect(record.oldData == before)
        let restore = TaskFileRecoveryService(store: fixture.store, service: fixture.service)
        _ = try await restore.restore(record)
        #expect(try Data(contentsOf: file) == before)

        // A user edit after the AI write must block restoration.
        let secondDigest = try Data(contentsOf: file).sha256
        _ = try await tool.execute(argumentsJSON: #"{"path":"\#(file.path)","expected_sha256":"\#(secondDigest)","old_text":"before","new_text":"ai-again"}"#)
        try "user change".write(to: file, atomically: true, encoding: .utf8)
        let latest = try #require(try await fixture.store.recoverable().first)
        await #expect(throws: TaskFileRecoveryError.self) {
            _ = try await restore.restore(latest)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "user change")
    }

    @Test("an edit without a recovery store stays manual")
    func noStoreManual() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let tool = FilesEditTool(service: fixture.service, space: .work)
        #expect(tool.approvalRoute(argumentsJSON: "{}") == .manualOnly)
    }

    @Test("auto review admits an in-scope edit only with an active task scope")
    func automaticApprovalNeedsTaskScope() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let file = fixture.service.workspaceRoot.appendingPathComponent("auto.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let digest = try Data(contentsOf: file).sha256
        let taskID = UUID()
        let tool = FilesEditTool(
            service: fixture.service,
            space: .work,
            recoveryStore: fixture.store,
            taskID: taskID
        )
        let args = #"{"path":"\#(file.path)","expected_sha256":"\#(digest)","old_text":"old","new_text":"new"}"#
        let tools: [String: any DispatcherTool] = ["files_edit": tool]
        let policy = PermissionPolicy(
            mode: .workspaceWrite,
            fileAreaPolicy: FileAreaPolicy(
                service: fixture.service,
                defaultWriteRoots: [fixture.service.workspaceRoot]
            )
        )
        let call = ToolCallRaw(id: "edit", name: "files_edit", argumentsJSON: args)
        let scope = TaskExecutionScope.make(
            space: .work,
            sessionID: UUID(),
            runID: taskID,
            parentRunID: nil,
            workspaceID: UUID(),
            workspacePath: fixture.service.workspaceRoot.path,
            readRoots: [fixture.service.workspaceRoot],
            writeRoots: [fixture.service.workspaceRoot],
            artifactRoots: [fixture.service.workspaceRoot],
            mode: .workspaceWrite,
            autoReviewEnabled: true,
            policyVersion: AutoReviewService.ruleVersion,
            userRequest: "Update the notes file."
        )
        #expect(DispatcherEngine.confirmationRequirement(
            call,
            toolsByName: tools,
            authorizedKeys: [],
            permissionPolicy: policy,
            taskScope: scope.withAutoReviewEnabled(false)
        ) == nil)
        let normal = try #require(DispatcherEngine.confirmationRequirement(
            call,
            toolsByName: tools,
            authorizedKeys: [],
            permissionPolicy: policy,
            workspaceAuthorizationActive: false,
            taskScope: scope
        ))
        #expect(normal.kind == .normal)
    }
}

@Suite("Model review parsing")
struct ModelReviewParsingTests {
    private func request(
        userRequest: String = "Please fix the project and run the tests.",
        scope: Bool = true
    ) -> AutoReviewRequest {
        let ws = FileManager.default.temporaryDirectory
        let taskScope = scope ? TaskExecutionScope.make(
            space: .work,
            sessionID: UUID(),
            runID: UUID(),
            parentRunID: nil,
            workspaceID: UUID(),
            workspacePath: ws.path,
            readRoots: [ws],
            writeRoots: [ws],
            artifactRoots: [ws],
            mode: .workspaceWrite,
            autoReviewEnabled: true,
            policyVersion: AutoReviewService.ruleVersion,
            userRequest: userRequest
        ) : nil
        return AutoReviewRequest(
            callId: "call-1",
            toolName: "python_execute",
            argumentsJSON: #"{"code":"print(1)"}"#,
            requirement: ConfirmationRequirement(kind: .normal, scope: .tool),
            route: .modelReviewable,
            sideEffectClass: .nonIdempotentWrite,
            taskScope: taskScope,
            evidence: ["execution_profile": "offline_artifacts"]
        )
    }

    @Test("structured approval must echo the call digest and cite the user request")
    func parseApproval() throws {
        let value = request()
        let json = """
        {"decision":"approve","reason_code":"matches_request","basis":"fix the project","call_digest":"\(value.callDigest)"}
        """
        #expect(ModelAutoReviewReviewer.parse(json, request: value) == .approve(reason: "matches_request"))
        let wrongDigest = """
        {"decision":"approve","reason_code":"matches_request","basis":"fix the project","call_digest":"wrong"}
        """
        #expect(ModelAutoReviewReviewer.parse(wrongDigest, request: value) == .manual(reason: "review_digest_mismatch"))
        let wrongBasis = """
        {"decision":"approve","reason_code":"matches_request","basis":"do something else","call_digest":"\(value.callDigest)"}
        """
        #expect(ModelAutoReviewReviewer.parse(wrongBasis, request: value) == .manual(reason: "review_basis_mismatch"))
    }

    @Test("Reviewer sends its decision contract as a system message and records malformed replies")
    func reviewMessageRoles() async throws {
        let value = request()
        let id = UUID().uuidString
        let body = #"{"choices":[{"message":{"role":"assistant","content":"missing decision"}}]}"#
        CompatibilityProtocol.register(id, replies: [.init(body: body)])
        defer { CompatibilityProtocol.remove(id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatibilityProtocol.self]
        configuration.httpAdditionalHeaders = ["X-AgRoom-Test-Fixture": id]
        let provider = CloudProvider(config: .init(name: "review fixture", endpoint: "https://review.invalid/v1", model: "fixture"),
                                     apiKey: "fixture", session: URLSession(configuration: configuration))
        let environment = AutoReviewEnvironment(space: .work, workspacePath: value.taskScope?.workspacePath ?? "")
        let decision = await ModelAutoReviewReviewer(provider: provider).reviewCandidate(value, environment: environment)
        #expect(decision == .manual(reason: "review_invalid_response"))
        let sent = try #require(CompatibilityProtocol.requests(id).first)
        let json = try #require(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let system = try #require(messages.first { $0["role"] as? String == "system" }?["content"] as? String)
        let user = try #require(messages.first { $0["role"] as? String == "user" }?["content"] as? String)
        #expect(system.contains("Return ONLY one JSON object") && !system.contains(value.callDigest))
        #expect(user.contains(value.callDigest) && !user.contains("Return ONLY one JSON object"))
        let budget = AutoReviewCallBudget(maxCalls: 0)
        let exhausted = await ModelAutoReviewReviewer(provider: provider, reviewBudget: budget).reviewCandidate(value, environment: environment)
        #expect(exhausted == .manual(reason: "review_budget_exhausted"))
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    @Test("model review decision cache stores only approve/reject")
    func decisionCache() async throws {
        let cache = AutoReviewDecisionCache()
        await cache.store(.approve(reason: "ok"), for: "call")
        #expect(await cache.decision(for: "call") == .approve(reason: "ok"))
        await cache.store(.manual(reason: "wait"), for: "manual")
        #expect(await cache.decision(for: "manual") == nil)
    }

    @Test("manual and reject do not require a user quote")
    func parseManual() throws {
        let value = request()
        let json = """
        {"decision":"manual","reason_code":"uncertain","basis":"","call_digest":"\(value.callDigest)"}
        """
        #expect(ModelAutoReviewReviewer.parse(json, request: value) == .manual(reason: "uncertain"))
    }
}

private extension Data {
    var sha256: String {
        ManagedTextSnapshot.digest(self)
    }
}
