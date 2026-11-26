import Foundation

// MARK: - Background Job

/// 后台作业：非会话类长任务（备份导出/恢复等）的统一载体。
/// 「会话前台，作业后台」：与消息流强耦合的 Agent 运行留在前台会话，
/// 发起后用户会切走、完成时需要拉回来的任务收进 JobCenter
public struct BackgroundJob: Identifiable, Equatable, Sendable, Codable {

    /// 作业状态机：queued → running → succeeded / failed / cancelled
    public enum State: String, Codable, Equatable, Sendable {
        case queued
        case running
        case awaitingSave
        case succeeded
        case failed
        case cancelled
        case interrupted
        case interruptionAcknowledged

        public var isFinished: Bool {
            switch self {
            case .queued, .running, .awaitingSave: return false
            case .succeeded, .failed, .cancelled, .interrupted, .interruptionAcknowledged: return true
            }
        }
    }

    public var isActive: Bool { state == .queued || state == .running }

    public let id: UUID
    /// 已本地化的显示名（提交方负责 L.string）
    public let name: String
    /// 作业类型标识（backup-export / backup-restore …）
    public let kind: String
    public let space: AppSpace?
    public let origin: String?
    public internal(set) var resultPath: String?
    public let submittedAt: Date
    public internal(set) var state: State = .queued
    /// 进度 0…1；nil = 不确定进度（转圈）
    public internal(set) var progress: Double?
    /// 结果文案（已本地化，如「已导出 12 会话 / 8 记忆 / 5 技能」）
    public internal(set) var resultText: String?
    public internal(set) var errorText: String?
    public internal(set) var finishedAt: Date?
    public internal(set) var historyTruncated: Bool?

    init(id: UUID = UUID(), name: String, kind: String, space: AppSpace? = nil, origin: String? = nil, submittedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.space = space
        self.origin = origin
        self.submittedAt = submittedAt
    }
}

// MARK: - Job Context

/// 作业执行上下文：上报进度与结果文案
public struct JobContext: Sendable {
    let progressHandler: @Sendable (Double?) -> Void
    let resultHandler: @Sendable (String) -> Void
    var resultPathHandler: (@Sendable (String) -> Void)? = nil

    /// 上报进度（0…1；nil = 不确定进度）
    public func reportProgress(_ value: Double?) {
        progressHandler(value.map { min(max($0, 0), 1) })
    }

    public func reportResultURL(_ url: URL) { resultPathHandler?(url.path) }

    /// 上报结果文案（已本地化；完成后展示在指示器与设置页状态行）
    public func reportResult(_ text: String) {
        resultHandler(text)
    }
}

/// Independent of the bounded toolbar history. A single observer can attach even after work finishes.
public struct JobSubmission: Sendable {
    public let id: UUID
    public let space: AppSpace
    public let completion: AsyncStream<JobOutcome>
}

public struct JobOutcome: Sendable {
    public let job: BackgroundJob
    public let historySaved: Bool
    public var state: BackgroundJob.State { historySaved ? job.state : .awaitingSave }
}

// MARK: - Job Center

/// 后台任务中心：并发上限 2（再多互相抢 IO）、协作式取消、
/// 状态经 AsyncStream 广播给 UI（工具栏作业指示器）。
/// 未完成作业不跨重启恢复（分钟级短任务，重启即作废）；
/// Indicator history is bounded; space-bound database receipts remain pageable.
/// A durable receipt is recorded before work, and a terminal receipt before completion is published.
/// 完成通知经 onCompletion 钩子由 UI 层注入（前台判定 + 文案本地化 + 失败必达）
public final class JobCenter: @unchecked Sendable {
    public static let shared = JobCenter()
    /// Isolated/temporary hosts retain activity in memory without touching the user's history.
    public static func ephemeral() -> JobCenter {
        JobCenter(historyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("jobs.json"),historyWriter: { _,_ in })
    }
    static let maxConcurrentJobs = 2
    static let maxHistory = 20
    static let maxPersistedHistory = maxHistory
    public typealias Operation = @Sendable (JobContext) async throws -> Void
    typealias HistoryWriter = @Sendable ([BackgroundJob], URL) throws -> Void

    // The lock owns only short state mutations. Disk operations have a separate serial owner.
    private let lock = NSLock()
    private let historyQueue = DispatchQueue(label: "com.agroom.app.job-history")
    private let publicationQueue = DispatchQueue(label: "com.agroom.app.job-publication")
    private var jobs: [BackgroundJob] = []
    private var operations: [UUID: Operation] = [:]
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingFinals: [UUID: BackgroundJob] = [:]
    private var historyStores: [UUID: ProductJobRunStore] = [:]
    private var continuations: [UUID: AsyncStream<[BackgroundJob]>.Continuation] = [:]
    private var completionReceipts: [UUID: AsyncStream<JobOutcome>.Continuation] = [:]
    private var completionHook: (@Sendable (BackgroundJob) async -> Void)?
    private let historyFileURL: URL?
    private let historyWriter: HistoryWriter

    public var onCompletion: (@Sendable (BackgroundJob) async -> Void)? {
        get { lock.withLock { completionHook } }
        set { lock.withLock { completionHook = newValue } }
    }

    init(historyFileURL: URL? = nil, historyWriter: HistoryWriter? = nil) {
        self.historyFileURL = historyFileURL ?? Self.defaultHistoryFileURL()
        self.historyWriter = historyWriter ?? Self.writeHistory
        restoreHistory()
    }

    deinit {
        // End subscriber tasks when a temporary center is released.
        for continuation in continuations.values { continuation.finish() }
        for receipt in completionReceipts.values { receipt.finish() }
    }

    private static func defaultHistoryFileURL() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("AgRoom").appendingPathComponent("JobHistory.json")
    }

    private func historyURL(space: AppSpace?) -> URL? {
        guard let base = historyFileURL else { return nil }
        guard let space else { return base }
        return base.deletingLastPathComponent().appendingPathComponent(space.rawValue)
            .appendingPathComponent(base.lastPathComponent)
    }

    private func restoreHistory() {
        let urls = [historyURL(space: nil)] + AppSpace.allCases.map { historyURL(space: $0) }
        let combined = urls.compactMap { $0 }.flatMap { url -> [BackgroundJob] in
            guard let data = try? Data(contentsOf: url),
                  let entries = try? JSONDecoder().decode([BackgroundJob].self, from: data) else { return [] }
            return entries
        }
        var seen = Set<UUID>()
        let unique = combined.filter(\.state.isFinished).filter { seen.insert($0.id).inserted }
        let keep = Self.retainedHistoryIDs(unique)
        jobs = unique.filter { keep.contains($0.id) }.sorted { $0.submittedAt > $1.submittedAt }
    }

    private static func retainedHistoryIDs(_ entries: [BackgroundJob]) -> Set<UUID> {
        var counts: [String: Int] = [:]
        var keep = Set<UUID>()
        for job in entries.filter(\.state.isFinished).sorted(by: {
            ($0.finishedAt ?? $0.submittedAt) > ($1.finishedAt ?? $1.submittedAt)
        }) {
            let key = job.space?.rawValue ?? "legacy"
            if counts[key, default: 0] < maxHistory {
                counts[key, default: 0] += 1
                keep.insert(job.id)
            }
        }
        return keep
    }

    private static func writeHistory(_ history: [BackgroundJob], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: url, options: .atomic)
    }

    // Called on historyQueue, never while holding lock. Only this space is written.
    private func persist(_ history: [BackgroundJob], space: AppSpace?) -> Bool {
        guard let url = historyURL(space: space) else { return false }
        do {
            let recent = history.sorted { ($0.finishedAt ?? $0.submittedAt) > ($1.finishedAt ?? $1.submittedAt) }
            try historyWriter(Array(recent.prefix(Self.maxPersistedHistory)), url)
            return true
        } catch {
            HubLogger.shared.warning("Job history persistence failed; completion retained for retry")
            return false
        }
    }

    public func snapshot() -> [BackgroundJob] { lock.withLock { jobs } }
    public func snapshot(space: AppSpace) -> [BackgroundJob] { lock.withLock { jobs.filter { $0.space == space } } }
    public func history() -> [BackgroundJob] { lock.withLock { jobs.filter(\.state.isFinished) } }

    public func stream() -> AsyncStream<[BackgroundJob]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations[id] = nil }
            }
            publicationQueue.sync {
                let snapshot = lock.withLock {
                    continuations[id] = continuation
                    return jobs
                }
                continuation.yield(snapshot)
            }
        }
    }

    public func stream(space: AppSpace) -> AsyncStream<[BackgroundJob]> {
        let upstream = stream()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await values in upstream {
                    guard !Task.isCancelled else { break }
                    continuation.yield(values.filter { $0.space == space })
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // Reading the latest snapshot inside one publication owner prevents older events
    // from being delivered after a newer terminal snapshot. Callbacks stay outside lock.
    private func broadcast() {
        publicationQueue.async { [self] in
            let (snapshot, subscribers) = lock.withLock { (jobs, Array(continuations.values)) }
            for subscriber in subscribers { subscriber.yield(snapshot) }
        }
    }

    @discardableResult
    public func submit(name: String, kind: String, space: AppSpace? = nil, origin: String? = nil,
                       historyStore: ProductJobRunStore? = nil,
                       operation: @escaping Operation) -> UUID {
        enqueue(name: name, kind: kind, space: space, origin: origin, historyStore: historyStore,
                receipt: nil, operation: operation)
    }

    public func submitTracked(name: String, kind: String, space: AppSpace, origin: String,
                              historyStore: ProductJobRunStore?, operation: @escaping Operation) -> JobSubmission {
        let (stream, receipt) = AsyncStream.makeStream(of: JobOutcome.self, bufferingPolicy: .bufferingNewest(1))
        let id = enqueue(name: name, kind: kind, space: space, origin: origin, historyStore: historyStore,
                         receipt: receipt, operation: operation)
        return JobSubmission(id: id, space: space, completion: stream)
    }

    private func enqueue(name: String, kind: String, space: AppSpace?, origin: String?,
                         historyStore: ProductJobRunStore?, receipt: AsyncStream<JobOutcome>.Continuation?,
                         operation: @escaping Operation) -> UUID {
        let job = BackgroundJob(name: name, kind: kind, space: space, origin: origin)
        lock.withLock {
            jobs.insert(job, at: 0)
            operations[job.id] = operation
            completionReceipts[job.id] = receipt
            if historyStore?.space == space { historyStores[job.id] = historyStore }
        }
        broadcast()
        pump()
        return job.id
    }

    public func cancel(id: UUID) {
        let (task, queued) = lock.withLock {
            let queued = jobs.contains { $0.id == id && $0.state == .queued } && operations[id] != nil
            if queued { operations[id] = nil }
            return (runningTasks[id], queued)
        }
        task?.cancel()
        if queued { finish(jobId: id, finalState: .cancelled) }
    }

    /// Migration and clearing share the history owner, so a stale cache snapshot
    /// cannot resurrect receipts after the user has cleared them.
    public func archiveHistory(to store: ProductJobRunStore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            historyQueue.async { [self] in
                do {
                    let entries = lock.withLock { jobs.filter { $0.space == store.space && $0.state.isFinished } }
                    try store.saveCompleted(entries)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    @discardableResult
    public func clearFinished(space: AppSpace? = nil, historyStore: ProductJobRunStore? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            historyQueue.async { [self] in
                let scopes: [AppSpace?] = space.map { [$0] } ?? ([nil] + AppSpace.allCases.map { Optional($0) })
                var saved = true
                for scope in scopes {
                    let ids = lock.withLock { Set(jobs.filter { $0.state.isFinished && $0.space == scope }.map(\.id)) }
                    if persist([], space: scope) {
                        do {
                            if let historyStore, historyStore.space == scope { try historyStore.clear() }
                            lock.withLock { jobs.removeAll { ids.contains($0.id) } }
                        } catch { saved = false }
                    } else { saved = false }
                }
                broadcast()
                continuation.resume(returning: saved)
            }
        }
    }

    /// Saves retained completion receipts only; never repeats the underlying operation.
    @discardableResult
    public func retryHistoryPersistence(id: UUID? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            historyQueue.async { [self] in
                let scopes = lock.withLock { Set(pendingFinals.values.filter { id == nil || $0.id == id }.map(\.space)) }
                var saved = true
                for scope in scopes { if !commitHistory(space: scope) { saved = false } }
                broadcast()
                continuation.resume(returning: saved)
            }
        }
    }

    private func pump() {
        lock.lock()
        while runningTasks.count < Self.maxConcurrentJobs,
              let index = jobs.firstIndex(where: { $0.state == .queued && operations[$0.id] != nil }),
              let operation = operations[jobs[index].id] {
            jobs[index].state = .running
            let job = jobs[index]
            runningTasks[job.id] = Task { [weak self] in await self?.run(job, operation: operation) }
        }
        lock.unlock()
    }

    private func run(_ job: BackgroundJob, operation: Operation) async {
        let context = JobContext(
            progressHandler: { [weak self] progress in self?.update(id: job.id) { $0.progress = progress } },
            resultHandler: { [weak self] text in self?.update(id: job.id) { $0.resultText = text } },
            resultPathHandler: { [weak self] path in self?.update(id: job.id) { $0.resultPath = path } }
        )
        do {
            if let store = lock.withLock({ historyStores[job.id] }) { try await store.recordStarted(job) }
            try Task.checkCancellation()
            try await operation(context)
            finish(jobId: job.id, finalState: .succeeded)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            finish(jobId: job.id, finalState: cancelled ? .cancelled : .failed,
                   errorText: cancelled ? nil : error.localizedDescription)
        }
    }

    private func update(id: UUID, _ mutate: (inout BackgroundJob) -> Void) {
        lock.withLock {
            guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].state.isFinished,
                  pendingFinals[id] == nil else { return }
            mutate(&jobs[index])
        }
        broadcast()
    }

    private func finish(jobId: UUID, finalState: BackgroundJob.State, errorText: String? = nil) {
        historyQueue.async { [self] in
            let space: AppSpace?? = lock.withLock {
                guard let job = jobs.first(where: { $0.id == jobId }), !job.state.isFinished,
                      pendingFinals[jobId] == nil else { return nil }
                var completed = job
                completed.state = finalState
                completed.finishedAt = Date()
                completed.errorText = errorText
                pendingFinals[jobId] = completed
                operations[jobId] = nil
                return .some(job.space)
            }
            guard let space else { return }
            _ = commitHistory(space: space)
            broadcast()
            pump()
        }
    }

    /// Serialized prepare -> disk -> commit. Readers cannot see the terminal copy before disk succeeds.
    private func commitHistory(space: AppSpace?) -> Bool {
        let (history, stores) = lock.withLock {
            let history = jobs.filter { $0.space == space }.map { pendingFinals[$0.id] ?? $0 }.filter(\.state.isFinished)
            let stores = pendingFinals.values.filter { $0.space == space }.compactMap { final in
                historyStores[final.id]
            }
            return (history, stores)
        }
        var archived = true
        do {
            var savedStores = Set<String>()
            for store in stores where savedStores.insert(store.storageIdentity).inserted { try store.saveCompleted(history) }
        }
        catch {
            archived = false
            HubLogger.shared.warning("Durable job receipt could not be saved; completion retained for retry")
        }
        let saved = archived && persist(history, space: space)
        var deliveries: [(AsyncStream<JobOutcome>.Continuation, BackgroundJob)] = []
        let (completed, hook): ([BackgroundJob], (@Sendable (BackgroundJob) async -> Void)?) = lock.withLock {
            let pending = pendingFinals.values.filter { $0.space == space }
            var completed: [BackgroundJob] = []
            for final in pending {
                guard let index = jobs.firstIndex(where: { $0.id == final.id }) else { continue }
                if let receipt = completionReceipts.removeValue(forKey: final.id) { deliveries.append((receipt, final)) }
                runningTasks[final.id] = nil
                if saved {
                    jobs[index] = final
                    pendingFinals[final.id] = nil
                    historyStores[final.id] = nil
                    completed.append(final)
                } else {
                    jobs[index].state = .awaitingSave
                    jobs[index].progress = nil
                }
            }
            if saved {
                let keep = Self.retainedHistoryIDs(jobs)
                jobs.removeAll { $0.state.isFinished && !keep.contains($0.id) }
            }
            return (completed, completionHook)
        }
        for (receipt, job) in deliveries {
            receipt.yield(JobOutcome(job: job, historySaved: saved))
            receipt.finish()
        }
        if let hook { for job in completed { Task { await hook(job) } } }
        return saved
    }
}
