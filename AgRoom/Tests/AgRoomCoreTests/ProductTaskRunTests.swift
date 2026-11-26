import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Independent task runs and current-space task center")
@MainActor
struct ProductTaskRunTests {
    private func queue() throws -> DatabaseQueue {
        let value = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(value); return value
    }
    private func session(title: String = "Request", runID: UUID = UUID(), at date: Date = Date(), status: TaskRunStatus = .succeeded,
                         answer: String = "Saved answer") -> ChatSession {
        var session = ChatSession(title: title)
        session.messages = [ChatMessage(role: .user, content: title), ChatMessage(role: .assistant, content: answer,
            runStatus: status, taskRun: .init(id: runID, startedAt: date))]
        return session
    }

    private func loadedModel(id: UUID, database: DatabaseQueue, root: URL, space: AppSpace = .work, spaceStore: SpaceStore? = nil,
                             makeEngine: @escaping @MainActor () async throws -> DispatcherEngine) async throws -> ChatViewModel {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: root.appendingPathComponent("files")))
        let model = ChatViewModel(hub: Hub(spaceStore: spaceStore ?? SpaceStore(space: space, databaseQueue: database)),
            space: space, workspaceRegistry: registry, observeHostServices: false,
            handoffStore: DaemonHandoffStore(baseDirectory: root.appendingPathComponent("daemon")), draftDefaults: nil,
            makeEngine: { _ in try await makeEngine() })
        await model.load()
        model.activeSessionId = id
        await model.retryLoadActiveMessages()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.session(id: id)?.isMessagesLoaded != true && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let loaded = try #require(model.session(id: id))
        try #require(loaded.isMessagesLoaded && loaded.messages.count >= 2)
        return model
    }

    private func replyEngine() -> DispatcherEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaskRetryReplyProtocol.self]
        let provider = CloudProvider(config: .init(name: "Retry fixture", endpoint: "https://retry.invalid/v1/chat/completions", model: "fixture"),
            apiKey: "", session: URLSession(configuration: configuration))
        return DispatcherEngine(provider: provider, tools: [], systemPrompt: "Synthetic retry fixture", maxSteps: 2)
    }

    private func waitForRun(_ model: ChatViewModel, service: SessionService) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var saved = false
        // Streaming ends before the final asynchronous save. Observe the durable
        // answer for this run before asserting its status and task receipt.
        while ContinuousClock.now < deadline {
            if !model.isAnyRunning, let id = model.activeSessionId,
               let answer = model.session(id: id)?.messages.last, answer.runStatus != .running,
               let stored = try await service.fetch(id: id)?.messages.last,
               stored.id == answer.id, stored.taskRun?.id == answer.taskRun?.id, stored.runStatus == answer.runStatus {
                saved = true; break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isAnyRunning)
        let runtime = model.activeSessionId.flatMap { model.session(id: $0)?.messages.last }
        let persisted: ChatMessage?
        if let id = model.activeSessionId { persisted = try await service.fetch(id: id)?.messages.last }
        else { persisted = nil }
        try #require(saved, "Runtime status=\(runtime?.runStatus?.rawValue ?? "nil"), stored status=\(persisted?.runStatus?.rawValue ?? "nil"), same message=\(runtime?.id == persisted?.id), same execution=\(runtime?.taskRun?.id == persisted?.taskRun?.id), save failed=\(model.isActiveSessionPersistFailed), error present=\(model.errorMessage != nil)")
        #expect(model.errorMessage == nil)
    }

    @Test("Failed UI answers can be retried repeatedly after reload, retaining each execution under one message", arguments: [AppSpace.work, .personal])
    func failedAnswerRetry(space: AppSpace) async throws {
        let db = try queue(), service = SessionService(databaseQueue: db), history = ProductTaskRunStore(databaseQueue: db)
        var task = session(title: "Synthetic retry")
        task.messages[1] = task.messages[1].appendingError("Original failure")
        let original = task.messages[1], firstRun = try #require(original.taskRun)
        try await service.save(task)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var builds = 0
        let model = try await loadedModel(id: task.id, database: db, root: root, space: space) {
            builds += 1
            let placeholder = try #require(try await service.fetch(id: task.id)?.messages.last)
            #expect(placeholder.id == original.id && placeholder.runStatus == .running)
            if builds < 3 { throw LLMError.configurationError(reason: "Synthetic retry failure") }
            return replyEngine()
        }
        var runIDs: Set<UUID> = [firstRun.id]
        for attempt in 1...3 {
            model.retryAnswer(messageId: original.id)
            try await waitForRun(model, service: service)
            try #require(!model.isActiveSessionPersistFailed)
            try #require(builds == attempt)
            let saved = try #require(try await service.fetch(id: task.id)?.messages.last)
            let identity = try #require(saved.taskRun)
            #expect(saved.id == original.id && saved.timestamp == original.timestamp)
            #expect(runIDs.insert(identity.id).inserted)
            #expect(saved.variations?.count == attempt + 1)
            #expect(saved.variations?.first?.taskRun == firstRun)
            #expect(saved.variations?.first?.content == original.content)
            #expect(saved.runStatus == (attempt == 3 ? .succeeded : .failed))
            let receipt = try #require(try await history.run(id: identity.id))
            #expect(receipt.messageID == original.id && receipt.sessionID == task.id && receipt.status == saved.runStatus)
            #expect(try await history.run(id: firstRun.id)?.answer == original.content)
        }
        #expect(try await history.summaries().count == 4)
        let metrics = try await ProductPreferencesService(databaseQueue: db).metrics()
        #expect(metrics.tasksStarted == 4 && metrics.tasksCompleted == 1)
    }

    @Test("UI edited resends retain answer identity, version questions and original task receipts", arguments: [false, true])
    func editedQuestionKeepsIdentity(failed: Bool) async throws {
        let db = try queue(), service = SessionService(databaseQueue: db), history = ProductTaskRunStore(databaseQueue: db)
        var task = session(title: "Synthetic original question")
        if failed { task.messages[1] = task.messages[1].appendingError("Original failure") }
        let original = task.messages[1], firstRun = try #require(original.taskRun)
        try await service.save(task)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var builds = 0
        let model = try await loadedModel(id: task.id, database: db, root: root) {
            builds += 1
            return replyEngine()
        }
        var runIDs: Set<UUID> = [firstRun.id]
        for (index, question) in ["Edited question", "Edited again"].enumerated() {
            model.resendEdited(messageId: task.messages[0].id, newText: question)
            try await waitForRun(model, service: service)
            try #require(!model.isActiveSessionPersistFailed)
            try #require(builds == index + 1)
            let saved = try #require(try await service.fetch(id: task.id))
            let answer = try #require(saved.messages.last), identity = try #require(answer.taskRun)
            #expect(saved.messages[0].content == question)
            #expect(answer.id == original.id && answer.timestamp == original.timestamp)
            #expect(answer.runStatus == .succeeded)
            #expect(runIDs.insert(identity.id).inserted)
            #expect(answer.variations?.count == index + 2 && answer.variations?.last?.question == question)
            #expect(answer.variations?.first?.question == task.messages[0].content)
            let receipt = try #require(try await history.run(id: identity.id))
            #expect(receipt.prompt == question && receipt.messageID == original.id)
            #expect(try await history.run(id: firstRun.id)?.answer == original.content)
            #expect(try await history.run(id: firstRun.id)?.prompt == task.messages[0].content)
        }
        model.switchVariation(messageId: original.id, to: 0)
        await model.retryPersistActiveSession()
        #expect(!model.isActiveSessionPersistFailed)
        #expect(try await history.summaries().count == 3)
        #expect(try await history.run(id: firstRun.id)?.status == original.runStatus)
    }

    @Test("Editing an earlier UI question creates a separate branch without reassigning original executions")
    func editedEarlierQuestionBranches() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db), history = ProductTaskRunStore(databaseQueue: db)
        var task = session(title: "Synthetic branch question")
        task.messages += session(title: "Follow-up").messages
        let originals = task.messages
        try await service.save(task)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-branch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await loadedModel(id: task.id, database: db, root: root) { replyEngine() }
        model.resendEdited(messageId: task.messages[0].id, newText: "Branch edit")
        try await waitForRun(model, service: service)
        try #require(!model.isActiveSessionPersistFailed)
        let branchID = try #require(model.activeSessionId)
        #expect(branchID != task.id)
        let branch = try #require(try await service.fetch(id: branchID))
        let answer = try #require(branch.messages.last), identity = try #require(answer.taskRun)
        #expect(answer.id != originals[1].id && answer.runStatus == .succeeded)
        #expect(try await history.run(id: identity.id)?.sessionID == branchID)
        #expect(try await service.fetch(id: task.id)?.messages == originals)
        #expect(try await history.summaries().count == 3)
    }

    @Test("Paged retry and edited resend persist every source turn before inference", arguments: ["retry", "edit", "boundary"])
    func pagedBranch(_ action: String) async throws {
        let db = try queue(), service = SessionService(databaseQueue: db)
        var original = ChatSession(title: "Paged history")
        for n in 0..<120 {
            original.messages.append(ChatMessage(role: .user, content: "question-\(n)", memoryExcluded: n == 2 ? true : nil))
            original.messages.append(ChatMessage(role: .assistant, content: "answer-\(n)", memoryExcluded: [70, 115].contains(n) ? true : nil))
        }
        if action == "boundary" { original.messages.append(ChatMessage(role: .user, content: "last")) }
        try await service.save(original)
        let source = original
        let pivot = action == "boundary" ? 141 : 231
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let model = try await loadedModel(id: source.id, database: db, root: root) {
            calls += 1
            let branch = try #require(try await service.getAll().first { $0.id != source.id })
            #expect(branch.messages.count == pivot + 1)
            #expect(branch.messages.first?.content == "question-0")
            #expect(branch.messages.last?.memoryExcluded == true)
            #expect(branch.messages[4].memoryExcluded == true)
            #expect(ChatViewModel.memoryEligibleMessages(in: branch.messages).contains { $0.content == "question-2" } == false)
            return replyEngine()
        }
        let page = try #require(model.session(id: source.id))
        try #require(page.messages.count == 100 && page.messageOffset > 0)
        if action == "boundary" { try #require(page.messages.first?.id == source.messages[pivot].id) }
        if action == "edit" { model.resendEdited(messageId: source.messages[pivot - 1].id, newText: "updated") }
        else { model.retryAnswer(messageId: source.messages[pivot].id) }
        model.retryAnswer(messageId: source.messages[pivot].id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.activeSessionId == source.id && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.activeSessionId != source.id)
        try await waitForRun(model, service: service)
        #expect(calls == 1)
        #expect(try await service.fetch(id: source.id)?.messages == source.messages)
        #expect(try await service.getAll().count == 2)
    }

    @Test("Stale paged branch requests cannot invoke the provider", arguments: ["restore", "switch"])
    func staleBranch(_ cause: String) async throws {
        let db = try queue(), service = SessionService(databaseQueue: db)
        var original = ChatSession()
        original.messages = (0..<120).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "row \($0)") }
        try await service.save(original)
        let source = original, root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = SpaceStore(space: .work, databaseQueue: db)
        var calls = 0
        let model = try await loadedModel(id: source.id, database: db, root: root, spaceStore: spaces) { calls += 1; return replyEngine() }
        if cause == "restore" {
            try await db.write { try $0.execute(sql: "INSERT INTO chat_restore_tokens(sessionId,token) VALUES (?,?)", arguments: [source.id.uuidString, "restored"]) }
        }
        model.retryAnswer(messageId: source.messages[111].id)
        if cause == "switch" { spaces.switchTo(.personal); spaces.switchTo(.work) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while model.isActiveSessionLoading && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.activeSessionId == source.id && calls == 0)
        #expect(try await service.getAll().map(\.id) == [source.id])
    }

    @Test("Restoring the source after preparing a branch aborts its first transaction")
    func restoreBeforeBranchCommit() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db)
        var source = ChatSession()
        source.messages = [ChatMessage(role: .user, content: "source")]
        try await service.save(source)
        let loaded = try #require(try await service.fetch(id: source.id))
        let copy = try #require(loaded.branch(titleSuffix: " copy"))
        let version = SessionRestoreVersion(id: loaded.id, token: loaded.restorationToken)
        try await db.write { try $0.execute(sql: "INSERT INTO chat_restore_tokens(sessionId,token) VALUES (?,?)", arguments: [loaded.id.uuidString, "new"]) }
        await #expect(throws: SessionServiceError.staleAfterRestore) { try await service.save(copy, branchSource: version) }
        #expect(try await service.fetch(id: copy.id) == nil)
        #expect(try await service.fetch(id: loaded.id)?.messages == loaded.messages)
    }

    @Test("Damage outside the displayed page blocks the branch and the provider")
    func damagedBranchSource() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db)
        var original = ChatSession()
        original.messages = (0..<120).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "row \($0)") }
        try await service.save(original)
        let source = original
        try await db.write { db in try db.execute(sql: "UPDATE chat_messages SET payload = 'broken' WHERE sessionId = ? AND seq = 0", arguments: [source.id.uuidString]) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let model = try await loadedModel(id: source.id, database: db, root: root) { calls += 1; return replyEngine() }
        model.retryAnswer(messageId: source.messages[111].id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while model.errorMessage == nil && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.isActiveSessionCorrupted && model.activeSessionId == source.id)
        #expect(calls == 0 && model.sessions.count == 1)
        #expect(try await db.read { try String.fetchOne($0, sql: "SELECT payload FROM chat_messages WHERE seq = 0") } == "broken")
    }

    @Test("Saving a different message cannot claim an existing execution identity")
    func conflictingOwnershipStillFails() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db)
        let original = session(title: "Original ownership")
        try await service.save(original)
        var changed = original
        changed.messages[1] = ChatMessage(role: .assistant, content: "Conflicting replacement", taskRun: original.messages[1].taskRun)
        await #expect(throws: ProductTaskHistoryError.self) { try await service.save(changed) }
        #expect(try await service.fetch(id: original.id)?.messages == original.messages)
    }

    @Test("Retry keeps both executions, while input and approval resumes keep one identity and one metric receipt")
    func retriesAndResumes() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db), history = ProductTaskRunStore(databaseQueue: db)
        let firstID = UUID(), secondID = UUID()
        var task = session(runID: firstID, status: .running, answer: "")
        let messageID = task.messages[1].id
        try await service.save(task)
        try await service.updateMessage(sessionId: task.id, messageId: messageID) { $0.runStatus = .waitingForConfirmation }
        #expect(try await history.run(id: firstID)?.status == .waitingForConfirmation)
        try await service.updateMessage(sessionId: task.id, messageId: messageID) { $0.runStatus = .running }
        task.messages[1].content = "First actual result"; task.messages[1].runStatus = .succeeded
        try await service.save(task)
        let first = try #require(try await history.run(id: firstID))
        let original = task.messages[1]
        task.messages[1].variations = [AnswerVariation(question: "Request", message: original), AnswerVariation(question: "Try again", content: "")]
        task.messages[1].activeVariationIndex = 1
        let secondIdentity = ProductTaskIdentity(id: secondID)
        task.messages[1].taskRun = secondIdentity
        task.messages[1].content = ""; task.messages[1].runStatus = .running
        task.messages[1].variations?[1].taskRun = secondIdentity
        try await service.save(task)
        let failedMessage = task.messages[1].appendingError("Second attempt failed")
        task.messages[1] = failedMessage
        task.messages[1].variations?[1] = AnswerVariation(question: "Try again", message: failedMessage)
        try await service.save(task)
        #expect(try await history.run(id: firstID)?.answer == "First actual result")
        #expect(try await history.run(id: secondID)?.status == .failed)
        #expect(try await history.summaries().count == 2)
        let metrics = try await ProductPreferencesService(databaseQueue: db).metrics()
        #expect(metrics.tasksStarted == 2 && metrics.tasksCompleted == 1)
        // Later UI metadata and stale progress must not relabel or regress the first run.
        task.mode = .coding; task.workspaceId = UUID().uuidString
        task.messages[1] = original
        try await service.save(task)
        try await service.updateMessage(sessionId: task.id, messageId: messageID) { $0.runStatus = .running }
        let stable = try #require(try await history.run(id: firstID))
        #expect(stable.status == .succeeded && stable.startedAt == first.startedAt && stable.mode == .chat && stable.workspaceID == first.workspaceID)
        #expect(stable.finishedAt == first.finishedAt)
    }

    @Test("History survives message replacement; copying context adds no execution; deleting a conversation erases its task text")
    func copyEditDeleteSemantics() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db), history = ProductTaskRunStore(databaseQueue: db)
        let identity = UUID()
        let original = session(runID: identity)
        try await service.save(original)
        var branch = try #require(original.branch(titleSuffix: " copy"))
        try await service.save(branch)
        #expect(try await history.summaries().count == 1)
        branch.messages[1].taskRun = .init()
        branch.messages[1].sourceTaskRunID = nil
        branch.messages[1].content = "New execution in copied context"
        try await service.save(branch)
        #expect(try await history.summaries().count == 2)
        var edited = original; edited.messages = [original.messages[0]]
        try await service.save(edited)
        #expect(try await history.run(id: identity)?.answer == original.messages[1].content)
        try await service.delete(id: original.id)
        #expect(try await history.run(id: identity) == nil)
        #expect(try await history.summaries().count == 1)
        #expect(try await service.fetch(id: branch.id)?.messages.last?.content == "New execution in copied context")
    }

    @Test("Task history and conversation writes commit atomically and never publish a task after a failed save")
    func transactionalSaveFailure() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db)
        let task = session(status: .running)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_task_history BEFORE INSERT ON product_task_runs BEGIN SELECT RAISE(FAIL, 'injected'); END") }
        await #expect(throws: (any Error).self) { try await service.save(task) }
        #expect(try await service.fetch(id: task.id) == nil)
        #expect(try await ProductTaskRunStore(databaseQueue: db).summaries().isEmpty)
        #expect(try await ProductPreferencesService(databaseQueue: db).metrics().tasksStarted == 0)
    }

    @Test("Old answer variations migrate independently without invented metrics or finish times")
    func legacyMigration() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db)
        var task = ChatSession(title: "Legacy")
        task.messages = [.init(role: .user, content: "Question"), .init(role: .assistant, content: "Second",
            variations: [.init(question: "Question", content: "First"), .init(question: "Edited", content: "Second")], activeVariationIndex: 1)]
        try await service.save(task)
        let taskID = task.id
        try await db.write { db in
            try db.execute(sql: "DROP TABLE product_task_runs")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v1_product_task_runs'")
            try db.execute(sql: "INSERT INTO chat_messages(sessionId,seq,payload) VALUES (?,2,'damaged row retained for repair')", arguments: [taskID.uuidString])
        }
        try DatabaseBootstrap.prepareSpace(db)
        let store = ProductTaskRunStore(databaseQueue: db)
        let summaries = try await store.summaries()
        #expect(summaries.count == 2)
        for summary in summaries {
            let run = try #require(try await store.run(id: summary.id))
            #expect(run.isLegacy && run.finishedAt == nil)
        }
        #expect(try await ProductPreferencesService(databaseQueue: db).metrics().tasksStarted == 0)
        let legacyBlob = try JSONEncoder().encode(task.messages)
        try await db.write { db in
            try db.execute(sql: "DROP TABLE product_task_runs; DROP TABLE chat_messages")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v1_product_task_runs'")
            try db.execute(sql: "UPDATE chat_sessions SET messagesJSON=? WHERE id=?", arguments: [String(decoding: legacyBlob, as: UTF8.self), taskID.uuidString])
        }
        try DatabaseBootstrap.prepareSpace(db)
        #expect(try await store.summaries().count == 2)
    }

    @Test("One timeline pages chat, team, scheduled and job runs without duplicates, and isolates equal IDs across spaces")
    func unifiedTimelineAndIsolation() async throws {
        let work = try queue(), personal = try queue(), id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let workTask = session(title: "Work result", runID: id, at: date)
        try await SessionService(databaseQueue: work).save(workTask)
        try await SessionService(databaseQueue: personal).save(session(title: "Personal private", runID: id, at: date))
        let teamID = UUID()
        let plan = TeamPlan(goal: "Team result", subtasks: [.init(title: "Analyze", objective: "Read")])
        let report = TeamTaskReport(taskID: teamID, goal: plan.goal, status: .completed, subtasks: [], artifacts: [], usage: .zero,
            openQuestions: [], errors: [], startedAt: date, finishedAt: date)
        try await TeamTaskStore(databaseQueue: work).save(plan: plan, report: report)
        let scheduled = ScheduledRun(taskID: UUID(), taskName: "Scheduled result", trigger: .manual, scheduledFor: nil,
            status: .succeeded, startedAt: date, finishedAt: date, outputText: "Scheduled full output")
        _ = try await ScheduledRunStore(databaseQueue: work).insert(scheduled)
        var workJob = BackgroundJob(name: "Work job", kind: "test", space: .work, submittedAt: date)
        workJob.state = .succeeded
        let personalJob = BackgroundJob(name: "Personal job", kind: "test", space: .personal, submittedAt: date)
        let center = ProductTaskCenterStore(databaseQueue: work, space: .work)
        let jobs = [workJob, personalJob]
        let first = try await center.page(limit: 2, jobs: jobs)
        let second = try await center.page(before: #require(first.items.last), limit: 2, jobs: jobs)
        #expect(first.hasMore && !second.hasMore)
        let all = first.items + second.items
        #expect(all.count == 4 && Set(all.map(\.id)).count == 4)
        #expect(Set(all.map(\.source)) == [.chat, .team, .scheduled, .job])
        #expect(all.allSatisfy { !$0.title.contains("Personal") })
        let privatePage = try await ProductTaskCenterStore(databaseQueue: personal, space: .personal).page(jobs: jobs)
        #expect(privatePage.items.count == 2 && privatePage.items.contains { $0.title == "Personal private" })
        #expect(try await center.page(source: .scheduled).items.first?.sourceID == scheduled.id)
        #expect(try await center.page(search: "work").items.count == 1)
    }

    @Test("Attention filtering finds old unresolved tasks and detects orphaned running snapshots")
    func attentionAndActivity() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let waiting = session(title: "Old approval", at: old, status: .waitingForConfirmation)
        let orphanID = UUID(), activeID = UUID()
        try await service.save(waiting)
        try await service.save(session(title: "Orphan", runID: orphanID, at: old, status: .running))
        try await service.save(session(title: "Active", runID: activeID, status: .running))
        for index in 0..<45 { try await service.save(session(title: "Finished \(index)")) }
        let center = ProductTaskCenterStore(databaseQueue: db, space: .work)
        let attention = try await center.page(group: .attention, activeChatRunIDs: [activeID])
        #expect(attention.items.count == 2)
        #expect(attention.items.first(where: { $0.sourceID == orphanID })?.status == .recoveryRequired)
        let active = try await center.page(group: .active, activeChatRunIDs: [activeID])
        #expect(active.items.map(\.sourceID) == [activeID])
        let finished = try await center.page(group: .finished)
        #expect(finished.items.count == 40 && finished.hasMore)
        let rest = try await center.page(group: .finished, before: #require(finished.items.last))
        #expect(rest.items.count == 5 && !rest.hasMore)
    }

    @Test("Clearing finished history includes coding and every source beyond one page, retaining originals and pending work")
    func clearFinishedTimeline() async throws {
        let db = try queue(), personal = try queue(), service = SessionService(databaseQueue: db)
        let center = ProductTaskCenterStore(databaseQueue: db, space: .work)
        let id = UUID()
        var coding = session(title: "Coding request", runID: id)
        coding.mode = .coding
        try await service.save(coding)
        try await SessionService(databaseQueue: personal).save(session(title: "Private request", runID: id))
        for index in 0..<45 { try await service.save(session(title: "Finished \(index)")) }
        try await service.save(session(status: .cancelled))
        let active = session(title: "Still running", status: .running)
        try await service.save(active)
        for status: TaskRunStatus in [.waitingForInput, .waitingForConfirmation, .failed, .incomplete, .recoveryRequired] {
            try await service.save(session(status: status))
        }
        let team = TeamTaskStore(databaseQueue: db)
        for status: TeamTaskStatus in [.completed, .cancelled, .failed, .interrupted, .running, .waitingForApproval] {
            let plan = TeamPlan(goal: "Team \(status.rawValue)", subtasks: [.init(title: "Read", objective: "Analyze")])
            let report = TeamTaskReport(taskID: UUID(), goal: plan.goal, status: status, subtasks: [], artifacts: [], usage: .zero,
                openQuestions: [], errors: [], startedAt: Date(), finishedAt: Date())
            try await team.save(plan: plan, report: report)
        }
        let schedules = ScheduledRunStore(databaseQueue: db), scheduleTaskID = UUID()
        for status in ScheduledRunStatus.allCases {
            _ = try await schedules.insert(ScheduledRun(taskID: scheduleTaskID, taskName: "Schedule \(status.rawValue)", trigger: .manual,
                scheduledFor: nil, status: status, startedAt: Date(), outputText: "Retain scheduled result"))
        }
        let jobStore = ProductJobRunStore(databaseQueue: db, space: .work)
        var jobs: [BackgroundJob] = []
        for state: BackgroundJob.State in [.succeeded, .cancelled, .failed, .queued, .running, .awaitingSave, .interrupted] {
            var job = BackgroundJob(name: "Job \(state.rawValue)", kind: "test", space: .work)
            job.state = state; job.resultText = "Retain job result"
            try await jobStore.recordStarted(job)
            jobs.append(job)
        }
        var liveOnly = BackgroundJob(id: id, name: "Cache-only job", kind: "test", space: .work)
        liveOnly.state = .succeeded
        jobs.append(liveOnly)
        var privateJob = BackgroundJob(name: "Personal job", kind: "test", space: .personal)
        privateJob.state = .succeeded
        jobs.append(privateJob)
        let finished = try await center.page(group: .finished, limit: 100, jobs: jobs)
        #expect(finished.items.count > 40 && !finished.hasMore)
        #expect(Set(finished.items.map(\.source)) == [.chat, .team, .scheduled, .job])
        let pending = try await center.page(group: .attention, limit: 100, jobs: jobs)
        let removableAttention = pending.items.filter(\.canClearHistory)
        #expect(removableAttention.map(\.sourceStatus).sorted() ==
            ["failed", "incomplete", "failed", "interrupted", "failed", "missed", "interrupted", "failed", "interrupted"].sorted())
        let metrics = try await ProductPreferencesService(databaseQueue: db).metrics()
        #expect(try await center.clearFinished(jobs: jobs) == finished.items.count + removableAttention.count)
        #expect(try await center.clearFinished(jobs: jobs) == 0)
        #expect(try await center.page(group: .finished, jobs: jobs).items.isEmpty)
        #expect(try await center.page(source: .chat, search: "Coding", jobs: jobs, includeHidden: true).items.isEmpty)
        #expect(try await center.page(group: .attention, limit: 100, jobs: jobs).items == pending.items.filter { !$0.canClearHistory })
        let remaining = try await center.page(limit: 100, activeChatRunIDs: [active.messages[1].taskRun!.id], jobs: jobs)
        #expect(remaining.items.contains { $0.sessionID == active.id && $0.status == .running })
        #expect(!remaining.items.contains { $0.status.taskGroup == .finished })
        #expect(try await ProductTaskRunStore(databaseQueue: db).run(id: id)?.answer == coding.messages[1].content)
        #expect(try await service.fetch(id: coding.id)?.messages == coding.messages)
        #expect(try await schedules.runs(taskID: scheduleTaskID, limit: 100).count == ScheduledRunStatus.allCases.count)
        #expect(try await jobStore.run(id: jobs[0].id)?.resultText == "Retain job result")
        #expect(try await ProductPreferencesService(databaseQueue: db).metrics().tasksCompleted == metrics.tasksCompleted)
        #expect(try await ProductTaskCenterStore(databaseQueue: personal, space: .personal).page(jobs: jobs).items.count == 2)
        // Conversation saves and cache migration cannot resurrect cleared identities.
        try await service.save(coding)
        try jobStore.saveCompleted([liveOnly])
        #expect(try await center.page(group: .finished, jobs: jobs).items.isEmpty)
        // A task active during the clear remains visible when it later finishes.
        try await service.updateMessage(sessionId: active.id, messageId: active.messages[1].id) { $0.runStatus = .succeeded }
        #expect(try await center.page(group: .finished, jobs: jobs).items.map(\.sessionID) == [active.id])
    }

    @Test("Single-history removal targets one space and source, rechecks stale selections and preserves results")
    func clearOneHistoryRecord() async throws {
        let db = try queue(), personal = try queue(), sharedID = UUID()
        let service = SessionService(databaseQueue: db)
        let center = ProductTaskCenterStore(databaseQueue: db, space: .work)
        let failed = session(title: "Order app", runID: sharedID, status: .failed)
        try await service.save(failed)
        try await SessionService(databaseQueue: personal).save(failed)
        var job = BackgroundJob(id: sharedID, name: "Index", kind: "test", space: .work)
        job.state = .failed
        let chat = try #require(try await center.page(source: .chat).items.first)
        let other = ProductTaskCenterStore(databaseQueue: personal, space: .personal)
        await #expect(throws: ProductTaskHistoryError.self) { try await other.clearFinished(only: chat) }
        #expect(try await center.clearFinished(only: chat, jobs: [job]) == 1)
        #expect(try await center.clearFinished(only: chat) == 0)
        let remaining = try await center.page(group: .attention, jobs: [job]).items
        #expect(remaining.count == 1)
        let jobItem = try #require(remaining.first)
        #expect(jobItem.source == .job && jobItem.sourceID == sharedID)
        #expect(try await center.clearedHistoryIDs(among: [chat.id, jobItem.id]) == [chat.id])
        #expect(try await service.fetch(id: failed.id)?.messages == failed.messages)
        #expect(try await other.page().items.count == 1)

        let store = ProductJobRunStore(databaseQueue: db, space: .work)
        // Confirmation arrives after a current host has published a protected receipt.
        job.state = .running
        try await store.recordStarted(job)
        #expect(try await center.clearFinished(only: jobItem, jobs: [job]) == 0)
        #expect(try await center.page(jobs: [job]).items.first?.canClearHistory == false)
        #expect(try await center.clearFinished(only: jobItem) == 0)
        try await db.write {
            try $0.execute(sql: "UPDATE product_job_runs SET hostID='previous-process' WHERE id=?", arguments: [sharedID.uuidString])
        }
        // A live snapshot still wins over an old host stamp. With no live owner the
        // interrupted index can be removed directly, without inventing a completion.
        #expect(try await center.clearFinished(only: jobItem, jobs: [job]) == 0)
        let interruption = try #require(try await center.page(source: .job).items.first)
        #expect(interruption.status == .recoveryRequired && interruption.canClearHistory)
        #expect(try await center.clearFinished(only: interruption) == 1)
        #expect(try await center.page().items.isEmpty)
        #expect(try await store.run(id: sharedID)?.state == .interrupted)
    }

    @Test("A storage failure rolls back the entire history clear, including cache-only jobs")
    func clearHistoryFailure() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db)
        let center = ProductTaskCenterStore(databaseQueue: db, space: .work)
        try await service.save(session(title: "Keep this result"))
        var job = BackgroundJob(name: "Live cache", kind: "test", space: .work)
        job.state = .succeeded
        let jobs = [job]
        let before = try await center.page(jobs: jobs)
        try await db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_history_clear BEFORE INSERT ON product_task_center_cleared WHEN NEW.id LIKE 'job:%' BEGIN SELECT RAISE(FAIL, 'injected'); END")
        }
        await #expect(throws: (any Error).self) { try await center.clearFinished(jobs: jobs) }
        #expect(try await center.page(jobs: jobs).items == before.items)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM product_task_center_cleared") } == 0)
        try await db.write { try $0.execute(sql: "DROP TRIGGER reject_history_clear") }
        #expect(try await center.clearFinished(jobs: jobs) == 2)
        #expect(try await center.page(jobs: jobs).items.isEmpty)
    }

    @Test("Old databases migrate without losing history; cleared legacy coding tasks stay cleared after reopening")
    func clearedHistorySurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("work.sqlite").path
        var legacy = ChatSession(title: "Legacy coding", mode: .coding)
        legacy.messages = [.init(role: .user, content: "Old request"), .init(role: .assistant, content: "Old result")]
        do {
            let db = try DatabaseQueue(path: path); try DatabaseBootstrap.prepareSpace(db)
            try await SessionService(databaseQueue: db).save(legacy)
            try await db.write { db in
                try db.execute(sql: "DROP TABLE product_task_center_cleared")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v1_product_task_center_cleared'")
            }
            try DatabaseBootstrap.prepareSpace(db)
            let center = ProductTaskCenterStore(databaseQueue: db, space: .work)
            #expect(try await center.page().items.count == 1)
            #expect(try await center.clearFinished() == 1)
        }
        let reopened = try DatabaseQueue(path: path); try DatabaseBootstrap.prepareSpace(reopened)
        let center = ProductTaskCenterStore(databaseQueue: reopened, space: .work)
        try await SessionService(databaseQueue: reopened).save(legacy)
        #expect(try await center.page(includeHidden: true).items.isEmpty)
        #expect(try await SessionService(databaseQueue: reopened).fetch(id: legacy.id)?.messages.last?.content == "Old result")
        #expect(try await center.clearFinished() == 0)
    }

    @Test("A daemon from a previous execution cannot write into a retry, and terminal results reject late progress")
    func guardedDaemonWriteback() async throws {
        let db = try queue(), service = SessionService(databaseQueue: db), history = ProductTaskRunStore(databaseQueue: db)
        let oldID = UUID(), newID = UUID()
        var task = session(runID: oldID, status: .running, answer: "Old progress")
        try await service.save(task)
        task.messages[1].taskRun = .init(id: newID)
        task.messages[1].content = "New result"; task.messages[1].runStatus = .succeeded
        try await service.save(task)
        await #expect(throws: ProductTaskHistoryError.self) {
            try await service.updateMessage(sessionId: task.id, messageId: task.messages[1].id, expectedTaskRunID: oldID) { $0.content = "Stale daemon result" }
        }
        try await service.updateMessage(sessionId: task.id, messageId: task.messages[1].id, expectedTaskRunID: newID, isProgressUpdate: true) { $0.content += " late chunk" }
        #expect(try await service.fetch(id: task.id)?.messages[1].content == "New result")
        #expect(try await history.run(id: newID)?.answer == "New result")
    }
}

private final class TaskRetryReplyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"Synthetic answer\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
