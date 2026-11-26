import Foundation

/// 显式宿主构建，不作为沙箱错误回退。固定 argv，但项目构建脚本仍具有宿主权限。
struct ProjectBuildTool: DispatcherTool {
    static let actions: Set<String> = ["swift_build", "swift_test", "xcode_build", "xcode_test"]

    static func checkRequirement(_ args: [String: Any], reader: RepositoryReader) throws -> CodingCheckRequirement {
        let keys: Set<String> = ["action", "directory", "project", "workspace", "scheme", "configuration", "test_filter"]
        guard args.keys.allSatisfy(keys.contains), args.values.allSatisfy({ (($0 as? String)?.count ?? 2049) <= 2048 }),
              let action = args["action"] as? String, actions.contains(action),
              ["Debug", "Release"].contains(args["configuration"] as? String ?? "Debug"),
              args["test_filter"] == nil || action.hasSuffix("test"),
              !(args["project"] != nil && args["workspace"] != nil),
              action.hasPrefix("xcode_") || (args["project"] == nil && args["workspace"] == nil && args["scheme"] == nil),
              !action.hasPrefix("xcode_") || ((args["project"] != nil || args["workspace"] != nil) && args["scheme"] != nil) else {
            throw ToolExecutionFailure(message: "Required checks must use project_build parameters without timeout_seconds.")
        }
        let directory = try reader.resolve(args["directory"] as? String ?? ".")
        guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              args["test_filter"] == nil || ((args["test_filter"] as? String).map { !$0.isEmpty && $0.count <= 256 && !$0.contains("\0") && !$0.contains("\n") } == true),
              args["scheme"] == nil || ((args["scheme"] as? String)?.range(of: #"^[A-Za-z0-9][A-Za-z0-9_. -]{0,127}$"#, options: .regularExpression) != nil) else {
            throw ToolExecutionFailure(message: "Invalid required check directory, scheme or filter.")
        }
        var normalized = args as? [String: String] ?? [:]
        normalized["directory"] = directory.path
        normalized["configuration"] = args["configuration"] as? String ?? "Debug"
        for key in ["project", "workspace"] {
            if let path = args[key] as? String {
                let target = path.hasPrefix("/") ? path : directory.appendingPathComponent(path).path
                normalized[key] = try reader.resolve(target).path
            }
        }
        let data = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
        return CodingCheckRequirement(id: ManagedTextSnapshot.digest(data), action: action,
            argumentsJSON: String(decoding: data, as: UTF8.self))
    }
    let service: FileAreaService
    let space: AppSpace
    let workspaceRoot: String
    /// 受信任的测试存储注入，模型参数不能指定缓存根。
    var cacheRoot: URL? = nil
    var codingTask: CodingTaskRuntime? = nil
    var repository: RepositoryReader? = nil
    var run: @Sendable (ChildProcessRequest) async -> ChildProcessResult = { await ChildProcessRunner.run($0) }

    var requiresConfirmation: Bool { true }
    var permissionClass: PermissionClass { .codeExecution }
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { true }
    func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .hostExecution }
    func writeTargets(argumentsJSON: String) -> [String] {
        (try? directory(ToolArguments.parse(argumentsJSON))).map { [$0.path] } ?? [workspaceRoot]
    }
    var definition: ToolDefinition {
        ToolDefinition(name: "project_build", description:
            "Explicitly run a host build/test with child processes. Requires danger-full-access and fresh hard confirmation on every call; no remembered approvals, no automatic sandbox fallback. Project build scripts may access host files, network and processes: the directory is not an OS sandbox boundary. Supported actions: swift_build, swift_test, xcode_build, xcode_test. Uses fixed executable/argv and space-specific caches; directory must be inside the bound conversation workspace and managed roots. Returns structured diagnostics, a saved bounded log and revision verification. Optional test_filter selects Swift tests or an Xcode test identifier. Choose this operation only when the user intends a host build, never to retry an unrelated sandbox denial.",
            parametersSchemaJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["swift_build","swift_test","xcode_build","xcode_test"]},"directory":{"type":"string","description":"Project folder inside the bound workspace; default workspace root"},"project":{"type":"string","description":"Xcode .xcodeproj path; mutually exclusive with workspace"},"workspace":{"type":"string","description":"Xcode .xcworkspace path; mutually exclusive with project"},"scheme":{"type":"string"},"test_filter":{"type":"string","description":"For test actions only: Swift test filter or Xcode Target/Class/method identifier"},"configuration":{"type":"string","enum":["Debug","Release"]},"timeout_seconds":{"type":"integer","minimum":30,"maximum":1800}},"required":["action"],"additionalProperties":false}"#)
    }

    /// 可信摘要：宿主构建不受 App Sandbox 保护，不能承诺项目级隔离。
    func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        let args = ToolArguments.parse(argumentsJSON)
        let directory = (try? directory(args))?.path
        var details: [String] = []
        if let action = args["action"] as? String { details.append("action=\(action)") }
        for key in ["project", "workspace", "test_filter"] {
            if let value = args[key] as? String { details.append("\(key)=\(value)") }
        }
        if let scheme = args["scheme"] as? String { details.append("scheme=\(scheme)") }
        if let configuration = args["configuration"] as? String { details.append("configuration=\(configuration)") }
        if let timeout = args["timeout_seconds"] as? Int { details.append("timeout=\(timeout)s") }
        return ToolApprovalPresentation(
            executionKind: .hostBuild, startingDirectory: directory,
            resourceAccess: .host,
            network: .init(allowed: true, detail: "host_network"),
            childProcesses: .init(allowed: true, detail: "host_processes"),
            reasonCode: "host_build",
            constraintSources: ["space", "sessionWorkspace", "mode"],
            executionDetails: details
        )
    }

    func directory(_ args: [String: Any]) throws -> URL {
        guard let bound = FileAreaService.expandHome(workspaceRoot) else { throw invalid() }
        let root = try service.resolveManaged(bound.path)
        guard args["directory"] == nil || args["directory"] is String else { throw invalid() }
        let raw = args["directory"] as? String ?? "."
        guard !raw.contains("\0"), !raw.split(separator: "/").contains("..") else { throw invalid() }
        let target = (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw)).standardizedFileURL
        let resolved = try service.resolveManaged(target.path)
        guard target.path == resolved.path, FileAreaService.isInside(resolved, root: root),
              !ScriptSandbox.privateRoots(space: space).contains(where: { FileAreaService.isInside(resolved, root: $0) }),
              (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw invalid() }
        return resolved
    }

    func request(args: [String: Any], cache: URL, temporary: URL) throws -> ChildProcessRequest {
        let allowed: Set<String> = ["action", "directory", "project", "workspace", "scheme", "test_filter", "configuration", "timeout_seconds"]
        guard args.keys.allSatisfy(allowed.contains), let action = args["action"] as? String,
              ["swift_build", "swift_test", "xcode_build", "xcode_test"].contains(action),
              args["configuration"] == nil || args["configuration"] is String,
              args["timeout_seconds"] == nil || args["timeout_seconds"] is Int else { throw invalid() }
        let configuration = args["configuration"] as? String ?? "Debug"
        let timeout = args["timeout_seconds"] as? Int ?? 600
        guard ["Debug", "Release"].contains(configuration), (30...1800).contains(timeout) else { throw invalid() }
        let directory = try directory(args)
        let executable: String
        var arguments: [String]
        let filter = args["test_filter"] as? String
        guard args["test_filter"] == nil || filter != nil,
              filter == nil || ((action == "swift_test" || action == "xcode_test") && !filter!.isEmpty
                && filter!.count <= 256 && !filter!.contains("\0") && !filter!.contains("\n")) else { throw invalid() }
        if action.hasPrefix("xcode_") {
            let isWorkspace = args["workspace"] != nil
            guard !(isWorkspace && args["project"] != nil),
                  let project = args[isWorkspace ? "workspace" : "project"] as? String, !project.contains("\0"),
                  !project.split(separator: "/").contains(".."), let scheme = args["scheme"] as? String,
                  scheme.range(of: #"^[A-Za-z0-9][A-Za-z0-9_. -]{0,127}$"#, options: .regularExpression) != nil else { throw invalid() }
            let url = (project.hasPrefix("/") ? URL(fileURLWithPath: project) : directory.appendingPathComponent(project)).standardizedFileURL
            guard url.pathExtension == (isWorkspace ? "xcworkspace" : "xcodeproj"), FileAreaService.isInside(url, root: directory),
                  try service.resolveManaged(url.path).path == url.path,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent(isWorkspace ? "contents.xcworkspacedata" : "project.pbxproj").path) else { throw invalid() }
            executable = "/usr/bin/xcodebuild"
            arguments = ["-quiet", isWorkspace ? "-workspace" : "-project", url.path, "-scheme", scheme, "-configuration", configuration,
                "-destination", "platform=macOS", "-derivedDataPath", cache.appendingPathComponent("DerivedData").path,
                "-clonedSourcePackagesDirPath", cache.appendingPathComponent("SourcePackages").path, action == "xcode_test" ? "test" : "build"]
            if let filter { arguments.append("-only-testing:" + filter) }
        } else {
            guard args["project"] == nil, args["workspace"] == nil, args["scheme"] == nil,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) else { throw invalid() }
            executable = "/usr/bin/swift"
            arguments = [action == "swift_test" ? "test" : "build", "--quiet", "--package-path", directory.path,
                "--scratch-path", cache.appendingPathComponent("swift").path,
                "--cache-path", cache.appendingPathComponent("packages").path, "--configuration", configuration.lowercased()]
            if let filter { arguments += ["--filter", filter] }
        }
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": temporary.appendingPathComponent("home").path,
            "TMPDIR": temporary.appendingPathComponent("tmp").path, "LANG": "en_US.UTF-8"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], developer.hasPrefix("/"), !developer.contains("\0") {
            environment["DEVELOPER_DIR"] = developer
        }
        return ChildProcessRequest(executable: URL(fileURLWithPath: executable), arguments: arguments, workingDirectory: directory,
            environment: environment, standardInputData: Data(), timeout: TimeInterval(timeout), outputLimit: 128 * 1024,
            mergeStandardError: true, label: "project_build")
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let project = try directory(args)
        let key = ManagedTextSnapshot.digest(Data(project.path.utf8))
        let cache = (cacheRoot ?? PythonSpacePaths.root(space: space)).appendingPathComponent("build-cache/\(key)")
        let logRoot = service.defaultChatRoot(for: space).appendingPathComponent(".agroom-builds/\(UUID().uuidString)")
        let spec = try request(args: args, cache: cache, temporary: logRoot)
        var checkArgs = args
        checkArgs.removeValue(forKey: "timeout_seconds")
        let checkID = try repository.map { try Self.checkRequirement(checkArgs, reader: $0).id }
        try await codingTask?.activateIfNeeded()
        for path in [cache, logRoot.appendingPathComponent("home"), logRoot.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let repository = self.repository
        let inputRevision = try? await Task.detached { try repository?.revision() }.value
        let result = await run(spec)
        let outputRevision = try? await Task.detached { try repository?.revision() }.value
        let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let log = logRoot.appendingPathComponent("build.log")
        try SecureFileWriter.write(Data(output.utf8), to: log, root: logRoot, policy: .createOnly)
        let diagnostics = CodingBuildDiagnostics.parse(output)
        var verification = CodingVerification(runID: codingTask?.runID ?? UUID(), action: args["action"] as? String ?? "",
            directory: project.path, exitCode: result.exitCode, succeeded: result.succeeded,
            inputRevision: inputRevision, outputRevision: outputRevision, logPath: log.path, diagnostics: diagnostics)
        verification.checkID = checkID
        if let codingTask { try await codingTask.recordVerification(verification) }
        if result.outcome.isCancelled { throw CancellationError() }
        let outcome: String
        switch result.outcome {
        case .exited: outcome = result.succeeded ? "passed" : "failed"
        case .timedOut: outcome = "timedOut"
        case .launchFailed: outcome = "launchFailed"
        case .indeterminate: outcome = "indeterminate"
        case .resourceLimited: outcome = "resourceLimited"
        case .cancelled: outcome = "cancelled"
        }
        struct Report: Encodable {
            let action: String; let exit_code: Int32; let outcome: String; let log: String
            let revision_verified: Bool; let input_revision: String?; let output_revision: String?
            let diagnostics: [CodingDiagnostic]; let diagnostics_truncated: Bool; let log_tail: String
        }
        var displayed = Array(diagnostics.prefix(8))
        var shortened = diagnostics.count > displayed.count
        var tail = String(output.suffix(1200))
        func excerpt() -> Report {
            Report(action: verification.action, exit_code: result.exitCode, outcome: outcome, log: log.path,
                revision_verified: verification.revisionVerified, input_revision: inputRevision, output_revision: outputRevision,
                diagnostics: displayed, diagnostics_truncated: shortened, log_tail: tail)
        }
        if try CodingJSON.encode(excerpt()).count > 5000 {
            displayed = displayed.map { var item = $0; item.relatedLocations = nil; return item }
            shortened = true
            tail = String(output.suffix(500))
        }
        while try CodingJSON.encode(excerpt()).count > 5000, !displayed.isEmpty {
            displayed.removeLast(); shortened = true
        }
        let reportData = excerpt()
        let report = "Host build \(outcome); exit code: \(result.exitCode)\n" + (try CodingJSON.encode(reportData))
        guard result.succeeded else { throw ToolExecutionFailure(message: report + "\nDo not retry automatically; build scripts may have changed host state.") }
        return report
    }

    private func invalid() -> ToolExecutionFailure {
        ToolExecutionFailure(message: "Invalid host build request. Select a registered project folder inside the conversation workspace, a fixed supported action and, for Xcode, an existing .xcodeproj plus an exact scheme. Nothing was executed.")
    }
}
