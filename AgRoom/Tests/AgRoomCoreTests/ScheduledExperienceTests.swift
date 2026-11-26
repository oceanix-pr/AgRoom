import Foundation
import GRDB
import Synchronization
import Testing
@testable import AgRoomCore

private final class ScheduledExperienceProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Mutex<Data>(Data())
    static let requests = Mutex(0)
    static let sequence = Mutex<[Data]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let scripted = Self.sequence.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        client?.urlProtocol(self, didLoad: scripted ?? Self.payload.withLock { $0 })
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Scheduled product lifecycle", .serialized)
@MainActor
struct ScheduledExperienceTests {
    private func queue() throws -> DatabaseQueue { let q = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(q); return q }
    private func task(change: Bool = true) -> ScheduledTask {
        .init(name: "Synthetic monitor", prompt: "Read the synthetic release version", schedule: .init(rule: .daily(hour: 9, minute: 0), timeZoneIdentifier: "UTC"),
            options: .init(notifyOnlyOnChange: change, comparisonInstructions: change ? "Compare the release version only" : ""))
    }
    private func completed(_ task: ScheduledTask, value: String, store: ScheduledRunStore) async throws -> ScheduledRun {
        var run = ScheduledRun(taskID: task.id, taskName: task.name, trigger: .manual, scheduledFor: nil, status: .running, startedAt: Date())
        try await store.insert(run)
        run.status = .succeeded; run.outputText = "Readable result"; run.finishedAt = Date()
        var details = ScheduledRunExperience(budget: task.effectiveOptions.budget)
        details.comparisonValue = value; details.definitionFingerprint = task.comparisonFingerprint
        run.experience = details
        return try await store.finish(run, task: task)
    }

    @Test("Draft receipts stay inert, reject invalid and foreign settings, and survive the ordinary conversation payload")
    func inertDraft() async throws {
        let q = try queue(), tool = ScheduledDraftTool(space: .work)
        let before = try await ScheduledTaskStore(databaseQueue: q).all()
        let args = #"{"name":"Release monitor","prompt":"Read releases","rule":"weekly","time_zone":"Asia/Shanghai","hour":9,"minute":30,"weekdays":[1,3],"comparison_instructions":"Latest version"}"#
        let text = try await tool.execute(argumentsJSON: args), draft = try ScheduledTaskDraft.read(text, space: .work)
        #expect(draft.task.effectiveOptions.notifyOnlyOnChange && draft.task.enabled)
        #expect(try await ScheduledTaskStore(databaseQueue: q).all() == before)
        #expect(throws: ScheduledExperienceError.invalidDraft) { _ = try ScheduledTaskDraft.read(text, space: .personal) }
        await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: args.replacingOccurrences(of: "9,", with: "true,")) }
        await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: args.replacingOccurrences(of: "Asia/Shanghai", with: "Invalid/Zone")) }
        await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: #"{"name":"Bad","prompt":"x","rule":"interval","time_zone":"UTC","interval_minutes":9223372036854775807}"#) }
        var message = ChatMessage(role: .assistant, content: "Draft ready")
        message.trace = [.init(toolName: "schedule_draft", argumentsPreview: args, resultPreview: text, resultFull: text, duration: 0, succeeded: true)]
        var session = ChatSession(title: "Draft conversation"); session.messages = [message]
        let service = SessionService(databaseQueue: q); try await service.save(session)
        let loaded = try #require(try await service.fetch(id: session.id)?.messages.first?.trace?.first?.resultFull)
        #expect(try ScheduledTaskDraft.read(loaded, space: .work).task == draft.task)
        let oversized: [String:Any] = ["name":"Large draft", "prompt":String(repeating: "x", count: 16_000),
            "rule":"daily", "time_zone":"UTC", "hour":9, "minute":0]
        let oversizedJSON = String(decoding: try JSONSerialization.data(withJSONObject: oversized), as: UTF8.self)
        await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: oversizedJSON) }
    }

    @Test("Change baselines are transactional, failure-safe, definition-bound and physically isolated")
    func baselines() async throws {
        let work = try queue(), personal = try queue(), t = task(), store = ScheduledRunStore(databaseQueue: work)
        try await ScheduledTaskStore(databaseQueue: work).save(t)
        let first = try await completed(t, value: "v1", store: store)
        #expect(first.experience?.comparisonState == .baseline && !ScheduledComparison.shouldNotify(first))
        let second = try await completed(t, value: " v1\n", store: store)
        #expect(second.experience?.comparisonState == .unchanged && second.experience?.baselineRunID == first.id)
        let third = try await completed(t, value: "v2", store: store)
        #expect(third.experience?.comparisonState == .changed && ScheduledComparison.shouldNotify(third))
        #expect(try await store.finish(third, task: t) == third)
        var edited = t; edited.prompt = "Read another release channel"
        #expect(try await completed(edited, value: "v2", store: store).experience?.comparisonState == .baseline)
        #expect(try await completed(t, value: "v2", store: ScheduledRunStore(databaseQueue: personal)).experience?.comparisonState == .baseline)
        try await work.write { db in try db.execute(sql: "CREATE TRIGGER reject_scheduled_finish BEFORE UPDATE ON scheduled_runs WHEN NEW.status='succeeded' BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        do { _ = try await completed(t, value: "v3", store: store); Issue.record("Expected receipt failure") } catch {}
        try await work.write { try $0.execute(sql: "DROP TRIGGER reject_scheduled_finish") }
        let retry = try #require(try await store.activeRun(taskID: t.id))
        var receipt = retry; receipt.status = .succeeded; receipt.outputText = "Readable result"; receipt.finishedAt = Date()
        var details = ScheduledRunExperience(budget: t.effectiveOptions.budget); details.comparisonValue = "v3"; details.definitionFingerprint = t.comparisonFingerprint
        receipt.experience = details
        let stored = try await store.finish(receipt, task: t)
        #expect(stored.experience?.comparisonState == .changed && stored.experience?.baselineRunID == third.id)
    }

    @Test("Legacy definitions and runs keep safe defaults while new options survive database and JSON round trips")
    func persistence() async throws {
        let q = try queue(), store = ScheduledTaskStore(databaseQueue: q), t = task()
        try await store.save(t)
        #expect(try await store.task(id: t.id)?.options == t.options)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String:Any]); object.removeValue(forKey: "options")
        let old = try JSONDecoder().decode(ScheduledTask.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.options == nil && old.effectiveOptions.budget.isValid)
        #expect(ScheduledTaskSchedule(rule: .interval(minutes: Int.max, anchor: Date())).validate() == .intervalTooLong)
        #expect(ScheduleCalculator.nextFireDate(for: .init(rule: .interval(minutes: Int.max, anchor: Date())), after: Date()) == nil)
        try await q.write { db in try db.execute(sql: "UPDATE scheduled_tasks SET optionsJSON='invalid' WHERE id=?", arguments: [t.id.uuidString]) }
        #expect(try await store.task(id: t.id) == nil)
        let isolated = SpaceStore(space: .work, databaseQueue: q)
        #expect(isolated.queue(for: .personal) == nil)
    }

    private func provider(text: String, usage: Bool) throws -> CloudProvider {
        let delta: [String:Any] = ["choices":[["index":0,"delta":["content":text],"finish_reason":"stop"]]]
        let parts = [delta] + (usage ? [["choices":[],"usage":["prompt_tokens":0,"completion_tokens":0]]] : [])
        let sse = try parts.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined() + "data: [DONE]\n\n"
        ScheduledExperienceProtocol.payload.withLock { $0 = Data(sse.utf8) }; ScheduledExperienceProtocol.requests.withLock { $0 = 0 }
        ScheduledExperienceProtocol.sequence.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ScheduledExperienceProtocol.self]
        return CloudProvider(config: .init(name: "Schedule fixture", endpoint: "https://schedule.invalid/v1", model: "fixture"), apiKey: "", session: URLSession(configuration: configuration))
    }

    @Test("Budget exhaustion retains successful reads and cannot be reported as a successful scheduled task", arguments: [false,true])
    func exhaustedBudget(_ tokenBudget: Bool) async throws {
        let q = try queue(), p = try provider(text: "Partial final answer", usage: true)
        let calls: [[String:Any]] = (0..<(tokenBudget ? 1 : 2)).map { ["index":$0,"id":"read-\($0)","type":"function","function":["name":"get_current_time","arguments":"{}"]] }
        let first: [String:Any] = ["choices":[["index":0,"delta":["tool_calls":calls],"finish_reason":"tool_calls"]],
            "usage":["prompt_tokens":tokenBudget ? 900 : 20,"completion_tokens":tokenBudget ? 100 : 10]]
        let frame = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: first), as: UTF8.self) + "\n\ndata: [DONE]\n\n"
        ScheduledExperienceProtocol.sequence.withLock { $0 = [Data(frame.utf8)] }
        var t = task(change: false); t.options?.budget = .init(maxTokens: tokenBudget ? 1_000 : 100_000, maxToolCalls: 1)
        let result = await ScheduledRunner.run(spaceStore: SpaceStore(space: .work, databaseQueue: q), space: .work, task: t,
            scheduledFor: nil, settings: .init(maxTokens: 256, temperature: 0, reasoningEffortRaw: nil, maxSteps: 4,
                replyLanguageInstruction: "English", personaInstruction: nil, workspacePath: ""), runID: UUID(), makeEngine: { settings,_ in
                let ledger = ExecutionBudgetLedger(maxTokens: settings.taskBudget!.maxTokens, maxToolCalls: 1, deadline: settings.taskBudget?.deadline)
                return DispatcherEngine(provider: p, tools: [CurrentTimeTool()], systemPrompt: "Synthetic task", config: .init(maxTokens: 256), budgetLedger: ledger)
            })
        #expect(result.status == .failed && result.errorCode == (tokenBudget ? "budget_tokens" : "budget_tools"))
        #expect(result.toolCallCount == 1 && result.outputText?.contains("get_current_time") == true)
        #expect(result.experience?.usageKnown == true)
    }

    @Test("Re-enabling skips disabled occurrences without deleting history or allowing an insert to overwrite an existing task")
    func enablingAndDuplicateDraft() async throws {
        let q = try queue(), store = ScheduledTaskStore(databaseQueue: q)
        let now = Date(), t = ScheduledTask(name: "Expired once", prompt: "Synthetic", schedule: .init(rule: .once(now.addingTimeInterval(-60)), timeZoneIdentifier: "UTC"), nextFireAt: now.addingTimeInterval(-60))
        try await store.insert(t)
        var replacement = t; replacement.prompt = "Must not overwrite"
        await #expect(throws: (any Error).self) { try await store.insert(replacement) }
        #expect(try await store.task(id: t.id)?.prompt == t.prompt)
        try await store.resumeFromNow(now)
        #expect(try await store.task(id: t.id)?.enabled == false)
        #expect(try await store.task(id: t.id)?.nextFireAt == nil)
        await #expect(throws: ScheduledTaskValidationError.onceInPast) { try await store.setEnabled(id: t.id, enabled: true, recalculateAt: now) }
        var monitored = task(); let old = monitored.comparisonFingerprint
        monitored.options?.notifyOnlyOnChange = false; monitored.options?.notifyOnlyOnChange = true
        #expect(monitored.comparisonFingerprint != old)
    }

    @Test("The runner enforces task budgets, preserves unknown versus actual zero usage, and requires structured observations", arguments: [false,true])
    func runnerUsage(_ known: Bool) async throws {
        let q = try queue(), provider = try provider(text: #"{"comparison_value":"v1","result":"Synthetic result"}"#, usage: known), t = task()
        let result = await ScheduledRunner.run(spaceStore: SpaceStore(space: .work, databaseQueue: q), space: .work, task: t,
            scheduledFor: nil, settings: .init(maxTokens: 256, temperature: 0, reasoningEffortRaw: nil, maxSteps: 4, replyLanguageInstruction: "English", personaInstruction: nil, workspacePath: ""), runID: UUID(), makeEngine: { settings, context in
                #expect(settings.permissionMode == .readOnly && settings.taskBudget?.maxTokens == t.effectiveOptions.budget.maxTokens)
                #expect(context.comparisonInstructions == t.effectiveOptions.comparisonInstructions)
                let ledger = ExecutionBudgetLedger(maxTokens: settings.taskBudget!.maxTokens, maxToolCalls: settings.taskBudget!.maxToolCalls, deadline: settings.taskBudget?.deadline)
                return DispatcherEngine(provider: provider, tools: [], systemPrompt: "Synthetic read-only task", config: .init(maxTokens: 256), budgetLedger: ledger)
            })
        #expect(result.status == .succeeded && result.outputText == "Synthetic result")
        #expect(result.experience?.usageKnown == known && result.inputTokens == 0 && result.outputTokens == 0)
        #expect(known ? result.experience?.budgetSpentTokens == 0 : (result.experience?.budgetSpentTokens ?? 0) > 0)
        #expect(result.experience?.comparisonValue == "v1")
    }

    @Test("Preparation is included in the task deadline and invalid comparison prose cannot establish a baseline")
    func runnerFailure() async throws {
        let q = try queue(); var t = task(); t.options?.budget.seconds = 1
        let expired = await ScheduledRunner.run(spaceStore: SpaceStore(space: .work, databaseQueue: q), space: .work, task: t,
            scheduledFor: nil, settings: .init(maxTokens: 256, temperature: 0, reasoningEffortRaw: nil, maxSteps: 4, replyLanguageInstruction: "English", personaInstruction: nil, workspacePath: ""), runID: UUID(), makeEngine: { _,_ in try await Task.sleep(for: .seconds(20)); return DispatcherEngine(tools: [], systemPrompt: "Never used") })
        #expect(expired.status == .failed && expired.errorCode == "budget_time" && expired.experience?.usageKnown == false)
        let p = try provider(text: "Unstructured prose", usage: true)
        let invalid = await ScheduledRunner.run(spaceStore: SpaceStore(space: .work, databaseQueue: q), space: .work, task: task(),
            scheduledFor: nil, settings: .init(maxTokens: 256, temperature: 0, reasoningEffortRaw: nil, maxSteps: 4, replyLanguageInstruction: "English", personaInstruction: nil, workspacePath: ""), runID: UUID(), makeEngine: { _,_ in DispatcherEngine(provider: p, tools: [], systemPrompt: "Synthetic task") })
        #expect(invalid.status == .failed && invalid.errorCode == "comparison_unavailable" && invalid.experience?.comparisonState == .unavailable)
        #expect(invalid.outputText == "Unstructured prose")
    }

    @Test("Oversized multilingual output retains valid UTF-8 and explicitly marks its excerpt")
    func boundedResult() async throws {
        let q = try queue(), original = String(repeating: "资料🙂", count: 12_000)
        let p = try provider(text: original, usage: true), t = task(change: false)
        let result = await ScheduledRunner.run(spaceStore: SpaceStore(space: .work, databaseQueue: q), space: .work, task: t,
            scheduledFor: nil, settings: .init(maxTokens: 256, temperature: 0, reasoningEffortRaw: nil, maxSteps: 4,
                replyLanguageInstruction: "English", personaInstruction: nil, workspacePath: ""), runID: UUID(), makeEngine: { _,_ in
                DispatcherEngine(provider: p, tools: [], systemPrompt: "Synthetic task")
            })
        let output = try #require(result.outputText)
        #expect(result.status == .succeeded && result.experience?.outputTruncated == true)
        #expect(output.utf8.count <= ScheduledCapabilityProfile.outputTextLimit && original.hasPrefix(output))
        #expect(String(data: Data(output.utf8), encoding: .utf8) == output && !output.contains("�"))
    }
}
