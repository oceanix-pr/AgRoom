import Testing
import Foundation
import GRDB
@testable import AgRoomUI
@testable import AgRoomCore

// MARK: - Fixtures

private actor Recorder {
    private var entries: [(String, Date)] = []

    func record(_ name: String) {
        entries.append((name, Date()))
    }

    func snapshot() -> [(String, Date)] {
        entries
    }
}

private struct TestWorker: TeamWorker {
    let name: String
    let subtaskID: UUID
    let result: TeamSubtaskResult
    let delay: TimeInterval
    let recorder: Recorder?

    func run() async throws -> TeamSubtaskResult {
        if let recorder {
            await recorder.record("start-\(subtaskID)")
        }
        if delay > 0 {
            try await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
        }
        if let recorder {
            await recorder.record("finish-\(subtaskID)")
        }
        return result
    }
}

private struct FakeFactory: TeamWorkerFactory {
    let results: [UUID: TeamSubtaskResult]
    let delays: [UUID: TimeInterval]
    let recorder: Recorder?

    func makeWorker(
        taskID: UUID,
        plan: TeamPlan,
        subtask: TeamSubtask,
        inputs: [TeamArtifact],
        budget: TeamBudget
    ) async throws -> any TeamWorker {
        guard let result = results[subtask.id] else {
            throw TeamError.workerUnavailable("missing fake result for \(subtask.title)")
        }
        return TestWorker(
            name: "fake-\(subtask.title)",
            subtaskID: subtask.id,
            result: result,
            delay: delays[subtask.id] ?? 0,
            recorder: recorder
        )
    }
}

private struct EchoFactory: TeamWorkerFactory {
    func makeWorker(
        taskID: UUID,
        plan: TeamPlan,
        subtask: TeamSubtask,
        inputs: [TeamArtifact],
        budget: TeamBudget
    ) async throws -> any TeamWorker {
        TestWorker(
            name: "echo",
            subtaskID: subtask.id,
            result: makeResult(id: subtask.id, summary: "\(subtask.title) done"),
            delay: 0,
            recorder: nil
        )
    }
}

private actor ReportRecorder {
    private var reports: [TeamTaskReport] = []

    func append(_ report: TeamTaskReport) {
        reports.append(report)
    }

    func snapshot() -> [TeamTaskReport] {
        reports
    }
}

private struct FixedVerifier: TeamVerifier {
    let verification: TeamVerification

    func verify(
        plan: TeamPlan,
        artifacts: [TeamArtifact],
        subtasks: [TeamSubtaskReport]
    ) async -> TeamVerification {
        verification
    }
}

private func makeResult(
    id: UUID,
    summary: String,
    tokens: Int = 10,
    artifactKind: String = "findings"
) -> TeamSubtaskResult {
    TeamSubtaskResult(
        subtaskID: id,
        outcome: .succeeded,
        summary: summary,
        artifacts: [
            TeamArtifactDraft(kind: artifactKind, title: summary, content: "content: \(summary)")
        ],
        evidence: ["source: \(summary)"],
        usage: TeamUsage(tokens: tokens, inputTokens: tokens / 2, outputTokens: tokens / 2, toolCalls: 1)
    )
}

// MARK: - Plan Validation

@Suite("TeamPlanValidator")
struct TeamPlanValidatorTests {
    @Test("rejects a dependency cycle")
    func rejectsCycle() {
        let a = UUID()
        let b = UUID()
        let plan = TeamPlan(
            goal: "cycle",
            subtasks: [
                TeamSubtask(id: a, title: "A", objective: "a", dependsOn: [b]),
                TeamSubtask(id: b, title: "B", objective: "b", dependsOn: [a]),
            ]
        )
        do {
            try TeamPlanValidator.validate(plan, budget: .default)
            Issue.record("expected a cycle error")
        } catch let error as TeamPlanError {
            #expect(error == .cycle)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("rejects an unknown dependency")
    func rejectsUnknownDependency() {
        let missing = UUID()
        let a = UUID()
        let plan = TeamPlan(
            goal: "missing dep",
            subtasks: [TeamSubtask(id: a, title: "A", objective: "a", dependsOn: [missing])]
        )
        do {
            try TeamPlanValidator.validate(plan, budget: .default)
            Issue.record("expected an unknown dependency error")
        } catch let error as TeamPlanError {
            if case .unknownDependency(let subtask, let dependency) = error {
                #expect(subtask == a)
                #expect(dependency == missing)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("write scopes are accepted as host-confined declarations but empty scopes are rejected")
    func validatesWriteScopes() {
        let id = UUID()
        let valid = TeamPlan(
            goal: "write",
            subtasks: [TeamSubtask(
                id: id, title: "A", objective: "a",
                writeScopes: ["reports", "reports/2026"]
            )]
        )
        do {
            try TeamPlanValidator.validate(valid, budget: .default)
        } catch {
            Issue.record("a non-empty write scope should pass structural validation: \(error)")
        }

        let invalid = TeamPlan(
            goal: "write",
            subtasks: [TeamSubtask(id: id, title: "A", objective: "a", writeScopes: ["  "])]
        )
        do {
            try TeamPlanValidator.validate(invalid, budget: .default)
            Issue.record("expected empty write scope rejection")
        } catch let error as TeamPlanError {
            #expect(error == .invalidWriteScope(id))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("rejects an estimate above the task budget")
    func rejectsBudget() {
        let id = UUID()
        let plan = TeamPlan(
            goal: "budget",
            subtasks: [TeamSubtask(id: id, title: "A", objective: "a", estimatedTokens: 500)]
        )
        do {
            try TeamPlanValidator.validate(plan, budget: TeamBudget(maxTokens: 100))
            Issue.record("expected budget rejection")
        } catch let error as TeamPlanError {
            if case .budgetTooSmall = error {
                // expected
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("an unrepresentable estimate is omitted from an uncapped plan")
    func optionalPlanEstimate() throws {
        let plan = TeamPlan(goal: "Estimate", subtasks: [
            TeamSubtask(title: "A", objective: "Read", estimatedTokens: .max),
            TeamSubtask(title: "B", objective: "Read", estimatedTokens: 1)
        ])
        try TeamPlanValidator.validate(plan, budget: .default)
        #expect(plan.estimatedTokens == nil)
        #expect(throws: TeamPlanError.self) { try TeamPlanValidator.validate(plan, budget: TeamBudget(maxTokens: 100)) }
    }
}

// MARK: - Payload Decoding

@Suite("TeamPlanPayload")
struct TeamPlanPayloadTests {
    @Test("decodes keys, snake_case and dependencies")
    func decodesPlan() throws {
        let json = #"""
        {
          "goal": "research two cities",
          "acceptance": ["cite sources"],
          "max_concurrency": 2,
          "subtasks": [
            {"key": "a", "title": "City A", "objective": "research A", "role": "researcher"},
            {"key": "b", "title": "City B", "objective": "research B", "role": "researcher"},
            {"key": "c", "title": "Compare", "objective": "compare A and B", "depends_on": ["a", "b"]}
          ]
        }
        """#
        let plan = try TeamPlanPayload.decode(json)
        #expect(plan.goal == "research two cities")
        #expect(plan.subtasks.count == 3)
        #expect(plan.maxConcurrency == 2)
        #expect(plan.subtasks[2].dependsOn == [plan.subtasks[0].id, plan.subtasks[1].id])
    }
}

// MARK: - Coordinator

@Suite("TeamCoordinator")
struct TeamCoordinatorTests {
    @Test("A team invoked through the engine charges the inherited parent for workers and tool calls")
    func inheritedParentBudget() async throws {
        let parent = ExecutionBudgetLedger(maxTokens: 1_000, maxToolCalls: 3, deadline: Date().addingTimeInterval(30))
        let tool = TeamRunTool(factory: ParentBudgetFactory(), space: .work)
        let context = ExecutionContext(space: .work, permissionPolicy: nil, budgetLedger: parent, deadline: parent.deadline)
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "Synthetic", executionContext: context)
        let plan = #"{"goal":"Synthetic","subtasks":[{"title":"Fixture","objective":"Synthetic budget probe","estimated_tokens":100}]}"#
        _ = try await engine.executeCommand(.init(id: "team", name: "team_run", argumentsJSON: plan))
        #expect(await parent.spent == 15)
        #expect(await parent.reserved == 0)
        #expect(await parent.toolCallCount == 2)
    }

    @Test("runs independent nodes concurrently and joins dependencies")
    func runsDAG() async throws {
        let recorder = Recorder()
        let a = TeamSubtask(title: "A", objective: "a", estimatedTokens: 10)
        let b = TeamSubtask(title: "B", objective: "b", estimatedTokens: 10)
        let c = TeamSubtask(title: "C", objective: "c", dependsOn: [a.id, b.id], estimatedTokens: 10)
        let plan = TeamPlan(goal: "join", subtasks: [a, b, c], maxConcurrency: 2)
        let factory = FakeFactory(
            results: [
                a.id: makeResult(id: a.id, summary: "A done"),
                b.id: makeResult(id: b.id, summary: "B done"),
                c.id: makeResult(id: c.id, summary: "C done"),
            ],
            delays: [a.id: 0.2, b.id: 0.2, c.id: 0.01],
            recorder: recorder
        )
        let coordinator = TeamCoordinator(plan: plan, factory: factory, maxSubtasks: 8)
        let report = try await coordinator.run()
        #expect(report.status == .completed)
        #expect(report.subtasks.count == 3)
        #expect(report.artifacts.count == 3)
        #expect(report.estimatedTokens == 30)
        #expect(report.digest().contains("Estimated: 30 tokens"))
        #expect(report.subtasks.contains { $0.evidence.contains("source: A done") })

        let entries = await recorder.snapshot()
        guard let startA = entries.firstIndex(where: { $0.0 == "start-\(a.id)" }),
              let startB = entries.firstIndex(where: { $0.0 == "start-\(b.id)" }),
              let finishA = entries.firstIndex(where: { $0.0 == "finish-\(a.id)" }),
              let finishB = entries.firstIndex(where: { $0.0 == "finish-\(b.id)" }),
              let startC = entries.firstIndex(where: { $0.0 == "start-\(c.id)" }) else {
            Issue.record("missing recorder entries: \(entries.map { $0.0 })")
            return
        }
        // A and B overlap; C starts only after both finish.
        #expect(startA < finishB)
        #expect(startB < finishA)
        #expect(startC > finishA)
        #expect(startC > finishB)
    }

    @Test("repeated run returns the cached terminal report without rerunning workers")
    func repeatedRunIsIdempotent() async throws {
        let recorder = Recorder()
        let a = TeamSubtask(title: "A", objective: "a", estimatedTokens: 10)
        let plan = TeamPlan(goal: "once", subtasks: [a])
        let factory = FakeFactory(
            results: [a.id: makeResult(id: a.id, summary: "A done")],
            delays: [:],
            recorder: recorder
        )
        let coordinator = TeamCoordinator(plan: plan, factory: factory)
        let first = try await coordinator.run()
        let second = try await coordinator.run()
        #expect(first == second)
        #expect(await recorder.snapshot().filter { $0.0 == "start-\(a.id)" }.count == 1)
    }

    @Test("budget exhaustion blocks remaining work and returns partial results")
    func budgetStopsRemaining() async throws {
        let a = TeamSubtask(title: "A", objective: "a", estimatedTokens: 40)
        let b = TeamSubtask(title: "B", objective: "b", estimatedTokens: 40)
        let plan = TeamPlan(goal: "budget", subtasks: [a, b], maxConcurrency: 1)
        let factory = FakeFactory(
            results: [
                a.id: makeResult(id: a.id, summary: "A done", tokens: 80),
                b.id: makeResult(id: b.id, summary: "B done", tokens: 80),
            ],
            delays: [:],
            recorder: nil
        )
        let coordinator = TeamCoordinator(
            plan: plan,
            budget: TeamBudget(maxTokens: 100, maxConcurrentWorkers: 1),
            factory: factory
        )
        let report = try await coordinator.run()
        #expect(report.status == .failed)
        #expect(report.subtasks.first(where: { $0.id == a.id })?.outcome == .succeeded)
        #expect(report.subtasks.first(where: { $0.id == b.id })?.outcome == .blocked)
        #expect(report.errors.contains { $0.contains("budget") })
    }

    @Test("successful workers that overspend still fail the task")
    func overspendFails() async throws {
        let a = TeamSubtask(title: "A", objective: "a", estimatedTokens: 40)
        let b = TeamSubtask(title: "B", objective: "b", estimatedTokens: 40)
        let plan = TeamPlan(goal: "overspend", subtasks: [a, b], maxConcurrency: 2)
        let factory = FakeFactory(
            results: [
                a.id: makeResult(id: a.id, summary: "A done", tokens: 80),
                b.id: makeResult(id: b.id, summary: "B done", tokens: 80),
            ],
            delays: [:],
            recorder: nil
        )
        let coordinator = TeamCoordinator(
            plan: plan,
            budget: TeamBudget(maxTokens: 100, maxConcurrentWorkers: 2),
            factory: factory
        )
        let report = try await coordinator.run()
        #expect(report.status == .failed)
        #expect(report.usage.tokens == 160)
        #expect(report.errors.contains { $0.contains("budget") })
    }

    @Test("independent verifier can block completion")
    func verifierCanFail() async throws {
        let a = TeamSubtask(title: "A", objective: "a", estimatedTokens: 10)
        let plan = TeamPlan(goal: "verify", acceptance: ["cite sources"], subtasks: [a])
        let factory = FakeFactory(
            results: [a.id: makeResult(id: a.id, summary: "A done")],
            delays: [:],
            recorder: nil
        )
        let verifier = FixedVerifier(verification: TeamVerification(
            passed: false,
            summary: "No citation was provided.",
            issues: ["missing source"]
        ))
        let coordinator = TeamCoordinator(plan: plan, factory: factory, verifier: verifier)
        let report = try await coordinator.run()
        #expect(report.status == .failed)
        #expect(report.verification?.passed == false)
        #expect(report.errors.contains { $0.contains("Verification failed") })
    }

    @Test("independent verifier pass allows completion")
    func verifierCanPass() async throws {
        let a = TeamSubtask(title: "A", objective: "a", estimatedTokens: 10)
        let plan = TeamPlan(goal: "verify", acceptance: ["cite sources"], subtasks: [a])
        let factory = FakeFactory(
            results: [a.id: makeResult(id: a.id, summary: "A done")],
            delays: [:],
            recorder: nil
        )
        let verifier = FixedVerifier(verification: TeamVerification(
            passed: true,
            summary: "Evidence covers the goal."
        ))
        let coordinator = TeamCoordinator(plan: plan, factory: factory, verifier: verifier)
        let report = try await coordinator.run()
        #expect(report.status == .completed)
        #expect(report.verification?.passed == true)
        #expect(report.digest().contains("Verification: passed"))
    }

    @Test("coordinator emits intermediate and final snapshots to the report observer")
    func reportObserverSnapshots() async throws {
        let recorder = ReportRecorder()
        let a = TeamSubtask(title: "A", objective: "a", estimatedTokens: 10)
        let plan = TeamPlan(goal: "persist", subtasks: [a])
        let factory = FakeFactory(
            results: [a.id: makeResult(id: a.id, summary: "A done")],
            delays: [:],
            recorder: nil
        )
        let coordinator = TeamCoordinator(
            plan: plan,
            factory: factory,
            onReport: { report in await recorder.append(report) }
        )
        let report = try await coordinator.run()
        let snapshots = await recorder.snapshot()
        #expect(report.status == .completed)
        #expect(snapshots.count >= 2)
        #expect(snapshots.last?.status == .completed)
    }

    @Test("cancellation stops workers and returns a cancelled report")
    func cancelStopsWorkers() async throws {
        let a = TeamSubtask(title: "A", objective: "a", estimatedTokens: 10)
        let b = TeamSubtask(title: "B", objective: "b", estimatedTokens: 10)
        let plan = TeamPlan(goal: "cancel", subtasks: [a, b], maxConcurrency: 1)
        let factory = FakeFactory(
            results: [a.id: makeResult(id: a.id, summary: "A done")],
            delays: [a.id: 5],
            recorder: nil
        )
        let coordinator = TeamCoordinator(plan: plan, factory: factory)
        let task = Task { try await coordinator.run() }
        try await Task.sleep(for: .milliseconds(100))
        await coordinator.cancel()
        let report = try await task.value
        #expect(report.status == .cancelled)
        #expect(report.subtasks.allSatisfy { $0.outcome != .succeeded })
    }
}

private struct ParentBudgetFactory: TeamWorkerFactory {
    func makeWorker(taskID: UUID, plan: TeamPlan, subtask: TeamSubtask, inputs: [TeamArtifact], budget: TeamBudget) async throws -> any TeamWorker {
        throw TeamError.workerUnavailable("The fixture requires the inherited ledger")
    }

    func makeWorker(taskID: UUID, plan: TeamPlan, subtask: TeamSubtask, inputs: [TeamArtifact], budget: TeamBudget,
                    budgetLedger: ExecutionBudgetLedger?) async throws -> any TeamWorker {
        guard let budgetLedger else { throw TeamError.workerUnavailable("Missing parent budget") }
        return ParentBudgetWorker(subtaskID: subtask.id, ledger: budgetLedger)
    }
}

private struct ParentBudgetWorker: TeamWorker {
    let name = "Synthetic worker"
    let subtaskID: UUID
    let ledger: ExecutionBudgetLedger
    func run() async throws -> TeamSubtaskResult {
        #expect(ledger.maxTokens == 1_000 && ledger.maxToolCalls == 3)
        let reservation = try await ledger.reserve(inputEstimate: 10, outputCap: 20, purpose: .worker)
        await ledger.settle(reservation, inputTokens: 10, outputTokens: 5)
        try await ledger.recordToolCall()
        return makeResult(id: subtaskID, summary: "Synthetic result", tokens: 15)
    }
}

// MARK: - Tool Registration

@Suite("Team tool registration")
struct TeamToolRegistrationTests {
    @Test("team_run is registered only when enabled and an agent exists")
    func registrationGating() throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let provider = CloudProvider(
            config: LLMProviderConfig(
                name: "test",
                endpoint: "https://example.invalid/v1",
                model: "m"
            ),
            apiKey: "key"
        )
        let memory = MemoryService(databaseQueue: queue)
        let agent = Agent(name: "Researcher")

        func names(enabled: Bool, agents: [Agent]) -> [String] {
            DispatcherToolFactory.buildTools(
                provider: provider,
                agents: agents,
                memoryService: memory,
                teamTasksEnabled: enabled
            ).map(\.definition.name)
        }

        #expect(!names(enabled: false, agents: [agent]).contains("team_run"))
        #expect(!names(enabled: true, agents: []).contains("team_run"))
        #expect(names(enabled: true, agents: [agent]).contains("team_run"))
    }
}

// MARK: - Tool & Settings Contracts

@Suite("TeamRunTool contracts")
struct TeamRunToolContractTests {
    @Test("A foreign retry scope is rejected before workers or task persistence")
    func foreignRetryScope() async throws {
        let scope = TeamRetryScope(resourceContext: .init(space: .personal, workspaceID: UUID()),
                                   workspaceName: "Private", directories: [])
        let factory = FakeFactory(results: [:], delays: [:], recorder: nil)
        let tool = TeamRunTool(factory: factory, space: .work, retryScope: scope)
        let plan = TeamPlan(goal: "Read", acceptance: [], subtasks: [.init(title: "Read", objective: "Read")])
        await #expect(throws: WorkspaceProjectError.wrongWorkspace) {
            try await tool.run(plan: plan, parentTaskID: nil)
        }
    }

    @Test("team_run is read-only and never asks for confirmation")
    func toolIsReadOnly() {
        let factory = FakeFactory(results: [:], delays: [:], recorder: nil)
        let tool = TeamRunTool(factory: factory)
        #expect(tool.definition.name == "team_run")
        #expect(tool.requiresConfirmation == false)
        if case .readOnly = tool.sideEffectClass {
            // expected
        } else {
            Issue.record("team_run must be read-only")
        }
    }

    @Test("team_run executes a parsed plan end to end and returns a digest")
    func executesPlan() async throws {
        let tool = TeamRunTool(factory: EchoFactory())
        let json = #"""
        {
          "goal": "tool e2e",
          "subtasks": [
            {"key": "a", "title": "A", "objective": "a"},
            {"key": "b", "title": "B", "objective": "b", "depends_on": ["a"]}
          ]
        }
        """#
        let digest = try await tool.execute(argumentsJSON: json)
        #expect(digest.contains("Status: completed"))
        #expect(digest.contains("A done"))
        #expect(digest.contains("B done"))
    }

    @Test("team_run is classified as a write only when team writes are enabled")
    func toolWriteClassification() {
        let factory = FakeFactory(results: [:], delays: [:], recorder: nil)
        let tool = TeamRunTool(factory: factory, allowsWrites: true)
        if case .nonIdempotentWrite = tool.sideEffectClass {
            // expected
        } else {
            Issue.record("team_run with writes must be non-idempotent")
        }
        if case .readOnly = tool.permissionClass {
            // expected: the entry is still governed by mode; worker writes have their own approval
        } else {
            Issue.record("team_run permission class must remain read-only at the entry")
        }
    }

    @Test("digest is bounded even when artifacts and summaries are long")
    func digestIsBounded() {
        let taskID = UUID()
        let subtaskID = UUID()
        let report = TeamTaskReport(
            taskID: taskID,
            goal: "long digest",
            status: .completed,
            subtasks: [
                TeamSubtaskReport(
                    id: subtaskID,
                    title: "A",
                    role: "researcher",
                    outcome: .succeeded,
                    summary: String(repeating: "s", count: 2_000)
                )
            ],
            artifacts: [
                TeamArtifact(
                    taskID: taskID,
                    subtaskID: subtaskID,
                    kind: "report",
                    title: "Big",
                    content: String(repeating: "x", count: 5_000),
                    producer: "Researcher"
                )
            ],
            usage: TeamUsage(tokens: 10),
            openQuestions: [],
            errors: [],
            startedAt: Date(),
            finishedAt: Date()
        )
        let digest = report.digest(maxArtifactCharacters: 100, maxTotalCharacters: 300)
        #expect(digest.count <= 340)
        #expect(digest.contains("team digest truncated"))
    }
}

@Suite("DaemonRunSettings team toggle")
struct DaemonRunSettingsTeamTests {
    @Test("team toggle round-trips and old records default to off")
    func teamToggle() throws {
        let settings = DaemonRunSettings(
            maxTokens: 100,
            temperature: 0,
            reasoningEffortRaw: nil,
            maxSteps: 3,
            replyLanguageInstruction: "English",
            personaInstruction: nil,
            workspacePath: "",
            teamTasksEnabled: true,
            teamWritesEnabled: true
        )
        let decoded = try JSONDecoder().decode(
            DaemonRunSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.teamTasksEnabled)
        #expect(decoded.teamWritesEnabled)

        let jsonObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        var object = try #require(jsonObject as? [String: Any])
        object.removeValue(forKey: "teamTasksEnabled")
        object.removeValue(forKey: "teamWritesEnabled")
        let legacy = try JSONDecoder().decode(
            DaemonRunSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.teamTasksEnabled == false)
        #expect(legacy.teamWritesEnabled == false)
    }
}

// MARK: - Verifier Parsing

@Suite("TeamVerifier parsing")
struct TeamVerifierParsingTests {
    @Test("Team verification reads only the latest approved version in the task's original workspace")
    func verifiesApprovedWriteReceipts() async throws {
        let f = try CodingWorkflowTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = TeamWriteStore(databaseQueue: f.queue)
        let provider = CloudProvider(config: .init(name: "fixture", endpoint: "https://fixture.invalid", model: "test"), apiKey: "fixture")
        let verifier = DispatcherTeamVerifier(provider: provider, writeStore: store, repository: f.reader)
        let task = UUID(), file = try f.file("report.txt", "second")
        func artifact(_ kind: String, _ content: String, _ id: UUID? = nil) -> TeamArtifact {
            TeamArtifact(taskID: task, subtaskID: UUID(), kind: kind, title: file.path, content: content,
                         producer: "writer", writeRecordID: id)
        }
        // An ordinary report may use a filename as its title without making a disk claim.
        #expect(await verifier.verifyFiles(taskID: task, artifacts: [artifact("report", "summary")]).isEmpty)
        #expect(await !verifier.verifyFiles(taskID: task, artifacts: [artifact("file-change", "second")]).isEmpty)
        let submit = TeamSubmitResultTool(box: TeamResultBox())
        await #expect(throws: LLMError.self) {
            _ = try await submit.execute(argumentsJSON: #"{"summary":"done","artifacts":[{"kind":"file-change","title":"report.txt","content":"second"}]}"#)
        }
        var history: [TeamArtifact] = []
        for value in ["first", "second"] {
            let write = try await store.record(taskID: task, space: "work", rootPath: f.reader.root.path,
                path: file.path, oldContent: nil, newContent: value, rootIdentity: f.reader.identity)
            try await store.markApplied(id: write.id)
            history.append(artifact("file-change", value, write.id))
        }
        #expect(await verifier.verifyFiles(taskID: task, artifacts: history.reversed()).isEmpty)
        #expect(await !verifier.verifyFiles(taskID: UUID(), artifacts: history).isEmpty)
        #expect(await !verifier.verifyFiles(taskID: task, artifacts: []).isEmpty)
        try Data("changed".utf8).write(to: file)
        #expect(await !verifier.verifyFiles(taskID: task, artifacts: history).isEmpty)
        try FileManager.default.moveItem(at: f.reader.root, to: f.base.appendingPathComponent("old-root"))
        _ = try f.file("report.txt", "second")
        #expect(await !verifier.verifyFiles(taskID: task, artifacts: history).isEmpty)
        let reopened = try RepositoryReader(root: f.reader.root, service: f.service, space: .work)
        let newVerifier = DispatcherTeamVerifier(provider: provider, writeStore: store, repository: reopened)
        #expect(await !newVerifier.verifyFiles(taskID: task, artifacts: history).isEmpty)
    }
    @Test("parses a strict JSON verdict")
    func parsesVerdict() {
        let verification = DispatcherTeamVerifier.parse(
            #"{"passed": true, "summary": "Sources cover the goal.", "issues": []}"#,
            usage: TeamUsage(tokens: 5)
        )
        #expect(verification.passed)
        #expect(verification.summary.contains("cover"))
        #expect(verification.issues.isEmpty)
        #expect(verification.usage.tokens == 5)
    }

    @Test("accepts a fenced JSON verdict and the pass alias")
    func parsesFencedAlias() {
        let text = """
        ```json
        {"pass": true, "summary": "ok"}
        ```
        """
        let verification = DispatcherTeamVerifier.parse(text, usage: .zero)
        #expect(verification.passed)
        #expect(verification.summary == "ok")
    }

    @Test("malformed or missing verdict fails closed")
    func malformedFails() {
        let malformed = DispatcherTeamVerifier.parse("I think it is fine.", usage: .zero)
        #expect(malformed.passed == false)
        #expect(malformed.summary.contains("malformed"))
        #expect(!malformed.rejectedDeliverables)
        #expect(!DispatcherTeamVerifier.parse(#"{"summary":"incomplete"}"#, usage: .zero).rejectedDeliverables)

        let failed = DispatcherTeamVerifier.parse(
            #"{"passed": false, "summary": "missing source"}"#,
            usage: .zero
        )
        #expect(failed.passed == false)
        #expect(failed.issues.isEmpty == false)
        #expect(failed.rejectedDeliverables)
    }
}

// MARK: - Approval & Lease

private struct ApprovalWaitTimedOut: Error {}

private func waitForApproval(
    _ center: TeamApprovalCenter,
    space: String
) async throws -> TeamApprovalRequest {
    for _ in 0..<300 {
        if let request = await center.pendingRequests(space: space).first {
            return request
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ApprovalWaitTimedOut()
}

@Suite("TeamApprovalCenter")
struct TeamApprovalCenterTests {
    private func request(space: String = "work") -> TeamApprovalRequest {
        TeamApprovalRequest(
            space: space,
            taskID: UUID(),
            taskGoal: "goal",
            subtaskID: UUID(),
            subtaskTitle: "subtask",
            path: "/tmp/a.txt",
            oldContent: nil,
            newContent: "new"
        )
    }

    @Test("approve resumes the waiting writer; space filter is enforced")
    func approve() async throws {
        let center = TeamApprovalCenter()
        let request = request()
        let waiting = Task { await center.request(request, timeout: 30) }
        let pending = try await waitForApproval(center, space: "work")
        #expect(await center.pendingRequests(space: "personal").isEmpty)
        #expect(await center.resolve(id: pending.id, space: "personal", approved: true) == false)
        #expect(await center.resolve(id: pending.id, space: "work", approved: true) == true)
        #expect(await waiting.value == .approved)
        #expect(await center.pendingRequests(space: "work").isEmpty)
    }

    @Test("deny resumes with denial")
    func deny() async throws {
        let center = TeamApprovalCenter()
        let request = request()
        let waiting = Task { await center.request(request, timeout: 30) }
        let pending = try await waitForApproval(center, space: "work")
        #expect(await center.resolve(id: pending.id, space: "work", approved: false))
        #expect(await waiting.value == .denied)
    }

    @Test("cancelling the waiting task removes the request")
    func cancel() async throws {
        let center = TeamApprovalCenter()
        let request = request()
        let waiting = Task { await center.request(request, timeout: 30) }
        _ = try await waitForApproval(center, space: "work")
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        #expect(await center.pendingRequests(space: "work").isEmpty)
    }
}

@Suite("TeamLeaseCenter")
struct TeamLeaseCenterTests {
    @Test("same path has one writer; same owner can renew; release frees it")
    func exclusiveLease() async throws {
        let center = TeamLeaseCenter()
        let task = UUID()
        let subtask = UUID()
        let lease = try await center.acquire(
            space: "work",
            path: "/tmp/a.txt",
            taskID: task,
            subtaskID: subtask
        )
        let renewed = try await center.acquire(
            space: "work",
            path: "/tmp/a.txt",
            taskID: task,
            subtaskID: subtask
        )
        #expect(renewed.id != lease.id)

        do {
            _ = try await center.acquire(
                space: "work",
                path: "/tmp/a.txt",
                taskID: UUID(),
                subtaskID: UUID()
            )
            Issue.record("expected a lease conflict")
        } catch let error as TeamLeaseError {
            #expect(error == .conflict(path: "/tmp/a.txt"))
        }

        await center.release(renewed)
        let next = try await center.acquire(
            space: "work",
            path: "/tmp/a.txt",
            taskID: UUID(),
            subtaskID: UUID()
        )
        await center.release(next)
    }
}

// MARK: - Team Write Tool

@Suite("TeamWriteTool")
struct TeamWriteToolTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-team-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeTool(
        root: URL,
        approvals: TeamApprovalCenter,
        leases: TeamLeaseCenter,
        taskID: UUID = UUID(),
        writeStore: TeamWriteStore? = nil
    ) -> TeamWriteTool {
        let resolvedStore: TeamWriteStore
        if let writeStore {
            resolvedStore = writeStore
        } else {
            let queue = try! DatabaseQueue()
            try! DatabaseBootstrap.prepareSpace(queue)
            resolvedStore = TeamWriteStore(databaseQueue: queue)
        }
        return TeamWriteTool(
            taskID: taskID,
            taskGoal: "write a file",
            subtaskID: UUID(),
            subtaskTitle: "draft",
            space: .work,
            root: root,
            approvals: approvals,
            leases: leases,
            writeStore: resolvedStore
        )
    }

    @Test("write tool is a workspace mutation and never bypasses approval")
    func writeToolPolicy() {
        let root = URL(fileURLWithPath: "/tmp/agroom-write-policy")
        let tool = TeamWriteTool(
            taskID: UUID(),
            taskGoal: "goal",
            subtaskID: UUID(),
            subtaskTitle: "subtask",
            space: .work,
            root: root,
            approvals: TeamApprovalCenter(),
            leases: TeamLeaseCenter()
        )
        #expect(tool.requiresConfirmation == false)
        if case .workspaceMutation = tool.permissionClass {
            // expected
        } else {
            Issue.record("team_write must be a workspace mutation")
        }
        if case .nonIdempotentWrite = tool.sideEffectClass {
            // expected
        } else {
            Issue.record("team_write must be a non-idempotent write")
        }
    }

    @Test("approved write replaces the file after showing old/new content")
    func approvedWrite() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("a.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)

        let approvals = TeamApprovalCenter()
        let leases = TeamLeaseCenter()
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let writeStore = TeamWriteStore(databaseQueue: queue)
        let taskID = UUID()
        let tool = makeTool(
            root: root,
            approvals: approvals,
            leases: leases,
            taskID: taskID,
            writeStore: writeStore
        )
        let writing = Task {
            try await tool.execute(argumentsJSON: #"{"path":"a.txt","content":"new content"}"#)
        }
        let request = try await waitForApproval(approvals, space: "work")
        #expect(request.oldContent == "old")
        #expect(request.newContent == "new content")
        #expect(request.path == target.path)
        #expect(await approvals.resolve(id: request.id, space: "work", approved: true))
        let result = try await writing.value
        #expect(result.contains("Updated"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "new content")
        #expect(await leases.activeLease(space: "work", path: target.path) == nil)
        let artifacts = tool.writeLog.drafts()
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.kind == "file-change")
        #expect(artifacts.first?.title == target.path)
        let records = try await writeStore.records(taskID: taskID)
        #expect(records.count == 1)
        #expect(records.first?.oldContent == "old")
        #expect(records.first?.newContent == "new content")
        #expect(artifacts.first?.writeRecordID == records.first?.id)
        #expect(try records.first?.rootIdentity == TaskDirectoryIdentity.capture(root))
        #expect(records.first?.state == .applied)
        let audit = try await writeStore.approvalAudit(taskID: taskID)
        #expect(audit.first?.decision == "approved")
        #expect(audit.first?.reason == "user_approved_once")
    }

    @Test("denied write leaves the file untouched")
    func deniedWrite() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("a.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)

        let approvals = TeamApprovalCenter()
        let tool = makeTool(root: root, approvals: approvals, leases: TeamLeaseCenter())
        let writing = Task {
            try await tool.execute(argumentsJSON: #"{"path":"a.txt","content":"new"}"#)
        }
        let request = try await waitForApproval(approvals, space: "work")
        _ = await approvals.resolve(id: request.id, space: "work", approved: false)
        do {
            _ = try await writing.value
            Issue.record("expected the denied write to throw")
        } catch {
            // expected
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    }

    @Test("file changed after approval aborts the write")
    func changedAfterApproval() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("a.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)

        let approvals = TeamApprovalCenter()
        let leases = TeamLeaseCenter()
        let tool = makeTool(root: root, approvals: approvals, leases: leases)
        let writing = Task {
            try await tool.execute(argumentsJSON: #"{"path":"a.txt","content":"new"}"#)
        }
        let request = try await waitForApproval(approvals, space: "work")
        try "changed meanwhile".write(to: target, atomically: true, encoding: .utf8)
        _ = await approvals.resolve(id: request.id, space: "work", approved: true)
        do {
            _ = try await writing.value
            Issue.record("expected the stale write to throw")
        } catch let error as TeamWriteError {
            #expect(error == .changedSinceApproval)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "changed meanwhile")
        #expect(await leases.activeLease(space: "work", path: target.path) == nil)
    }

    @Test("a competing writer's lease blocks the approved write")
    func leaseConflict() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("a.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)

        let approvals = TeamApprovalCenter()
        let leases = TeamLeaseCenter()
        let other = try await leases.acquire(
            space: "work",
            path: target.path,
            taskID: UUID(),
            subtaskID: UUID()
        )
        let tool = makeTool(root: root, approvals: approvals, leases: leases)
        let writing = Task {
            try await tool.execute(argumentsJSON: #"{"path":"a.txt","content":"new"}"#)
        }
        let request = try await waitForApproval(approvals, space: "work")
        _ = await approvals.resolve(id: request.id, space: "work", approved: true)
        do {
            _ = try await writing.value
            Issue.record("expected the lease conflict to throw")
        } catch let error as TeamLeaseError {
            #expect(error == .conflict(path: target.path))
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        await leases.release(other)
    }

    @Test("paths outside the workspace are rejected before approval")
    func outsideWorkspaceRejected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = makeTool(root: root, approvals: TeamApprovalCenter(), leases: TeamLeaseCenter())
        do {
            _ = try await tool.execute(argumentsJSON: #"{"path":"../escape.txt","content":"x"}"#)
            Issue.record("expected outside-workspace rejection")
        } catch let error as TeamWriteError {
            #expect(error == .outsideWorkspace)
        }
    }
}

// MARK: - Provider Gate

private actor GateProbe {
    private var entered = false

    func mark() { entered = true }
    func value() -> Bool { entered }
}

@Suite("ProviderConcurrencyGate")
struct ProviderConcurrencyGateTests {
    @Test("limits concurrent requests per provider and hands slots in FIFO order")
    func limitsConcurrency() async throws {
        let gate = ProviderConcurrencyGate(limit: 2)
        let probe = GateProbe()
        let first = try await gate.acquire("provider")
        let second = try await gate.acquire("provider")
        let activeAtStart = await gate.activeCount("provider")
        #expect(activeAtStart == 2)

        let third = Task {
            let ticket = try await gate.acquire("provider")
            await probe.mark()
            return ticket
        }
        try await Task.sleep(for: .milliseconds(80))
        let enteredBeforeRelease = await probe.value()
        #expect(enteredBeforeRelease == false)

        await gate.release(first)
        var thirdTicket: ProviderGateTicket?
        for _ in 0..<100 {
            if await probe.value() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let enteredAfterRelease = await probe.value()
        #expect(enteredAfterRelease == true)
        let activeAfterHandoff = await gate.activeCount("provider")
        #expect(activeAfterHandoff == 2)

        thirdTicket = try await third.value
        await gate.release(second)
        if let thirdTicket { await gate.release(thirdTicket) }

        // 重复释放不会把计数减成负数，也不会重复唤醒等待者。
        await gate.release(first)
        #expect(await gate.activeCount("provider") == 0)
    }

    @Test("cancelled waiter leaves the queue and does not consume a slot")
    func cancelledWaiterIsRemoved() async throws {
        let gate = ProviderConcurrencyGate(limit: 1)
        let first = try await gate.acquire("provider")
        let waiting = Task {
            try await gate.acquire("provider")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await gate.waitingCount("provider") == 1)
        waiting.cancel()
        do {
            _ = try await waiting.value
            Issue.record("cancelled acquire should throw")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await gate.waitingCount("provider") == 0)
        await gate.release(first)
        #expect(await gate.activeCount("provider") == 0)
    }

    @Test("queue timeout returns a distinct error and releases no slot")
    func queueTimeout() async throws {
        let gate = ProviderConcurrencyGate(limit: 1)
        let first = try await gate.acquire("provider")
        do {
            _ = try await gate.acquire("provider", timeout: 0.05)
            Issue.record("expected timeout")
        } catch ProviderGateError.timedOut {
            // expected
        }
        #expect(await gate.waitingCount("provider") == 0)
        await gate.release(first)
        #expect(await gate.activeCount("provider") == 0)
    }
}

// MARK: - Progress Center

@Suite("TeamProgressCenter")
struct TeamProgressCenterTests {
    @Test("updates per-subtask progress and clears with the task")
    func updatesProgress() async {
        let center = TeamProgressCenter()
        let taskID = UUID()
        let a = UUID()
        let b = UUID()
        await center.update(
            taskID: taskID,
            subtaskID: a,
            subtaskTitle: "A",
            agentName: "Researcher",
            toolName: "starting",
            succeeded: nil,
            duration: 0
        )
        await center.update(
            taskID: taskID,
            subtaskID: b,
            subtaskTitle: "B",
            agentName: "Analyst",
            toolName: "web_search",
            succeeded: true,
            duration: 0.2
        )
        let entries = await center.progress(taskID: taskID)
        #expect(entries.count == 2)
        #expect(entries.contains { $0.toolName == "web_search" && $0.succeeded == true })

        await center.clear(taskID: taskID)
        let afterClear = await center.progress(taskID: taskID)
        #expect(afterClear.isEmpty)
    }
}

// MARK: - Write Store & Revert

@Suite("TeamWriteStore and revert")
struct TeamWriteStoreTests {
    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return queue
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-team-revert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("records, lists, marks reverted and deletes")
    func storeRoundTrip() async throws {
        let queue = try makeQueue()
        let store = TeamWriteStore(databaseQueue: queue)
        let taskID = UUID()
        let record = try await store.record(
            taskID: taskID,
            space: "work",
            rootPath: "/tmp/root",
            path: "/tmp/root/a.txt",
            oldContent: "old",
            newContent: "new"
        )
        let records = try await store.records(taskID: taskID)
        #expect(records.count == 1)
        #expect(records.first?.id == record.id)

        try await store.markReverted(id: record.id)
        let reverted = try await store.records(taskID: taskID)
        #expect(reverted.first?.isReverted == true)

        try await store.delete(taskID: taskID)
        let empty = try await store.records(taskID: taskID)
        #expect(empty.isEmpty)
    }

    @Test("reverts an updated file")
    func revertUpdatedFile() async throws {
        let queue = try makeQueue()
        let store = TeamWriteStore(databaseQueue: queue)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("a.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let record = try await store.record(
            taskID: UUID(),
            space: "work",
            rootPath: root.path,
            path: target.path,
            oldContent: "old",
            newContent: "new"
        )
        try "new".write(to: target, atomically: true, encoding: .utf8)

        let service = TeamWriteRevertService(store: store, leases: TeamLeaseCenter())
        let reverted = try await service.revert(record)
        #expect(reverted.isReverted)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    }

    @Test("reverts a created file by deleting it")
    func revertCreatedFile() async throws {
        let queue = try makeQueue()
        let store = TeamWriteStore(databaseQueue: queue)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("new.txt")
        let record = try await store.record(
            taskID: UUID(),
            space: "work",
            rootPath: root.path,
            path: target.path,
            oldContent: nil,
            newContent: "new"
        )
        try "new".write(to: target, atomically: true, encoding: .utf8)

        let service = TeamWriteRevertService(store: store, leases: TeamLeaseCenter())
        _ = try await service.revert(record)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("reverts all team writes for a task")
    func revertAllFiles() async throws {
        let queue = try makeQueue()
        let store = TeamWriteStore(databaseQueue: queue)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try "old-a".write(to: a, atomically: true, encoding: .utf8)
        try "old-b".write(to: b, atomically: true, encoding: .utf8)
        let taskID = UUID()
        _ = try await store.record(
            taskID: taskID, space: "work", rootPath: root.path,
            path: a.path, oldContent: "old-a", newContent: "new-a"
        )
        _ = try await store.record(
            taskID: taskID, space: "work", rootPath: root.path,
            path: b.path, oldContent: "old-b", newContent: "new-b"
        )
        try "new-a".write(to: a, atomically: true, encoding: .utf8)
        try "new-b".write(to: b, atomically: true, encoding: .utf8)

        let service = TeamWriteRevertService(store: store, leases: TeamLeaseCenter())
        let count = try await service.revertAll(taskID: taskID)
        #expect(count == 2)
        #expect(try String(contentsOf: a, encoding: .utf8) == "old-a")
        #expect(try String(contentsOf: b, encoding: .utf8) == "old-b")
        let stored = try await store.records(taskID: taskID)
        #expect(stored.allSatisfy { $0.isReverted })
    }

    @Test("reverts two writes to the same path in reverse order")
    func revertSamePathTwice() async throws {
        let queue = try makeQueue()
        let store = TeamWriteStore(databaseQueue: queue)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("a.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let taskID = UUID()
        _ = try await store.record(
            taskID: taskID, space: "work", rootPath: root.path,
            path: target.path, oldContent: "old", newContent: "new-1"
        )
        try "new-1".write(to: target, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(5))
        _ = try await store.record(
            taskID: taskID, space: "work", rootPath: root.path,
            path: target.path, oldContent: "new-1", newContent: "new-2"
        )
        try "new-2".write(to: target, atomically: true, encoding: .utf8)

        let service = TeamWriteRevertService(store: store, leases: TeamLeaseCenter())
        _ = try await service.revertAll(taskID: taskID)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    }

    @Test("batch revert aborts before writing when any file is stale")
    func revertAllAbortsOnStaleFile() async throws {
        let queue = try makeQueue()
        let store = TeamWriteStore(databaseQueue: queue)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try "old-a".write(to: a, atomically: true, encoding: .utf8)
        try "old-b".write(to: b, atomically: true, encoding: .utf8)
        let taskID = UUID()
        _ = try await store.record(
            taskID: taskID, space: "work", rootPath: root.path,
            path: a.path, oldContent: "old-a", newContent: "new-a"
        )
        _ = try await store.record(
            taskID: taskID, space: "work", rootPath: root.path,
            path: b.path, oldContent: "old-b", newContent: "new-b"
        )
        try "new-a".write(to: a, atomically: true, encoding: .utf8)
        try "changed-b".write(to: b, atomically: true, encoding: .utf8)

        let service = TeamWriteRevertService(store: store, leases: TeamLeaseCenter())
        do {
            _ = try await service.revertAll(taskID: taskID)
            Issue.record("expected a stale batch to abort")
        } catch let error as TeamWriteRevertError {
            #expect(error == .changedSinceWrite)
        }
        #expect(try String(contentsOf: a, encoding: .utf8) == "new-a")
        #expect(try String(contentsOf: b, encoding: .utf8) == "changed-b")
        let stored = try await store.records(taskID: taskID)
        #expect(stored.allSatisfy { !$0.isReverted })
    }

    @Test("refuses to revert when the file changed after the team write")
    func refusesStaleRevert() async throws {
        let queue = try makeQueue()
        let store = TeamWriteStore(databaseQueue: queue)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("a.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let record = try await store.record(
            taskID: UUID(),
            space: "work",
            rootPath: root.path,
            path: target.path,
            oldContent: "old",
            newContent: "new"
        )
        try "newer".write(to: target, atomically: true, encoding: .utf8)

        let service = TeamWriteRevertService(store: store, leases: TeamLeaseCenter())
        do {
            _ = try await service.revert(record)
            Issue.record("expected a stale-revert error")
        } catch let error as TeamWriteRevertError {
            #expect(error == .changedSinceWrite)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "newer")
    }
}

// MARK: - Task Store

@Suite("TeamTaskStore")
struct TeamTaskStoreTests {
    @Test("saves, lists and deletes a task snapshot")
    func roundTrip() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let store = TeamTaskStore(databaseQueue: queue)

        let subtask = TeamSubtask(title: "A", objective: "a")
        let plan = TeamPlan(goal: "persist", subtasks: [subtask])
        let now = Date()
        let report = TeamTaskReport(
            taskID: UUID(),
            goal: plan.goal,
            status: .completed,
            subtasks: [
                TeamSubtaskReport(
                    id: subtask.id,
                    title: subtask.title,
                    role: subtask.role.rawValue,
                    outcome: .succeeded,
                    summary: "done"
                )
            ],
            artifacts: [],
            usage: TeamUsage(tokens: 12, toolCalls: 1),
            openQuestions: [],
            errors: [],
            startedAt: now,
            finishedAt: now,
            verification: TeamVerification(passed: true, summary: "ok")
        )
        try await store.save(plan: plan, report: report)

        let records = try await store.listTasks()
        #expect(records.count == 1)
        #expect(records.first?.goal == "persist")
        #expect(records.first?.status == .completed)
        #expect(records.first?.report?.verification?.passed == true)

        try await store.delete(id: report.taskID)
        let afterDelete = try await store.listTasks()
        #expect(afterDelete.isEmpty)
    }

    @Test("team_run persists its snapshots through the store")
    func teamRunPersists() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let store = TeamTaskStore(databaseQueue: queue)
        let tool = TeamRunTool(factory: EchoFactory(), store: store)
        let json = #"""
        {"goal": "persist through tool", "subtasks": [{"key": "a", "title": "A", "objective": "a"}]}
        """#
        _ = try await tool.execute(argumentsJSON: json)
        let records = try await store.listTasks()
        #expect(records.count == 1)
        #expect(records.first?.goal == "persist through tool")
        #expect(records.first?.status == .completed)
        #expect(records.first?.report?.subtasks.count == 1)
    }

    @Test("explicit retry uses a new run identity and records its parent task")
    func retryRecordsParent() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let store = TeamTaskStore(databaseQueue: queue)
        let tool = TeamRunTool(factory: EchoFactory(), store: store)
        let plan = TeamPlan(
            goal: "retry",
            subtasks: [TeamSubtask(title: "A", objective: "a")]
        )
        let parent = UUID()
        let report = try await tool.run(plan: plan, parentTaskID: parent)
        #expect(report.status == .completed)
        let record = try await store.task(id: report.taskID)
        #expect(record?.parentTaskID == parent)
        #expect(record?.runID != nil)
    }

    @Test("a saved content rejection revises existing work once, then independently verifies the complete replacement",
          arguments: [true, false])
    func revisesRejectedDeliverables(passes: Bool) async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let store = TeamTaskStore(databaseQueue: queue)
        let plan = TeamPlan(goal: "Deliver one sign-off package", acceptance: ["Use consistent examples"], subtasks: [
            TeamSubtask(title: "Contract", objective: "Define the fields"),
            TeamSubtask(title: "Cases", objective: "Provide examples", acceptance: ["Cover lost receipts"])
        ])
        // A saved verdict from before failureKind was added.
        let issue = "Example F-17 refers to two different inputs."
        let original = try await TeamRunTool(factory: EchoFactory(), store: store, verifier: FixedVerifier(
            verification: .init(passed: false, summary: "Examples disagree", issues: [issue])
        )).run(plan: plan, parentTaskID: nil)

        let revised = (1...9).map { index in
            ["title": "Case \(index)", "content": String(repeating: "x", count: index == 9 ? 1_100 : 1) + " signed-\(index)"]
        }
        let submission: [String: Any] = ["summary": "Updated examples", "outcome": "succeeded",
                                         "evidence": ["See signed cases"], "artifacts": revised]
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: submission), as: UTF8.self)
        let delta = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"submit","type":"function","function":{"name":"team_submit_result","arguments":\#(try CodingJSON.encode(arguments))}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":20}}"#
        let verdict = passes ? #"{"passed":true,"summary":"Consistent","issues":[]}"#
                             : #"{"passed":false,"summary":"Still inconsistent","issues":["Check the field mapping"]}"#
        let response = #"{"choices":[{"message":{"role":"assistant","content":\#(try CodingJSON.encode(verdict))},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#
        let fixtureID = UUID().uuidString
        CompatibilityProtocol.register(fixtureID, replies: [.init(body: "data: " + delta + "\n\ndata: [DONE]\n\n"), .init(body: response)])
        defer { CompatibilityProtocol.remove(fixtureID) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompatibilityProtocol.self]
        config.httpAdditionalHeaders = ["X-AgRoom-Test-Fixture": fixtureID]
        let provider = CloudProvider(config: .init(name: "fixture", endpoint: "https://team.invalid/v1", model: "fixture"),
                                     apiKey: "fixture", session: URLSession(configuration: config))
        let tool = TeamRunTool(factory: DispatcherTeamWorkerFactory(provider: provider, agents: [Agent(name: "Editor")]),
                               store: store, verifier: DispatcherTeamVerifier(provider: provider))
        let result = try await tool.retry(plan: plan, parentTaskID: original.taskID, revisionTitle: "Revise")
        #expect(result.status == (passes ? .completed : .failed))
        #expect(result.subtasks.count == 1)
        #expect(result.artifacts.count == revised.count)
        #expect(result.usage.tokens == 85)
        let saved = try #require(try await store.task(id: result.taskID))
        #expect(saved.parentTaskID == original.taskID)
        #expect(saved.plan.acceptance == plan.acceptance)
        #expect(saved.plan.subtasks.first?.role == .synthesizer)
        #expect(saved.plan.revision?.issues == [issue])
        #expect(try await store.task(id: original.taskID)?.report == original)
        let requests = CompatibilityProtocol.requests(fixtureID)
        try #require(requests.count == 2)
        func message(_ request: CompatibilityProtocol.Request, role: String) throws -> String {
            let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            return try #require(messages.first { $0["role"] as? String == role }?["content"] as? String)
        }
        let worker = try message(requests[0], role: "user")
        #expect(worker.contains(issue) && worker.contains("content: Contract done") && worker.contains("source: Cases done"))
        let instructions = try message(requests[0], role: "system")
        #expect(instructions.contains("Cover lost receipts") && !instructions.contains(issue))
        let check = try message(requests[1], role: "user")
        #expect(check.contains(issue) && check.contains("Use consistent examples") && check.contains("signed-9"))
        #expect(!check.contains("content: Contract done"))
    }

    @Test("technical failures rerun the same plan and a durable write prevents replay even without an artifact")
    func retryChecksSource() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let store = TeamTaskStore(databaseQueue: queue)
        let plan = TeamPlan(goal: "Review", subtasks: [TeamSubtask(title: "A", objective: "Review the contract")])
        let verifier = FixedVerifier(verification: .init(passed: false, summary: "Verifier failed: offline",
                                                         issues: ["The independent verification call did not complete."]))
        let report = try await TeamRunTool(factory: EchoFactory(), store: store, verifier: verifier)
            .run(plan: plan, parentTaskID: nil)
        #expect(try await store.planForRetry(id: report.taskID, expectedPlan: plan, revisionTitle: nil) == plan)
        _ = try await TeamWriteStore(databaseQueue: queue).record(taskID: report.taskID, space: "work",
            rootPath: "/fixture", path: "draft.txt", oldContent: nil, newContent: "pending")
        await #expect(throws: TeamError.retryUnavailable) {
            try await store.planForRetry(id: report.taskID, expectedPlan: plan, revisionTitle: nil)
        }
    }

    @Test("late callbacks cannot overwrite a newer run or resurrect a deleted task")
    func lateCallbacksAreRejected() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let store = TeamTaskStore(databaseQueue: queue)
        let subtask = TeamSubtask(title: "A", objective: "a")
        let plan = TeamPlan(goal: "guard", subtasks: [subtask])
        let runID = UUID()
        let now = Date()
        let running = TeamTaskReport(
            taskID: UUID(),
            goal: plan.goal,
            status: .running,
            subtasks: [],
            artifacts: [],
            usage: .zero,
            openQuestions: [],
            errors: [],
            startedAt: now,
            finishedAt: now
        )
        try await store.save(
            plan: plan, report: running, runID: runID, runVersion: 2,
            createIfMissing: true
        )
        try await store.delete(id: running.taskID)
        // 删除后的迟到回调不允许重新创建。
        try await store.save(
            plan: plan, report: running, runID: runID, runVersion: 3,
            createIfMissing: false
        )
        #expect(try await store.listTasks().isEmpty)

        try await store.save(
            plan: plan, report: running, runID: runID, runVersion: 4,
            createIfMissing: true
        )
        // 更旧的版本不能覆盖当前快照。
        let stale = TeamTaskReport(
            taskID: running.taskID,
            goal: "stale",
            status: .running,
            subtasks: [],
            artifacts: [],
            usage: .zero,
            openQuestions: [],
            errors: [],
            startedAt: now,
            finishedAt: now
        )
        try await store.save(
            plan: plan, report: stale, runID: runID, runVersion: 3,
            createIfMissing: false
        )
        #expect(try await store.task(id: running.taskID)?.report?.goal == "guard")
    }

    @Test("unfinished tasks can be marked interrupted after restart")
    func interruptsUnfinishedTasks() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let store = TeamTaskStore(databaseQueue: queue)
        let plan = TeamPlan(goal: "restart", subtasks: [TeamSubtask(title: "A", objective: "a")])
        let now = Date()
        let running = TeamTaskReport(
            taskID: UUID(), goal: plan.goal, status: .running, subtasks: [],
            artifacts: [], usage: .zero, openQuestions: [], errors: [],
            startedAt: now, finishedAt: now
        )
        try await store.save(plan: plan, report: running, runVersion: 1)
        try await store.interruptUnfinishedTasks()
        #expect(try await store.listTasks().first?.status == .interrupted)
    }

    @Test("migration creates the team_tasks table")
    func migrationCreatesTable() throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let tableNames = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
        }
        #expect(tableNames.contains("team_tasks"))
        #expect(tableNames.contains("team_writes"))
    }
}

// MARK: - Blackboard

@Suite("TeamBlackboard")
struct TeamBlackboardTests {
    @Test("commits artifacts with task/subtask/producer identity")
    func commitsArtifacts() async {
        let board = TeamBlackboard()
        let taskID = UUID()
        let subtaskID = UUID()
        let artifacts = await board.commit(
            taskID: taskID,
            subtaskID: subtaskID,
            producer: "Researcher",
            drafts: [
                TeamArtifactDraft(kind: "findings", title: "Sources", content: "one\ntwo"),
                TeamArtifactDraft(kind: "report", title: "Summary", content: "done"),
            ]
        )
        #expect(artifacts.count == 2)
        #expect(artifacts.allSatisfy { $0.producer == "Researcher" })
        let stored = await board.artifacts(for: taskID)
        let references = await board.references(for: taskID)
        #expect(stored.count == 2)
        #expect(references.count == 2)
    }
}

@Suite("Team worker request budget regressions")
struct TeamWorkerBudgetRegressionTests {
    @Test("stored budget failures use the current UI language and retain the subtask title")
    @MainActor
    func localizedBudgetFailure() {
        let message = "Research: " + BudgetError.tokensExhausted.localizedDescription
        let explanation = L.string("team.budget.reservation_failed")
        #expect(explanation != "team.budget.reservation_failed")
        #expect(L.teamMessage(message) == "Research: " + explanation)
        #expect(L.teamMessage("Unrelated result") == "Unrelated result")
    }

    private func fixture(replies: [CompatibilityProtocol.Reply]) -> (CloudProvider, String) {
        let id = UUID().uuidString
        CompatibilityProtocol.register(id, replies: replies.map { .init(body: "data: " + $0.body + "\n\ndata: [DONE]\n\n") })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompatibilityProtocol.self]
        config.httpAdditionalHeaders = ["X-AgRoom-Test-Fixture": id]
        return (CloudProvider(config: .init(name: "fixture", endpoint: "https://team.invalid/v1", model: "fixture"),
                              apiKey: "fixture", session: URLSession(configuration: config)), id)
    }

    @Test("parent output limits are capped while smaller limits are preserved", arguments: [4_096, 1_048_576])
    func largeParentOutput(_ outputLimit: Int) async throws {
        let body = #"{"choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"submit","type":"function","function":{"name":"team_submit_result","arguments":"{\"summary\":\"done\",\"outcome\":\"succeeded\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":20}}"#
        let (provider, id) = fixture(replies: Array(repeating: .init(body: body), count: 3))
        defer { CompatibilityProtocol.remove(id) }
        let factory = DispatcherTeamWorkerFactory(provider: provider, agents: [Agent(name: "Researcher")],
                                                 maxOutputTokens: outputLimit)
        let ledger = ExecutionBudgetLedger(maxTokens: 120_000, maxToolCalls: 160, verificationReserve: 12_000)
        let subtasks = (1...3).map { TeamSubtask(title: "Research \($0)", objective: "Read and summarize") }
        let plan = TeamPlan(goal: "Research", subtasks: subtasks)
        try await withThrowingTaskGroup(of: TeamSubtaskResult.self) { group in
            for subtask in subtasks {
                group.addTask {
                    let worker = try await factory.makeWorker(taskID: UUID(), plan: plan, subtask: subtask,
                        inputs: [], budget: .default, budgetLedger: ledger)
                    return try await worker.run()
                }
            }
            for try await result in group {
                #expect(result.outcome == .succeeded)
                #expect(result.usage.tokens == 70)
            }
        }
        let requests = CompatibilityProtocol.requests(id)
        #expect(requests.count == 3)
        for request in requests {
            let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            #expect(body["max_tokens"] as? Int == min(outputLimit, 8_192))
        }
        #expect(await ledger.spent == 210)
        #expect(await ledger.reserved == 0)
    }

    @Test("a default team can submit and verify after passing the old cumulative limit")
    func defaultTeamCompletesLongResearch() async throws {
        let read = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"clock","type":"function","function":{"name":"get_current_time","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":83616,"completion_tokens":1641}}"#
        let submit = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"submit","type":"function","function":{"name":"team_submit_result","arguments":"{\"summary\":\"done\",\"outcome\":\"succeeded\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":34751,"completion_tokens":1000}}"#
        let (provider, id) = fixture(replies: [.init(body: read), .init(body: submit)])
        defer { CompatibilityProtocol.remove(id) }
        let factory = DispatcherTeamWorkerFactory(provider: provider, agents: [Agent(name: "Researcher")])
        let plan = TeamPlan(goal: "Research", subtasks: [TeamSubtask(title: "Research", objective: "Check the time")])
        let verifier = FixedVerifier(verification: .init(passed: true, summary: "Verified", usage: .init(tokens: 100)))
        let report = try await TeamRunTool(factory: factory, verifier: verifier).run(plan: plan, parentTaskID: nil)
        #expect(report.status == .completed)
        #expect(report.verification?.passed == true)
        #expect(report.estimatedTokens == 12_000)
        #expect(report.subtasks.first?.usage.tokens == 121_008)
        #expect(report.usage.tokens == 121_108)
        #expect(report.usage.toolCalls == 2)
        #expect(!report.artifacts.isEmpty)
        #expect(CompatibilityProtocol.requests(id).count == 2)
    }

    @Test("a later budget failure keeps completed request and tool usage in the task report")
    func failedWorkerKeepsUsage() async throws {
        let body = #"{"choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"clock","type":"function","function":{"name":"get_current_time","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":9990,"completion_tokens":1}}"#
        let (provider, id) = fixture(replies: [.init(body: body)])
        defer { CompatibilityProtocol.remove(id) }
        let factory = DispatcherTeamWorkerFactory(provider: provider, agents: [Agent(name: "Researcher")],
                                                 maxOutputTokens: 256)
        let subtask = TeamSubtask(title: "Research", objective: "Check current time", estimatedTokens: 100)
        let coordinator = TeamCoordinator(plan: TeamPlan(goal: "Research", subtasks: [subtask]),
                                          budget: TeamBudget(maxTokens: 10_000), factory: factory)
        let report = try await coordinator.run()
        #expect(report.status == .failed)
        #expect(report.usage.tokens == 9_991)
        #expect(report.usage.inputTokens == 9_990)
        #expect(report.usage.outputTokens == 1)
        #expect(report.usage.toolCalls == 1)
        #expect(report.subtasks.first?.usage.tokens == 9_991)
        #expect(report.errors.contains { $0.contains(BudgetError.tokensExhausted.localizedDescription) })
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }
}
