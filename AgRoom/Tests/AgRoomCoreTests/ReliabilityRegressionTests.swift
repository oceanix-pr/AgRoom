import Foundation
import GRDB
import Testing
import AppKit
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Reliability and resource regression coverage", .serialized)
struct ReliabilityRegressionTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reliability-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(db)
        return db
    }

    @Test("Temporary job centers finish subscribers on release")
    func releasedJobCenterFinishesStream() async throws {
        var center: JobCenter? = .ephemeral()
        weak let released = center
        let stream = center!.stream(space: .work)
        center = nil
        #expect(released == nil)
        let finished = RegressionFlag()
        let consumer = Task {
            for await _ in stream {}
            await finished.set()
        }
        defer { consumer.cancel() }
        let deadline = Date().addingTimeInterval(2)
        while !(await finished.value), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await finished.value)
    }

    @Test("SSE parsing checks cancellation even when the source has no newline")
    func cancelledSSEWithoutNewline() async throws {
        let state = RegressionFlag()
        let consumer = Task {
            let source = AsyncStream<UInt8> { continuation in
                for _ in 0..<8192 { continuation.yield(65) }
                continuation.finish()
            }
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                for try await _ in BoundedLLMLines(bytes: source) {}
            } catch is CancellationError { await state.set() }
        }
        try await consumer.value
        #expect(await state.value)
    }

    @Test("Legacy provider closes a server stream after completion or rejected headers", arguments: [false, true])
    func legacyStreamNetworkLifetime(rejected: Bool) async throws {
        LifetimeStreamProtocol.stopped.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifetimeStreamProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = CloudProvider(config: .init(name: "Lifetime", endpoint: "http://127.0.0.1:64415/" + (rejected ? "reject" : "ok") + "/v1/chat/completions", model: "fixture"), apiKey: "fixture", session: session)
        do {
            var text = ""
            for try await delta in try await provider.stream(prompt: "fixture") { text += delta }
            #expect(!rejected && text == "ok")
        } catch LLMError.invalidAPIKey { #expect(rejected) }
        let deadline = Date().addingTimeInterval(2)
        while LifetimeStreamProtocol.stopped.value == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(LifetimeStreamProtocol.stopped.value > 0)
    }

    @Test("Dense transcript corrections preserve Unicode and never cascade replacements")
    func denseTranscriptCorrections() throws {
        let rules = try NoteTranscriptDictionary("bad=good\ngood=best")
        let source = String(repeating: "😀 bad good é\n", count: 10_000)
        #expect(try rules.apply(source) == String(repeating: "😀 good best é\n", count: 10_000))
    }

    @Test("Released provider tickets are removed and unknown/duplicate releases cannot free slots")
    func providerTicketLifetime() async throws {
        let gate = ProviderConcurrencyGate(limit: 1)
        for _ in 0..<2_000 {
            let ticket = try await gate.acquire("test")
            await gate.release(ticket); await gate.release(ticket)
        }
        #expect(await gate.retainedTicketCount == 0)
        let ticket = try await gate.acquire("test")
        await gate.release(ProviderGateTicket(key: "test", id: UUID()))
        #expect(await gate.activeCount("test") == 1)
        await gate.release(ticket)
        #expect(await gate.activeCount("test") == 0)
    }

    @Test("Account queue cancellation completes while its current owner still holds the lease")
    func accountQueueCancellation() async throws {
        let coordinator = MailAccountCoordinator()
        let id = UUID(), ready = RegressionFlag()
        let owner = Task {
            try await coordinator.withLease(space: .work, accountId: id) {
                await ready.set()
                try await Task.sleep(for: .seconds(10))
            }
        }
        defer { owner.cancel() }
        while !(await ready.value) { try await Task.sleep(for: .milliseconds(2)) }
        let waiter = Task { try await coordinator.withLease(space: .work, accountId: id) { true } }
        while await coordinator.waitingCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
        waiter.cancel()
        do { _ = try await TaskDeadline.run(until: Date().addingTimeInterval(1)) { try await waiter.value }; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        #expect(await coordinator.waitingCount == 0)
        await coordinator.invalidate(space: .work, accountId: id)
        do { try await owner.value; Issue.record("Revoked operation completed") } catch is CancellationError {}
        #expect(try await coordinator.withLease(space: .personal, accountId: id) { true })
    }

    @Test("Speech cancellation before continuation registration remains cancelled")
    func recognitionCancellationBeforeInstall() async throws {
        let handle = RecognitionHandle()
        handle.cancel()
        do {
            let _: TranscriptionResult = try await withCheckedThrowingContinuation { continuation in
                handle.install(continuation)
                handle.finish(.success(.init(text: "late", segments: [])))
            }
            Issue.record("A cancelled request succeeded")
        } catch is CancellationError {}
    }

    @Test("Team wall clock interrupts a cooperative in-flight worker")
    func teamDeadline() async throws {
        let subtask = TeamSubtask(title: "Wait", objective: "Wait", estimatedTokens: 10)
        let coordinator = TeamCoordinator(plan: TeamPlan(goal: "Timeout", subtasks: [subtask]),
            budget: TeamBudget(maxWallClockSeconds: 1), factory: SlowRegressionFactory())
        let start = Date()
        let result = try await coordinator.run()
        #expect(result.status == .failed)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("Repeated image rejection performs one downgrade and then fails")
    func imageRetryBound() async throws {
        RegressionImageProtocol.counter.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegressionImageProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = CloudProvider(config: .init(name: "Fixture", endpoint: "http://127.0.0.1:64411/v1/chat/completions", model: "fixture"), apiKey: "fixture", session: session)
        let engine = DispatcherEngine(provider: provider, tools: [], systemPrompt: "test")
        do {
            _ = try await engine.run(userMessage: "image", history: [], images: [.init(data: Data([0]), mimeType: "image/png")])
            Issue.record("Expected rejection")
        } catch LLMError.imageUnsupported {}
        #expect(RegressionImageProtocol.counter.value == 2)
        let textOnly = DispatcherEngine(provider: provider, tools: [], systemPrompt: "test")
        do { _ = try await textOnly.run(userMessage: "text", history: []); Issue.record("Expected rejection") }
        catch LLMError.imageUnsupported {}
        #expect(RegressionImageProtocol.counter.value == 3)
    }

    @Test("SSE limits reject oversized individual events before a complete line is allocated")
    func responseLimits() async throws {
        let data = Data(repeating: 65, count: LLMResponseLimits.eventBytes + 1)
        let stream = AsyncStream<UInt8> { continuation in for byte in data { continuation.yield(byte) }; continuation.finish() }
        do {
            for try await _ in BoundedLLMLines(bytes: stream) {}
            Issue.record("Expected size rejection")
        } catch LLMError.responseTooLarge {}
        #expect(!DispatcherEngine.isRetryable(LLMError.responseTooLarge))
    }

    @Test("OCR dimensions reject oversized and overflowing metadata before image allocation")
    func imageDimensionLimits() throws {
        try OCRService.validateDimensions(width: 8_000, height: 5_000)
        #expect(throws: OCRService.OCRError.self) { try OCRService.validateDimensions(width: 8_001, height: 5_000) }
        #expect(throws: OCRService.OCRError.self) { try OCRService.validateDimensions(width: Int.max, height: Int.max) }
        #expect(throws: OCRService.OCRError.self) { try OCRService.validateDimensions(width: 1, height: 0) }
    }

    @Test("Tail pages save against their original sequence without replacing older history")
    func messagePagePersistence() async throws {
        let queue = try database(), service = SessionService(databaseQueue: queue)
        var session = ChatSession(title: "History")
        session.messages = (0..<350).map { ChatMessage(role: .user, content: "message-\($0)") }
        try await service.save(session)
        let page = try await service.getMessagePage(id: session.id)
        #expect(page.messages.count == 100 && page.offset == 250)
        var tail = session
        tail.messages = page.messages; tail.messageOffset = page.offset
        tail.messages.append(ChatMessage(role: .assistant, content: "new tail"))
        try await service.save(tail, changedMessageIndexFrom: 99)
        let full = try await service.getMessages(id: session.id)
        #expect(full.count == 351 && full.first?.content == "message-0" && full.last?.content == "new tail")
        let older = try await service.getMessagePage(id: session.id, before: 250)
        #expect(older.offset == 150 && older.messages.last?.content == "message-249")
        tail.messages.removeLast(2)
        try await service.save(tail)
        #expect(try await service.getMessages(id: session.id).count == 349)
    }

    @Test("Damaged conversations cannot be exported as healthy backups")
    func corruptBackupRejected() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = try database(), sessions = SessionService(databaseQueue: queue)
        var chat = ChatSession(); chat.messages = [ChatMessage(role: .user, content: "keep"), ChatMessage(role: .assistant, content: "keep too")]
        try await sessions.save(chat)
        let id = chat.id.uuidString
        try await queue.write { try $0.execute(sql: "UPDATE chat_messages SET payload='broken' WHERE sessionId=? AND seq=0", arguments: [id]) }
        let service = BackupService(sessionService: sessions, memoryService: MemoryService(databaseQueue: queue),
            skillStore: SkillStore(directoryURL: root.appendingPathComponent("skills")), spaceName: "work")
        do { _ = try await service.export(to: root.appendingPathComponent("backup.zip")); Issue.record("Damaged backup exported") }
        catch BackupError.preflightFailed {}
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("backup.zip").path))
        #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_messages") } == 2)
    }

    @Test("Restore maintenance rejects competing writes and remains reentrant for its own services")
    func maintenanceIsolation() async throws {
        let queue = try database(), sessions = SessionService(databaseQueue: queue)
        let chat = ChatSession(title: "original")
        try await sessions.save(chat)
        try await ResourceMaintenance.withExclusive([sessions.maintenanceKey]) {
            var updated = chat; updated.title = "restore"
            try await sessions.save(updated)
            let outside = Task.detached {
                var competing = chat; competing.title = "competing"
                try await sessions.save(competing)
            }
            do { try await outside.value; Issue.record("Competing writer entered maintenance") }
            catch MaintenanceError.busy {}
        }
        #expect(try await sessions.fetch(id: chat.id)?.title == "restore")
        try await sessions.save(chat)
        #expect(try await sessions.fetch(id: chat.id)?.title == "original")
    }

    @Test("Restore generations reject stale snapshots and old daemon writers after maintenance ends")
    func restoredSnapshotProtection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = try database(), sessions = SessionService(databaseQueue: queue)
        var original = ChatSession(title: "before")
        original.messages = [.init(role: .assistant, content: "before")]
        try await sessions.save(original)
        let oldDaemon = SessionService(databaseQueue: queue, expectedRestoreVersion: .init(id: original.id, token: nil))
        var imported = original; imported.title = "restored"; imported.messages[0].content = "restored"
        try await sessions.save(imported)
        let backup = BackupService(sessionService: sessions, memoryService: MemoryService(databaseQueue: queue),
            skillStore: SkillStore(directoryURL: root.appendingPathComponent("skills")), spaceName: "work",
            attachmentsDirectory: root.appendingPathComponent("attachments"), audioDirectory: root.appendingPathComponent("audio"))
        let archive = root.appendingPathComponent("snapshot.zip")
        _ = try await backup.export(to: archive)
        try await sessions.save(original)
        _ = try await backup.restore(from: archive)
        do { try await sessions.save(original); Issue.record("Old UI snapshot overwrote restored data") }
        catch SessionServiceError.staleAfterRestore {}
        do { try await oldDaemon.updateMessage(sessionId: original.id, messageId: original.messages[0].id) { $0.content = "late" }; Issue.record("Old daemon wrote back") }
        catch SessionServiceError.staleAfterRestore {}
        var refreshed = try #require(try await sessions.fetch(id: original.id))
        #expect(refreshed.restorationToken != nil)
        #expect(refreshed.messages[0].content == "restored")
        refreshed.messages.append(.init(role: .user, content: "continue"))
        try await sessions.save(refreshed)
        #expect(try await sessions.getMessages(id: original.id).count == 2)
        let page = try await sessions.getMessagePage(id: original.id)
        #expect(page.restorationToken == refreshed.restorationToken)
        let summary = try #require(try await sessions.getSummaries().first)
        #expect(summary.restorationToken == refreshed.restorationToken)
    }

    @Test("Deleted account and message guards prevent late network results from resurrecting rows")
    func mailIntegrity() async throws {
        let queue = try database()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO mail_deleted_accounts VALUES ('removed')")
        }
        do {
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO mail_folders (id,accountId,name,path,role,unreadCount,totalCount) VALUES ('folder','removed','Inbox','INBOX','inbox',0,0)")
            }
            Issue.record("Removed account accepted a late folder")
        } catch let error as DatabaseError { #expect(error.message == "mail account removed") }
        do {
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO mail_bodies (messageId,textBody,htmlBody,fetchedAt) VALUES ('missing','late',NULL,?)", arguments: [Date()])
            }
            Issue.record("Removed message accepted a late body")
        } catch let error as DatabaseError { #expect(error.message == "mail message removed") }
        #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mail_bodies") } == 0)
    }

    @Test("Independent log writers retain both entries and an object can go out of scope before its write")
    func logPublication() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = SkillUsageLog(spaceDirectoryURL: root), second = SkillUsageLog(spaceDirectoryURL: root)
        first.record(.init(skill: "one", tool: "skill_load", time: Date(), success: true, detail: ""))
        second.record(.init(skill: "two", tool: "skill_load", time: Date(), success: true, detail: ""))
        SkillUsageLog(spaceDirectoryURL: root).record(.init(skill: "three", tool: "skill_load", time: Date(), success: true, detail: ""))
        first.flushPendingWrites()
        let loaded = SkillUsageLog(spaceDirectoryURL: root)
        #expect(["one", "two", "three"].allSatisfy { loaded.entries(for: $0).count == 1 })
    }

    @Test("Recovery drafts are separated by space and reject stale writes")
    func markdownRecoveryDraft() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownDraftStore(root: root)
        let draft = MarkdownRecoveryDraft(text: "new draft", suggestedName: "test.md")
        try await store.save(draft, space: .work, revision: 2)
        try await store.save(.init(text: "stale", suggestedName: "old"), space: .work, revision: 1)
        #expect(try await store.load(.work) == draft)
        #expect(try await store.load(.personal) == nil)
        let reopened = MarkdownDraftStore(root: root)
        #expect(try await reopened.load(.work) == draft)
        try await store.save(nil, space: .work, revision: 3)
        #expect(try await store.load(.work) == nil)
        let large = root.appendingPathComponent("large.md")
        try Data(repeating: 65, count: BoundedDocumentIO.limit + 1).write(to: large)
        #expect(throws: LLMError.self) { try BoundedDocumentIO.read(large) }
    }

    @MainActor @Test("Block rendering reuses stable paragraphs and updates only the changed tail")
    func markdownBlockReuse() throws {
        let first = MarkdownParser.parse("# Heading\n\nFirst paragraph.\n\nTail.")
        let changed = MarkdownParser.parse("# Heading\n\nFirst paragraph.\n\nTail extended.")
        let cache = MarkdownBlockRenderCache()
        _ = cache.segments(first.blocks, resources: [:], failed: [], typography: ReadingTypography())
        let baseline = cache.rebuildCount
        let output = cache.segments(changed.blocks, resources: [:], failed: [], typography: ReadingTypography())
        #expect(cache.rebuildCount == baseline + 1)
        guard case .prose(let prose) = output.first else { Issue.record("Missing prose"); return }
        let text = prose.attributedString
        #expect(text.string.contains("Heading") && text.string.contains("First paragraph.") && text.string.contains("Tail extended."))
    }
}

private actor RegressionFlag { private(set) var value = false; func set() { value = true } }
private struct SlowRegressionFactory: TeamWorkerFactory {
    func makeWorker(taskID: UUID, plan: TeamPlan, subtask: TeamSubtask, inputs: [TeamArtifact], budget: TeamBudget) async throws -> any TeamWorker {
        SlowRegressionWorker(id: subtask.id)
    }
}
private struct SlowRegressionWorker: TeamWorker {
    let id: UUID
    var name: String { "slow" }
    func run() async throws -> TeamSubtaskResult {
        try await Task.sleep(for: .seconds(10))
        return .init(subtaskID: id, summary: "late")
    }
}
private final class RegressionCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func reset() { lock.withLock { count = 0 } }
    func increment() { lock.withLock { count += 1 } }
}
private final class RegressionImageProtocol: URLProtocol, @unchecked Sendable {
    static let counter = RegressionCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counter.increment()
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"image unsupported"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Tool schema compatibility")
struct ToolSchemaCompatibilityTests {
    @MainActor
    @Test("Tool schema failures identify the tool and field in all three UI languages")
    func localizedFailure() {
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        let error = LLMError.invalidToolSchema(toolName: "schema_fixture", field: "parameters.oneOf")
        var messages: Set<String> = []
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            LanguageManager.shared.currentLanguage = language
            let message = L.errorDescription(error)
            #expect(message.contains("schema_fixture") && message.contains("parameters.oneOf"))
            #expect(L.actionableError(error, fallbackKey: "error.actionable.provider_connection") == message)
            messages.insert(message)
        }
        #expect(messages.count == 3)
    }

    @Test("Object tool schemas include properties in both protocols and request modes", arguments: [false, true], [false, true])
    func objectProperties(anthropic: Bool, stream: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StrictToolSchemaProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = anthropic ? "https://api.anthropic.com/v1/messages" : "http://127.0.0.1:1234/v1/chat/completions"
        let provider = CloudProvider(config: .init(name: "Schema fixture", endpoint: endpoint, model: "fixture"), apiKey: "", session: session)
        let queue = try DatabaseQueue()
        let tools = [
            MySQLConnectionsTool(service: MySQLConnectorService(databaseQueue: queue, space: .work)).definition,
            ShellRunTool().definition,
            ToolDefinition(name: "empty", description: "No arguments", parametersSchemaJSON: #"{"type":"object"}"#),
            ToolDefinition(name: "dynamic", description: "String map", parametersSchemaJSON: #"{"type":"object","additionalProperties":{"type":"string"}}"#),
            ToolDefinition(name: "search", description: "Required query", parametersSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#),
            ToolDefinition(name: "nested", description: "Nested constraints", parametersSchemaJSON: #"{"type":"object","properties":{"value":{"anyOf":[{"type":"string","enum":["a","b"]},{"type":"null"}]},"oneOf":{"type":"string"}}}"#)
        ]
        let messages = [EngineMessage(role: .user, text: "你好")]
        let reply: ChatReply
        if stream {
            reply = try await provider.chatStream(messages: messages, tools: tools, config: .default) { _ in }
        } else {
            reply = try await provider.chat(messages: messages, tools: tools, config: .default)
        }
        #expect(reply.text == "ok")
    }

    @Test("Assembled built-in tools including the optional team tool have valid parameter objects", arguments: [false, true], [false, true])
    func assembledTools(anthropic: Bool, stream: Bool) throws {
        let endpoint = anthropic ? "https://api.anthropic.com/v1/messages" : "http://127.0.0.1:1234/v1/chat/completions"
        let provider = CloudProvider(config: .init(name: "Schema fixture", endpoint: endpoint, model: "fixture"), apiKey: "")
        let definitions = DispatcherToolFactory.buildTools(provider: provider, agents: [Agent(name: "Fixture")],
            memoryService: nil, hostCapabilities: .foregroundApp, teamTasksEnabled: true).map(\.definition)
        #expect(definitions.contains { $0.name == "shell_run" })
        let team = try #require(definitions.first { $0.name == "team_run" })
        let schema = try #require(JSONSerialization.jsonObject(with: Data(team.parametersSchemaJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let subtasks = try #require(properties["subtasks"] as? [String: Any])
        let items = try #require(subtasks["items"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["goal", "subtasks"])
        #expect(items["required"] as? [String] == ["title", "objective"])
        _ = try provider.buildChatRequest(messages: [.init(role: .user, text: "你好")], tools: definitions, config: .default, stream: stream)
    }

    @Test("Invalid tool schema structure fails before HTTP in both protocols and request modes", arguments: [false, true], [false, true])
    func invalidStructure(anthropic: Bool, stream: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedToolSchemaRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = anthropic ? "https://api.anthropic.com/v1/messages" : "http://127.0.0.1:1234/v1/chat/completions"
        let provider = CloudProvider(config: .init(name: "Schema fixture", endpoint: endpoint, model: "fixture"), apiKey: "", session: session)
        for (schema, field) in [
            ("{", "parameters"), ("[]", "parameters"), ("false", "parameters"),
            ("{}", "parameters.type"), (#"{"type":"array"}"#, "parameters.type"),
            (#"{"type":["object","null"]}"#, "parameters.type"),
            (#"{"type":"object","properties":[]}"#, "parameters.properties"),
            (#"{"type":"object","properties":null}"#, "parameters.properties")
        ] {
            let tool = ToolDefinition(name: "invalid_schema", description: "Fixture", parametersSchemaJSON: schema)
            do {
                if stream {
                    _ = try await provider.chatStream(messages: [.init(role: .user, text: "你好")], tools: [tool], config: .default) { _ in }
                } else {
                    _ = try await provider.chat(messages: [.init(role: .user, text: "你好")], tools: [tool], config: .default)
                }
                Issue.record("Invalid schema must fail before HTTP")
            } catch {
                guard let llm = error as? LLMError, case .invalidToolSchema(let name, let location) = llm else {
                    Issue.record("Expected a tool schema error, got \(error)"); continue
                }
                #expect(name == tool.name && location == field)
                #expect(!DispatcherEngine.isRetryable(error))
            }
        }
    }

    @Test("OpenAI rejects forbidden root keywords before HTTP; Anthropic constraints remain intact", arguments: [false, true])
    func rootKeywords(stream: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedToolSchemaRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = CloudProvider(config: .init(name: "OpenAI fixture", endpoint: "http://127.0.0.1:1234/v1/chat/completions", model: "fixture"), apiKey: "", session: session)
        let anthropic = CloudProvider(config: .init(name: "Anthropic fixture", endpoint: "https://api.anthropic.com/v1/messages", model: "fixture"), apiKey: "", session: session)
        for (keyword, value) in [
            ("oneOf", #"[{"type":"object"}]"#), ("anyOf", #"[{"type":"object"}]"#),
            ("allOf", #"[{"type":"object"}]"#), ("enum", "[{}]"), ("const", "{}"), ("not", "{}")
        ] {
            let schema = #"{"type":"object","properties":{},"\#(keyword)":\#(value)}"#
            let tool = ToolDefinition(name: "constrained", description: "Fixture", parametersSchemaJSON: schema)
            do {
                if stream {
                    _ = try await provider.chatStream(messages: [.init(role: .user, text: "你好")], tools: [tool], config: .default) { _ in }
                } else {
                    _ = try await provider.chat(messages: [.init(role: .user, text: "你好")], tools: [tool], config: .default)
                }
                Issue.record("Unsupported root keyword must fail before HTTP")
            } catch {
                guard let llm = error as? LLMError, case .invalidToolSchema(let name, let field) = llm else {
                    Issue.record("Expected a tool schema error, got \(error)"); continue
                }
                #expect(name == tool.name && field == "parameters.\(keyword)")
                #expect(!DispatcherEngine.isRetryable(error))
            }
            let request = try anthropic.buildChatRequest(messages: [.init(role: .user, text: "你好")], tools: [tool], config: .default, stream: stream)
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let tools = try #require(body["tools"] as? [[String: Any]])
            let sent = try #require(tools.first?["input_schema"] as? [String: Any])
            let original = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
            #expect(NSDictionary(dictionary: sent).isEqual(to: original))
        }
    }
}

private final class UnexpectedToolSchemaRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Issue.record("Invalid tool schema reached HTTP")
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }
    override func stopLoading() {}
}

private final class StrictToolSchemaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let tools = try #require(body["tools"] as? [[String: Any]])
            #expect(tools.count == 6)
            let anthropic = request.url?.host == "api.anthropic.com"
            for tool in tools {
                let function = anthropic ? tool : try #require(tool["function"] as? [String: Any])
                let schema = try #require(function[anthropic ? "input_schema" : "parameters"] as? [String: Any])
                let properties = try #require(schema["properties"] as? [String: Any])
                #expect(schema["type"] as? String == "object")
                if !anthropic {
                    for keyword in ["oneOf", "anyOf", "allOf", "enum", "const", "not"] {
                        #expect(schema[keyword] == nil)
                    }
                }
                switch function["name"] as? String {
                case "mysql_connections":
                    #expect(properties.isEmpty && schema["additionalProperties"] as? Bool == false)
                case "shell_run":
                    #expect((properties["program"] as? [String: Any])?["type"] as? String == "string")
                    #expect((properties["arguments"] as? [String: Any])?["type"] as? String == "array")
                    #expect((properties["script"] as? [String: Any])?["type"] as? String == "string")
                    #expect((properties["execution_mode"] as? [String: Any])?["enum"] as? [String] == ["sandbox", "host"])
                case "empty":
                    #expect(properties.isEmpty && schema["additionalProperties"] == nil)
                case "dynamic":
                    #expect(properties.isEmpty)
                    #expect((schema["additionalProperties"] as? [String: Any])?["type"] as? String == "string")
                case "search":
                    #expect((properties["query"] as? [String: Any])?["type"] as? String == "string")
                    #expect(schema["required"] as? [String] == ["query"])
                    #expect(schema["additionalProperties"] as? Bool == false)
                case "nested":
                    let alternatives = try #require((properties["value"] as? [String: Any])?["anyOf"] as? [[String: Any]])
                    #expect(alternatives.count == 2 && alternatives.first?["enum"] as? [String] == ["a", "b"])
                    #expect((properties["oneOf"] as? [String: Any])?["type"] as? String == "string")
                default: Issue.record("Unexpected tool")
                }
            }
            let streaming = body["stream"] as? Bool == true
            let payload: String
            if streaming {
                payload = anthropic
                    ? "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
                    : "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            } else {
                payload = anthropic
                    ? #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
                    : #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#
            }
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class LifetimeStreamProtocol: URLProtocol, @unchecked Sendable {
    static let stopped = RegressionCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let rejected = request.url!.path.contains("reject")
        let response = HTTPURLResponse(url: request.url!, statusCode: rejected ? 401 : 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !rejected {
            client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        }
        // Deliberately leave the connection open after the protocol terminator.
    }
    override func stopLoading() { Self.stopped.increment() }
}
