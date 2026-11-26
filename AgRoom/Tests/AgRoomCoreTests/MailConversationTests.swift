import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Mail header conversations")
struct MailConversationTests {
    private struct Fixture {
        let queue: DatabaseQueue
        let mail: MailService
        let first: MailAccount
        let second: MailAccount
        let inbox: MailFolder
        let other: MailFolder
        let foreign: MailFolder
    }

    private func fixture(_ existing: DatabaseQueue? = nil) async throws -> Fixture {
        let queue = try existing ?? DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue)
        let first = try await mail.createLocalArchive(name: "First", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let second = try await mail.createLocalArchive(name: "Second", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let ownFolders = try await mail.folders(accountId: first.id)
        return .init(queue: queue, mail: mail, first: first, second: second,
            inbox: try #require(ownFolders.first { $0.role == .inbox }),
            other: try #require(ownFolders.first { $0.role == .archive }),
            foreign: try #require(try await mail.folders(accountId: second.id).first { $0.role == .inbox }))
    }

    @Test("Exact header edges connect transitive and missing-parent siblings across folders, never accounts or subjects")
    func componentAndIsolation() async throws {
        let f = try await fixture()
        let root = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: MailService.localUIDFloor, messageId: "<root%_@test>", subject: "Same subject")
        let child = MailMessage(accountId: f.first.id, folderId: f.other.id, uid: MailService.localUIDFloor + 1, messageId: "<child@test>", references: "<root%_@test>")
        let leaf = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: MailService.localUIDFloor + 2, messageId: "<leaf@test>", references: "<child@test> <missing@test>")
        let sibling = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: MailService.localUIDFloor + 3, messageId: "<sibling@test>", references: "<missing@test> <leaf@test>")
        let unrelated = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: MailService.localUIDFloor + 4, messageId: "<rootXX@test>", subject: "Same subject")
        let substring = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: MailService.localUIDFloor + 5, references: "<prefixroot%_@test>")
        let foreign = MailMessage(accountId: f.second.id, folderId: f.foreign.id, uid: MailService.localUIDFloor, messageId: "<root%_@test>")
        try await f.mail.upsertMessages([root, child, leaf, sibling, unrelated, substring, foreign])
        let expected = Set([root.id, child.id, leaf.id, sibling.id])
        #expect(Set(try await f.mail.conversationMessages(accountID: f.first.id, anchorID: leaf.id).map(\.id)) == expected)
        #expect(Set(try await f.mail.threadMessages(accountId: f.first.id, messageId: root.id, limit: 20).map(\.id)) == expected.subtracting([root.id]))
        #expect(try await f.mail.conversationMessages(accountID: f.second.id, anchorID: foreign.id).map(\.id) == [foreign.id])
        await #expect(throws: MailSearchError.unavailable) { try await f.mail.conversationMessages(accountID: f.second.id, anchorID: root.id) }
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        await #expect(throws: MailSearchError.unavailable) { try await MailService(databaseQueue: isolated).conversationMessages(accountID: f.first.id, anchorID: root.id) }
    }

    @Test("Chronological keysets retain equal and absent dates without duplicates or skipped messages")
    func keysetPaging() async throws {
        let f = try await fixture()
        let messages = (0..<121).map { index in
            MailMessage(accountId: f.first.id, folderId: index.isMultiple(of: 2) ? f.inbox.id : f.other.id,
                uid: MailService.localUIDFloor + UInt32(index), messageId: "<\(index)@test>", references: "<missing-root@test>",
                date: index < 8 ? nil : Date(timeIntervalSince1970: Double(index / 10)))
        }
        try await f.mail.upsertMessages(messages)
        let anchor = messages[120]
        var cursor: MailConversationCursor?, ids: [UUID] = []
        while ids.count <= messages.count {
            let page = try await f.mail.conversationMessages(accountID: f.first.id, anchorID: anchor.id, after: cursor, limit: 7)
            guard let last = page.last else { break }
            ids += page.map(\.id); cursor = .init(date: last.date, id: last.id)
        }
        let full = try await f.mail.conversationMessages(accountID: f.first.id, anchorID: anchor.id, limit: 200)
        #expect(ids == full.map(\.id) && ids.count == messages.count && Set(ids).count == messages.count)
        #expect(full.prefix(8).allSatisfy { $0.date == nil })
        #expect(try await f.mail.conversationMessages(accountID: f.first.id, anchorID: anchor.id, limit: 0).isEmpty)
    }

    @Test("Raw In-Reply-To backfills old databases, survives cache eviction, and live indexes follow updates and deletion")
    func migrationAndTriggers() async throws {
        let f = try await fixture()
        try await f.queue.write { db in
            for trigger in ["mail_thread_insert", "mail_thread_update", "mail_thread_raw_insert", "mail_thread_raw_update"] { try db.execute(sql: "DROP TRIGGER \(trigger)") }
            try db.execute(sql: "DROP TABLE mail_thread_links")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v15_mail_conversations'")
        }
        let parent = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: MailService.localUIDFloor, messageId: "<parent@test>")
        let reply = MailMessage(accountId: f.first.id, folderId: f.other.id, uid: MailService.localUIDFloor + 1, messageId: "<reply@test>")
        try await f.mail.upsertMessages([parent, reply])
        let raw = Data("Message-ID: <reply@test>\r\nIn-Reply-To: <parent@test>\r\nContent-Type: text/plain\r\n\r\nBody".utf8)
        try await f.mail.saveRawMessage(id: reply.id, raw: .init(data: raw, kind: .received))
        try DatabaseBootstrap.prepareSpace(f.queue); try DatabaseBootstrap.prepareSpace(f.queue)
        #expect(Set(try await f.mail.conversationMessages(accountID: f.first.id, anchorID: parent.id).map(\.id)) == [parent.id, reply.id])
        #expect(try await f.mail.rawMessage(id: reply.id)?.data == raw)
        try await f.queue.write { db in try db.execute(sql: "DELETE FROM mail_raw_messages WHERE messageID=?", arguments: [reply.id.uuidString]) }
        #expect(try await f.mail.conversationMessages(accountID: f.first.id, anchorID: parent.id).count == 2)
        try await f.mail.setReferences(messageId: reply.id, references: "<another@test>")
        #expect(try await f.mail.conversationMessages(accountID: f.first.id, anchorID: parent.id).map(\.id) == [parent.id])
        try await f.mail.saveRawMessage(id: reply.id, raw: .init(data: raw, kind: .received))
        #expect(try await f.mail.conversationMessages(accountID: f.first.id, anchorID: parent.id).count == 2)
        try await f.mail.deleteMessage(id: reply.id)
        #expect(try await f.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mail_thread_links WHERE messageID=?", arguments: [reply.id.uuidString]) } == 0)
    }

    @Test("Conversation links rebuild during backup restore and rollback, and functions are available after reopening")
    func backupAndReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mail-conversation-\(UUID()).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let f = try await fixture(DatabaseQueue(path: url.path))
        let first = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: MailService.localUIDFloor, messageId: "<root@test>")
        let second = MailMessage(accountId: f.first.id, folderId: f.other.id, uid: MailService.localUIDFloor + 1, messageId: "<second@test>")
        try await f.mail.upsertMessages([first, second])
        try await f.mail.saveRawMessage(id: second.id, raw: .init(data: Data("In-Reply-To: <root@test>\r\n\r\nBody".utf8), kind: .received))
        let reopened = try DatabaseQueue(path: url.path); try DatabaseBootstrap.prepareSpace(reopened)
        let reopenedMail = MailService(databaseQueue: reopened)
        try await reopenedMail.setReferences(messageId: second.id, references: "<root@test> <ancestor@test>")
        #expect(try await reopenedMail.conversationMessages(accountID: f.first.id, anchorID: first.id).count == 2)
        let backup = try await SpaceDatabaseBackupStore(queue: reopened, space: "work").export()
        #expect(!backup.tables.contains { $0.name == "mail_thread_links" })
        let target = try await fixture()
        let untouched = MailMessage(accountId: target.first.id, folderId: target.inbox.id, uid: MailService.localUIDFloor, messageId: "<untouched@test>")
        try await target.mail.upsertMessages([untouched])
        let store = SpaceDatabaseBackupStore(queue: target.queue, space: "work")
        let plan = try await store.plan(backup, sourceSpace: "work")
        #expect(!plan.before.tables.contains { $0.name == "mail_thread_links" })
        let receipt = try await store.apply(plan, willCommit: { _ in })
        try await store.verify(receipt)
        #expect(try await target.mail.conversationMessages(accountID: f.first.id, anchorID: first.id).count == 2)
        try await store.rollback(receipt)
        #expect(try await target.mail.conversationMessages(accountID: target.first.id, anchorID: untouched.id).map(\.id) == [untouched.id])
        #expect(try await target.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mail_thread_links") } == 1)
    }

    @Test("Partial summary parents preserve known ancestry and parsers use header fields rather than body text")
    func partialHeaderLearning() async throws {
        let f = try await fixture()
        var message = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: MailService.localUIDFloor,
            messageId: "<child@test>", references: "<root@test> <parent@test>")
        try await f.mail.upsertMessages([message])
        message.references = "<parent@test>"; try await f.mail.upsertMessages([message])
        #expect(try await f.mail.message(id: message.id)?.references == "<root@test> <parent@test>")
        message.messageId = nil; message.references = nil
        try await f.mail.upsertMessages([message])
        #expect(try await f.mail.message(id: message.id)?.messageId == "<child@test>")
        let messageID = message.id
        #expect(try await f.queue.read { try String.fetchAll($0, sql: "SELECT token FROM mail_thread_links WHERE messageID=? ORDER BY token", arguments: [messageID.uuidString]) } == ["child@test", "parent@test", "root@test"])
        let replacement = MailMessage(accountId: f.first.id, folderId: f.inbox.id, uid: message.uid, messageId: "<replacement@test>", references: "<different@test>")
        try await f.mail.upsertMessages([replacement])
        #expect(try await f.mail.message(id: message.id) == nil)
        #expect(try await f.queue.read { try String.fetchAll($0, sql: "SELECT token FROM mail_thread_links ORDER BY token") } == ["different@test", "replacement@test"])
        let raw = Data("References: <root@test>\r\n\t<parent@test>\r\nIn-Reply-To: <last@test>\r\n\r\nReferences: <body@test>".utf8)
        let parsed = MailFoundationAdapter.threadReferences(in: raw)
        #expect(Set(MailService.conversationTokens(own: nil, references: parsed)) == ["root@test", "parent@test", "last@test"])
        let many = (0..<200).map { "<\($0)@test>" }.joined(separator: " ")
        let tokens = MailService.conversationTokens(own: "<own@test>", references: many)
        #expect(tokens.count == 129 && tokens.contains("0@test") && tokens.contains("199@test") && tokens.contains("own@test") && !tokens.contains("1@test"))
        #expect(MailService.conversationTokens(own: "<bad id>", references: "garbage <bad id> <good@test>") == ["good@test"])
    }
}
