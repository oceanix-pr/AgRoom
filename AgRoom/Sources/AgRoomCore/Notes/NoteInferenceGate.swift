import Foundation

/// Only resource ownership is shared. No model, audio, identity or space data is cached here.
actor NoteInferenceGate {
    static let shared = NoteInferenceGate()
    private var owner: UUID?
    private var waiters: [(UUID,CheckedContinuation<Void,Error>)] = []
    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        if owner == nil { owner = id; return id }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiters.append((id,continuation)) }
        } onCancel: { Task { await self.cancel(id) } }
        if Task.isCancelled { release(id); throw CancellationError() }
        return id
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: index).1.resume(throwing: CancellationError()) }
    }
    func release(_ id: UUID) {
        guard owner == id else { return }
        if waiters.isEmpty { owner = nil }
        else { let next = waiters.removeFirst(); owner = next.0; next.1.resume() }
    }
}
