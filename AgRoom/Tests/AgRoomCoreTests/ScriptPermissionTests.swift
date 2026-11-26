import Darwin
import Foundation
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("ScriptPermission")
struct ScriptPermissionTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-permission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Python selects only its fixed runtime and rejects external executable or directory links")
    func dedicatedRuntimeBoundary() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PythonRuntimeManager(environmentRoot: root.appendingPathComponent("managed"))
        #expect(manager.status() == .notInstalled)
        #expect(!manager.isManagedInterpreter("/usr/bin/python3"))
        let bin = manager.managedRuntimeDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let versioned = bin.appendingPathComponent("python3.13")
        try Data("fixture".utf8).write(to: versioned)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: versioned.path)
        let interpreter = URL(fileURLWithPath: manager.managedPythonPath)
        try FileManager.default.createSymbolicLink(at: interpreter, withDestinationURL: versioned)
        #expect(manager.status() == .managed(path: interpreter.path))

        let external = root.appendingPathComponent("external/bin")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let outsidePython = external.appendingPathComponent("python3")
        try FileManager.default.copyItem(at: versioned, to: outsidePython)
        try FileManager.default.removeItem(at: interpreter)
        try FileManager.default.createSymbolicLink(at: interpreter, withDestinationURL: outsidePython)
        #expect(manager.status() == .notInstalled)

        try FileManager.default.removeItem(at: manager.managedRuntimeDir)
        try FileManager.default.createSymbolicLink(at: manager.managedRuntimeDir,
            withDestinationURL: external.deletingLastPathComponent())
        #expect(manager.status() == .notInstalled)
    }

    @Test("Venv reuse rejects external base paths, external executables, and inherited packages")
    func isolatedVenvBoundary() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("python-runtime/bin")
        let venv = root.appendingPathComponent("python/work/venv")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: venv.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let base = runtime.appendingPathComponent("python3")
        try Data("fixture".utf8).write(to: base)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        let interpreter = venv.appendingPathComponent("bin/python3")
        try FileManager.default.createSymbolicLink(at: interpreter, withDestinationURL: base)
        let config = venv.appendingPathComponent("pyvenv.cfg")
        func writeConfig(home: String, inherited: Bool = false) throws {
            try "home = \(home)\ninclude-system-site-packages = \(inherited ? "true" : "false")\n".write(
                to: config, atomically: true, encoding: .utf8)
        }
        try writeConfig(home: runtime.path)
        #expect(PythonEnvironmentService.isIsolatedVenv(at: venv, baseInterpreter: base.path))
        try writeConfig(home: "/usr/bin")
        #expect(!PythonEnvironmentService.isIsolatedVenv(at: venv, baseInterpreter: base.path))
        try writeConfig(home: runtime.path, inherited: true)
        #expect(!PythonEnvironmentService.isIsolatedVenv(at: venv, baseInterpreter: base.path))
        try writeConfig(home: runtime.path)
        let outside = root.appendingPathComponent("external-python")
        try FileManager.default.copyItem(at: base, to: outside)
        try FileManager.default.removeItem(at: interpreter)
        try FileManager.default.createSymbolicLink(at: interpreter, withDestinationURL: outside)
        #expect(!PythonEnvironmentService.isIsolatedVenv(at: venv, baseInterpreter: base.path))
        try FileManager.default.removeItem(at: interpreter)
        try FileManager.default.createSymbolicLink(at: interpreter, withDestinationURL: base)
        let externalConfig = root.appendingPathComponent("external.cfg")
        try FileManager.default.moveItem(at: config, to: externalConfig)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: externalConfig)
        #expect(!PythonEnvironmentService.isIsolatedVenv(at: venv, baseInterpreter: base.path))
        try FileManager.default.removeItem(at: config)
        try FileManager.default.moveItem(at: externalConfig, to: config)
        try FileManager.default.removeItem(at: venv.appendingPathComponent("bin"))
        try FileManager.default.createSymbolicLink(at: venv.appendingPathComponent("bin"), withDestinationURL: runtime)
        #expect(!PythonEnvironmentService.isIsolatedVenv(at: venv, baseInterpreter: base.path))
    }

    @Test("Document-based Python environments remain exclusive to their spaces")
    func dedicatedSpaceBoundaries() throws {
        let base = PythonRuntimeManager.shared.environmentRoot
        let service = FileAreaService(baseDirectory: base)
        for space in AppSpace.allCases {
            let other: AppSpace = space == .work ? .personal : .work
            let root = PythonSpacePaths.root(space: space)
            let otherRoot = PythonSpacePaths.root(space: other)
            #expect(PythonRuntimeManager.contains(root, in: base))
            #expect(root != otherRoot)
            #expect(ScriptSandbox.privateRoots(space: space).contains(otherRoot))
            let policy = FileAreaPolicy(service: service, space: space,
                defaultWriteRoots: [base], spaceWriteRoots: [base])
            #expect(policy.writeViolation(targets: [otherRoot.appendingPathComponent("venv/marker").path]) != nil)
            #expect(PythonEnvironmentService.plannedIdentity(space: space, baseInterpreter: "/usr/bin/python3") == nil)
        }

        let fixture = try directory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let personal = fixture.appendingPathComponent("python/personal")
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        let work = fixture.appendingPathComponent("python/work")
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: personal)
        #expect(!PythonRuntimeManager.isUnredirectedDirectory(work.appendingPathComponent("venv"), in: fixture))
    }

    @Test("Missing dedicated Python reports a download requirement without preparing an environment",
          .enabled(if: PythonRuntimeManager.shared.status() == .notInstalled))
    func missingRuntimeIsActionable() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = PythonExecutor(space: .work, runRoot: root)
        do {
            _ = try await executor.execute(code: "raise RuntimeError('must not execute')")
            Issue.record("A missing runtime must prevent execution")
        } catch PythonExecutor.ExecutorError.noRuntime {
            #expect(PythonExecutor.ExecutorError.noRuntime.localizedDescription.contains("download and install"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let report = try await PythonEnvStatusTool(executor: executor).execute(argumentsJSON: "{}")
        #expect(report.contains(PythonRuntimeManager.shared.environmentRoot.path))
        #expect(report.contains("download and install"))
        #expect(report.contains("System and external Python environments: disabled"))
        do {
            _ = try await PythonEnvironmentService.shared.environment(for: .work, baseInterpreter: "/usr/bin/python3")
            Issue.record("External base interpreters must be rejected")
        } catch PythonEnvironmentError.noRuntime {}
    }

    @Test("Git reflog mutations never receive read-only eligibility")
    func reflogMutations() {
        for command in ["git reflog drop refs/heads/main", "git reflog expire HEAD", "git reflog delete HEAD", "git reflog write HEAD a b message"] {
            #expect(ShellReadOnlyCommand.parse(command) == nil, "\(command)")
        }
        #expect(ShellReadOnlyCommand.parse("git reflog") != nil)
        #expect(ShellReadOnlyCommand.parse("git reflog show HEAD") != nil)
    }

    @Test("Bundle identity preserves file boundaries even when resource bytes contain NUL separators")
    func bundleBoundaryIdentity() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Data("value = 42\n".utf8)
        let main = root.appendingPathComponent("main.py")
        try "try:\n import b\nexcept ModuleNotFoundError:\n pass\n".write(to: main, atomically: true, encoding: .utf8)
        let resource = root.appendingPathComponent("a.dat")
        try (Data("ok\0b.py\0".utf8) + helper).write(to: resource)
        let before = try ScriptBundleSnapshot(root: root).digest
        try Data("ok".utf8).write(to: resource)
        try helper.write(to: root.appendingPathComponent("b.py"))
        let after = try ScriptBundleSnapshot(root: root).digest
        #expect(before != after)
        #expect(after == (try ScriptBundleSnapshot(root: root).digest))
    }

    @Test("Skill confirmation and execution identity bind only explicitly selected workspace inputs")
    func skillReadScope() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(directoryURL: root.appendingPathComponent("skills"))
        let scripts = store.directoryURL.appendingPathComponent("fixture/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "pass".write(to: scripts.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        let workspaceA = root.appendingPathComponent("a")
        let workspaceB = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: workspaceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceB, withIntermediateDirectories: true)
        let toolA = SkillRunScriptTool(store: store, executor: PythonExecutor(space: nil, readWorkspace: workspaceA, runRoot: root))
        let toolB = SkillRunScriptTool(store: store, executor: PythonExecutor(space: nil, readWorkspace: workspaceB, runRoot: root))
        let args = #"{"name":"fixture","path":"scripts/main.py"}"#
        let empty = try #require(toolA.approvalPresentation(argumentsJSON: args))
        #expect(!empty.resourceAccess.readable.contains(workspaceA.path))
        let selected = try MCPJSON.string(["name": "fixture", "path": "scripts/main.py", "input_paths": [workspaceA.path]])
        let presentation = try #require(toolA.approvalPresentation(argumentsJSON: selected))
        #expect(presentation.resourceAccess.readable.contains(workspaceA.path))
        #expect(toolB.approvalPresentation(argumentsJSON: selected) == nil)
        #expect(toolB.executionAuthorizationKey(argumentsJSON: selected) == nil)
        if let key = toolA.executionAuthorizationKey(argumentsJSON: selected) {
            #expect(key != toolA.executionAuthorizationKey(argumentsJSON: args))
        }
    }

    @Test("Audit corruption and unsafe lock files are reported and never overwritten")
    func auditFailuresPreserveEvidence() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = AutoReviewAuditLog(spaceDirectoryURL: root)
        let entry = AutoReviewAuditEntry(callId: "fixture", toolName: "shell_run", decision: "manual_approved", reason: "manual_once")
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: log.fileURL)
        guard case .corrupt = log.loadResult() else { Issue.record("Expected corrupt audit state"); return }
        #expect(!log.record(entry))
        #expect(try Data(contentsOf: log.fileURL) == corrupt)
        try FileManager.default.removeItem(at: log.fileURL)
        try FileManager.default.removeItem(atPath: log.fileURL.path + ".lock")
        try FileManager.default.createSymbolicLink(atPath: log.fileURL.path + ".lock", withDestinationPath: root.appendingPathComponent("other").path)
        guard case .unavailable = log.loadResult() else { Issue.record("Unsafe lock must be unavailable"); return }
        #expect(!log.record(entry))
        #expect(!FileManager.default.fileExists(atPath: log.fileURL.path))
    }

    @Test("Venv preparation disables startup hooks in the configured base environment",
          .enabled(if: PythonRuntimeManager.shared.status().pythonPath != nil))
    func bootstrapSkipsStartupHooks() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try #require(PythonRuntimeManager.shared.status().pythonPath)
        let fixture = root.appendingPathComponent("base")
        let created = await ChildProcessRunner.run(ChildProcessRequest(executable: URL(fileURLWithPath: base),
            arguments: ["-I", "-S", "-m", "venv", "--without-pip", fixture.path], timeout: 30, outputLimit: 1000, label: "bootstrap-fixture"))
        try #require(created.succeeded, "\(created.stderr)")
        let paths = try FileManager.default.subpathsOfDirectory(atPath: fixture.path)
        let packages = try #require(paths.first { $0.hasSuffix("/site-packages") })
        let marker = root.appendingPathComponent("hook-ran")
        try "from pathlib import Path\nPath(\(String(reflecting: marker.path))).write_text('hook')".write(
            to: fixture.appendingPathComponent(packages).appendingPathComponent("sitecustomize.py"), atomically: true, encoding: .utf8)
        let interpreter = fixture.appendingPathComponent("bin/python3")
        let probe = await ChildProcessRunner.run(ChildProcessRequest(executable: interpreter,
            arguments: ["-I", "-c", "pass"], timeout: 10, outputLimit: 1000, label: "hook-fixture"))
        try #require(probe.succeeded)
        try #require(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)
        try await PythonEnvironmentService.createVenv(base: interpreter.path, at: root.appendingPathComponent("target"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Audit append waits for a separate process and merges its committed records",
          .enabled(if: PythonRuntimeManager.shared.status().pythonPath != nil))
    func auditCrossProcessAppend() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try #require(PythonRuntimeManager.shared.status().pythonPath)
        let log = AutoReviewAuditLog(spaceDirectoryURL: root)
        let ready = root.appendingPathComponent("ready")
        let attempted = root.appendingPathComponent("attempted")
        let code = """
        import fcntl, json, pathlib, sys, time
        root = pathlib.Path(sys.argv[1])
        with open(root / 'auto-review.json.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            (root / 'ready').touch()
            deadline = time.monotonic() + 5
            while not (root / 'attempted').exists() and time.monotonic() < deadline:
                time.sleep(.01)
            time.sleep(.3)
            (root / 'auto-review.json').write_text(json.dumps([dict(callId='external', toolName='shell_run', ruleVersion='approval/v1', decision='approved', reason='fixture', time=0)]))
        """
        let task = Task {
            await ChildProcessRunner.run(ChildProcessRequest(executable: URL(fileURLWithPath: python),
                arguments: ["-I", "-S", "-c", code, root.path], timeout: 10, outputLimit: 1000, label: "audit-lock-test"))
        }
        defer { task.cancel() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        let saved = try await Task.detached {
            try Data().write(to: attempted)
            return log.record(AutoReviewAuditEntry(callId: "local", toolName: "shell_run", decision: "approved", reason: "fixture"))
        }.value
        let result = await task.value
        #expect(result.succeeded, "\(result.stderr)")
        #expect(saved)
        #expect(Set(log.entries().map(\.callId)) == ["local", "external"])
    }

    @Test("Expired run cleanup preserves artifacts and active executions")
    func safeRunCleanup() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent(UUID().uuidString)
        let artifact = root.appendingPathComponent(UUID().uuidString)
        let active = root.appendingPathComponent(UUID().uuidString)
        for dir in [empty, artifact, active] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("output"), withIntermediateDirectories: true)
        }
        try "keep".write(to: artifact.appendingPathComponent("output/result.txt"), atomically: true, encoding: .utf8)
        let descriptor = open(active.appendingPathComponent(".execution.lock").path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let past = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        for dir in [empty, artifact, active] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: dir.path)
        }
        PythonExecutor.cleanExpiredEmptyRuns(in: root)
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        #expect(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("output/result.txt").path))
        #expect(FileManager.default.fileExists(atPath: active.path))
    }

    @Test("Python and package management do not grant the whole tool for a turn")
    func codeApprovalScope() {
        let executor = PythonExecutor()
        let tool = PythonExecuteTool(executor: executor)
        let first = #"{"code":"print(1)"}"#
        #expect(tool.roundAuthorizationKey(argumentsJSON: first) == nil)
        #expect(tool.executionAuthorizationKey(argumentsJSON: first) != nil)
        #expect(tool.executionAuthorizationKey(argumentsJSON: first) != tool.executionAuthorizationKey(argumentsJSON: #"{"code":"print(2)"}"#))
        #expect(PythonPackageManageTool(executor: executor).roundAuthorizationKey(argumentsJSON: #"{"package":"pandas"}"#) == nil)
    }

    @Test("Arbitrary browser JavaScript always requires a fresh confirmation")
    func browserScripts() {
        let tool = BrowserEvaluateTool(space: .work)
        for script in ["document.title", "localStorage.setItem('audit', '1')", "navigator.clipboard.writeText('audit')"] {
            let data = try! JSONSerialization.data(withJSONObject: ["script": script, "tab_id": UUID().uuidString])
            let args = String(decoding: data, as: UTF8.self)
            #expect(tool.requiresHardConfirmation(argumentsJSON: args))
            #expect(tool.roundAuthorizationKey(argumentsJSON: args) == nil)
        }
    }

    @Test("Persistent rules reject expansion and track mutable executable bytes")
    func executableIdentity() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for script in ["echo *.txt", "echo file?.txt", "echo [ab]", "ls && pwd", "ls | cat", "ls\npwd"] {
            #expect(ShellRunTool.ruleDrafts(for: script, workingDirectory: root.path, space: "work", workspaceRoot: root.path) == nil)
        }
        let command = root.appendingPathComponent("task")
        try "#!/bin/sh\necho one\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path)
        let args = #"{"script":"./task"}"#
        #expect(tool.roundAuthorizationKey(argumentsJSON: args) == nil)
        let first = try #require(tool.executionAuthorizationKey(argumentsJSON: args))
        try "#!/bin/sh\necho two\n".write(to: command, atomically: true, encoding: .utf8)
        #expect(first != tool.executionAuthorizationKey(argumentsJSON: args))
    }

    @Test("Rule store fails closed when its stable lock cannot be acquired")
    func stableLock() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rules.json")
        let store = ShellApprovalRuleStore(fileURL: path)
        let drafts = try #require(ShellRunTool.ruleDrafts(for: "echo hi", workingDirectory: root.path, space: "work", workspaceRoot: nil))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("rules.json.lock"), withDestinationURL: root.appendingPathComponent("other-lock"))
        #expect(!store.add(drafts, origin: "echo hi"))
        #expect(store.all().isEmpty)
    }

    @Test("Bundle snapshots cover data files and reject symbolic links")
    func bundleIdentity() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.json")
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        let first = try ScriptBundleSnapshot(root: root).digest
        try "{\"changed\":true}".write(to: config, atomically: true, encoding: .utf8)
        #expect(first != (try ScriptBundleSnapshot(root: root).digest))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: FileManager.default.temporaryDirectory)
        #expect(throws: (any Error).self) { try ScriptBundleSnapshot(root: root) }
    }

    @Test("Every execution has its own directory")
    func uniqueDirectories() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = PythonExecutor(workspaceRoot: root)
        #expect(try executor.workspaceDir() != executor.workspaceDir())
    }

    @Test("An explicitly forbidden space remains inaccessible beneath a broader allowed root")
    func deniedSpaceWins() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let otherSpace = root.appendingPathComponent("other-space")
        try FileManager.default.createDirectory(at: otherSpace, withIntermediateDirectories: true)
        let secret = otherSpace.appendingPathComponent("private.txt")
        try "other-space-secret".write(to: secret, atomically: true, encoding: .utf8)
        let sandbox = ScriptSandbox(readRoots: [root, URL(fileURLWithPath: "/System"), URL(fileURLWithPath: "/bin"), URL(fileURLWithPath: "/usr/lib")],
            writeRoots: [], deniedRoots: [otherSpace])
        let plan = ScriptExecutionPlan(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [secret.path],
            directory: root, environment: [:], timeout: 5, sandbox: sandbox)
        let result = await ChildProcessRunner.run(try plan.request(label: "space-fence-test", outputLimit: 1024))
        #expect(!result.succeeded)
        #expect(!result.stdout.contains("other-space-secret"))
    }

    @Test("Python works inside the real fence and cannot access outside files or network",
          .enabled(if: PythonRuntimeManager.shared.status().pythonPath != nil))
    func liveFence() async throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret")
        try "private-test-data".write(to: secret, atomically: true, encoding: .utf8)
        let executor = PythonExecutor(workspaceRoot: root)
        let path = String(reflecting: secret.path)
        let result = try await executor.execute(code: """
        from pathlib import Path
        import socket, subprocess
        print('started', flush=True)
        for action in [lambda: Path(\(path)).read_text(), lambda: Path(\(path)).write_text('changed'), lambda: socket.create_connection(('127.0.0.1', 9), timeout=1), lambda: subprocess.run(['/usr/bin/true'], check=True)]:
            try:
                action()
                raise RuntimeError('escaped execution fence')
            except PermissionError:
                print('blocked', flush=True)
        Path('output.txt').write_text('ok')
        print('finished', flush=True)
        """)
        #expect(result.succeeded, "runtime=\(executor.runtimeStatus); exit=\(result.exitCode); \(result.displayOutput)")
        #expect(result.stdout.components(separatedBy: "blocked").count == 5)
        #expect(try String(contentsOf: secret, encoding: .utf8) == "private-test-data")
    }

    @Test("Approval durations never offer more than the engine authorizes")
    func approvalDurations() {
        let hard = ConfirmationRequirement(kind: .hard, scope: .script, hardReason: .hostExecution)
        #expect(hard.availableApprovalDurations == [.once])
        let round = ConfirmationRequirement(kind: .normal, scope: .script, roundKey: "round-key")
        #expect(round.availableApprovalDurations == [.once, .round])
        let persistent = ConfirmationRequirement(
            kind: .normal, scope: .script, roundKey: "round-key",
            persistentRuleCandidates: ["/bin/echo hi"]
        )
        #expect(persistent.availableApprovalDurations == [.once, .round, .persistent])
        let onceOnly = ConfirmationRequirement(kind: .normal, scope: .tool)
        #expect(onceOnly.availableApprovalDurations == [.once])
    }

    @Test("Rule store distinguishes missing and corrupt files and refuses to overwrite corruption")
    func ruleStoreReadResult() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rules.json")
        let store = ShellApprovalRuleStore(fileURL: path)
        #expect(store.loadResult() == .missing)

        let corrupt = "{not valid json"
        try corrupt.write(to: path, atomically: true, encoding: .utf8)
        guard case .corrupt = store.loadResult() else {
            Issue.record("corrupt rule file must be reported as corrupt")
            return
        }
        #expect(!store.remove(id: "missing"))
        #expect(throws: ShellApprovalRuleStore.StoreError.self) {
            try store.removeChecked(id: "missing")
        }
        #expect(try String(contentsOf: path, encoding: .utf8) == corrupt)
    }

    @Test("File edits reuse one turn approval per file while revalidating content")
    func fileEditRoundAuthorization() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileAreaService(baseDirectory: root)
        let tool = FilesEditTool(service: service)
        func arguments(path: String, sha: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "path": path, "expected_sha256": sha, "old_text": "old", "new_text": "new",
            ])
            return String(decoding: data, as: UTF8.self)
        }
        let path = root.appendingPathComponent("app.swift").path
        let other = root.appendingPathComponent("other.swift").path
        let first = try arguments(path: path, sha: "a")
        let second = try arguments(path: path, sha: "b")

        #expect(tool.requiresConfirmation(argumentsJSON: first))
        #expect(!tool.requiresHardConfirmation(argumentsJSON: first))
        #expect(tool.confirmationScope == .fileArea)
        #expect(tool.roundAuthorizationKey(argumentsJSON: first)
            == tool.roundAuthorizationKey(argumentsJSON: second))
        #expect(tool.roundAuthorizationKey(argumentsJSON: first)
            != tool.roundAuthorizationKey(argumentsJSON: try arguments(path: other, sha: "a")))
    }

    @Test("Ripgrep read-only whitelist rejects executable options and disables config")
    func ripgrepReadOnlyWhitelist() {
        #expect(ShellReadOnlyCommand.parse("rg --pre /bin/sh TODO .") == nil)
        #expect(ShellReadOnlyCommand.parse("rg -z TODO .") == nil)
        #expect(ShellReadOnlyCommand.parse("rg -L TODO .") == nil)
        #expect(ShellReadOnlyCommand.parse("rg -f patterns.txt TODO .") == nil)
        let installed = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/opt/local/bin/rg", "/usr/bin/rg"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
        if installed {
            let command = ShellReadOnlyCommand.parse("rg -n TODO Sources")
            #expect(command != nil)
            #expect(command?.injectedPrefix == ["--no-config"])
            #expect(ShellReadOnlyCommand.parse("rg --files")?.injectedPrefix == ["--no-config"])
        } else {
            #expect(ShellReadOnlyCommand.parse("rg --files") == nil)
        }
    }

    @Test("Approval presentation exposes the real sandbox and host capabilities")
    func approvalPresentation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path)

        let sandboxData = try JSONSerialization.data(withJSONObject: [
            "program": "/bin/ls", "arguments": [root.path]
        ])
        let sandbox = try #require(tool.approvalPresentation(
            argumentsJSON: String(decoding: sandboxData, as: UTF8.self)
        ))
        #expect(sandbox.executionKind == .sandboxCommand)
        #expect(!sandbox.network.allowed)
        #expect(!sandbox.childProcesses.allowed)
        #expect(sandbox.resourceAccess.verified)

        let hostData = try JSONSerialization.data(withJSONObject: [
            "script": "echo hi", "execution_mode": "host"
        ])
        let host = try #require(tool.approvalPresentation(
            argumentsJSON: String(decoding: hostData, as: UTF8.self)
        ))
        #expect(host.executionKind == .hostCommand)
        #expect(host.network.allowed)
        #expect(host.childProcesses.allowed)
        #expect(!host.resourceAccess.verified)
    }
}
