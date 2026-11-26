import Foundation
import Darwin

// MARK: - Child Process Runner

/// 子进程的统一执行结果。取消、超时、启动失败与“结果不确定”必须分开，
/// 调用方不能把其中任何一种当成正常退出，也不能在取消后自动重试有副作用的命令。
public enum ChildProcessOutcome: Sendable, Equatable {
    case exited(Int32)
    case cancelled
    case timedOut
    case launchFailed(String)
    case resourceLimited(String)
    /// 进程已启动但无法可靠判定是否已完整结束（例如终止后仍拿不到状态）。
    case indeterminate(String)

    public var exitCode: Int32? {
        if case .exited(let code) = self { return code }
        return nil
    }

    public var isSuccess: Bool {
        if case .exited(0) = self { return true }
        return false
    }

    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    public var isTimedOut: Bool {
        if case .timedOut = self { return true }
        return false
    }
}

public struct ChildProcessResult: Sendable {
    public let outcome: ChildProcessOutcome
    public let stdout: String
    public let stderr: String
    public let duration: TimeInterval

    public init(
        outcome: ChildProcessOutcome,
        stdout: String,
        stderr: String,
        duration: TimeInterval
    ) {
        self.outcome = outcome
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
    }

    public var exitCode: Int32 { outcome.exitCode ?? -1 }
    public var succeeded: Bool { outcome.isSuccess }
    public var timedOut: Bool { outcome.isTimedOut }
}

public struct ChildProcessBudget: Sendable {
    public var maximumResidentBytes: UInt64
    public var maximumOutputBytes: UInt64
    public var maximumOutputFiles: Int
    /// 只监控明确的本次输出目录，不扫描输入工作区，不跟随符号链接。
    public var outputRoots: [URL]

    public init(maximumResidentBytes: UInt64, maximumOutputBytes: UInt64,
                maximumOutputFiles: Int, outputRoots: [URL]) {
        self.maximumResidentBytes = maximumResidentBytes
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumOutputFiles = maximumOutputFiles
        self.outputRoots = outputRoots
    }

    func outputViolation() -> String? {
        var bytes: UInt64 = 0
        var count = 0
        for root in outputRoots where FileManager.default.fileExists(atPath: root.path) {
            guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
                return "output_monitor_unavailable"
            }
            var failed = false
            guard let paths = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                errorHandler: { _, _ in failed = true; return false }) else { return "output_monitor_unavailable" }
            for case let url as URL in paths {
                count += 1
                if count > maximumOutputFiles { return "output_file_count" }
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
                    return "output_monitor_unavailable"
                }
                if values.isSymbolicLink != true, values.isRegularFile == true {
                    let size = UInt64(max(0, values.fileSize ?? 0))
                    if size > maximumOutputBytes - min(bytes, maximumOutputBytes) { return "output_bytes" }
                    bytes += size
                }
            }
            if failed { return "output_monitor_unavailable" }
        }
        return nil
    }
}

public struct ChildProcessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]?
    /// 通过启动前即 unlink 的临时文件描述符传递，避免管道写入阻塞及磁盘控制文件残留。
    public var standardInputData: Data?
    public var timeout: TimeInterval
    public var outputLimit: Int
    /// true = stdout/stderr 合流到同一管道（Shell 的既有语义）
    public var mergeStandardError: Bool
    public var label: String
    public var resourceBudget: ChildProcessBudget? = nil

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        standardInputData: Data? = nil,
        timeout: TimeInterval,
        outputLimit: Int,
        mergeStandardError: Bool = false,
        label: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInputData = standardInputData
        self.timeout = max(0.1, timeout)
        self.outputLimit = max(256, outputLimit)
        self.mergeStandardError = mergeStandardError
        self.label = label
    }
}

/// 启动、环境、输出、超时和取消的唯一实现。Shell 与 Python 共用。
///
/// 关键约束：
/// - 取消处理器与启动之间用同一把锁判定，覆盖“启动前取消”和“启动中取消”；
/// - 结束回调只允许完成一次；
/// - 收尾不等待管道 EOF（后台后代可能一直持有写端），只读取当前可用数据后关闭；
/// - 超时/取消都终止整棵进程树，而不是只杀直接子进程。
public enum ChildProcessRunner {

    public static func run(_ request: ChildProcessRequest) async -> ChildProcessResult {
        let state = RunState(request: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)
                if Task.isCancelled {
                    state.requestCancellation()
                } else {
                    state.start()
                }
            }
        } onCancel: {
            state.requestCancellation()
        }
    }

    // MARK: Run State

    private final class RunState: @unchecked Sendable {
        private let request: ChildProcessRequest
        private let lock = NSLock()
        /// 读取与最终收集由同一串行队列拥有；不在状态锁内做 I/O。
        private let outputQueue = DispatchQueue(label: "agroom.childProcess.output")
        private var outputClosed = false
        private let startTime = Date()

        private var continuation: CheckedContinuation<ChildProcessResult, Never>?
        private var process: Process?
        private var stdoutPipe: Pipe?
        private var stderrPipe: Pipe?
        private var stdoutCollector: BoundedOutputCollector?
        private var stderrCollector: BoundedOutputCollector?
        private var timeoutTask: Task<Void, Never>?
        private var fallbackTask: Task<Void, Never>?
        private var resourceTask: Task<Void, Never>?
        private var resourceViolation: String?

        private var finished = false
        private var installed = false
        private var launched = false
        private var cancellationRequested = false
        private var timeoutRequested = false
        private var terminationStatus: Int32?

        init(request: ChildProcessRequest) {
            self.request = request
        }

        func install(_ continuation: CheckedContinuation<ChildProcessResult, Never>) {
            let cancelImmediately = lock.withLock { () -> Bool in
                self.continuation = continuation
                installed = true
                return cancellationRequested
            }
            // 取消可能早于 continuation 安装完成；此时不能在 requestCancellation 里
            // 提前 finish（没有 continuation 可恢复），必须在安装后补一次。
            if cancelImmediately {
                finish(.cancelled)
            }
        }

        func start() {
            let process = Process()
            process.executableURL = request.executable
            process.arguments = request.arguments
            process.currentDirectoryURL = request.workingDirectory
            if let environment = request.environment {
                process.environment = environment
            }
            let input: FileHandle?
            do {
                input = try request.standardInputData.map(Self.inputHandle)
                if let input { process.standardInput = input }
            } catch {
                finish(.launchFailed("Could not prepare process input."))
                return
            }
            defer { try? input?.close() }

            let stdoutPipe = Pipe()
            let stdoutCollector = BoundedOutputCollector(limit: request.outputLimit)
            guard configureOutput(stdoutPipe, collector: stdoutCollector) else {
                finish(.launchFailed("Could not prepare nonblocking process output.")); return
            }
            process.standardOutput = stdoutPipe

            let stderrPipe: Pipe?
            let stderrCollector: BoundedOutputCollector?
            if request.mergeStandardError {
                process.standardError = stdoutPipe
                stderrPipe = nil
                stderrCollector = nil
            } else {
                let pipe = Pipe()
                let collector = BoundedOutputCollector(limit: request.outputLimit)
                guard configureOutput(pipe, collector: collector) else {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    finish(.launchFailed("Could not prepare nonblocking process output.")); return
                }
                process.standardError = pipe
                stderrPipe = pipe
                stderrCollector = collector
            }

            // 取消可能正好发生在准备阶段：必须在 run() 之前再判定一次。
            let shouldCancel = lock.withLock { () -> Bool in
                if cancellationRequested || finished { return true }
                launched = true
                self.process = process
                self.stdoutPipe = stdoutPipe
                self.stderrPipe = stderrPipe
                self.stdoutCollector = stdoutCollector
                self.stderrCollector = stderrCollector
                return false
            }
            guard !shouldCancel else {
                finish(.cancelled)
                return
            }

            process.terminationHandler = { [weak self] terminated in
                guard let self else { return }
                let outcome = self.lock.withLock { () -> ChildProcessOutcome in
                    self.terminationStatus = terminated.terminationStatus
                    if self.timeoutRequested { return .timedOut }
                    if self.cancellationRequested { return .cancelled }
                    if let violation = self.resourceViolation { return .resourceLimited(violation) }
                    return .exited(terminated.terminationStatus)
                }
                self.finish(outcome)
            }

            do {
                try process.run()
            } catch {
                finish(.launchFailed(error.localizedDescription))
                return
            }

            // 进程可能在 run() 返回前就结束；terminationHandler 会先完成，这里不能再启动定时器。
            let isFinished = lock.withLock { finished }
            guard !isFinished else { return }

            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                let nanoseconds = UInt64(max(0.1, self.request.timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self.timeoutFired()
            }
            let cancelAfterLaunch = lock.withLock { () -> Bool in
                if finished {
                    timeoutTask.cancel()
                    return true
                }
                self.timeoutTask = timeoutTask
                return cancellationRequested
            }
            if cancelAfterLaunch {
                timeoutTask.cancel()
                terminate(kind: .cancelled)
            }
            if request.resourceBudget != nil {
                let task = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, let self else { return }
                        if self.checkResources() { return }
                    }
                }
                let discard = lock.withLock { () -> Bool in
                    if finished { return true }
                    resourceTask = task
                    return false
                }
                if discard { task.cancel() }
            }
        }

        private func checkResources() -> Bool {
            guard let budget = request.resourceBudget,
                  let process = lock.withLock({ finished ? nil : self.process }) else { return true }
            var violation = budget.outputViolation()
            if violation == nil {
                var info = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                let read = proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &info, size)
                if read == size {
                    if info.pti_resident_size > budget.maximumResidentBytes { violation = "resident_memory" }
                } else if process.isRunning { violation = "memory_monitor_unavailable" }
            }
            guard let violation else { return false }
            let stop = lock.withLock { () -> Bool in
                guard !finished, resourceViolation == nil else { return false }
                resourceViolation = violation
                return true
            }
            if stop { terminate(kind: .resourceLimit) }
            return true
        }

        func requestCancellation() {
            let action = lock.withLock { () -> Action in
                if finished { return .none }
                cancellationRequested = true
                guard installed else { return .deferred }
                return launched ? .terminate : .finishCancelled
            }
            switch action {
            case .none, .deferred:
                break
            case .finishCancelled:
                finish(.cancelled)
            case .terminate:
                terminate(kind: .cancelled)
            }
        }

        private static func inputHandle(_ data: Data) throws -> FileHandle {
            var template = Array((NSTemporaryDirectory() + "/agroom-stdin-XXXXXX").utf8CString)
            let descriptor = mkstemp(&template)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            // unlink 在写数据之前完成；脚本无法从文件系统中重新打开授权请求。
            let removed = template.withUnsafeBufferPointer { unlink($0.baseAddress!) }
            guard removed == 0, fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                close(descriptor)
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.seek(toOffset: 0)
                return handle
            } catch {
                try? handle.close()
                throw error
            }
        }

        private func timeoutFired() {
            let shouldTerminate = lock.withLock { () -> Bool in
                guard !finished else { return false }
                timeoutRequested = true
                return true
            }
            guard shouldTerminate else { return }
            terminate(kind: .timedOut)
        }

        private enum Action { case none, deferred, finishCancelled, terminate }

        private enum TerminationKind { case cancelled, timedOut, resourceLimit }

        private func terminate(kind: TerminationKind) {
            let process = lock.withLock { self.process }
            guard let process else {
                finish(kind == .cancelled ? .cancelled : .timedOut)
                return
            }
            ProcessTerminator.terminate(process: process, label: request.label)
            // terminationHandler 正常情况下会先完成；若进程树忽略信号，兜底一次结果，
            // 避免调用方永久挂起。此时进程可能尚未被 SIGKILL，明确标为不确定。
            let fallback = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ProcessTerminator.killGracePeriod + 1))
                guard !Task.isCancelled, let self else { return }
                let stillRunning = self.lock.withLock { !self.finished }
                guard stillRunning else { return }
                let reason = switch kind {
                    case .cancelled: "cancellation timed out while stopping the process tree"
                    case .timedOut: "timeout escalation did not confirm process termination"
                    case .resourceLimit: "resource-limit escalation did not confirm process termination"
                }
                self.finish(.indeterminate(reason))
            }
            lock.withLock { fallbackTask = fallback }
        }

        private func finish(_ outcome: ChildProcessOutcome) {
            let outcome: ChildProcessOutcome = if outcome.isSuccess,
                let violation = request.resourceBudget?.outputViolation() {
                .resourceLimited(violation)
            } else { outcome }
            let (continuation, timeoutTask, fallbackTask): (
                CheckedContinuation<ChildProcessResult, Never>?,
                Task<Void, Never>?,
                Task<Void, Never>?
            ) = lock.withLock {
                guard !finished else { return (nil, nil, nil) }
                finished = true
                let cont = self.continuation
                self.continuation = nil
                return (cont, self.timeoutTask, self.fallbackTask)
            }
            guard let continuation else { return }
            timeoutTask?.cancel()
            fallbackTask?.cancel()
            let resourceTask = lock.withLock { self.resourceTask }
            resourceTask?.cancel()

            // 先停止新事件，再排在所有在途读取之后收尾，不能抢在 append 之前快照。
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            let (stdout, stderr) = outputQueue.sync {
                if let pipe = stdoutPipe, let collector = stdoutCollector {
                    _ = drain(pipe.fileHandleForReading.fileDescriptor, collector: collector)
                }
                if let pipe = stderrPipe, let collector = stderrCollector {
                    _ = drain(pipe.fileHandleForReading.fileDescriptor, collector: collector)
                }
                outputClosed = true
                try? stdoutPipe?.fileHandleForReading.close()
                try? stderrPipe?.fileHandleForReading.close()
                return (stdoutCollector.map { String(decoding: $0.data, as: UTF8.self) } ?? "",
                        stderrCollector.map { String(decoding: $0.data, as: UTF8.self) } ?? "")
            }
            continuation.resume(returning: ChildProcessResult(
                outcome: outcome,
                stdout: stdout,
                stderr: stderr,
                duration: Date().timeIntervalSince(startTime)
            ))
        }

        private func configureOutput(_ pipe: Pipe, collector: BoundedOutputCollector) -> Bool {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let eof = self.outputQueue.sync {
                    guard !self.outputClosed else { return false }
                    return self.drain(descriptor, collector: collector)
                }
                if eof { handle.readabilityHandler = nil }
            }
            return true
        }

        /// 非阻塞且每次有限读取；后台后代持续写入也不能阻塞主进程退出收尾。
        private func drain(_ descriptor: Int32, collector: BoundedOutputCollector) -> Bool {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var remaining = 256 * 1024
            while remaining > 0 {
                let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining))
                if count > 0 {
                    collector.append(Data(buffer.prefix(count)))
                    remaining -= count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return count == 0
                }
            }
            return false
        }
    }
}
