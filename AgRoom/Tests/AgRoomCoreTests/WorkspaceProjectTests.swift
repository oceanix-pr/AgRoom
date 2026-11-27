import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Space-bound workspace projects")
struct WorkspaceProjectTests {
    private func queue() throws -> DatabaseQueue { let q = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(q); return q }

    @MainActor @Test("聊天 Markdown 上下文跟随会话目录、失效状态和数据策略")
    func markdownSessionContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: try queue()), skillDirectoryRoot: root)
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root))
        let model = ChatViewModel(hub: hub, space: .work, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil)
        var work = ChatWorkspace(name: "one", path: root.appendingPathComponent("one").path, isDefault: true, space: .work)
        let other = ChatWorkspace(name: "two", path: root.appendingPathComponent("two").path, space: .work)
        model.workspaces = [work, other]
        var session = ChatSession()
        #expect(model.markdownContext(for: session).allowedRoots == work.folderURLs)
        work.referencedFolders = [.init(path: root.appendingPathComponent("reference").path)]
        model.workspaces[0] = work
        session.dataPolicy = .localOnly
        let restricted = model.markdownContext(for: session)
        #expect(restricted.allowedRoots == work.folderURLs && !restricted.allowsRemoteMedia)
        session.workspaceId = other.id.uuidString
        #expect(model.markdownContext(for: session).allowedRoots == other.folderURLs)
        model.brokenWorkspaceIds = [other.id]
        #expect(model.markdownContext(for: session).allowedRoots.isEmpty)
        #expect(MarkdownSourceContext.conversation(space: .personal, workspace: work).allowedRoots.isEmpty)

        let registered = try registry.createWorkspace(named: "project", for: .work)
        let reference = root.appendingPathComponent("shared-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        session.workspaceId = registered.id.uuidString
        model.reloadWorkspaces()
        let file = reference.appendingPathComponent("image.png").path
        try registry.addReferencedFolders([reference], to: registered.id, in: .work)
        try await wait { (try? model.markdownContext(for: session).resolveImage(file)) != nil }
        let folder = try #require(model.workspaces.first { $0.id == registered.id }?.referencedFolders.first)
        try registry.removeReferencedFolder(folder.id, from: registered.id, in: .work)
        try await wait { (try? model.markdownContext(for: session).resolveImage(file)) == nil }
    }
    @MainActor private final class RunProbe {
        var requests: [ChatEngineRequest] = []
        var gate: CheckedContinuation<Void, Never>?
        var current = true
        var editable = true
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw WorkspaceProjectError.unavailable
    }

    @Test("Project content is physically isolated, version checked and never overwrites a competing edit")
    func isolationAndConcurrentEdit() async throws {
        let work = try queue(), personal = try queue(), id = UUID(), base = UUID()
        let store = WorkspaceProjectStore(databaseQueue: work, space: .work)
        let other = WorkspaceProjectStore(databaseQueue: personal, space: .personal)
        let configuration = WorkspaceProjectConfiguration(instructions: "WORK PRIVATE PROJECT", knowledgeBaseIDs: [base], preferredSkillNames: ["source-review"])
        let saved = try await store.save(configuration, workspaceID: id, expectedRevision: nil)
        #expect(try await other.project(workspaceID: id) == nil)
        try await other.save(.init(instructions: "PERSONAL PRIVATE PROJECT", knowledgeBaseIDs: []), workspaceID: id, expectedRevision: nil)
        #expect(try await store.project(workspaceID: id) == saved)
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for value in ["Revision A", "Revision B"] {
                group.addTask {
                    do { _ = try await store.save(.init(instructions: value), workspaceID: id, expectedRevision: saved.revision); return true }
                    catch WorkspaceProjectError.changed { return false }
                    catch { Issue.record("Unexpected edit error: \(error)"); return false }
                }
            }
            var values: [Bool] = []; for await result in group { values.append(result) }; return values
        }
        #expect(outcomes.filter { $0 }.count == 1)
        #expect(try await other.project(workspaceID: id)?.configuration.instructions == "PERSONAL PRIVATE PROJECT")
        await #expect(throws: WorkspaceProjectError.changed) { _ = try await store.save(configuration, workspaceID: id, expectedRevision: nil) }
    }

    @Test("Malformed content and failed persistence cannot silently expand a project's knowledge selection")
    func invalidAndFailedSave() async throws {
        let q = try queue(), id = UUID(), store = WorkspaceProjectStore(databaseQueue: q, space: .work)
        let original = try await store.save(.init(instructions: "Retained", knowledgeBaseIDs: []), workspaceID: id, expectedRevision: nil)
        await #expect(throws: WorkspaceProjectError.invalid) {
            _ = try await store.save(.init(instructions: String(repeating: "x", count: 12_001)), workspaceID: id, expectedRevision: original.revision)
        }
        try await q.write { db in try db.execute(sql: "CREATE TRIGGER reject_project_change BEFORE UPDATE ON workspace_projects BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        await #expect(throws: (any Error).self) { _ = try await store.save(.init(instructions: "Must not save"), workspaceID: id, expectedRevision: original.revision) }
        #expect(try await store.project(workspaceID: id) == original)
        try await q.write { db in
            try db.execute(sql: "DROP TRIGGER reject_project_change")
            try db.execute(sql: "UPDATE workspace_projects SET configuration=? WHERE workspaceID=?", arguments: [Data("broken".utf8), id.uuidString])
        }
        await #expect(throws: (any Error).self) { _ = try await store.context(workspaceID: id) }
        try DatabaseBootstrap.prepareSpace(q)
    }

    @Test("Complete backup remaps workspace identity while retaining project context and recovery semantics")
    func backup() async throws {
        let source = try queue(), target = try queue(), oldID = UUID(), newID = UUID()
        let configuration = WorkspaceProjectConfiguration(instructions: "Project conventions", knowledgeBaseIDs: [], preferredSkillNames: ["review"])
        let original = try await WorkspaceProjectStore(databaseQueue: source, space: .work).save(configuration, workspaceID: oldID, expectedRevision: nil)
        let archive = try await SpaceDatabaseBackupStore(queue: source, space: "work").export()
        let destination = SpaceDatabaseBackupStore(queue: target, space: "personal")
        let plan = try await destination.plan(archive, sourceSpace: "work", workspaceMappings: [oldID.uuidString:newID.uuidString])
        let applied = try await destination.apply(plan) { _ in }
        try await destination.verify(applied)
        let restored = try #require(try await WorkspaceProjectStore(databaseQueue: target, space: .personal).project(workspaceID: newID))
        #expect(restored.configuration == configuration && restored.revision == original.revision && restored.space == .personal)
        #expect(try await WorkspaceProjectStore(databaseQueue: target, space: .personal).project(workspaceID: oldID) == nil)
        try await destination.rollback(applied)
        #expect(try await WorkspaceProjectStore(databaseQueue: target, space: .personal).project(workspaceID: newID) == nil)
    }

    @Test("A run snapshot keeps its selected resources through Codable and explicit recovery rebinding")
    func snapshot() throws {
        let oldID = UUID(), newID = UUID()
        let project = WorkspaceProject(space: .work, workspaceID: oldID, configuration: .init(instructions: "Project rules", knowledgeBaseIDs: [], preferredSkillNames: ["review", "disabled-skill"]))
        let value = RunResourceContext(space: .work, workspaceID: oldID, project: project, excludesMemory: true)
        #expect(value.isValid && value.knowledgeBaseIDs?.isEmpty == true && value.suppressesBusinessDatabase)
        #expect(try JSONDecoder().decode(RunResourceContext.self, from: JSONEncoder().encode(value)) == value)
        let rebound = value.rebinding(space: .personal, workspaceMappings: [oldID.uuidString:newID.uuidString])
        #expect(rebound.isValid && rebound.workspaceID == newID && rebound.project?.space == .personal && rebound.excludesMemory)
        let prompt = try value.systemPrompt(availableSkillNames: ["review"])
        #expect(prompt.contains("Preferred available skills: review.") && prompt.contains("Memory is excluded"))
        var foreign = value; foreign.workspaceID = UUID()
        #expect(!foreign.isValid)
        #expect(throws: WorkspaceProjectError.invalid) { _ = try foreign.systemPrompt(availableSkillNames: []) }
    }

    @Test("Project knowledge selection limits real search, listing and writes even when a call asks for another base")
    func knowledgeSelection() async throws {
        let q = try queue(), service = KnowledgeService(databaseQueue: q)
        let first = KnowledgeBase(name: "Project A"), other = KnowledgeBase(name: "Outside project")
        try await service.saveBase(first); try await service.saveBase(other)
        var allowed = KnowledgeItem(title: "Atlas source A", content: "ATLAS ALLOWED EVIDENCE"); allowed.baseId = first.id
        var denied = KnowledgeItem(title: "Atlas source B", content: "ATLAS OUTSIDE SECRET"); denied.baseId = other.id
        try await service.save(allowed); try await service.save(denied)
        let scope: Set<UUID> = [first.id]
        let search = KnowledgeSearchTool(service: service, allowedBaseIDs: scope)
        let matched = try await search.execute(argumentsJSON: #"{"query":"ATLAS"}"#)
        #expect(matched.contains("ATLAS ALLOWED EVIDENCE") && !matched.contains("ATLAS OUTSIDE SECRET"))
        let outside = try await search.execute(argumentsJSON: "{\"query\":\"ATLAS\",\"base_id\":\"\(other.id)\"}")
        #expect(!outside.contains("ATLAS OUTSIDE SECRET") && outside.contains("No knowledge passages"))
        let listed = try await KnowledgeListTool(service: service, allowedBaseIDs: scope).execute(argumentsJSON: "{}")
        #expect(listed.contains(first.name) && !listed.contains(other.name) && !listed.contains(denied.title))
        let empty = try await KnowledgeSearchTool(service: service, allowedBaseIDs: []).execute(argumentsJSON: #"{"query":"ATLAS"}"#)
        #expect(empty.contains("No knowledge passages"))
        let save = KnowledgeSaveTool(service: service, allowedBaseIDs: scope)
        await #expect(throws: WorkspaceProjectError.outsideKnowledgeScope) {
            _ = try await save.execute(argumentsJSON: "{\"id\":\"\(denied.id)\",\"title\":\"Must not update\"}")
        }
        await #expect(throws: WorkspaceProjectError.outsideKnowledgeScope) {
            _ = try await save.execute(argumentsJSON: #"{"title":"Must not create","content":"x","base":"Unselected new base"}"#)
        }
        #expect(try await service.getBases().count == 2)
        _ = try await save.execute(argumentsJSON: #"{"title":"New project evidence","content":"Allowed write","base":"Project A"}"#)
        #expect(try await service.getAll().count == 3)
        var moved = allowed; moved.baseId = other.id; try await service.save(moved)
        await #expect(throws: WorkspaceProjectError.outsideKnowledgeScope) { try await service.save(allowed, allowedBaseIDs: scope) }
        await #expect(throws: WorkspaceProjectError.outsideKnowledgeScope) { try await service.delete(id: moved.id, allowedBaseIDs: scope) }
        #expect(try await service.get(id: moved.id)?.baseId == other.id)
        #expect(try await service.get(id: denied.id)?.content == denied.content)
    }

    @Test("Excluding memory removes every memory entry point and persists the exact resource choice through engine and daemon snapshots")
    @MainActor
    func memoryToolFaceAndSnapshot() throws {
        let q = try queue(), memory = MemoryService(databaseQueue: q)
        let resource = RunResourceContext(space: .work, workspaceID: UUID(), excludesMemory: true)
        let provider = FirstTaskFixtureProvider.make()
        let tools = DispatcherToolFactory.buildTools(provider: provider, agents: [Agent(name: "Reviewer")], memoryService: memory,
            knowledgeService: KnowledgeService(databaseQueue: q), resourceContext: resource)
        let names = tools.map { $0.definition.name }
        #expect(!names.contains { $0.hasPrefix("memory_") || $0.hasPrefix("backup_") || $0 == "sql_query" })
        let delegate = try #require(tools.compactMap { $0 as? AgentTool }.first)
        #expect(delegate.memoryService == nil && delegate.resourceContext == resource)
        let engine = DispatcherEngine(provider: provider, tools: tools, systemPrompt: "Synthetic context")
        engine.setContextMemoryIDs([UUID()], contents: ["Must clear this prior metadata"])
        engine.setResourceContext(resource)
        #expect(engine.requestReport.memoryIDs.isEmpty && engine.requestReport.memoryContents == nil)
        let restored = try JSONDecoder().decode(EngineRunSnapshot.self, from: JSONEncoder().encode(engine.takeSnapshot()))
        #expect(restored.contextReport?.resourceContext == resource)
        var settings = DaemonRunSettings(maxTokens: 256, temperature: 0, reasoningEffortRaw: nil, maxSteps: 4,
            replyLanguageInstruction: "English", personaInstruction: nil, workspacePath: "")
        settings.resourceContext = resource
        #expect(try JSONDecoder().decode(DaemonRunSettings.self, from: JSONEncoder().encode(settings)).resourceContext == resource)
        settings.resourceContext = nil
        #expect(try JSONDecoder().decode(DaemonRunSettings.self, from: JSONEncoder().encode(settings)).resourceContext == nil)
        let user = ChatMessage(role: .user, content: "Excluded from extraction", memoryExcluded: true)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(user)).memoryExcluded == true)
        let foreign = DispatcherToolFactory.buildTools(provider: provider, agents: [], memoryService: memory, space: .personal, resourceContext: resource)
        #expect(foreign.isEmpty)
    }

    @Test("Later extraction and independent task history retain an excluded turn even after another answer version is selected")
    @MainActor
    func extractionAndHistory() async throws {
        let q = try queue(), service = SessionService(databaseQueue: q), workspace = UUID()
        let project = WorkspaceProject(space: .work, workspaceID: workspace, configuration: .init(instructions: "FROZEN RULES", knowledgeBaseIDs: []))
        let resource = RunResourceContext(space: .work, workspaceID: workspace, project: project, excludesMemory: true)
        var report = RequestContextReport(); report.resourceContext = resource
        var session = ChatSession(title: "Exclusion history", workspaceId: workspace.uuidString)
        let privateID = UUID()
        let original = ChatMessage(role: .assistant, content: "PRIVATE ANSWER", runStatus: .succeeded, contextReport: report,
            taskRun: .init(id: privateID))
        session.messages = [.init(role: .user, content: "PRIVATE USER", memoryExcluded: true), original,
            .init(role: .user, content: "PUBLIC USER"), .init(role: .assistant, content: "PUBLIC ANSWER", runStatus: .succeeded, taskRun: .init())]
        try await service.save(session)
        #expect(ChatViewModel.memoryEligibleMessages(in: session.messages).map(\.content) == ["PUBLIC USER", "PUBLIC ANSWER"])
        session.messages[1].variations = [AnswerVariation(question: "PRIVATE USER", message: original), AnswerVariation(question: "PRIVATE USER", content: "RETRY WITHOUT FLAG")]
        session.messages[1].activeVariationIndex = 1
        session.messages[1].content = "RETRY WITHOUT FLAG"; session.messages[1].contextReport = nil; session.messages[1].taskRun = .init()
        session.messages[0].memoryExcluded = nil // Variation snapshot independently protects older exports.
        #expect(!ChatViewModel.memoryEligibleMessages(in: session.messages).map(\.content).joined().contains("PRIVATE"))
        try await service.save(session)
        let retained = try #require(try await ProductTaskRunStore(databaseQueue: q).run(id: privateID))
        #expect(retained.resourceContext == resource)
        let destination = try queue(), reboundID = UUID()
        let archive = try await SpaceDatabaseBackupStore(queue: q, space: "work").export()
        let recovery = SpaceDatabaseBackupStore(queue: destination, space: "personal")
        let plan = try await recovery.plan(archive, sourceSpace: "work", workspaceMappings: [workspace.uuidString:reboundID.uuidString])
        _ = try await recovery.apply(plan) { _ in }
        let restored = try #require(try await ProductTaskRunStore(databaseQueue: destination).run(id: privateID))
        #expect(restored.resourceContext == resource.rebinding(space: .personal, workspaceMappings: [workspace.uuidString:reboundID.uuidString]))
    }

    @Test("Project editing rejects stale or closed owners, preserves competing edits and does not grant a directory")
    @MainActor
    func editorLifecycle() async throws {
        let q = try queue(), root = FileManager.default.temporaryDirectory.appendingPathComponent("project-editor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: q), skillDirectoryRoot: root.appendingPathComponent("catalog"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root.appendingPathComponent("files")))
        let workspace = try #require(registry.defaultWorkspace(for: .work)), probe = RunProbe()
        let oldFolders = workspace.folderURLs
        let first = WorkspaceProjectModel(hub: hub, workspace: workspace, isCurrent: { probe.current }, allowsChanges: { probe.editable })
        let second = WorkspaceProjectModel(hub: hub, workspace: workspace, isCurrent: { probe.current })
        await first.load(); await second.load()
        #expect(first.ready && first.canSave)
        first.configuration = .init(instructions: "FIRST PROJECT", knowledgeBaseIDs: [])
        probe.editable = false
        #expect(!first.canSave)
        #expect(await first.save() == false)
        probe.editable = true
        #expect(await first.save())
        second.configuration.instructions = "STALE OVERWRITE"
        #expect(await second.save() == false && second.errorText != nil)
        await second.load()
        #expect(second.configuration.instructions == "FIRST PROJECT" && second.configuration.knowledgeBaseIDs == [])
        second.configuration.instructions = "CLOSED OVERWRITE"; second.close()
        #expect(await second.save() == false)
        probe.current = false
        #expect(!first.canSave)
        #expect(await first.save() == false)
        #expect(try await hub.makeWorkspaceProjectStore(for: .work)?.project(workspaceID: workspace.id)?.configuration.instructions == "FIRST PROJECT")
        #expect(registry.defaultWorkspace(for: .work)?.folderURLs == oldFolders)
    }

    @Test("Send, queue and retry freeze their own memory choice, survive conversation switches and load later project revisions only for later runs")
    @MainActor
    func realSendQueueAndRetry() async throws {
        let q = try queue(), root = FileManager.default.temporaryDirectory.appendingPathComponent("project-send-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: q), skillDirectoryRoot: root.appendingPathComponent("catalog"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"), fileAreaService: .init(baseDirectory: root.appendingPathComponent("files")))
        let workspace = try #require(registry.defaultWorkspace(for: .work)), probe = RunProbe()
        let projects = try #require(hub.makeWorkspaceProjectStore(for: .work))
        let original = try await projects.save(.init(instructions: "FIRST REVISION", knowledgeBaseIDs: []), workspaceID: workspace.id, expectedRevision: nil)
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil, makeEngine: { request in
            probe.requests.append(request)
            if probe.requests.count == 1 { await withCheckedContinuation { probe.gate = $0 } }
            return DispatcherEngine(provider: WorkspaceResourceProvider.make(), tools: [], systemPrompt: "Disposable run")
        })
        await model.load(); model.newSession()
        let owner = try #require(model.activeSessionId)
        model.excludesMemoryForNextTurn = true; model.inputText = "FIRST PRIVATE"; model.send()
        try await wait { probe.gate != nil }
        #expect(probe.requests.first?.settings.resourceContext?.excludesMemory == true)
        #expect(!model.excludesMemoryForNextTurn)
        model.excludesMemoryForNextTurn = true; model.inputText = "QUEUED PRIVATE"; model.send()
        #expect(model.activeQueue.first?.memoryExcluded == true && !model.excludesMemoryForNextTurn)
        model.inputText = "QUEUED ORDINARY"; model.send()
        model.excludesMemoryForNextTurn = true // This unsent choice must not be consumed by queue draining.
        _ = try await projects.save(.init(instructions: "SECOND REVISION", knowledgeBaseIDs: []), workspaceID: workspace.id, expectedRevision: original.revision)
        model.newSession()
        let other = try #require(model.activeSessionId)
        #expect(other != owner && !model.excludesMemoryForNextTurn)
        model.excludesMemoryForNextTurn = true
        probe.gate?.resume(); probe.gate = nil
        try await wait { probe.requests.count == 3 && !model.isAnyRunning }
        #expect(probe.requests.allSatisfy { $0.sessionID == owner })
        #expect(probe.requests.map { $0.settings.resourceContext?.excludesMemory } == [true, true, false])
        #expect(probe.requests.first?.settings.resourceContext?.project?.configuration.instructions == "FIRST REVISION")
        #expect(probe.requests.last?.settings.resourceContext?.project?.configuration.instructions == "SECOND REVISION")
        #expect(model.activeSessionId == other && model.excludesMemoryForNextTurn)
        model.activeSessionId = owner
        #expect(model.excludesMemoryForNextTurn)
        let lastAnswer = try #require(model.session(id: owner)?.messages.last)
        model.retryAnswer(messageId: lastAnswer.id)
        try await wait { probe.requests.count == 4 && !model.isAnyRunning }
        #expect(probe.requests.last?.settings.resourceContext?.excludesMemory == true && !model.excludesMemoryForNextTurn)
        model.retryAnswer(messageId: lastAnswer.id)
        try await wait { probe.requests.count == 5 && !model.isAnyRunning }
        #expect(probe.requests.last?.settings.resourceContext?.excludesMemory == true)
        model.inputText = "LATER ORDINARY"; model.send()
        try await wait { probe.requests.count == 6 && !model.isAnyRunning }
        #expect(probe.requests.last?.settings.resourceContext?.excludesMemory == false)
        let persisted = try #require(try await SessionService(databaseQueue: q).fetch(id: owner))
        #expect(persisted.messages.filter { $0.role == .user && $0.memoryExcluded == true }.count == 3)
        #expect(ChatViewModel.memoryEligibleMessages(in: persisted.messages).map(\.content).joined().contains("LATER ORDINARY"))
        #expect(!ChatViewModel.memoryEligibleMessages(in: persisted.messages).map(\.content).joined().contains("PRIVATE"))
    }

    @Test("Actual delegated engines and team workers cannot retrieve excluded memory or knowledge from an unselected base")
    @MainActor
    func delegates() async throws {
        let q = try queue(), knowledge = KnowledgeService(databaseQueue: q), memory = MemoryService(databaseQueue: q)
        let selected = KnowledgeBase(name: "Selected"), outside = KnowledgeBase(name: "Outside")
        try await knowledge.saveBase(selected); try await knowledge.saveBase(outside)
        var permitted = KnowledgeItem(title: "ATLAS", content: "ATLAS ALLOWED EVIDENCE"); permitted.baseId = selected.id
        var denied = KnowledgeItem(title: "ATLAS", content: "ATLAS OUTSIDE SECRET"); denied.baseId = outside.id
        try await knowledge.save(permitted); try await knowledge.save(denied)
        try await memory.save(MemoryItem(content: "ATLAS PRIVATE MEMORY"))
        let workspace = UUID(), agent = Agent(name: "Reviewer")
        let context = RunResourceContext(space: .work, workspaceID: workspace,
            project: .init(space: .work, workspaceID: workspace, configuration: .init(knowledgeBaseIDs: [selected.id])), excludesMemory: true)
        let provider = WorkspaceResourceProvider.make(delegate: true)
        let delegated = try await AgentTool(agent: agent, provider: provider, knowledgeService: knowledge, memoryService: memory, resourceContext: context)
            .execute(argumentsJSON: #"{"message":"ATLAS"}"#)
        #expect(delegated.contains("ALLOWED EVIDENCE") && !delegated.contains("OUTSIDE SECRET") && !delegated.contains("PRIVATE MEMORY"))
        let subtask = TeamSubtask(title: "Review", objective: "ATLAS")
        let factory = DispatcherTeamWorkerFactory(provider: provider, agents: [agent], memoryService: memory, knowledgeService: knowledge, resourceContext: context)
        let worker = try await factory.makeWorker(taskID: UUID(), plan: .init(goal: "ATLAS", subtasks: [subtask]), subtask: subtask, inputs: [], budget: .default)
        let result = try await worker.run()
        #expect(result.summary.contains("ALLOWED EVIDENCE") && !result.summary.contains("OUTSIDE SECRET") && !result.summary.contains("PRIVATE MEMORY"))
        let foreign = DispatcherTeamWorkerFactory(provider: provider, agents: [agent], space: .personal, resourceContext: context)
        await #expect(throws: WorkspaceProjectError.wrongWorkspace) {
            _ = try await foreign.makeWorker(taskID: UUID(), plan: .init(goal: "ATLAS", subtasks: [subtask]), subtask: subtask, inputs: [], budget: .default)
        }
    }
}

private enum WorkspaceResourceProvider {
    static func make(delegate: Bool = false) -> CloudProvider {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkspaceResourceProtocol.self]
        config.httpAdditionalHeaders = ["X-Delegate":delegate ? "true" : "false"]
        return CloudProvider(config: .init(name: "Resource fixture", endpoint: "https://resource-context.invalid/v1", model: "fixture"),
            apiKey: "synthetic", session: URLSession(configuration: config))
    }
}

private final class WorkspaceResourceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "resource-context.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String:Any] ?? [:]
            let messages = object["messages"] as? [[String:Any]] ?? [], results = messages.filter { $0["role"] as? String == "tool" }
            let delegate = request.value(forHTTPHeaderField: "X-Delegate") == "true"
            let delta: [String:Any], reason: String
            if delegate && results.count < 2 {
                let name = results.isEmpty ? "memory_search" : "knowledge_search" // Deliberately forge the removed memory tool.
                delta = ["tool_calls":[["index":0,"id":"resource-\(results.count)","function":["name":name,"arguments":#"{"query":"ATLAS"}"#]]]]; reason = "tool_calls"
            } else {
                let content = delegate ? messages.filter { $0["role"] as? String != "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n") : "SYNTHETIC RESULT"
                let tools = object["tools"] as? [[String:Any]] ?? []
                if tools.contains(where: { ($0["function"] as? [String:Any])?["name"] as? String == "team_submit_result" }) {
                    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["summary":content,"outcome":"succeeded"]), as: UTF8.self)
                    delta = ["tool_calls":[["index":0,"id":"team-result","function":["name":"team_submit_result","arguments":arguments]]]]; reason = "tool_calls"
                } else { delta = ["content":content]; reason = "stop" }
            }
            let event: [String:Any] = ["choices":[["delta":delta,"finish_reason":reason]],"usage":["prompt_tokens":20,"completion_tokens":10]]
            let body = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\ndata: [DONE]\n\n"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
