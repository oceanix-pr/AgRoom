import CryptoKit
import Foundation

// MARK: - Python Runtime Status

public enum PythonRuntimeStatus: Sendable, Equatable {
    /// 托管运行时（应用自行安装，不依赖系统 Python）
    case managed(path: String)
    case notInstalled

    public var pythonPath: String? {
        switch self {
        case .managed(let path): return path
        case .notInstalled: return nil
        }
    }
}

// MARK: - Python Runtime Manager

/// 只使用 Documents/AgRoom 内的独立 Python，不读取旧自定义路径或系统回退设置。
public final class PythonRuntimeManager: @unchecked Sendable {

    /// 安装器超时：正常安装分钟级（解压数百 MB），卡死时靠它熔断
    static let installTimeout: TimeInterval = 1800

    /// 固定的发行版标签：不使用 `releases/latest`——「latest」意味着今天装的和上次装的
    /// 未必是同一份，也无法为一份会变的产物维护校验值。升级需显式改这一处。
    static let miniforgeVersion = "24.11.3-0"

    /// 该架构对应的发布附件名（带版本号，指向不可变的发布产物）
    static func miniforgeAssetName(architecture: String) -> String {
        architecture == "arm64"
            ? "Miniforge3-\(miniforgeVersion)-MacOSX-arm64.sh"
            : "Miniforge3-\(miniforgeVersion)-MacOSX-x86_64.sh"
    }

    /// 线程安全的输出累积器（readabilityHandler 在独立队列回调）
    private final class ProcessOutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ data: Data) { lock.withLock { buffer.append(data) } }
        var data: Data { lock.withLock { buffer } }
    }

    public enum RuntimeError: LocalizedError {
        case downloadFailed(String)
        case installFailed(String)
        case alreadyInstalling

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let reason):
                return "Failed to download Python runtime: \(reason)"
            case .installFailed(let reason):
                return "Failed to install Python runtime: \(reason)"
            case .alreadyInstalling:
                return "Installation already in progress."
            }
        }
    }

    public static let shared = PythonRuntimeManager()

    private let installLock = NSLock()
    private var _installing = false
    private let environmentRootOverride: URL?

    /// 内部根目录注入仅供临时目录回归；产品入口始终使用 Documents/AgRoom。
    init(environmentRoot: URL? = nil) {
        self.environmentRootOverride = environmentRoot
    }

    // MARK: - Paths

    /// 应用支持根目录（数据库等私有状态，Python 环境不在此处）
    public var supportRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AgRoom")
    }

    /// Python 运行时与两个空间环境的唯一受管根目录。
    public var environmentRoot: URL {
        environmentRootOverride ?? FileAreaService.documentsDirectory
            .appendingPathComponent("AgRoom", isDirectory: true)
    }

    /// 托管运行时安装目录
    public var managedRuntimeDir: URL {
        environmentRoot.appendingPathComponent("python-runtime", isDirectory: true)
    }

    /// 托管运行时 python 可执行文件
    public var managedPythonPath: String {
        managedRuntimeDir.appendingPathComponent("bin/python3").path
    }

    /// 沙箱工作目录（按用途隔离的执行目录由调用方追加子目录）
    public var sandboxRoot: URL {
        environmentRoot.appendingPathComponent("python-workspace", isDirectory: true)
    }

    public var isInstalling: Bool {
        installLock.withLock { _installing }
    }

    // MARK: - Status

    /// 只探测固定托管路径；缺失时由用户主动下载安装，不扫描或回退本机 Python。
    public func status() -> PythonRuntimeStatus {
        if isManagedInterpreter(managedPythonPath) {
            return .managed(path: managedPythonPath)
        }
        return .notInstalled
    }

    /// 同时检查原路径和真实路径，拒绝指向受管根之外的解释器或目录链接。
    static func contains(_ url: URL, in root: URL) -> Bool {
        func inside(_ path: String, _ rootPath: String) -> Bool {
            path == rootPath || path.hasPrefix(rootPath + "/")
        }
        return inside(url.standardizedFileURL.path, root.standardizedFileURL.path)
            && inside(url.standardizedFileURL.resolvingSymlinksInPath().path,
                      root.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    /// 环境目录不能重定向到另一个空间；解释器文件仍可在本运行时内链接版本化文件。
    static func isUnredirectedDirectory(_ url: URL, in root: URL) -> Bool {
        guard contains(url, in: root) else { return false }
        // 末级目录尚未创建时，resolvingSymlinksInPath 不保证展开已有父级链接。
        // 逐级读取链接本身，环境创建前也不能经父目录跳到另一空间。
        var current = root.standardizedFileURL
        for component in url.standardizedFileURL.pathComponents.dropFirst(current.pathComponents.count) {
            current.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil { return false }
        }
        return true
    }

    func isManagedInterpreter(_ path: String, requireExecutable: Bool = true) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.standardizedFileURL.path == managedPythonPath
            && Self.isUnredirectedDirectory(managedRuntimeDir, in: environmentRoot)
            && Self.contains(url, in: environmentRoot)
            && Self.contains(url, in: managedRuntimeDir)
            && (!requireExecutable || FileManager.default.isExecutableFile(atPath: path))
    }

    // MARK: - Managed Runtime Installation

    /// 安装托管运行时：下载 Miniforge 安装脚本并以静默模式安装到托管目录。
    /// 进度通过回调上报（0~1 下载，安装阶段为 -1 表示不确定进度）。
    public func installManagedRuntime(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        try installLock.withLock {
            if _installing { throw RuntimeError.alreadyInstalling }
            _installing = true
        }
        defer { installLock.withLock { _installing = false } }

        let arch = ProcessInfo.processInfo.machineArchitecture
        let assetName = Self.miniforgeAssetName(architecture: arch)
        let base = "https://github.com/conda-forge/miniforge/releases/download/\(Self.miniforgeVersion)"
        guard let scriptURL = URL(string: "\(base)/\(assetName)"),
              let checksumURL = URL(string: "\(base)/\(assetName).sha256") else {
            throw RuntimeError.downloadFailed("Invalid download URL")
        }

        // 1. 下载安装脚本与官方校验值：脚本先落盘（不整包读入内存），校验通过才允许执行
        progress(0, "Downloading \(assetName)...")
        let downloadDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-python-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: downloadDir) }

        let downloadPath = downloadDir.appendingPathComponent(assetName)
        do {
            try await Self.downloadToFile(scriptURL, to: downloadPath)
            let checksumText = try await Self.fetchText(checksumURL)
            guard let expected = Self.parseExpectedSHA256(checksumText) else {
                throw RuntimeError.downloadFailed("Checksum file \(assetName).sha256 has no SHA-256 value")
            }
            // 诚实说明：校验值来自同一发布目录，能发现传输损坏与被动替换，
            // 但不等同于独立的来源认证（能改写发布产物的人也能改写校验值文件）
            guard try Self.sha256Hex(ofFileAt: downloadPath).caseInsensitiveCompare(expected) == .orderedSame else {
                throw RuntimeError.downloadFailed("Checksum mismatch for \(assetName)")
            }
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.downloadFailed(error.localizedDescription)
        }

        // 2. 静默安装到**新目录**：装好并验证可用后才替换现有运行时，
        //    中途失败（含取消）不会毁掉当前可用的运行时
        progress(-1, "Installing runtime...")
        let targetDir = managedRuntimeDir
        guard Self.isUnredirectedDirectory(targetDir, in: environmentRoot) else {
            throw RuntimeError.installFailed("The runtime directory points outside Documents/AgRoom.")
        }
        let parentDir = targetDir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let stagingDir = parentDir
            .appendingPathComponent("python-runtime-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [downloadPath.path, "-b", "-p", stagingDir.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                               "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "TMPDIR": downloadDir.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        // 执行期间持续抽取 stderr：管道缓冲（64KB）写满会卡死安装器，
        // 安装器异常时的输出量不可预知，不能等退出后再读
        let stderrCollector = ProcessOutputCollector()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrCollector.append(data)
            }
        }

        // 取消传播：用户中止安装时主动终止安装器进程树
        let gate = CancellationGate()
        do {
            // 续体桥接退出 + 超时熔断：安装器正常分钟级，卡死则 SIGTERM→SIGKILL 兜底，
            // 避免 async 任务永久挂起（与 shell_run/python_execute 同一熔断语义）
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    do {
                        try process.run()
                        // 取消可能先于 run 抵达（此时 terminate 无进程可杀），启动后补判断
                        if gate.isCancelled {
                            ProcessTerminator.terminate(process: process, label: "python-runtime-install")
                        }
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    ProcessTerminator.scheduleTimeout(
                        process: process,
                        timeout: Self.installTimeout,
                        label: "python-runtime-install"
                    ) {}
                }
            } onCancel: {
                gate.markCancelled()
                ProcessTerminator.terminate(process: process, label: "python-runtime-install")
            }
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw RuntimeError.installFailed(error.localizedDescription)
        }

        // 收尾：清空处理器并读取残余数据
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        // 取消导致的非零退出不应报成安装失败：先判取消，让上层按中止处理
        if gate.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrCollector.data, encoding: .utf8)?.suffix(300) ?? ""
            throw RuntimeError.installFailed("exit \(process.terminationStatus): \(message)")
        }

        // 3. 先验证新目录确实可用，再切换；切换失败自动退回原运行时
        guard Self.probeRuntime(in: stagingDir) else {
            throw RuntimeError.installFailed("freshly installed python3 failed to run")
        }
        try Self.activate(staging: stagingDir, target: targetDir)
        guard isManagedInterpreter(managedPythonPath) else {
            throw RuntimeError.installFailed("python3 not found after install")
        }
        progress(1, "Done")
        HubLogger.shared.info("Managed Python runtime installed")
    }

    // MARK: - Download / Verify / Activate

    /// 流式落盘下载：不把安装脚本整包读入内存
    static func downloadToFile(_ url: URL, to destination: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RuntimeError.downloadFailed("HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    /// 抓取小体积文本（校验值文件）
    static func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RuntimeError.downloadFailed("HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeError.downloadFailed("\(url.lastPathComponent) is not UTF-8 text")
        }
        return text
    }

    /// 取文件里第一个 64 位十六进制串作为期望摘要：
    /// 官方校验值文件为 `<hex>  <文件名>` 形态，容忍行尾/文件名差异
    static func parseExpectedSHA256(_ text: String) -> String? {
        for token in text.split(whereSeparator: { !$0.isHexDigit }) where token.count == 64 {
            return String(token)
        }
        return nil
    }

    /// 分块计算文件 SHA-256（不整包读入内存）
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 验证新目录里的 python3 能启动并报版本（短命进程，毫秒级）
    static func probeRuntime(in directory: URL) -> Bool {
        let python = directory.appendingPathComponent("bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-S", "--version"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 切换运行时：旧目录先改名为备份、新目录就位；就位失败则把备份改回来。
    /// 同一父目录内的改名是原子的，不会出现「一半新一半旧」的中间态
    static func activate(staging: URL, target: URL) throws {
        let fileManager = FileManager.default
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent("python-runtime-previous-\(UUID().uuidString)", isDirectory: true)
        var movedExisting = false
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.moveItem(at: target, to: backup)
            movedExisting = true
        }
        do {
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            if movedExisting {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw RuntimeError.installFailed("failed to activate runtime: \(error.localizedDescription)")
        }
        if movedExisting {
            try? fileManager.removeItem(at: backup)
        }
    }
}

// MARK: - ProcessInfo Architecture Helper

extension ProcessInfo {
    /// 机器架构（arm64 / x86_64）
    var machineArchitecture: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { buffer in
            let data = Data(bytes: buffer.baseAddress!, count: buffer.count)
            guard let index = data.firstIndex(of: 0) else { return "arm64" }
            return String(data: data.prefix(upTo: index), encoding: .ascii) ?? "arm64"
        }
    }
}
