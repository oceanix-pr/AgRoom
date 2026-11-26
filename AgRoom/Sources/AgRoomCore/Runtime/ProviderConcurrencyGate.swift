import Foundation

// MARK: - Provider Concurrency Gate

/// 一次并发槽位的所有权凭据。释放必须凭票且只生效一次，
/// 避免重复 defer/取消路径把同一槽位释放两次。
public struct ProviderGateTicket: Sendable, Hashable {
    public let key: String
    public let id: UUID
}

public enum ProviderGateError: LocalizedError, Sendable, Equatable {
    case cancelled
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The model request was cancelled while waiting for a provider slot."
        case .timedOut(let key):
            return "Timed out waiting for a provider concurrency slot (\(key))."
        }
    }
}

/// 按 Provider 端点限制同时进行的模型请求数。等待者拥有稳定 ID：
/// 取消会把它从队列移除，排队超时会返回明确错误，槽位只释放一次。
/// 流式请求的槽位由消费方持有到流结束（见 CloudProvider）。
public actor ProviderConcurrencyGate {
    public static let shared = ProviderConcurrencyGate()
    public static let defaultQueueTimeout: TimeInterval = 120

    private let limit: Int
    private var active: [String: Int] = [:]
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<ProviderGateTicket, Error>
    }
    private var waiters: [String: [Waiter]] = [:]
    private var activeTickets: [UUID: String] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    public init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    public func acquire(
        _ key: String,
        timeout: TimeInterval? = ProviderConcurrencyGate.defaultQueueTimeout
    ) async throws -> ProviderGateTicket {
        let waiterID = UUID()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    enqueue(key: key, id: waiterID, continuation: continuation, timeout: timeout)
                }
            } onCancel: {
                Task { await self.cancelWaiting(key: key, id: waiterID) }
            }
        } catch ProviderGateError.cancelled {
            throw CancellationError()
        }
    }

    /// 凭票释放；重复释放、未知票和越界计数都静默忽略，绝不把 active 减成负数。
    public func release(_ ticket: ProviderGateTicket) {
        guard activeTickets[ticket.id] == ticket.key else { return }
        activeTickets[ticket.id] = nil
        if var queue = waiters[ticket.key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[ticket.key] = queue.isEmpty ? nil : queue
            timeoutTasks.removeValue(forKey: next.id)?.cancel()
            activeTickets[next.id] = ticket.key
            // 直接把槽位交给下一个等待者，active 不变。
            next.continuation.resume(returning: ProviderGateTicket(key: ticket.key, id: next.id))
        } else {
            let remaining = max(0, active[ticket.key, default: 0] - 1)
            active[ticket.key] = remaining == 0 ? nil : remaining
        }
    }

    public func activeCount(_ key: String) -> Int {
        active[key, default: 0]
    }

    public func waitingCount(_ key: String) -> Int {
        waiters[key]?.count ?? 0
    }
    var retainedTicketCount: Int { activeTickets.count }

    // MARK: Actor-isolated queue operations

    private func enqueue(
        key: String,
        id: UUID,
        continuation: CheckedContinuation<ProviderGateTicket, Error>,
        timeout: TimeInterval?
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: ProviderGateError.cancelled)
            return
        }
        let current = active[key, default: 0]
        if current < limit {
            active[key] = current + 1
            activeTickets[id] = key
            continuation.resume(returning: ProviderGateTicket(key: key, id: id))
            return
        }
        waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
        if let timeout, timeout > 0 {
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.timeoutWaiting(key: key, id: id)
            }
        }
    }

    private func cancelWaiting(key: String, id: UUID) {
        guard var queue = waiters[key],
              let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[key] = queue.isEmpty ? nil : queue
        timeoutTasks.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(throwing: ProviderGateError.cancelled)
    }

    private func timeoutWaiting(key: String, id: UUID) {
        guard var queue = waiters[key],
              let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[key] = queue.isEmpty ? nil : queue
        timeoutTasks.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(throwing: ProviderGateError.timedOut(key))
    }
}
