import CryptoKit
import Darwin
import Foundation
import AgRoomScriptIPC

/// 只读文件身份。失败关闭；不把读取失败的文件当成空摘要。
enum ScriptFileIdentity {
    static func read(_ url: URL, root: URL? = nil, limit: Int = 128 * 1024 * 1024) throws -> Data {
        try readStamped(url, root: root, limit: limit).data
    }

    static func readStamped(_ url: URL, root: URL?, limit: Int = 128 * 1024 * 1024) throws
        -> (data: Data, stamp: ArtifactFileStamp) {
        var parentDescriptors: [Int32] = []
        defer { for descriptor in parentDescriptors.reversed() { close(descriptor) } }
        let descriptor: Int32
        if let root {
            guard url.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let components = String(url.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
            guard components.allSatisfy({ $0 != "." && $0 != ".." }), let leaf = components.last else {
                throw CocoaError(.fileReadNoPermission)
            }
            var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw CocoaError(.fileReadNoPermission) }
            parentDescriptors.append(parent)
            for component in components.dropLast() {
                parent = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else { throw CocoaError(.fileReadNoPermission) }
                parentDescriptors.append(parent)
            }
            descriptor = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        } else {
            descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw CocoaError(.fileReadTooLarge) }
        var contents = Data()
        while let data = try handle.read(upToCount: min(64 * 1024, limit + 1 - contents.count)), !data.isEmpty {
            contents.append(data)
            guard contents.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        }
        var after = stat()
        let stamp = ArtifactFileStamp(info)
        guard fstat(descriptor, &after) == 0, ArtifactFileStamp(after) == stamp, contents.count == info.st_size else {
            throw TaskArtifactError.changedFile
        }
        return (contents, stamp)
    }
    static func digest(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 128 * 1024 * 1024 else { return nil }
        var hash = SHA256()
        do {
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }
}

/// 技能按目录结构冻结为本次运行的副本；只把 scratch 中的常规文件发布回技能库。
struct ScriptBundleSnapshot {
    struct Entry: Sendable { let path: String; let data: Data; let stamp: ArtifactFileStamp }
    let entries: [Entry]
    let digest: String

    init(root: URL, outputs: Bool = false) throws {
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        // 使用天然相对路径，避免 /var 与 /private/var 别名导致绝对路径截取错误。
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        var entries: [Entry] = []
        var total = 0
        for relative in paths {
            let url = root.appendingPathComponent(relative)
            let first = relative.split(separator: "/").first.map(String.init) ?? ""
            if !outputs && ["scratch", "versions", "__pycache__"].contains(first) {
                continue
            }
            if relative == SkillValidationService.validationFileName || relative.hasSuffix(".pyc") { continue }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else {
                throw LLMError.configurationError(reason: "Skill execution refused a symbolic link in its package: \(relative)")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true,
                  FileAreaService.isInside(url, root: root), entries.count < 4096 else {
                throw CocoaError(.fileReadUnknown)
            }
            let (data, stamp) = try ScriptFileIdentity.readStamped(url, root: root)
            total += data.count
            guard total <= 256 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            entries.append(Entry(path: relative, data: data, stamp: stamp))
        }
        self.entries = entries.sorted { $0.path < $1.path }
        // 内容可包含任意分隔符；用有结构的清单绑定文件边界，不能直接拼接原始内容。
        struct Fingerprint: Encodable {
            let path: String
            let size: Int
            let sha256: String
        }
        let manifest = self.entries.map {
            Fingerprint(path: $0.path, size: $0.data.count,
                sha256: SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined())
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var identity = Data("agroom.bundle.v2\n".utf8)
        identity.append(try encoder.encode(manifest))
        digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    func write(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in entries { try SecureFileWriter.write(entry.data, to: root.appendingPathComponent(entry.path), root: root) }
    }
}

/// 执行端只消费固定的启动数据，不重新解释模型的 Shell 文本。
struct ScriptExecutionPlan: Sendable {
    let executable: URL
    let arguments: [String]
    let directory: URL
    let environment: [String: String]
    let timeout: TimeInterval
    let sandbox: ScriptSandbox?
    var standardIO: ScriptRunnerStandardIO? = nil
    var resourceBudget: ChildProcessBudget? = nil

    func request(label: String, outputLimit: Int, mergeStandardError: Bool = false) throws -> ChildProcessRequest {
        guard standardIO == nil else { throw ScriptIsolationError.unavailable }
        var executable = executable
        var arguments = arguments
        if let sandbox {
            guard FileManager.default.isExecutableFile(atPath: ScriptSandbox.launcher.path) else {
                throw LLMError.configurationError(reason: "Process isolation is unavailable. Nothing was executed; unrestricted fallback is disabled.")
            }
            arguments = ["-p", try sandbox.profile(), executable.path] + arguments
            executable = ScriptSandbox.launcher
        }
        var request = ChildProcessRequest(
            executable: executable, arguments: arguments, workingDirectory: directory,
            environment: environment, timeout: timeout, outputLimit: outputLimit,
            mergeStandardError: mergeStandardError, label: label
        )
        request.resourceBudget = resourceBudget
        return request
    }
}

/// macOS Seatbelt 兼容后端。后端失败一律停止，绝不重试为无围栏进程。
/// SBPL 是兼容层，不作为稳定平台 API；策略与调用方不依赖该后端的语法。
struct ScriptSandbox: Sendable {
    static let launcher = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    let readRoots: [URL]
    let writeRoots: [URL]
    let deniedRoots: [URL]
    var allowsNetwork = false

    func profile() throws -> String {
        func filter(_ url: URL) throws -> String {
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
            let path: String
            if let resolved = realpath(normalized, nil) {
                path = String(cString: resolved)
                free(resolved)
            } else { path = normalized }
            guard path != "/", !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
                throw LLMError.configurationError(reason: "An execution scope could not be verified. Nothing was executed.")
            }
            return "(subpath \"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\")"
        }
        // 元数据读取允许解释器检查父路径；正文读取与写入仍仅在显式根内。
        // 默认不允许 fork/posix_spawn，避免子进程脱离本次运行的取消与超时生命周期。
        var rules = ["(version 1)", "(deny default)", "(allow process-exec)", "(allow process-info*)", "(allow sysctl-read)",
                     "(allow file-read-metadata)", "(allow file-read-data (literal \"/\"))",
                     "(allow file-read* (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \"/dev/random\"))",
                     "(allow file-write* (literal \"/dev/null\"))"]
        for root in readRoots { rules.append("(allow file-read* \(try filter(root)))") }
        for root in writeRoots { rules.append("(allow file-read* file-write* \(try filter(root)))") }
        if allowsNetwork {
            rules += ["(allow network-outbound)",
                      "(allow file-read* (literal \"/private/etc/resolv.conf\") (literal \"/private/etc/hosts\") (subpath \"/private/etc/ssl\"))",
                      "(allow mach-lookup (global-name \"com.apple.mDNSResponder\") (global-name \"com.apple.SystemConfiguration.configd\"))"]
        }
        // 显式拒绝优先于允许：误配更宽工作区也不得读写另一空间和宿主私有状态。
        for root in deniedRoots { rules.append("(deny file-read* file-write* \(try filter(root)))") }
        return rules.joined(separator: "\n")
    }

    /// Older workspaces used one shared run directory without trustworthy ownership metadata.
    static func legacyRunRoots(in workspaces: [URL]) -> [URL] {
        workspaces.map { $0.appendingPathComponent(".agroom-runs", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Managed interpreters, wheels, leases and per-space runs must stay outside project grants.
    static func permitsProjectRoot(_ url: URL) -> Bool {
        guard !url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.contains(".agroom-runs") else { return false }
        let manager = PythonRuntimeManager.shared
        let reserved = [manager.managedRuntimeDir, manager.sandboxRoot,
                        manager.environmentRoot.appendingPathComponent("python", isDirectory: true)]
        return !reserved.contains { FileAreaService.isInside(url, root: $0) || FileAreaService.isInside($0, root: url) }
    }

    static func privateRoots(space: AppSpace) -> [URL] {
        let other: AppSpace = space == .work ? .personal : .work
        let files = FileAreaService.standard
        let support = PythonRuntimeManager.shared.supportRoot
        // 空间数据库位于支持根目录，而不在 <space>/ 内；WAL/SHM 也属于该空间。
        let databases = ["", "-wal", "-shm", "-journal"].map {
            support.appendingPathComponent(other.databaseFileName + $0)
        }
        return [support.appendingPathComponent(other.rawValue), PythonSpacePaths.root(space: other),
                files.defaultChatRoot(for: other)] + files.defaultWriteRoots(for: other) + databases
    }
}

/// 独立锁文件协调 App/Daemon 的运行与安装。等待不占 actor 或线程，取消可立即退出。
final class PythonEnvironmentLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }

    static func acquire(root: URL, mutation: Bool) async throws -> PythonEnvironmentLease {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent(".execution.lock").path,
                              O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LLMError.configurationError(reason: "The Python environment lock is unavailable. Nothing was executed.")
        }
        do {
            while flock(descriptor, (mutation ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                    throw LLMError.configurationError(reason: "The Python environment could not be locked. Nothing was executed.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            return PythonEnvironmentLease(descriptor: descriptor)
        } catch { close(descriptor); throw error }
    }
}
