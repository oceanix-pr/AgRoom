import Foundation

// MARK: - Timeout Budget

/// 邮件网络操作的超时预算（毫秒，按操作分级）。
///
/// **与上游的关系**：`MailFoundation` 的会话自带每命令超时，默认 120 秒
/// （`defaultImapTimeoutMs` / `defaultSmtpTimeoutMs`），且它把所有会话错误都
/// 抹成同一种描述，调用方无法区分「超时」与「服务器返回异常」。本预算的作用是
/// 在它之内再收一层：
///
/// 1. 按操作分级，而不是一律等 120 秒——点一次星标挂两分钟不是可接受的交互；
/// 2. 让超时以 `MailProtocolError.timedOut` 的明确语义浮上来；
/// 3. 对发信单独给出「结果未知」语义（见 `MailProtocolError.sendResultUnknown`）。
///
/// 因此**每一项都必须严格小于上游的 120 秒**，否则上限仍由上游决定、语义仍是含混的。
/// 等分段拉取与按部件拉取落地后再收紧拉取类预算（见 `docs/wiki/10-改进清单.md`）。
///
/// 可注入是为了测试：回归用例把预算压到几十毫秒即可验证超时路径，
/// 不需要真正等待秒级。
public struct MailTimeoutBudget: Sendable, Equatable {
    /// 上游会话超时（120 秒）；本类型的各项取值须低于它。
    public static let upstreamSessionTimeout = 120_000

    /// TCP 建连 + TLS 握手。
    public var connect: Int
    /// 登录（IMAP LOGIN / SMTP SASL）。
    public var authenticate: Int
    /// `LIST` 文件夹发现。
    public var listFolders: Int
    /// `STATUS` 游标读取。
    public var folderStatus: Int
    /// 增量摘要拉取；单次请求可能覆盖大量邮件，预算需宽松。
    public var fetchSummaries: Int
    /// 正文拉取；当前实现会整封下载（含附件），预算需覆盖大邮件。
    public var fetchBody: Int
    /// 标记回写、移动、删除等写操作。
    public var write: Int
    /// SMTP 投递（含 DATA 阶段）；超时按「结果未知」处理，故不能自动重试。
    public var send: Int

    public init(
        connect: Int = 20_000,
        authenticate: Int = 20_000,
        listFolders: Int = 30_000,
        folderStatus: Int = 20_000,
        fetchSummaries: Int = 90_000,
        fetchBody: Int = 90_000,
        write: Int = 30_000,
        send: Int = 100_000
    ) {
        self.connect = connect
        self.authenticate = authenticate
        self.listFolders = listFolders
        self.folderStatus = folderStatus
        self.fetchSummaries = fetchSummaries
        self.fetchBody = fetchBody
        self.write = write
        self.send = send
    }

    public static let `default` = MailTimeoutBudget()
}

// MARK: - Deadline Guard

/// 网络操作的截止时间守卫：到点主动断链，让卡住的读立即失败收尾。
///
/// **为什么不用上游 `MailFoundation.withTimeout`**：它基于结构化任务组，
/// 超时后会**等待落败的子任务结束**；而套接字读不响应协作式取消，遇到半开连接
/// （对端消失、中间设备静默丢包）时子任务永不结束，等于没有超时。
///
/// 超时或显式取消先通过单次恢复门闩决定结果，再请求断链来唤醒阻塞中的读。
/// 正常完成后不再断链；超时或取消后的连接不可复用。网络写入仍可能已经到达
/// 服务器，调用方必须保留既有的结果未知保护，不能把取消当作确定未投递。
enum MailDeadline {

    /// 在预算内执行 `operation`；超时则断链并抛 `MailProtocolError.timed_out`。
    ///
    /// `onExpiry` 必须是幂等且非阻塞的：它可能和正常完成路径并发执行。
    ///
    /// 操作在超时点前落地时**返回结果而不是报错**：单次恢复门闩
    /// 让看门狗放弃判断超时，不会掐断仍在使用的连接。
    ///
    /// 不用 `withThrowingTaskGroup` 竞速：落选任务若挂在底层 `await` 上不响应取消，
    /// 结构化并发会在组退出时永远等它。这里改为独立任务 + 单次恢复的 continuation：
    /// 看门狗与主操作谁先抢到恢复权谁赢，落选者被取消 + 断链尽力唤醒（连接已作废，
    /// 写入的残留结果必须由调用方按结果未知处理，不自动重放）。
    static func run<T: Sendable>(
        milliseconds: Int,
        label: String,
        onExpiry: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = RaceGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard race.install(continuation) else {
                    continuation.resume(throwing: CancellationError()); return
                }
                let operationTask = Task {
                    do {
                        try Task.checkCancellation()
                        let value = try await operation()
                        _ = race.settle(.success(value))
                    } catch { _ = race.settle(.failure(error)) }
                }
                race.installOperation(operationTask)
                // Nonpositive / Int.max disables the clock, while explicit
                // cancellation still closes a blocked connection.
                if milliseconds > 0, milliseconds < Int.max {
                    let watchdog = Task {
                        do { try await Task.sleep(for: .milliseconds(milliseconds)) }
                        catch { return }
                        guard race.settle(.failure(MailProtocolError.timedOut(label)), cancelOperation: true, cancelWatchdog: false) else { return }
                        HubLogger.shared.warning("Mail operation timed out after \(milliseconds) ms: \(label); closing the connection")
                        await onExpiry()
                    }
                    race.installWatchdog(watchdog)
                }
            }
        } onCancel: {
            guard race.settle(.failure(CancellationError()), cancelOperation: true) else { return }
            Task { await onExpiry() }
        }
    }

    /// Only small ownership changes happen under the lock. Task cancellation,
    /// continuation callbacks and connection I/O always run after releasing it.
    private final class RaceGate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var won = false
        private var continuation: CheckedContinuation<T, Error>?
        private var operation: Task<Void, Never>?
        private var watchdog: Task<Void, Never>?

        func install(_ value: CheckedContinuation<T, Error>) -> Bool {
            lock.withLock {
                guard !won else { return false }
                continuation = value; return true
            }
        }

        func installOperation(_ task: Task<Void, Never>) {
            let accepted = lock.withLock {
                guard !won else { return false }
                operation = task; return true
            }
            if !accepted { task.cancel() }
        }

        func installWatchdog(_ task: Task<Void, Never>) {
            let accepted = lock.withLock {
                guard !won else { return false }
                watchdog = task; return true
            }
            if !accepted { task.cancel() }
        }

        @discardableResult
        func settle(_ result: Result<T, Error>, cancelOperation: Bool = false, cancelWatchdog: Bool = true) -> Bool {
            let claimed = lock.withLock { () -> (Bool, CheckedContinuation<T, Error>?, Task<Void, Never>?, Task<Void, Never>?) in
                guard !won else { return (false, nil, nil, nil) }
                won = true
                let values = (true, continuation, operation, watchdog)
                continuation = nil; operation = nil; watchdog = nil
                return values
            }
            guard claimed.0 else { return false }
            if cancelOperation { claimed.2?.cancel() }
            if cancelWatchdog { claimed.3?.cancel() }
            claimed.1?.resume(with: result)
            return true
        }
    }
}

// MARK: - Client Convenience

extension MailDeadline {

    /// 按预算执行一次协议调用；超时先断开该客户端，让阻塞中的读立即失败收尾。
    ///
    /// 超时后连接**不可再用**是有意为之：主动断链是唯一能解开不响应取消的
    /// 套接字读的手段，所以调用方在失败路径上必须重新建连。
    static func call<C: MailConnectedClient, T: Sendable>(
        _ milliseconds: Int,
        label: String,
        client: C,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await run(
            milliseconds: milliseconds,
            label: label,
            onExpiry: { await client.disconnect() },
            operation: body
        )
    }

    /// 建连 + 登录，两段各自受预算约束（握手慢与认证慢要能分辨）。
    static func openSession<C: MailConnectedClient>(
        _ client: C,
        username: String,
        password: String,
        budget: MailTimeoutBudget
    ) async throws {
        try await call(budget.connect, label: "connect", client: client) {
            try await client.connect()
        }
        try await call(budget.authenticate, label: "authenticate", client: client) {
            try await client.authenticate(username: username, password: password)
        }
    }
}
