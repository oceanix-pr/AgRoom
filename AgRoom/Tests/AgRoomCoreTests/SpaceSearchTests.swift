import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Read-only, space-bound search")
struct SpaceSearchTests {
    private struct Stack {
        let root: URL
        let queue: DatabaseQueue
        let search: SpaceSearchService
        let space: AppSpace
    }
    private func fixture(_ space: AppSpace = .work) throws -> Stack {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("space-search-" + UUID().uuidString).appendingPathComponent(space.rawValue)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        return .init(root: root, queue: queue, search: SpaceSearchService(databaseQueue: queue, space: space, catalogDirectory: root), space: space)
    }
    private func remove(_ stack: Stack) { try? FileManager.default.removeItem(at: stack.root.deletingLastPathComponent()) }

    @Test("One query searches actual space records and installed catalogs without copying content or mutating the database")
    func allSources() async throws {
        let s = try fixture(); defer { remove(s) }
        let knowledge = KnowledgeService(databaseQueue: s.queue)
        try await knowledge.save(KnowledgeItem(title: "needle knowledge", content: "Matching source text"))
        try await MemoryService(databaseQueue: s.queue).save(MemoryItem(content: "needle memory", isEnabled: false))
        try await AgentService(databaseQueue: s.queue).save(Agent(name: "needle agent", nickname: "Display alias", description: "Agent metadata", systemPrompt: "PRIVATE SYSTEM PROMPT"))
        let skills = SkillStore(directoryURL: s.root.appendingPathComponent("skills"))
        try skills.save(Skill(name: "needle-skill", alias: "needle skill", description: "Skill metadata", content: "Do not automatically execute this source."))
        var app = try NativeAppTemplates.note()
        for language in Array(app.i18n.keys) { app.i18n[language]?[app.manifest.nameKey] = "needle app" }
        try await NativeAppStore(directoryURL: s.root.appendingPathComponent("apps"), space: .work).install(app, replacing: nil)
        var chat = ChatSession(title: "needle conversation")
        chat.messages = [.init(role: .user, content: "needle request"), .init(role: .assistant, content: "needle answer", runStatus: .succeeded, taskRun: .init())]
        try await SessionService(databaseQueue: s.queue).save(chat)
        let mailID = UUID().uuidString, account = UUID().uuidString, folder = UUID().uuidString
        try await s.queue.write { db in
            try db.execute(sql: "INSERT INTO mail_messages(id,accountId,folderId,uid,subject,snippet) VALUES(?,?,?,?,?,?)",
                arguments: [mailID, account, folder, 1, "needle mail", "Local cached message"])
        }
        let report = TeamTaskReport(taskID: UUID(), goal: "needle team", status: .completed, subtasks: [], artifacts: [],
            usage: .zero, openQuestions: [], errors: [], startedAt: Date(), finishedAt: Date())
        try await TeamTaskStore(databaseQueue: s.queue).save(plan: TeamPlan(goal: report.goal, subtasks: []), report: report)
        _ = try await ScheduledRunStore(databaseQueue: s.queue).insert(.init(taskID: UUID(), taskName: "needle scheduled", trigger: .manual,
            scheduledFor: nil, status: .succeeded, startedAt: Date(), finishedAt: Date(), outputText: "Local scheduled result"))
        var job = BackgroundJob(name: "needle job", kind: "fixture", space: .work)
        job.state = .succeeded; job.finishedAt = Date()
        try ProductJobRunStore(databaseQueue: s.queue, space: .work).saveCompleted([job])
        let file = s.root.appendingPathComponent("needle-file.txt"); try Data("Retained file bytes".utf8).write(to: file)
        let store = TaskArtifactStore(databaseQueue: s.queue, space: .work, previewRoot: s.root.appendingPathComponent("previews"))
        _ = try await store.capture(file, root: s.root, logicalPath: "needle-file.txt",
            origin: .init(space: .work, sessionID: chat.id, runID: UUID(), workspaceID: nil, operationID: "search", tool: "files_write"))
        try FileManager.default.removeItem(at: file)
        let changes = try await s.queue.read { try Int.fetchOne($0, sql: "SELECT total_changes()") }
        let page = try await s.search.search("needle", limit: 100)
        #expect(Set(page.hits.map(\.kind)) == Set(SpaceSearchKind.allCases))
        #expect(page.unavailableSources.isEmpty && !page.hasMore)
        #expect(try await s.search.search("PRIVATE SYSTEM PROMPT", kind: .agent).hits.isEmpty)
        #expect(page.hits.allSatisfy { $0.space == .work && $0.snippet.count <= 480 })
        #expect(page.hits.first { $0.kind == .memory }?.isEnabled == false)
        #expect(try await s.queue.read { try Int.fetchOne($0, sql: "SELECT total_changes()") } == changes)
        let mail = try #require(page.hits.first { $0.kind == .mail })
        #expect(mail.parentID == account && mail.secondaryID == folder)
        let artifact = try #require(page.hits.first { $0.kind == .artifact })
        #expect(try await s.search.preview(artifact).canQuote == false)
    }

    @Test("Equal IDs remain physically isolated, hidden conversation material stays hidden, and search input is literal")
    func isolationAndVisibility() async throws {
        let work = try fixture(), personal = try fixture(.personal)
        defer { remove(work); remove(personal) }
        let shared = UUID()
        try await KnowledgeService(databaseQueue: work.queue).save(KnowledgeItem(id: shared, title: "工作资料", content: "needle % _ 工作资料"))
        try await KnowledgeService(databaseQueue: personal.queue).save(KnowledgeItem(id: shared, title: "私人资料", content: "needle private"))
        let result = try #require(try await work.search.search("工作资料").hits.first)
        #expect(result.sourceID == shared.uuidString && result.space == .work)
        #expect(try await personal.search.search("工作资料").hits.isEmpty)
        #expect(try await work.search.search("% _", kind: .knowledge).hits.count == 1)
        #expect(try await work.search.search("' OR 1=1 --").hits.isEmpty)
        await #expect(throws: SpaceSearchError.invalidScope) { _ = try await personal.search.preview(result) }
        await #expect(throws: SpaceSearchError.invalidScope) { _ = try await personal.search.search("needle", before: result) }
        var hidden = ChatSession(title: "private-hidden")
        hidden.isHidden = true
        hidden.messages = [.init(role: .user, content: "private-hidden request"),
            .init(role: .assistant, content: "private-hidden answer", runStatus: .succeeded, taskRun: .init())]
        try await SessionService(databaseQueue: work.queue).save(hidden)
        #expect(try await work.search.search("private-hidden").hits.isEmpty)
        let revealed = try await work.search.search("private-hidden", includeHidden: true)
        #expect(!revealed.hits.isEmpty)
        let hit = try #require(revealed.hits.first { $0.kind == .conversation })
        await #expect(throws: SpaceSearchError.missing) { _ = try await work.search.preview(hit) }
    }

    @Test("Search includes later worker summaries and failure reasons even when a run has partial output")
    func fullSavedResults() async throws {
        let s = try fixture(); defer { remove(s) }
        let report = TeamTaskReport(taskID: UUID(), goal: "Saved team run", status: .failed,
            subtasks: [.init(id: UUID(), title: "First", role: "reader", outcome: .succeeded, summary: "Earlier summary"),
                .init(id: UUID(), title: "Second", role: "reader", outcome: .failed, summary: "LATER WORKER FINDING")],
            artifacts: [], usage: .zero, openQuestions: ["SAVED OPEN QUESTION"], errors: ["UNIQUE FAILURE REASON"],
            startedAt: Date(), finishedAt: Date())
        try await TeamTaskStore(databaseQueue: s.queue).save(plan: .init(goal: report.goal, subtasks: []), report: report)
        _ = try await ScheduledRunStore(databaseQueue: s.queue).insert(.init(taskID: UUID(), taskName: "Saved schedule", trigger: .manual,
            scheduledFor: nil, status: .failed, startedAt: Date(), finishedAt: Date(), outputText: "Partial output", errorText: "UNIQUE FAILURE REASON"))
        var job = BackgroundJob(name: "Saved job", kind: "fixture", space: .work)
        job.state = .failed; job.resultText = "Partial output"; job.errorText = "UNIQUE FAILURE REASON"; job.finishedAt = Date()
        try ProductJobRunStore(databaseQueue: s.queue, space: .work).saveCompleted([job])
        #expect(Set(try await s.search.search("UNIQUE FAILURE REASON").hits.map(\.kind)) == [.team, .scheduled, .job])
        let hit = try #require(try await s.search.search("LATER WORKER FINDING", kind: .team).hits.first)
        #expect(try await s.search.preview(hit).content.contains("LATER WORKER FINDING"))
        #expect(try await s.search.search("SAVED OPEN QUESTION", kind: .team).hits.count == 1)
        // A valid JSON envelope with unusable legacy children must not make
        // unrelated source searches fail during the combined SQL projection.
        try await s.queue.write { db in
            try db.execute(sql: "UPDATE team_tasks SET reportJSON=? WHERE id=?",
                arguments: ["{\"subtasks\":[\"not-json\"],\"errors\":[7]}", report.taskID.uuidString])
        }
        #expect(Set(try await s.search.search("UNIQUE FAILURE REASON").hits.map(\.kind)) == [.scheduled, .job])
    }

    @Test("A stable cursor pages database results and installed skills together without duplicates or lost rows")
    func combinedPagination() async throws {
        let s = try fixture(); defer { remove(s) }
        let knowledge = KnowledgeService(databaseQueue: s.queue)
        for index in 0..<43 {
            var item = KnowledgeItem(title: "PageRecord \(index)", content: "Stored source \(index)")
            item.updatedAt = Date(timeIntervalSince1970: Double(index + 1))
            try await knowledge.save(item)
        }
        let skills = SkillStore(directoryURL: s.root.appendingPathComponent("skills"))
        for name in ["page-one", "page-two"] { try skills.save(Skill(name: name, alias: "PageRecord " + name, description: "Catalog source")) }
        var seen = Set<String>(), before: SpaceSearchHit?
        repeat {
            let page = try await s.search.search("PageRecord", before: before, limit: 7)
            for hit in page.hits { #expect(seen.insert(hit.id).inserted) }
            before = page.hits.last
            if !page.hasMore { break }
        } while before != nil
        #expect(seen.count == 45)
    }

    @Test("Preview centers the hit in long text, and a changed or deleted reference cannot be silently quoted")
    func inspectedReference() async throws {
        let s = try fixture(); defer { remove(s) }
        let service = KnowledgeService(databaseQueue: s.queue)
        var item = KnowledgeItem(title: "Long reference", content: String(repeating: "Before. ", count: 4_000) + "UNIQUE SEARCH PASSAGE" + String(repeating: " After.", count: 4_000))
        try await service.save(item)
        let hit = try #require(try await s.search.search("UNIQUE SEARCH PASSAGE", kind: .knowledge).hits.first)
        #expect(hit.snippet.contains("UNIQUE SEARCH PASSAGE"))
        let preview = try await s.search.preview(hit)
        #expect(preview.content.contains("UNIQUE SEARCH PASSAGE") && preview.truncated && preview.content.count <= 12_000)
        #expect(try await s.search.reference(preview).revision == preview.revision)
        item.content = "Changed source"; item.updatedAt = Date().addingTimeInterval(1)
        try await service.updateContent(item)
        await #expect(throws: SpaceSearchError.changed) { _ = try await s.search.reference(preview) }
        try await service.delete(id: item.id)
        await #expect(throws: SpaceSearchError.missing) { _ = try await s.search.preview(hit) }
    }

    @Test("Unsafe catalog links never read the other space, and skipped catalogs are reported")
    func catalogSafety() async throws {
        let work = try fixture(), personal = try fixture(.personal)
        defer { remove(work); remove(personal) }
        let privateSkills = SkillStore(directoryURL: personal.root.appendingPathComponent("skills"))
        try privateSkills.save(Skill(name: "private-source", alias: "private secret", description: "PRIVATE CATALOG NEEDLE"))
        let directory = work.root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("borrowed-source"), withDestinationURL: personal.root.appendingPathComponent("skills/private-source"))
        let page = try await work.search.search("PRIVATE CATALOG NEEDLE", kind: .skill)
        #expect(page.hits.isEmpty && page.unavailableSources == [.skill])
        let wrongRoot = SpaceSearchService(databaseQueue: work.queue, space: .work, catalogDirectory: personal.root)
        await #expect(throws: SpaceSearchError.invalidScope) { _ = try await wrongRoot.search("needle") }
    }

    @Test("Cancellation and query deadlines clean up their handler so the space remains readable")
    func boundedQuery() async throws {
        let s = try fixture(); defer { remove(s) }
        try await KnowledgeService(databaseQueue: s.queue).save(KnowledgeItem(title: "deadline", content: "source"))
        let timed = SpaceSearchService(databaseQueue: s.queue, space: .work, catalogDirectory: s.root, timeout: 0)
        await #expect(throws: SpaceSearchError.timedOut) { _ = try await timed.search("deadline", kind: .knowledge) }
        let task = Task {
            try Task.checkCancellation()
            return try await s.search.search("deadline")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await s.search.search("deadline", kind: .knowledge).hits.count == 1)
    }
}
