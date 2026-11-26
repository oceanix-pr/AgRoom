import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Search, references and source navigation", .serialized)
@MainActor
struct SpaceSearchFlowTests {
    private struct Fixture {
        let root: URL
        let queue: DatabaseQueue
        let hub: Hub
        let search: SpaceSearchService
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-flow-" + UUID().uuidString)
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        return .init(root: root, queue: queue, hub: hub,
            search: SpaceSearchService(databaseQueue: queue, space: .work, catalogDirectory: root.appendingPathComponent("work")))
    }

    @Test("A superseded query or closed context cannot publish results, and quoting rechecks the inspected version")
    func staleSearchAndChangedReference() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let knowledge = KnowledgeService(databaseQueue: f.queue)
        var first = KnowledgeItem(title: "Alpha reference", content: "Alpha saved content")
        try await knowledge.save(first)
        try await knowledge.save(KnowledgeItem(title: "Beta reference", content: "Beta saved content"))
        let model = SpaceSearchModel(service: f.search, isCurrent: { true })
        model.kind = .knowledge; model.query = "Alpha"
        let old = Task { await model.load() }
        await Task.yield()
        model.query = "Beta"; await model.load(); await old.value
        #expect(model.hits.count == 1 && model.hits.first?.title == "Beta reference")
        model.query = "Alpha"; await model.load(); await model.loadPreview()
        #expect(model.preview?.content == first.content)
        first.content = "Edited after inspection"; first.updatedAt = first.updatedAt.addingTimeInterval(1)
        try await knowledge.updateContent(first)
        #expect(await model.quote() == nil)
        #expect(model.errorText == L.errorDescription(SpaceSearchError.changed))
        await model.loadPreview()
        #expect(await model.quote()?.content == first.content)
        model.cancel(); model.query = "Beta"; await model.load()
        #expect(model.hits.isEmpty && model.preview == nil && !model.loading)
        #expect(await model.quote() == nil)
    }

    @Test("A reference appends to the captured conversation draft without sending, losing attachments or accepting another context")
    func referenceDraftProtection() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let registry = WorkspaceRegistry(fileURL: f.root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: f.root.appendingPathComponent("files")))
        let model = ChatViewModel(hub: f.hub, workspaceRegistry: registry, observeHostServices: false, draftDefaults: nil)
        let sessions = SessionService(databaseQueue: f.queue), session = ChatSession(title: "Existing draft")
        try await sessions.save(session); await model.load(); model.activeSessionId = session.id
        let file = f.root.appendingPathComponent("attached.txt"); try Data("Keep attachment".utf8).write(to: file)
        model.inputText = "Keep my instructions"; model.addAttachments([file])
        let item = KnowledgeItem(title: "Reference title", content: "Source text\nSecond line")
        try await KnowledgeService(databaseQueue: f.queue).save(item)
        let hit = try #require(try await f.search.search("Reference title", kind: .knowledge).hits.first)
        let preview = try await f.search.preview(hit)
        try model.appendSearchReference(try await f.search.reference(preview), expectedSessionID: session.id)
        #expect(model.inputText.hasPrefix("Keep my instructions\n\n> "))
        #expect(model.inputText.contains("> Source text\n> Second line"))
        #expect(model.pendingAttachments == [file] && model.drafts[session.id] == model.inputText)
        #expect(model.activeSessionId == session.id && !model.isAnyRunning)
        #expect(try await sessions.fetch(id: session.id)?.messages.isEmpty == true)
        let before = model.inputText
        #expect(throws: SpaceSearchError.invalidScope) { try model.appendSearchReference(preview, expectedSessionID: nil) }
        let foreign = SpaceSearchPreview(hit: .init(space: .personal, kind: hit.kind, sourceID: hit.sourceID,
            title: hit.title, snippet: hit.snippet, modifiedAt: hit.modifiedAt, parentID: hit.parentID,
            secondaryID: hit.secondaryID, isEnabled: hit.isEnabled, query: hit.query, rank: hit.rank),
            content: preview.content, truncated: false, revision: preview.revision)
        #expect(throws: SpaceSearchError.invalidScope) { try model.appendSearchReference(foreign, expectedSessionID: session.id) }
        #expect(model.inputText == before && model.pendingAttachments == [file])
        let route = SpaceSearchRoutes.source(preview)
        #expect(route.page == "knowledge" && route.contentID == item.id.uuidString && route.draft == nil)
    }

    @Test("Old mail opens its actual account and folder while subsequent pages stay complete and deduplicated")
    func olderMailSource() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let accounts = MailAccountService(databaseQueue: f.queue, space: .work), mail = MailService(databaseQueue: f.queue)
        let a = MailAccount(displayName: "First", emailAddress: "a@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "a")
        let b = MailAccount(displayName: "Second", emailAddress: "b@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "b")
        try await accounts.save(a, password: nil); try await accounts.save(b, password: nil)
        let inbox = MailFolder(accountId: a.id, path: "INBOX", name: "Inbox", role: .inbox)
        let archive = MailFolder(accountId: b.id, path: "Archive", name: "Archive", role: .archive)
        try await mail.upsertFolders([inbox, archive])
        let messages = (1...421).map { MailMessage(accountId: b.id, folderId: archive.id, uid: UInt32($0),
            subject: "Saved message \($0)", date: Date(timeIntervalSince1970: Double($0)), bodyState: .ready) }
        try await mail.upsertMessages(messages)
        let target = try #require(messages.first)
        try await mail.saveBody(.init(messageId: target.id, textBody: "CACHED OLD SOURCE"))
        let model = MailViewModel(hub: f.hub, space: .work)
        await model.loadIfNeeded(); await model.openSearchSource(target.id, isCurrent: { true })
        #expect(model.selectedAccountId == b.id && model.selectedFolderId == archive.id && model.selectedMessageId == target.id)
        #expect(model.body?.textBody == "CACHED OLD SOURCE" && model.messages.count == 201)
        await model.reloadMessages()
        #expect(model.selectedMessageId == target.id && model.messages.contains { $0.id == target.id })
        while model.hasMoreMessages { await model.loadMoreMessages() }
        #expect(Set(model.messages.map(\.id)) == Set(messages.map(\.id)))
        #expect(model.messages.count == messages.count && model.messages.first?.uid == 421 && model.messages.last?.uid == 1)
        await model.reloadMessages()
        #expect(model.messages.count == messages.count)
        #expect(model.selectedMessageId == target.id && model.selectedMessageIDs == [target.id])
        await model.openSearchSource(target.id, isCurrent: { false })
        #expect(model.selectedMessageId == target.id && model.body?.textBody == "CACHED OLD SOURCE")
        model.cancelPendingWork()
    }
}
