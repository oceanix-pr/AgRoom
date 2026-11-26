import Foundation
import Darwin
import Security
import AgRoomScriptIPC

public enum ScriptIsolationError: LocalizedError, Sendable {
    case unavailable
    case invalidScope
    case diagnostic(ScriptRunnerFailure)
    public var code: String {
        switch self {
        case .unavailable: "runnerUnavailable"
        case .invalidScope: "unverifiedScope"
        case .diagnostic(let failure): failure.code.rawValue
        }
    }
    public var localizationKey: String {
        switch self {
        case .unavailable: "python.sandbox.unavailable"
        case .invalidScope: "python.sandbox.invalid_scope"
        case .diagnostic(let failure): "python.sandbox.diagnostic." + failure.code.rawValue
        }
    }
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The signed sandbox runner is missing or could not be verified. Nothing was executed. Rebuild or reinstall the complete AgRoom app."
        case .invalidScope:
            "The execution scope could not be verified. Run sandbox_diagnose to identify the failed stage. This error does not establish that the workspace contains private data. Nothing was executed."
        case .diagnostic(let failure):
            Self.description(for: failure)
        }
    }

    private static func description(for failure: ScriptRunnerFailure) -> String {
        let advice: String
        switch failure.code {
        case .scopeConflict: advice = "A write grant overlaps a forbidden space root. Select a narrower write directory."
        case .scopeLimitExceeded: advice = "The scope count or request size exceeds the isolation limit. Reduce explicit input roots."
        case .protocolMismatch: advice = "The app and runner protocol versions differ. Rebuild and reinstall the complete signed app."
        case .runnerLaunchFailed: advice = "The trusted runner could not launch. Check the installed app and system execution permissions."
        case .preparationTimeout: advice = "Trusted scope preparation timed out. Check runner health before retrying."
        case .preparationFailed: advice = "Trusted scope preparation failed without a structured diagnostic. Check the installed runner version."
        case .bookmarkIdentityMismatch: advice = "The authorized file or directory was replaced. Select the original directory again; do not retry unchanged requests."
        case .bookmarkCreationFailed, .bookmarkResolutionFailed, .bookmarkStale, .scopeAccessDenied, .bookmarkPathMismatch:
            advice = "An input or output bookmark could not be authorized at its expected path. Compare minimal and workspace checks with sandbox_diagnose."
        case .identityMismatch: advice = "The runner identity or entitlements do not match the request. Reinstall the complete signed app."
        default: advice = "The runner refused the request at the reported stage. Use sandbox_diagnose; do not infer private data or repeat unchanged commands."
        }
        return "Sandbox error [\(failure.code.rawValue); stage=\(failure.stage.rawValue)"
            + (failure.scopeIndex.map { "; scope_index=\($0)" } ?? "") + "]. " + advice + " Nothing was executed."
    }
}

/// 宿主授权代理。只认当前 App 内、同一开发团队签名的独立沙箱 App。
/// 每次启动新进程，不复用安全作用域；每个空间共用一个离线容器身份。
struct ScriptAppSandbox: Sendable {
    let executable: URL
    let identifier: String

    static func bundled(space: AppSpace) throws -> Self {
        guard let host = Bundle.main.executableURL,
              let team = try signingInfo(at: host)[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw unavailable()
        }
        var parent = host.deletingLastPathComponent()
        while parent.path != "/", parent.pathExtension != "app" { parent.deleteLastPathComponent() }
        guard parent.pathExtension == "app" else { throw unavailable() }
        let name = "AgRoomRunner\(space == .work ? "Work" : "Personal")"
        let bundle = parent.appendingPathComponent("Contents/Helpers/\(name).app")
        let identifier = "com.agroom.runner.\(space.rawValue)"
        return try Self(bundle: bundle, identifier: identifier, team: team)
    }

    /// 内部注入仅用于真实签名产物回归；产品不接受环境变量指定替代执行器。
    init(bundle: URL, identifier: String, team: String) throws {
        guard ["com.agroom.runner.personal", "com.agroom.runner.work"].contains(identifier) else { throw Self.unavailable() }
        guard let metadata = Bundle(url: bundle), metadata.bundleIdentifier == identifier,
              let executable = metadata.executableURL else { throw Self.unavailable() }
        let info = try Self.signingInfo(at: bundle)
        let runtimeKey = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
        let space = identifier.hasSuffix(".personal") ? "personal" : "work"
        let runtimePaths: Set<String> = ["/Documents/AgRoom/python-runtime/", "/Documents/AgRoom/python/\(space)/venv/"]
        guard info[kSecCodeInfoIdentifier as String] as? String == identifier,
              info[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let rights = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              rights["com.apple.security.app-sandbox"] as? Bool == true,
              rights["com.apple.security.inherit"] as? Bool != true,
              rights["com.apple.security.files.user-selected.read-write"] as? Bool == true,
              rights["com.apple.security.network.client"] as? Bool != true,
              Set(rights[runtimeKey] as? [String] ?? []) == runtimePaths,
              rights.keys.allSatisfy({ key in
                  [
                      "com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write",
                      "com.apple.security.get-task-allow",
                      "com.apple.application-identifier", "com.apple.developer.team-identifier", "application-identifier"
                  ].contains(key) || key == runtimeKey
              }) else { throw Self.unavailable() }
        #if !DEBUG
        guard rights["com.apple.security.get-task-allow"] as? Bool != true else { throw Self.unavailable() }
        #endif
        self.executable = executable
        self.identifier = identifier
    }

    func request(plan: ScriptExecutionPlan, label: String, outputLimit: Int,
                 purpose: ScriptRunnerRequest.Purpose = .script) async throws -> ChildProcessRequest {
        guard let sandbox = plan.sandbox, !sandbox.allowsNetwork else { throw Self.unavailable() }
        let started = ProcessInfo.processInfo.systemUptime
        let reads = try Self.readScopes(sandbox: sandbox)
        let denied = sandbox.deniedRoots.map(Self.canonical)
        let writes = sandbox.writeRoots.map(Self.canonical)
        guard writes.allSatisfy({ root in
            !denied.contains { Self.contains($0, root) || Self.contains(root, $0) }
        }) else { throw ScriptIsolationError.diagnostic(ScriptRunnerFailure(.scopeConflict, stage: .writeScopes)) }
        // 普通跨进程书签可能带读写扩展，不能直接交给不可信代码。
        // 可信准备进程先换成自身身份的只读 app-scoped 书签，退出后再启动全新执行进程。
        let prepare = ScriptRunnerRequest(phase: .prepareScopes, helperIdentifier: identifier,
            allowsNetwork: sandbox.allowsNetwork, bookmarks: try Self.bookmarks(reads, stage: .inputScopes),
            executable: "", arguments: [], directory: "/", environment: [:], purpose: purpose)
        // A package replay consumes the shared transfer deadline. Ordinary scripts
        // retain their execution timeout independently of trusted scope preparation.
        let preparationTimeout = purpose == .packageResolution ? min(15, plan.timeout) : 15
        let preparation = await ChildProcessRunner.run(try messageRequest(prepare, timeout: preparationTimeout,
            outputLimit: ScriptRunnerRequest.maximumBytes + 1, label: "script_scope_preparation"))
        if preparation.outcome.isCancelled { throw CancellationError() }
        try Task.checkCancellation()
        if let failure = Self.preparationFailure(preparation) { throw failure }
        guard let bookmarks = try? JSONDecoder().decode([ScriptRunnerBookmark].self, from: Data(preparation.stdout.utf8)),
              bookmarks.map(\.path) == reads.map(\.path) else {
            throw ScriptIsolationError.diagnostic(ScriptRunnerFailure(.invalidResponse, stage: .prepareScopes))
        }
        let message = ScriptRunnerRequest(helperIdentifier: identifier, allowsNetwork: sandbox.allowsNetwork,
            bookmarks: bookmarks, writeBookmarks: try Self.bookmarks(writes, stage: .writeScopes), executable: plan.executable.path,
            arguments: plan.arguments, directory: plan.directory.path, environment: plan.environment,
            standardIO: plan.standardIO, purpose: purpose)
        let remaining = purpose == .packageResolution ? plan.timeout - (ProcessInfo.processInfo.systemUptime - started) : plan.timeout
        guard remaining > 0 else {
            throw ScriptIsolationError.diagnostic(ScriptRunnerFailure(.preparationTimeout, stage: .prepareScopes))
        }
        var request = try messageRequest(message, timeout: remaining, outputLimit: outputLimit, label: label)
        request.resourceBudget = plan.resourceBudget
        return request
    }

    private func messageRequest(_ message: ScriptRunnerRequest, timeout: TimeInterval,
                                outputLimit: Int, label: String) throws -> ChildProcessRequest {
        let data = try JSONEncoder().encode(message)
        guard data.count <= ScriptRunnerRequest.maximumBytes,
              message.bookmarks.count + message.writeBookmarks.count <= 256 else {
            throw ScriptIsolationError.diagnostic(ScriptRunnerFailure(.scopeLimitExceeded, stage: .request))
        }
        return ChildProcessRequest(executable: executable, arguments: [], workingDirectory: URL(fileURLWithPath: "/"),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"], standardInputData: data,
            timeout: timeout, outputLimit: outputLimit, label: label)
    }

    private static func bookmarks(_ roots: [URL], stage: ScriptRunnerFailure.Stage) throws -> [ScriptRunnerBookmark] {
        try roots.enumerated().map { index, url in
            do {
                guard let identity = ScriptRunnerFileIdentity.capture(url) else { throw ScriptIsolationError.invalidScope }
                let data = try url.bookmarkData(options: [])
                guard ScriptRunnerFileIdentity.capture(url) == identity else { throw ScriptIsolationError.invalidScope }
                return ScriptRunnerBookmark(data: data, path: url.path, identity: identity)
            }
            catch { throw ScriptIsolationError.diagnostic(ScriptRunnerFailure(.bookmarkCreationFailed, stage: stage, scopeIndex: index)) }
        }
    }

    /// 只解析可信 prepareScopes 进程的 stderr，不把用户程序的输出当作可信诊断。
    static func preparationFailure(_ result: ChildProcessResult) -> ScriptIsolationError? {
        guard !result.succeeded else { return nil }
        let fallback: ScriptRunnerFailure.Code
        switch result.outcome {
        case .launchFailed: fallback = .runnerLaunchFailed
        case .timedOut: fallback = .preparationTimeout
        default:
            if result.stderr.utf8.count <= 4096,
               let failure = try? JSONDecoder().decode(ScriptRunnerFailure.self, from: Data(result.stderr.utf8)), failure.isValid {
                return .diagnostic(failure)
            }
            fallback = .preparationFailed
        }
        return .diagnostic(ScriptRunnerFailure(fallback, stage: .prepareScopes))
    }

    /// App Sandbox 没有动态减去子路径的接口。与禁止目录相交时只授权其安全子项，绝不授权父目录。
    static func readScopes(sandbox: ScriptSandbox) throws -> [URL] {
        let denied = sandbox.deniedRoots.map(canonical)
        var paths = Set<String>()
        var result: [URL] = []
        func collect(_ root: URL) throws {
            guard FileManager.default.fileExists(atPath: root.path),
                  !denied.contains(where: { contains($0, root) }) else { return }
            if denied.contains(where: { contains(root, $0) }) {
                let children: [URL]
                do { children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) }
                catch { throw ScriptIsolationError.diagnostic(ScriptRunnerFailure(.scopeAccessDenied, stage: .inputScopes)) }
                for child in children {
                    // 不跟随输入目录内的链接，避免被授权根中夹入另一个空间的别名。
                    guard try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                    try collect(canonical(child))
                }
            } else if paths.insert(root.path).inserted {
                guard result.count < 240 else { throw ScriptIsolationError.diagnostic(ScriptRunnerFailure(.scopeLimitExceeded, stage: .inputScopes)) }
                guard root.path != "/" else { throw ScriptIsolationError.diagnostic(ScriptRunnerFailure(.scopeConflict, stage: .inputScopes)) }
                result.append(root)
            }
        }
        for root in sandbox.readRoots { try collect(canonical(root)) }
        return result
    }

    private static func contains(_ root: URL, _ child: URL) -> Bool {
        root.path == child.path || child.path.hasPrefix(root.path + "/")
    }

    private static func canonical(_ url: URL) -> URL {
        var root = url.standardizedFileURL.resolvingSymlinksInPath()
        var suffix: [String] = []
        while true {
            if let path = realpath(root.path, nil) {
                defer { free(path) }
                return suffix.reversed().reduce(URL(fileURLWithPath: String(cString: path))) { $0.appendingPathComponent($1) }
            }
            if root.path == "/" { return url.standardizedFileURL }
            suffix.append(root.lastPathComponent)
            root.deleteLastPathComponent()
        }
    }

    private static func signingInfo(at url: URL) throws -> [String: Any] {
        var code: SecStaticCode?
        var info: CFDictionary?
        // 限制 Apple 签发的同团队代码；仅比较自报 bundle ID 或 ad-hoc team 字段不构成信任。
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let result = info as? [String: Any] else { throw unavailable() }
        return result
    }

    private static func unavailable() -> ScriptIsolationError { .unavailable }
}
