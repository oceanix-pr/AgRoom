import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Product workflows")
struct ProductWorkflowTests {
    private func queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return queue
    }

    @Test("Task deadline and spent tokens survive checkpoint round trips without a new time allowance")
    func budgetSurvivesResume() async throws {
        let legacy = try JSONDecoder().decode(ExecutionBudgetCheckpoint.self, from: Data(#"{"maxTokens":1000,"maxToolCalls":10,"spentTokens":0,"toolCalls":0}"#.utf8))
        #expect(legacy.deadline == nil)
        var settings = ProductTaskBudget()
        settings.enabled = true; settings.maxTokens = 10_000; settings.minutes = 2
        let checkpoint = try #require(settings.checkpoint(now: Date()))
        let first = ExecutionBudgetLedger(maxTokens: checkpoint.maxTokens, maxToolCalls: checkpoint.maxToolCalls, restoring: checkpoint)
        let reservation = try await first.reserve(inputEstimate: 100, outputCap: 500, purpose: .main)
        await first.settle(reservation, inputTokens: 100, outputTokens: 200)
        let saved = try JSONDecoder().decode(ExecutionBudgetCheckpoint.self, from: JSONEncoder().encode(first.checkpoint))
        let resumed = ExecutionBudgetLedger(maxTokens: saved.maxTokens, maxToolCalls: saved.maxToolCalls, deadline: Date().addingTimeInterval(3_600), restoring: saved)
        #expect(await resumed.deadline == checkpoint.deadline)
        #expect(await resumed.spent == 300)
        let expired = ExecutionBudgetLedger(maxTokens: 1_000, maxToolCalls: 1, deadline: Date().addingTimeInterval(-1))
        await #expect(throws: BudgetError.deadlineExceeded) { try await expired.reserve(inputEstimate: 1, outputCap: 1, purpose: .main) }
    }

    @Test("First-result verification is atomic, idempotent and cannot confirm a newer task")
    func firstResultVerification() async throws {
        let service = ProductPreferencesService(databaseQueue: try queue())
        let initial = FirstResultProgress(template: "organize", sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 1_000))
        try await service.save(initial, key: "first-result.progress")
        let verified = try await service.verifyFirstResult(sessionID: initial.sessionID, at: Date(timeIntervalSince1970: 1_030))
        let again = try await service.verifyFirstResult(sessionID: initial.sessionID, at: Date(timeIntervalSince1970: 1_090))
        #expect(verified == again)
        #expect(try await service.metrics().firstResultSeconds == 30)
        let newer = FirstResultProgress(template: "compare", sessionID: UUID())
        try await service.save(newer, key: "first-result.progress")
        await #expect(throws: SpaceServiceError.self) { try await service.verifyFirstResult(sessionID: initial.sessionID) }
        #expect(try await service.load(FirstResultProgress.self, key: "first-result.progress") == newer)
    }

    @Test("Configured prices preserve missing usage instead of presenting a zero charge")
    func unknownCostAndLocalMetrics() async throws {
        let price = ProductModelPrice(providerID: UUID(), model: "test-model", inputPerMillion: 2, outputPerMillion: 8)
        #expect(price.estimate(input: 1_000, output: 500) == 0.006)
        #expect(price.estimate(input: nil, output: 500) == nil)
        let first = ProductPreferencesService(databaseQueue: try queue()), second = ProductPreferencesService(databaseQueue: try queue())
        let id = UUID()
        try await first.record(.artifactProduced, id: "produced", taskID: id)
        try await first.record(.artifactUsed, taskID: id)
        try await first.record(.artifactUsed, taskID: id)
        let summary = try await first.metrics()
        #expect(summary.tasksWithArtifacts == 1 && summary.reusedArtifactTasks == 1)
        #expect(try await second.metrics().tasksWithArtifacts == 0)
        try await first.clearMetrics()
        #expect(try await first.metrics().tasksWithArtifacts == 0)
    }

    @Test("Clearing starts a durable measurement period; old runs and earlier setup cannot silently refill it")
    func metricsPeriod() async throws {
        let db = try queue(), service = ProductPreferencesService(databaseQueue: db), sessions = SessionService(databaseQueue: db)
        var old = ChatSession(title: "Keep business data")
        old.messages = [.init(role: .user, content: "Original task"), .init(role: .assistant, content: "Original result", runStatus: .succeeded,
            taskRun: .init(startedAt: Date().addingTimeInterval(-60)))]
        try await sessions.save(old)
        let oldRun = try #require(old.messages.last?.taskRun?.id)
        let progress = FirstResultProgress(template: "organize", sessionID: old.id, startedAt: Date().addingTimeInterval(-40))
        try await service.beginFirstResult(progress)
        #expect(try await service.metrics().tasksStarted == 1)
        try await service.clearMetrics()
        let cutoff = try #require(try await service.metrics().measuredSince)
        old.messages[1].content = "Later edit of an earlier run"
        old.messages[1].trace = [.init(toolName: "files_write", argumentsPreview: "", resultPreview: "", artifact: .init(path: "/synthetic/report.md"), duration: 0, succeeded: true)]
        try await sessions.save(old)
        try await service.record(.artifactUsed, taskID: oldRun)
        _ = try await service.verifyFirstResult(sessionID: old.id)
        let cleared = try await ProductPreferencesService(databaseQueue: db).metrics()
        #expect(cleared.tasksStarted == 0 && cleared.tasksCompleted == 0 && cleared.tasksWithArtifacts == 0 && cleared.reusedArtifactTasks == 0 && cleared.firstResultSeconds == nil)
        var current = ChatSession(title: "New period")
        let currentID = UUID()
        current.messages = [.init(role: .user, content: "New request"), .init(role: .assistant, content: "New result", trace: old.messages[1].trace,
            runStatus: .succeeded, taskRun: .init(id: currentID))]
        try await sessions.save(current)
        try await service.record(.artifactUsed, taskID: currentID)
        try await service.record(.artifactUsed, taskID: currentID)
        let summary = try await service.metrics()
        #expect(summary.tasksStarted == 1 && summary.tasksCompleted == 1 && summary.tasksWithArtifacts == 1 && summary.reusedArtifactTasks == 1 && summary.measuredSince == cutoff)
        #expect(try await sessions.fetch(id: old.id)?.messages.last?.content == "Later edit of an earlier run")
    }

    @Test("A failed clear preserves counters and the prior measurement period atomically")
    func failedMetricsClear() async throws {
        let db = try queue(), service = ProductPreferencesService(databaseQueue: db)
        try await service.record(.manualIntervention)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_metrics_period BEFORE INSERT ON product_preferences WHEN NEW.key='metrics.since' BEGIN SELECT RAISE(FAIL, 'injected'); END") }
        await #expect(throws: (any Error).self) { try await service.clearMetrics() }
        let retained = try await service.metrics()
        #expect(retained.manualInterventions == 1 && retained.measuredSince == nil)
        await #expect(throws: SpaceServiceError.self) { try await service.record(.firstResultVerified, elapsedSeconds: .nan) }
    }

    @Test("Derived prompts remain physically isolated and survive service reconstruction")
    func scopedPrompts() async throws {
        let personal = try queue(), work = try queue()
        let personalService = ProductPreferencesService(databaseQueue: personal)
        let workService = ProductPreferencesService(databaseQueue: work)
        try await personalService.saveQuickPrompts([" Private note ", "Private note", ""])
        try await workService.saveQuickPrompts(["Work report"])
        #expect(try await ProductPreferencesService(databaseQueue: personal).quickPrompts() == ["Private note"])
        #expect(try await workService.quickPrompts() == ["Work report"])
        let global = try DatabaseQueue()
        try DatabaseBootstrap.prepareGlobal(global)
        #expect(try await global.read { try !$0.tableExists("product_preferences") })
    }

    @MainActor @Test("Legacy prompt migration requires a chosen destination and consumes its copy only after success")
    func legacyPromptOwnership() async throws {
        let suite = "product-prompts-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(try JSONEncoder().encode(["Old private prompt"]), forKey: LegacyQuickPromptMigration.key)
        let personal = ProductPreferencesService(databaseQueue: try queue())
        let work = ProductPreferencesService(databaseQueue: try queue())
        #expect(try await work.quickPrompts().isEmpty)
        try await LegacyQuickPromptMigration.migrate(to: personal, preferences: preferences)
        try await LegacyQuickPromptMigration.migrate(to: work, preferences: preferences)
        #expect(try await personal.quickPrompts() == ["Old private prompt"])
        #expect(try await work.quickPrompts().isEmpty)
        #expect(!LegacyQuickPromptMigration.isAvailable(in: preferences))
    }
}
