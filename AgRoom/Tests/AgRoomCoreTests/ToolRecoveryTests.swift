import Foundation
import Testing
import AgRoomScriptIPC
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("ToolRecovery")
struct ToolRecoveryTests {
    private static let signed = ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"] != nil
    private static let hostBuild = ProcessInfo.processInfo.environment["AGROOM_TEST_HOST_BUILD"] == "1"
    private func fixture() throws -> (URL, FileAreaService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-recovery-\(UUID().uuidString)")
        let service = FileAreaService(baseDirectory: root, additionalRoots: [root])
        try service.ensureRoots()
        return (root, service)
    }
    private func json(_ args: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    }

    @Test("Pages reconstruct escaped Unicode and long lines within the model budget")
    func paginatedReads() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = service.workspaceRoot.appendingPathComponent("design.md")
        let text = String(repeating: "中文👨‍👩‍👧‍👦\"\\\n", count: 1800) + String(repeating: "超长行", count: 2500) + "\n§12 最后待核对点"
        try Data(text.utf8).write(to: file)
        let tool = FilesReadTool(service: service)
        var cursor: String?
        var full = ""
        var pages = 0
        var digest: String?
        repeat {
            var args: [String: Any] = ["path": file.path, "max_chars": 4000]
            if let cursor { args["cursor"] = cursor }
            let result = try await tool.execute(argumentsJSON: json(args))
            #expect(result.count <= 5500)
            let page = try JSONDecoder().decode(ManagedTextSnapshot.Page.self, from: Data(result.utf8))
            #expect(page.offset == full.count)
            #expect(page.total_characters == text.count)
            if let digest { #expect(page.sha256 == digest) } else { digest = page.sha256 }
            full += page.content
            cursor = page.next_cursor
            pages += 1
            try #require(pages < 100)
        } while cursor != nil
        #expect(pages > 1)
        #expect(full == text)
        #expect(digest == ManagedTextSnapshot.digest(Data(text.utf8)))
    }

    @Test("Read cursors reject file changes and reuse against another path")
    func cursorIdentity() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = service.workspaceRoot.appendingPathComponent("a.txt")
        let other = service.workspaceRoot.appendingPathComponent("b.txt")
        let text = String(repeating: "a", count: 6000)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try text.write(to: other, atomically: true, encoding: .utf8)
        let tool = FilesReadTool(service: service)
        let first = try await tool.execute(argumentsJSON: json(["path": file.path]))
        let page = try JSONDecoder().decode(ManagedTextSnapshot.Page.self, from: Data(first.utf8))
        let cursor = try #require(page.next_cursor)
        await #expect(throws: ToolExecutionFailure.self) {
            try await tool.execute(argumentsJSON: json(["path": other.path, "cursor": cursor]))
        }
        try "changed".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: ToolExecutionFailure.self) {
            try await tool.execute(argumentsJSON: json(["path": file.path, "cursor": cursor]))
        }
    }

    @Test("Existing source edits require exact content and preserve executable permissions")
    func sourceEdits() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = service.workspaceRoot.appendingPathComponent("script.sh")
        let original = "#!/bin/sh\necho old\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let args = try json(["path": file.path, "expected_sha256": ManagedTextSnapshot.digest(Data(original.utf8)), "old_text": "echo old", "new_text": "echo new"])
        let tool = FilesEditTool(service: service)
        let preview = try #require(FileChangePreviewBuilder.build(toolName: "files_edit", argumentsJSON: args, service: service))
        #expect(preview.kind == .overwrite)
        #expect(preview.diff?.contains("echo new") == true)
        let requirement = try #require(DispatcherEngine.confirmationRequirement(ToolCallRaw(id: "edit", name: "files_edit", argumentsJSON: args), toolsByName: ["files_edit": tool], authorizedKeys: []))
        // 编辑按文件获得「本轮允许」；内容仍由 expected_sha256 每次复核。
        #expect(requirement.kind == .normal)
        #expect(requirement.roundKey != nil)
        #expect(requirement.hardReason == nil)
        _ = try await tool.execute(argumentsJSON: args)
        #expect(try String(contentsOf: file, encoding: .utf8) == "#!/bin/sh\necho new\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        await #expect(throws: ToolExecutionFailure.self) { try await tool.execute(argumentsJSON: args) }
        #expect(try service.entries(at: service.workspaceRoot.path).filter { $0.name.hasPrefix("script") }.count == 1)
    }

    @Test("Edits reject ambiguous/overlapping matches, links and other-space targets")
    func editGuards() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = service.workspaceRoot.appendingPathComponent("a.txt")
        try "aaa".write(to: file, atomically: true, encoding: .utf8)
        let tool = FilesEditTool(service: service)
        let digest = ManagedTextSnapshot.digest(Data("aaa".utf8))
        for old in ["aa", "missing", ""] {
            await #expect(throws: ToolExecutionFailure.self) {
                try await tool.execute(argumentsJSON: json(["path": file.path, "expected_sha256": digest, "old_text": old, "new_text": "new"]))
            }
        }
        let link = service.workspaceRoot.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        await #expect(throws: (any Error).self) {
            try await tool.execute(argumentsJSON: json(["path": link.path, "expected_sha256": digest, "old_text": "aaa", "new_text": "new"]))
        }
        let other = service.privateRoot.appendingPathComponent("other.txt")
        try "aaa".write(to: other, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) {
            try await tool.execute(argumentsJSON: json(["path": other.path, "expected_sha256": digest, "old_text": "aaa", "new_text": "new"]))
        }
        let policy = PermissionPolicy(mode: .readOnly, fileAreaPolicy: FileAreaPolicy(service: service, defaultWriteRoots: []))
        guard case .deny = policy.assess(toolName: "files_edit", permissionClass: .workspaceMutation, argumentsJSON: "{}", skillWorkspace: nil) else {
            Issue.record("Read-only mode must reject edits"); return
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "aaa")
    }

    @Test("Preparation diagnostics distinguish launch, timeout and protocol errors without leaking paths")
    func diagnosticMapping() throws {
        for (outcome, code) in [(ChildProcessOutcome.launchFailed("private-path-secret"), ScriptRunnerFailure.Code.runnerLaunchFailed), (.timedOut, .preparationTimeout)] {
            let result = ChildProcessResult(outcome: outcome, stdout: "", stderr: "private-path-secret", duration: 0)
            let error = try #require(ScriptAppSandbox.preparationFailure(result))
            #expect(error.code == code.rawValue)
            #expect(!error.localizedDescription.contains("private-path-secret"))
        }
        let detail = ScriptRunnerFailure(.protocolMismatch, stage: .request)
        let result = ChildProcessResult(outcome: .exited(78), stdout: "", stderr: String(decoding: try JSONEncoder().encode(detail), as: UTF8.self), duration: 0)
        #expect(ScriptAppSandbox.preparationFailure(result)?.code == "protocolMismatch")
        #expect(!ScriptIsolationError.invalidScope.localizedDescription.contains("Select a smaller workspace"))
    }

    @Test("Signed runner reports protocol and bookmark failures before executing code", .enabled(if: Self.signed))
    func liveDiagnostics() async throws {
        let runner = try ScriptAppSandboxTests().runner()
        var message = ScriptRunnerRequest(phase: .prepareScopes, helperIdentifier: runner.identifier, allowsNetwork: false,
            bookmarks: [], executable: "", arguments: [], directory: "/", environment: [:])
        message.version = 0
        let mismatch = await ChildProcessRunner.run(ChildProcessRequest(executable: runner.executable, arguments: [],
            standardInputData: try JSONEncoder().encode(message), timeout: 5, outputLimit: 4096, label: "protocol-test"))
        #expect(ScriptAppSandbox.preparationFailure(mismatch)?.code == "protocolMismatch")
        message.version = ScriptRunnerRequest.currentVersion
        message.bookmarks = [ScriptRunnerBookmark(data: Data([0, 1]), path: "/must-not-be-disclosed",
            identity: .init(device: 0, inode: 0, kind: 0))]
        let invalid = await ChildProcessRunner.run(ChildProcessRequest(executable: runner.executable, arguments: [],
            standardInputData: try JSONEncoder().encode(message), timeout: 5, outputLimit: 4096, label: "bookmark-test"))
        #expect(ScriptAppSandbox.preparationFailure(invalid)?.code == "bookmarkResolutionFailed")
        #expect(!invalid.stderr.contains("must-not-be-disclosed"))
    }

    @Test("Minimal and workspace probes use fixed commands and reveal no directory contents", .enabled(if: Self.signed))
    func liveHealthCheck() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = service.workspaceRoot.appendingPathComponent("private-name-do-not-disclose.txt")
        try "fixture".write(to: file, atomically: true, encoding: .utf8)
        let tool = SandboxDiagnoseTool(space: .work, workspaceRoot: service.workspaceRoot.path,
            runner: { _ in try ScriptAppSandboxTests().runner() })
        let result = try await tool.execute(argumentsJSON: #"{"check_workspace":true}"#)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let checks = try #require(object["checks"] as? [[String: String]])
        #expect(checks.count == 4)
        #expect(checks.allSatisfy { $0["status"] == "passed" })
        #expect(!result.contains("private-name-do-not-disclose"))
        #expect(object["sandbox_builds_supported"] as? Bool == false)
    }

    @Test("Host builds use fixed argv and cannot bypass full-access and hard confirmation")
    func hostBuildPolicy() throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// fixture".write(to: service.workspaceRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let tool = ProjectBuildTool(service: service, space: .work, workspaceRoot: service.workspaceRoot.path, cacheRoot: root)
        let args: [String: Any] = ["action": "swift_test"]
        let spec = try tool.request(args: args, cache: root.appendingPathComponent("cache"), temporary: root.appendingPathComponent("run"))
        #expect(spec.executable.path == "/usr/bin/swift")
        #expect(spec.arguments.first == "test")
        #expect(spec.environment?["AGROOM_DATABASE_PATH"] == nil)
        let serialized = try json(args)
        let pending = try #require(DispatcherEngine.confirmationRequirement(ToolCallRaw(id: "build", name: "project_build", argumentsJSON: serialized), toolsByName: ["project_build": tool], authorizedKeys: []))
        #expect(pending.kind == .hard)
        #expect(pending.roundKey == nil)
        #expect(pending.hardReason == .hostExecution)
        let policy = PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: FileAreaPolicy(service: service, defaultWriteRoots: []))
        guard case .deny = policy.assess(toolName: "project_build", permissionClass: .codeExecution, argumentsJSON: "{}", skillWorkspace: nil) else {
            Issue.record("Workspace-write must not enable a host build"); return
        }
        #expect(throws: ToolExecutionFailure.self) { try tool.request(args: ["action": "swift_build", "script": "touch escaped"], cache: root, temporary: root) }
        #expect(throws: (any Error).self) { try tool.request(args: ["action": "swift_build", "directory": "../outside"], cache: root, temporary: root) }
    }

    @Test("A real dependency-free Swift project builds through the explicit host entry", .enabled(if: Self.hostBuild))
    func realHostBuild() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = service.workspaceRoot
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Probe\", targets: [.target(name: \"Probe\")])\n"
            .write(to: project.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let sources = project.appendingPathComponent("Sources/Probe")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "public func answer() -> Int { 42 }\n".write(to: sources.appendingPathComponent("Probe.swift"), atomically: true, encoding: .utf8)
        let tool = ProjectBuildTool(service: service, space: .work, workspaceRoot: project.path, cacheRoot: root.appendingPathComponent("cache"))
        let result = try await tool.execute(argumentsJSON: #"{"action":"swift_build"}"#)
        #expect(result.contains("Host build passed; exit code: 0"))
        let logs = try FileManager.default.subpathsOfDirectory(atPath: service.defaultChatRoot(for: .work).path)
        #expect(logs.contains { $0.hasSuffix("build.log") })
    }
}
