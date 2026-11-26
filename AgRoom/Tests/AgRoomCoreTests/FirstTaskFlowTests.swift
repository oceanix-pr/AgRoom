import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Resumable first task setup")
@MainActor
struct FirstTaskFlowTests {
    @MainActor private final class Probes {
        var replies: [CheckedContinuation<Result<String, Error>, Never>] = []
        var current = true
        var failProviderLoad = false
        var probeCount = 0
        func run() async -> Result<String, Error> {
            await withCheckedContinuation { replies.append($0) }
        }
    }
    @MainActor private final class ProviderReloads {
        let initial: LLMProviderConfig
        var loaded = false
        var reply: CheckedContinuation<[LLMProviderConfig], Never>?
        init(_ initial: LLMProviderConfig) { self.initial = initial }
        func fetch() async -> [LLMProviderConfig] {
            if !loaded { loaded = true; return [initial] }
            return await withCheckedContinuation { reply = $0 }
        }
    }
    private func queue() throws -> DatabaseQueue {
        let value = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(value); return value
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TaskArtifactError.unavailable
    }

    @Test("A credential-only configuration change and an overlapping probe cannot restore stale verification")
    func staleProbe() async throws {
        let preferences = ProductPreferencesService(databaseQueue: try queue()), probes = Probes()
        let config = LLMProviderConfig(name: "Fixture", endpoint: "https://first-task.invalid/v1", model: "fixture")
        let setup = FirstTaskSetupModel(space: .work, preferences: preferences, fetchProviders: { [config] },
            probe: { _ in await probes.run() }, isCurrentSpace: { probes.current })
        await setup.load()
        setup.testConnection()
        try await wait { probes.replies.count == 1 }
        await setup.configurationChanged().value // Same endpoint and model, different credential revision.
        #expect(!setup.connected && !setup.testing)
        setup.testConnection()
        try await wait { probes.replies.count == 2 }
        probes.replies[0].resume(returning: .success("old probe"))
        await Task.yield()
        #expect(!setup.connected && setup.testing)
        probes.replies[1].resume(returning: .success("current probe"))
        try await wait { setup.connected }
        #expect(setup.canStart)
        setup.testConnection()
        try await wait { probes.replies.count == 3 }
        probes.current = false; setup.cancel()
        probes.replies[2].resume(returning: .success("late probe"))
        await Task.yield()
        #expect(!setup.connected && !setup.testing && !setup.canStart)
        #expect(await setup.request() == nil)
    }

    @Test("Restart preserves ordered setup intent in its own space, requires file reselection and a fresh probe")
    func setupRecovery() async throws {
        let work = ProductPreferencesService(databaseQueue: try queue()), personal = ProductPreferencesService(databaseQueue: try queue())
        let first = LLMProviderConfig(name: "First", endpoint: "https://first-task.invalid/v1", model: "first")
        let second = LLMProviderConfig(name: "Second", endpoint: "https://first-task.invalid/v1", model: "second")
        func model() -> FirstTaskSetupModel {
            FirstTaskSetupModel(space: .work, preferences: work, fetchProviders: { [first, second] },
                probe: { _ in .success("connected") }, isCurrentSpace: { true })
        }
        let setup = model(); await setup.load()
        setup.template = "mail"; setup.template = "organize"; setup.template = "compare"
        setup.useSample = false; setup.selectedProvider = second.id
        let sources = [URL(fileURLWithPath: "/private/tmp/first-task-evidence-A.txt"), URL(fileURLWithPath: "/private/tmp/first-task-evidence-B.txt")]
        setup.selectFiles(sources); setup.testConnection()
        try await wait { setup.connected }
        let request = try #require(await setup.request()) // Drains the serialized save chain.
        #expect(request.files == sources && request.providerID == second.id && request.template == "compare")
        setup.cancel()
        let restored = model(); await restored.load()
        #expect(restored.template == "compare" && restored.selectedProvider == second.id && !restored.useSample)
        #expect(restored.sourceNames == sources.map(\.lastPathComponent))
        #expect(restored.files.isEmpty && restored.needsSourceReselection && !restored.sourcesReady && !restored.connected)
        #expect(await restored.request() == nil)
        let saved = try #require(try await work.load(FirstResultSetupDraft.self, key: "first-result.setup"))
        let serialized = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!serialized.contains("/private/tmp") && !serialized.contains("connected"))
        #expect(try await personal.load(FirstResultSetupDraft.self, key: "first-result.setup") == nil)
        restored.selectFiles(sources); restored.testConnection()
        try await wait { restored.connected }
        #expect(try #require(await restored.request()).startedAt == request.startedAt)
        restored.cancel()
    }

    @Test("A configuration change blocks probes synchronously until the updated endpoint has loaded")
    func providerReloadWindow() async throws {
        let config = LLMProviderConfig(name: "Fixture", endpoint: "https://old.first-task.invalid/v1", model: "fixture")
        let reloads = ProviderReloads(config), probes = Probes()
        var observed: [LLMProviderConfig] = []
        let setup = FirstTaskSetupModel(space: .work, preferences: ProductPreferencesService(databaseQueue: try queue()),
            fetchProviders: { await reloads.fetch() }, probe: { provider in observed.append(provider); return await probes.run() },
            isCurrentSpace: { true })
        await setup.load(); setup.testConnection()
        try await wait { probes.replies.count == 1 }
        probes.replies[0].resume(returning: .success("first connection"))
        try await wait { setup.connected }
        let reloading = setup.configurationChanged()
        #expect(setup.loadingProviders && !setup.connected && !setup.canStart)
        setup.testConnection() // Must be blocked even before the reload task starts.
        try await wait { reloads.reply != nil }
        setup.testConnection() // Still blocked while the database read is suspended.
        await Task.yield()
        #expect(probes.replies.count == 1 && observed.count == 1)
        var updated = config; updated.endpoint = "https://new.first-task.invalid/v1"
        reloads.reply?.resume(returning: [updated])
        await reloading.value
        #expect(!setup.loadingProviders && !setup.connected)
        setup.testConnection()
        try await wait { probes.replies.count == 2 }
        #expect(observed.last == updated)
        probes.replies[1].resume(returning: .success("updated connection"))
        try await wait { setup.connected }
        #expect(setup.canStart)
        setup.cancel()
    }

    @Test("A failed draft save keeps setup visible and blocks task launch")
    func setupSaveFailure() async throws {
        let db = try queue(), config = LLMProviderConfig(name: "Fixture", endpoint: "https://first-task.invalid/v1", model: "fixture")
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_setup BEFORE INSERT ON product_preferences WHEN NEW.key='first-result.setup' BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        let setup = FirstTaskSetupModel(space: .work, preferences: ProductPreferencesService(databaseQueue: db),
            fetchProviders: { [config] }, probe: { _ in .success("connected") }, isCurrentSpace: { true })
        await setup.load(); setup.testConnection()
        try await wait { setup.connected }
        #expect(await setup.request() == nil)
        #expect(setup.errorText != nil && !setup.starting)
        try await db.write { try $0.execute(sql: "DROP TRIGGER fail_setup") }
        #expect(await setup.request() != nil)
        #expect(setup.errorText == nil)
        setup.cancel()
    }

    @Test("A failed configuration reload cannot probe stale metadata and can be retried without changing selection")
    func failedProviderReload() async throws {
        let probes = Probes(), config = LLMProviderConfig(name: "Fixture", endpoint: "https://first-task.invalid/v1", model: "fixture")
        let setup = FirstTaskSetupModel(space: .work, preferences: ProductPreferencesService(databaseQueue: try queue()), fetchProviders: {
            if probes.failProviderLoad { throw TaskArtifactError.storage }
            return [config]
        }, probe: { _ in probes.probeCount += 1; return .success("connected") }, isCurrentSpace: { true })
        await setup.load(); setup.testConnection()
        try await wait { setup.connected }
        probes.failProviderLoad = true
        await setup.configurationChanged().value
        #expect(setup.providers.isEmpty && !setup.connected && !setup.loadingProviders && setup.errorText != nil)
        setup.testConnection(); await Task.yield()
        #expect(probes.probeCount == 1 && !setup.canStart)
        probes.failProviderLoad = false
        await setup.configurationChanged().value
        #expect(setup.selectedProvider == config.id && !setup.connected)
        setup.testConnection()
        try await wait { setup.connected }
        #expect(probes.probeCount == 2 && setup.canStart)
        setup.cancel()
    }

    @Test("Review accepts later artifacts in a receipt and retained copies, rejects unrelated roots and removed contents")
    func reviewArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("first-result-review-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workDB = try queue(), personalDB = try queue()
        let store = TaskArtifactStore(databaseQueue: workDB, space: .work, previewRoot: root.appendingPathComponent("copies"))
        let foreignStore = TaskArtifactStore(databaseQueue: personalDB, space: .personal, previewRoot: root.appendingPathComponent("other-copies"))
        var session = ChatSession()
        let file = root.appendingPathComponent("report.md")
        try Data("Actual retained evidence".utf8).write(to: file)
        let artifact = try await store.capture(file, root: root, logicalPath: nil,
            origin: .init(space: .work, sessionID: session.id, runID: UUID(), workspaceID: nil, operationID: "report", tool: "files_write"))
        try FileManager.default.removeItem(at: file)
        let missing = TaskArtifact(path: root.appendingPathComponent("missing.md").path)
        session.messages = [.init(role: .assistant, content: "Report ready", trace: [
            .init(toolName: "files_write", argumentsPreview: "", resultPreview: "", artifacts: [missing, artifact], duration: 0, succeeded: true)
        ], runStatus: .succeeded, taskRun: .init())]
        let progress = FirstResultProgress(template: "organize", sessionID: session.id)
        let inspection = try #require(try await FirstResultReview.inspect(progress: progress, session: session, roots: [], store: store))
        #expect(inspection.artifactID == artifact.id && FirstResultReview.matches(inspection, session: session))
        #expect(try await FirstResultReview.inspect(progress: progress, session: session, roots: [root], store: foreignStore) == nil)
        session.messages[0].runStatus = .failed
        #expect(!FirstResultReview.matches(inspection, session: session))
        #expect(try await FirstResultReview.inspect(progress: progress, session: session, roots: [], store: store) == nil)
        session.messages[0].runStatus = .succeeded
        try await store.removeRetainedContents([artifact])
        #expect(try await FirstResultReview.inspect(progress: progress, session: session, roots: [], store: store) == nil)
        let other = root.appendingPathComponent("unrelated"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let outside = other.appendingPathComponent("old.md"); try Data("legacy".utf8).write(to: outside)
        session.messages[0].trace = [.init(toolName: "files_write", argumentsPreview: "", resultPreview: "", artifact: TaskArtifact(path: outside.path), duration: 0, succeeded: true)]
        #expect(try await FirstResultReview.inspect(progress: progress, session: session, roots: [root.appendingPathComponent("own-workspace")], store: store) == nil)
        #expect(try await FirstResultReview.inspect(progress: progress, session: session, roots: [other], store: store) != nil)
    }

    @Test("Mail setup requires enabled local sources, refreshes before launch and remains physically space scoped")
    func mailReadiness() async throws {
        let db = try queue(), otherDB = try queue(), service = MailService(databaseQueue: db)
        let preferences = ProductPreferencesService(databaseQueue: db)
        let config = LLMProviderConfig(name: "Fixture", endpoint: "https://first-task.invalid/v1", model: "fixture")
        try await preferences.save(FirstResultSetupDraft(template: "mail"), key: "first-result.setup")
        let setup = FirstTaskSetupModel(space: .work, preferences: preferences, fetchProviders: { [config] },
            probe: { _ in .success("connected") }, fetchMailSources: { try await service.localSourceSummary() }, isCurrentSpace: { true })
        await setup.load(); setup.testConnection()
        try await wait { setup.connected }
        #expect(!setup.sourcesReady && !setup.canStart)
        #expect(await setup.request() == nil)
        var account = MailAccount(displayName: "Fixture", emailAddress: "mail@first-task.invalid", imapHost: "imap.first-task.invalid", smtpHost: "smtp.first-task.invalid", username: "fixture")
        let accounts = MailAccountService(databaseQueue: db, space: .work)
        try await accounts.save(account, password: nil)
        await setup.refreshMailSources()
        #expect(setup.mailSources?.enabledAccounts == 1 && !setup.sourcesReady)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox", role: .inbox)
        try await service.upsertFolders([folder])
        try await service.upsertMessages([
            .init(accountId: account.id, folderId: folder.id, uid: 1, subject: "Local source", snippet: "Follow up on Friday"),
            .init(accountId: account.id, folderId: folder.id, uid: MailService.localUIDFloor, subject: "Local sent copy")
        ])
        await setup.refreshMailSources()
        #expect(setup.sourcesReady && setup.mailSources?.syncedMessages == 1)
        #expect(await setup.request() != nil)
        #expect(try await MailService(databaseQueue: otherDB).localSourceSummary() == .init(enabledAccounts: 0, syncedMessages: 0))
        account.isEnabled = false; try await accounts.save(account, password: nil)
        // Even a previously ready snapshot must be refreshed before producing a request.
        #expect(await setup.request() == nil)
        #expect(!setup.sourcesReady && setup.mailSources?.syncedMessages == 0)
        setup.cancel()
    }

    @Test("First task startup preserves drafts and never sends after persistence or source import failure")
    func startupFailureRecovery() async throws {
        for failure in ["progress", "source"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("first-task-startup-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let db = try queue(), hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: db))
            let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"), fileAreaService: FileAreaService(baseDirectory: root.appendingPathComponent("files")))
            var didBuild = false, didSelect = false
            let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil,
                makeEngine: { _ in didBuild = true; throw TaskArtifactError.unavailable }, selectProvider: { _ in didSelect = true })
            await model.load()
            model.inputText = "Preserve existing work"
            let missing = root.appendingPathComponent("removed-source.txt")
            if failure == "progress" {
                try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_progress BEFORE INSERT ON product_preferences WHEN NEW.key='first-result.progress' BEGIN SELECT RAISE(FAIL,'fixture'); END") }
            }
            let request = FirstTaskRequest(space: .work, template: "organize", prompt: "Organize the supplied evidence", files: failure == "source" ? [missing] : [], providerID: UUID(), startedAt: Date())
            #expect(await model.startFirstTask(request) == false)
            #expect(!didBuild && !model.isAnyRunning && model.errorMessage != nil)
            let targetID = try #require(model.activeSessionId)
            #expect(model.session(id: targetID)?.messages.isEmpty == true && model.inputText == request.prompt && model.pendingAttachments == request.files)
            #expect(try await SessionService(databaseQueue: db).fetch(id: targetID) != nil)
            let progress = try await ProductPreferencesService(databaseQueue: db).load(FirstResultProgress.self, key: "first-result.progress")
            if failure == "progress" { #expect(progress == nil && !didSelect) }
            else { #expect(progress?.sessionID == targetID) }
            let previous = try #require(model.sessions.first { $0.id != targetID })
            model.activeSessionId = previous.id
            #expect(model.inputText == "Preserve existing work")
            #expect(try await ProductTaskRunStore(databaseQueue: db).summaries().isEmpty)
        }
    }

    @Test("First-result progress requires a saved session; deleting its source removes the resume pointer but preserves metrics")
    func progressSourceLifecycle() async throws {
        let db = try queue(), preferences = ProductPreferencesService(databaseQueue: db), sessions = SessionService(databaseQueue: db)
        let source = ChatSession(), unrelated = ChatSession()
        let progress = FirstResultProgress(template: "organize", sessionID: source.id)
        await #expect(throws: SpaceServiceError.self) { try await preferences.beginFirstResult(progress) }
        #expect(try await preferences.firstResultProgress() == nil)
        // Legacy dangling pointers are ignored, even though their bytes remain
        // available to normal backup/inspection until replaced by a new task.
        try await preferences.save(progress, key: "first-result.progress")
        #expect(try await preferences.firstResultProgress() == nil)
        try await sessions.save(source); try await sessions.save(unrelated)
        try await preferences.beginFirstResult(progress)
        try await sessions.delete(id: unrelated.id)
        #expect(try await preferences.firstResultProgress() == progress)
        _ = try await preferences.verifyFirstResult(sessionID: source.id)
        #expect(try await preferences.metrics().firstResultSeconds != nil)
        try await sessions.delete(id: source.id)
        #expect(try await preferences.firstResultProgress() == nil)
        #expect(try await preferences.load(FirstResultProgress.self, key: "first-result.progress") == nil)
        #expect(try await preferences.metrics().firstResultSeconds != nil)
    }
}

@Suite("First task guidance visibility")
struct FirstTaskGuidanceTests {
    private func queue() throws -> DatabaseQueue {
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db); return db
    }

    @Test("Startup guidance remains readable while backup holds the space maintenance lease")
    func guidanceDuringBackup() async throws {
        let workDB = try queue(), personalDB = try queue()
        let work = ProductPreferencesService(databaseQueue: workDB)
        let personal = ProductPreferencesService(databaseQueue: personalDB)
        let sessions = SessionService(databaseQueue: workDB)
        var session = ChatSession()
        try await sessions.save(session)
        let progress = FirstResultProgress(template: "organize", sessionID: session.id)
        try await work.beginFirstResult(progress)
        var message = ChatMessage(role: .assistant, content: "Synthetic result")
        message.runStatus = .succeeded; message.taskRun = ProductTaskIdentity()
        session.messages = [message]
        try await sessions.save(session)
        // An older installation may not yet have a persisted visibility preference.
        try await workDB.write { try $0.execute(sql: "DELETE FROM product_preferences WHERE key='first-task.hidden'") }

        let workLease = try ResourceMaintenance.Lease(key: workDB.maintenanceKey, exclusive: true)
        let personalLease = try ResourceMaintenance.Lease(key: personalDB.maintenanceKey, exclusive: true)
        defer { withExtendedLifetime((workLease, personalLease)) {} }

        let state = try await work.firstTaskGuidance()
        #expect(state.isHidden && state.progress == progress)
        #expect(try await personal.firstTaskGuidance().shouldOfferNewTask)
        #expect(try await workDB.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM product_preferences WHERE key='first-task.hidden'")
        } == 0)
        do {
            try await work.hideFirstTaskGuidance()
            Issue.record("A competing write entered backup maintenance")
        } catch MaintenanceError.busy {}
    }

    @Test("Upgrading persists guidance visibility before startup reads or history deletion")
    func migrateExistingSuccess() async throws {
        let db = try queue(), preferences = ProductPreferencesService(databaseQueue: db)
        let sessions = SessionService(databaseQueue: db)
        var session = ChatSession()
        var message = ChatMessage(role: .assistant, content: "Synthetic result")
        message.runStatus = .succeeded; message.taskRun = ProductTaskIdentity()
        session.messages = [message]
        try await sessions.save(session)
        try await db.write {
            try $0.execute(sql: "DELETE FROM product_preferences WHERE key='first-task.hidden'")
            try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v1_first_task_guidance'")
        }

        try DatabaseBootstrap.prepareSpace(db)
        try await sessions.delete(id: session.id)
        try await preferences.clearMetrics()
        #expect(try await preferences.firstTaskGuidance().isHidden)
    }

    @Test("Restoring older successful history persists visibility and rollback restores its previous state")
    func restoreExistingSuccess() async throws {
        let sourceDB = try queue(), targetDB = try queue()
        let targetSessions = SessionService(databaseQueue: targetDB)
        let targetPreferences = ProductPreferencesService(databaseQueue: targetDB)
        var session = ChatSession()
        var message = ChatMessage(role: .assistant, content: "Synthetic result")
        message.runStatus = .succeeded; message.taskRun = ProductTaskIdentity()
        session.messages = [message]
        try await SessionService(databaseQueue: sourceDB).save(session)
        try await sourceDB.write { try $0.execute(sql: "DELETE FROM product_preferences WHERE key='first-task.hidden'") }
        var emptySession = session; emptySession.messages = []
        try await targetSessions.save(emptySession)
        let source = SpaceDatabaseBackupStore(queue: sourceDB, space: "work")
        let target = SpaceDatabaseBackupStore(queue: targetDB, space: "work")
        let plan = try await target.plan(source.export(), sourceSpace: "work")

        let applied = try await target.apply(plan, willCommit: { _ in })
        try await target.verify(applied)
        #expect(try await targetPreferences.load(Bool.self, key: "first-task.hidden") == true)
        try await target.rollback(applied)
        #expect(try await targetPreferences.firstTaskGuidance().shouldOfferNewTask)
        _ = try await target.apply(plan, willCommit: { _ in })
        try await targetSessions.delete(id: session.id)
        #expect(try await targetPreferences.firstTaskGuidance().isHidden)
    }

    @Test("Skipping is durable and belongs only to its physical space")
    func skippedGuidance() async throws {
        let workDB = try queue(), personalDB = try queue()
        let work = ProductPreferencesService(databaseQueue: workDB)
        #expect(try await work.firstTaskGuidance().shouldOfferNewTask)
        try await work.hideFirstTaskGuidance()
        #expect(try await ProductPreferencesService(databaseQueue: workDB).firstTaskGuidance().isHidden)
        #expect(try await ProductPreferencesService(databaseQueue: personalDB).firstTaskGuidance().shouldOfferNewTask)
    }

    @Test("Only success hides guidance, and deleting history or clearing metrics cannot restore it")
    func successfulTask() async throws {
        let db = try queue(), preferences = ProductPreferencesService(databaseQueue: db)
        let sessions = SessionService(databaseQueue: db)
        var session = ChatSession()
        for status in [TaskRunStatus.running, .failed, .cancelled, .incomplete] {
            var message = ChatMessage(role: .assistant, content: "Synthetic result")
            message.runStatus = status; message.taskRun = ProductTaskIdentity()
            session.messages = [message]
            try await sessions.save(session)
            #expect(try await preferences.firstTaskGuidance().shouldOfferNewTask)
        }
        session.messages[0].runStatus = .succeeded
        try await sessions.save(session)
        try await sessions.delete(id: session.id)
        try await preferences.clearMetrics()
        #expect(try await ProductPreferencesService(databaseQueue: db).firstTaskGuidance().isHidden)
    }

    @Test("Existing successful history is recognized, while unfinished first results retain review")
    func existingHistoryAndReview() async throws {
        let db = try queue(), preferences = ProductPreferencesService(databaseQueue: db)
        let sessions = SessionService(databaseQueue: db)
        var session = ChatSession()
        try await sessions.save(session)
        let progress = FirstResultProgress(template: "organize", sessionID: session.id)
        try await preferences.beginFirstResult(progress)
        #expect(try await preferences.firstTaskGuidance().progress == progress)
        #expect(try await preferences.firstTaskGuidance().shouldOfferNewTask == false)
        var message = ChatMessage(role: .assistant, content: "Synthetic result")
        message.runStatus = .succeeded; message.taskRun = ProductTaskIdentity()
        session.messages = [message]; try await sessions.save(session)
        // Emulate an upgrade whose successful run predates the sticky preference.
        try await db.write { try $0.execute(sql: "DELETE FROM product_preferences WHERE key='first-task.hidden'") }
        let state = try await preferences.firstTaskGuidance()
        #expect(state.isHidden && state.progress?.verifiedAt == nil && state.progress?.sessionID == session.id)
        _ = try await preferences.verifyFirstResult(sessionID: session.id)
        try await sessions.delete(id: session.id)
        #expect(try await preferences.firstTaskGuidance().isHidden)
    }

    @Test("A failed transaction cannot hide guidance or claim that a task succeeded")
    func failedSave() async throws {
        let db = try queue(), preferences = ProductPreferencesService(databaseQueue: db)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_guidance BEFORE INSERT ON product_preferences WHEN NEW.key='first-task.hidden' BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        var session = ChatSession()
        var message = ChatMessage(role: .assistant, content: "Synthetic result")
        message.runStatus = .succeeded; message.taskRun = ProductTaskIdentity(); session.messages = [message]
        await #expect(throws: (any Error).self) { try await SessionService(databaseQueue: db).save(session) }
        #expect(try await preferences.firstTaskGuidance().shouldOfferNewTask)
    }
}

/// Exercises the real provider protocol and engine loop without contacting a
/// network account. The destination belongs to each private test workspace.
enum FirstTaskFixtureProvider {
    static let report = "# Source report\n\n## Evidence\nLin: Wednesday; Zhou: Friday.\n\n## Open questions\nLaunch date is not decided.\n"
    static func make(destination: URL? = nil) -> CloudProvider {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [FirstTaskProtocol.self]
        if let destination { session.httpAdditionalHeaders = ["X-First-Task-Destination": destination.path] }
        return CloudProvider(config: .init(name: "First task fixture", endpoint: "https://first-task.invalid/v1", model: "fixture"),
            apiKey: "synthetic", session: URLSession(configuration: session))
    }
}

private final class FirstTaskProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "first-task.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let body: String
        if object["stream"] as? Bool != true {
            body = #"{"choices":[{"message":{"role":"assistant","content":"connected"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#
        } else if (object["messages"] as? [[String: Any]] ?? []).contains(where: { $0["role"] as? String == "tool" }) {
            body = "data: {\"choices\":[{\"delta\":{\"content\":\"Report saved with evidence and open questions.\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        } else {
            let arguments = ["path": request.value(forHTTPHeaderField: "X-First-Task-Destination") ?? "", "content": FirstTaskFixtureProvider.report]
            let json = String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self)
            let call: [String: Any] = ["choices": [["delta": ["tool_calls": [["index": 0, "id": "first-result-write", "function": ["name": "files_write", "arguments": json]]]], "finish_reason": NSNull()]]]
            let event = String(decoding: try! JSONSerialization.data(withJSONObject: call), as: UTF8.self)
            body = "data: \(event)\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": object["stream"] as? Bool == true ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
