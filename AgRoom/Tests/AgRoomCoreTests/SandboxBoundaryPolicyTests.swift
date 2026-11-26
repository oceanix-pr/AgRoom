import Foundation
import GRDB
import Testing
import AgRoomScriptIPC
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Sandbox boundaries and external submissions")
struct SandboxBoundaryPolicyTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    @Test func sharedProjectHasDistinctRunRootsAndExplicitInputs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = PythonExecutor(space: .personal, readWorkspace: root, readWorkspaces: [root])
        let work = PythonExecutor(space: .work, readWorkspace: root, readWorkspaces: [root])
        #expect(personal.runStorageRoot == PythonSpacePaths.workspace(space: .personal, name: "run"))
        #expect(work.runStorageRoot == PythonSpacePaths.workspace(space: .work, name: "run"))
        #expect(!FileAreaService.isInside(personal.runStorageRoot, root: root))
        #expect(try work.selectedInputs([:]).isEmpty)
        let input = root.appendingPathComponent("input.csv")
        try Data("x\n1".utf8).write(to: input)
        let tool = PythonExecuteTool(executor: work)
        let args = try MCPJSON.string(["code": "pass", "input_paths": [input.path]])
        let before = try #require(tool.executionAuthorizationKey(argumentsJSON: args))
        let card = try #require(tool.approvalPresentation(argumentsJSON: args))
        #expect(card.resourceAccess.readable.contains(input.path))
        #expect(!card.resourceAccess.readable.contains(root.path))
        try FileManager.default.moveItem(at: input, to: root.appendingPathComponent("original"))
        try Data("x\n2".utf8).write(to: input)
        #expect(before != tool.executionAuthorizationKey(argumentsJSON: args))
        #expect(throws: ScriptIsolationError.self) { try work.selectedInputs(["input_paths": [root.deletingLastPathComponent().path]]) }
    }

    @Test func legacyRunsStayOutOfScopedFileOperations() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(".agroom-runs/run")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(!ScriptSandbox.permitsProjectRoot(legacy))
        let service = FileAreaService.standard.scoped(to: [root])
        #expect(throws: FileAreaService.AreaError.self) { try service.resolveManaged(legacy.path) }
        #expect(!((try service.entries(at: root.path)).contains { $0.name == ".agroom-runs" }))
        #expect(try service.resolveManaged(root.path) == root)
    }

    @Test func managedPythonStorageCannotBeRegisteredAsProjectInput() throws {
        let runtime = PythonRuntimeManager.shared
        let candidates = [runtime.environmentRoot, runtime.managedRuntimeDir, runtime.managedRuntimeDir.appendingPathComponent("bin"),
                          PythonSpacePaths.venv(space: .personal), PythonSpacePaths.workspace(space: .work, name: "package-downloads")]
        for url in candidates {
            #expect(!ScriptSandbox.permitsProjectRoot(url))
            #expect(FileAreaService.standard.scoped(to: [url]).managedRoots.isEmpty)
        }
        #expect(ScriptSandbox.permitsProjectRoot(FileAreaService.standard.defaultChatRoot(for: .work)))
    }

    @Test func wholeDirectoryShellWritesAlwaysNeedOneTimeApproval() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ruleStore = ShellApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"))
        let shell = ShellRunTool(defaultWorkingDirectory: root.path, workspaceRoot: root.path, ruleStore: ruleStore)
        let copy = #"{"program":"cp","arguments":["input","report"]}"#
        #expect(shell.requiresHardConfirmation(argumentsJSON: copy))
        #expect(shell.hardConfirmationReason(argumentsJSON: copy) == .directoryWrite)
        #expect(shell.roundAuthorizationKey(argumentsJSON: copy) == nil)
        #expect(!shell.persistApprovalRule(argumentsJSON: copy))
        let card = try #require(shell.approvalPresentation(argumentsJSON: copy))
        #expect(card.resourceAccess.writable == [root.path])
        let redirected = #"{"program":"ls","arguments":[],"stdout_file":"listing"}"#
        let redirectCard = try #require(shell.approvalPresentation(argumentsJSON: redirected))
        #expect(redirectCard.resourceAccess.writable == [root.appendingPathComponent("listing").path])
        #expect(!shell.requiresHardConfirmation(argumentsJSON: redirected))
    }

    @Test func restrictedScopeSurvivesHandoffAndRejectsRemoteReadTools() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        func scope(_ policy: TaskDataPolicy, host: Bool = false) -> TaskExecutionScope {
            .make(space: .work, sessionID: id, runID: id, parentRunID: nil, workspaceID: id,
                workspacePath: root.path, readRoots: [root], writeRoots: [root], artifactRoots: [],
                mode: .dangerFullAccess, autoReviewEnabled: true, policyVersion: "test", userRequest: "", dataPolicy: policy,
                allowsHostExecution: host)
        }
        #expect(!scope(.configuredServices).allows(.codeExecution))
        #expect(scope(.configuredServices, host: true).allows(.codeExecution))
        #expect(!scope(.modelOnly, host: true).allows(.codeExecution))
        let restored = try scope(.localOnly).forHandoff().restored(restrictedTo: scope(.configuredServices))
        for item in [restored, restored.child(runID: UUID(), subtaskID: UUID()), scope(.modelOnly)] {
            for name in ["web_fetch", "mcp_unknown", "mail_send", "unregistered_future_tool", "project_build"] {
                #expect(DispatcherEngine.taskScopeDenial(scope: item, toolName: name, permissionClass: .readOnly, writeTargets: []) != nil)
            }
            #expect(DispatcherEngine.taskScopeDenial(scope: item, toolName: "repo_symbols", permissionClass: .codeExecution, writeTargets: []) != nil)
            #expect(DispatcherEngine.taskScopeDenial(scope: item, toolName: "repo_symbols", permissionClass: .readOnly, writeTargets: []) == nil)
        }
        #expect(TaskConstraintExtractor.detect(in: "仅本机处理，分析附件。").contains(.localOnly))
        #expect(!TaskConstraintExtractor.detect(in: "解释什么是仅本机处理。").contains(.localOnly))
    }

    @Test func modelTransportChecksEndpointAndOriginBeforeIO() async throws {
        let local = URL(string: "http://127.0.0.1:11434/v1/chat/completions")!
        let remote = URL(string: "https://example.invalid/v1/chat/completions")!
        func provider(_ url: URL) -> CloudProvider {
            CloudProvider(config: .init(name: "fixture", endpoint: url.absoluteString, model: "fixture"), apiKey: "")
        }
        #expect(throws: TaskDataPolicyError.self) { try provider(remote).restricted(to: .localOnly) }
        let restricted = try provider(local).restricted(to: .localOnly).withParameterMode(.coding)
        await #expect(throws: TaskDataPolicyError.self) { try await restricted.responseBytes(for: URLRequest(url: remote)) }
        #expect(!ModelOriginDelegate.matches(URL(string: "http://127.0.0.1:8080/")!, local))
        #expect(ModelOriginDelegate.matches(local.deletingLastPathComponent(), local))
    }

    @MainActor @Test func privateConversationPreviewsDoNotFetchRemoteMedia() throws {
        let image = "https://media.example/picture.png"
        for policy in [TaskDataPolicy.modelOnly, .localOnly] {
            let context = MarkdownSourceContext.conversation(space: .work, workspace: nil, dataPolicy: policy)
            #expect(throws: MarkdownResourceError.self) { try context.resolveImage(image) }
        }
        let normal = MarkdownSourceContext.conversation(space: .work, workspace: nil)
        #expect(try normal.resolveImage(image).absoluteString == image)
    }

    @Test func sessionPolicyIsPersistedAndLegacySessionsDecode() async throws {
        let global = try DatabaseQueue()
        try DatabaseBootstrap.prepareGlobal(global)
        #expect(try await global.read { try !$0.tableExists("chat_sessions") })
        let db = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(db)
        let service = SessionService(databaseQueue: db)
        let session = ChatSession(dataPolicy: .localOnly)
        try await service.save(session)
        #expect(try await service.dataPolicy(id: session.id) == .localOnly)
        #expect(try await service.fetch(id: session.id)?.dataPolicy == .localOnly)
        try await service.setDataPolicy(id: session.id, policy: .modelOnly, restorationToken: nil)
        #expect(try await service.dataPolicy(id: session.id) == .modelOnly)
        #expect(try await service.executionAccess(id: session.id)?.allowsHost == false)
        try await service.setDataPolicy(id: session.id, policy: .modelOnly, allowsHostExecution: true, restorationToken: nil)
        #expect(try await service.executionAccess(id: session.id)?.allowsHost == true)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        legacy.removeValue(forKey: "dataPolicy")
        #expect(try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: legacy)).dataPolicy == .configuredServices)
    }

    @Test func wheelManifestRequiresEveryDependencyToBePinnedAndHashed() throws {
        let hash = String(repeating: "a", count: 64)
        try PythonExecutor.validateWheelManifest(Data("example==1.0 --hash=sha256:\(hash)\n".utf8))
        for invalid in ["", "example>=1 --hash=sha256:" + hash, "example==1", "--index-url https://example.invalid"] {
            #expect(throws: ScriptIsolationError.self) { try PythonExecutor.validateWheelManifest(Data(invalid.utf8)) }
        }
        #expect(PackageDownload.validRequirement("example[extra]==1.2"))
        #expect(!PackageDownload.validRequirement("https://example.invalid/example.whl"))
    }

    @Test func changedMailBindingAndAmbiguousDeliveryStopBeforeTransport() async throws {
        let db = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(db)
        let accounts = MailAccountService(databaseQueue: db, space: .work)
        var account = MailAccount(displayName: "Fixture", emailAddress: "from@example.invalid", imapHost: "imap.example.invalid",
                                  smtpHost: "smtp.example.invalid", username: "fixture")
        try await accounts.save(account, password: nil)
        let mail = MailService(databaseQueue: db)
        let sync = MailSyncService(accountService: accounts, mail: mail, space: .work,
            sendClientFactory: { _ in Issue.record("SMTP must not be reached"); return UnusedSMTP() },
            passwordProvider: { _ in "fixture" })
        let tool = MailSendTool(accountService: accounts, syncService: sync)
        let args = #"{"to":"a@example.invalid","subject":"Fixture","body":"One"}"#
        let first = try tool.prepared(args)
        for modified in [args.replacingOccurrences(of: "a@example", with: "b@example"),
                         args.replacingOccurrences(of: "One", with: "Two")] {
            #expect(try tool.prepared(modified).key != first.key)
            await #expect(throws: ToolExecutionFailure.self) { try await tool.execute(argumentsJSON: modified, authorizationKey: first.key) }
        }
        account.smtpHost = "second.example.invalid"
        try await accounts.save(account, password: nil)
        let second = try tool.prepared(args)
        #expect(second.key != first.key)
        #expect(second.draft.id == first.draft.id)
        var draft = first.draft
        draft.deliveryState = .unknown
        try await mail.saveDraft(draft)
        await #expect(throws: MailSyncError.self) { try await tool.execute(argumentsJSON: args, authorizationKey: second.key) }
    }

    @Test("The host fetches a pinned wheel for an offline helper and disposable environment",
          .enabled(if: ScriptAppSandboxTests.hasSignedHelpers && ProcessInfo.processInfo.environment["AGROOM_TEST_WHEEL_DOWNLOAD"] == "1"))
    func signedWheelTransfer() async throws {
        let runners = ScriptAppSandboxTests()
        let runtime = PythonRuntimeManager.shared
        let spaceRoot = PythonSpacePaths.workspace(space: .work, name: "package-downloads")
        let transfer = spaceRoot.appendingPathComponent(UUID().uuidString)
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: transfer); try? FileManager.default.removeItem(at: work) }
        let wheels = transfer.appendingPathComponent("output")
        let scratchHome = transfer.appendingPathComponent("home")
        let temporary = transfer.appendingPathComponent("tmp")
        for directory in [wheels, scratchHome, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let plan = ScriptExecutionPlan(executable: URL(fileURLWithPath: runtime.managedPythonPath),
            arguments: PackageDownload.arguments(requirement: "idna==3.10"), directory: wheels,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "HOME": scratchHome.path,
                          "TMPDIR": temporary.path, "PYTHONDONTWRITEBYTECODE": "1"], timeout: 75,
            sandbox: ScriptSandbox(readRoots: [runtime.managedRuntimeDir, transfer],
                writeRoots: [wheels, temporary, scratchHome], deniedRoots: []))
        let fetch = try await PythonPackageDownloader().resolve(in: transfer, timeout: 75) { remaining in
            let replay = ScriptExecutionPlan(executable: plan.executable, arguments: plan.arguments, directory: plan.directory,
                environment: plan.environment, timeout: remaining, sandbox: plan.sandbox)
            let result = await ChildProcessRunner.run(try await runners.runner().request(plan: replay, label: "wheel-fetch",
                outputLimit: 4000, purpose: .packageResolution))
            return PythonExecutionResult(outcome: result.outcome, stdout: result.stdout, stderr: result.stderr, duration: result.duration)
        }
        try #require(fetch.succeeded, "\(fetch.stderr)")
        let lock = wheels.appendingPathComponent("requirements.lock")
        try PythonExecutor.validateWheelManifest(Data(contentsOf: lock))
        let target = work.appendingPathComponent("venv")
        try await PythonEnvironmentService.createVenv(base: runtime.managedPythonPath, at: target)
        let install = ScriptExecutionPlan(executable: target.appendingPathComponent("bin/python3"),
            arguments: PackageDownload.offlineArguments(["install", "--only-binary=:all:", "--no-deps", "--no-index",
                        "--require-hashes", "--find-links", wheels.path, "-r", lock.path]),
            directory: work, environment: ["HOME": work.path, "TMPDIR": work.path, "PATH": "/usr/bin:/bin"], timeout: 40,
            sandbox: ScriptSandbox(readRoots: [work, wheels, runtime.managedRuntimeDir], writeRoots: [work], deniedRoots: []))
        let offline = await ChildProcessRunner.run(try await runners.runner().request(plan: install, label: "wheel-install", outputLimit: 4000))
        try #require(offline.succeeded, "\(offline.stderr)")
        #expect(offline.stdout.contains("idna-3.10"))
        let library = target.appendingPathComponent("lib")
        let versions = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        #expect(versions.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("site-packages/idna/__init__.py").path) })
    }

    private actor UnusedSMTP: MailSendClient {
        func connect() throws { throw CancellationError() }
        func authenticate(username: String, password: String) throws { throw CancellationError() }
        func send(_ message: OutgoingMail) throws { throw CancellationError() }
        func disconnect() {}
    }
}
