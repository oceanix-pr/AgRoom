import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

private struct HandoffHostReadTool: DispatcherTool {
    let definition = ToolDefinition(name: "handoff_host_read", description: "Synthetic read", parametersSchemaJSON: "{}")
    let requiresConfirmation = false
    let sideEffectClass: ToolSideEffectClass = .readOnly

    func execute(argumentsJSON: String) async throws -> String { "ready" }
}

@MainActor
private final class HandoffEngineSpy {
    var attempts = 0
}

@MainActor
@Suite("Daemon handoff App ownership", .serialized)
struct DaemonHandoffHostTests {
    private struct Fixture {
        let root: URL
        let queue: DatabaseQueue
        let sessions: SessionService
        let store: DaemonHandoffStore
        let registry: WorkspaceRegistry
        let model: ChatViewModel
        let engineSpy: HandoffEngineSpy
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-handoff-host-" + UUID().uuidString)
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue),
                      artifactPreviewsRoot: root.appendingPathComponent("artifact-cache"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: root.appendingPathComponent("files")))
        let store = DaemonHandoffStore(baseDirectory: root)
        let engineSpy = HandoffEngineSpy()
        let model = ChatViewModel(hub: hub, space: .work, workspaceRegistry: registry,
            observeHostServices: false, handoffStore: store, draftDefaults: nil,
            makeEngine: { _ in
                engineSpy.attempts += 1
                throw ToolExecutionFailure(message: "A restored card must not start a model request")
            })
        return Fixture(root: root, queue: queue, sessions: SessionService(databaseQueue: queue),
                       store: store, registry: registry, model: model, engineSpy: engineSpy)
    }

    private func readyEngine() async throws -> DispatcherEngine {
        let engine = DispatcherEngine(tools: [HandoffHostReadTool()], systemPrompt: "Synthetic handoff")
        _ = try await engine.executeCommand(.init(id: "read-1", name: "handoff_host_read", argumentsJSON: "{}"))
        #expect(engine.isAtRecoverableBoundary)
        return engine
    }

    private func recoveryRecord(space: AppSpace, sessionID: UUID, messageID: UUID) -> DaemonRunRecord {
        let snapshot = EngineRunSnapshot(messages: [], thoughts: [], trace: [], stepsUsed: 0,
            totalTokens: 0, totalInputTokens: 0, totalOutputTokens: 0,
            callFingerprintCounts: [:], consecutiveFailedRounds: 0,
            restrictedToolNames: nil, activeSkillWorkspace: nil,
            loopNoticeInjected: false, preApprovedTools: [])
        return DaemonRunRecord(space: space, sessionId: sessionID,
            assistantMessageId: messageID, state: .recoveryRequired(reason: "synthetic unknown effect"),
            snapshot: snapshot, settings: ChatViewModel.currentRunSettings(mode: .chat, workspacePath: ""))
    }

    @Test("Goal availability is an in-memory projection; submission detects a new durable owner")
    func composerRefreshDoesNotAuthorizeExecution() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.model.load()
        fixture.model.newSession()
        let session = try #require(fixture.model.activeSessionId)
        #expect(fixture.model.canComposeGoal)
        let record = recoveryRecord(space: .work, sessionID: session, messageID: UUID())
        try #require(fixture.store.writeRecord(record))
        // This isolated supervisor has not polled. Repainting the button never reads the new record.
        #expect(fixture.model.canComposeGoal)
        let definition = GoalSetupInput.makeDefinition(objective: "Fixture objective")
        #expect(await fixture.model.startGoal(definition, expectedSessionID: session) == false)
        #expect(fixture.engineSpy.attempts == 0 && fixture.model.session(id: session)?.messages.isEmpty == true)
        #expect(try await GoalStore(databaseQueue: fixture.queue, space: .work).latest(sessionID: session) == nil)
    }

    @Test("Queued App save and late callbacks cannot replace a fast Daemon completion")
    func fastDaemonCompletion() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Original", variations: [
            AnswerVariation(question: "Synthetic", content: "Original"),
            AnswerVariation(question: "Synthetic", content: "Queued App edit")
        ])
        var session = ChatSession(title: "Synthetic handoff")
        session.messages = [assistant]
        try await fixture.sessions.save(session)
        await fixture.model.load()
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let engine = try await readyEngine()

        // switchVariation queues a whole-session save on MainActor. There is no
        // suspension between that enqueue and the handoff, so the old save must
        // retain its earlier ownership generation.
        fixture.model.switchVariation(messageId: assistant.id, to: 1)
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = engine
        fixture.model.beginRun(run)
        #expect(fixture.model.handoffToDaemon() == 1)
        #expect(run.isHandingOff)

        // The local cancelled task has not yet called finishRun. A Daemon can
        // finish and notify App during precisely this interval.
        fixture.model.handleStreamDelta(" late local token", runID: run.id)
        fixture.model.handleTrace(.init(toolName: "late_local", argumentsPreview: "{}",
            resultPreview: "ignored", duration: 0, succeeded: true), runID: run.id)
        #expect(run.trace.isEmpty)
        #expect(fixture.model.session(id: session.id)?.messages.first?.content == "Queued App edit")

        try await fixture.sessions.updateMessage(sessionId: session.id, messageId: assistant.id) {
            $0.content = "Daemon final answer"
        }
        let record = try #require(fixture.store.records(in: .work).map(\.record).first { $0.sessionId == session.id })
        fixture.store.removeRecord(id: record.id, origin: .space(record.space))
        await fixture.model.refreshFromDatabase()
        #expect(fixture.model.session(id: session.id)?.messages.first?.content == "Daemon final answer")
        #expect(!fixture.model.isActiveSessionBackgroundOwned)
        for _ in 0..<5 { await Task.yield() }
        #expect(try await fixture.sessions.fetch(id: session.id)?.messages.first?.content == "Daemon final answer")
    }

    @Test("A provably absent record releases the claim and leaves local execution available")
    func failedRecordWrite() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Running")
        var session = ChatSession(title: "Synthetic failed handoff")
        session.messages = [assistant]
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let engine = try await readyEngine()
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = engine
        fixture.model.beginRun(run)

        // An unusable Store lock rejects the write while the private daemon
        // root remains readable, so record absence can still be established.
        let lock = fixture.store.storeLockFileURL
        #expect(!FileManager.default.fileExists(atPath: lock.path))
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        #expect(fixture.model.handoffToDaemon() == 0)
        #expect(!run.isHandingOff)
        #expect(run.isStreaming)
        let claim = try #require(engine.claimHandoffSnapshot())
        engine.releaseHandoffClaim(claim)
        fixture.model.finishRun(run: run)
    }

    @Test("An uncertain handoff write retains the local run and blocks App exit")
    func uncertainRecordWriteRetainsRun() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Only in memory")
        var session = ChatSession(title: "Uncertain synthetic handoff")
        session.messages = [assistant]
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let engine = try await readyEngine()
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = engine
        fixture.model.beginRun(run)

        // The store was constructed successfully, but its daemon directory
        // becomes a regular file before write. Both write and source listing
        // fail, so the App cannot prove that a handoff record is absent.
        try FileManager.default.removeItem(at: fixture.store.directory)
        try Data("synthetic inaccessible directory".utf8).write(to: fixture.store.directory)
        if case .uncertain = fixture.store.recordPresence(id: UUID(), origin: .space(.work)) {
        } else {
            Issue.record("Unreadable daemon directory must make record presence uncertain")
        }
        #expect(fixture.model.handoffToDaemon() == 0)
        #expect(fixture.model.isSessionRunning(session.id))
        #expect(fixture.model.hasUncertainHandoffClaims)
        #expect(run.isHandingOff)
        #expect(run.engine != nil)
        #expect(fixture.model.session(id: session.id)?.messages.first?.content == "Only in memory")
    }

    @Test("A restored question cannot answer or cancel into a new run, and ending it commits a recovery state")
    func restoredQuestion() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let form = QuestionForm(title: "Review", prompt: "Choose a next step", fields: [
            QuestionField(id: "answer", label: "Answer", type: .text, required: true)
        ])
        var assistant = ChatMessage(role: .assistant, content: "Waiting for a decision",
            runStatus: .waitingForInput)
        assistant.variations = [AnswerVariation(question: "Original request", message: assistant)]
        var session = ChatSession(title: "Restored question")
        session.messages = [assistant]
        session.pendingQuestion = PendingQuestionSnapshot(messageId: assistant.id, form: form)
        try await fixture.sessions.save(session)

        #expect(await fixture.model.openTaskSource(sessionID: session.id, messageID: assistant.id))
        #expect(fixture.model.isRestoredQuestion(messageID: assistant.id))
        fixture.model.inputText = "Preserved draft"
        fixture.model.answerQuestion(.init(values: ["answer": .text("yes")]))
        fixture.model.cancelQuestion()
        for _ in 0..<3 { await Task.yield() }
        #expect(fixture.engineSpy.attempts == 0)
        #expect(fixture.model.inputText == "Preserved draft")
        #expect(fixture.model.pendingQuestion?.messageId == assistant.id)
        #expect(fixture.model.session(id: session.id)?.messages.count == 1)
        #expect(try await fixture.sessions.fetch(id: session.id)?.pendingQuestion?.messageId == assistant.id)

        await fixture.model.endInterruptedQuestion()
        #expect(fixture.model.pendingQuestion == nil)
        #expect(fixture.model.session(id: session.id)?.messages.first?.runStatus == .recoveryRequired)
        #expect(fixture.model.session(id: session.id)?.messages.first?.variations?.first?.runStatus == .recoveryRequired)
        let saved = try #require(try await fixture.sessions.fetch(id: session.id))
        #expect(saved.pendingQuestion == nil)
        #expect(saved.messages.first?.runStatus == .recoveryRequired)
        #expect(saved.messages.first?.variations?.first?.runStatus == .recoveryRequired)
        #expect(fixture.engineSpy.attempts == 0)
    }

    @Test("A failed interrupted-card save preserves both the visible card and durable pending state")
    func failedEndInterruptedQuestion() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let form = QuestionForm(title: "Review", prompt: "Choose a next step", fields: [
            QuestionField(id: "answer", label: "Answer", type: .text)
        ])
        let assistant = ChatMessage(role: .assistant, content: "Waiting for a decision",
            runStatus: .waitingForInput)
        var session = ChatSession(title: "Restored question with write failure")
        session.messages = [assistant]
        session.pendingQuestion = PendingQuestionSnapshot(messageId: assistant.id, form: form)
        try await fixture.sessions.save(session)
        #expect(await fixture.model.openTaskSource(sessionID: session.id, messageID: assistant.id))

        try await fixture.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_interrupted_insert BEFORE INSERT ON chat_sessions BEGIN SELECT RAISE(ABORT, 'synthetic save failure'); END")
            try db.execute(sql: "CREATE TRIGGER fail_interrupted_update BEFORE UPDATE ON chat_sessions BEGIN SELECT RAISE(ABORT, 'synthetic save failure'); END")
        }
        await fixture.model.endInterruptedQuestion()
        #expect(fixture.model.pendingQuestion?.messageId == assistant.id)
        #expect(fixture.model.session(id: session.id)?.messages.first?.runStatus == .waitingForInput)
        #expect(try await fixture.sessions.fetch(id: session.id)?.pendingQuestion?.messageId == assistant.id)
        #expect(try await fixture.sessions.fetch(id: session.id)?.messages.first?.runStatus == .waitingForInput)
        #expect(fixture.engineSpy.attempts == 0)

        try await fixture.queue.write { db in
            try db.execute(sql: "DROP TRIGGER fail_interrupted_insert")
            try db.execute(sql: "DROP TRIGGER fail_interrupted_update")
        }
        await fixture.model.endInterruptedQuestion()
        #expect(fixture.model.pendingQuestion == nil)
        #expect(try await fixture.sessions.fetch(id: session.id)?.pendingQuestion == nil)
        #expect(try await fixture.sessions.fetch(id: session.id)?.messages.first?.runStatus == .recoveryRequired)
    }

    @Test("Explicitly abandoned recovery releases App ownership after authoritative refresh")
    func abandonedRecoveryUnlocks() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Running")
        var session = ChatSession(title: "Synthetic abandoned recovery")
        session.messages = [assistant]
        try await fixture.sessions.save(session)
        await fixture.model.load()
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = try await readyEngine()
        fixture.model.beginRun(run)
        #expect(fixture.model.handoffToDaemon() == 1)
        let record = try #require(fixture.store.records(in: .work).map(\.record).first { $0.sessionId == session.id })
        #expect(fixture.store.updateState(id: record.id, origin: .space(record.space),
            to: .recoveryRequired(reason: "synthetic unknown effect")) != nil)
        #expect(fixture.model.isActiveSessionBackgroundOwned)

        // The task center persists the user's explicit abandonment before it
        // asks ChatViewModel to refresh. A completed audit record remains on disk.
        try await fixture.sessions.updateMessage(sessionId: session.id, messageId: assistant.id) {
            $0.runStatus = .cancelled
        }
        #expect(fixture.store.abandonRecovery(id: record.id, space: .work))
        #expect(fixture.store.records(in: .work).contains { $0.record.id == record.id })
        await fixture.model.refreshFromDatabase()
        #expect(!fixture.model.isActiveSessionBackgroundOwned)
        #expect(fixture.model.session(id: session.id)?.messages.first?.runStatus == .cancelled)
    }

    @Test("A quarantined run record never looks like a completed Daemon run")
    func quarantinedRecordKeepsOwnership() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Running")
        var session = ChatSession(title: "Synthetic corrupted run record")
        session.messages = [assistant]
        try await fixture.sessions.save(session)
        await fixture.model.load()
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = try await readyEngine()
        fixture.model.beginRun(run)
        #expect(fixture.model.handoffToDaemon() == 1)
        let record = try #require(fixture.store.records(in: .work).map(\.record).first { $0.sessionId == session.id })
        let recordURL = fixture.store.directory.appendingPathComponent("work/run-\(record.id.uuidString).json")
        try Data("{truncated".utf8).write(to: recordURL, options: .atomic)
        #expect(fixture.store.records(in: .work).isEmpty)
        #expect(FileManager.default.fileExists(atPath: recordURL.path))

        await fixture.model.refreshFromDatabase()
        #expect(fixture.model.isActiveSessionBackgroundOwned)
        #expect(fixture.model.session(id: session.id)?.messages.first?.content == "Running")

        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: fixture.queue))
        let registry = WorkspaceRegistry(fileURL: fixture.root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: fixture.root.appendingPathComponent("files")))
        let cold = ChatViewModel(hub: hub, space: .work, workspaceRegistry: registry,
            observeHostServices: false, handoffStore: fixture.store, draftDefaults: nil,
            makeEngine: { _ in
                fixture.engineSpy.attempts += 1
                throw ToolExecutionFailure(message: "Synthetic model request")
            })
        #expect(await cold.openTaskSource(sessionID: session.id, messageID: assistant.id))
        cold.inputText = "Repeat unknown work"
        cold.send()
        #expect(cold.inputText == "Repeat unknown work")
        #expect(cold.session(id: session.id)?.messages.count == 1)
        #expect(fixture.engineSpy.attempts == 0)

        let evidence = try #require(fixture.store.quarantinedEvidence(in: .work).first {
            $0.fileURL.lastPathComponent.contains("run-\(record.id.uuidString).json")
        })
        #expect(evidence.space == .work && evidence.sessionID == session.id)
        #expect(evidence.assistantMessageID == assistant.id)
        try await fixture.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_quarantine_terminal BEFORE UPDATE ON chat_messages BEGIN SELECT RAISE(ABORT, 'synthetic terminal failure'); END")
        }
        #expect(await fixture.store.abandonQuarantinedEvidence(evidence,
            space: .work, sessionService: fixture.sessions) == false)
        #expect(FileManager.default.fileExists(atPath: recordURL.path))
        #expect(fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work]?.contains(session.id) == true)
        #expect(try await fixture.sessions.fetch(id: session.id)?.messages.first?.runStatus == nil)

        try await fixture.queue.write { db in
            try db.execute(sql: "DROP TRIGGER fail_quarantine_terminal")
        }
        #expect(await fixture.store.abandonQuarantinedEvidence(evidence,
            space: .work, sessionService: fixture.sessions))
        #expect(try await fixture.sessions.fetch(id: session.id)?.messages.first?.runStatus == .cancelled)
        let abandoned = fixture.store.directory.appendingPathComponent("work/quarantine/abandoned", isDirectory: true)
        let preserved = try #require(FileManager.default.contentsOfDirectory(at: abandoned,
            includingPropertiesForKeys: nil).first {
                $0.lastPathComponent.contains("run-\(record.id.uuidString).json")
            })
        #expect(try Data(contentsOf: preserved) == Data("{truncated".utf8))
        await fixture.model.refreshFromDatabase()
        #expect(!fixture.model.isActiveSessionBackgroundOwned)
    }

    @Test("A malformed space record stays in place on read and keeps ownership")
    func failedQuarantineMoveKeepsOwnership() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Running")
        var session = ChatSession(title: "Synthetic immovable evidence")
        session.messages = [assistant]
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = try await readyEngine()
        fixture.model.beginRun(run)
        #expect(fixture.model.handoffToDaemon() == 1)
        let record = try #require(fixture.store.records(in: .work).map(\.record).first { $0.sessionId == session.id })
        let recordURL = fixture.store.directory.appendingPathComponent("work/run-\(record.id.uuidString).json")
        try Data("{truncated".utf8).write(to: recordURL, options: .atomic)
        #expect(fixture.store.records(in: .work).isEmpty)
        #expect(FileManager.default.fileExists(atPath: recordURL.path))
        #expect(try Data(contentsOf: recordURL) == Data("{truncated".utf8))
        let ownership = fixture.store.ownershipSnapshot()
        #expect(ownership.blockedSessionIdsBySpace[.work]?.contains(session.id) == true)
        #expect(ownership.recoverySessionIds[.work]?.contains(session.id) == true)
        await fixture.model.refreshFromDatabase()
        #expect(fixture.model.isActiveSessionBackgroundOwned)
    }

    @Test("Abandoning quarantined waiting input clears pending and terminal status atomically")
    func quarantinedWaitingInputResolution() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Waiting")
        var session = ChatSession(title: "Synthetic pending recovery")
        session.messages = [assistant]
        try await fixture.sessions.save(session)
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = try await readyEngine()
        fixture.model.beginRun(run)
        #expect(fixture.model.handoffToDaemon() == 1)
        let record = try #require(fixture.store.records(in: .work).map(\.record).first { $0.sessionId == session.id })

        let form = QuestionForm(title: "Review", prompt: "Choose", fields: [
            QuestionField(id: "answer", label: "Answer", type: .text)
        ])
        try await fixture.sessions.updateMessage(sessionId: session.id, messageId: assistant.id) {
            $0.runStatus = .waitingForInput
        }
        try await fixture.sessions.setPending(sessionId: session.id, confirmation: nil,
            question: PendingQuestionSnapshot(messageId: assistant.id, form: form))
        let recordURL = fixture.store.directory.appendingPathComponent("work/run-\(record.id.uuidString).json")
        try Data("{truncated-pending".utf8).write(to: recordURL, options: .atomic)
        #expect(fixture.store.records(in: .work).isEmpty)
        let evidence = try #require(fixture.store.quarantinedEvidence(in: .work).first {
            $0.fileURL.lastPathComponent.contains("run-\(record.id.uuidString).json")
        })
        #expect(evidence.sessionID == session.id && evidence.assistantMessageID == assistant.id)

        try await fixture.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_pending_clear BEFORE UPDATE ON chat_sessions BEGIN SELECT RAISE(ABORT, 'synthetic pending clear failure'); END")
        }
        #expect(await fixture.store.abandonQuarantinedEvidence(evidence,
            space: .work, sessionService: fixture.sessions) == false)
        let afterFailure = try #require(try await fixture.sessions.fetch(id: session.id))
        #expect(afterFailure.pendingQuestion?.messageId == assistant.id)
        #expect(afterFailure.messages.first?.runStatus == .waitingForInput)
        #expect(fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work]?.contains(session.id) == true)
        #expect(!fixture.store.quarantinedEvidence().isEmpty)

        try await fixture.queue.write { db in
            try db.execute(sql: "DROP TRIGGER fail_pending_clear")
        }
        #expect(await fixture.store.abandonQuarantinedEvidence(evidence,
            space: .work, sessionService: fixture.sessions))
        let resolved = try #require(try await fixture.sessions.fetch(id: session.id))
        #expect(resolved.pendingQuestion == nil)
        #expect(resolved.messages.first?.runStatus == .cancelled)
        #expect(fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work]?.contains(session.id) != true)
    }

    @Test("A queued follow-up stays queued during handoff and resumes only after explicit recovery abandonment")
    func queuedFollowUpOwnership() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Running")
        var session = ChatSession(title: "Synthetic queued follow-up")
        session.messages = [assistant]
        try await fixture.sessions.save(session)
        await fixture.model.load()
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = try await readyEngine()
        fixture.model.beginRun(run)
        fixture.model.inputText = "Queued follow-up"
        fixture.model.send()
        #expect(fixture.model.activeQueue.count == 1)
        #expect(fixture.model.session(id: session.id)?.messages.count == 1)
        #expect(fixture.model.handoffToDaemon() == 1)

        await fixture.model.resumeQueueForActiveSession()
        #expect(fixture.model.activeQueue.count == 1)
        #expect(fixture.model.session(id: session.id)?.messages.count == 1)
        #expect(fixture.engineSpy.attempts == 0)

        let record = try #require(fixture.store.records(in: .work).map(\.record).first { $0.sessionId == session.id })
        #expect(fixture.store.updateState(id: record.id, origin: .space(record.space),
            to: .recoveryRequired(reason: "synthetic unknown effect")) != nil)
        try await fixture.sessions.updateMessage(sessionId: session.id, messageId: assistant.id) {
            $0.runStatus = .cancelled
        }
        #expect(fixture.store.abandonRecovery(id: record.id, space: .work))
        await fixture.model.refreshFromDatabase()
        await fixture.model.resumeQueueForActiveSession()
        #expect(fixture.model.activeQueue.isEmpty)
        #expect(fixture.model.session(id: session.id)?.messages.count == 3)
        #expect(fixture.model.session(id: session.id)?.messages[1].content == "Queued follow-up")
    }

    @Test("Retry, edited resend and deletion obey Daemon ownership until abandonment", arguments: ["retry", "resend", "delete"])
    func otherConversationActionsRespectOwnership(_ action: String) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let user = ChatMessage(role: .user, content: "Original question")
        let assistant = ChatMessage(role: .assistant, content: "Running")
        var session = ChatSession(title: "Synthetic action gate")
        session.messages = [user, assistant]
        try await fixture.sessions.save(session)
        await fixture.model.load()
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = try await readyEngine()
        fixture.model.beginRun(run)
        #expect(fixture.model.handoffToDaemon() == 1)
        let record = try #require(fixture.store.records(in: .work).map(\.record).first { $0.sessionId == session.id })
        #expect(fixture.store.updateState(id: record.id, origin: .space(record.space),
            to: .recoveryRequired(reason: "synthetic unknown effect")) != nil)

        switch action {
        case "retry": fixture.model.retryAnswer(messageId: assistant.id)
        case "resend": fixture.model.resendEdited(messageId: user.id, newText: "Edited question")
        default: fixture.model.deleteSession(id: session.id)
        }
        for _ in 0..<3 { await Task.yield() }
        #expect(fixture.model.session(id: session.id)?.messages == session.messages)
        #expect(try await fixture.sessions.fetch(id: session.id)?.messages == session.messages)
        #expect(fixture.engineSpy.attempts == 0)

        try await fixture.sessions.updateMessage(sessionId: session.id, messageId: assistant.id) {
            $0.runStatus = .cancelled
        }
        #expect(fixture.store.abandonRecovery(id: record.id, space: .work))
        await fixture.model.refreshFromDatabase()
        #expect(!fixture.model.isActiveSessionBackgroundOwned)
        switch action {
        case "retry":
            fixture.model.retryAnswer(messageId: assistant.id)
            #expect(fixture.model.session(id: session.id)?.messages.last?.content != "Running")
        case "resend":
            fixture.model.resendEdited(messageId: user.id, newText: "Edited question")
            #expect(fixture.model.session(id: session.id)?.messages.first?.content == "Edited question")
        default:
            fixture.model.deleteSession(id: session.id)
            for _ in 0..<100 {
                if fixture.model.session(id: session.id) == nil,
                   try await fixture.sessions.fetch(id: session.id) == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(fixture.model.session(id: session.id) == nil)
            #expect(try await fixture.sessions.fetch(id: session.id) == nil)
        }
    }

    @Test("A cold App model cannot send into a recovery-required conversation")
    func coldStartRecoveryBlocksSend() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Outcome unknown")
        var session = ChatSession(title: "Synthetic cold recovery")
        session.messages = [assistant]
        try await fixture.sessions.save(session)
        fixture.model.sessions = [session]
        fixture.model.activeSessionId = session.id
        let run = ChatRunContext(space: .work, sessionID: session.id, messageID: assistant.id)
        run.engine = try await readyEngine()
        fixture.model.beginRun(run)
        #expect(fixture.model.handoffToDaemon() == 1)
        let record = try #require(fixture.store.records(in: .work).map(\.record).first { $0.sessionId == session.id })
        #expect(fixture.store.updateState(id: record.id, origin: .space(record.space),
            to: .recoveryRequired(reason: "synthetic unknown effect")) != nil)

        // A new model has no in-memory handedOffSessionIds. The production send
        // path must consult the injected durable store before accepting input.
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: fixture.queue))
        let registry = WorkspaceRegistry(fileURL: fixture.root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: fixture.root.appendingPathComponent("files")))
        let cold = ChatViewModel(hub: hub, space: .work, workspaceRegistry: registry,
            observeHostServices: false, handoffStore: fixture.store, draftDefaults: nil,
            makeEngine: { _ in
                fixture.engineSpy.attempts += 1
                throw ToolExecutionFailure(message: "Synthetic model request")
            })
        #expect(await cold.openTaskSource(sessionID: session.id, messageID: assistant.id))
        cold.inputText = "Please repeat the unfinished work"
        cold.send()
        #expect(cold.inputText == "Please repeat the unfinished work")
        #expect(cold.session(id: session.id)?.messages.count == 1)
        #expect(fixture.engineSpy.attempts == 0)

        try await fixture.sessions.updateMessage(sessionId: session.id, messageId: assistant.id) {
            $0.runStatus = .cancelled
        }
        #expect(fixture.store.abandonRecovery(id: record.id, space: .work))
        await cold.refreshFromDatabase()
        cold.send()
        #expect(cold.session(id: session.id)?.messages.count == 3)
        #expect(cold.session(id: session.id)?.messages[1].content == "Please repeat the unfinished work")
    }

    @Test("Unattributed legacy quarantine blocks a cold model from starting unrelated work")
    func unattributedQuarantineBlocksSend() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistant = ChatMessage(role: .assistant, content: "Saved answer")
        var session = ChatSession(title: "Synthetic unrelated conversation")
        session.messages = [assistant]
        try await fixture.sessions.save(session)
        let legacy = fixture.store.directory
            .appendingPathComponent("run-\(UUID().uuidString).json")
        try Data("{legacy-corrupt".utf8).write(to: legacy)
        #expect(fixture.store.locatedRecords().isEmpty)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(fixture.store.ownershipSnapshot().hasUnattributedQuarantine)

        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: fixture.queue))
        let registry = WorkspaceRegistry(fileURL: fixture.root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: fixture.root.appendingPathComponent("files")))
        let cold = ChatViewModel(hub: hub, space: .work, workspaceRegistry: registry,
            observeHostServices: false, handoffStore: fixture.store, draftDefaults: nil,
            makeEngine: { _ in
                fixture.engineSpy.attempts += 1
                throw ToolExecutionFailure(message: "Synthetic model request")
            })
        #expect(await cold.openTaskSource(sessionID: session.id, messageID: assistant.id))
        cold.inputText = "A new task"
        cold.send()
        #expect(cold.inputText == "A new task")
        #expect(cold.session(id: session.id)?.messages.count == 1)
        #expect(fixture.engineSpy.attempts == 0)

        let evidence = try #require(fixture.store.quarantinedEvidence().first)
        #expect(evidence.space == nil && evidence.sessionID == nil)
        #expect(fixture.store.abandonUnattributedEvidence(evidence))
        let abandoned = fixture.store.directory.appendingPathComponent("quarantine/abandoned", isDirectory: true)
        let preserved = try #require(FileManager.default.contentsOfDirectory(at: abandoned,
            includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: preserved) == Data("{legacy-corrupt".utf8))
        #expect(!fixture.store.ownershipSnapshot().hasUnattributedQuarantine)
        cold.send()
        #expect(cold.session(id: session.id)?.messages.count == 3)
        #expect(cold.session(id: session.id)?.messages[1].content == "A new task")
    }

    @Test("A cold recovery record blocks archive and removal of its workspace")
    func coldRecoveryBlocksWorkspaceMutation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = try fixture.registry.createWorkspace(named: "Synthetic owned project", for: .work)
        let answer = ChatMessage(role: .assistant, content: "Unknown result")
        var session = ChatSession(title: "Owned project", workspaceId: workspace.id.uuidString)
        session.messages = [answer]
        try await fixture.sessions.save(session)
        let record = recoveryRecord(space: .work, sessionID: session.id, messageID: answer.id)
        #expect(fixture.store.writeRecord(record))

        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: fixture.queue))
        let cold = ChatViewModel(hub: hub, space: .work, workspaceRegistry: fixture.registry,
            observeHostServices: false, handoffStore: fixture.store, draftDefaults: nil,
            makeEngine: { _ in throw ToolExecutionFailure(message: "Synthetic model request") })
        await cold.load()
        #expect(cold.session(id: session.id) != nil)
        #expect(cold.workspaces.contains { $0.id == workspace.id })
        cold.archiveSessions(in: workspace)
        cold.archiveSessionsIfSafe(session: session)
        #expect(cold.session(id: session.id)?.isArchived == false)
        #expect(try await fixture.sessions.fetch(id: session.id)?.isArchived == false)

        await cold.removeWorkspace(workspace)
        #expect(fixture.registry.workspaces(for: .work).contains { $0.id == workspace.id })
        #expect(cold.session(id: session.id)?.workspaceId == workspace.id.uuidString)
        #expect(try await fixture.sessions.fetch(id: session.id)?.workspaceId == workspace.id.uuidString)
    }

    @Test("The same session ID in another space can archive and send while work recovery is blocked")
    func sameSessionIDAcrossSpaces() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sharedSessionID = UUID()
        let workAnswer = ChatMessage(role: .assistant, content: "Work outcome unknown")
        var work = ChatSession(id: sharedSessionID, title: "Work")
        work.messages = [workAnswer]
        try await fixture.sessions.save(work)
        let workRecord = recoveryRecord(space: .work,
            sessionID: sharedSessionID, messageID: workAnswer.id)
        #expect(fixture.store.writeRecord(workRecord))

        let personalQueue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(personalQueue)
        let personalService = SessionService(databaseQueue: personalQueue)
        let personalAnswer = ChatMessage(role: .assistant, content: "Personal answer")
        var personal = ChatSession(id: sharedSessionID, title: "Personal")
        personal.messages = [personalAnswer]
        try await personalService.save(personal)
        #expect(try await personalService.fetch(id: sharedSessionID)?.messages.first?.content == "Personal answer")
        #expect(try await fixture.sessions.fetch(id: sharedSessionID)?.messages.first?.content == "Work outcome unknown")
        let personalHub = Hub(spaceStore: SpaceStore(space: .personal, databaseQueue: personalQueue))
        let personalModel = ChatViewModel(hub: personalHub, space: .personal,
            workspaceRegistry: fixture.registry, observeHostServices: false,
            handoffStore: fixture.store, draftDefaults: nil,
            makeEngine: { _ in
                fixture.engineSpy.attempts += 1
                throw ToolExecutionFailure(message: "Synthetic model request")
            })
        await personalModel.load()
        #expect(await personalModel.openTaskSource(sessionID: sharedSessionID,
            messageID: personalAnswer.id))
        #expect(personalModel.session(id: sharedSessionID)?.messages.first?.content == "Personal answer")
        let personalWorkspace = try #require(fixture.registry.defaultWorkspace(for: .personal))
        personalModel.archiveSessions(in: personalWorkspace)
        for _ in 0..<50 {
            if try await personalService.fetch(id: sharedSessionID)?.isArchived == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await personalService.fetch(id: sharedSessionID)?.isArchived == true)
        #expect(try await fixture.sessions.fetch(id: sharedSessionID)?.isArchived == false)
        personalModel.restoreSession(id: sharedSessionID)
        for _ in 0..<50 {
            if try await personalService.fetch(id: sharedSessionID)?.isArchived == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        personalModel.activeSessionId = sharedSessionID
        personalModel.inputText = "Independent personal request"
        personalModel.send()
        #expect(personalModel.session(id: sharedSessionID)?.messages.count == 3)
        #expect(personalModel.session(id: sharedSessionID)?.messages[1].content == "Independent personal request")
        #expect(try await fixture.sessions.fetch(id: sharedSessionID)?.messages == work.messages)
        #expect(fixture.store.records(in: .work).filter { $0.record.id == workRecord.id }
            .map(\.record.space) == [.work])
    }

    @Test("New run records with the same UUID occupy independent physical space directories")
    func spacePartitionedRunFiles() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionID = UUID(), workMessageID = UUID(), personalMessageID = UUID()
        let work = recoveryRecord(space: .work, sessionID: sessionID, messageID: workMessageID)
        let personal = DaemonRunRecord(id: work.id, space: .personal,
            sessionId: sessionID, assistantMessageId: personalMessageID,
            state: .recoveryRequired(reason: "independent personal recovery"),
            snapshot: work.snapshot, settings: work.settings)
        #expect(fixture.store.writeRecord(work))
        #expect(fixture.store.writeRecord(personal))
        let workDirectory = fixture.store.directory.appendingPathComponent("work", isDirectory: true)
        let personalDirectory = fixture.store.directory.appendingPathComponent("personal", isDirectory: true)
        for directory in [workDirectory, personalDirectory] {
            #expect(FileManager.default.fileExists(atPath:
                directory.appendingPathComponent("run-\(work.id.uuidString).json").path))
            #expect(FileManager.default.fileExists(atPath:
                directory.appendingPathComponent("owner-\(work.id.uuidString).json").path))
        }
        #expect(fixture.store.locatedRecords().filter { $0.record.id == work.id }
            .map(\.record.space).sorted { $0.rawValue < $1.rawValue }
            == [.personal, .work])
        #expect(!FileManager.default.fileExists(atPath:
            fixture.store.directory.appendingPathComponent("run-\(work.id.uuidString).json").path))
    }

    @Test("A legacy and a space record for one run ID stop automatic execution and preserve both copies")
    func duplicateLegacyAndSpaceRunFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        record.state = .pending
        #expect(fixture.store.writeRecord(record))
        let legacy = fixture.store.directory
        let partition = legacy.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: partition, withIntermediateDirectories: true)
        let rootRun = legacy.appendingPathComponent("run-\(record.id.uuidString).json")
        let rootOwner = legacy.appendingPathComponent("owner-\(record.id.uuidString).json")
        let spaceRun = partition.appendingPathComponent(rootRun.lastPathComponent)
        let spaceOwner = partition.appendingPathComponent(rootOwner.lastPathComponent)
        let source = FileManager.default.fileExists(atPath: rootRun.path) ? legacy : partition
        let destination = source == legacy ? partition : legacy
        for fileName in [rootRun.lastPathComponent, rootOwner.lastPathComponent] {
            let original = source.appendingPathComponent(fileName)
            let duplicate = destination.appendingPathComponent(fileName)
            try Data(contentsOf: original).write(to: duplicate, options: .atomic)
        }
        #expect(FileManager.default.fileExists(atPath: rootRun.path))
        #expect(FileManager.default.fileExists(atPath: spaceRun.path))
        #expect(FileManager.default.fileExists(atPath: rootOwner.path))
        #expect(FileManager.default.fileExists(atPath: spaceOwner.path))
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == record.id && $0.record.space == .work })
        #expect(fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work]?.contains(record.sessionId) == true)
    }

    @Test("A legacy handoff file conflicts with creation of the same space and run ID")
    func legacyHandoffPreventsDuplicateCreate() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        record.state = .pending
        let legacy = DaemonHandoff(id: record.id, space: .work,
            sessionId: record.sessionId, assistantMessageId: record.assistantMessageId,
            snapshot: record.snapshot, settings: record.settings)
        let legacyURL = try #require(fixture.store.write(legacy))
        #expect(!fixture.store.createHandoffRecord(record))
        let workRun = fixture.store.directory
            .appendingPathComponent("work/run-\(record.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(!FileManager.default.fileExists(atPath: workRun.path))

        // Simulate an interrupted older writer that already made the second
        // copy. Neither source may be handed to a Daemon for execution.
        #expect(fixture.store.writeRecord(record))
        #expect(FileManager.default.fileExists(atPath: workRun.path))
        #expect(!fixture.store.actionableLocatedRecords.contains {
            $0.record.id == record.id && $0.record.space == .work
        })
        #expect(fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work]?.contains(record.sessionId) == true)
    }

    @Test("A legacy handoff with a conflicting owner sidecar never becomes actionable")
    func legacyHandoffOwnerMismatchFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runID = UUID()
        let handoff = DaemonHandoff(id: runID, space: .work,
            sessionId: UUID(), assistantMessageId: UUID(),
            snapshot: recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID()).snapshot,
            settings: ChatViewModel.currentRunSettings(mode: .chat, workspacePath: ""))
        let handoffURL = try #require(fixture.store.write(handoff))
        struct ForeignOwner: Codable {
            let version = 1
            let id: UUID
            let space: AppSpace
            let sessionId: UUID
            let assistantMessageId: UUID
            let taskRunID: UUID? = nil
        }
        let sidecar = ForeignOwner(id: runID, space: .work,
            sessionId: UUID(), assistantMessageId: UUID())
        try JSONEncoder().encode(sidecar).write(to: fixture.store.directory
            .appendingPathComponent("owner-\(runID.uuidString).json"), options: .atomic)

        if case .uncertain = fixture.store.recordStatus(id: runID, origin: .legacyRoot) {
        } else {
            Issue.record("A legacy handoff and foreign owner sidecar must be uncertain")
        }
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == runID })
        #expect(!fixture.store.ownershipSnapshot().hasActionableRecords)
        #expect(fixture.store.unattributedLegacyEvidence().contains {
            $0.recordID == runID && $0.space == nil
        })
        #expect(FileManager.default.fileExists(atPath: handoffURL.path))
    }

    @Test("A legacy personal handoff paired with a work owner blocks both claimed spaces")
    func legacyHandoffCrossSpaceOwnerFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        struct ForeignOwner: Codable {
            let version = 1
            let id: UUID
            let space: AppSpace
            let sessionId: UUID
            let assistantMessageId: UUID
            let taskRunID: UUID? = nil
        }
        let runID = UUID(), personalSessionID = UUID(), workSessionID = UUID()
        let source = recoveryRecord(space: .personal,
            sessionID: personalSessionID, messageID: UUID())
        let handoff = DaemonHandoff(id: runID, space: .personal,
            sessionId: personalSessionID, assistantMessageId: source.assistantMessageId,
            snapshot: source.snapshot, settings: source.settings)
        let handoffURL = try #require(fixture.store.write(handoff))
        let owner = ForeignOwner(id: runID, space: .work,
            sessionId: workSessionID, assistantMessageId: UUID())
        try JSONEncoder().encode(owner).write(to: fixture.store.directory
            .appendingPathComponent("owner-\(runID.uuidString).json"), options: .atomic)

        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == runID })
        let ownership = fixture.store.ownershipSnapshot()
        #expect(!ownership.hasActionableRecords)
        #expect(ownership.blockedSessionIdsBySpace[.personal]?.contains(personalSessionID) == true)
        #expect(ownership.blockedSessionIdsBySpace[.work]?.contains(workSessionID) == true)
        #expect(ownership.hasUnattributedQuarantine || (
            ownership.blockedSessionIdsBySpace[.personal]?.contains(personalSessionID) == true &&
            ownership.blockedSessionIdsBySpace[.work]?.contains(workSessionID) == true))
        #expect(fixture.store.unattributedLegacyEvidence().contains {
            $0.recordID == runID && $0.space == nil
        })
        #expect(FileManager.default.fileExists(atPath: handoffURL.path))
    }

    @Test("Mismatched legacy handoff and owner require separate reviewed abandonment")
    func legacyHandoffMismatchAbandonmentOrder() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        struct ForeignOwner: Codable {
            let version = 1
            let id: UUID
            let space: AppSpace
            let sessionId: UUID
            let assistantMessageId: UUID
            let taskRunID: UUID? = nil
        }
        let runID = UUID(), workSessionID = UUID(), ownerMessageID = UUID()
        let source = recoveryRecord(space: .personal, sessionID: UUID(), messageID: UUID())
        let handoff = DaemonHandoff(id: runID, space: .personal,
            sessionId: source.sessionId, assistantMessageId: source.assistantMessageId,
            snapshot: source.snapshot, settings: source.settings)
        let handoffURL = try #require(fixture.store.write(handoff))
        let owner = ForeignOwner(id: runID, space: .work,
            sessionId: workSessionID, assistantMessageId: ownerMessageID)
        let ownerURL = fixture.store.directory.appendingPathComponent("owner-\(runID.uuidString).json")
        try JSONEncoder().encode(owner).write(to: ownerURL, options: .atomic)
        var workSession = ChatSession(id: workSessionID, title: "Synthetic owner review")
        workSession.messages = [ChatMessage(id: ownerMessageID, role: .assistant,
            content: "Owner-only recovery", runStatus: .recoveryRequired)]
        try await fixture.sessions.save(workSession)

        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == runID })
        let body = try #require(fixture.store.unattributedLegacyEvidence().first {
            $0.recordID == runID && $0.fileURL.lastPathComponent.hasPrefix("handoff-")
        })
        let ownerEvidence = try #require(fixture.store.quarantinedEvidence(in: .work).first {
            $0.recordID == runID && $0.fileURL.lastPathComponent.hasPrefix("owner-")
        })
        #expect(!fixture.store.abandonUnattributedEvidence(ownerEvidence))
        #expect(FileManager.default.fileExists(atPath: handoffURL.path))
        #expect(FileManager.default.fileExists(atPath: ownerURL.path))

        #expect(fixture.store.abandonUnattributedEvidence(body))
        #expect(!FileManager.default.fileExists(atPath: handoffURL.path))
        #expect(FileManager.default.fileExists(atPath: ownerURL.path))
        #expect(fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work]?.contains(workSessionID) == true)
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == runID })
        #expect(await fixture.store.abandonQuarantinedEvidence(ownerEvidence,
            space: .work, sessionService: fixture.sessions))
        #expect(!FileManager.default.fileExists(atPath: ownerURL.path))
        #expect(try await fixture.sessions.fetch(id: workSessionID)?.messages.first?.runStatus == .cancelled)
        #expect(!fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work, default: []].contains(workSessionID))
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == runID })
    }

    @Test("A corrupt attributable legacy copy blocks an otherwise valid space run with the same identity")
    func corruptLegacyDuplicateBlocksSpaceRun() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        record.state = .pending
        #expect(fixture.store.writeRecord(record))
        let root = fixture.store.directory
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let runName = "run-\(record.id.uuidString).json"
        let ownerName = "owner-\(record.id.uuidString).json"
        let legacyRun = root.appendingPathComponent(runName)
        let legacyOwner = root.appendingPathComponent(ownerName)
        let spaceRun = work.appendingPathComponent(runName)
        let spaceOwner = work.appendingPathComponent(ownerName)
        let original = FileManager.default.fileExists(atPath: spaceRun.path) ? work : root
        let copy = original == work ? root : work
        for fileName in [runName, ownerName] {
            try Data(contentsOf: original.appendingPathComponent(fileName))
                .write(to: copy.appendingPathComponent(fileName), options: .atomic)
        }
        try Data("{legacy-truncated".utf8).write(to: legacyRun, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: legacyOwner.path))
        #expect(FileManager.default.fileExists(atPath: spaceRun.path))
        #expect(FileManager.default.fileExists(atPath: spaceOwner.path))

        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == record.id && $0.record.space == .work })
        #expect(fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work]?.contains(record.sessionId) == true)
        #expect(FileManager.default.fileExists(atPath: legacyRun.path))
    }

    @Test("A corrupt attributable legacy duplicate cannot be abandoned while its new run is actionable")
    func attributableDuplicateAbandonmentFailsClosed() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        record.state = .pending
        let assistant = ChatMessage(id: record.assistantMessageId, role: .assistant,
            content: "Awaiting a decision", runStatus: .waitingForConfirmation)
        var session = ChatSession(id: record.sessionId, title: "Synthetic duplicate review")
        session.messages = [assistant]
        session.pendingConfirmation = PendingConfirmationSnapshot(messageId: assistant.id,
            toolName: "files_write", argumentsDisplay: "synthetic")
        try await fixture.sessions.save(session)
        #expect(fixture.store.writeRecord(record))
        let workOwner = fixture.store.directory.appendingPathComponent("work/owner-\(record.id.uuidString).json")
        let rootOwner = fixture.store.directory.appendingPathComponent("owner-\(record.id.uuidString).json")
        try Data(contentsOf: workOwner).write(to: rootOwner, options: .atomic)
        let corruptRoot = fixture.store.directory.appendingPathComponent("run-\(record.id.uuidString).json")
        try Data("{legacy-corrupt-duplicate".utf8).write(to: corruptRoot)
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == record.id })
        let evidence = try #require(fixture.store.quarantinedEvidence(in: .work).first {
            $0.origin == .legacyRoot && $0.fileURL.lastPathComponent.contains("run-\(record.id.uuidString).json")
        })
        #expect(await fixture.store.abandonQuarantinedEvidence(evidence,
            space: .work, sessionService: fixture.sessions) == false)
        let saved = try #require(try await fixture.sessions.fetch(id: session.id))
        #expect(saved.pendingConfirmation?.messageId == assistant.id)
        #expect(saved.messages.first?.runStatus == .waitingForConfirmation)
        #expect(FileManager.default.fileExists(atPath: evidence.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.store.directory
            .appendingPathComponent("work/run-\(record.id.uuidString).json").path))
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == record.id })
    }

    @Test("Unknown legacy evidence with a valid same-ID space run cannot be abandoned alone")
    func unattributedDuplicateAbandonmentFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        record.state = .pending
        #expect(fixture.store.writeRecord(record))
        let corruptRoot = fixture.store.directory.appendingPathComponent("run-\(record.id.uuidString).json")
        try Data("{legacy-unknown-duplicate".utf8).write(to: corruptRoot)
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == record.id })
        let evidence = try #require(fixture.store.unattributedLegacyEvidence().first {
            $0.recordID == record.id && $0.fileURL.lastPathComponent.contains("run-\(record.id.uuidString).json")
        })
        #expect(!fixture.store.abandonUnattributedEvidence(evidence))
        #expect(FileManager.default.fileExists(atPath: evidence.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.store.directory
            .appendingPathComponent("work/run-\(record.id.uuidString).json").path))
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == record.id })
    }

    @Test("An owner sidecar without its run body remains uncertain in the same space")
    func ownerOnlyRecordNeverLooksAbsent() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        record.state = .pending
        let work = fixture.store.directory.appendingPathComponent("work", isDirectory: true)
        let body = work.appendingPathComponent("run-\(record.id.uuidString).json")
        let owner = work.appendingPathComponent("owner-\(record.id.uuidString).json")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Occupy the body path so owner creation succeeds but the real atomic
        // body write fails, leaving the same evidence as a failed handoff.
        try FileManager.default.createDirectory(at: body, withIntermediateDirectories: false)
        #expect(!fixture.store.writeRecord(record))
        try FileManager.default.removeItem(at: body)
        #expect(FileManager.default.fileExists(atPath: owner.path))
        if case .uncertain = fixture.store.recordPresence(id: record.id, origin: .space(.work)) {
        } else {
            Issue.record("The space-specific presence must not release an owner-only handoff")
        }
        if case .uncertain = fixture.store.recordPresence(id: record.id) {
        } else {
            Issue.record("The global presence must not claim owner-only evidence is absent")
        }
        #expect(fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work]?.contains(record.sessionId) == true)
    }

    @Test("A legacy owner-only sidecar makes the matching new run uncertain across sources")
    func legacyOwnerOnlyDuplicateNeverLooksAbsent() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        record.state = .pending
        #expect(fixture.store.writeRecord(record))
        let workOwner = fixture.store.directory.appendingPathComponent("work/owner-\(record.id.uuidString).json")
        let legacyOwner = fixture.store.directory.appendingPathComponent("owner-\(record.id.uuidString).json")
        try Data(contentsOf: workOwner).write(to: legacyOwner, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: legacyOwner.path))
        if case .uncertain = fixture.store.recordPresence(id: record.id, origin: .legacyRoot) {
        } else {
            Issue.record("The legacy owner-only source must remain uncertain")
        }
        if case .uncertain = fixture.store.recordPresence(id: record.id) {
        } else {
            Issue.record("Two sources for one space/run identity must remain uncertain")
        }
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == record.id })
        #expect(fixture.store.ownershipSnapshot().blockedSessionIdsBySpace[.work]?.contains(record.sessionId) == true)
    }

    @Test("A same-ID foreign record cannot be mistaken for this App handoff write")
    func recordPresenceRequiresExactExpectedIdentity() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let existing = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        #expect(fixture.store.writeRecord(existing))
        func isValid(_ presence: DaemonHandoffStore.RecordPresence) -> Bool {
            if case .valid = presence { return true }
            return false
        }
        func isUncertain(_ presence: DaemonHandoffStore.RecordPresence) -> Bool {
            if case .uncertain = presence { return true }
            return false
        }
        #expect(isValid(fixture.store.recordPresence(matching: existing, origin: .space(.work))))

        let otherSession = DaemonRunRecord(id: existing.id, space: .work,
            sessionId: UUID(), assistantMessageId: existing.assistantMessageId,
            createdAt: existing.createdAt, updatedAt: existing.updatedAt,
            state: existing.state, snapshot: existing.snapshot, settings: existing.settings)
        let otherMessage = DaemonRunRecord(id: existing.id, space: .work,
            sessionId: existing.sessionId, assistantMessageId: UUID(),
            createdAt: existing.createdAt, updatedAt: existing.updatedAt,
            state: existing.state, snapshot: existing.snapshot, settings: existing.settings)
        var otherSettings = existing.settings
        otherSettings.taskAuthorization = TaskExecutionScope(space: .work,
            sessionID: existing.sessionId, runID: UUID(), parentRunID: nil,
            workspaceID: nil, workspacePath: "", workspaceIdentity: nil,
            writeRootIdentities: [:], permissionMode: .workspaceWrite,
            approvalPolicyVersion: "synthetic", autoReviewEnabled: false,
            readRoots: [], writeRoots: [], artifactRoots: [], capabilities: [],
            constraints: [], userRequest: "Synthetic collision")
        let otherTaskRun = DaemonRunRecord(id: existing.id, space: .work,
            sessionId: existing.sessionId, assistantMessageId: existing.assistantMessageId,
            createdAt: existing.createdAt, updatedAt: existing.updatedAt,
            state: existing.state, snapshot: existing.snapshot, settings: otherSettings)
        for foreign in [otherSession, otherMessage, otherTaskRun] {
            #expect(isUncertain(fixture.store.recordPresence(matching: foreign, origin: .space(.work))))
        }
        #expect(fixture.store.records(in: .work).contains {
            $0.record.id == existing.id && $0.record.sessionId == existing.sessionId
        })
    }

    @Test("A run placed in the other space directory is never executed or silently discarded")
    func spaceDirectoryIdentityMismatchFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        record.state = .pending
        #expect(fixture.store.writeRecord(record))
        let root = fixture.store.directory
        let work = root.appendingPathComponent("work", isDirectory: true)
        let personal = root.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        let fileNames = ["run-\(record.id.uuidString).json", "owner-\(record.id.uuidString).json"]
        let source = FileManager.default.fileExists(atPath: work.appendingPathComponent(fileNames[0]).path)
            ? work : root
        for fileName in fileNames {
            try FileManager.default.moveItem(at: source.appendingPathComponent(fileName),
                to: personal.appendingPathComponent(fileName))
        }
        #expect(fileNames.allSatisfy { FileManager.default.fileExists(atPath:
            personal.appendingPathComponent($0).path) })
        #expect(!fixture.store.actionableLocatedRecords.contains { $0.record.id == record.id })
        let ownership = fixture.store.ownershipSnapshot()
        func blocked(_ space: AppSpace) -> Bool {
            ownership.hasUnattributedQuarantine || ownership.unattributedSpaces.contains(space) ||
                ownership.blockedSessionIdsBySpace[space]?.contains(record.sessionId) == true
        }
        #expect(blocked(.work))
        #expect(blocked(.personal))
    }

    @Test("Unknown personal evidence cannot be abandoned through the neutral legacy recovery API")
    func partitionUnknownEvidenceRejectsNeutralAbandonment() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let personal = fixture.store.directory.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        let raw = personal.appendingPathComponent("run-\(UUID().uuidString).json")
        try Data("{personal-broken".utf8).write(to: raw)
        #expect(fixture.store.records(in: .personal).isEmpty)
        let evidence = try #require(fixture.store.quarantinedEvidence().first {
            $0.origin == .space(.personal) && $0.space == nil
        })
        #expect(fixture.store.quarantinedEvidence(in: .work).isEmpty)
        #expect(fixture.store.unattributedEvidence(in: .work).isEmpty)
        #expect(fixture.store.unattributedEvidence(in: .personal).contains { $0.id == evidence.id })
        #expect(!fixture.store.abandonUnattributedEvidence(evidence))
        #expect(!fixture.store.abandonUnattributedEvidence(evidence, in: .work))
        #expect(FileManager.default.fileExists(atPath: evidence.fileURL.path))
        #expect(fixture.store.ownershipSnapshot().unattributedSpaces.contains(.personal))
        #expect(fixture.store.abandonUnattributedEvidence(evidence, in: .personal))
        let abandoned = personal.appendingPathComponent("quarantine/abandoned", isDirectory: true)
        let preserved = try #require(FileManager.default.contentsOfDirectory(at: abandoned,
            includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: preserved) == Data("{personal-broken".utf8))
        #expect(!fixture.store.ownershipSnapshot().unattributedSpaces.contains(.personal))
    }

    @Test("Personal unknown evidence may be abandoned without touching a same-ID work run")
    func scopedUnknownSameRunIDKeepsOtherSpace() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var work = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        work.state = .pending
        #expect(fixture.store.writeRecord(work))
        let personal = fixture.store.directory.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        let raw = personal.appendingPathComponent("run-\(work.id.uuidString).json")
        try Data("{personal-only-corrupt".utf8).write(to: raw)
        _ = fixture.store.records(in: .personal)
        let evidence = try #require(fixture.store.unattributedEvidence(in: .personal).first {
            $0.recordID == work.id
        })
        #expect(!fixture.store.abandonUnattributedEvidence(evidence))
        #expect(!fixture.store.abandonUnattributedEvidence(evidence, in: .work))
        #expect(fixture.store.abandonUnattributedEvidence(evidence, in: .personal))
        let abandoned = personal.appendingPathComponent("quarantine/abandoned", isDirectory: true)
        let preserved = try #require(FileManager.default.contentsOfDirectory(at: abandoned,
            includingPropertiesForKeys: nil).first {
                $0.lastPathComponent.contains("run-\(work.id.uuidString).json")
            })
        #expect(try Data(contentsOf: preserved) == Data("{personal-only-corrupt".utf8))
        #expect(fixture.store.records(in: .work).contains {
            $0.record.id == work.id && $0.record.sessionId == work.sessionId
        })
        #expect(fixture.store.actionableLocatedRecords.contains {
            $0.record.id == work.id && $0.record.space == .work
        })
        #expect(!fixture.store.ownershipSnapshot().unattributedSpaces.contains(.personal))
    }

    @Test("A work scoped read preserves personal evidence and a cross-path claim blocks cold sends")
    func scopedReadIsPureAndCrossPathClaimFailsClosed() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let personal = fixture.store.directory.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        let workRecord = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        #expect(fixture.store.writeRecord(workRecord))

        let foreignURL = personal.appendingPathComponent("run-\(UUID().uuidString).json")
        let malformed = Data("{personal-only-corrupt".utf8)
        try malformed.write(to: foreignURL)
        #expect(fixture.store.records(in: .work).map(\.record.id) == [workRecord.id])
        #expect(try Data(contentsOf: foreignURL) == malformed)
        #expect(fixture.store.ownershipSnapshot().unattributedSpaces.contains(.personal))
        #expect(!fixture.store.ownershipSnapshot().hasUnattributedQuarantine)

        // The body is decodable but physically in the wrong space, with no
        // owner sidecar. A work send must fail closed synchronously, without
        // waiting for the periodic Supervisor cache to refresh.
        let wrongPath = recoveryRecord(space: .work, sessionID: UUID(), messageID: UUID())
        let wrongURL = personal.appendingPathComponent("run-\(wrongPath.id.uuidString).json")
        let original = try JSONEncoder().encode(wrongPath)
        try original.write(to: wrongURL)
        let ownership = fixture.store.ownershipSnapshot()
        #expect(ownership.hasUnattributedQuarantine)
        #expect(ownership.blockedSessionIdsBySpace[.work]?.contains(wrongPath.sessionId) == true)
        #expect(try Data(contentsOf: wrongURL) == original)

        let assistant = ChatMessage(role: .assistant, content: "Existing answer")
        var session = ChatSession(title: "Cold work session")
        session.messages = [assistant]
        try await fixture.sessions.save(session)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: fixture.queue))
        let cold = ChatViewModel(hub: hub, space: .work, workspaceRegistry: fixture.registry,
            observeHostServices: false, handoffStore: fixture.store, draftDefaults: nil,
            makeEngine: { _ in
                fixture.engineSpy.attempts += 1
                throw ToolExecutionFailure(message: "Synthetic model request")
            })
        #expect(await cold.openTaskSource(sessionID: session.id, messageID: assistant.id))
        cold.inputText = "Must wait for review"
        cold.send()
        #expect(cold.inputText == "Must wait for review")
        #expect(cold.session(id: session.id)?.messages.count == 1)
        #expect(fixture.engineSpy.attempts == 0)
        #expect(try Data(contentsOf: foreignURL) == malformed)
        #expect(try Data(contentsOf: wrongURL) == original)
    }
}
