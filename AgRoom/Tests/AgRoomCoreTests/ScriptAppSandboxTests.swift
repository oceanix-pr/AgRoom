import Foundation
import Security
import Testing
import AgRoomScriptIPC
@testable import AgRoomCore

@Suite("ScriptAppSandbox")
struct ScriptAppSandboxTests {
    private static let appPath = ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"]

    private static let productsPath = ProcessInfo.processInfo.environment["AGROOM_TEST_SIGNED_HELPERS"]
    static let hasSignedHelpers = appPath != nil || productsPath != nil

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-sandbox-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func runner(space: AppSpace = .work) throws -> ScriptAppSandbox {
        let products: URL
        let signingReference: URL
        if let path = Self.appPath {
            signingReference = URL(fileURLWithPath: path)
            products = signingReference.appendingPathComponent("Contents/Helpers")
        } else {
            products = URL(fileURLWithPath: try #require(Self.productsPath))
            signingReference = products.appendingPathComponent("AgRoomRunnerWork.app")
        }
        var code: SecStaticCode?
        var rawInfo: CFDictionary?
        #expect(SecStaticCodeCreateWithPath(signingReference as CFURL, [], &code) == errSecSuccess)
        let signed = try #require(code)
        #expect(SecCodeCopySigningInformation(signed, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess)
        let info = try #require(rawInfo as? [String: Any])
        let team = try #require(info[kSecCodeInfoTeamIdentifier as String] as? String)
        let name = "AgRoomRunner\(space == .work ? "Work" : "Personal")"
        return try ScriptAppSandbox(bundle: products.appendingPathComponent("\(name).app"),
            identifier: "com.agroom.runner.\(space.rawValue)", team: team)
    }

    /// A test fixture only. Production continues to require the managed Python runtime.
    func testPythonPath() throws -> String {
        let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        let path = URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/python3").resolvingSymlinksInPath().path
        try #require(FileManager.default.isExecutableFile(atPath: path))
        return path
    }

    func makeExecutor(root: URL, space: AppSpace = .work) throws -> PythonExecutor {
        PythonExecutor(workspaceRoot: root, sandboxRunner: try runner(space: space), runtime: .managed(path: try testPythonPath()))
    }

    @Test("Anonymous stdin transfers data without a named control file")
    func anonymousInput() async {
        let data = Data(repeating: 65, count: 200_000)
        let result = await ChildProcessRunner.run(ChildProcessRequest(executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [], standardInputData: data, timeout: 5, outputLimit: data.count + 1, label: "stdin-test"))
        #expect(result.succeeded)
        #expect(result.stdout.utf8.count == data.count)
    }

    @Test("Missing or unsigned runners fail closed")
    func unavailableRunner() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ScriptIsolationError.self) {
            try ScriptAppSandbox(bundle: root, identifier: "com.agroom.runner.work", team: "untrusted")
        }
    }

    @Test("Read scopes omit private descendants even before those directories exist")
    func projectedScopes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("public.txt")
        try "public".write(to: allowed, atomically: true, encoding: .utf8)
        let privateRoot = root.appendingPathComponent("runs/personal")
        let runs = root.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let scopes = try ScriptAppSandbox.readScopes(sandbox: ScriptSandbox(readRoots: [root], writeRoots: [], deniedRoots: [privateRoot]))
        #expect(scopes.count == 1)
        #expect(scopes[0].lastPathComponent == "public.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: FileManager.default.temporaryDirectory)
        #expect(try ScriptAppSandbox.readScopes(sandbox: ScriptSandbox(readRoots: [root], writeRoots: [], deniedRoots: [privateRoot])).count == 1)
    }

    @Test("A private space stays unreadable below an otherwise approved root", .enabled(if: Self.hasSignedHelpers))
    func privateDescendant() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateRoot = root.appendingPathComponent("other-space")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        let secret = privateRoot.appendingPathComponent("secret.txt")
        let allowed = root.appendingPathComponent("public.txt")
        try "private".write(to: secret, atomically: true, encoding: .utf8)
        try "public".write(to: allowed, atomically: true, encoding: .utf8)
        let helper = try runner()
        let code = """
        assert open(\(String(reflecting: allowed.path))).read() == 'public'
        try: open(\(String(reflecting: secret.path))).read(); raise RuntimeError('private space escaped')
        except PermissionError: print('private-blocked')
        """
        let plan = ScriptExecutionPlan(executable: URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/python3"),
            arguments: ["-I", "-c", code], directory: root, environment: [:], timeout: 10,
            sandbox: ScriptSandbox(readRoots: [root, URL(fileURLWithPath: "/Library/Developer/CommandLineTools")],
                                   writeRoots: [], deniedRoots: [privateRoot]))
        let request = try await helper.request(plan: plan, label: "private-scope-test", outputLimit: 1000)
        let result = await ChildProcessRunner.run(request)
        #expect(result.succeeded, "\(result.stderr)")
        #expect(result.stdout.contains("private-blocked"))
    }

    @Test("Signed production runner enforces input, output, network and process boundaries",
           .enabled(if: Self.hasSignedHelpers))
    func productionFence() async throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let input = root.appendingPathComponent("input.txt")
        let privateFile = outside.appendingPathComponent("private.txt")
        try "input-data".write(to: input, atomically: true, encoding: .utf8)
        try "private-data".write(to: privateFile, atomically: true, encoding: .utf8)
        let alias = root.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: privateFile)
        for space in [AppSpace.personal, .work] {
            let executor = try makeExecutor(root: root, space: space)
            let result = try await executor.execute(code: """
            from pathlib import Path
            import socket, subprocess, sys
            assert Path(\(String(reflecting: input.path))).read_text() == 'input-data'
            assert sys.stdin.read() == ''
            for action in [lambda: Path(\(String(reflecting: input.path))).write_text('changed'),
                           lambda: Path(\(String(reflecting: privateFile.path))).read_text(),
                           lambda: Path(\(String(reflecting: alias.path))).read_text(),
                           lambda: socket.create_connection(('127.0.0.1', 9), timeout=1)]:
                try: action(); raise RuntimeError('escaped')
                except PermissionError: print('blocked')
            import resource
            assert resource.getrlimit(resource.RLIMIT_NPROC) == (0, 0)
            try: subprocess.run(['/usr/bin/true'], check=True); raise RuntimeError('fork allowed')
            except BlockingIOError: print('blocked')
            try: resource.setrlimit(resource.RLIMIT_NPROC, (10, 10)); raise RuntimeError('limit raised')
            except (ValueError, PermissionError): pass
            Path('output.txt').write_text('artifact')
            print('finished')
            """, workspaceInputs: try executor.selectedInputs(["input_paths": [input.path]]))
            #expect(result.succeeded, "\(result.displayOutput)")
            #expect(result.stdout.components(separatedBy: "blocked").count == 6)
            let output = try #require(result.outputDirectory)
            #expect(try String(contentsOf: output.appendingPathComponent("output.txt"), encoding: .utf8) == "artifact")
        }
        #expect(try String(contentsOf: input, encoding: .utf8) == "input-data")
    }

    @Test("Frozen multi-file skills run and publish scratch through the independent runner", .enabled(if: Self.hasSignedHelpers))
    func skillArtifacts() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("skill")
        let scripts = skill.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "value = 42".write(to: scripts.appendingPathComponent("module.py"), atomically: true, encoding: .utf8)
        let entry = scripts.appendingPathComponent("main.py")
        try "from module import value\nfrom pathlib import Path\nPath('scratch/result.txt').write_text(str(value))".write(to: entry, atomically: true, encoding: .utf8)
        let executor = try makeExecutor(root: root)
        let result = try await executor.executeSkillScript(entryURL: entry, skillRoot: skill)
        #expect(result.succeeded, "\(result.displayOutput)")
        #expect(try String(contentsOf: skill.appendingPathComponent("scratch/result.txt"), encoding: .utf8) == "42")
    }

    @Test("Cross-team runner substitution is rejected", .enabled(if: Self.hasSignedHelpers))
    func signatureBoundary() throws {
        let helper = try runner()
        let bundle = helper.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(throws: ScriptIsolationError.self) {
            try ScriptAppSandbox(bundle: bundle, identifier: helper.identifier, team: "UNTRUSTED")
        }
    }

    @Test("Failed and timed-out skills preserve the previous published artifact", .enabled(if: Self.hasSignedHelpers))
    func failedSkillArtifacts() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("skill")
        let scratch = skill.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let output = scratch.appendingPathComponent("result.txt")
        try "previous-success".write(to: output, atomically: true, encoding: .utf8)
        let entry = skill.appendingPathComponent("main.py")
        let executor = try makeExecutor(root: root)
        for ending in ["raise RuntimeError('fixture failure')", "import time; time.sleep(30)"] {
            try "from pathlib import Path\nPath('scratch/result.txt').write_text('partial')\n\(ending)".write(
                to: entry, atomically: true, encoding: .utf8)
            let result = try await executor.executeSkillScript(entryURL: entry, skillRoot: skill, timeout: 1)
            #expect(!result.succeeded)
            #expect(try String(contentsOf: output, encoding: .utf8) == "previous-success")
        }
    }

    @Test("Signed offline runner installs immutable resource limits", .enabled(if: Self.hasSignedHelpers))
    func runnerResourceLimits() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = try makeExecutor(root: root)
        let result = try await executor.execute(code: """
        import resource
        assert resource.getrlimit(resource.RLIMIT_FSIZE) == (\(ScriptRunnerLimits.maximumFileBytes), \(ScriptRunnerLimits.maximumFileBytes))
        assert resource.getrlimit(resource.RLIMIT_NOFILE) == (1024, 1024)
        assert resource.getrlimit(resource.RLIMIT_CPU) == (300, 300)
        try:
            resource.setrlimit(resource.RLIMIT_FSIZE, (-1, -1))
            raise RuntimeError('limit raised')
        except (ValueError, PermissionError):
            pass
        print('limits-verified')
        """)
        #expect(result.succeeded, "\(result.displayOutput)")
        #expect(result.stdout.contains("limits-verified"))
    }

    @Test("A bookmark moved outside its approved path is refused", .enabled(if: Self.hasSignedHelpers))
    func relocatedScope() async throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let input = root.appendingPathComponent("input.txt")
        try "sensitive-input".write(to: input, atomically: true, encoding: .utf8)
        let helper = try runner()
        let plan = ScriptExecutionPlan(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [input.path], directory: root,
            environment: [:], timeout: 5, sandbox: ScriptSandbox(readRoots: [input], writeRoots: [], deniedRoots: []))
        let request = try await helper.request(plan: plan, label: "relocated-scope", outputLimit: 1000)
        try FileManager.default.moveItem(at: input, to: outside.appendingPathComponent("moved.txt"))
        let result = await ChildProcessRunner.run(request)
        #expect(result.exitCode == 78)
        #expect(!result.stdout.contains("sensitive-input"))
    }

    @Test("The managed runtime's stale cross-process metadata can refresh without granting a conversation workspace",
           .enabled(if: Self.hasSignedHelpers))
    func managedRuntimeSyntax() async throws {
        let runtime = PythonRuntimeManager.shared.status()
        // Never install or substitute a runtime to run this optional integration check.
        guard runtime.pythonPath != nil else { return }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = PythonExecutor(workspaceRoot: root, sandboxRunner: try runner(), runtime: runtime)
        let result = try #require(try await executor.compileCheck(code: "raise RuntimeError('must never execute')\ndef main(inputs, context):\n    return {}\n"))
        #expect(result.succeeded, "\(result.displayOutput)")
        let invalid = try #require(try await executor.compileCheck(code: "def broken(:\n    pass"))
        #expect(!invalid.succeeded && invalid.stderr.contains("SyntaxError"))
    }

    @Test("A same-path object with a different identity cannot be authorized", .enabled(if: Self.hasSignedHelpers))
    func replacedScopeIdentity() async throws {
        let root = try directory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.txt")
        try "fixture".write(to: input, atomically: true, encoding: .utf8)
        let old = try #require(ScriptRunnerFileIdentity.capture(input))
        try FileManager.default.moveItem(at: input, to: root.appendingPathComponent("old.txt"))
        try "replacement".write(to: input, atomically: true, encoding: .utf8)
        #expect(ScriptRunnerFileIdentity.capture(input) != old)
        let helper = try runner()
        let approved = try #require(ScriptAppSandbox.readScopes(sandbox: ScriptSandbox(readRoots: [input], writeRoots: [], deniedRoots: [])).first)
        let bookmark = ScriptRunnerBookmark(data: try approved.bookmarkData(), path: approved.path, identity: old)
        let message = ScriptRunnerRequest(phase: .prepareScopes, helperIdentifier: helper.identifier, allowsNetwork: false,
            bookmarks: [bookmark], executable: "", arguments: [], directory: "/", environment: [:])
        let result = await ChildProcessRunner.run(ChildProcessRequest(executable: helper.executable, arguments: [],
            standardInputData: try JSONEncoder().encode(message), timeout: 5, outputLimit: 4096, label: "replaced-scope"))
        #expect(ScriptAppSandbox.preparationFailure(result)?.code == "bookmarkIdentityMismatch")
        #expect(result.stdout.isEmpty)
    }

    @Test("Offline script runner installs a local wheel into a temporary environment", .enabled(if: Self.hasSignedHelpers))
    func packageInstallation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try testPythonPath()
        let venv = root.appendingPathComponent("venv")
        let created = await ChildProcessRunner.run(ChildProcessRequest(executable: URL(fileURLWithPath: python),
            arguments: ["-m", "venv", venv.path], timeout: 60, outputLimit: 2000, label: "fixture-venv"))
        try #require(created.succeeded, "\(created.stderr)")
        let contents = root.appendingPathComponent("wheel-contents")
        let metadata = "zw_sandbox_fixture-1.0.dist-info"
        let files = [
            "zw_sandbox_fixture/__init__.py": "def main(): return 0\n",
            "\(metadata)/METADATA": "Metadata-Version: 2.1\nName: zw-sandbox-fixture\nVersion: 1.0\n",
            "\(metadata)/WHEEL": "Wheel-Version: 1.0\nGenerator: AgRoomTest\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
            "\(metadata)/entry_points.txt": "[console_scripts]\nzw-sandbox-fixture = zw_sandbox_fixture:main\n",
            "\(metadata)/RECORD": ""
        ]
        for (path, data) in files {
            let file = contents.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, atomically: true, encoding: .utf8)
        }
        let wheel = root.appendingPathComponent("zw_sandbox_fixture-1.0-py3-none-any.whl")
        let zipped = await ChildProcessRunner.run(ChildProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-qr", wheel.path, "."], workingDirectory: contents, timeout: 10, outputLimit: 1000, label: "fixture-wheel"))
        try #require(zipped.succeeded, "\(zipped.stderr)")
        let temporary = root.appendingPathComponent("tmp")
        let home = root.appendingPathComponent("home")
        for directory in [temporary, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let plan = ScriptExecutionPlan(executable: venv.appendingPathComponent("bin/python3"),
            arguments: ["-I", "-m", "pip", "--isolated", "--disable-pip-version-check", "install", "--no-index", "--no-deps", wheel.path],
            directory: temporary, environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": temporary.path], timeout: 30,
            sandbox: ScriptSandbox(readRoots: [wheel, venv] + PythonExecutor.systemReadRoots,
                writeRoots: [venv, temporary, home], deniedRoots: [], allowsNetwork: false))
        let request = try await runner().request(plan: plan, label: "wheel-installation-test", outputLimit: 3000)
        let installed = await ChildProcessRunner.run(request)
        #expect(installed.succeeded, "\(installed.stdout)\n\(installed.stderr)")
        #expect(FileManager.default.isExecutableFile(atPath: venv.appendingPathComponent("bin/zw-sandbox-fixture").path))
    }

    @Test("Both space identities block ungranted files and network access",
           .enabled(if: Self.hasSignedHelpers))
    func outerBoundary() async throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        for space in [AppSpace.personal, .work] {
            for network in [false, true] {
                let helper = try runner(space: space)
                let code = """
                import socket
                try: open(\(String(reflecting: secret.path))).read(); raise RuntimeError('outer sandbox escaped')
                except PermissionError: print('file-blocked')
                try: socket.create_connection(('127.0.0.1', 9), timeout=1)
                except PermissionError: print('network-blocked')
                except ConnectionRefusedError: print('network-permitted')
                """
                let plan = ScriptExecutionPlan(executable: URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/python3"),
                    arguments: ["-I", "-c", code], directory: root, environment: ["PATH": "/usr/bin:/bin"], timeout: 10,
                    sandbox: ScriptSandbox(readRoots: [root, URL(fileURLWithPath: "/Library/Developer/CommandLineTools")],
                        writeRoots: [], deniedRoots: [], allowsNetwork: network))
                if network {
                    await #expect(throws: ScriptIsolationError.self) {
                        try await helper.request(plan: plan, label: "app-sandbox-test", outputLimit: 2000)
                    }
                    continue
                }
                let request = try await helper.request(plan: plan, label: "app-sandbox-test", outputLimit: 2000)
                let result = await ChildProcessRunner.run(request)
                #expect(result.succeeded, "\(result.stderr)")
                #expect(result.stdout.contains("file-blocked"))
                #expect(result.stdout.contains("network-blocked"))
            }
        }
    }

    @Test("Space containers are physically separate", .enabled(if: Self.hasSignedHelpers))
    func separateContainers() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suffix = "agroom-fixture-" + UUID().uuidString
        let containers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers")
        for space in [AppSpace.personal, .work] {
            let helper = try runner(space: space)
            #expect(helper.identifier == "com.agroom.runner.\(space.rawValue)")
            let marker = containers.appendingPathComponent("\(helper.identifier)/Data/\(suffix)")
            let result = try await makeExecutor(root: root, space: space).execute(code:
                "from pathlib import Path; Path(\(String(reflecting: marker.path))).write_text('fixture')")
            try #require(result.succeeded, "\(result.displayOutput)")
        }
        for space in [AppSpace.personal, .work] {
            let own = containers.appendingPathComponent("com.agroom.runner.\(space.rawValue)/Data/\(suffix)")
            let other = containers.appendingPathComponent("com.agroom.runner.\(space == .work ? "personal" : "work")/Data/\(suffix)")
            let result = try await makeExecutor(root: root, space: space).execute(code: """
            from pathlib import Path
            own = Path(\(String(reflecting: own.path)))
            assert own.read_text() == 'fixture'
            try: Path(\(String(reflecting: other.path))).read_bytes(); raise RuntimeError('cross-space access')
            except PermissionError: print('other-container-blocked')
            """)
            #expect(result.succeeded, "\(result.displayOutput)")
            #expect(result.stdout.contains("other-container-blocked"))
        }
        for space in [AppSpace.personal, .work] {
            let own = containers.appendingPathComponent("com.agroom.runner.\(space.rawValue)/Data/\(suffix)")
            let result = try await makeExecutor(root: root, space: space).execute(code:
                "from pathlib import Path; Path(\(String(reflecting: own.path))).unlink(missing_ok=True)")
            #expect(result.succeeded)
        }
    }

    @Test("Package resolution budgets cannot be requested for arbitrary code", .enabled(if: Self.hasSignedHelpers))
    func resolutionPurposeFailsClosed() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try runner()
        let plan = ScriptExecutionPlan(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], directory: root,
            environment: [:], timeout: 5, sandbox: ScriptSandbox(readRoots: [root], writeRoots: [], deniedRoots: []))
        await #expect(throws: ScriptIsolationError.self) {
            try await helper.request(plan: plan, label: "invalid-package-resolution", outputLimit: 1000, purpose: .packageResolution)
        }
    }

    @Test("Runner keeps timeout and cancellation semantics", .enabled(if: Self.hasSignedHelpers))
    func lifecycle() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = try makeExecutor(root: root)
        let timeout = try await executor.execute(code: "import time; time.sleep(30)", timeout: 0.5)
        #expect(timeout.timedOut, "\(timeout.displayOutput)")
        let task = Task { try await executor.execute(code: "import time; time.sleep(30)") }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled runner returned normally") }
        catch is CancellationError { }
    }
}
