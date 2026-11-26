import Darwin
import Foundation

// 子进程管理相关符号：libproc 未随 Swift 的 Darwin 模块导出，需显式声明。
// `proc_listchildpids` 是 macOS 10.7+ 的稳定公开符号（libproc.dylib），
// 返回写入 buffer 的 pid 数（或字节数，视实现而定）——调用侧统一按
// `min(written, capacity)` 截断，两种口径都能得到正确的 pid 列表
@_silgen_name("proc_listchildpids")
private func agroomProcListChildPids(
    _ ppid: pid_t,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32

// MARK: - Process Terminator

/// 子进程超时熔断：SIGTERM → 宽限期 → SIGKILL 的两级终止。
///
/// 为什么必须两级：只发 SIGTERM 时，忽略该信号的进程（shell 脚本里的子进程树、
/// 卡在不可中断系统调用中的进程等）永不退出，`Process.terminationHandler` 不触发，
/// 等待它的续体就永久挂起——工具循环被这一步占死，用户除了中止整轮对话别无自救路径。
/// SIGKILL 无法被捕获或忽略，作为兜底保证续体一定能被恢复。
///
/// 为什么必须杀整棵树：`Process` 只暴露直接子进程，`kill(pid, …)` 也只作用于它；
/// 脚本派生出的后代（`zsh -c '… python …'` 里的 python、后台任务等）在直接子进程
/// 退出后会被重新挂到 launchd 下成为孤儿继续占资源。这里在信号前后按
/// `proc_listchildpids` 递归枚举后代，对整个进程树发信号。
///
/// `shell_run`（超时上限 600s）与 `python_execute` 共用此实现，避免两处熔断语义分叉。
public enum ProcessTerminator {

    /// SIGTERM 到 SIGKILL 的宽限期：给进程正常清理的机会，又不把挂起窗口拉得太长
    public static let killGracePeriod: TimeInterval = 3

    /// 串行熔断队列：超时检查与两级信号发送都在此队列上，天然避免并发重复发信号
    private static let queue = DispatchQueue(label: "com.agroom.app.processTerminator")

    /// Process 非 Sendable，跨队列闭包按项目惯例用盒子封装
    private struct ProcessBox: @unchecked Sendable { let process: Process }

    /// 安排一次超时熔断。进程已正常退出时，到点的检查自动跳过，不产生任何副作用。
    ///
    /// - Parameters:
    ///   - process: 待熔断的进程；调用前必须已经 `run()`，否则 `terminate()` 无意义
    ///   - timeout: 自调用时刻起算的超时秒数
    ///   - label: 日志定位标识（哪个工具触发的熔断）
    ///   - killGracePeriod: SIGTERM 到 SIGKILL 的宽限期；可注入是为了让测试不必等满 3s
    ///   - onTimeout: 判定超时后的回调，在熔断队列上执行（调用方据此置超时标记）；
    ///     回调内禁止阻塞——它会推迟信号发送
    public static func scheduleTimeout(
        process: Process,
        timeout: TimeInterval,
        label: String,
        killGracePeriod: TimeInterval = ProcessTerminator.killGracePeriod,
        onTimeout: @escaping @Sendable () -> Void
    ) {
        let box = ProcessBox(process: process)
        queue.asyncAfter(deadline: .now() + timeout) {
            guard box.process.isRunning else { return }
            onTimeout()
            escalate(box: box, label: label, killGracePeriod: killGracePeriod)
        }
    }

    /// 立即终止进程树（取消传播用）：SIGTERM → 宽限期 → SIGKILL。
    /// 进程已退出时无副作用；与 `scheduleTimeout` 共用同一熔断实现，语义不分叉。
    public static func terminate(
        process: Process,
        label: String,
        killGracePeriod: TimeInterval = ProcessTerminator.killGracePeriod
    ) {
        let box = ProcessBox(process: process)
        queue.async {
            escalate(box: box, label: label, killGracePeriod: killGracePeriod)
        }
    }

    /// 两级终止的实际执行（须在 `queue` 上调用）：枚举后代 → SIGTERM → 宽限期后 SIGKILL 兜底
    private static func escalate(box: ProcessBox, label: String, killGracePeriod: TimeInterval) {
        guard box.process.isRunning else { return }
        let parentPID = box.process.processIdentifier
        // 先枚举后代再终止直接子进程：父进程一旦退出，其子进程会被 reparent 到
        // launchd，届时再按父 PID 枚举将拿不到任何结果
        let descendants = descendantPIDs(of: parentPID)
        box.process.terminate()
        for pid in descendants { kill(pid, SIGTERM) }
        queue.asyncAfter(deadline: .now() + killGracePeriod) {
            // 兜底 SIGKILL：直接子进程与后代一并处理。
            // 直接子进程已退出时，早先捕获的后代仍需兜底（其中可能有忽略 SIGTERM 的
            // 顽固进程）；3s 宽限期内 PID 回绕复用可忽略，且父进程未 wait 回收时
            // 其 PID 不会被复用，故不存在误杀无关进程的风险
            var targets = Set(descendants)
            targets.formUnion(descendantPIDs(of: parentPID))
            for pid in targets where pid != parentPID { kill(pid, SIGKILL) }
            if box.process.isRunning {
                HubLogger.shared.warning(
                    "\(label) ignored SIGTERM for \(Int(killGracePeriod))s; escalating to SIGKILL"
                )
                kill(parentPID, SIGKILL)
            }
        }
    }

    // MARK: - Descendant Enumeration

    /// 递归枚举某进程的全部后代（子、孙……），用于对整棵进程树发信号
    private static func descendantPIDs(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var seen = Set<pid_t>()
        var frontier: [pid_t] = [pid]
        while let current = frontier.popLast() {
            for child in childPIDs(of: current) where seen.insert(child).inserted {
                result.append(child)
                frontier.append(child)
            }
        }
        return result
    }

    /// 直接子进程列表（libproc 的 `proc_listchildpids`）。
    /// 首次以较大容量调用后按返回值截断——返回口径为「pid 数」或「字节数」时
    /// `min(written, capacity)` 都能得到正确长度的前缀，多余的零项由过滤剔除
    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let capacity = 1024
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBytes { raw in
            agroomProcListChildPids(pid, raw.baseAddress, Int32(raw.count))
        }
        guard written > 0 else { return [] }
        let actual = min(Int(written), capacity)
        return buffer[0..<actual].filter { $0 > 0 }
    }
}

// MARK: - Cancellation Gate

/// 取消标记：跨「取消处理器」与「后台执行块」传递取消意图。
/// 覆盖「取消先于进程启动」的竞态——此时 `terminate` 尚无进程可终止，
/// 需在执行块真正 `run()` 之后再补一次判断并终止。
final class CancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func markCancelled() {
        lock.withLock { cancelled = true }
    }
}

// MARK: - Bounded Output Collector

/// 子进程输出收集器：在管道抽取阶段就地限幅，避免长任务/大输出在熔断前把内存吃满。
/// 与 `ProcessTerminator` 同属子进程支撑层（`shell_run` / `python_execute` 共用）。
///
/// 保留头尾各半、中间丢弃并标记：与面向模型展示的截断语义一致（首尾信息量最大）。
/// 抽取回调与收尾读取可能来自不同线程，内部加锁；`data` 返回时拼接头 + 截断标记 + 尾
final class BoundedOutputCollector: @unchecked Sendable {
    private static let truncationNotice = Data("\n...[truncated]...\n".utf8)

    private let lock = NSLock()
    private let halfLimit: Int
    private var head = Data()
    private var tail = Data()
    private var droppedBytes = 0

    /// - Parameter limit: 期望保留的总字节上限（头尾各半）
    init(limit: Int) {
        self.halfLimit = max(limit / 2, 1)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            var remainder = data[...]
            if head.count < halfLimit {
                let take = min(halfLimit - head.count, remainder.count)
                head.append(contentsOf: remainder.prefix(take))
                remainder = remainder.dropFirst(take)
            }
            guard !remainder.isEmpty else { return }
            tail.append(contentsOf: remainder)
            if tail.count > halfLimit {
                let overflow = tail.count - halfLimit
                droppedBytes += overflow
                tail.removeFirst(overflow)
            }
        }
    }

    /// 是否发生过截断（中间字节已被丢弃）
    var isTruncated: Bool { lock.withLock { droppedBytes > 0 } }

    /// 限幅后的完整内容：未截断时即原文；发生截断时为头 + 标记 + 尾
    var data: Data {
        lock.withLock {
            guard droppedBytes > 0 else { return head + tail }
            var result = head
            result.append(Self.truncationNotice)
            result.append(tail)
            return result
        }
    }
}
