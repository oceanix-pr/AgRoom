import Foundation

/// A single deadline covers queueing and in-flight cooperative operations.
public enum TaskDeadline {
    public static func run<T: Sendable>(until deadline: Date?,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard let deadline else { return try await operation() }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw BudgetError.deadlineExceeded }
        return try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(remaining))
                throw BudgetError.deadlineExceeded
            }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
