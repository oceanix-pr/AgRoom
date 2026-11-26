import Testing
import Foundation
@testable import AgRoomCore

@Suite("ExecutionBudgetLedger")
struct ExecutionBudgetTests {
    @Test("a checkpoint with a missing limit cannot restore an uncapped run")
    func damagedCheckpoint() {
        let damaged = Data(#"{"maxToolCalls":160,"spentTokens":100,"toolCalls":1}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExecutionBudgetCheckpoint.self, from: damaged) }
    }

    @Test("A team inherits only configured token limits, including across handoff", arguments: [nil, 120_000] as [Int?])
    func teamTokenLimit(_ limit: Int?) async throws {
        var settings = DaemonRunSettings(maxTokens: 8_192, temperature: 0, reasoningEffortRaw: nil,
            maxSteps: 1, replyLanguageInstruction: "", personaInstruction: nil, workspacePath: "", teamTasksEnabled: true)
        if let limit {
            settings.taskBudget = .init(maxTokens: limit, maxToolCalls: 20, spentTokens: 0, toolCalls: 0)
        }
        let ledger = EngineAssembly.executionBudget(settings: settings, contextTokenBudget: 40_000, teamToolAvailable: true)
        let previous = try await ledger.reserve(inputEstimate: 30_000, outputCap: 8_192, purpose: .worker)
        await ledger.settle(previous, inputTokens: 83_616, outputTokens: 1_641)
        settings.taskBudget = ledger.checkpoint
        let restored = try JSONDecoder().decode(DaemonRunSettings.self, from: JSONEncoder().encode(settings))
        let parent = EngineAssembly.executionBudget(settings: restored, contextTokenBudget: 40_000, teamToolAvailable: true)
        let team = ExecutionBudgetLedger(maxTokens: TeamBudget.default.maxTokens, maxToolCalls: 160, parent: parent)
        #expect(team.maxTokens == limit)
        #expect(await parent.spent == 85_257)
        if limit == nil {
            let narrowed = EngineAssembly.executionBudget(settings: restored, contextTokenBudget: 40_000, teamToolAvailable: false)
            #expect(narrowed.maxTokens == nil)
            let next = try await team.reserve(inputEstimate: 34_751, outputCap: 8_192, purpose: .worker)
            #expect(parent.checkpoint.spentTokens == 128_200)
            await team.settle(next, inputTokens: 34_751, outputTokens: 1_000)
            #expect(await parent.spent == 121_008)
        } else {
            await #expect(throws: BudgetError.tokensExhausted) {
                try await team.reserve(inputEstimate: 34_751, outputCap: 8_192, purpose: .worker)
            }
            #expect(await parent.spent == 85_257)
        }
        #expect(await team.reserved == 0)
        #expect(await parent.reserved == 0)
    }

    @Test("Child execution contexts retain the root identity and earliest context or ledger deadline")
    func inheritedContextDeadline() {
        let earliest = Date().addingTimeInterval(20)
        let ledger = ExecutionBudgetLedger(maxTokens: 1000, maxToolCalls: 2, deadline: earliest)
        let root = ExecutionContext(space: .work, permissionPolicy: nil, budgetLedger: ledger,
            deadline: earliest.addingTimeInterval(50))
        let policy = PermissionPolicy(mode: .readOnly, fileAreaPolicy: nil)
        let child = root.child(subtaskID: UUID(), permissionPolicy: policy, deadline: earliest.addingTimeInterval(100))
        #expect(root.deadline == earliest && child.deadline == earliest)
        #expect(child.rootRunID == root.runID && child.parentRunID == root.runID)
        let narrower = root.child(subtaskID: UUID(), permissionPolicy: policy, deadline: earliest.addingTimeInterval(-10))
        #expect(narrower.deadline == earliest.addingTimeInterval(-10))
    }
    @Test("Sibling teams reserve against one parent and release reservations exactly once")
    func hierarchicalReservations() async throws {
        let parent = ExecutionBudgetLedger(maxTokens: 1_000, maxToolCalls: 4)
        let children = (0..<2).map { _ in ExecutionBudgetLedger(maxTokens: 2_000, maxToolCalls: 10, parent: parent) }
        let held = await withTaskGroup(of: (Int, BudgetReservation?).self) { group in
            for index in children.indices {
                group.addTask {
                    (index, try? await children[index].reserve(inputEstimate: 100, outputCap: 500, purpose: .worker))
                }
            }
            var results: [(Int, BudgetReservation?)] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(held.filter { $0.1 != nil }.count == 1)
        #expect(await parent.reserved == 600)
        #expect(parent.checkpoint.spentTokens == 600)
        for (index, reservation) in held {
            if let reservation {
                await children[index].settle(reservation, inputTokens: 100, outputTokens: 20)
                await children[index].settle(reservation, inputTokens: 900, outputTokens: 900)
                await children[index].cancel(reservation)
            }
            #expect(await children[index].reserved == 0)
        }
        #expect(await parent.reserved == 0)
        #expect(await parent.spent == 120)
    }

    @Test("Nested budgets preserve deadlines, tool caps, unknown usage and parent verification reserve")
    func hierarchicalLimits() async throws {
        let deadline = Date().addingTimeInterval(60)
        let parent = ExecutionBudgetLedger(maxTokens: 1_000, maxToolCalls: 1, deadline: deadline, verificationReserve: 300)
        let child = ExecutionBudgetLedger(maxTokens: 2_000, maxToolCalls: 8,
            deadline: deadline.addingTimeInterval(60), parent: parent)
        #expect(child.deadline == deadline)
        #expect(child.maxTokens == 1_000 && child.maxToolCalls == 1)
        await #expect(throws: BudgetError.tokensExhausted) {
            _ = try await child.reserve(inputEstimate: 100, outputCap: 700, purpose: .verifier)
        }
        #expect(await child.reserved == 0)
        let grandchild = ExecutionBudgetLedger(maxTokens: 1_000, maxToolCalls: 1, parent: child)
        let unknown = try await grandchild.reserve(inputEstimate: 100, outputCap: 400, purpose: .verifier)
        await grandchild.settle(unknown, inputTokens: nil, outputTokens: 20)
        #expect(await parent.spent == 500)
        #expect(await child.unknownUsageCount == 1)
        #expect(await parent.unknownUsageCount == 1)
        try await grandchild.recordToolCall()
        await #expect(throws: BudgetError.toolCallsExhausted) { try await child.recordToolCall() }
        #expect(await parent.toolCallCount == 1)
        #expect(await child.toolCallCount == 1)
        let remaining = try await child.reserve(inputEstimate: 50, outputCap: 50, purpose: .worker)
        await child.cancel(remaining)
        #expect(await parent.reserved == 0)
    }

    @Test("A cancelled child never leaves a parent reservation")
    func cancelledChild() async throws {
        let parent = ExecutionBudgetLedger(maxTokens: 1_000, maxToolCalls: 1)
        let child = ExecutionBudgetLedger(maxTokens: 1_000, maxToolCalls: 1, parent: parent)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await child.reserve(inputEstimate: 100, outputCap: 400, purpose: .worker)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await parent.reserved == 0)
        #expect(await child.reserved == 0)
    }

    @Test("An automatic reply fits its parent budget and preserves the verifier's share")
    func flexibleOutputFitsParent() async throws {
        let parent = ExecutionBudgetLedger(maxTokens: 4_000, maxToolCalls: 2, verificationReserve: 500)
        let child = ExecutionBudgetLedger(maxTokens: 4_000, maxToolCalls: 2, parent: parent)
        let existing = try await parent.reserve(inputEstimate: 100, outputCap: 400, purpose: .main)
        let reservation = try await child.reserve(inputEstimate: 600, outputCap: 16_000,
            purpose: .worker, allowSmallerOutput: true)
        #expect(reservation.tokens == 3_000)
        #expect(await child.reserved == 3_000 && parent.checkpoint.spentTokens == 3_500)
        await #expect(throws: BudgetError.tokensExhausted) {
            try await child.reserve(inputEstimate: 100, outputCap: 200, purpose: .worker, allowSmallerOutput: true)
        }
        await child.settle(reservation, inputTokens: nil, outputTokens: nil)
        await parent.cancel(existing)
        #expect(await child.spent == 3_000 && parent.checkpoint.spentTokens == 3_000)
        #expect(await child.reserved == 0)
    }

    @Test("concurrent reservations cannot spend the same tokens twice")
    func reservationIsExclusive() async throws {
        let ledger = ExecutionBudgetLedger(maxTokens: 1_000, maxToolCalls: 10)
        let first = try await ledger.reserve(inputEstimate: 100, outputCap: 300, purpose: .worker)
        do {
            _ = try await ledger.reserve(inputEstimate: 100, outputCap: 700, purpose: .worker)
            Issue.record("second reservation should not fit")
        } catch BudgetError.tokensExhausted {
            // expected
        }
        await ledger.settle(first, inputTokens: 100, outputTokens: 200)
        #expect(await ledger.spent == 300)
        #expect(await ledger.reserved == 0)
        let second = try await ledger.reserve(inputEstimate: 100, outputCap: 300, purpose: .worker)
        await ledger.cancel(second)
        #expect(await ledger.spent == 300)
    }

    @Test("missing provider usage is settled conservatively, never as zero")
    func unknownUsageIsConservative() async throws {
        let ledger = ExecutionBudgetLedger(maxTokens: 2_000, maxToolCalls: 10)
        let reservation = try await ledger.reserve(
            inputEstimate: 100, outputCap: 400, purpose: .main
        )
        await ledger.settle(reservation, inputTokens: nil, outputTokens: nil)
        #expect(await ledger.spent == 500)
        #expect(await ledger.unknownUsageCount == 1)
    }

    @Test("verification reserve is unavailable to workers but available to the verifier")
    func verificationReserve() async throws {
        let ledger = ExecutionBudgetLedger(
            maxTokens: 1_000, maxToolCalls: 10, verificationReserve: 300
        )
        let worker = try await ledger.reserve(
            inputEstimate: 100, outputCap: 500, purpose: .worker
        )
        do {
            _ = try await ledger.reserve(
                inputEstimate: 100, outputCap: 200, purpose: .worker
            )
            Issue.record("worker must not consume the verification reserve")
        } catch BudgetError.tokensExhausted {
            // expected
        }
        await ledger.releaseVerificationReserve()
        let verifier = try await ledger.reserve(
            inputEstimate: 100, outputCap: 200, purpose: .verifier
        )
        await ledger.cancel(verifier)
        await ledger.cancel(worker)
        #expect(await ledger.spent == 0)
    }

    @Test("tool calls and deadlines are checked before execution")
    func toolAndDeadline() async throws {
        let ledger = ExecutionBudgetLedger(
            maxTokens: 1_000,
            maxToolCalls: 1,
            deadline: Date().addingTimeInterval(-1)
        )
        do {
            try await ledger.recordToolCall()
            Issue.record("expired deadline should block the call")
        } catch BudgetError.deadlineExceeded {
            // expected
        }
        let live = ExecutionBudgetLedger(maxTokens: 1_000, maxToolCalls: 1)
        try await live.recordToolCall()
        do {
            try await live.recordToolCall()
            Issue.record("tool budget should be exhausted")
        } catch BudgetError.toolCallsExhausted {
            // expected
        }
    }
}
