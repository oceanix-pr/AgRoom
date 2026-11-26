import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Scheduled UI orchestration", .serialized)
@MainActor
struct ScheduledProductFlowTests {
    private func queue() throws -> DatabaseQueue { let q = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(q); return q }
    private func task() -> ScheduledTask { .init(name: "Synthetic scheduled task", prompt: "Read synthetic material", schedule: .init(rule: .daily(hour: 9, minute: 0), timeZoneIdentifier: "UTC")) }
    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<300 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Scheduler fixture did not settle")
    }

    @Test("Failed result persistence blocks replay, exposes a retry and notifies only after the exact receipt commits")
    func saveFailureDoesNotReplay() async throws {
        let q = try queue(), spaces = SpaceStore(space: .work, databaseQueue: q), t = task()
        let tasks = ScheduledTaskStore(databaseQueue: q), runs = ScheduledRunStore(databaseQueue: q)
        try await tasks.save(t)
        try await q.write { db in try db.execute(sql: "CREATE TRIGGER reject_finished_schedule BEFORE UPDATE ON scheduled_runs WHEN NEW.status='failed' BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        var executed = 0, notifications = 0
        let center = ScheduledTaskCenter(spaceStore: spaces, enabled: { true }, execute: { _,space,_,_,_,_ in
            #expect(space == .work); executed += 1
            return .init(status: .failed, outputText: "EXACT PARTIAL RESULT", errorCode: "budget_tokens", errorText: "Synthetic budget stop")
        }, notification: { _,_ in notifications += 1 })
        defer { center.stop() }
        try await center.runNow(taskID: t.id, space: .work)
        try await wait { center.hasUnsavedResults }
        #expect(executed == 1 && notifications == 0 && center.hasPendingResult(taskID: t.id, space: .work))
        #expect(!center.hasPendingResult(taskID: t.id, space: .personal))
        await #expect(throws: ScheduledTaskCenterError.busy) { try await center.runNow(taskID: t.id, space: .work) }
        try await q.write { try $0.execute(sql: "DROP TRIGGER reject_finished_schedule") }
        await center.retrySaving(taskID: t.id, space: .work)
        let stored = try #require(try await runs.latestRun(taskID: t.id))
        #expect(stored.status == .failed && stored.outputText == "EXACT PARTIAL RESULT")
        #expect(executed == 1 && notifications == 1 && !center.hasUnsavedResults)
        await center.retrySaving(taskID: t.id, space: .work)
        #expect(executed == 1 && notifications == 1)
    }

    @Test("A same-ID operation in another space cannot cancel the fixed-space execution")
    func fixedSpaceCancellation() async throws {
        let q = try queue(), spaces = SpaceStore(space: .work, databaseQueue: q), t = task()
        try await ScheduledTaskStore(databaseQueue: q).save(t)
        var cancelled = false
        let center = ScheduledTaskCenter(spaceStore: spaces, enabled: { true }, execute: { _,_,_,_,_,_ in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { cancelled = true; return .init(status: .cancelled) }
            return .init(status: .succeeded, outputText: "SAVED SYNTHETIC RESULT")
        }, notification: { _,_ in })
        defer { center.stop() }
        try await center.runNow(taskID: t.id, space: .work)
        #expect(center.isRunning(taskID: t.id, space: .work) && !center.isRunning(taskID: t.id, space: .personal))
        center.cancel(taskID: t.id, space: .personal)
        try await wait { try await ScheduledRunStore(databaseQueue: q).latestRun(taskID: t.id)?.status == .succeeded }
        #expect(!cancelled && spaces.queue(for: .personal) == nil)
    }

    @Test("Results only create drafts or editable knowledge previews until the user's save, with source-change and context protection")
    func resultActions() async throws {
        let q = try queue(), runs = ScheduledRunStore(databaseQueue: q), knowledge = KnowledgeService(databaseQueue: q), t = task()
        let run = ScheduledRun(taskID: t.id, taskName: t.name, trigger: .manual, scheduledFor: nil, status: .succeeded,
            startedAt: Date(), finishedAt: Date(), outputText: "SAVED RESULT 1024")
        try await runs.insert(run)
        let stored = try #require(try await runs.run(id: run.id))
        var current = true
        let model = ScheduledResultActionsModel(run: stored, space: .work, store: runs, knowledge: knowledge, isCurrent: { current })
        #expect(try await model.draft(report: false).contains("> SAVED RESULT 1024"))
        #expect(try await model.draft(report: true).contains("> SAVED RESULT 1024"))
        var draft = try await model.prepareKnowledge(); draft.title = "Edited knowledge title"; draft.content = "Edited saved content"
        #expect(try await knowledge.getAll().isEmpty)
        current = false
        await #expect(throws: ScheduledExperienceError.changed) { try await model.saveKnowledge(draft) }
        current = true
        var changed = stored; changed.outputText = "A different result"; try await runs.update(changed)
        await #expect(throws: ScheduledExperienceError.changed) { try await model.saveKnowledge(draft) }
        #expect(try await knowledge.getAll().isEmpty)
        try await runs.update(stored)
        try await model.saveKnowledge(draft)
        let saved = try await knowledge.getAll()
        #expect(model.saved && saved.map(\.title) == ["Edited knowledge title"])
        #expect(try await knowledge.get(id: draft.id)?.content == draft.content)
        await #expect(throws: ScheduledExperienceError.changed) { try await model.saveKnowledge(draft) }
        #expect(try await knowledge.getAll().count == 1)
    }

    @Test("The master switch's disabled interval is skipped when explicitly re-enabled")
    func masterEnableSkipsDisabledTimes() async throws {
        let q = try queue(), spaces = SpaceStore(space: .work, databaseQueue: q), now = Date()
        let t = ScheduledTask(name: "Disabled-period once", prompt: "Synthetic", schedule: .init(rule: .once(now.addingTimeInterval(-30)), timeZoneIdentifier: "UTC"), nextFireAt: now.addingTimeInterval(-30))
        try await ScheduledTaskStore(databaseQueue: q).save(t)
        var enabled = false, executions = 0
        let center = ScheduledTaskCenter(spaceStore: spaces, enabled: { enabled }, execute: { _,_,_,_,_,_ in
            executions += 1; return .init(status: .succeeded)
        }, notification: { _,_ in })
        defer { center.stop() }
        enabled = true; center.schedulingSettingChanged(to: true)
        try await wait { try await ScheduledTaskStore(databaseQueue: q).task(id: t.id)?.enabled == false }
        let runs = try await ScheduledRunStore(databaseQueue: q).runs(taskID: t.id)
        #expect(executions == 0 && runs.isEmpty)
    }

    @Test("The live scheduler stays quiet for the baseline and unchanged results, then notifies only after the changed receipt commits")
    func changeNotifications() async throws {
        let q = try queue(), spaces = SpaceStore(space: .work, databaseQueue: q)
        var t = task()
        t.options = .init(notifyOnlyOnChange: true, comparisonInstructions: "Compare the synthetic release version")
        try await ScheduledTaskStore(databaseQueue: q).save(t)
        var values = ["v1", "v1", "v2"], notifications = 0, executions = 0
        let center = ScheduledTaskCenter(spaceStore: spaces, enabled: { true }, execute: { _,_,definition,_,_,_ in
            executions += 1
            var experience = ScheduledRunExperience(budget: definition.effectiveOptions.budget)
            experience.comparisonValue = values.removeFirst()
            experience.definitionFingerprint = definition.comparisonFingerprint
            return .init(status: .succeeded, outputText: "Synthetic observation", experience: experience)
        }, notification: { _,_ in
            let latest = try? await ScheduledRunStore(databaseQueue: q).latestRun(taskID: t.id)
            #expect(latest?.experience?.comparisonState == .changed)
            notifications += 1
        })
        defer { center.stop() }
        for index in 0..<3 {
            try await center.runNow(taskID: t.id, space: .work)
            try await wait {
                let receipts = try await ScheduledRunStore(databaseQueue: q).runs(taskID: t.id)
                return executions == index + 1 && !center.isRunning(taskID: t.id, space: .work) &&
                    !center.hasUnsavedResults && receipts.count == index + 1 && receipts.allSatisfy { $0.status == .succeeded } &&
                    notifications == (index == 2 ? 1 : 0)
            }
            #expect(notifications == (index == 2 ? 1 : 0))
        }
    }
}
