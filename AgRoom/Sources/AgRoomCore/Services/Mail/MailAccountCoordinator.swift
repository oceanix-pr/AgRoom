import Foundation

/// Process-local account leases. No services, connections or private content are cached here.
public actor MailAccountCoordinator {
    public static let shared = MailAccountCoordinator()
    private struct Waiter {
        let id: UUID
        let background: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    @TaskLocal private static var tickets: [String: UUID] = [:]
    private var busy: Set<String> = []
    private var owners: [String: UUID] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private var generations: [String: UInt] = [:]
    private var activeCancellation: [String: @Sendable () -> Void] = [:]
    public init() {}
    var waitingCount: Int { waiters.values.reduce(0) { $0 + $1.count } }

    public func withLease<T: Sendable>(space: AppSpace, accountId: UUID, background: Bool = false,
                                       maintenanceKey: String? = nil,
                                       operation: @escaping @Sendable () async throws -> T) async throws -> T {
        // Covers the whole network operation, including queued callers. Restore
        // cannot overtake a request that will later publish an older mail snapshot.
        let maintenance: ResourceMaintenance.Lease?
        if let maintenanceKey, !ResourceMaintenance.owned.contains(maintenanceKey) {
            maintenance = try ResourceMaintenance.Lease(key: maintenanceKey, exclusive: false)
        } else { maintenance = nil }
        defer { withExtendedLifetime(maintenance) {} }
        let key = "\(space.rawValue)|\(accountId.uuidString)"
        let generation = generations[key, default: 0]
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if busy.insert(key).inserted { owners[key] = id; continuation.resume() }
                else { waiters[key, default: []].append(Waiter(id: id, background: background, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancelWaiting(key: key, id: id) } }
        defer { release(key, id: id) }
        try Task.checkCancellation()
        guard generations[key, default: 0] == generation else { throw CancellationError() }
        var tickets = Self.tickets
        tickets[key] = id
        let ownedTickets = tickets
        let task = Task { try await Self.$tickets.withValue(ownedTickets) { try await operation() } }
        activeCancellation[key] = { task.cancel() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Deletion revokes in-flight work, then obtains the lease before deleting rows.
    public func invalidate(space: AppSpace, accountId: UUID) {
        let key = "\(space.rawValue)|\(accountId.uuidString)"
        if busy.contains(key) { generations[key, default: 0] &+= 1 }
        activeCancellation[key]?()
        let removed = waiters.removeValue(forKey: key) ?? []
        for waiter in removed { waiter.continuation.resume(throwing: CancellationError()) }
    }

    /// A background sync retains its connection but yields ownership between UID batches.
    public func yieldLease(space: AppSpace, accountId: UUID) async throws {
        let key = "\(space.rawValue)|\(accountId.uuidString)"
        guard let id = Self.tickets[key], owners[key] == id else { throw CancellationError() }
        let cancellation = activeCancellation[key]
        let generation = generations[key, default: 0]
        release(key, id: id)
        await Task.yield()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if busy.insert(key).inserted { owners[key] = id; continuation.resume() }
                else { waiters[key, default: []].append(Waiter(id: id, background: true, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancelWaiting(key: key, id: id) } }
        activeCancellation[key] = cancellation
        try Task.checkCancellation()
        guard generations[key, default: 0] == generation else { throw CancellationError() }
    }

    private func cancelWaiting(key: String, id: UUID) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }),
              let waiter = waiters[key]?.remove(at: index) else { return }
        if waiters[key]?.isEmpty == true { waiters[key] = nil }
        waiter.continuation.resume(throwing: CancellationError())
    }
    private func release(_ key: String, id: UUID) {
        guard owners[key] == id else { return }
        owners[key] = nil
        activeCancellation[key] = nil
        if var queue = waiters[key], !queue.isEmpty {
            let index = queue.firstIndex(where: { !$0.background }) ?? 0
            let next = queue.remove(at: index)
            waiters[key] = queue.isEmpty ? nil : queue
            owners[key] = next.id
            next.continuation.resume()
        } else {
            busy.remove(key)
            generations[key] = nil
        }
    }
}
