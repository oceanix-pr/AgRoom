import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Complete space database backups")
struct SpaceBackupTests {
    private func queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return queue
    }

    private func account() -> MailAccount {
        MailAccount(displayName: "Archive mailbox", emailAddress: "a@example.com", imapHost: "imap.example.com",
            smtpHost: "smtp.example.com", username: "a@example.com")
    }

    @Test("Knowledge, agents, mail, schedules and preferences restore without credentials or automatic network work")
    func allDatasetsAndSecrets() async throws {
        let source = try queue(), target = try queue()
        let agent = Agent(name: "Archive agent", systemPrompt: "Private project context", modelName: "archive-model", providerID: UUID())
        try await AgentService(databaseQueue: source).save(agent)
        let knowledge = KnowledgeService(databaseQueue: source)
        let base = KnowledgeBase(name: "Project"), item = KnowledgeItem(title: "Decision", content: "Keep source evidence")
        try await knowledge.saveBase(base)
        try await knowledge.save(item)
        let account = account()
        try await MailAccountService(databaseQueue: source, space: .work).save(account, password: nil)
        let mail = MailService(databaseQueue: source)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox")
        try await mail.upsertFolders([folder])
        try await mail.upsertMessages([MailMessage(accountId: account.id, folderId: folder.id, uid: 1, subject: "Archived message")])
        let task = ScheduledTask(name: "Daily review", prompt: "Read only", schedule: ScheduledTaskSchedule(rule: .daily(hour: 9, minute: 0)),
            options: .init(budget: .init(maxTokens: 8_000, maxToolCalls: 4, seconds: 45), notifyOnlyOnChange: true, comparisonInstructions: "Compare the version"))
        try await ScheduledTaskStore(databaseQueue: source).save(task)
        var scheduledExperience = ScheduledRunExperience(budget: task.effectiveOptions.budget)
        scheduledExperience.usageKnown = true; scheduledExperience.budgetSpentTokens = 127
        scheduledExperience.comparisonValue = "v1"; scheduledExperience.comparisonState = .baseline
        scheduledExperience.definitionFingerprint = task.comparisonFingerprint
        let scheduledRun = ScheduledRun(taskID: task.id, taskName: task.name, trigger: .manual, scheduledFor: nil,
            status: .succeeded, startedAt: Date(), finishedAt: Date(), outputText: "Retained scheduled result", inputTokens: 100,
            outputTokens: 27, experience: scheduledExperience)
        try await ScheduledRunStore(databaseQueue: source).insert(scheduledRun)
        try await ProductPreferencesService(databaseQueue: source).saveQuickPrompts(["Work-only prompt"])
        var mcp = MCPServerConfig(name: "Private MCP", endpoint: "https://example.com/mcp", authentication: .bearer)
        let credential = UUID()
        mcp.credentialID = credential
        let mcpID = mcp.id
        let configJSON = String(decoding: try JSONEncoder().encode(mcp), as: UTF8.self)
        try await source.write { db in
            try db.execute(sql: "INSERT INTO mcp_servers VALUES (?, ?)", arguments: [mcpID.uuidString, configJSON])
        }
        let store = SpaceDatabaseBackupStore(queue: source, space: "work")
        let archive = try await store.export()
        #expect(!String(decoding: try JSONEncoder().encode(archive), as: UTF8.self).contains(credential.uuidString))
        let destination = SpaceDatabaseBackupStore(queue: target, space: "work")
        let plan = try await destination.plan(archive, sourceSpace: "work")
        let observed = try await destination.apply(plan) { _ in }
        try await destination.verify(observed)
        #expect(try await AgentService(databaseQueue: target).getAll().first?.name == agent.name)
        #expect(try await AgentService(databaseQueue: target).getAll().first?.providerID == agent.providerID)
        #expect(try await AgentService(databaseQueue: target).getAll().first?.modelName == agent.modelName)
        #expect(try await KnowledgeService(databaseQueue: target).get(id: item.id)?.content == item.content)
        #expect(try await MailService(databaseQueue: target).messages(folderId: folder.id).first?.subject == "Archived message")
        #expect(try await MailAccountService(databaseQueue: target, space: .work).getAll().first?.isEnabled == false)
        #expect(try await ScheduledTaskStore(databaseQueue: target).task(id: task.id)?.enabled == false)
        #expect(try await ScheduledTaskStore(databaseQueue: target).task(id: task.id)?.options == task.options)
        let restoredRun = try #require(try await ScheduledRunStore(databaseQueue: target).run(id: scheduledRun.id))
        #expect(restoredRun.outputText == scheduledRun.outputText && restoredRun.experience == scheduledExperience)
        let restoredMCP = try #require(try await MCPServerConfigService(databaseQueue: target, space: .work).getAll().first)
        #expect(!restoredMCP.isEnabled && restoredMCP.credentialID == nil)
        #expect(try await ProductPreferencesService(databaseQueue: target).quickPrompts() == ["Work-only prompt"])
        #expect(try await ProductPreferencesService(databaseQueue: source).quickPrompts() == ["Work-only prompt"])
    }

    @Test("Rollback restores trigger-deleted graph evidence and account tombstones from a durable after-image")
    func triggerAwareRollback() async throws {
        let source = try queue(), target = try queue()
        let item = KnowledgeItem(title: "Old", content: "Current evidence")
        try await KnowledgeService(databaseQueue: target).save(item)
        var replacement = item; replacement.content = "Archived content"
        try await KnowledgeService(databaseQueue: source).save(replacement)
        let relation = UUID().uuidString, tombstone = UUID().uuidString
        try await target.write { db in
            try db.execute(sql: "INSERT INTO knowledge_graph_relations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [relation, item.id.uuidString, "hash", "A", "supports", "B", "Current evidence", 0, "test"])
            try db.execute(sql: "INSERT INTO mail_deleted_accounts VALUES (?)", arguments: [tombstone])
        }
        let account = account()
        try await MailAccountService(databaseQueue: source, space: .work).save(account, password: nil)
        let archive = try await SpaceDatabaseBackupStore(queue: source, space: "work").export()
        let store = SpaceDatabaseBackupStore(queue: target, space: "work")
        let plan = try await store.plan(archive, sourceSpace: "work")
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: journal) }
        _ = try await store.apply(plan) { try JSONEncoder().encode($0).write(to: journal, options: .atomic) }
        #expect(try await target.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM knowledge_graph_relations") } == 0)
        let recovered = try JSONDecoder().decode(SpaceDatabaseRestorePlan.self, from: Data(contentsOf: journal))
        try await store.rollback(recovered)
        #expect(try await KnowledgeService(databaseQueue: target).get(id: item.id)?.content == item.content)
        #expect(try await target.read { try String.fetchAll($0, sql: "SELECT id FROM knowledge_graph_relations") } == [relation])
        #expect(try await target.read { try String.fetchAll($0, sql: "SELECT accountId FROM mail_deleted_accounts") } == [tombstone])
        try await store.rollback(recovered)
    }

    @Test("Journal failure rolls back atomically; later user edits are never overwritten by rollback")
    func journalFailureAndLaterEdits() async throws {
        enum Injected: Error { case journal }
        let source = try queue(), target = try queue()
        let agent = Agent(name: "Restored")
        try await AgentService(databaseQueue: source).save(agent)
        let store = SpaceDatabaseBackupStore(queue: target, space: "work")
        let archive = try await SpaceDatabaseBackupStore(queue: source, space: "work").export()
        let plan = try await store.plan(archive, sourceSpace: "work")
        await #expect(throws: Injected.self) { try await store.apply(plan) { _ in throw Injected.journal } }
        #expect(try await AgentService(databaseQueue: target).getAll().isEmpty)
        let observed = try await store.apply(plan) { _ in }
        var changed = agent; changed.name = "User edited after restore"
        try await AgentService(databaseQueue: target).save(changed)
        await #expect(throws: MaintenanceError.self) { try await store.rollback(observed) }
        #expect(try await AgentService(databaseQueue: target).getAll().first?.name == changed.name)
    }

    @Test("A prior delivery receipt cannot be erased by an older editable draft")
    func deliveryReceiptProtection() async throws {
        let source = try queue(), target = try queue()
        let account = account()
        for database in [source, target] { try await MailAccountService(databaseQueue: database, space: .work).save(account, password: nil) }
        let draft = MailDraft(accountId: account.id, to: [MailAddress(name: "", address: "b@example.com")], subject: "Old editable content", bodyText: "old")
        try await MailService(databaseQueue: source).saveDraft(draft)
        var delivered = draft
        delivered.subject = "Actual delivered content"; delivered.deliveryState = .unknown
        try await MailService(databaseQueue: target).saveDraft(delivered)
        let archive = try await SpaceDatabaseBackupStore(queue: source, space: "work").export()
        let store = SpaceDatabaseBackupStore(queue: target, space: "work")
        let plan = try await store.plan(archive, sourceSpace: "work")
        #expect(plan.preservedDeliveryDrafts == 1)
        _ = try await store.apply(plan) { _ in }
        let restored = try #require(try await MailService(databaseQueue: target).draft(id: draft.id))
        #expect(restored.subject == delivered.subject && restored.deliveryState == .unknown)
    }

    @Test("Unsupported columns, duplicate identities and false space labels fail before writing")
    func invalidArchive() async throws {
        let source = try queue(), target = try queue()
        try await AgentService(databaseQueue: source).save(Agent(name: "Source"))
        let original = try await SpaceDatabaseBackupStore(queue: source, space: "personal").export()
        let store = SpaceDatabaseBackupStore(queue: target, space: "work")
        await #expect(throws: BackupError.self) { try await store.plan(original, sourceSpace: "work") }
        var duplicate = original
        let index = try #require(duplicate.tables.firstIndex { $0.name == "agents" })
        duplicate.tables[index].rows += duplicate.tables[index].rows
        await #expect(throws: BackupError.self) { try await store.plan(duplicate, sourceSpace: "personal") }
        let invalid = SpaceDatabaseBackup(space: "personal", tables: [SpaceTableBackup(name: "agents", columns: ["id", "unrecognized"], primaryKey: ["id"], rows: [[.text(UUID().uuidString), .text("bad")]])])
        await #expect(throws: BackupError.self) { try await store.plan(invalid, sourceSpace: "personal") }
        #expect(try await AgentService(databaseQueue: target).getAll().isEmpty)
    }
}
