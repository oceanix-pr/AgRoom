import Testing
import Foundation
import GRDB
@testable import AgRoomCore

@Suite("PermissionPolicy")
struct PermissionPolicyTests {

    // MARK: - Fixtures

    private func makeWorkspace() throws -> (base: URL, workspace: URL, policy: FileAreaPolicy) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-permission-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let service = FileAreaService(baseDirectory: base)
        let policy = FileAreaPolicy(service: service, defaultWriteRoots: [workspace])
        return (base, workspace, policy)
    }

    private func pathJSON(_ path: String) -> String {
        #"{"path":"\#(path)"}"#
    }

    // MARK: - Mode ceilings

    @Test("read-only allows reads but denies mutations, code and external effects")
    func readOnlyCeiling() throws {
        let fixture = try makeWorkspace()
        let policy = PermissionPolicy(
            mode: .readOnly,
            fileAreaPolicy: fixture.policy
        )
        let target = pathJSON(fixture.workspace.appendingPathComponent("a.txt").path)

        #expect(policy.assess(
            toolName: "files_read",
            permissionClass: .readOnly,
            argumentsJSON: target,
            skillWorkspace: nil,
        ) == .allow)

        guard case .deny(let mutation) = policy.assess(
            toolName: "files_write",
            permissionClass: .workspaceMutation,
            argumentsJSON: target,
            skillWorkspace: nil,
        ) else {
            Issue.record("read-only must deny workspace mutations")
            return
        }
        #expect(mutation.reason == .readOnlyMode)

        guard case .deny = policy.assess(
            toolName: "shell_run",
            permissionClass: .codeExecution,
            argumentsJSON: #"{"script":"echo hi"}"#,
            skillWorkspace: nil,
        ) else {
            Issue.record("read-only must deny code execution")
            return
        }

        guard case .deny(let external) = policy.assess(
            toolName: "mail_send",
            permissionClass: .externalEffect,
            argumentsJSON: #"{"to":"a@example.com"}"#,
            skillWorkspace: nil,
        ) else {
            Issue.record("read-only must deny external effects")
            return
        }
        #expect(external.reason == .externalEffectBlocked)
    }

    @Test("workspace-write allows only in-scope file work and blocks code execution")
    func workspaceWriteCeiling() throws {
        let fixture = try makeWorkspace()
        let policy = PermissionPolicy(
            mode: .workspaceWrite,
            fileAreaPolicy: fixture.policy
        )
        let inside = pathJSON(fixture.workspace.appendingPathComponent("a.txt").path)
        let outside = pathJSON(fixture.base.appendingPathComponent("outside.txt").path)

        #expect(policy.assess(
            toolName: "files_write",
            permissionClass: .workspaceMutation,
            argumentsJSON: inside,
            skillWorkspace: nil,
        ) == .allow)
        #expect(policy.assess(
            toolName: "files_delete",
            permissionClass: .workspaceMutation,
            argumentsJSON: inside,
            skillWorkspace: nil,
        ) == .allow)

        guard case .deny(let outsideDenial) = policy.assess(
            toolName: "files_write",
            permissionClass: .workspaceMutation,
            argumentsJSON: outside,
            skillWorkspace: nil,
        ) else {
            Issue.record("workspace-write must deny writes outside the workspace")
            return
        }
        #expect(outsideDenial.reason == .outsideWorkspace)

        guard case .deny(let code) = policy.assess(
            toolName: "python_execute",
            permissionClass: .codeExecution,
            argumentsJSON: #"{"code":"print(1)"}"#,
            skillWorkspace: nil,
        ) else {
            Issue.record("workspace-write must deny code execution")
            return
        }
        #expect(code.reason == .codeExecutionBlocked)

        #expect(policy.assess(
            toolName: "mail_send",
            permissionClass: .externalEffect,
            argumentsJSON: #"{"to":"a@example.com"}"#,
            skillWorkspace: nil,
        ) == .requireApproval)
    }

    @Test("daemon-style policy keeps workspace writes behind confirmation")
    func workspaceWriteWithoutAutoApproval() throws {
        let fixture = try makeWorkspace()
        let policy = PermissionPolicy(
            mode: .workspaceWrite,
            fileAreaPolicy: fixture.policy
        )
        #expect(policy.assess(
            toolName: "files_write",
            permissionClass: .workspaceMutation,
            argumentsJSON: pathJSON(fixture.workspace.appendingPathComponent("a.txt").path),
            skillWorkspace: nil,
        ) == .allow)
    }

    @Test("full access widens file roots but keeps managed-root fencing")
    func fullAccessCeiling() throws {
        let fixture = try makeWorkspace()
        let service = FileAreaService(baseDirectory: fixture.base)
        let widened = FileAreaPolicy(
            service: service,
            defaultWriteRoots: [fixture.workspace, service.filesRoot]
        )
        let policy = PermissionPolicy(
            mode: .dangerFullAccess,
            fileAreaPolicy: widened,
        )

        #expect(policy.assess(
            toolName: "files_write",
            permissionClass: .workspaceMutation,
            argumentsJSON: pathJSON(service.filesRoot.appendingPathComponent("note.md").path),
            skillWorkspace: nil,
        ) == .allow)
        #expect(policy.assess(
            toolName: "shell_run",
            permissionClass: .codeExecution,
            argumentsJSON: #"{"script":"echo hi"}"#,
            skillWorkspace: nil,
        ) == .allow)

        guard case .deny = policy.assess(
            toolName: "files_write",
            permissionClass: .workspaceMutation,
            argumentsJSON: pathJSON(fixture.base.appendingPathComponent("outside.txt").path),
            skillWorkspace: nil,
        ) else {
            Issue.record("full access must still deny paths outside managed roots")
            return
        }
    }

    @Test("skill scope narrows the session scope instead of replacing it")
    func skillScopeIsIntersection() throws {
        let fixture = try makeWorkspace()
        let skillRoot = fixture.base.appendingPathComponent("files/skill-area", isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        let policy = FileAreaPolicy(
            service: fixture.policy.service,
            skillWorkspaces: ["narrow": skillRoot.path],
            defaultWriteRoots: [fixture.workspace]
        )
        let permission = PermissionPolicy(
            mode: .workspaceWrite,
            fileAreaPolicy: policy,
        )

        let outsideSession = pathJSON(skillRoot.appendingPathComponent("a.txt").path)
        guard case .deny(let denial) = permission.assess(
            toolName: "files_write",
            permissionClass: .workspaceMutation,
            argumentsJSON: outsideSession,
            skillWorkspace: skillRoot.path,
            writeTargets: [skillRoot.appendingPathComponent("a.txt").path],
            skillName: "narrow"
        ) else {
            Issue.record("a skill must not widen the session write scope")
            return
        }
        #expect(denial.reason == .outsideWorkspace)
    }

    @Test("invalid skill workspace fails closed instead of falling back")
    func invalidSkillWorkspaceFailsClosed() throws {
        let fixture = try makeWorkspace()
        let policy = PermissionPolicy(
            mode: .workspaceWrite,
            fileAreaPolicy: fixture.policy
        )
        let target = fixture.workspace.appendingPathComponent("a.txt").path
        guard case .deny(let denial) = policy.assess(
            toolName: "files_write",
            permissionClass: .workspaceMutation,
            argumentsJSON: pathJSON(target),
            skillWorkspace: nil,
            writeTargets: [target],
            skillName: "broken",
            skillWorkspaceError: "workspace-folder is outside the current space"
        ) else {
            Issue.record("an invalid skill workspace must block writes")
            return
        }
        #expect(denial.reason == .invalidSkillWorkspace)
    }

    @Test("another space's exclusive directory is blocked even in a widened scope")
    func crossSpaceWriteBlocked() throws {
        let fixture = try makeWorkspace()
        let service = FileAreaService(baseDirectory: fixture.base)
        let widened = FileAreaPolicy(
            service: service,
            space: .work,
            defaultWriteRoots: [service.filesRoot, service.privateRoot, service.workspaceRoot],
            spaceWriteRoots: [service.filesRoot, service.privateRoot, service.workspaceRoot]
        )
        let target = service.privateRoot.appendingPathComponent("leak.txt").path
        let violation = widened.writeViolation(targets: [target])
        #expect(violation?.contains("another space") == true)
    }

    @Test("subtask scope further restricts an allowed session write")
    func subtaskScopeNarrows() throws {
        let fixture = try makeWorkspace()
        let subtaskRoot = fixture.workspace.appendingPathComponent("subtask", isDirectory: true)
        try FileManager.default.createDirectory(at: subtaskRoot, withIntermediateDirectories: true)
        let policy = FileAreaPolicy(
            service: fixture.policy.service,
            defaultWriteRoots: [fixture.workspace]
        )
        let outsideSubtask = fixture.workspace.appendingPathComponent("other.txt").path
        #expect(policy.writeViolation(
            targets: [outsideSubtask],
            subtaskRoots: [subtaskRoot]
        ) != nil)
        let inside = subtaskRoot.appendingPathComponent("ok.txt").path
        #expect(policy.writeViolation(targets: [inside], subtaskRoots: [subtaskRoot]) == nil)
    }

    // MARK: - Engine confirmation integration

    @Test("confirmation verdict is layered under the mode ceiling")
    func confirmationRequirementUsesMode() throws {
        let fixture = try makeWorkspace()
        let inside = pathJSON(fixture.workspace.appendingPathComponent("a.txt").path)
        let outside = pathJSON(fixture.base.appendingPathComponent("outside.txt").path)
        let call = ToolCallRaw(id: "call-1", name: "files_write", argumentsJSON: inside)
        let tool = FakeTool(name: "files_write", permissionClass: .workspaceMutation, autoReviewEligible: true)
        let tools: [String: any DispatcherTool] = ["files_write": tool]

        let workspacePolicy = PermissionPolicy(
            mode: .workspaceWrite,
            fileAreaPolicy: fixture.policy
        )
        // 自动审核关闭时，工作区内写仍需确认；自动批准由统一审批器决定。
        let normal = try #require(DispatcherEngine.confirmationRequirement(
            call,
            toolsByName: tools,
            authorizedKeys: [],
            permissionPolicy: workspacePolicy
        ))
        #expect(normal.kind == .normal)

        // 即使关闭模型审核，有效的任务写范围也覆盖同一调用。
        let scope = TaskExecutionScope.make(
            space: .work,
            sessionID: UUID(),
            runID: UUID(),
            parentRunID: nil,
            workspaceID: UUID(),
            workspacePath: fixture.workspace.path,
            readRoots: [fixture.workspace],
            writeRoots: [fixture.workspace],
            artifactRoots: [fixture.workspace],
            mode: .workspaceWrite,
            autoReviewEnabled: true,
            policyVersion: AutoReviewService.ruleVersion,
            userRequest: "Update the project files."
        )
        #expect(DispatcherEngine.confirmationRequirement(
            call,
            toolsByName: tools,
            authorizedKeys: [],
            permissionPolicy: workspacePolicy,
            taskScope: scope.withAutoReviewEnabled(false)
        ) == nil)

        let outsideCall = ToolCallRaw(id: "call-2", name: "files_write", argumentsJSON: outside)
        #expect(DispatcherEngine.confirmationRequirement(
            outsideCall,
            toolsByName: tools,
            authorizedKeys: [],
            permissionPolicy: workspacePolicy
        ) == nil)

        let readOnlyPolicy = PermissionPolicy(
            mode: .readOnly,
            fileAreaPolicy: fixture.policy
        )
        #expect(DispatcherEngine.confirmationRequirement(
            call,
            toolsByName: tools,
            authorizedKeys: [],
            permissionPolicy: readOnlyPolicy
        ) == nil)
    }

    @Test("workspace-write forces approval for external effects even when the tool asks nothing")
    func externalEffectGetsConfirmation() throws {
        let fixture = try makeWorkspace()
        let call = ToolCallRaw(id: "call-3", name: "mail_mark", argumentsJSON: #"{"id":"1"}"#)
        let tool = FakeTool(name: "mail_mark", permissionClass: .externalEffect, autoReviewEligible: false)
        let tools: [String: any DispatcherTool] = ["mail_mark": tool]
        let policy = PermissionPolicy(
            mode: .workspaceWrite,
            fileAreaPolicy: fixture.policy
        )
        let requirement = DispatcherEngine.confirmationRequirement(
            call,
            toolsByName: tools,
            authorizedKeys: [],
            permissionPolicy: policy
        )
        #expect(requirement?.kind == .normal)
    }

    @Test("hard confirmation wins only when the mode permits the call")
    func hardConfirmationLayering() throws {
        let fixture = try makeWorkspace()
        let call = ToolCallRaw(id: "call-4", name: "mail_delete", argumentsJSON: #"{"id":"1"}"#)
        let tool = FakeTool(
            name: "mail_delete",
            permissionClass: .destructive,
            requiresHardConfirmation: true
        )
        let tools: [String: any DispatcherTool] = ["mail_delete": tool]
        let workspacePolicy = PermissionPolicy(
            mode: .workspaceWrite,
            fileAreaPolicy: fixture.policy
        )
        #expect(DispatcherEngine.confirmationRequirement(
            call,
            toolsByName: tools,
            authorizedKeys: [],
            permissionPolicy: workspacePolicy
        )?.kind == .hard)

        let readOnlyPolicy = PermissionPolicy(
            mode: .readOnly,
            fileAreaPolicy: fixture.policy
        )
        #expect(DispatcherEngine.confirmationRequirement(
            call,
            toolsByName: tools,
            authorizedKeys: [],
            permissionPolicy: readOnlyPolicy
        ) == nil)
    }

    @Test("shell read-only classification is reused by the mode policy")
    func shellReadOnlyClassification() throws {
        let fixture = try makeWorkspace()
        let tool = ShellRunTool(
            defaultWorkingDirectory: fixture.workspace.path,
            workspaceRoot: fixture.workspace.path,
            space: .work
        )
        #expect(tool.permissionClass(argumentsJSON: #"{"script":"ls"}"#) == .readOnly)
        #expect(tool.permissionClass(argumentsJSON: #"{"script":"rm -rf build"}"#) == .workspaceMutation)
        #expect(tool.permissionClass(argumentsJSON: #"{"script":"ls","working_directory":"/tmp"}"#) == .workspaceMutation)
    }

    @Test("permission mode ordering and session default")
    func modeOrderingAndSessionDefault() throws {
        #expect(PermissionMode.readOnly < .workspaceWrite)
        #expect(PermissionMode.workspaceWrite < .dangerFullAccess)
        #expect(PermissionMode.dangerFullAccess.restricted(to: .workspaceWrite) == .workspaceWrite)
        #expect(PermissionMode.readOnly.restricted(to: .workspaceWrite) == .readOnly)

        let session = ChatSession()
        #expect(session.permissionMode == .workspaceWrite)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)
        #expect(decoded.permissionMode == .workspaceWrite)
    }

    @Test("legacy session JSON without permissionMode decodes to full access")
    func legacySessionDecodesToFullAccess() throws {
        let session = ChatSession()
        let data = try JSONEncoder().encode(session)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("session JSON must be an object")
            return
        }
        object.removeValue(forKey: "permissionMode")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: legacy)
        #expect(decoded.permissionMode == .dangerFullAccess)
    }

    @Test("SQL permission classification uses the space database's prepared statement")
    func sqlPermissionClassification() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("permission-sql-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE t(value INTEGER)") }
        let tool = SQLQueryTool(
            workbench: DatabaseWorkbench(),
            databasePath: path.path
        )
        #expect(tool.permissionClass(argumentsJSON: #"{"sql":"SELECT 1"}"#) == .readOnly)
        #expect(tool.permissionClass(argumentsJSON: #"{"sql":"EXPLAIN SELECT 1"}"#) == .readOnly)
        #expect(tool.permissionClass(argumentsJSON: #"{"sql":"WITH x AS (SELECT 1) SELECT * FROM x"}"#) == .readOnly)
        #expect(tool.permissionClass(argumentsJSON: #"{"sql":"WITH x AS (SELECT 1) DELETE FROM t"}"#) == .externalEffect)
        #expect(tool.permissionClass(argumentsJSON: #"{"sql":"PRAGMA journal_mode=WAL"}"#) == .externalEffect)
        #expect(tool.permissionClass(argumentsJSON: #"{"sql":"SELECT 1; DELETE FROM t"}"#) == .externalEffect)
    }

    @Test("session permission mode round-trips through SessionService")
    func sessionPermissionPersistence() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = SessionService(databaseQueue: queue)
        var session = ChatSession(title: "mode")
        session.permissionMode = .readOnly
        session.messages = [ChatMessage(role: .user, content: "hi")]
        try await service.save(session)

        let summaries = try await service.getSummaries()
        #expect(summaries.first?.permissionMode == .readOnly)

        try await service.setPermissionMode(id: session.id, mode: .dangerFullAccess)
        let updated = try await service.getSummaries()
        #expect(updated.first?.permissionMode == .dangerFullAccess)
    }
}

// MARK: - Fake Tool

private struct FakeTool: DispatcherTool {
    let name: String
    let permissionClass: PermissionClass
    let autoReviewEligible: Bool
    let requiresHardConfirmation: Bool

    init(
        name: String,
        permissionClass: PermissionClass,
        autoReviewEligible: Bool = false,
        requiresHardConfirmation: Bool = false
    ) {
        self.name = name
        self.permissionClass = permissionClass
        self.autoReviewEligible = autoReviewEligible
        self.requiresHardConfirmation = requiresHardConfirmation
    }

    var definition: ToolDefinition {
        ToolDefinition(name: name, description: "fake", parametersSchemaJSON: #"{"type":"object"}"#)
    }

    var requiresConfirmation: Bool { true }

    func requiresHardConfirmation(argumentsJSON: String) -> Bool {
        requiresHardConfirmation
    }

    func approvalRoute(argumentsJSON: String) -> ApprovalRoute {
        autoReviewEligible ? .deterministic : .manualOnly
    }

    func writeTargets(argumentsJSON: String) -> [String] {
        [ToolArguments.string(ToolArguments.parse(argumentsJSON), "path")].filter { !$0.isEmpty }
    }

    func execute(argumentsJSON: String) async throws -> String { "ok" }
}
