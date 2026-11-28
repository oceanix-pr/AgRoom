import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Execution goals", .serialized)
struct GoalTests {
    private func queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue); return queue
    }
    private func definition(checks: Bool = false) -> GoalDefinition {
        .init(title: "Evidence report", objective: "Create a report from the selected sources",
            criteria: [.init(text: "Covers the requested sources")] + (checks ? [.init(kind: .executionCheck, text: "execution_check")] : []))
    }
    private func goal(_ queue: DatabaseQueue, space: AppSpace = .work, id: UUID = UUID(), sessionID: UUID = UUID(), checks: Bool = false) async throws -> ExecutionGoal {
        try await SessionService(databaseQueue: queue).save(ChatSession(id: sessionID, title: "Disposable goal conversation"))
        let workspace = UUID()
        let identity = try TaskDirectoryIdentity.capture(FileManager.default.temporaryDirectory)
        return ExecutionGoal(id: id, space: space, sessionID: sessionID, workspaceID: workspace,
            definition: definition(checks: checks), scope: .init(resourceContext: .init(space: space, workspaceID: workspace),
                permissionMode: .workspaceWrite, autoReviewEnabled: false, directories: [identity]))
    }
    private func receipt(_ snapshot: GoalExecutionSnapshot, spent: Int, evidence: String = "a", ready: Bool = false,
                         reason: GoalStopReason = .modelFinished, completion: TaskCompletionAssessment = .unassessed) -> GoalRunReceipt {
        .init(runID: snapshot.runID,
            usage: .init(tokens: spent - snapshot.goal.spentTokens, toolCalls: 1), reason: reason,
            completion: completion, progress: .init(summary: "Actual execution notes", nextActions: ready ? [] : ["Inspect the next source"], readyForReview: ready),
            evidenceDigests: [evidence.count == 64 ? evidence : String(repeating: evidence, count: 64)])
    }

    @Test("A plain-language goal keeps its full objective and requires human acceptance")
    @MainActor func simpleSetupDefinition() {
        let objective = String(repeating: "需要保留的完整目标。", count: 100) + "\n验证结果并生成报告。"
        let value = GoalSetupInput.makeDefinition(title: " ", objective: "  " + objective + "\n", criteria: "\n ",
            constraints: "", requireChecks: false)
        #expect(value.isValid && value.objective == objective)
        #expect(value.title == String(objective.prefix(60)))
        #expect(value.criteria.count == 1 && value.criteria[0].kind == .manual)
        #expect(value.criteria[0].verdict == .unknown && value.criteria[0].evidenceRunID == nil)
        #expect(L.format("goal.usage", 4_000_000_000, 2_000, 55).contains("4000000000"))
        let empty = GoalSetupInput.makeDefinition(title: "", objective: " \n", criteria: "", constraints: "",
            requireChecks: false)
        #expect(!empty.isValid)
    }

    @Test("Advanced goal setup preserves custom criteria and constraints")
    @MainActor func advancedSetupDefinition() {
        let value = GoalSetupInput.makeDefinition(title: "Report", objective: "Produce report", criteria: " Source coverage \n\n Evidence links ",
            constraints: "Read only", requireChecks: true)
        #expect(value.isValid && value.title == "Report" && value.constraints == "Read only")
        #expect(value.criteria.filter { $0.kind == .manual }.map(\.text) == ["Source coverage", "Evidence links"])
        #expect(value.criteria.last?.kind == .executionCheck)
        let invalid = GoalSetupInput.makeDefinition(title: "", objective: String(repeating: "a", count: 8_001),
            criteria: "", constraints: "", requireChecks: true)
        #expect(!invalid.isValid && invalid.objective.count == 8_001)
    }

    @Test("Space isolation, single active execution and transaction failures")
    func isolationAndClaim() async throws {
        let work = try queue(), personal = try queue(), id = UUID(), session = UUID()
        let store = GoalStore(databaseQueue: work, space: .work), other = GoalStore(databaseQueue: personal, space: .personal)
        let created = try await store.create(goal(work, id: id, sessionID: session))
        #expect(try await other.latest(sessionID: session) == nil)
        _ = try await other.create(goal(personal, space: .personal, id: id, sessionID: session))
        let coordinator = GoalCoordinator(store: store)
        let outcomes = await withTaskGroup(of: Bool.self) { tasks in
            for _ in 0..<2 {
                tasks.addTask { do { _ = try await coordinator.prepare(created, runID: UUID()); return true } catch { return false } }
            }
            var result: [Bool] = []; for await value in tasks { result.append(value) }; return result
        }
        #expect(outcomes.filter { $0 }.count == 1)
        #expect(try await store.attempts(goalID: id).count == 1)
        #expect(try await other.goal(id: id).attemptCount == 0)
        let fresh = try await store.create(goal(work))
        try await work.write { db in try db.execute(sql: "CREATE TRIGGER refuse_goal_update BEFORE UPDATE ON execution_goals BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        await #expect(throws: (any Error).self) { _ = try await coordinator.prepare(fresh, runID: UUID()) }
        #expect(try await store.goal(id: fresh.id) == fresh)
        #expect(try await store.attempts(goalID: fresh.id).isEmpty)
    }

    @Test("Model completion claims cannot pass manual or unknown execution criteria")
    func acceptance() async throws {
        let queue = try queue(), store = GoalStore(databaseQueue: queue, space: .work), coordinator = GoalCoordinator(store: store)
        let original = try await store.create(goal(queue, checks: true))
        let snapshot = try await coordinator.prepare(original, runID: UUID())
        let candidate = receipt(snapshot, spent: 120, ready: true)
        let waiting = try await coordinator.finish(goalID: original.id, receipt: candidate)
        #expect(waiting.status == .awaitingReview && waiting.passedCount == 0)
        let manual = Set(waiting.definition.criteria.filter { $0.kind == .manual }.map(\.id))
        let reviewed = try await coordinator.review(waiting, passedIDs: manual)
        #expect(reviewed.status == .awaitingReview && reviewed.passedCount == 1)
        await #expect(throws: GoalError.changed) { _ = try await coordinator.review(waiting, passedIDs: manual) }
        await #expect(throws: GoalError.changed) { _ = try await coordinator.review(reviewed, passedIDs: [UUID()]) }
        let resumed = try await coordinator.resume(reviewed, scope: try #require(reviewed.scope))
        let next = try await coordinator.prepare(resumed, runID: UUID())
        let checked = try await coordinator.finish(goalID: original.id, receipt: receipt(next, spent: 240, ready: true, completion: .completed))
        #expect(checked.passedCount == 1) // prior manual votes were invalidated by new work
        let accepted = try await coordinator.review(checked, passedIDs: manual)
        #expect(accepted.status == .succeeded && accepted.passedCount == 2)
        #expect(accepted.definition.criteria.allSatisfy { $0.evidenceRunID == next.runID })
    }

    @Test("Cumulative spend, bounded no-progress continuation and idempotent receipt retries")
    func continuation() async throws {
        let queue = try queue(), store = GoalStore(databaseQueue: queue, space: .work), coordinator = GoalCoordinator(store: store)
        var current = try await store.create(goal(queue))
        for index in 1...4 {
            let snapshot = try await coordinator.prepare(current, runID: UUID())
            #expect(snapshot.goal.spentTokens == (index - 1) * 100)
            let result = receipt(snapshot, spent: index * 100)
            current = try await coordinator.finish(goalID: current.id, receipt: result)
            #expect(try await coordinator.finish(goalID: current.id, receipt: result) == current)
            #expect(current.spentTokens == index * 100)
        }
        #expect(current.status == .blocked && current.stopReason == .noProgress && current.attemptCount == 4)
        #expect(try await store.attempts(goalID: current.id).count == 4)
        await #expect(throws: GoalError.busy) { _ = try await coordinator.prepare(current, runID: UUID()) }
        let resumed = try await coordinator.resume(current, scope: try #require(current.scope))
        #expect(resumed.spentTokens == 400 && resumed.attemptCount == 4)
    }

    @Test("Interruptions mark usage incomplete and stale writes cannot revive a stopped goal")
    func interruption() async throws {
        let queue = try queue(), store = GoalStore(databaseQueue: queue, space: .work), coordinator = GoalCoordinator(store: store)
        let original = try await store.create(goal(queue))
        let snapshot = try await coordinator.prepare(original, runID: UUID())
        let recovered = try await coordinator.recover(snapshot.goal)
        #expect(recovered.status == .recoveryRequired && recovered.spentTokens == 0 && recovered.usageIsIncomplete == true)
        #expect(recovered.activeRunID == nil && recovered.reservedTokens == 0)
        await #expect(throws: GoalError.changed) { _ = try await coordinator.finish(goalID: original.id, receipt: receipt(snapshot, spent: 1)) }
        let resumed = try await coordinator.resume(recovered, scope: try #require(recovered.scope))
        #expect(resumed.status == .ready && resumed.spentTokens == 0)
        let fresh = try await store.create(goal(queue))
        let running = try await coordinator.prepare(fresh, runID: UUID())
        let stopped = try await coordinator.stop(running.goal, cancel: true)
        #expect(stopped.status == .cancelled)
        let late = try await coordinator.finish(goalID: fresh.id, receipt: receipt(running, spent: 80, ready: true, completion: .completed))
        #expect(late.status == .cancelled && late.spentTokens == 80 && late.activeRunID == nil)
    }

    @Test("Goals continue past old usage, duration and segment limits with paged history and exact retries")
    func unlimitedContinuation() async throws {
        let queue = try queue(), store = GoalStore(databaseQueue: queue, space: .work), coordinator = GoalCoordinator(store: store)
        let original = try await store.create(goal(queue))
        var current = try await store.update(id: original.id, expectedRevision: original.revision, event: "fixture_usage") { value, _ in
            value.spentTokens = 150_000_000; value.toolCalls = 2_000_000
            value.deadline = Date().addingTimeInterval(-1)
        }
        var firstReceipt: GoalRunReceipt?, lastReceipt: GoalRunReceipt?
        for index in 1...55 {
            let snapshot = try await coordinator.prepare(current, runID: UUID(), now: Date().addingTimeInterval(Double(index) * 86_400))
            #expect(snapshot.goal.deadline == nil && snapshot.goal.reservedTokens == 0)
            let result = GoalRunReceipt(runID: snapshot.runID, usage: .init(tokens: 6_000_000, toolCalls: 2_000),
                reason: [.tokenBudget, .toolBudget, .stepLimit][index % 3],
                progress: .init(summary: "Verified source \(index)", nextActions: ["Inspect the next source"]),
                evidenceDigests: [String(format: "%064x", index)])
            current = try await coordinator.finish(goalID: current.id, receipt: result)
            #expect(current.status == .running && current.attemptCount == index)
            if firstReceipt == nil { firstReceipt = result }
            lastReceipt = result
        }
        #expect(current.spentTokens == 480_000_000 && current.toolCalls == 2_110_000)
        #expect(try await coordinator.finish(goalID: current.id, receipt: #require(lastReceipt)) == current)
        #expect(try await coordinator.finish(goalID: current.id, receipt: #require(firstReceipt)) == current)
        let recent = try await store.attempts(goalID: current.id)
        #expect(recent.count == 50 && recent.first?.sequence == 6 && recent.last?.sequence == 55)
        let older = try await store.attempts(goalID: current.id, beforeSequence: recent.first?.sequence)
        #expect(older.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(try await store.attempt(goalID: current.id, runID: #require(lastReceipt).runID)?.sequence == 55)
    }

    @Test("Goal segments and their children execute past the ordinary one-hour deadline")
    @MainActor func segmentHasNoTimeLimit() async throws {
        let queue = try queue(), value = try await goal(queue)
        let startedAt = Date().addingTimeInterval(-7_200)
        let ordinaryDeadline = try #require(EngineAssembly.executionDeadline(budgetDeadline: nil, goalScope: nil, now: startedAt))
        #expect(ordinaryDeadline == startedAt.addingTimeInterval(3_600))
        let policy = PermissionPolicy(mode: .readOnly, fileAreaPolicy: nil)
        let ordinary = ExecutionContext(space: .work, permissionPolicy: policy, deadline: ordinaryDeadline)
        #expect(throws: BudgetError.deadlineExceeded) { try ordinary.checkDeadline() }
        let explicitDeadline = Date().addingTimeInterval(30)
        #expect(EngineAssembly.executionDeadline(budgetDeadline: explicitDeadline, goalScope: nil, now: startedAt) == explicitDeadline)

        let ledger = ExecutionBudgetLedger(maxTokens: 50_000, maxToolCalls: 100)
        let context = ExecutionContext(space: .work, permissionPolicy: policy, budgetLedger: ledger,
            deadline: EngineAssembly.executionDeadline(budgetDeadline: ledger.deadline, goalScope: try #require(value.scope), now: startedAt))
        let child = context.child(subtaskID: UUID(), permissionPolicy: policy)
        #expect(context.deadline == nil && child.deadline == nil)
        try context.checkDeadline(); try child.checkDeadline()
        let progress = GoalProgressState()
        let engine = DispatcherEngine(provider: GoalFixtureProvider.make(segment: 2),
            tools: [GoalCheckpointTool(state: progress), GoalProbeTool(value: "Source inspected after an extended execution")],
            systemPrompt: "Disposable long-running goal fixture", config: .init(maxTokens: 256, temperature: 0),
            maxSteps: 4, executionContext: child)
        guard case .finished(_, _, let trace, _, _, _, _) = try await engine.run(userMessage: value.definition.objective, history: []) else {
            Issue.record("An elapsed hour must not stop a goal segment"); return
        }
        #expect(trace.contains { $0.toolName == "goal_probe" && $0.succeeded })
        #expect(await progress.snapshot()?.readyForReview == true)
    }

    @Test("Legacy goal limits are ignored while cumulative receipts and unknown usage remain compatible")
    func legacyUsageCompatibility() async throws {
        let queue = try queue(), store = GoalStore(databaseQueue: queue, space: .work), coordinator = GoalCoordinator(store: store)
        let original = try await goal(queue)
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var oldDefinition = try #require(raw["definition"] as? [String: Any])
        oldDefinition["budget"] = ["maxTokens": 1_000, "maxToolCalls": 1, "maxAttempts": 1, "minutes": 1]
        raw["definition"] = oldDefinition; raw["deadline"] = -1_000_000.0
        let legacy = try GoalStore.decode(JSONSerialization.data(withJSONObject: raw), space: .work)
        var current = try await store.create(legacy)
        let first = try await coordinator.prepare(current, runID: UUID())
        current = try await coordinator.finish(goalID: current.id, receipt: receipt(first, spent: 1_000))
        let second = try await coordinator.prepare(current, runID: UUID())
        var oldReceipt = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt(second, spent: 1_500, evidence: "b"))) as? [String: Any])
        oldReceipt.removeValue(forKey: "usage")
        oldReceipt["budget"] = ["maxTokens": 1_000, "maxToolCalls": 1, "spentTokens": 1_500, "toolCalls": 3]
        let decoded = try JSONDecoder().decode(GoalRunReceipt.self, from: JSONSerialization.data(withJSONObject: oldReceipt))
        #expect(decoded.isValid && decoded.hasCumulativeUsage)
        current = try await coordinator.finish(goalID: current.id, receipt: decoded)
        #expect(current.status == .running && current.spentTokens == 1_500 && current.toolCalls == 3)
        #expect(try await coordinator.finish(goalID: current.id, receipt: decoded) == current)
        let third = try await coordinator.prepare(current, runID: UUID())
        let reserved = try await store.update(id: current.id, expectedRevision: third.goal.revision, event: "legacy_reservation") { value, _ in
            value.reservedTokens = 500; value.reservedToolCalls = 2
        }
        let recovered = try await coordinator.recover(reserved)
        #expect(recovered.spentTokens == 2_000 && recovered.toolCalls == 5 && recovered.usageIsIncomplete == true)
        let resumed = try await coordinator.resume(recovered, scope: #require(recovered.scope))
        #expect(try await coordinator.prepare(resumed, runID: UUID()).goal.attemptCount == 4)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy.definition)) as? [String: Any])
        #expect(encoded["budget"] == nil)
    }

    @Test("Portable backup strips execution authority, pauses goals, remaps workspaces and rolls back")
    func backup() async throws {
        let source = try queue(), target = try queue(), store = GoalStore(databaseQueue: source, space: .work)
        let original = try await store.create(goal(source)), coordinator = GoalCoordinator(store: store)
        var current = original
        for index in 1...21 {
            let segment = try await coordinator.prepare(current, runID: UUID())
            current = try await coordinator.finish(goalID: original.id, receipt: receipt(segment, spent: index * 100, evidence: String(format: "%064x", index)))
        }
        let snapshot = try await coordinator.prepare(current, runID: UUID())
        let archive = try await SpaceDatabaseBackupStore(queue: source, space: "work").export()
        let table = try #require(archive.tables.first { $0.name == "execution_goals" })
        let payloadIndex = try #require(table.columns.firstIndex(of: "payload"))
        guard case .blob(let data) = table.rows[0][payloadIndex] else { throw GoalError.invalid }
        #expect(try GoalStore.decode(data, space: .work).scope == nil)
        try await SessionService(databaseQueue: target).save(ChatSession(id: original.sessionID, title: "Restored conversation"))
        let rebound = UUID(), destination = SpaceDatabaseBackupStore(queue: target, space: "personal")
        let plan = try await destination.plan(archive, sourceSpace: "work", workspaceMappings: [original.workspaceID.uuidString:rebound.uuidString])
        let applied = try await destination.apply(plan) { _ in }
        try await destination.verify(applied)
        let restoredStore = GoalStore(databaseQueue: target, space: .personal)
        let restored = try await restoredStore.goal(id: original.id)
        #expect(restored.space == .personal && restored.workspaceID == rebound && restored.scope == nil)
        #expect(restored.status == .paused && restored.activeRunID == nil && restored.spentTokens == snapshot.goal.spentTokens && restored.usageIsIncomplete == true)
        #expect(try await restoredStore.attempts(goalID: original.id).count == 22)
        try await destination.rollback(applied)
        #expect(try await restoredStore.latest(sessionID: original.sessionID) == nil)
        #expect(try await store.goal(id: original.id).activeRunID == snapshot.runID)
    }

    @Test("Draft and checkpoint tools are bounded inert data and cannot change goal authority")
    func tools() async throws {
        let session = UUID(), workspace = UUID(), state = GoalProgressState()
        let tool = GoalDraftTool(space: .work, sessionID: session, workspaceID: workspace)
        let text = try await tool.execute(argumentsJSON: #"{"title":"Goal","objective":"Produce a report","criteria":["Cite actual sources"]}"#)
        let draft = try GoalDraftReceipt.read(text, space: .work, sessionID: session, workspaceID: workspace)
        #expect(draft.definition.criteria.allSatisfy { $0.verdict == .unknown && $0.kind == .manual })
        #expect(throws: GoalError.invalid) { _ = try GoalDraftReceipt.read(text, space: .personal, sessionID: session, workspaceID: workspace) }
        await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: #"{"title":"x","objective":"x","criteria":["x"],"max_tokens":true}"#) }
        let checkpoint = GoalCheckpointTool(state: state)
        await #expect(throws: (any Error).self) { _ = try await checkpoint.execute(argumentsJSON: #"{"summary":"done","ready_for_review":true,"max_tokens":999999}"#) }
        _ = try await checkpoint.execute(argumentsJSON: #"{"summary":"Candidate report ready","ready_for_review":true}"#)
        #expect(await state.snapshot()?.readyForReview == true)
        #expect(GoalCoordinator.evidence(from: [.init(toolName: "goal_checkpoint", argumentsPreview: "x", resultPreview: "claimed new progress", duration: 0, succeeded: true)]).isEmpty)
    }

    @Test("Late progress cannot replace a final answer or write through a restored conversation")
    func progressCommitGate() async throws {
        let queue = try queue(), service = SessionService(databaseQueue: queue), runID = UUID()
        var session = ChatSession(title: "Progress gate fixture")
        let running = ChatMessage(role: .assistant, content: "Partial", runStatus: .running, taskRun: .init(id: runID))
        session.messages = [.init(role: .user, content: "Fixture request"), running]
        try await service.save(session)
        var finished = running; finished.content = "Final answer"; finished.runStatus = .succeeded
        session.messages[1] = finished
        try await service.save(session)
        let oldVersion = SessionRestoreVersion(id: session.id, token: nil)
        try await service.updateMessage(sessionId: session.id, messageId: running.id,
            expectedTaskRunID: runID, isProgressUpdate: true, expectedRestorationVersion: oldVersion,
            messageSequence: 1) { $0 = running }
        #expect(try await service.fetch(id: session.id)?.messages.last?.runStatus == .succeeded)
        #expect(try await service.fetch(id: session.id)?.messages.last?.content == "Final answer")
        try await service.invalidateRestoredSnapshots(ids: [session.id])
        await #expect(throws: SessionServiceError.staleAfterRestore) {
            try await service.updateMessage(sessionId: session.id, messageId: running.id,
                expectedTaskRunID: runID, isProgressUpdate: true, expectedRestorationVersion: oldVersion,
                messageSequence: 1) { $0 = running }
        }
        #expect(try await service.fetch(id: session.id)?.messages.last?.content == "Final answer")
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw GoalError.unavailable
    }
    @MainActor private final class HostProbe { var requests: [ChatEngineRequest] = [] }

    @MainActor private func hostEngine(_ request: ChatEngineRequest, segment: Int, mutation: GoalMutationCounter? = nil) throws -> DispatcherEngine {
        #expect(request.settings.taskBudget == nil)
        let state = try #require(request.goalProgress)
        let ledger = ExecutionBudgetLedger(maxTokens: 50_000, maxToolCalls: 100)
        let context = ExecutionContext(space: request.space, sessionID: request.sessionID, runID: request.runID,
            permissionPolicy: .init(mode: .workspaceWrite, fileAreaPolicy: nil), budgetLedger: ledger)
        var tools: [any DispatcherTool] = [GoalCheckpointTool(state: state)]
        if let mutation { tools.append(GoalMutationTool(counter: mutation)) }
        else { tools.append(GoalProbeTool(value: "Verified source \(segment)")) }
        return DispatcherEngine(provider: GoalFixtureProvider.make(segment: segment, approval: mutation != nil),
            tools: tools, systemPrompt: "Disposable goal fixture", config: .init(maxTokens: 256, temperature: 0),
            maxSteps: 4, executionContext: context)
    }

    @Test("An objective-only setup starts real chat segments, preserves drafts and requires human acceptance")
    @MainActor func chatFlow() async throws {
        let queue = try queue(), root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), skillDirectoryRoot: root.appendingPathComponent("skills"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root.appendingPathComponent("files")))
        let probe = HostProbe()
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil, makeEngine: { request in
            probe.requests.append(request)
            return try hostEngine(request, segment: probe.requests.count)
        })
        await model.load(); model.newSession()
        let session = try #require(model.activeSessionId)
        model.inputText = "Unsent draft must survive"
        let simpleGoal = GoalSetupInput.makeDefinition(title: "", objective: "Create a report from the selected sources",
            criteria: "", constraints: "", requireChecks: false)
        #expect(await model.startGoal(simpleGoal, expectedSessionID: session))
        try await wait { model.activeGoal?.status == .awaitingReview && !model.isAnyRunning }
        #expect(probe.requests.count == 2)
        #expect(probe.requests.allSatisfy { $0.settings.taskBudget == nil })
        #expect(model.inputText == "Unsent draft must survive")
        let goal = try #require(model.activeGoal)
        #expect(goal.attemptCount == 2 && goal.passedCount == 0)
        #expect(goal.definition == simpleGoal)
        #expect(probe.requests.allSatisfy { $0.sessionID == session && $0.space == .work && $0.goalProgress != nil })
        #expect(probe.requests.allSatisfy { $0.taskRequest.contains(simpleGoal.objective) && $0.taskRequest.contains(simpleGoal.criteria[0].text) })
        #expect(model.session(id: session)?.messages.filter { $0.role == .user }.count == 1)
        #expect(model.session(id: session)?.messages.first(where: { $0.role == .user })?.content == simpleGoal.objective)
        let runs = try await hub.makeGoalStore(for: .work)!.attempts(goalID: goal.id)
        #expect(runs.count == 2 && runs[0].id != runs[1].id && runs.allSatisfy { $0.receipt != nil })
        for run in runs { #expect(try await hub.makeTaskRunStore(for: .work)!.run(id: run.id) != nil) }
        #expect(await model.openGoalResult(goal))
        let resultMessage = model.session(id: session)?.messages.last { $0.taskRun?.id == goal.latestRunID }
        #expect(model.sourceMessageFocus?.messageID == resultMessage?.id)
        #expect(model.inputText == "Unsent draft must survive" && probe.requests.count == 2)
        await model.reviewGoal(goal, passedIDs: Set(goal.definition.criteria.map(\.id)))
        #expect(model.activeGoal?.status == .succeeded && probe.requests.count == 2)
    }

    @Test("The selected goal mode submits once from the composer and preserves later edits", arguments: [false, true])
    @MainActor func composerGoalFlow(editAfterSend: Bool) async throws {
        let queue = try queue(), root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-composer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), skillDirectoryRoot: root.appendingPathComponent("skills"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root.appendingPathComponent("files")))
        let probe = HostProbe()
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil, makeEngine: { request in
            probe.requests.append(request); return try hostEngine(request, segment: probe.requests.count)
        })
        await model.load()
        #expect(model.activeSessionId == nil)
        model.inputText = "我需要一个技能开发计划，核对资料后输出报告。"
        let objective = model.inputText
        model.setGoalComposerEnabled(true)
        #expect(model.canSubmitComposerGoal)
        model.send(); model.send()
        #expect(model.isSendingGoalFromComposer)
        if editAfterSend { model.inputText = "A later draft"; model.saveDraftForActive() }
        try await wait { model.activeGoal?.status == .awaitingReview && !model.isAnyRunning && !model.isSendingGoalFromComposer }
        let goal = try #require(model.activeGoal)
        #expect(goal.definition.objective == objective && goal.attemptCount == 2 && goal.passedCount == 0)
        #expect(model.activeSkillGenerationOffer == nil && !model.isComposingGoal)
        #expect(model.inputText == (editAfterSend ? "A later draft" : ""))
        #expect(model.drafts[goal.sessionID] == (editAfterSend ? "A later draft" : nil))
        #expect(model.session(id: goal.sessionID)?.messages.filter { $0.role == .user }.count == 1)
        #expect(probe.requests.count == 2)
        #expect(!model.canComposeGoal)
        await model.reviewGoal(goal, passedIDs: Set(goal.definition.criteria.map(\.id)))
        #expect(model.activeGoal?.status == .succeeded && model.canComposeGoal)
    }

    @Test("Goal mode rejects invalid text and attachments without falling back to ordinary send")
    @MainActor func composerValidation() async throws {
        let queue = try queue(), root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-composer-validation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), skillDirectoryRoot: root.appendingPathComponent("skills"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root.appendingPathComponent("files")))
        let probe = HostProbe()
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil, makeEngine: { request in
            probe.requests.append(request); return try hostEngine(request, segment: probe.requests.count)
        })
        await model.load(); model.newSession()
        model.setGoalComposerEnabled(true)
        model.inputText = String(repeating: "a", count: 8_001)
        model.send()
        #expect(!model.canSubmitComposerGoal && model.inputText.count == 8_001 && model.isComposingGoal)
        let source = root.appendingPathComponent("source.txt")
        model.inputText = "Summarize the sources"; model.addAttachments([source])
        model.send()
        #expect(!model.canSubmitComposerGoal && model.pendingAttachments == [source])
        #expect(model.inputText == "Summarize the sources" && model.errorMessage == L.string("goal.composer.attachments"))
        #expect(probe.requests.isEmpty && model.activeGoal == nil)
        model.setGoalComposerEnabled(false)
        #expect(!model.isComposingGoal && model.pendingAttachments == [source])
    }

    @Test("Switching conversations invalidates an unsent goal selection and a queued submission")
    @MainActor func composerSessionSwitch() async throws {
        let queue = try queue(), root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-composer-switch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), skillDirectoryRoot: root.appendingPathComponent("skills"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root.appendingPathComponent("files")))
        let probe = HostProbe()
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil, makeEngine: { request in
            probe.requests.append(request); return try hostEngine(request, segment: probe.requests.count)
        })
        await model.load(); model.newSession()
        let origin = try #require(model.activeSessionId)
        model.inputText = "Original goal"; model.setGoalComposerEnabled(true); model.send()
        model.newSession()
        #expect(!model.isComposingGoal)
        let other = try #require(model.activeSessionId)
        model.inputText = "Other conversation draft"
        model.activeSessionId = origin
        try await wait { !model.isSendingGoalFromComposer }
        #expect(!model.isComposingGoal && model.inputText == "Original goal")
        #expect(model.drafts[other] == "Other conversation draft" && probe.requests.isEmpty)
        #expect(try await hub.makeGoalStore(for: .work)!.latest(sessionID: origin) == nil)
    }

    @Test("Rejecting a real approval does not execute the action or start another segment")
    @MainActor func rejectedApproval() async throws {
        let queue = try queue(), root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-approval-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), skillDirectoryRoot: root.appendingPathComponent("skills"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root.appendingPathComponent("files")))
        let probe = HostProbe(), mutation = GoalMutationCounter()
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil, makeEngine: { request in
            probe.requests.append(request)
            return try hostEngine(request, segment: probe.requests.count, mutation: mutation)
        })
        await model.load(); model.newSession()
        #expect(await model.startGoal(definition(), expectedSessionID: model.activeSessionId))
        try await wait { model.pendingConfirmation != nil && model.activeGoal?.status == .waitingForConfirmation }
        #expect(await mutation.count == 0)
        model.confirmPending(approved: false)
        try await wait { model.activeGoal?.status == .blocked && !model.isAnyRunning }
        #expect(model.activeGoal?.stopReason == .approvalRejected && probe.requests.count == 1)
        #expect(await mutation.count == 0)
    }

    @Test("A failed goal receipt commit blocks sends and retries persistence without running the model again")
    @MainActor func receiptSaveFailure() async throws {
        let queue = try queue(), root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), skillDirectoryRoot: root.appendingPathComponent("skills"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root.appendingPathComponent("files")))
        let probe = HostProbe()
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil, makeEngine: { request in
            probe.requests.append(request); return try hostEngine(request, segment: probe.requests.count)
        })
        let gate = GoalReceiptCommitGate()
        defer { gate.release() }
        try await queue.write { db in
            db.add(function: DatabaseFunction("goal_commit_gate", argumentCount: 0, pure: false) { _ in
                gate.enter(); return 1
            })
            try db.execute(sql: "CREATE TRIGGER delay_goal_commit BEFORE UPDATE ON execution_goals WHEN NEW.status='running' AND json_extract(CAST(NEW.payload AS TEXT),'$.activeRunID') IS NULL BEGIN SELECT goal_commit_gate(); END")
            try db.execute(sql: "CREATE TRIGGER refuse_goal_result BEFORE UPDATE ON execution_goals WHEN NEW.status='awaitingReview' BEGIN SELECT RAISE(FAIL,'fixture'); END")
        }
        await model.load(); model.newSession()
        #expect(await model.startGoal(definition(), expectedSessionID: model.activeSessionId))
        try await wait { gate.entered }
        #expect(model.goalIsCommittingReceipt && !model.goalSavePending && !model.canComposeGoal)
        model.inputText = "Keep this unsent"; model.send()
        await model.retryGoalSave()
        #expect(model.inputText == "Keep this unsent" && probe.requests.count == 1)
        gate.release()
        try await wait { model.goalSavePending && !model.isAnyRunning }
        #expect(probe.requests.count == 2)
        model.inputText = "Keep this unsent"; model.send()
        #expect(model.inputText == "Keep this unsent" && probe.requests.count == 2)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER refuse_goal_result") }
        await model.retryGoalSave()
        #expect(!model.goalSavePending && model.activeGoal?.status == .awaitingReview)
        #expect(probe.requests.count == 2)
        #expect(try await hub.makeGoalStore(for: .work)!.attempts(goalID: model.activeGoal!.id).count == 2)
    }

    @Test("Ending a goal immediately after start durably stops preparation and cannot leave a ready goal")
    @MainActor func cancelDuringPreparation() async throws {
        let queue = try queue(), root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-early-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), skillDirectoryRoot: root.appendingPathComponent("skills"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root.appendingPathComponent("files")))
        let probe = HostProbe()
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil, makeEngine: { request in
            probe.requests.append(request)
            try Task.checkCancellation()
            return try hostEngine(request, segment: 1)
        })
        await model.load(); model.newSession()
        #expect(await model.startGoal(definition(), expectedSessionID: model.activeSessionId))
        let current = try #require(model.activeGoal)
        await model.stopGoal(current, cancel: true)
        try await wait { !model.isAnyRunning && model.activeGoal?.status == .cancelled }
        #expect(model.activeGoal?.activeRunID == nil && !model.goalSavePending)
        let saved = try await hub.makeGoalStore(for: .work)!.goal(id: current.id)
        #expect(saved.status == .cancelled && saved.stopReason == .userCancelled)
        #expect(probe.requests.isEmpty)
    }

    @Test("Native goal setup and progress views render using localized product text")
    @MainActor func nativePresentation() async throws {
        guard let directory = ProcessInfo.processInfo.environment["AGROOM_GOAL_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        let queue = try queue()
        var value = try await goal(queue)
        value.status = .awaitingReview
        value.latestRunID = UUID()
        let oldLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = oldLanguage }
        for language in AppLanguage.allCases.filter({ $0 != .system }) {
            LanguageManager.shared.currentLanguage = language
            let context = GoalEditorPresentation(sessionID: value.sessionID,
                definition: .init(title: "", objective: value.definition.objective, criteria: []))
            let setup = GoalSetupSheet(context: context, space: .work, workspaceName: "Goal test workspace", permissionMode: .workspaceWrite) { _ in false }
            let resume = GoalSetupSheet(context: .init(sessionID: value.sessionID, definition: value.definition, existing: value),
                space: .work, workspaceName: "Goal test workspace", permissionMode: .workspaceWrite) { _ in false }
            let card = GoalProgressCard(goal: value, busy: false, savePending: false, onPause: {}, onCancel: {}, onResume: {}, onReview: { _ in }, onRetrySave: {})
            let composer = GoalComposerNotice(hasAttachments: false, objectiveIsTooLong: false, submitting: false, onCancel: {})
            for (name, content, height) in [("setup", AnyView(setup), 560.0), ("resume", AnyView(resume), 560.0), ("progress", AnyView(card), 400.0), ("composer", AnyView(composer.padding(16)), 120.0)] {
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: content.frame(width: 640, height: height, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.layoutDirection, LanguageManager.shared.layoutDirection)
                    .environment(\.locale, Locale(identifier: language.rawValue)))
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100))
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let view = try #require(window.contentView), bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("goal-\(name)-\(language.rawValue).png"))
                window.close()
            }
        }
        #expect(L.string("goal.setup") != "goal.setup" && L.string("goal.reason.interrupted") != "goal.reason.interrupted")
    }
}

private final class GoalReceiptCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }
    func enter() {
        lock.withLock { didEnter = true }
        _ = semaphore.wait(timeout: .now() + 5)
    }
    func release() { semaphore.signal() }
}

private actor GoalMutationCounter { var count = 0; func increment() { count += 1 } }
private struct GoalMutationTool: DispatcherTool {
    let counter: GoalMutationCounter
    var requiresConfirmation: Bool { true }
    var sideEffectClass: ToolSideEffectClass { .nonIdempotentWrite }
    var definition: ToolDefinition { .init(name: "goal_write", description: "Synthetic mutation", parametersSchemaJSON: #"{"type":"object","properties":{}}"#) }
    func execute(argumentsJSON: String) async throws -> String { await counter.increment(); return "Synthetic action performed" }
}

private struct GoalProbeTool: DispatcherTool {
    let value: String
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    var definition: ToolDefinition { .init(name: "goal_probe", description: "Synthetic source", parametersSchemaJSON: #"{"type":"object","properties":{}}"#) }
    func execute(argumentsJSON: String) async throws -> String { value }
}
private enum GoalFixtureProvider {
    static func make(segment: Int, approval: Bool = false) -> CloudProvider {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GoalFixtureProtocol.self]
        config.httpAdditionalHeaders = ["X-Goal-Segment": String(segment), "X-Goal-Approval": approval ? "yes" : "no"]
        return CloudProvider(config: .init(name: "Goal fixture", endpoint: "https://goal-fixture.invalid/v1", model: "fixture"),
            apiKey: "synthetic", session: URLSession(configuration: config))
    }
}
private final class GoalFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "goal-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let hasResult = (raw["messages"] as? [[String: Any]] ?? []).contains { $0["role"] as? String == "tool" }
        let ready = (Int(request.value(forHTTPHeaderField: "X-Goal-Segment") ?? "1") ?? 1) >= 2
        let toolName = request.value(forHTTPHeaderField: "X-Goal-Approval") == "yes" ? "goal_write" : "goal_probe"
        let body: String
        if hasResult {
            body = "data: {\"choices\":[{\"delta\":{\"content\":\"Segment evidence saved.\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":40,\"completion_tokens\":10}}\n\ndata: [DONE]\n\n"
        } else {
            let progress: [String: Any] = ["summary": "Source inspected", "next_actions": ready ? [] : ["Inspect remaining source"], "ready_for_review": ready]
            let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: progress), as: UTF8.self)
            let calls: [[String: Any]] = [
                ["index":0,"id":"probe","function":["name":toolName,"arguments":"{}"]],
                ["index":1,"id":"checkpoint","function":["name":"goal_checkpoint","arguments":arguments]]]
            let event: [String: Any] = ["choices":[["delta":["tool_calls":calls],"finish_reason":NSNull()]]]
            body = "data: \(String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self))\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":40,\"completion_tokens\":10}}\n\ndata: [DONE]\n\n"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
