import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
@Suite("Conversation title completion", .serialized)
struct ConversationTitleGenerationTests {
    private struct Fixture {
        let root: URL
        let queue: DatabaseQueue
        let model: ChatViewModel
        let session: ChatSession
        var service: SessionService { .init(databaseQueue: queue) }
    }

    private func fixture(title: String = "", queued: Bool = false,
        completion: @escaping @MainActor ([EngineMessage], LLMConfig) async throws -> String) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("title-completion-" + UUID().uuidString)
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: root.appendingPathComponent("files")))
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil,
            generateTitle: completion)
        var session = ChatSession(title: title)
        session.messages = [ChatMessage(role: .user, content: "将侧栏按钮改为直接切换工作区"),
            ChatMessage(role: .assistant, content: "已完成按钮修改", runStatus: .succeeded)]
        if queued { session.messages.append(ChatMessage(role: .user, content: "继续检查")) }
        try await SessionService(databaseQueue: queue).save(session)
        model.sessions = [session]
        return .init(root: root, queue: queue, model: model, session: session)
    }

    private var generatedTitle: String {
        LanguageManager.shared.activeLanguageCode == "en" ? "Workspace switch button" : "工作区直接切换"
    }

    @Test("Queued messages do not prevent naming, and local reasoning receives a sufficient fast budget")
    func queuedTurn() async throws {
        let expected = generatedTitle
        var calls = 0
        let f = try await fixture(queued: true) { _, config in
            calls += 1
            #expect(config.maxTokens >= 2048 && config.reasoningEffort == .fast)
            return expected
        }
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.autoTitleIfNeeded(containing: f.session.messages[1].id)
        #expect(f.model.sessions[0].title == expected)
        #expect(try await f.service.fetch(id: f.session.id)?.title == expected)
        #expect(calls == 1)
    }

    @Test("Empty local output persists the question as a useful fallback instead of New Chat", arguments: ["", "新对话", "新對談", "New Chat"])
    func localEmptyOutput(oldTitle: String) async throws {
        var calls = 0
        let f = try await fixture(title: oldTitle) { _, _ in calls += 1; return "" }
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.autoTitleIfNeeded(containing: f.session.messages[1].id)
        let expected = ConversationTitle.fallback(question: f.session.messages[0].content)
        #expect(f.model.sessions[0].title == expected && !ConversationTitle.isPlaceholder(expected))
        #expect(try await f.service.fetch(id: f.session.id)?.title == expected)
        await f.model.autoTitleIfNeeded(containing: f.session.messages[1].id)
        #expect(calls == 2)
    }

    @Test("A failed title request does not discard the completed conversation or its fallback")
    func requestFailure() async throws {
        let f = try await fixture { _, _ in throw CancellationError() }
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.autoTitleIfNeeded(containing: f.session.messages[1].id)
        let saved = try #require(try await f.service.fetch(id: f.session.id))
        #expect(!ConversationTitle.isPlaceholder(saved.title))
        #expect(saved.messages[1].content == "已完成按钮修改")
    }

    @MainActor private final class PendingReply {
        var started = false
        var continuation: CheckedContinuation<String, Never>?
        func read() async -> String {
            await withCheckedContinuation { continuation = $0; started = true }
        }
    }

    @Test("A background title cannot overwrite a manual rename")
    func renameDuringGeneration() async throws {
        let pending = PendingReply(), expected = generatedTitle
        let f = try await fixture { _, _ in await pending.read() }
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = Task { await f.model.autoTitleIfNeeded(containing: f.session.messages[1].id) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !pending.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(pending.started)
        f.model.renameSession(id: f.session.id, title: "我的手动标题")
        pending.continuation?.resume(returning: expected)
        await task.value
        #expect(f.model.sessions[0].title == "我的手动标题")
        while try await f.service.fetch(id: f.session.id)?.title != "我的手动标题", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await f.service.fetch(id: f.session.id)?.title == "我的手动标题")
    }

    @Test("The database rejects stale titles after a rename, deletion or restore")
    func conditionalRename() async throws {
        let f = try await fixture { _, _ in "" }
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.rename(id: f.session.id, title: "Manual")
        #expect(try await !f.service.renameIfUnchanged(id: f.session.id, title: "Late", expectedTitle: "", restorationToken: nil))
        let id = f.session.id.uuidString
        try await f.queue.write { db in
            try db.execute(sql: "INSERT INTO chat_restore_tokens(sessionId,token) VALUES (?,?)", arguments: [id, "restored"])
        }
        #expect(try await !f.service.renameIfUnchanged(id: f.session.id, title: "Late", expectedTitle: "Manual", restorationToken: nil))
        #expect(try await f.service.fetch(id: f.session.id)?.title == "Manual")
        try await f.service.delete(id: f.session.id)
        #expect(try await !f.service.renameIfUnchanged(id: f.session.id, title: "Late", expectedTitle: "Manual", restorationToken: "restored"))
        #expect(try await f.service.fetch(id: f.session.id) == nil)
    }

    @Test("Reasoning wrappers and placeholder responses are not used as titles")
    func reasoningText() {
        #expect(ConversationTitle.cleaned("<think>Analyze the chat</think>\n工作区切换", languageCode: "zh-Hans") == "工作区切换")
        #expect(ConversationTitle.cleaned("<think>still reasoning", languageCode: "en") == nil)
        #expect(ConversationTitle.cleaned("新对话", languageCode: "zh-Hans") == nil)
    }
}
