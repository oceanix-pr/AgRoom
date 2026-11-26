import Foundation
import Testing
import AgRoomScriptIPC
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("ShellSandbox")
struct ShellSandboxTests {
    private static let signedApp = ScriptAppSandboxTests.hasSignedHelpers

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func args(_ script: String, mode: String? = nil, directory: URL? = nil) throws -> String {
        var values = ["script": script]
        if let mode { values["execution_mode"] = mode }
        if let directory { values["working_directory"] = directory.path }
        return String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }

    private func command(_ program: String, _ arguments: [String] = [], _ extra: [String: Any] = [:]) throws -> String {
        var values = extra
        values["program"] = program
        values["arguments"] = arguments
        return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test("Numeric sed reads and recursive grep preserve output and use read-only workspace grants")
    func codingReadCommands() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main"), reference = root.appendingPathComponent("reference")
        for folder in [main, reference] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let file = reference.appendingPathComponent("file with space.swift")
        try Data("first\nneedle 123\nlast\n".utf8).write(to: file)
        try Data("needle 456\n".utf8).write(to: reference.appendingPathComponent("skip.md"))
        let outside = root.appendingPathComponent("outside.swift")
        try Data("needle 999\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: reference.appendingPathComponent("link.swift"), withDestinationURL: outside)

        let service = FileAreaService(baseDirectory: root, scopedRoots: [main, reference])
        let backend: ShellRunTool.SandboxBackend = Self.signedApp
            ? .injected(try ScriptAppSandboxTests().runner()) : .compatibility
        let tool = ShellRunTool(defaultWorkingDirectory: main.path, workspaceRoot: main.path,
                                sandboxBackend: backend, fileAreaService: service)
        let area = FileAreaPolicy(service: service, defaultWriteRoots: [main, reference])
        let policy = PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: area)
        let forms = [
            try command("sed", ["-n", "2p", file.path]),
            try command("sed", ["-n", "1,2p", file.path]),
            try command("grep", ["-R", "-n", "--include=*.swift", "needle", reference.path]),
            try command("grep", ["-rE", "--include", "*.swift", "needle [0-9]+", reference.path]),
            try command("grep", ["-R", "-n", "-E", "--include=*.swift", "needle [0-9]+", reference.path]),
            try command("grep", ["-R", "-n", "needle", reference.path])
        ]
        for (index, json) in forms.enumerated() {
            let engine = DispatcherEngine(tools: [tool], systemPrompt: "fixture", fileAreaPolicy: area, permissionPolicy: policy)
            #expect(tool.sideEffectClass(argumentsJSON: json) == .readOnly)
            let call = ToolCallRaw(id: "read-\(index)", name: "shell_run", argumentsJSON: json)
            guard case .finished(let output, _, let trace, _, _, _, _) = try await engine.executeCommand(call) else {
                Issue.record("Workspace reads must finish without a confirmation card"); continue
            }
            #expect(trace.first?.succeeded == true && output.contains("needle 123"))
            #expect(!output.contains("needle 999"))
            if index >= 2 && index <= 4 { #expect(!output.contains("skip.md")) }
            if index == 0 { #expect(!output.contains("first") && !output.contains("last")) }
            if index == 1 { #expect(output.contains("first") && !output.contains("last")) }
            if index == 5 { #expect(output.contains("skip.md")) }
        }
        for json in [try command("sed", ["-n", "1p", outside.path]),
                     try command("sed", ["-n", "1p;2p", file.path]),
                     try command("grep", ["-R", "-S", "needle", reference.path]),
                     try command("grep", ["-f", outside.path, file.path])] {
            #expect(throws: ToolExecutionFailure.self) { try tool.validateArguments(argumentsJSON: json) }
        }
    }

    @Test("Common Git display options skip confirmation without weakening path or driver checks")
    func commonReadOnlyGit() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path)
        let policy = PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: nil)
        for argv in [["status", "--porcelain"], ["diff", "--stat"], ["diff", "--cached", "--name-only"],
                     ["log", "--oneline", "-5"], ["show", "HEAD", "--", "Sources/a.swift"],
                     ["diff", "--", "--output=filename"]] {
            let json = try command("git", argv)
            #expect(tool.permissionClass(argumentsJSON: json) == .readOnly)
            #expect(DispatcherEngine.confirmationRequirement(ToolCallRaw(id: "read", name: "shell_run", argumentsJSON: json),
                toolsByName: ["shell_run": tool], authorizedKeys: [], permissionPolicy: policy) == nil)
            let parsed = try #require(ShellRunTool.readOnlyCommand(ToolArguments.parse(json)))
            let executed = parsed.injectedPrefix + parsed.arguments + parsed.injectedSuffix
            if let separator = executed.firstIndex(of: "--") {
                #expect(try #require(executed.firstIndex(of: "--no-ext-diff")) < separator)
                #expect(try #require(executed.firstIndex(of: "--no-textconv")) < separator)
            }
        }
        for argv in [["diff", "--output=changed.txt"], ["diff", "--ext-diff"], ["log", "--unknown"],
                     ["-c", "diff.external=evil", "diff"], ["diff", "--", "../outside"]] {
            let json = try command("git", argv)
            #expect(!tool.isReadOnlyCommand(argumentsJSON: json))
            #expect(tool.approvalRoute(argumentsJSON: json) == .manualOnly)
        }
    }

    @Test("Ripgrep file listing and literal filters preserve config hardening and reject execution or extra file inputs")
    func ripgrepQueries() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for argv in [["--files"], ["--files", "--hidden", "-g", "*.swift", "."],
                     ["-n", "--glob=*.swift", "foo$", "."], ["-n", "-efoo", "--regexp", "bar", "."],
                     ["--type", "swift", "--max-count", "10", "needle"], ["needle", "-A2", "."]] {
            let parsed = try #require(ShellReadOnlyCommand.parseRipgrep(executable: "/trusted/rg", arguments: argv))
            #expect(parsed.injectedPrefix == ["--no-config"])
            #expect(parsed.isInside(workspace: root, directory: root))
            #expect(parsed.arguments == argv)
        }
        let files = try #require(ShellReadOnlyCommand.parseRipgrep(executable: "/trusted/rg", arguments: ["--files"]))
        #expect(files.paths == ["."] && files.injectedSuffix == ["."])
        let outside = try #require(ShellReadOnlyCommand.parseRipgrep(executable: "/trusted/rg", arguments: ["--files", "../"]))
        #expect(!outside.isInside(workspace: root, directory: root))
        for argv in [["--pre", "sh", "x", "."], ["--pre=sh", "x", "."], ["--search-zip", "x", "."],
                     ["--follow", "x", "."], ["-L", "x", "."], ["--ignore-file", "secret", "x", "."],
                     ["-f", "secret", "."], ["--glob"], ["--max-count", "-1", "x", "."], ["--files", "-e", "x"]] {
            #expect(ShellReadOnlyCommand.parseRipgrep(executable: "/trusted/rg", arguments: argv) == nil)
        }
        let configured = ShellReadOnlyCommand.resolvedRipgrepExecutable()
        if configured.isEmpty {
            #expect(ShellRunTool.resolveExecutable("rg", workingDirectory: root) == nil)
        } else {
            for program in ["rg", configured] {
                let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path)
                let json = try command(program, ["--files", "."])
                #expect(tool.permissionClass(argumentsJSON: json) == .readOnly)
                #expect(ShellRunTool.resolveExecutable(program, workingDirectory: root)?.path == configured)
            }
        }
    }

    @Test("Executable aliases use the same canonical identity as execution and reject a same-name replacement")
    func canonicalExecutable() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("ls")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: "/bin/ls"))
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path)
        let json = try command(alias.path, ["."])
        #expect(tool.permissionClass(argumentsJSON: json) == .readOnly)
        let read = try #require(ShellRunTool.readOnlyCommand(ToolArguments.parse(json)))
        #expect(read.executable == ShellRunTool.resolveExecutable(alias.path, workingDirectory: root)?.path)
        try FileManager.default.removeItem(at: alias)
        try Data("#!/bin/sh\ntouch changed\n".utf8).write(to: alias)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: alias.path)
        #expect(!tool.isReadOnlyCommand(argumentsJSON: json))
        #expect(tool.approvalRoute(argumentsJSON: json) == .manualOnly)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("changed").path))
    }

    @Test("Invalid Shell calls finish as failures without an approval card or side effects")
    func invalidCallsDoNotAsk() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileAreaService(baseDirectory: root, additionalRoots: [root]).scoped(to: [root])
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path, fileAreaService: service)
        for json in [try args("ls"), try command("ls")] {
            try tool.validateArguments(argumentsJSON: json)
        }
        for json in ["{}", #"{"program":"ls"}"#, #"{"arguments":[]}"#, #"{"script":"ls","arguments":[]}"#,
                     try args("touch changed; ls"), try args("ls | head"), try args("ls", mode: "unknown"),
                     try args("ls", mode: "host"), try command("agroom-command-that-does-not-exist"),
                     try command("touch", ["changed"], ["script": "touch changed"]),
                     try command("ls", [], ["working_directory": root.appendingPathComponent("missing").path]),
                     try command("ls", [], ["output_mode": "overwrite"])] {
            let engine = DispatcherEngine(tools: [tool], systemPrompt: "fixture",
                permissionPolicy: PermissionPolicy(mode: .dangerFullAccess, fileAreaPolicy: nil))
            let outcome = try await engine.executeCommand(ToolCallRaw(id: "invalid", name: "shell_run", argumentsJSON: json))
            guard case .finished(let text, _, let trace, _, _, _, _) = outcome else {
                Issue.record("Invalid calls must not suspend for approval"); continue
            }
            #expect(text.contains("Nothing was executed"))
            #expect(trace.count == 1 && trace.first?.succeeded == false)
            #expect(engine.pendingApprovalID == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("changed").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".agroom-runs").path))
    }

    @Test("Valid writable and unrecognized commands still require approval, including output overwrite")
    func mutationsStillAsk() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path)
        let area = FileAreaPolicy(service: FileAreaService(baseDirectory: root, additionalRoots: [root]), defaultWriteRoots: [root])
        for json in [try command("mkdir", ["changed"]), try command("sh", ["-c", "pwd"]),
                     try command("ls", [], ["stdout_file": "output", "output_mode": "overwrite"])] {
            let engine = DispatcherEngine(tools: [tool], systemPrompt: "fixture", fileAreaPolicy: area,
                permissionPolicy: PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: area))
            guard case .needsConfirmation(_, _, _, let requirement) = try await engine.executeCommand(
                ToolCallRaw(id: "write", name: "shell_run", argumentsJSON: json)) else {
                Issue.record("Writable or unrecognized commands must still require approval"); continue
            }
            #expect(requirement.kind == .hard)
            #expect(requirement.hardReason == (json.contains("overwrite") ? .irreversible : .directoryWrite))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("changed").path))
    }

    @Test("Structured argv preserves literals, rejects ambiguous forms, and binds argument boundaries")
    func structuredArguments() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path,
            ruleStore: ShellApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json")), sandboxBackend: .compatibility)
        let literal = #"$(touch escaped); $HOME `pwd` \regex --key=value"#
        let output = try await tool.execute(argumentsJSON: command("printf", ["%s", literal]))
        #expect(output.contains(literal))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
        let approved = try command("printf", ["%s", "a b", "c"])
        #expect(tool.persistApprovalRule(argumentsJSON: approved))
        #expect(tool.isCoveredByPersistentRule(argumentsJSON: approved))
        let different = try command("printf", ["%s", "a", "b c"])
        #expect(!tool.isCoveredByPersistentRule(argumentsJSON: different))
        for invalid in [try command("touch", ["escaped"], ["script": "touch escaped"]),
                        try command("touch", ["escaped\0"]),
                        try command("touch", ["escaped"], ["execution_mode": "host"]),
                        #"{"program":"touch","arguments":[1]}"#] {
            await #expect(throws: (any Error).self) { try await tool.execute(argumentsJSON: invalid) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
        let grep = try command("grep", ["foo$", "a.txt"])
        #expect(tool.isReadOnlyCommand(argumentsJSON: grep))
        #expect(tool.approvalRoute(argumentsJSON: grep) == .deterministic)
    }

    @Test("I/O calls cannot reuse approvals and output writes remain within the policy intersection")
    func ioPermissions() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path,
            ruleStore: ShellApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json")))
        let ordinary = try command("ls")
        #expect(tool.persistApprovalRule(argumentsJSON: ordinary))
        let redirected = try command("ls", [], ["stdout_file": "project/list.txt"])
        #expect(tool.permissionClass(argumentsJSON: redirected) == .workspaceMutation)
        #expect(tool.writeTargets(argumentsJSON: redirected) == [child.appendingPathComponent("list.txt").path])
        #expect(tool.approvalRoute(argumentsJSON: redirected) == .manualOnly)
        #expect(tool.roundAuthorizationKey(argumentsJSON: redirected) == nil)
        #expect(!tool.isCoveredByPersistentRule(argumentsJSON: redirected))
        #expect(tool.persistentApprovalCandidates(argumentsJSON: redirected) == nil)
        let policy = PermissionPolicy(mode: .workspaceWrite,
            fileAreaPolicy: FileAreaPolicy(service: FileAreaService(baseDirectory: root, additionalRoots: [root]), defaultWriteRoots: [root]))
        #expect(policy.assess(toolName: "shell_run", permissionClass: .workspaceMutation,
            argumentsJSON: redirected, skillWorkspace: child.path,
            writeTargets: tool.writeTargets(argumentsJSON: redirected), subtaskWriteRoots: [child]) == .allow)
        for mode in ["overwrite", "append"] {
            let changed = try command("ls", [], ["stdout_file": "project/list.txt", "output_mode": mode])
            let pending = try #require(DispatcherEngine.confirmationRequirement(
                ToolCallRaw(id: mode, name: "shell_run", argumentsJSON: changed), toolsByName: ["shell_run": tool], authorizedKeys: []))
            #expect(pending.kind == .hard)
            #expect(pending.hardReason == .irreversible)
        }
        let inputOnly = try command("wc", ["-c"], ["stdin_file": "data.bin"])
        #expect(tool.permissionClass(argumentsJSON: inputOnly) == .readOnly)
        #expect(tool.approvalRoute(argumentsJSON: inputOnly) == .manualOnly)
    }

    @Test("Publication refuses changed targets, new collisions, symlinks and private input paths")
    func guardedPublication() throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("out")
        try Data("original".utf8).write(to: destination)
        let io = try ShellFileRedirection(args: ["stdout_file": "out", "output_mode": "append"], directory: root, denied: [])
        let staged = try io.stage(in: temporary)
        try Data("new".utf8).write(to: URL(fileURLWithPath: try #require(staged.output)))
        let captured = try io.collect(ChildProcessResult(outcome: .exited(0), stdout: "", stderr: "", duration: 0), temporary: temporary, previewLimit: 100)
        try Data("concurrent-edit".utf8).write(to: destination)
        #expect(throws: ToolExecutionFailure.self) { try io.publish(captured) }
        #expect(try Data(contentsOf: destination) == Data("concurrent-edit".utf8))
        let privateFile = outside.appendingPathComponent("secret")
        try Data("secret".utf8).write(to: privateFile)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        for values in [["stdout_file": "alias/out"], ["stdin_file": "alias/secret"],
                       ["stdout_file": "../escape"], ["stdout_file": "same", "stderr_file": "same"],
                       ["stdin_file": "out"], ["stdout_file": "out"]] {
            let denied = values["stdin_file"] == "out" ? [destination] : []
            #expect(throws: (any Error).self) { try ShellFileRedirection(args: values, directory: root, denied: denied) }
        }
        let fresh = try ShellFileRedirection(args: ["stdout_file": "fresh"], directory: root, denied: [])
        try Data("raced".utf8).write(to: root.appendingPathComponent("fresh"))
        let freshCapture = ShellFileRedirection.Captured(result: captured.result, files: [(try #require(fresh.destinations.first), Data("new".utf8))])
        #expect(throws: ToolExecutionFailure.self) { try fresh.publish(freshCapture) }
        #expect(try String(contentsOf: root.appendingPathComponent("fresh"), encoding: .utf8) == "raced")
        // 连已批准根的祖先也不能在发布前换成链接。
        let parent = root.appendingPathComponent("parent")
        let nested = parent.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try SecureFileWriter.write(Data(), to: nested.appendingPathComponent("escape"), root: nested, policy: .createOnly) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("nested/escape").path))
    }

    @Test("Signed Shell streams preserve complete binary data, separate stderr, append and fail without truncation", .enabled(if: Self.signedApp))
    func liveStandardIO() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<100_000).map { UInt8($0 % 256) })
        try bytes.write(to: root.appendingPathComponent("input.bin"))
        let python = try ScriptAppSandboxTests().testPythonPath()
        for space in [AppSpace.personal, .work] {
            let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path, space: space,
                sandboxBackend: .injected(try ScriptAppSandboxTests().runner(space: space)))
            let name = space.rawValue + ".bin"
            let output = try await tool.execute(argumentsJSON: command("cat", [], ["stdin_file": "input.bin", "stdout_file": name]))
            #expect(try Data(contentsOf: root.appendingPathComponent(name)) == bytes)
            #expect(output.contains("100000 bytes"))
            #expect(output.utf8.count < 40_000)
            _ = try await tool.execute(argumentsJSON: command("printf", ["%s", "suffix"], ["stdout_file": name, "output_mode": "append"]))
            #expect(try Data(contentsOf: root.appendingPathComponent(name)) == bytes + Data("suffix".utf8))
            let out = space.rawValue + "-out"
            let err = space.rawValue + "-err"
            _ = try await tool.execute(argumentsJSON: command(python, ["-I", "-c", "import os; os.write(1,b'out'); os.write(2,b'err')"], ["stdout_file": out, "stderr_file": err]))
            #expect(try String(contentsOf: root.appendingPathComponent(out), encoding: .utf8) == "out")
            #expect(try String(contentsOf: root.appendingPathComponent(err), encoding: .utf8) == "err")
            await #expect(throws: ToolExecutionFailure.self) {
                try await tool.execute(argumentsJSON: command(python, ["-I", "-c", "import os; os.write(1,b'partial'); os._exit(9)"], ["stdout_file": out, "output_mode": "overwrite"]))
            }
            #expect(try String(contentsOf: root.appendingPathComponent(out), encoding: .utf8) == "out")
            await #expect(throws: ToolExecutionFailure.self) {
                try await tool.execute(argumentsJSON: command("touch", ["must-not-run"], ["stdout_file": name]))
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-run").path))
        }
    }

    @Test("Output limits and cancellation keep existing redirection targets intact", .enabled(if: Self.signedApp))
    func liveOutputLimitsAndCancellation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path,
            sandboxBackend: .injected(try ScriptAppSandboxTests().runner()))
        let python = try ScriptAppSandboxTests().testPythonPath()
        let destination = root.appendingPathComponent("out")
        try Data("original".utf8).write(to: destination)
        do {
            _ = try await tool.execute(argumentsJSON: command(python,
                ["-I", "-c", "import sys; sys.stdout.buffer.write(b'x' * (65 * 1024 * 1024))"],
                ["stdout_file": "out", "output_mode": "overwrite"]))
            Issue.record("The regular-file size hard limit must stop oversized output")
        } catch let failure as ToolExecutionFailure {
            #expect(failure.message.contains("64 MiB"))
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        let spec = try command(python, ["-I", "-c", "import pathlib,sys,time; sys.stdout.write('partial'); sys.stdout.flush(); pathlib.Path('ready').touch(); time.sleep(30)"],
            ["stdout_file": "out", "output_mode": "overwrite"])
        let task = Task { try await tool.execute(argumentsJSON: spec) }
        defer { task.cancel() }
        let ready = root.appendingPathComponent("ready")
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    }

    @MainActor
    @Test("Confirmation names the I/O destinations and output mode")
    func ioConfirmationSummary() throws {
        let spec = try command("cat", [], ["stdin_file": "source.bin", "stdout_file": "report.bin", "stderr_file": "errors.txt", "output_mode": "append"])
        let summary = ConfirmationSummary.text(tool: "shell_run", arguments: spec, preview: nil)
        #expect(summary.contains("source.bin"))
        #expect(summary.contains("report.bin"))
        #expect(summary.contains("errors.txt"))
        #expect(summary.contains(L.string("product.confirm.shell.mode.append")))
        #expect(summary.contains(L.string("product.confirm.shell.publish")))
    }

    @Test("Host execution cannot reuse remembered or turn approvals, including read-only commands")
    func hostApproval() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rules = ShellApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"))
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path, ruleStore: rules)
        let sandbox = try args("ls")
        let host = try args("ls", mode: "host")
        #expect(tool.persistApprovalRule(argumentsJSON: sandbox))
        #expect(tool.isCoveredByPersistentRule(argumentsJSON: sandbox))
        #expect(!tool.isCoveredByPersistentRule(argumentsJSON: host))
        #expect(tool.roundAuthorizationKey(argumentsJSON: host) == nil)
        #expect(tool.persistentApprovalCandidates(argumentsJSON: host) == nil)
        #expect(tool.permissionClass(argumentsJSON: host) == .codeExecution)
        let sandboxKey = try #require(tool.roundAuthorizationKey(argumentsJSON: sandbox))
        let pending = try #require(DispatcherEngine.confirmationRequirement(
            ToolCallRaw(id: "host", name: "shell_run", argumentsJSON: host),
            toolsByName: ["shell_run": tool], authorizedKeys: [sandboxKey]))
        #expect(pending.kind == .hard)
        #expect(pending.hardReason == .hostExecution)
        #expect(pending.roundKey == nil)
        let policy = PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: nil)
        guard case .deny = policy.assess(toolName: "shell_run", permissionClass: tool.permissionClass(argumentsJSON: host),
            argumentsJSON: host, skillWorkspace: nil) else {
            Issue.record("Workspace mode must reject host execution"); return
        }
    }

    @Test("Sandbox writes obey the session, skill and subtask intersection")
    func scopedWrites() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path)
        let arguments = try args("mkdir output", directory: child)
        let policy = PermissionPolicy(mode: .workspaceWrite,
            fileAreaPolicy: FileAreaPolicy(service: FileAreaService(baseDirectory: root, additionalRoots: [root]), defaultWriteRoots: [root]))
        #expect(tool.permissionClass(argumentsJSON: arguments) == .workspaceMutation)
        #expect(tool.writeTargets(argumentsJSON: arguments) == [child.path])
        #expect(policy.assess(toolName: "shell_run", permissionClass: tool.permissionClass(argumentsJSON: arguments),
            argumentsJSON: arguments, skillWorkspace: child.path,
            writeTargets: tool.writeTargets(argumentsJSON: arguments), subtaskWriteRoots: [child]) == .allow)
        let broad = try args("mkdir output")
        guard case .deny = policy.assess(toolName: "shell_run", permissionClass: tool.permissionClass(argumentsJSON: broad),
            argumentsJSON: broad, skillWorkspace: child.path,
            writeTargets: tool.writeTargets(argumentsJSON: broad), subtaskWriteRoots: [child]) else {
            Issue.record("Broad working-directory grants must not escape a narrowed scope"); return
        }
    }

    @Test("Unsupported syntax and unknown modes fail without falling back to host execution")
    func noFallback() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("escaped")
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path)
        for mode in ["sandbox", "invalid"] {
            await #expect(throws: (any Error).self) {
                try await tool.execute(argumentsJSON: args("touch escaped; echo bypass", mode: mode))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Real shell runners permit approved writes and block outside files, network and forks", .enabled(if: Self.signedApp))
    func liveShell() async throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let child = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret")
        try "private-fixture-data".write(to: secret, atomically: true, encoding: .utf8)
        let python = try ScriptAppSandboxTests().testPythonPath()
        for space in [AppSpace.personal, .work] {
            let helper = try ScriptAppSandboxTests().runner(space: space)
            let tool = ShellRunTool(defaultWorkingDirectory: child.path, workspaceRoot: root.path, space: space,
                environmentContext: ["AGROOM_DATABASE_PATH": "private-db", "PATH": "/untrusted"], sandboxBackend: .injected(helper))
            let name = "output-\(space.rawValue)"
            let output = try await tool.execute(argumentsJSON: args("mkdir \(name)"))
            #expect(output.contains("execution mode: sandbox"))
            #expect(FileManager.default.fileExists(atPath: child.appendingPathComponent(name).path))
            for script in ["cat '\(secret.path)'", "printenv AGROOM_DATABASE_PATH"] {
                await #expect(throws: ToolExecutionFailure.self) { try await tool.execute(argumentsJSON: args(script)) }
            }
            let probe = """
            import errno, os, socket
            try: socket.create_connection(("127.0.0.1", 9), timeout=1)
            except PermissionError: print("network-blocked")
            else: raise RuntimeError("network allowed")
            try: os.fork()
            except BlockingIOError as error:
                assert error.errno == errno.EAGAIN
                print("fork-blocked")
            else: raise RuntimeError("fork allowed")
            """
            let probed = try await tool.execute(argumentsJSON: args("\(python) -I -c '\(probe)'"))
            #expect(probed.contains("network-blocked"))
            #expect(probed.contains("fork-blocked"))
            let read = try await tool.execute(argumentsJSON: args("ls"))
            #expect(read.contains(name))
        }
        #expect(try String(contentsOf: secret, encoding: .utf8) == "private-fixture-data")
    }

    @Test("Real git runs directly inside App Sandbox", .enabled(if: Self.signedApp))
    func liveGit() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try ScriptAppSandboxTests().runner()
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path, sandboxBackend: .injected(helper))
        let initialized = await ChildProcessRunner.run(ChildProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", root.path], timeout: 10, outputLimit: 1000, label: "git-fixture"))
        try #require(initialized.succeeded)
        let output = try await tool.execute(argumentsJSON: args("git status --short"))
        #expect(output.contains("exit code: 0"))
    }
}
