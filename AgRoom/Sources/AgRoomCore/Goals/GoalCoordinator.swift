import CryptoKit
import Foundation
import GRDB

/// The App drives segments through its existing chat host. This actor only owns
/// durable goal transitions; Core never reaches into UI or grants tool approval.
public actor GoalCoordinator {
    public let store: GoalStore
    public init(store: GoalStore) { self.store = store }

    public func prepare(_ goal: ExecutionGoal, runID: UUID, now: Date = Date()) async throws -> GoalExecutionSnapshot {
        let updated = try await store.update(id: goal.id, expectedRevision: goal.revision, event: "started") { value, db in
            guard value.activeRunID == nil, value.scope != nil,
                  [.ready, .running].contains(value.status) else { throw GoalError.busy }
            guard value.attemptCount < Int.max else { throw GoalError.invalid }
            value.deadline = nil
            value.activeRunID = runID; value.status = .running; value.stopReason = nil
            value.attemptCount += 1
            for index in value.definition.criteria.indices {
                value.definition.criteria[index].verdict = .unknown
                value.definition.criteria[index].evidenceRunID = nil
            }
            let attempt = GoalAttempt(id: runID, goalID: value.id, goalRevision: value.revision,
                sequence: value.attemptCount, startedAt: now)
            try db.execute(sql: "INSERT INTO goal_attempts(id,goalID,sequence,payload) VALUES(?,?,?,?)",
                arguments: [runID.uuidString, value.id.uuidString, attempt.sequence, try JSONEncoder().encode(attempt)])
        }
        return .init(goal: updated, runID: runID)
    }

    public func finish(goalID: UUID, receipt: GoalRunReceipt) async throws -> ExecutionGoal {
        let goal = try await store.goal(id: goalID)
        if goal.activeRunID == nil {
            let saved = try await store.attempt(goalID: goalID, runID: receipt.runID)
            guard saved?.receipt == receipt else { throw GoalError.changed }
            return goal // exact retry of a committed result, never re-execution
        }
        return try await store.update(id: goal.id, expectedRevision: goal.revision, event: "segment_finished") { value, db in
            guard receipt.isValid, value.activeRunID == receipt.runID,
                  (!receipt.hasCumulativeUsage || (receipt.recordedUsage.tokens >= value.spentTokens && receipt.recordedUsage.toolCalls >= value.toolCalls)),
                  receipt.progress?.isValid != false, receipt.evidenceDigests.count <= 256,
                  receipt.artifactVersionIDs.count <= 256 else { throw GoalError.changed }
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM goal_attempts WHERE id=? AND goalID=?", arguments: [receipt.runID.uuidString, goalID.uuidString]) else { throw GoalError.changed }
            var attempt = try JSONDecoder().decode(GoalAttempt.self, from: data)
            guard attempt.receipt == nil else { throw GoalError.changed }
            attempt.receipt = receipt; attempt.finishedAt = Date()
            try db.execute(sql: "UPDATE goal_attempts SET payload=? WHERE id=?", arguments: [try JSONEncoder().encode(attempt), receipt.runID.uuidString])
            if receipt.hasCumulativeUsage {
                value.spentTokens = receipt.usageMayBeUnreported && receipt.recordedUsage.tokens == value.spentTokens
                    ? GoalUsage.adding(value.spentTokens, value.reservedTokens) : receipt.recordedUsage.tokens
                value.toolCalls = receipt.recordedUsage.toolCalls
            } else {
                value.spentTokens = GoalUsage.adding(value.spentTokens, receipt.recordedUsage.tokens)
                value.toolCalls = GoalUsage.adding(value.toolCalls, receipt.recordedUsage.toolCalls)
            }
            if receipt.usageMayBeUnreported { value.usageIsIncomplete = true }
            value.reservedTokens = 0; value.reservedToolCalls = 0; value.activeRunID = nil
            value.latestRunID = receipt.runID; value.progress = receipt.progress
            let previous = Set(value.evidenceDigests)
            let added = Set(receipt.evidenceDigests).subtracting(previous)
            value.noProgressCount = added.isEmpty ? value.noProgressCount + 1 : 0
            value.evidenceDigests = Array((value.evidenceDigests + added.sorted()).suffix(512))
            for index in value.definition.criteria.indices where value.definition.criteria[index].kind == .executionCheck {
                value.definition.criteria[index].verdict = receipt.completion.status == .completed ? .passed
                    : (receipt.completion.status == .incomplete ? .failed : .unknown)
                value.definition.criteria[index].evidenceRunID = receipt.runID
            }
            // A user stop wins even if the old model finishes while cancellation drains.
            if value.status == .paused || value.status == .cancelled { return }
            value.stopReason = receipt.reason
            if receipt.reason == .userPaused { value.status = .paused; return }
            if receipt.reason == .userCancelled { value.status = .cancelled; return }
            if [.approvalRejected, .inputCancelled, .executionFailed, .checkpointMissing, .noProgress, .scopeChanged].contains(receipt.reason) {
                value.status = .blocked; return
            }
            if [.interrupted, .persistenceFailed].contains(receipt.reason) { value.status = .recoveryRequired; return }
            if value.definition.criteria.allSatisfy({ $0.verdict == .passed }) { value.status = .succeeded; return }
            if receipt.progress?.readyForReview == true { value.status = .awaitingReview; return }
            guard receipt.progress != nil else { value.status = .blocked; value.stopReason = .checkpointMissing; return }
            if value.noProgressCount >= 3 { value.status = .blocked; value.stopReason = .noProgress }
            else { value.status = .running }
        }
    }

    public func stop(_ goal: ExecutionGoal, cancel: Bool = false, reason: GoalStopReason? = nil) async throws -> ExecutionGoal {
        try await store.update(id: goal.id, expectedRevision: goal.revision, event: cancel ? "cancelled" : "paused") { value, _ in
            guard !value.status.isTerminal else { throw GoalError.changed }
            value.status = cancel ? .cancelled : .paused; value.stopReason = reason ?? (cancel ? .userCancelled : .userPaused)
        }
    }
    public func invalidateForUserTurn(_ goal: ExecutionGoal) async throws -> ExecutionGoal {
        try await store.update(id: goal.id, expectedRevision: goal.revision, event: "user_turn") { value, _ in
            guard value.activeRunID == nil, !value.status.isTerminal else { throw GoalError.busy }
            value.status = .paused; value.stopReason = .userPaused
            for index in value.definition.criteria.indices {
                value.definition.criteria[index].verdict = .unknown
                value.definition.criteria[index].evidenceRunID = nil
            }
        }
    }
    public func waiting(goalID: UUID, runID: UUID, forInput: Bool) async throws -> ExecutionGoal {
        let goal = try await store.goal(id: goalID)
        return try await store.update(id: goal.id, expectedRevision: goal.revision, event: "waiting") { value, _ in
            guard value.activeRunID == runID, value.status != .paused, value.status != .cancelled else { throw GoalError.changed }
            value.status = forInput ? .waitingForInput : .waitingForConfirmation
        }
    }
    public func review(_ goal: ExecutionGoal, passedIDs: Set<UUID>) async throws -> ExecutionGoal {
        try await store.update(id: goal.id, expectedRevision: goal.revision, event: "reviewed") { value, _ in
            guard value.activeRunID == nil, value.latestRunID != nil, !value.status.isTerminal,
                  passedIDs.isSubset(of: Set(value.definition.criteria.filter { $0.kind == .manual }.map(\.id))) else { throw GoalError.changed }
            for index in value.definition.criteria.indices where value.definition.criteria[index].kind == .manual {
                value.definition.criteria[index].verdict = passedIDs.contains(value.definition.criteria[index].id) ? .passed : .unknown
                value.definition.criteria[index].evidenceRunID = value.latestRunID
            }
            value.status = value.definition.criteria.allSatisfy { $0.verdict == .passed } ? .succeeded : .awaitingReview
        }
    }
    /// Resuming requires a fresh host scope and user review, never a new allowance.
    public func resume(_ goal: ExecutionGoal, scope: GoalScope) async throws -> ExecutionGoal {
        try await store.update(id: goal.id, expectedRevision: goal.revision, event: "resumed") { value, _ in
            guard value.activeRunID == nil, !value.status.isTerminal else { throw GoalError.busy }
            guard scope.resourceContext.space == value.space,
                  scope.resourceContext.workspaceID == value.workspaceID else { throw GoalError.scopeChanged }
            value.scope = scope; value.deadline = nil
            value.status = .ready; value.stopReason = nil; value.noProgressCount = 0
        }
    }
    public func recover(_ goal: ExecutionGoal) async throws -> ExecutionGoal {
        try await store.update(id: goal.id, expectedRevision: goal.revision, event: "interrupted") { value, db in
            guard value.activeRunID != nil || value.status == .running else { throw GoalError.changed }
            value.spentTokens = GoalUsage.adding(value.spentTokens, value.reservedTokens)
            value.toolCalls = GoalUsage.adding(value.toolCalls, value.reservedToolCalls)
            value.usageIsIncomplete = true; value.deadline = nil
            value.reservedTokens = 0; value.reservedToolCalls = 0
            if let id = value.activeRunID,
               let data = try Data.fetchOne(db, sql: "SELECT payload FROM goal_attempts WHERE id=?", arguments: [id.uuidString]) {
                var attempt = try JSONDecoder().decode(GoalAttempt.self, from: data); attempt.finishedAt = Date()
                try db.execute(sql: "UPDATE goal_attempts SET payload=? WHERE id=?", arguments: [try JSONEncoder().encode(attempt), id.uuidString])
            }
            value.activeRunID = nil; value.status = .recoveryRequired; value.stopReason = .interrupted
        }
    }

    /// Only actual host receipts count as new evidence. Changing model prose or
    /// calling goal_checkpoint repeatedly cannot defeat the no-progress bound.
    public nonisolated static func evidence(from trace: [DispatcherTraceEntry]) -> [String] {
        Array(Set(trace.filter { $0.succeeded && !["goal_checkpoint", "goal_draft", "get_current_time", "tools_search"].contains($0.toolName) }.map {
            SHA256.hash(data: Data([$0.toolName, $0.argumentsFull ?? $0.argumentsPreview, $0.resultFull ?? $0.resultPreview].joined(separator: "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
        })).sorted().prefix(256).map { $0 }
    }
}
