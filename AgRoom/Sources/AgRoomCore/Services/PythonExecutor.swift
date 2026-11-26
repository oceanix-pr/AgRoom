import Foundation
import Darwin
import AgRoomScriptIPC
import CryptoKit

// MARK: - Python Execution Result

public struct PythonExecutionResult: Sendable {
    public let outcome: ChildProcessOutcome
    public let stdout: String
    public let stderr: String
    public let duration: TimeInterval
    public let outputDirectory: URL?
    /// Bytes captured from this invocation's private scratch directory, keyed relative to scratch.
    var skillOutputs: [String: ScriptBundleSnapshot.Entry] = [:]
    var inheritedSkillPaths: Set<String> = []

    public var exitCode: Int32 { outcome.exitCode ?? -1 }
    public var succeeded: Bool { outcome.isSuccess }
    public var timedOut: Bool { outcome.isTimedOut }
    public var cancelled: Bool { outcome.isCancelled }
    public var indeterminate: Bool {
        if case .indeterminate = outcome { return true }
        if case .launchFailed = outcome { return true }
        return false
    }

    public init(
        outcome: ChildProcessOutcome,
        stdout: String,
        stderr: String,
        duration: TimeInterval,
        outputDirectory: URL? = nil
    ) {
        self.outcome = outcome
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
        self.outputDirectory = outputDirectory
    }

    /// 面向展示的合并输出（截断保护）
    public var displayOutput: String {
        var parts: [String] = []
        if !stdout.isEmpty { parts.append(stdout) }
        if !stderr.isEmpty { parts.append("[stderr]\n" + stderr) }
        switch outcome {
        case .timedOut:
            parts.append("[timeout] Execution exceeded the time limit and was terminated.")
        case .cancelled:
            parts.append("[cancelled] Execution was stopped before completion.")
        case .launchFailed(let reason):
            parts.append("[launch failed] " + reason)
        case .indeterminate(let reason):
            parts.append("[indeterminate] " + reason)
        case .resourceLimited(let reason):
            parts.append("[resource_limit] " + reason)
        case .exited:
            break
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Python Executor

/// Python 执行器：每次使用独立目录与离线进程围栏，失败时不回退无围栏执行。
///
/// 两种运行模式：
/// - 空间环境模式（调度工具面使用）：解释器来自当前空间的统一环境对象，
///   `python_execute` / `python_packages` / `python_package_manage` / `skill_run_script`
///   全部指向同一解释器，消除「装上了却导入不到」；
/// - 受控模式（测试/受控验证使用）：显式指定工作目录根，使用基础解释器。
public final class PythonExecutor: @unchecked Sendable {

    /// 一轮内固定的输入授权计划：确认卡、授权身份与执行授权共同消费。
    private struct InputScope: Sendable {
        let runtime: URL?
        let environment: URL?
        let workspaces: [URL]
        let workspaceIdentities: [String: TaskDirectoryIdentity]?
        var workspace: URL? { workspaces.first }
        init(runtime: PythonRuntimeStatus, space: AppSpace?, workspace: URL?, workspaces: [URL]? = nil) {
            self.runtime = runtime.pythonPath.map { PythonExecutor.runtimeRoot(for: URL(fileURLWithPath: $0)) }
            self.environment = space.map(PythonSpacePaths.venv)
            let resolvedWorkspaces = (workspaces ?? [workspace].compactMap { $0 })
                .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            self.workspaces = resolvedWorkspaces
            workspaceIdentities = workspaces.map { _ in
                Dictionary(resolvedWorkspaces.compactMap { root in
                    (try? TaskDirectoryIdentity.capture(root)).map { (root.path, $0) }
                }, uniquingKeysWith: { first, _ in first })
            }
        }
        var runtimeRoots: [URL] { [runtime, environment].compactMap { $0 } + PythonExecutor.systemReadRoots }
        func validateWorkspaces() throws {
            guard let workspaceIdentities else { return }
            guard workspaces.allSatisfy({ workspaceIdentities[$0.path]?.matches($0) == true }) else {
                throw ToolExecutionFailure(message: "A referenced workspace folder moved or was replaced. Start a new turn after checking the workspace folders. Nothing was executed.")
            }
        }
    }

    private let inputScope: InputScope

    private static func runtimeRoot(for interpreter: URL) -> URL {
        let resolved = interpreter.resolvingSymlinksInPath()
        if let range = resolved.path.range(of: "/Python.framework/") {
            return URL(fileURLWithPath: String(resolved.path[..<range.upperBound]))
        }
        return resolved.deletingLastPathComponent().deletingLastPathComponent()
    }

    public enum ExecutorError: LocalizedError {
        case noRuntime
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .noRuntime:
                return PythonEnvironmentError.noRuntime.localizedDescription
            case .encodingFailed:
                return "The Python code could not be encoded as UTF-8."
            }
        }
    }

    public static let defaultTimeout: TimeInterval = 30
    private static let outputLimit = 8000
    /// 解释器/stdlib 使用的公开系统资源；存在的路径才会发放只读授权。
    static let systemReadRoots = [
        "/System", "/usr/lib", "/usr/share", "/bin", "/usr/bin", "/sbin", "/usr/sbin",
        "/Library/Apple/System", "/Applications/Xcode.app/Contents/Developer",
        "/Library/Developer/CommandLineTools", "/opt/homebrew/Cellar", "/opt/homebrew/lib", "/usr/local/Cellar", "/usr/local/lib",
        "/private/etc/mime.types", "/private/etc/httpd/mime.types", "/private/etc/apache2/mime.types"
    ].map { URL(fileURLWithPath: $0) }

    /// 技能启动器源码：显式把已校验的目录加入模块搜索路径后，用 runpy 执行真实入口。
    /// 直接 `python3 -I scripts/main.py` 会在隔离模式下屏蔽脚本目录，同目录模块无法导入。
    /// 配置经 JSON 文件传入，路径含中文/空格/引号都不会被拼进 Python 源码。
    static let launcherSource = """
    import json, runpy, sys


    def __agroom_run():
        with open(sys.argv[1], "r", encoding="utf-8") as handle:
            config = json.load(handle)
        for path in reversed(config.get("search_paths", [])):
            if path:
                sys.path.insert(0, path)
        sys.argv = list(config.get("argv", []))
        runpy.run_path(config["entry"], run_name="__main__")


    __agroom_run()
    """

    private let manager = PythonRuntimeManager.shared
    /// 每次执行使用独立子目录（执行之间互不污染）
    private let workspaceName: String
    /// 受控模式的执行目录根覆盖（nil = 空间环境模式或托管运行时默认位置）
    private let workspaceRootOverride: URL?
    /// 空间环境模式：解释器来自该空间的统一环境对象
    private let space: AppSpace?
    private let configuredRuntime: PythonRuntimeStatus
    private let sandboxRunner: ScriptAppSandbox?
    /// Only the internal signed-runner test initializer can supply this exact interpreter.
    private let testInterpreterPath: String?

    public init(workspaceName: String = "default", workspaceRoot: URL? = nil) {
        self.workspaceName = workspaceName
        self.workspaceRootOverride = workspaceRoot
        self.space = nil
        self.configuredRuntime = PythonRuntimeManager.shared.status()
        self.sandboxRunner = nil
        self.testInterpreterPath = nil
        self.inputScope = InputScope(runtime: configuredRuntime, space: nil, workspace: workspaceRoot)
    }

    /// 空间环境模式：安装、查询与执行共用当前空间的解释器；space 为 nil 时回退到受控模式
    public init(space: AppSpace?, workspaceName: String = "run", readWorkspace: URL? = nil, runRoot: URL? = nil,
                readWorkspaces: [URL]? = nil) {
        self.workspaceName = workspaceName
        self.workspaceRootOverride = runRoot
        self.space = space
        self.configuredRuntime = PythonRuntimeManager.shared.status()
        self.sandboxRunner = nil
        self.testInterpreterPath = nil
        self.inputScope = InputScope(runtime: configuredRuntime, space: space, workspace: readWorkspace, workspaces: readWorkspaces)
    }

    /// 真实签名执行器集成回归；仅改变后端，不接触用户空间环境和数据。
    init(workspaceRoot: URL, sandboxRunner: ScriptAppSandbox, runtime: PythonRuntimeStatus? = nil) {
        self.workspaceName = "sandbox-integration"
        self.workspaceRootOverride = workspaceRoot
        self.space = nil
        self.configuredRuntime = runtime ?? PythonRuntimeManager.shared.status()
        self.sandboxRunner = sandboxRunner
        self.testInterpreterPath = runtime?.pythonPath
        self.inputScope = InputScope(runtime: configuredRuntime, space: nil, workspace: workspaceRoot)
    }

    /// 当前运行时状态（基础解释器是否可用；用于「Python 是否可用」的前置判断）
    public var runtimeStatus: PythonRuntimeStatus { configuredRuntime }

    /// 是否具备产品级签名执行器后端。真实签名/协议在每次执行时仍会重新核验；
    /// 这里只用于判断某次调用能否进入模型审核候选，不能代替执行前校验。
    public var hasVerifiedSandboxBackend: Bool {
        sandboxRunner != nil || space != nil
    }

    // MARK: - Environment

    /// 本轮实际采用的执行环境（空间环境模式）；受控模式返回 nil
    public func currentEnvironment() async -> PythonEnvironment? {
        guard let space else { return nil }
        return PythonEnvironmentService.existingEnvironment(for: space, baseInterpreter: configuredRuntime.pythonPath)
    }

    /// Bound workspace for selecting inputs. A workspace grant is issued only when selected.
    public var approvalReadWorkspacePath: String? { inputScope.workspace?.path }
    public var approvalReadablePaths: [String] { approvalPaths(for: []) }

    public struct WorkspaceInput: Codable, Equatable, Sendable {
        let path: String
        let identity: ScriptRunnerFileIdentity

        func validate() throws {
            guard ScriptRunnerFileIdentity.capture(URL(fileURLWithPath: path)) == identity else {
                throw ScriptIsolationError.invalidScope
            }
        }
    }

    func selectedInputs(_ args: [String: Any]) throws -> [WorkspaceInput] {
        guard let value = args["input_paths"] else { return [] }
        guard let paths = value as? [String], paths.count <= 32 else { throw ScriptIsolationError.invalidScope }
        let denied = space.map(ScriptSandbox.privateRoots) ?? []
        if !paths.isEmpty { try inputScope.validateWorkspaces() }
        return try Set(paths).sorted().map { path in
            guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else {
                throw ScriptIsolationError.invalidScope
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard ScriptSandbox.permitsProjectRoot(url),
                  inputScope.workspaces.contains(where: { FileAreaService.isInside(url, root: $0) }),
                  !denied.contains(where: { FileAreaService.isInside(url, root: $0) }),
                  let identity = ScriptRunnerFileIdentity.capture(url) else { throw ScriptIsolationError.invalidScope }
            return WorkspaceInput(path: url.path, identity: identity)
        }
    }

    func approvalPaths(for inputs: [WorkspaceInput]) -> [String] {
        [inputScope.runtime, inputScope.environment].compactMap { $0?.path }
            + inputs.map(\.path) + [ToolApprovalPresentation.ScopeToken.systemBaseline]
    }

    /// 同步可读的环境标识（授权指纹用）：只做路径推导，不创建环境
    public var environmentIdentity: String? {
        if let space {
            return PythonEnvironmentService.plannedIdentity(
                space: space, baseInterpreter: configuredRuntime.pythonPath
            )
        }
        return configuredRuntime.pythonPath
    }

    /// 解析实际执行解释器
    private func interpreterPath() throws -> String {
        guard let base = configuredRuntime.pythonPath,
              manager.isManagedInterpreter(base) || (sandboxRunner != nil && space == nil && testInterpreterPath == base) else {
            throw ExecutorError.noRuntime
        }
        if let space {
            guard let environment = PythonEnvironmentService.existingEnvironment(for: space, baseInterpreter: base) else {
                throw PythonEnvironmentError.notPrepared
            }
            return environment.interpreter
        }
        return base
    }

    /// 唯一的运行根，同时用来派生本次目录和声明任务的产物范围。
    var runStorageRoot: URL {
        if let override = workspaceRootOverride {
            return override.appendingPathComponent(workspaceName, isDirectory: true)
        }
        if let space { return PythonSpacePaths.workspace(space: space, name: workspaceName) }
        return manager.sandboxRoot.appendingPathComponent(workspaceName, isDirectory: true)
    }

    public func workspaceDir() throws -> URL {
        try Self.createRun(in: runStorageRoot)
    }

    private static func createRun(in dir: URL) throws -> URL {
        let parent = try AppDirectory(url: dir, create: true)
        Self.cleanExpiredEmptyRuns(in: try parent.kernelURL())
        let runName = UUID().uuidString
        let run = try parent.child(runName, create: true)
        for name in ["output", "tmp", "home"] {
            _ = try run.child(name, create: true)
        }
        // Preserve Foundation's spelling of system /var aliases for callers that
        // compare descendant URLs; creation itself remains descriptor-relative.
        return dir.appendingPathComponent(runName, isDirectory: true)
    }

    /// 只清理过期且无业务产物的 UUID 运行目录；持有运行锁或有产物时保留。
    static func cleanExpiredEmptyRuns(in root: URL, now: Date = Date()) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]) else { return }
        var removed = 0
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            guard removed < 32,
                  let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true, values.isDirectory == true,
                  let date = values.contentModificationDate, now.timeIntervalSince(date) > 7 * 24 * 60 * 60 else { continue }
            let outputs = ["output", "skill/scratch"].map { child.appendingPathComponent($0) }
            guard outputs.allSatisfy({ output in
                if !FileManager.default.fileExists(atPath: output.path) { return true }
                return (try? FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty) == true
            }) else { continue }
            let descriptor = open(child.appendingPathComponent(".execution.lock").path,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                do { try FileManager.default.removeItem(at: child); removed += 1 }
                catch { HubLogger.shared.warning("Expired empty Python run cleanup failed.") }
                flock(descriptor, LOCK_UN)
            }
            close(descriptor)
        }
    }

    /// 执行代码片段：写入临时脚本文件后以 python3 运行。
    /// 使用隔离模式（`-I`），工作目录为本次执行自己的临时目录，不加入任何技能目录。
    public func execute(code: String, timeout: TimeInterval = defaultTimeout,
                        expectedEnvironmentIdentity: String? = nil, workspaceInputs: [WorkspaceInput] = []) async throws -> PythonExecutionResult {
        let pythonPath = try interpreterPath()
        let dir = try workspaceDir()
        let scriptURL = dir.appendingPathComponent("run_\(UUID().uuidString.prefix(8)).py")
        try Self.writeScript(code, to: scriptURL)
        defer { Self.removeQuietly(scriptURL) }

        return try await runProcess(
            executable: pythonPath,
            arguments: ["-I", "-B", scriptURL.path],
            workingDirectory: dir.appendingPathComponent("output"),
            runDirectory: dir,
            timeout: timeout,
            expectedEnvironmentIdentity: expectedEnvironmentIdentity,
            workspaceInputs: workspaceInputs
        )
    }

    /// Application functions receive JSON and frozen files, never a live application directory.
    /// The caller validates result.json and artifacts before publishing any business data.
    func executeAppScript(source: String, payload: Data, files: [String: Data],
                          timeout: TimeInterval, expectedEnvironmentIdentity: String?) async throws -> PythonExecutionResult {
        let pythonPath = try interpreterPath()
        let dir = try workspaceDir()
        var returned = false
        defer { if !returned { try? FileManager.default.removeItem(at: dir) } }
        let root = try AppDirectory(url: dir, create: false)
        try root.write(Data(source.utf8), name: "function.py")
        try root.write(payload, name: "input.json")
        let inputs = try root.child("inputs", create: true)
        for (key, bytes) in files {
            guard NativeAppDefinition.validID(key) else { throw NativeAppError(.unsafePath) }
            try inputs.write(bytes, name: key)
        }
        _ = try root.child("output", create: false).child("artifacts", create: true)
        try root.write(Data(Self.appLauncherSource.utf8), name: "launcher.py")
        let result = try await runProcess(executable: pythonPath,
            arguments: ["-I", "-B", dir.appendingPathComponent("launcher.py").path, dir.path],
            workingDirectory: dir.appendingPathComponent("output"), runDirectory: dir,
            timeout: timeout, expectedEnvironmentIdentity: expectedEnvironmentIdentity,
            workspaceInputs: [])
        returned = true
        return result
    }

    private static let appLauncherSource = """
    import json, pathlib, runpy, sys

    root = pathlib.Path(sys.argv[1])
    with (root / 'input.json').open('r', encoding='utf-8') as handle:
        payload = json.load(handle)
    context = {
        'records': payload['records'],
        'data': payload.get('data') or {},
        'files': {key: dict(info, path=str(root / 'inputs' / key)) for key, info in payload['files'].items()},
        'outputDirectory': str(root / 'output' / 'artifacts')
    }
    main = runpy.run_path(str(root / 'function.py'), run_name='__zhiapp__')['main']
    result = main(payload['inputs'], context)
    with (root / 'output' / 'result.json').open('x', encoding='utf-8') as handle:
        json.dump(result, handle, ensure_ascii=False, allow_nan=False)
    """

    /// 执行技能包内的入口脚本：工作目录为技能根目录，模块搜索路径显式加入
    /// 入口脚本目录与技能根目录，使 `from processor import run` 与
    /// `assets/config.json` 这类相对资源都可用。
    public func executeSkillScript(
        entryURL: URL,
        skillRoot: URL,
        arguments: [String] = [],
        timeout: TimeInterval = defaultTimeout,
        expectedDependencyDigest: String? = nil,
        expectedEnvironmentIdentity: String? = nil,
        workspaceInputs: [WorkspaceInput] = [],
        validateBeforeLaunch: (@Sendable () throws -> Void)? = nil
    ) async throws -> PythonExecutionResult {
        try validateBeforeLaunch?()
        let pythonPath = try interpreterPath()
        let dir = try workspaceDir()
        let originalRoot = skillRoot.standardizedFileURL.resolvingSymlinksInPath()
        let entry = entryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard entry.path.hasPrefix(originalRoot.path + "/") else { throw SkillStore.StoreError.unsafePath }
        let relativeEntry = String(entry.path.dropFirst(originalRoot.path.count + 1))
        let bundle = try ScriptBundleSnapshot(root: originalRoot)
        guard expectedDependencyDigest == nil || expectedDependencyDigest == bundle.digest else {
            throw ToolExecutionFailure(message: "The skill package changed after approval. Nothing was executed; request a fresh approval.")
        }
        let snapshotRoot = dir.appendingPathComponent("skill", isDirectory: true)
        try bundle.write(to: snapshotRoot)
        let output = snapshotRoot.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let oldOutput = originalRoot.appendingPathComponent("scratch", isDirectory: true)
        var inherited: [String: ArtifactFileStamp] = [:]
        if FileManager.default.fileExists(atPath: oldOutput.path) {
            let previous = try ScriptBundleSnapshot(root: oldOutput, outputs: true)
            try previous.write(to: output)
            for entry in previous.entries {
                var info = stat()
                guard lstat(output.appendingPathComponent(entry.path).path, &info) == 0 else {
                    throw TaskArtifactError.unavailable
                }
                inherited[entry.path] = ArtifactFileStamp(info)
            }
        }
        let snapshotEntry = snapshotRoot.appendingPathComponent(relativeEntry)
        let launcherURL = dir.appendingPathComponent("agroom_launcher.py")
        try Self.writeScript(Self.launcherSource, to: launcherURL)
        let configURL = dir.appendingPathComponent("agroom_launch_\(UUID().uuidString.prefix(8)).json")
        let config: [String: Any] = [
            "entry": snapshotEntry.path,
            "search_paths": [snapshotEntry.deletingLastPathComponent().path, snapshotRoot.path],
            "argv": [snapshotEntry.path] + arguments
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try configData.write(to: configURL, options: .atomic)
        defer {
            Self.removeQuietly(configURL)
            Self.removeQuietly(launcherURL)
        }

        let execution = try await runProcess(
            executable: pythonPath,
            arguments: ["-I", "-B", launcherURL.path, configURL.path],
            workingDirectory: snapshotRoot,
            runDirectory: dir,
            timeout: timeout,
            additionalWriteRoots: [output],
            expectedEnvironmentIdentity: expectedEnvironmentIdentity,
            workspaceInputs: workspaceInputs,
            validateBeforeLaunch: validateBeforeLaunch
        )
        var result = PythonExecutionResult(outcome: execution.outcome, stdout: execution.stdout,
            stderr: execution.stderr, duration: execution.duration, outputDirectory: output)
        guard !result.indeterminate else { return result }
        try Task.checkCancellation()
        if result.succeeded, try ScriptBundleSnapshot(root: originalRoot).digest != bundle.digest {
            throw ToolExecutionFailure(message: "The skill package changed while running. Outputs remain in the run directory and were not published into the changed skill.")
        }
        let produced = try ScriptBundleSnapshot(root: output, outputs: true)
        for item in produced.entries {
            try Task.checkCancellation()
            if inherited[item.path] == item.stamp {
                result.inheritedSkillPaths.insert(item.path)
            } else {
                result.skillOutputs[item.path] = item
                if result.succeeded {
                    try SecureFileWriter.write(item.data, to: oldOutput.appendingPathComponent(item.path), root: originalRoot)
                }
            }
        }
        return result
    }

    /// 语法校验（py_compile）：只编译不执行，无副作用。
    /// 用于 AI 生成技能脚本的验证闭环；返回 nil 表示运行时不可用（调用方跳过校验）
    public func compileCheck(code: String) async throws -> PythonExecutionResult? {
        guard configuredRuntime.pythonPath != nil else {
            return nil
        }
        // 语法检查不依赖第三方包，也不能在保存时隐式启动宿主 venv 初始化。
        guard let pythonPath = configuredRuntime.pythonPath else { return nil }
        let dir = try workspaceDir()
        let scriptURL = dir.appendingPathComponent("check_\(UUID().uuidString.prefix(8)).py")
        try Self.writeScript(code, to: scriptURL)
        defer { Self.removeQuietly(scriptURL) }

        return try await runProcess(
            executable: pythonPath,
            // 不加载 site-packages/.pth；语法检查不执行第三方启动钩子。
            arguments: ["-I", "-S", "-c", "import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_bytes())", scriptURL.path],
            workingDirectory: dir,
            runDirectory: dir,
            timeout: 20
        )
    }

    /// 执行 pip 命令（安装/列出包）：使用统一环境的解释器，超时放宽
    public func runPip(arguments: [String], timeout: TimeInterval = 300,
                       expectedEnvironmentIdentity: String? = nil) async throws -> PythonExecutionResult {
        let started = ProcessInfo.processInfo.systemUptime
        let mutation = arguments.first == "install" || arguments.first == "uninstall"
        guard let operation = arguments.first, ["install", "uninstall", "list", "show"].contains(operation) else {
            throw LLMError.configurationError(reason: "Unsupported package operation.")
        }
        if mutation {
            guard space != nil else {
                throw LLMError.configurationError(reason: "Package changes require a space-specific virtual environment.")
            }
            guard let package = arguments.last else { throw LLMError.configurationError(reason: "Missing package name.") }
            _ = try AppTaskToolFactory.validatePackageName(package)
            guard arguments == ["install", package] || arguments == ["uninstall", "-y", package] else {
                throw LLMError.configurationError(reason: "Package options must be selected by the app.")
            }
        } else if operation == "list" {
            guard arguments == ["list"] || arguments == ["list", "--format=columns"] else { throw ScriptIsolationError.invalidScope }
        } else {
            guard arguments.count == 2, arguments[1].wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._-]*$/) != nil else {
                throw ScriptIsolationError.invalidScope
            }
        }
        guard let base = configuredRuntime.pythonPath else { throw ExecutorError.noRuntime }
        let pythonPath = try interpreterPath()
        let expectedIdentity = expectedEnvironmentIdentity ?? environmentIdentity
        if let expectedIdentity, environmentIdentity != expectedIdentity {
            throw ToolExecutionFailure(message: "The Python environment changed. Request a fresh approval.")
        }
        var transfer: URL?
        var canCleanTransfer = true
        defer {
            if canCleanTransfer, let transfer { Self.removeQuietly(transfer) }
        }
        var pipArguments = arguments
        let dir = try workspaceDir()
        if operation == "install", let space, let package = arguments.last {
            guard PackageDownload.validRequirement(package) else { throw ScriptIsolationError.invalidScope }
            let run = try Self.createRun(in: PythonSpacePaths.workspace(space: space, name: "package-downloads"))
            transfer = run
            let wheels = run.appendingPathComponent("output", isDirectory: true)
            let download = try await PythonPackageDownloader().resolve(in: run, timeout: timeout) { remaining in
                try await self.runProcess(executable: base, arguments: PackageDownload.arguments(requirement: package),
                    workingDirectory: wheels, runDirectory: run, timeout: remaining, packageDownload: true)
            }
            canCleanTransfer = !download.indeterminate
            guard download.succeeded else { return download }
            let lock = try AppDirectory(url: wheels, create: false).read("requirements.lock", limit: 128 * 1024)
            try Self.validateWheelManifest(lock)
            try AppDirectory(url: dir, create: false).write(lock, name: "requirements.lock")
            pipArguments = ["install", "--no-index", "--no-deps", "--only-binary=:all:", "--require-hashes",
                            "--find-links", wheels.path, "-r", dir.appendingPathComponent("requirements.lock").path]
        }
        let remaining = timeout - (ProcessInfo.processInfo.systemUptime - started)
        guard remaining > 0 else {
            return PythonExecutionResult(outcome: .timedOut, stdout: "", stderr: "", duration: ProcessInfo.processInfo.systemUptime - started)
        }
        let result = try await runProcess(executable: pythonPath,
            arguments: PackageDownload.offlineArguments(pipArguments),
            workingDirectory: dir, runDirectory: dir, timeout: remaining, environmentMutation: mutation,
            wheelhouse: transfer?.appendingPathComponent("output"), expectedEnvironmentIdentity: mutation ? expectedIdentity : nil)
        canCleanTransfer = !result.indeterminate
        return result
    }

    static func validateWheelManifest(_ data: Data) throws {
        guard let text = String(data: data, encoding: .ascii) else { throw ScriptIsolationError.invalidScope }
        let lines = text.split(separator: "\n")
        guard !lines.isEmpty, lines.count <= 256,
              lines.allSatisfy({ $0.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9_.-]*==[A-Za-z0-9][A-Za-z0-9.!+_-]* --hash=sha256:[a-f0-9]{64}$/) != nil }) else {
            throw ScriptIsolationError.invalidScope
        }
    }

    /// 在统一环境中探测模块是否可见（`-I`，与实际执行同一隔离参数）。
    /// 返回 true/false；运行时不可用返回 nil。
    public func probeModule(importName: String, timeout: TimeInterval = 30) async throws -> Bool? {
        guard configuredRuntime.pythonPath != nil else { return nil }
        let pythonPath = try interpreterPath()
        let dir = try workspaceDir()
        let code = "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec(\(String(reflecting: importName))) else 1)"
        let scriptURL = dir.appendingPathComponent("probe_\(UUID().uuidString.prefix(8)).py")
        try Self.writeScript(code, to: scriptURL)
        defer { Self.removeQuietly(scriptURL) }
        let result = try await runProcess(
            executable: pythonPath,
            arguments: ["-I", scriptURL.path],
            workingDirectory: dir,
            runDirectory: dir,
            timeout: timeout
        )
        return result.succeeded
    }

    // MARK: - Script File Helpers

    /// 写入临时脚本：UTF-8 编码失败必须显式抛错（静默跳过会让进程去跑旧文件）
    private static func writeScript(_ code: String, to url: URL) throws {
        guard let data = code.data(using: .utf8) else {
            throw ExecutorError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    /// 清理临时脚本：失败记警告（不影响执行结果，但堆积可追溯）
    private static func removeQuietly(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch {
            HubLogger.shared.warning("Temp script cleanup failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    // MARK: - Process Runner

    private func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        runDirectory: URL,
        timeout: TimeInterval,
        additionalWriteRoots: [URL] = [],
        environmentMutation: Bool = false,
        packageDownload: Bool = false,
        wheelhouse: URL? = nil,
        expectedEnvironmentIdentity: String? = nil,
        workspaceInputs: [WorkspaceInput] = [],
        validateBeforeLaunch: (@Sendable () throws -> Void)? = nil
    ) async throws -> PythonExecutionResult {
        guard let base = configuredRuntime.pythonPath else { throw ExecutorError.noRuntime }
        let usesTestInterpreter = sandboxRunner != nil && space == nil && testInterpreterPath == base && executable == base
        guard usesTestInterpreter || (manager.isManagedInterpreter(base)
              && PythonRuntimeManager.contains(URL(fileURLWithPath: executable), in: manager.environmentRoot)) else {
            throw ExecutorError.noRuntime
        }
        if executable != base {
            guard let space,
                  PythonEnvironmentService.existingEnvironment(for: space, baseInterpreter: base)?.interpreter == executable else {
                throw PythonEnvironmentError.notPrepared
            }
        }
        let lockRoot = space.map { PythonSpacePaths.root(space: $0) }
            ?? workspaceRootOverride ?? manager.sandboxRoot
        let lease = try await PythonEnvironmentLease.acquire(root: lockRoot, mutation: environmentMutation)
        defer { withExtendedLifetime(lease) {} }
        let runLease = try await PythonEnvironmentLease.acquire(root: runDirectory, mutation: true)
        defer { withExtendedLifetime(runLease) {} }
        if let expectedEnvironmentIdentity, environmentIdentity != expectedEnvironmentIdentity {
            throw ToolExecutionFailure(message: "The Python environment changed after approval. Nothing was executed; request a fresh approval.")
        }
        let interpreter = URL(fileURLWithPath: executable)
        let runtimeRoot = Self.runtimeRoot(for: interpreter)
        guard inputScope.runtime == runtimeRoot else {
            throw ToolExecutionFailure(message: "The interpreter input scope changed. Nothing was executed; start a new turn and request approval again.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        guard runtimeRoot.path != home.path else {
            throw LLMError.configurationError(reason: "This custom Python layout cannot be isolated without granting home-directory access. Select a dedicated Python installation.")
        }
        if !workspaceInputs.isEmpty {
            let verified = try selectedInputs(["input_paths": workspaceInputs.map(\.path)])
            guard verified == workspaceInputs else { throw ScriptIsolationError.invalidScope }
        }
        var reads = inputScope.runtimeRoots + workspaceInputs.map { URL(fileURLWithPath: $0.path) } + [runDirectory]
        if let wheelhouse { reads.append(wheelhouse) }
        if packageDownload {
            guard executable == base, !environmentMutation, workspaceInputs.isEmpty, wheelhouse == nil,
                  additionalWriteRoots.isEmpty else { throw ScriptIsolationError.invalidScope }
            reads = [runtimeRoot, runDirectory]
        }
        var writes = ["output", "tmp", "home"].map { runDirectory.appendingPathComponent($0) } + additionalWriteRoots
        if environmentMutation, let space { writes.append(PythonSpacePaths.venv(space: space)) }
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                           "HOME": runDirectory.appendingPathComponent("home").path,
                           "TMPDIR": runDirectory.appendingPathComponent("tmp").path,
                           "PYTHONDONTWRITEBYTECODE": "1"]
        if !packageDownload { environment["PIP_CONFIG_FILE"] = "/dev/null" }
        let denied = (space.map(ScriptSandbox.privateRoots) ?? []) + ScriptSandbox.legacyRunRoots(in: inputScope.workspaces)
        var plan = ScriptExecutionPlan(executable: interpreter, arguments: arguments, directory: workingDirectory,
            environment: environment, timeout: timeout,
            sandbox: ScriptSandbox(readRoots: reads, writeRoots: writes,
                deniedRoots: denied, allowsNetwork: false))
        plan.resourceBudget = ChildProcessBudget(maximumResidentBytes: ScriptRunnerLimits.maximumResidentBytes,
            maximumOutputBytes: environmentMutation || packageDownload ? 1024 * 1024 * 1024 : ScriptRunnerLimits.maximumOutputBytes,
            maximumOutputFiles: environmentMutation || packageDownload ? 100_000 : ScriptRunnerLimits.maximumOutputFiles,
            outputRoots: writes.filter { $0 != space.map(PythonSpacePaths.venv) })
        let request: ChildProcessRequest
        if let sandboxRunner {
            request = try await sandboxRunner.request(plan: plan, label: "python_execute", outputLimit: Self.outputLimit,
                purpose: packageDownload ? .packageResolution : .script)
        } else if let space {
            let runner = try ScriptAppSandbox.bundled(space: space)
            request = try await runner.request(plan: plan, label: "python_execute", outputLimit: Self.outputLimit,
                purpose: packageDownload ? .packageResolution : .script)
        } else {
            // 显式受控验证入口（SPM 没有签名 App bundle）；产品空间执行绝不降级到这里。
            request = try plan.request(label: "python_execute", outputLimit: Self.outputLimit)
        }
        if environmentMutation, let space {
            // 授权准备完成后、实际执行前失效旧指纹；失败的 pip 也可能改了部分依赖。
            try UUID().uuidString.write(to: PythonSpacePaths.root(space: space).appendingPathComponent("environment-revision"), atomically: true, encoding: .utf8)
        }
        // 租约和沙箱准备均可能挂起；提交进程前复查调用方的实时门禁。
        try Task.checkCancellation()
        try validateBeforeLaunch?()
        for input in workspaceInputs { try input.validate() }
        let result = await ChildProcessRunner.run(request)
        if case .indeterminate = result.outcome {
            // 进程状态不确定时保留全部现场。
        } else {
            for name in ["home", "tmp"] {
                try? FileManager.default.removeItem(at: runDirectory.appendingPathComponent(name))
            }
        }
        if result.outcome.isCancelled {
            // 取消不是失败，也不能被自动重试：让调用方按 CancellationError 收尾。
            throw CancellationError()
        }
        return PythonExecutionResult(
            outcome: result.outcome,
            stdout: result.stdout,
            stderr: result.stderr,
            duration: result.duration,
            outputDirectory: runDirectory.appendingPathComponent("output")
        )
    }
}

// MARK: - Python Execute Tool

/// 调度工具：执行 Python 代码（任意代码执行属危险操作，必须用户确认）
public struct PythonExecuteTool: DispatcherTool {
    let executor: PythonExecutor

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "python_execute",
            description: "Execute Python in a mandatory offline sandbox and return stdout/stderr plus the output directory. "
                + "Only the dedicated runtime and space environment under Documents/AgRoom are used; if missing, ask the user to download the runtime in Python settings. "
                + "Use for calculations, data processing, or plots. Declare each necessary workspace file or directory in input_paths. By default no workspace is mounted. Inputs are read-only. Write artifacts to this run’s output directory; macOS also permits access to the executor’s own space-specific sandbox container. Network access and child processes are blocked even in full-access mode. Do not retry blocked access through another tool.",
            parametersSchemaJSON: #"{"type":"object","properties":{"code":{"type":"string","description":"The Python code to execute"},"input_paths":{"type":"array","items":{"type":"string"},"maxItems":32,"description":"Absolute workspace file or directory paths needed by this code. Prefer individual files."}},"required":["code"]}"#
        )
    }
    public let requiresConfirmation = true
    /// 由执行器强制离线和产物目录围栏；允许工作区模式调用。
    public let permissionClass = PermissionClass.confinedCodeExecution

    /// 离线 Python 可按实际执行档交给模型审核；宿主/缺失执行器仍转人工。
    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute { .modelReviewable }

    public func autoReviewEvidence(argumentsJSON: String) -> [String: String] {
        let code = ToolArguments.string(ToolArguments.parse(argumentsJSON), "code")
        return [
            "execution_profile": "offline_artifacts",
            "network": "false",
            "child_processes": "false",
            "executor_verified": executor.hasVerifiedSandboxBackend ? "true" : "false",
            "environment_identity": executor.environmentIdentity ?? "",
            "code": String(code.prefix(32 * 1024)),
            "evidence_truncated": code.utf8.count > 32 * 1024 ? "true" : "false",
        ]
    }

    public init(executor: PythonExecutor) {
        self.executor = executor
    }

    public func validateArguments(argumentsJSON: String) throws {
        _ = try executor.selectedInputs(ToolArguments.parse(argumentsJSON))
    }

    public func executionAuthorizationKey(argumentsJSON: String) -> String? {
        guard let inputs = try? executor.selectedInputs(ToolArguments.parse(argumentsJSON)) else { return nil }
        return authorizationKey(argumentsJSON, inputs: inputs, environment: executor.environmentIdentity)
    }

    private func authorizationKey(_ argumentsJSON: String, inputs: [PythonExecutor.WorkspaceInput], environment: String?) -> String? {
        struct Identity: Encodable {
            let code: String
            let inputs: [PythonExecutor.WorkspaceInput]
            let environment: String?
        }
        let identity = Identity(code: ToolArguments.string(ToolArguments.parse(argumentsJSON), "code"),
            inputs: inputs, environment: environment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(identity) else { return nil }
        return "python_execute#" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 可信摘要：工作区只读，产物写本次运行目录；联网与子进程始终关闭。
    public func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        guard let inputs = try? executor.selectedInputs(ToolArguments.parse(argumentsJSON)) else { return nil }
        let readable = executor.approvalPaths(for: inputs)
        var details = ["timeout=\(Int(PythonExecutor.defaultTimeout))s"]
        if let environment = executor.environmentIdentity { details.append("environment=\(environment)") }
        return ToolApprovalPresentation(
            executionKind: .offlinePython,
            resourceAccess: ToolApprovalPresentation.ResourceAccess(
                readable: readable,
                writable: [ToolApprovalPresentation.ScopeToken.pythonOutput],
                outputs: [ToolApprovalPresentation.ScopeToken.pythonOutput],
                temporary: [ToolApprovalPresentation.ScopeToken.runTemporary],
                executorContainer: ToolApprovalPresentation.ScopeToken.executorContainer,
                systemBaseline: true,
                verified: true
            ),
            network: .init(allowed: false),
            childProcesses: .init(allowed: false),
            reasonCode: "offline_python",
            constraintSources: ["space", "sessionWorkspace", "executor"],
            executionDetails: details
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        try await execute(argumentsJSON: argumentsJSON, authorizationKey: executionAuthorizationKey(argumentsJSON: argumentsJSON))
    }

    public func execute(argumentsJSON: String, authorizationKey: String?) async throws -> String {
        let inputs = try executor.selectedInputs(ToolArguments.parse(argumentsJSON))
        let environment = executor.environmentIdentity
        guard let authorizationKey, self.authorizationKey(argumentsJSON, inputs: inputs, environment: environment) == authorizationKey else {
            throw ToolExecutionFailure(message: "The approved Python execution changed. Nothing was executed; request a fresh approval.")
        }
        let code = ToolArguments.string(ToolArguments.parse(argumentsJSON), "code")
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "python_execute requires non-empty code."
        }
        let result = try await executor.execute(code: code, expectedEnvironmentIdentity: environment, workspaceInputs: inputs)
        let header = "exit=\(result.exitCode) duration=\(String(format: "%.2f", result.duration))s"
            + (result.timedOut ? " TIMED_OUT" : "")
        let directory = result.outputDirectory.map { "\noutput directory: " + $0.path } ?? ""
        let output = header + directory + "\n" + result.displayOutput
        let skipped: Int
        if !result.indeterminate, let directory = result.outputDirectory {
            do { skipped = try await ToolArtifactCapture.recordDirectory(directory) }
            catch let failure as ToolExecutionFailure { throw ToolExecutionFailure(message: output + "\n" + failure.message) }
        }
        else { skipped = 0 }
        if !result.succeeded { throw ToolExecutionFailure(message: output) }
        return output + (skipped > 0 ? "\n[\(skipped) non-regular or linked entries were excluded from artifact capture.]" : "")
    }
}
