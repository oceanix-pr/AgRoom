import Foundation
import GRDB
import Testing
import SwiftUI
import AppKit
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Space-bound model usage receipts")
struct UsageTests {
    @Test("Request provenance survives upgrade and backup without retaining content")
    func requestMetadataMigration() async throws {
        let queue = try queue(), service = UsageService(databaseQueue: queue)
        let oldID = UUID()
        try await service.begin(id: oldID, providerID: UUID(), model: "fixture", source: "test", sessionID: nil)
        try await queue.write { db in
            try db.execute(sql: "ALTER TABLE provider_usage DROP COLUMN requestContextJSON")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4_provider_usage_request_context'")
        }
        try DatabaseBootstrap.prepareSpace(queue)
        #expect(try await service.exportRecords().first?.request == nil)
        let secret = "do-not-retain-private-source"
        let messages: [EngineMessage] = [.init(role: .system, text: "rules"), .init(role: .user, text: secret),
            .init(role: .assistant, text: "", toolCalls: [.init(id: "read", name: "files_read_range", argumentsJSON: "{}")]),
            .init(role: .toolResult, text: String(repeating: secret, count: 30), toolCallId: "read")]
        let estimate = TokenEstimator.breakdown(messages: messages, tools: [], historyMessageCount: 1)
        #expect(estimate.history > 0 && estimate.sourceEvidence > 0)
        #expect(estimate.total == TokenEstimator.estimate(messages: messages))
        let context = ProviderRequestMetadata(runID: UUID(), parentRunID: UUID(), purpose: .worker, estimate: estimate)
        let recorder = ProviderUsageRecorder(service: service, source: "test")
        let id = await ProviderRequestContext.$current.withValue(context) {
            await recorder.begin(providerID: UUID(), model: "fixture")
        }
        await recorder.finish(id: id, input: 10, output: 2, status: "failed")
        let records = try await service.exportRecords()
        let data = try JSONEncoder().encode(records)
        #expect(!String(decoding: data, as: UTF8.self).contains(secret))
        let other = UsageService(databaseQueue: try self.queue())
        try await other.importRecords(JSONDecoder().decode([ProviderUsageRecord].self, from: data))
        #expect(try await other.exportRecords().first { $0.id == id.uuidString }?.request == context)
        #expect(try await other.exportRecords().first { $0.id == oldID.uuidString }?.request == nil)
    }

    private func queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return queue
    }

    @Test("Request dates survive session edits/deletion, and missing counts remain explicit")
    func durableRequestStats() async throws {
        let queue = try queue(), other = try self.queue()
        let service = UsageService(databaseQueue: queue), sessions = SessionService(databaseQueue: queue)
        var session = ChatSession(title: "Synthetic receipt")
        try await sessions.save(session)
        let date = Date(timeIntervalSince1970: 1_700_000_000), provider = UUID(), first = UUID(), second = UUID()
        try await service.begin(id: first, providerID: provider, model: "test", source: "chat", sessionID: session.id, at: date)
        try await service.finish(id: first, input: 123, output: 45, status: "succeeded")
        try await service.finish(id: first, input: 999, output: 999, status: "succeeded")
        try await service.begin(id: second, providerID: provider, model: "test", source: "chat", sessionID: session.id, at: date)
        try await service.finish(id: second, input: nil, output: nil, status: "cancelled")
        session.title = "Updated later"; session.updatedAt = date.addingTimeInterval(86_400 * 20)
        try await sessions.save(session)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let stats = try await service.getStats(calendar: calendar)
        #expect(stats.totalTokens == 168 && stats.totalRequests == 2)
        #expect(stats.unreportedRequests == 1 && stats.failedRequests == 1)
        #expect(stats.byDay["2023-11-14"]?.input == 123)
        #expect(stats.byDay.count == 1)
        try await sessions.delete(id: session.id)
        #expect(try await service.getStats().totalTokens == 168)
        #expect(try await UsageService(databaseQueue: other).getStats().totalTokens == 0)
    }

    @Test("Upgrade counts all saved variations once on their original message day")
    func legacyBaseline() async throws {
        let queue = try queue(), sessions = SessionService(databaseQueue: queue)
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        var message = ChatMessage(role: .assistant, content: "new", timestamp: original, inputTokens: 30, outputTokens: 40)
        message.variations = [AnswerVariation(question: "old", content: "old", inputTokens: 10, outputTokens: 20),
                              AnswerVariation(question: "new", content: "new", inputTokens: 30, outputTokens: 40)]
        var session = ChatSession(title: "History"); session.messages = [message]
        session.updatedAt = original.addingTimeInterval(86_400 * 10)
        try await sessions.save(session)
        try await queue.write { db in
            try db.drop(table: "provider_usage")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v1_provider_usage'")
        }
        try DatabaseBootstrap.prepareSpace(queue)
        try DatabaseBootstrap.prepareSpace(queue)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let stats = try await UsageService(databaseQueue: queue).getStats(calendar: calendar)
        #expect(stats.totalInputTokens == 40 && stats.totalOutputTokens == 60)
        #expect(stats.legacyTurns == 2 && stats.totalRequests == 0)
        #expect(stats.byDay["2023-11-14"]?.turns == 2)
        #expect(stats.byDay.count == 1)
    }

    @Test("An incomplete stream preserves usage already reported by the provider")
    func interruptedStream() async throws {
        let queue = try queue(), service = UsageService(databaseQueue: queue)
        let config = LLMProviderConfig(name: "Usage test", endpoint: "http://localhost/interrupted", model: "usage-test")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UsageReceiptProtocol.self]
        let provider = CloudProvider(config: config, apiKey: "synthetic", session: URLSession(configuration: configuration),
            usageRecorder: ProviderUsageRecorder(service: service, source: "test"))
        await #expect(throws: LLMError.self) {
            _ = try await provider.chatStream(messages: [.init(role: .user, text: "synthetic")], tools: [], config: .default) { _ in }
        }
        let stats = try await service.getStats()
        #expect(stats.totalRequests == 1 && stats.failedRequests == 1)
        #expect(stats.totalInputTokens == 13 && stats.totalOutputTokens == 2)
        let ledger = ExecutionBudgetLedger(maxTokens: 10_000, maxToolCalls: 2)
        let engine = DispatcherEngine(provider: provider, tools: [], systemPrompt: "Synthetic", budgetLedger: ledger)
        await #expect(throws: LLMError.self) { _ = try await engine.run(userMessage: "Synthetic", history: []) }
        // No visible delta was delivered, so the bounded retry path makes three attempts.
        #expect(engine.requestReport.requestCount == 3)
        #expect(engine.takeSnapshot().totalInputTokens == 39)
        #expect(engine.takeSnapshot().totalOutputTokens == 6)
        #expect(await ledger.spent == 45)
        #expect(await ledger.reserved == 0)
    }

    @Test("Actual provider attempts count adaptation retries and provider token reports")
    func providerRetries() async throws {
        let queue = try queue(), service = UsageService(databaseQueue: queue)
        let recorder = ProviderUsageRecorder(service: service, source: "test")
        let config = LLMProviderConfig(name: "Usage test", endpoint: "http://localhost/usage", model: "usage-test")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UsageReceiptProtocol.self]
        let provider = CloudProvider(config: config, apiKey: "synthetic", session: URLSession(configuration: configuration), usageRecorder: recorder)
        let reply = try await provider.chat(messages: [.init(role: .user, text: "synthetic")], tools: [],
                                            config: LLMConfig(modelName: "usage-test", maxTokens: 4096, temperature: 0))
        #expect(reply.text == "ok")
        let stats = try await service.getStats()
        #expect(stats.totalRequests == 2 && stats.failedRequests == 1)
        #expect(stats.unreportedRequests == 1 && stats.totalTokens == 24)
        #expect(stats.totalCacheReadTokens == 10)
        let receipts = try await service.getRecords()
        #expect(receipts.first(where: { $0.status == "succeeded" })?.usage.reportedModel == "actual-usage-model")
        #expect(stats.bySession.first?.id == "auxiliary")
        #expect(CloudProvider.usageCounts(["input_tokens": 5, "cache_read_input_tokens": 10,
            "cache_creation_input_tokens": 20, "output_tokens": 3], anthropic: true).input == 35)
    }
}

@Suite("Reported reasoning usage")
struct ReasoningUsageTests {
    static func engine(_ path: String, tools: Bool = false) -> DispatcherEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReasoningUsageProtocol.self]
        let provider = CloudProvider(config: .init(name: "Synthetic", endpoint: "https://reasoning.invalid/" + path, model: "fixture"),
            apiKey: "synthetic", session: URLSession(configuration: configuration))
        return DispatcherEngine(provider: provider, tools: tools ? [ThoughtFixtureTool()] : [], systemPrompt: "Synthetic", maxSteps: 3)
    }

    @Test("Tool rounds use provider reasoning counts and retain one ordered thought transcript")
    func toolRounds() async throws {
        let engine = Self.engine("tools", tools: true)
        let outcome = try await engine.run(userMessage: "Synthetic", history: [])
        guard case .finished(_, let thoughts, _, _, _, _, _) = outcome else {
            Issue.record("Expected a finished answer"); return
        }
        #expect(thoughts == ["计划", "先读取", "核对"])
        let usage = engine.reasoningUsageSnapshot
        #expect(usage.reportedTokens == 400 && usage.isComplete && usage.requestCount == 2)
        #expect(TokenEstimator.estimate(thoughts.joined()) != usage.reportedTokens)
        let snapshot = try JSONDecoder().decode(EngineRunSnapshot.self, from: JSONEncoder().encode(engine.takeSnapshot()))
        #expect(snapshot.reasoningTokenUsage == usage && snapshot.thoughts == thoughts)

        // Resume adds a request to the existing usage rather than resetting it.
        let resumed = Self.engine("hidden")
        _ = try await resumed.run(fromSnapshot: snapshot)
        #expect(resumed.reasoningUsageSnapshot.reportedTokens == 960)
        #expect(resumed.reasoningUsageSnapshot.requestCount == 3)
    }

    @Test("Missing, partial, zero and hidden reasoning stay distinct", arguments: ["missing", "partial", "zero", "hidden", "interrupted"])
    func reportCoverage(_ path: String) async throws {
        let engine = Self.engine(path, tools: path == "partial")
        if path == "interrupted" {
            await #expect(throws: LLMError.self) { _ = try await engine.run(userMessage: "Synthetic", history: []) }
        } else {
            _ = try await engine.run(userMessage: "Synthetic", history: [])
        }
        let usage = engine.reasoningUsageSnapshot
        switch path {
        case "missing": #expect(usage.reportedTokens == nil && usage.unreportedRequests == 1 && !usage.isComplete)
        case "partial": #expect(usage.reportedTokens == 120 && usage.unreportedRequests == 1 && !usage.isComplete)
        case "zero": #expect(usage.reportedTokens == 0 && usage.isComplete)
        default: #expect(usage.reportedTokens == 560 && usage.isComplete)
        }
        if path == "hidden" { #expect(engine.takeSnapshot().thoughts.isEmpty) }
    }

    @Test("Legacy messages and snapshots keep unknown reasoning usage")
    func legacyDecoding() async throws {
        let message = ChatMessage(role: .assistant, content: "Legacy", thoughts: "Short narration")
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(restored.reasoningTokenUsage == nil)
        let engine = Self.engine("tools", tools: true)
        _ = try await engine.run(userMessage: "Synthetic", history: [])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.takeSnapshot())) as? [String: Any])
        json.removeValue(forKey: "reasoningTokenUsage")
        let legacy = try JSONDecoder().decode(EngineRunSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.reasoningTokenUsage == nil)
        let resumed = Self.engine("hidden")
        _ = try await resumed.run(fromSnapshot: legacy)
        #expect(resumed.reasoningUsageSnapshot.reportedTokens == 560 && !resumed.reasoningUsageSnapshot.isComplete)
    }

    private struct ThoughtFixtureTool: DispatcherTool {
        var definition: ToolDefinition { .init(name: "thought_fixture", description: "Synthetic read", parametersSchemaJSON: #"{"type":"object","properties":{}}"#) }
        var requiresConfirmation: Bool { false }
        func execute(argumentsJSON: String) async throws -> String { "Synthetic result" }
    }
}

@MainActor @Suite("Conversation reasoning usage", .serialized)
struct ChatReasoningUsageTests {
    @Test("Completion, retry and version switching preserve the correct transcript and reasoning report")
    func chatLifecycle() async throws {
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thinking-chat-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"), fileAreaService: FileAreaService(baseDirectory: root.appendingPathComponent("files")))
        var builds = 0
        let model = ChatViewModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: db)), space: .work,
            workspaceRegistry: registry, observeHostServices: false,
            handoffStore: DaemonHandoffStore(baseDirectory: root.appendingPathComponent("daemon")), draftDefaults: nil, makeEngine: { _ in
                builds += 1
                return ReasoningUsageTests.engine(builds == 1 ? "tools" : "hidden", tools: builds == 1)
            })
        await model.load()
        model.newSession()
        let sessionID = try #require(model.activeSessionId)
        let index = try #require(model.sessions.firstIndex { $0.id == sessionID })
        model.sessions[index].title = "Synthetic reasoning"
        model.inputText = "Synthetic request"
        model.send()
        try await waitForRun(model)
        let first = try #require(model.session(id: sessionID)?.messages.last)
        #expect(first.thoughts == "计划\n\n先读取\n\n核对")
        #expect(first.reasoningTokenUsage?.reportedTokens == 400)
        model.retryAnswer(messageId: first.id)
        try await waitForRun(model)
        let retry = try #require(model.session(id: sessionID)?.messages.last)
        #expect(retry.thoughts == nil && retry.reasoningTokenUsage?.reportedTokens == 560)
        model.switchVariation(messageId: first.id, to: 0)
        #expect(model.session(id: sessionID)?.messages.last?.thoughts == first.thoughts)
        #expect(model.session(id: sessionID)?.messages.last?.reasoningTokenUsage == first.reasoningTokenUsage)
        let saved = try #require(try await SessionService(databaseQueue: db).latestMessage(id: sessionID))
        #expect(saved.variations?.first?.reasoningTokenUsage == first.reasoningTokenUsage)
        #expect(saved.appendingError("Synthetic failure").reasoningTokenUsage == saved.reasoningTokenUsage)
    }

    private func waitForRun(_ model: ChatViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isAnyRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isAnyRunning && model.errorMessage == nil, Comment(rawValue: model.errorMessage ?? ""))
    }

    @Test("Late and concurrent-session reports cannot overwrite another run")
    func runIsolation() throws {
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thinking-isolation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"), fileAreaService: FileAreaService(baseDirectory: root))
        let model = ChatViewModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: db)), space: .work,
            workspaceRegistry: registry, observeHostServices: false,
            handoffStore: DaemonHandoffStore(baseDirectory: root.appendingPathComponent("daemon")), draftDefaults: nil)
        let firstMessage = ChatMessage(role: .assistant, content: ""), otherMessage = ChatMessage(role: .assistant, content: "")
        var first = ChatSession(), other = ChatSession()
        first.messages = [firstMessage]; other.messages = [otherMessage]
        model.sessions = [first, other]
        let run = ChatRunContext(space: .work, sessionID: first.id, messageID: firstMessage.id)
        let otherRun = ChatRunContext(space: .work, sessionID: other.id, messageID: otherMessage.id)
        model.beginRun(run); model.beginRun(otherRun)
        var initial = ReasoningTokenUsage(); initial.record(120)
        var updated = initial; updated.record(280)
        model.handleReasoningUsage(updated, runID: run.id)
        model.handleReasoningUsage(initial, runID: run.id)
        #expect(model.sessions[0].messages[0].reasoningTokenUsage == updated)
        #expect(model.sessions[1].messages[0].reasoningTokenUsage == nil)
        model.finishRun(run: run)
        model.handleReasoningUsage(updated, runID: otherRun.id)
        model.handleReasoningUsage(initial, runID: run.id)
        #expect(model.sessions[0].messages[0].reasoningTokenUsage == updated)
        #expect(model.sessions[1].messages[0].reasoningTokenUsage == updated)
        model.finishRun(run: otherRun)
    }

}

private final class ReasoningUsageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "reasoning.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        let path = request.url?.path ?? ""
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let hasResult = (json?["messages"] as? [[String: Any]])?.contains { $0["role"] as? String == "tool" } == true
        let toolRound = (path == "/tools" || path == "/partial") && !hasResult
        var rows: [String] = []
        if toolRound {
            rows = [
                #"{"choices":[{"delta":{"reasoning_content":"计划"}}]}"#,
                #"{"choices":[{"delta":{"content":"先读取","tool_calls":[{"index":0,"id":"t","function":{"name":"thought_fixture","arguments":"{}"}}]}}]}"#,
                #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":500,"completion_tokens_details":{"reasoning_tokens":80}}}"#,
                #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":100,"completion_tokens":500,"completion_tokens_details":{"reasoning_tokens":120}}}"#
            ]
        } else {
            if path != "/hidden" && path != "/zero" { rows.append(#"{"choices":[{"delta":{"reasoning_content":"核对"}}]}"#) }
            if path != "/interrupted" { rows.append(#"{"choices":[{"delta":{"content":"Synthetic answer"}}]}"#) }
            let tokens = path == "/tools" ? 280 : (path == "/zero" ? 0 : 560)
            let details = ["/missing", "/partial"].contains(path) ? "" : ",\"completion_tokens_details\":{\"reasoning_tokens\":\(tokens)}"
            rows.append("{\"choices\":[],\"usage\":{\"prompt_tokens\":200,\"completion_tokens\":700\(details)}}")
            if path != "/interrupted" { rows.append(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#) }
        }
        if path != "/interrupted" { rows.append("[DONE]") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(rows.map { "data: " + $0 + "\n\n" }.joined().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Observed generation speed")
struct GenerationRateTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [StreamGenerationEvent] = []
        func append(_ event: StreamGenerationEvent) { lock.withLock { values.append(event) } }
        var all: [StreamGenerationEvent] { lock.withLock { values } }
    }

    @Test("Stream timing excludes first-token wait and preserves token estimates across tiny fragments")
    func timingAndEstimates() throws {
        let events = Events(), start = ContinuousClock.now
        let tracker = StreamGenerationTracker(onMetrics: events.append)
        tracker.observe("a", at: start)
        tracker.observe("b", at: start.advanced(by: .milliseconds(100)))
        tracker.observe("cd推理", at: start.advanced(by: .seconds(1)))
        tracker.finish(outputTokens: 20)
        let snapshots = events.all
        #expect(snapshots.count == 4) // start, first sample, throttled update, finish
        #expect(snapshots[2].estimatedOutputTokens == TokenEstimator.estimate("abcd推理"))
        #expect(snapshots[2].rate?.isEstimated == true)
        let final = try #require(snapshots.last?.rate)
        #expect(final.tokensPerSecond == 20 && final.seconds == 1 && !final.isEstimated)
        tracker.observe("late", at: start.advanced(by: .seconds(2))); tracker.finish(outputTokens: 99)
        #expect(events.all.count == snapshots.count)
    }

    @Test("Multiple requests use a duration-weighted average, with unknown usage explicitly estimated")
    func weightedAverage() throws {
        var accumulator = GenerationMetricsAccumulator()
        let first = UUID(), second = UUID()
        accumulator.accept(.init(requestID: first, phase: .finished, estimatedOutputTokens: 20, reportedOutputTokens: 100, seconds: 2, samples: 2))
        accumulator.accept(.init(requestID: second, phase: .started, estimatedOutputTokens: 0, reportedOutputTokens: nil, seconds: 0, samples: 0))
        #expect(accumulator.snapshot.current == nil)
        accumulator.accept(.init(requestID: second, phase: .finished, estimatedOutputTokens: 20, reportedOutputTokens: nil, seconds: 8, samples: 2))
        let rate = try #require(accumulator.snapshot.average)
        #expect(rate.tokensPerSecond == 12 && rate.isEstimated)
        accumulator.accept(.init(requestID: second, phase: .finished, estimatedOutputTokens: 20, reportedOutputTokens: nil, seconds: 8, samples: 2))
        #expect(accumulator.snapshot.average == rate)
        let single = StreamGenerationEvent(requestID: UUID(), phase: .finished, estimatedOutputTokens: 40, reportedOutputTokens: 40, seconds: 0, samples: 1)
        #expect(single.rate == nil)
    }

    @Test("Both SSE protocols count reasoning and tool parameters; an interrupted stream still ends its meter")
    func providerEvents() async throws {
        for (endpoint, interrupted) in [("https://generation.invalid/v1/chat/completions", false),
                                        ("https://api.anthropic.com/generation-fixture/messages", false),
                                        ("https://generation.invalid/interrupted", true)] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GenerationRateProtocol.self]
            let provider = CloudProvider(config: .init(name: "Synthetic", endpoint: endpoint, model: "fixture"),
                apiKey: "synthetic", session: URLSession(configuration: configuration))
            let events = Events()
            do {
                _ = try await provider.chatStream(messages: [.init(role: .user, text: "fixture")], tools: [], config: .default,
                    onGenerationMetrics: events.append, onDelta: { _ in })
                #expect(!interrupted)
            } catch { #expect(interrupted && error is LLMError) }
            let last = try #require(events.all.last)
            #expect(last.phase == .finished && last.samples == 3)
            #expect(last.estimatedOutputTokens == TokenEstimator.estimate("想答{\"x\":1}"))
            #expect(last.reportedOutputTokens == 30)
        }
    }

    @Test("Engine metering is opt-in and its final snapshot survives asynchronous UI delivery")
    func engineMetrics() async throws {
        for observed in [false, true] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GenerationRateProtocol.self]
            let provider = CloudProvider(config: .init(name: "Synthetic", endpoint: "https://generation.invalid/engine", model: "fixture"),
                apiKey: "synthetic", session: URLSession(configuration: configuration))
            let engine = DispatcherEngine(provider: provider, tools: [], systemPrompt: "Synthetic", maxSteps: 1)
            if observed { engine.onGenerationMetrics = { _ in } }
            _ = try await engine.run(userMessage: "Synthetic", history: [])
            #expect(observed ? engine.generationMetricsSnapshot.revision >= 3 : engine.generationMetricsSnapshot.revision == 0)
            #expect(engine.generationMetricsSnapshot.current == nil)
        }
    }
}

@MainActor @Suite("Conversation generation speed isolation")
struct ChatGenerationRateTests {
    @Test("Concurrent sessions, suspended runs and late events keep their own generation speed")
    func runIsolation() throws {
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generation-isolation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"), fileAreaService: FileAreaService(baseDirectory: root))
        let model = ChatViewModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: db)), space: .work,
            workspaceRegistry: registry, observeHostServices: false,
            handoffStore: DaemonHandoffStore(baseDirectory: root.appendingPathComponent("daemon")), draftDefaults: nil)
        let first = ChatRunContext(space: .work, sessionID: UUID(), messageID: UUID())
        let other = ChatRunContext(space: .work, sessionID: UUID(), messageID: UUID())
        let rate = TokenGenerationRate(outputTokens: 100, seconds: 2, isEstimated: true)
        model.beginRun(first); model.beginRun(other)
        defer { model.finishRun(run: first); model.finishRun(run: other) }
        model.handleGenerationMetrics(.init(revision: 2, current: rate, average: nil), runID: first.id)
        model.handleGenerationMetrics(.init(revision: 1, current: nil, average: nil), runID: first.id)
        #expect(model.generationRate(for: first.sessionID)?.rate == rate)
        #expect(model.generationRate(for: other.sessionID) == nil)
        model.suspendRun(run: first)
        #expect(model.generationRate(for: first.sessionID) == nil)
        model.handleGenerationMetrics(.init(revision: 2, current: rate, average: nil), runID: other.id)
        model.beginRun(first)
        model.handleGenerationMetrics(.init(revision: 3, current: nil, average: rate), runID: first.id)
        model.finishRun(run: first)
        #expect(model.generationRate(for: first.sessionID)?.isAverage == true)
        let replacement = ChatRunContext(space: .work, sessionID: first.sessionID, messageID: UUID())
        model.beginRun(replacement)
        defer { model.finishRun(run: replacement) }
        model.handleGenerationMetrics(.init(revision: 99, current: rate, average: rate), runID: first.id)
        model.finishRun(run: first)
        #expect(model.generationRate(for: replacement.sessionID) == nil)
        #expect(model.isCurrentRun(replacement))
        #expect(model.generationRate(for: other.sessionID)?.rate == rate)
    }
}

private final class GenerationRateProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "generation.invalid" || request.url?.path == "/generation-fixture/messages"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let anthropic = request.url?.host == "api.anthropic.com"
        let rows: [String]
        if request.url?.path == "/engine" {
            rows = [
                #"{"choices":[{"delta":{"content":"Synthetic answer"}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#,
                "[DONE]"
            ]
        } else if anthropic {
            rows = [
                #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"想"}}"#,
                #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"答"}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"fixture"}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"x\":1}"}}"#,
                #"{"type":"message_delta","usage":{"output_tokens":30},"delta":{"stop_reason":"tool_use"}}"#,
                #"{"type":"message_stop"}"#
            ]
        } else {
            rows = [
                #"{"choices":[{"delta":{"reasoning_content":"想"}}]}"#,
                #"{"choices":[{"delta":{"content":"答"}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t","function":{"name":"fixture","arguments":"{\"x\":1}"}}]}}]}"#,
                #"{"choices":[],"usage":{"completion_tokens":30}}"#
            ] + (request.url?.path == "/interrupted" ? [] : ["[DONE]"])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(rows.map { "data: " + $0 + "\n\n" }.joined().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UsageReceiptProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/interrupted" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: {\"usage\":{\"prompt_tokens\":13,\"completion_tokens\":2},\"choices\":[]}\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let retry = (body?["max_tokens"] as? Int ?? 0) <= 1024
        let status = retry ? 200 : 400
        let payload = retry
            ? #"{"model":"actual-usage-model","choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":17,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":10,"cache_write_tokens":0}}}"#
            : #"{"error":{"message":"the valid range of max_tokens is [1, 1024]"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Usage dashboard queries")
struct UsageDashboardQueryTests {
    @Test("Charts cover the full selected interval and retain totals when calendar days are grouped")
    func chartRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 1)))
        var stats = UsageStats()
        stats.byDay = ["2026-01-01": (input: 100, output: 10, turns: 1), "2026-03-08": (input: 50, output: 20, turns: 1),
                       "2026-03-31": (input: 30, output: 5, turns: 1), "2026-04-01": (input: 1000, output: 100, turns: 1)]
        let buckets = UsageChartData.trend(stats, interval: DateInterval(start: start, end: end), now: end, calendar: calendar)
        #expect(buckets.count <= 60 && buckets.count > 1)
        #expect(buckets.first?.start == start && buckets.last?.end == end)
        #expect(buckets.reduce(0) { $0 + $1.input + $1.output } == 215)
        let today = UsageChartData.trend(UsageStats(), interval: nil, now: start, calendar: calendar)
        #expect(today.count == 1 && today[0].input == 0 && today[0].output == 0)
        #expect(UsageChartData.trend(stats, interval: DateInterval(start: end, duration: 86400), now: start, calendar: calendar).isEmpty)
    }
    private func queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return queue
    }

    @Test("Every aggregate uses request start dates with an exclusive end, including legacy and unknown counts")
    func dateRangeAndCoverage() async throws {
        let queue = try queue(), service = UsageService(databaseQueue: queue)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = DateInterval(start: start, duration: 86_400)
        let provider = UUID().uuidString
        let records = [
            receipt("known", at: start, provider: provider, usage: .init(input: 100, output: 20, cacheRead: 0, cacheWrite: 0, reportedModel: "flash")),
            receipt("failed", at: start.addingTimeInterval(300), provider: provider, status: "failed"),
            receipt("cancelled", at: interval.end.addingTimeInterval(-1), provider: provider, status: "cancelled", usage: .init(input: 50, cacheRead: 0)),
            receipt("before", at: start.addingTimeInterval(-1), provider: provider, usage: .init(input: 900, output: 900)),
            receipt("at-end", at: interval.end, provider: provider, usage: .init(input: 1000, output: 1000)),
            receipt("legacy", at: start.addingTimeInterval(1800), provider: nil, model: "", source: "legacy", usage: .init(input: 5, output: 2))
        ]
        try await service.importRecords(records)
        let stats = try await service.getStats(in: interval)
        #expect(stats.totalTokens == 177 && stats.totalRequests == 3 && stats.legacyTurns == 1)
        #expect(stats.unreportedRequests == 2 && stats.failedRequests == 2)
        #expect(stats.reportedInputRecords == 3 && stats.reportedOutputRecords == 2)
        #expect(stats.reportedCacheReadRecords == 2 && stats.reportedCacheWriteRecords == 1)
        #expect(stats.totalCacheReadTokens == 0 && stats.unknownCacheRequests == 3)
        #expect(stats.byDay.values.reduce(0) { $0 + $1.input + $1.output } == 177)
        #expect(stats.bySession.reduce(0) { $0 + $1.inputTokens + $1.outputTokens } == 177)
        #expect(stats.byModel.reduce(0) { $0 + $1.input + $1.output } == 177)
        #expect(Set(try await service.getRecords(in: interval).map(\.id)) == ["known", "failed", "cancelled", "legacy"])
        #expect(try await service.getRecords(in: interval, filter: .failed).map(\.id) == ["failed"])
        #expect(try await service.getRecords(in: interval, filter: .cancelled).map(\.id) == ["cancelled"])
        #expect(Set(try await service.getRecords(in: interval, filter: .unreported).map(\.id)) == ["failed", "cancelled"])
        #expect(Set(try await service.getRecords(in: interval, filter: .incompleteCache).map(\.id)) == ["failed", "cancelled", "legacy"])
        #expect(try await UsageService(databaseQueue: self.queue()).getStats(in: interval).totalTurns == 0)
    }

    @Test("Filters query the full ledger and pagination handles tied timestamps without leaking outside the range")
    func filteredPagination() async throws {
        let queue = try queue(), service = UsageService(databaseQueue: queue)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = DateInterval(start: start, duration: 3600)
        let provider = UUID().uuidString
        var records = (0..<63).map { index in
            receipt(String(format: "missing-%03d", index), at: start.addingTimeInterval(30), provider: provider, status: "failed")
        }
        records += (0..<55).map { index in
            receipt("complete-\(index)", at: start.addingTimeInterval(60), provider: provider,
                    usage: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
        }
        records.append(receipt("outside", at: interval.end, provider: provider, status: "failed"))
        records.append(receipt("unfinished", at: start, provider: provider, status: "started"))
        try await service.importRecords(records)
        let first = try await service.getRecords(in: interval, filter: .failed)
        let second = try await service.getRecords(in: interval, filter: .failed, before: first.last)
        #expect(first.count == 50 && second.count == 13)
        #expect(Set((first + second).map(\.id)) == Set((0..<63).map { String(format: "missing-%03d", $0) }))
        #expect(first.map(\.id) == first.map(\.id).sorted(by: >))
        #expect(try await service.getRecords(in: interval, filter: .unfinished).map(\.id) == ["unfinished"])
        #expect(try await service.getRecords(in: interval, filter: .failedOrCancelled, before: first.last).count == 13)
        #expect(try await service.getStats(in: interval).unreportedRequests == 64)
    }

    @Test("Same-name models retain source and provider boundaries and unknown cache counts never become reported zero")
    func groupedModelSources() async throws {
        let queue = try queue(), service = UsageService(databaseQueue: queue)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = UUID().uuidString, b = UUID().uuidString
        try await service.importRecords([
            receipt("confirmed", at: date, provider: a, model: "alias", usage: .init(input: 100, output: 20, cacheRead: 0, cacheWrite: 0, reportedModel: "flash")),
            receipt("requested", at: date, provider: a, usage: .init(input: 30, output: 5)),
            receipt("other-provider", at: date, provider: b, usage: .init(input: 2, output: 1, reportedModel: "flash")),
            receipt("different-response", at: date, provider: a, usage: .init(input: 10, output: 1, reportedModel: "actual-other"))
        ])
        let stats = try await service.getStats()
        #expect(stats.modelGroups.count == 3)
        let group = try #require(stats.modelGroups.first { $0.id.providerID == a && $0.model == "flash" })
        #expect(group.records == 2 && group.input == 130 && group.output == 25)
        #expect(group.sources.count == 2 && group.sources.first?.isReportedModel == true)
        #expect(group.reportedCacheReadRecords == 1 && group.cacheRead == 0 && group.unknownCacheRecords == 1)
        #expect(group.sources.last?.reportedCacheReadRecords == 0)
        #expect(ProviderTokenUsage().reportedTotal == nil)
        #expect(ProviderTokenUsage(input: 0, output: 0).reportedTotal == 0)
        #expect(ProviderTokenUsage(input: 30).reportedTotal == 30)
        #expect(!ProviderTokenUsage(input: 30).hasCompleteTokenCounts)
    }

    @Test("Local-day presets and inclusive custom dates survive daylight-saving changes")
    func calendarIntervals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let today = try #require(UsagePeriod.today.interval(now: date, calendar: calendar))
        let week = try #require(UsagePeriod.last7Days.interval(now: date, calendar: calendar))
        #expect(today.duration == 23 * 3600)
        #expect(week.duration == 167 * 3600)
        #expect(calendar.component(.day, from: week.start) == 2)
        #expect(calendar.component(.day, from: week.end) == 9)
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 18)))
        let last = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 8)))
        let custom = try #require(UsagePeriod.custom.interval(calendar: calendar, customStart: last, customEnd: first))
        #expect(custom.duration == 71 * 3600)
        #expect(calendar.component(.day, from: custom.start) == 7)
        #expect(calendar.component(.day, from: custom.end) == 10)
        #expect(UsagePeriod.all.interval(now: date, calendar: calendar) == nil)
        let month = try #require(UsagePeriod.thisMonth.interval(now: date, calendar: calendar))
        #expect(calendar.component(.day, from: month.start) == 1 && calendar.component(.month, from: month.end) == 4)
        var stats = UsageStats(); stats.byDay["2026-03-08"] = (input: 10, output: 2, turns: 1)
        let days = stats.recentDays(3, endingAt: date, calendar: calendar)
        #expect(days.map(\.day) == ["2026-03-06", "2026-03-07", "2026-03-08"])
        #expect(days.last?.input == 10 && days.first?.input == 0)
    }

    private func receipt(_ id: String, at: Date, provider: String?, model: String = "flash", source: String = "chat",
                         status: String = "succeeded", usage: ProviderTokenUsage = .init()) -> ProviderUsageRecord {
        ProviderUsageRecord(id: id, sessionID: nil, providerID: provider, providerName: "Synthetic provider",
            requestedModel: model, source: source, startedAt: at, finishedAt: status == "started" ? nil : at.addingTimeInterval(1.25),
            status: status, usage: usage)
    }
}

@Suite("Native usage dashboard rendering", .serialized)
struct UsageDashboardRenderingTests {
    @MainActor @Test("The dashboard renders narrow and wide layouts in three languages, both appearances and larger interface text")
    func dashboardRendering() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let service = UsageService(databaseQueue: queue)
        let now = Date(), provider = UUID().uuidString
        let statuses = ["succeeded", "succeeded", "succeeded", "succeeded", "failed", "cancelled"]
        let fixtures: [ProviderUsageRecord] = statuses.enumerated().map { index, status in
            let offset = TimeInterval(-index * 86_400)
            let model = index < 2 ? "deepseek-flash" : "synthetic-model"
            let usage = status == "succeeded"
                ? ProviderTokenUsage(input: 12_500, output: 1_500, cacheRead: index == 0 ? 4_000 : nil,
                                     reportedModel: index < 2 ? model : nil)
                : ProviderTokenUsage()
            return ProviderUsageRecord(id: "preview-\(index)", sessionID: nil, providerID: provider, providerName: "Synthetic provider",
                requestedModel: model, source: "chat", startedAt: now.addingTimeInterval(offset),
                finishedAt: now.addingTimeInterval(offset + 1.2), status: status, usage: usage)
        }
        try await service.importRecords(fixtures)
        let stats = try await service.getStats(), records = try await service.getRecords()
        let oldLanguage = LanguageManager.shared.currentLanguage
        let oldLarge = InterfaceTypographyPreferences.shared.isLarge
        defer {
            LanguageManager.shared.currentLanguage = oldLanguage
            InterfaceTypographyPreferences.shared.isLarge = oldLarge
        }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for dark in [false, true] {
                for width in [900.0, 1440.0] {
                    InterfaceTypographyPreferences.shared.isLarge = width == 900
                    for section in UsageSection.allCases {
                        let sidebarWidth = language == .english ? 230.0 : 180.0
                        let host = NSHostingView(rootView: HStack(spacing: 0) {
                            UsageCategoryList(selection: .constant(section))
                            Divider()
                            ScrollView {
                                UsageDashboardContent(stats: stats, records: records, interval: nil, availableWidth: width - sidebarWidth - 49,
                                    section: .constant(section), requestFilter: .constant(.all), hasMore: true, loadingMore: false, refreshing: false, onLoadMore: {})
                                    .padding(24)
                            }
                        }
                        .font(MeetTypography.control)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light))
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1050),
                            styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.contentView = host
                        defer { window.close() }
                        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                        #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                        if let directory = ProcessInfo.processInfo.environment["AGROOM_USAGE_SNAPSHOT_DIR"] {
                            let png = try #require(bitmap.representation(using: .png, properties: [:]))
                            try png.write(to: URL(fileURLWithPath: directory)
                                .appendingPathComponent("usage-\(section.rawValue)-\(language.rawValue)-\(Int(width))-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
        }
    }
}
