import Foundation

// MARK: - Python Space Paths

/// 空间级 Python 目录布局：解释器环境与执行目录都落在当前空间目录下，
/// `personal` / `work` 各自独立（隔离红线：不跨空间共享解释器环境）。
public enum PythonSpacePaths {

    /// `~/Documents/AgRoom/python/<space>`
    public static func root(space: AppSpace) -> URL {
        PythonRuntimeManager.shared.environmentRoot
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent(space.rawValue, isDirectory: true)
    }

    /// 空间专用虚拟环境：pip 安装与代码执行指向同一解释器，
    /// 否则会出现「装上了却导入不到」的反复故障
    public static func venv(space: AppSpace) -> URL {
        root(space: space).appendingPathComponent("venv", isDirectory: true)
    }

    /// 普通代码执行的临时工作目录（技能脚本不使用它：技能以技能文件夹为工作目录）
    public static func workspace(space: AppSpace, name: String) -> URL {
        root(space: space)
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// 空间虚拟环境内的 python3 可执行文件
    public static func venvInterpreter(space: AppSpace) -> URL {
        venv(space: space).appendingPathComponent("bin/python3")
    }
}

// MARK: - Resolved Python Environment

/// 一轮任务内固定的 Python 执行环境。
/// 包安装（pip）、状态查询（pip list）与代码/技能脚本执行必须指向同一解释器。
public struct PythonEnvironment: Sendable, Equatable {
    /// 所属空间（nil = 受控/测试模式，不经过空间虚拟环境）
    public let space: AppSpace?
    /// 基础解释器（PythonRuntimeManager 当前配置给出）
    public let baseInterpreter: String
    /// 实际执行使用的解释器
    public let interpreter: String
    public let venvRoot: URL
    /// true = 使用空间虚拟环境；false = 显式受控模式使用基础解释器
    public let isVirtual: Bool
    /// 兼容旧环境报告；产品空间环境不允许降级到基础解释器
    public let degradedReason: String?

    public init(
        space: AppSpace?,
        baseInterpreter: String,
        interpreter: String,
        venvRoot: URL,
        isVirtual: Bool,
        degradedReason: String? = nil
    ) {
        self.space = space
        self.baseInterpreter = baseInterpreter
        self.interpreter = interpreter
        self.venvRoot = venvRoot
        self.isVirtual = isVirtual
        self.degradedReason = degradedReason
    }

    /// 稳定环境标识：参与技能脚本授权指纹。切换解释器或环境身份变化必须重新核验授权，
    /// 因此同时包含基础解释器与目标解释器。
    public var identity: String {
        let spaceKey = space?.rawValue ?? "-"
        return [spaceKey, baseInterpreter, interpreter, isVirtual ? "venv" : "base"]
            .joined(separator: "|")
    }
}

public enum PythonEnvironmentError: LocalizedError {
    case noRuntime
    case notPrepared
    case venvCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noRuntime:
            return "No dedicated Python runtime is available in \(PythonRuntimeManager.shared.environmentRoot.path). "
                + "Ask the user to download and install it from Settings → Tools & Automation → Python Environment. "
                + "System Python and external environments are never used."
        case .notPrepared:
            return "Prepare this space’s Python environment in Settings → Python Environment before running scripts or managing packages."
        case .venvCreationFailed(let reason):
            return "Failed to prepare the Python environment for this space: \(reason)"
        }
    }
}

// MARK: - Python Environment Service

/// 统一 Python 环境解析：按空间创建并复用虚拟环境，供安装、查询与执行三方共用。
///
/// 并发协调：同一空间的环境创建在进程内串行复用同一任务；跨进程（App 与 Daemon 同时使用）
/// 依赖「先建到暂存目录、再原子改名」的落位方式——先落下者胜出，后到者复用已有环境。
public actor PythonEnvironmentService {

    public static let shared = PythonEnvironmentService()

    /// venv 创建超时（含下载编译类的重型依赖时会慢，正常为秒级）
    static let venvCreationTimeout: TimeInterval = 300

    private let manager: PythonRuntimeManager
    private var cache: [AppSpace: (base: String, environment: PythonEnvironment)] = [:]
    private var inFlight: [AppSpace: Task<PythonEnvironment, Error>] = [:]

    init(manager: PythonRuntimeManager = .shared) {
        self.manager = manager
    }

    /// 解析当前空间的执行环境；同一基础解释器下复用已建环境。
    /// 解释器配置变更后（下一轮）自动重新解析。
    public func environment(for space: AppSpace, baseInterpreter: String? = nil) async throws -> PythonEnvironment {
        guard let base = baseInterpreter ?? manager.status().pythonPath else {
            throw PythonEnvironmentError.noRuntime
        }
        guard manager.isManagedInterpreter(base) else { throw PythonEnvironmentError.noRuntime }
        if let cached = cache[space], cached.base == base,
           Self.existingEnvironment(for: space, baseInterpreter: base) != nil {
            return cached.environment
        }
        if let running = inFlight[space] {
            return try await running.value
        }
        let task = Task { [base] in
            try await Self.prepare(space: space, base: base)
        }
        inFlight[space] = task
        defer { inFlight[space] = nil }
        let environment = try await task.value
        cache[space] = (base, environment)
        return environment
    }

    /// 查询绝不创建目录或启动解释器；只返回已经就绪的空间环境。
    public nonisolated static func existingEnvironment(for space: AppSpace, baseInterpreter: String?) -> PythonEnvironment? {
        guard let baseInterpreter,
              PythonRuntimeManager.shared.isManagedInterpreter(baseInterpreter),
              PythonRuntimeManager.isUnredirectedDirectory(PythonSpacePaths.venv(space: space),
                  in: PythonRuntimeManager.shared.environmentRoot),
              isIsolatedVenv(at: PythonSpacePaths.venv(space: space), baseInterpreter: baseInterpreter) else { return nil }
        return PythonEnvironment(space: space, baseInterpreter: baseInterpreter,
            interpreter: PythonSpacePaths.venvInterpreter(space: space).path,
            venvRoot: PythonSpacePaths.venv(space: space), isVirtual: true)
    }

    /// 同步可读的计划环境标识（授权指纹用）：只做路径推导，不创建环境。
    /// 口径与实际执行一致——目标解释器固定为空间虚拟环境内的 python3。
    public nonisolated static func plannedIdentity(
        space: AppSpace,
        baseInterpreter: String?
    ) -> String? {
        guard let baseInterpreter,
              PythonRuntimeManager.shared.isManagedInterpreter(baseInterpreter, requireExecutable: false) else { return nil }
        let root = PythonSpacePaths.root(space: space)
        let revisionURL = root.appendingPathComponent("environment-revision")
        guard PythonRuntimeManager.isUnredirectedDirectory(root, in: PythonRuntimeManager.shared.environmentRoot),
              PythonRuntimeManager.contains(revisionURL, in: root) else { return nil }
        let revision: String
        if FileManager.default.fileExists(atPath: revisionURL.path) {
            guard let value = try? String(contentsOf: revisionURL, encoding: .utf8) else { return nil }
            revision = value
        } else { revision = "initial" }
        return [
            space.rawValue,
            baseInterpreter,
            PythonSpacePaths.venvInterpreter(space: space).path,
            "venv", revision
        ].joined(separator: "|")
    }

    private static func prepare(space: AppSpace, base: String) async throws -> PythonEnvironment {
        let venvRoot = PythonSpacePaths.venv(space: space)
        if let existing = existingEnvironment(for: space, baseInterpreter: base) { return existing }
        do {
            guard PythonRuntimeManager.isUnredirectedDirectory(venvRoot, in: PythonRuntimeManager.shared.environmentRoot) else {
                throw PythonEnvironmentError.venvCreationFailed("The space environment points outside Documents/AgRoom.")
            }
            guard !FileManager.default.fileExists(atPath: venvRoot.path) else {
                throw PythonEnvironmentError.venvCreationFailed("The existing environment is invalid or refers to an external Python. Recreate this space's environment in Documents/AgRoom.")
            }
            try await createVenv(base: base, at: venvRoot)
            guard let environment = existingEnvironment(for: space, baseInterpreter: base) else {
                throw PythonEnvironmentError.venvCreationFailed("The environment does not use the dedicated runtime.")
            }
            return environment
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 空间隔离依赖真实 venv；创建失败不得回退到可修改的共享基础环境。
            HubLogger.shared.warning(
                "Python venv preparation failed for space '\(space.rawValue)': \(HubLogger.safeErrorSummary(error))"
            )
            if let environmentError = error as? PythonEnvironmentError { throw environmentError }
            throw PythonEnvironmentError.venvCreationFailed(error.localizedDescription)
        }
    }

    /// 不能把「目录里有 python3」当成隔离成立：venv 的 home 和解释器链接也必须受管，
    /// 且禁止继承基础环境的 site-packages。
    static func isIsolatedVenv(at root: URL, baseInterpreter: String) -> Bool {
        let python = root.appendingPathComponent("bin/python3")
        let runtime = URL(fileURLWithPath: baseInterpreter).deletingLastPathComponent().deletingLastPathComponent()
        let resolved = python.standardizedFileURL.resolvingSymlinksInPath()
        let configURL = root.appendingPathComponent("pyvenv.cfg")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              PythonRuntimeManager.isUnredirectedDirectory(python.deletingLastPathComponent(), in: root),
              PythonRuntimeManager.contains(resolved, in: root.resolvingSymlinksInPath())
                || PythonRuntimeManager.contains(resolved, in: runtime.resolvingSymlinksInPath()),
              PythonRuntimeManager.contains(configURL, in: root),
              let config = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        var values: [String: String] = [:]
        for line in config.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0].lowercased()] = parts[1] }
        }
        guard values["include-system-site-packages"]?.lowercased() == "false",
              let home = values["home"], home.hasPrefix("/") else { return false }
        return PythonRuntimeManager.contains(URL(fileURLWithPath: home), in: runtime)
    }

    /// 创建虚拟环境：先建到同父目录的暂存目录并验证可用，再原子改名落位。
    /// 目标已存在时直接复用（跨进程并发时后到者不会覆盖先到者的环境）。
    static func createVenv(base: String, at target: URL) async throws {
        let fileManager = FileManager.default
        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("venv-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let result = await ChildProcessRunner.run(ChildProcessRequest(
            executable: URL(fileURLWithPath: base),
            arguments: ["-I", "-S", "-m", "venv", staging.path],
            workingDirectory: parent,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                          "HOME": parent.path, "TMPDIR": NSTemporaryDirectory()],
            timeout: venvCreationTimeout,
            outputLimit: 8_000,
            mergeStandardError: true,
            label: "python-venv"
        ))
        if result.outcome.isCancelled { throw CancellationError() }
        guard result.outcome.isSuccess else {
            let detail = (result.stdout + result.stderr).suffix(400)
            throw PythonEnvironmentError.venvCreationFailed(String(detail))
        }
        guard fileManager.isExecutableFile(
            atPath: staging.appendingPathComponent("bin/python3").path
        ) else {
            throw PythonEnvironmentError.venvCreationFailed("venv did not produce bin/python3")
        }
        // 已被其他进程建好：把本次暂存结果丢弃即可，不覆盖既有环境
        if fileManager.fileExists(atPath: target.path) { return }
        do {
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            // 并发下先到者已落位：复用其环境，其余情况如实抛出
            guard fileManager.fileExists(atPath: target.path) else { throw error }
        }
    }
}
