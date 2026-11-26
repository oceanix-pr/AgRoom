import Testing
import Foundation
import GRDB
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Mail list queries and selection")
struct MailListQueryTests {
    @Test func batchReconcilesRepeatedUIDsRelocationAndRollback() async throws {
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db)
        let mail = MailService(databaseQueue: db), account = sampleAccount()
        try await MailAccountService(databaseQueue: db, space: .work).save(account, password: nil)
        let folder = sampleFolder(accountId: account.id)
        try await mail.upsertFolders([folder])
        let original = sampleMessage(accountId: account.id, folderId: folder.id, uid: 1, date: Date())
        try await mail.upsertMessages([original])
        try await mail.saveBody(MailBody(messageId: original.id, textBody: "saved"))
        let attachment = MailAttachment(messageId: original.id, filename: "fixture.txt", mimeType: "text/plain", sizeBytes: 12)
        try await mail.saveAttachments([attachment])
        try await mail.setFlags(messageId: original.id, isRead: true, isStarred: true, pendingRemote: true)
        var moved = original; moved.id = UUID(); moved.uid = 2; moved.snippet = ""
        var second = moved; second.uid = 3
        for _ in 0..<2 { try await mail.upsertMessages([moved, second, second], expectedFolder: folder) }
        let rows = try await mail.messages(folderId: folder.id)
        try #require(rows.count == 1)
        #expect(rows[0].id == original.id && rows[0].uid == 3 && rows[0].isRead && rows[0].isStarred)
        #expect(try await mail.body(messageId: original.id)?.textBody == "saved")
        #expect(try await mail.attachments(messageId: original.id).first?.id == attachment.id)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mail_pending_flags") } == 1)
        var replacement = second; replacement.messageId = "<new@example.com>"; replacement.id = UUID()
        var collision = replacement; collision.uid = 4; collision.messageId = "<another@example.com>"
        await #expect(throws: (any Error).self) { try await mail.upsertMessages([replacement, collision]) }
        #expect(try await mail.body(messageId: original.id)?.textBody == "saved")
        try await mail.upsertMessages([replacement, replacement])
        #expect(try await mail.messages(folderId: folder.id).map(\.id) == [replacement.id])
        #expect(try await mail.body(messageId: original.id) == nil)
        #expect(try await mail.attachments(messageId: replacement.id).isEmpty)
    }

    @Test("Filtering precedes pagination, escapes wildcards, and remains inside the folder")
    func olderLocalResultsAndFilters() async throws {
        let queue = try makeMailDatabase(), account = sampleAccount()
        try await MailAccountService(databaseQueue: queue, space: .work).save(account, password: nil)
        let mail = MailService(databaseQueue: queue)
        let inbox = sampleFolder(accountId: account.id)
        let other = sampleFolder(accountId: account.id, path: "Archive")
        try await mail.upsertFolders([inbox, other])
        var messages = (1...450).map {
            sampleMessage(accountId: account.id, folderId: inbox.id, uid: UInt32($0), date: Date(timeIntervalSince1970: Double($0)))
        }
        for index in 0..<3 {
            messages[index].subject = "Budget 50%_\\ approved"
            messages[index].isStarred = true; messages[index].hasAttachments = true
        }
        messages[2].isRead = true
        var foreign = messages[0]; foreign.id = UUID(); foreign.folderId = other.id
        try await mail.upsertMessages(messages + [foreign])
        let filter = MailListFilter(query: "50%_\\", unreadOnly: true, starredOnly: true, attachmentsOnly: true,
                                    sender: "sender@", after: Date(timeIntervalSince1970: 1), before: Date(timeIntervalSince1970: 3))
        let page = try await mail.messages(folderId: inbox.id, before: nil, limit: 1, matching: filter)
        #expect(page.map(\.uid) == [2])
        let last = try #require(page.last)
        let next = try await mail.messages(folderId: inbox.id, before: .init(date: last.date, uid: last.uid), limit: 1, matching: filter)
        #expect(next.map(\.uid) == [1])
        #expect(Set(try await mail.messageIDs(folderId: inbox.id, matching: filter)) == Set(messages.prefix(2).map(\.id)))
        #expect(try await mail.messages(folderId: other.id, before: nil, matching: filter).map(\.id) == [foreign.id])
        #expect(try await mail.messages(folderId: inbox.id, before: nil, matching: .init(query: "50XYZ")).isEmpty)
    }

    @Test("Reply All uses Reply-To, deduplicates addresses and removes own recipients")
    func replyAllRecipients() {
        var message = sampleMessage(accountId: UUID(), folderId: UUID(), uid: 1, date: Date())
        message.replyTo = [.init(name: "Reply", address: "reply@example.com")]
        message.to = [.init(name: "Self", address: "USER@example.com"), .init(name: "Peer", address: "peer@example.com")]
        message.cc = [.init(name: "Duplicate", address: "PEER@example.com"), .init(name: "Other", address: "other@example.com")]
        let recipients = message.replyAllRecipients(excluding: ["user@example.com"])
        #expect(recipients.to.map(\.address) == ["reply@example.com", "peer@example.com"])
        #expect(recipients.cc.map(\.address) == ["other@example.com"])
    }

    @MainActor
    @Test("The mail UI searches beyond its first page and multi-selection never loads a body")
    func modelSearchAndSelection() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let account = sampleAccount(), folder = sampleFolder(accountId: account.id)
        try await MailAccountService(databaseQueue: queue, space: .work).save(account, password: nil)
        let mail = MailService(databaseQueue: queue)
        try await mail.upsertFolders([folder])
        let messages = (1...420).map {
            sampleMessage(accountId: account.id, folderId: folder.id, uid: UInt32($0), date: Date(timeIntervalSince1970: Double($0)))
        }
        try await mail.upsertMessages(messages)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = MailViewModel(hub: hub, space: .work)
        await model.loadIfNeeded()
        #expect(model.messages.count == 200)
        await model.updateListFilter(.init(query: "主题 1"))
        #expect(model.messages.contains { $0.uid == 1 })
        #expect(model.messages.allSatisfy { $0.subject.contains("主题 1") })
        let ids = Set(model.messages.prefix(2).map(\.id))
        model.setSelection(ids)
        await Task.yield()
        #expect(model.selectedMessageIDs == ids && model.selectedMessageId == nil && model.body == nil)
        let obsolete = Task { await model.updateListFilter(.init(query: "主题 2")) }
        await Task.yield()
        await model.updateListFilter(.init(query: "主题 3")); await obsolete.value
        #expect(model.messages.allSatisfy { $0.subject.contains("主题 3") })
        #expect(model.selectedMessageIDs.isEmpty)
        model.cancelPendingWork()
    }
}

// MARK: - Helpers

private func makeMailDatabase() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try queue.write { db in
        try MailService.createSchema(db)
    }
    return queue
}

private func sampleAccount(id: UUID = UUID(), name: String = "工作邮箱") -> MailAccount {
    MailAccount(
        id: id,
        displayName: name,
        emailAddress: "user@example.com",
        imapHost: "imap.example.com",
        imapPort: 993,
        imapSecurity: .tls,
        smtpHost: "smtp.example.com",
        smtpPort: 587,
        smtpSecurity: .startTLS,
        username: "user@example.com"
    )
}

private func sampleFolder(accountId: UUID, path: String = "INBOX", role: MailFolderRole = .inbox) -> MailFolder {
    MailFolder(accountId: accountId, path: path, name: path, role: role)
}

private func sampleMessage(accountId: UUID, folderId: UUID, uid: UInt32, date: Date, isRead: Bool = false) -> MailMessage {
    MailMessage(
        accountId: accountId,
        folderId: folderId,
        uid: uid,
        messageId: "<\(uid)@example.com>",
        subject: "主题 \(uid)",
        fromName: "发件人",
        fromAddress: "sender@example.com",
        to: [MailAddress(name: "收件人", address: "user@example.com")],
        date: date,
        isRead: isRead,
        sizeBytes: 1024,
        snippet: "摘要 \(uid)"
    )
}

// MARK: - Schema

@Suite("Mail schema")
struct MailSchemaTests {

    @Test("迁移幂等：重复建表不报错")
    func migrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try MailService.createSchema(db)
            try MailService.createSchema(db)
        }
    }

    @Test("六张业务表全部建立")
    func allTablesCreated() throws {
        let queue = try makeMailDatabase()
        let tables = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in ["mail_accounts", "mail_folders", "mail_messages", "mail_bodies", "mail_attachments", "mail_drafts"] {
            #expect(tables.contains(table), "missing table \(table)")
        }
    }
}

// MARK: - Accounts

@Suite("Mail accounts")
struct MailAccountServiceTests {

    @Test("账号往返：写入后可读回，字段一致")
    func roundTrip() async throws {
        let queue = try makeMailDatabase()
        let service = MailAccountService(databaseQueue: queue, space: .work)
        let account = sampleAccount()

        try await service.save(account, password: nil)
        let all = try await service.getAll()

        #expect(all.count == 1)
        let loaded = try #require(all.first)
        #expect(loaded.id == account.id)
        #expect(loaded.displayName == account.displayName)
        #expect(loaded.imapHost == account.imapHost)
        #expect(loaded.imapPort == 993)
        #expect(loaded.imapSecurity == .tls)
        #expect(loaded.smtpSecurity == .startTLS)
        #expect(loaded.username == account.username)
    }

    @Test("账号更新不重复插入")
    func updateInPlace() async throws {
        let queue = try makeMailDatabase()
        let service = MailAccountService(databaseQueue: queue, space: .work)
        var account = sampleAccount()

        try await service.save(account, password: nil)
        account.displayName = "改名后"
        try await service.save(account, password: nil)

        let all = try await service.getAll()
        #expect(all.count == 1)
        #expect(all.first?.displayName == "改名后")
    }

    @Test("删除账号级联清理文件夹与草稿")
    func deleteCascades() async throws {
        let queue = try makeMailDatabase()
        let accounts = MailAccountService(databaseQueue: queue, space: .work)
        let mail = MailService(databaseQueue: queue)
        let account = sampleAccount()
        try await accounts.save(account, password: nil)

        try await mail.upsertFolders([sampleFolder(accountId: account.id)])
        let folder = try #require(try await mail.folders(accountId: account.id).first)
        try await mail.upsertMessages([
            sampleMessage(accountId: account.id, folderId: folder.id, uid: 1, date: Date())
        ])
        try await mail.saveDraft(MailDraft(accountId: account.id, subject: "草稿"))

        try await accounts.delete(id: account.id)

        #expect(try await accounts.getAll().isEmpty)
        #expect(try await mail.folders(accountId: account.id).isEmpty)
        #expect(try await mail.messageCount(folderId: folder.id) == 0)
        #expect(try await mail.drafts(accountId: account.id).isEmpty)
    }
}

// MARK: - Folders & Messages

@Suite("Mail persistence")
struct MailPersistenceTests {

    @Test("文件夹按 (accountId, path) upsert 保留既有 id 与同步游标")
    func folderUpsertPreservesIDAndCursor() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()

        var folder = sampleFolder(accountId: accountId)
        try await mail.upsertFolders([folder])
        let firstID = try #require(try await mail.folders(accountId: accountId).first?.id)
        try await mail.updateFolderSync(folderId: firstID, uidValidity: 42, uidNext: 100, unread: 3, total: 10)

        // 再次 upsert 同 path（模拟重新发现文件夹）
        folder.name = "收件箱"
        try await mail.upsertFolders([folder])

        let folders = try await mail.folders(accountId: accountId)
        #expect(folders.count == 1)
        let stored = try #require(folders.first)
        #expect(stored.id == firstID)
        #expect(stored.name == "收件箱")
        #expect(stored.uidValidity == 42)
        #expect(stored.uidNext == 100)
        #expect(stored.unreadCount == 3)
    }

    @Test("文件夹层级字段随 upsert 更新，容器保留")
    func folderHierarchyColumnsRoundTrip() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()

        let container = MailFolder(
            accountId: accountId, path: "Groups", name: "Groups",
            parentPath: nil, delimiter: "/", isContainer: true
        )
        let child = MailFolder(
            accountId: accountId, path: "Groups/Work", name: "Work",
            parentPath: "Groups", delimiter: "/", isContainer: false
        )
        try await mail.upsertFolders([container, child])

        let folders = try await mail.folders(accountId: accountId)
        #expect(folders.count == 2)
        let storedContainer = try #require(folders.first { $0.path == "Groups" })
        #expect(storedContainer.isContainer == true)
        #expect(storedContainer.parentPath == nil)
        #expect(storedContainer.delimiter == "/")
        let storedChild = try #require(folders.first { $0.path == "Groups/Work" })
        #expect(storedChild.parentPath == "Groups")
        #expect(storedChild.isContainer == false)

        // 再次 upsert 更新层级
        var updatedChild = child
        updatedChild.parentPath = "Groups/New"
        try await mail.upsertFolders([updatedChild])
        let refreshed = try #require(try await mail.folders(accountId: accountId).first { $0.path == "Groups/Work" })
        #expect(refreshed.parentPath == "Groups/New")
    }

    @Test("邮件按 (folderId, uid) upsert，列表按日期倒序")
    func messageUpsertAndOrdering() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()
        try await mail.upsertFolders([sampleFolder(accountId: accountId)])
        let folderId = try #require(try await mail.folders(accountId: accountId).first?.id)

        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        try await mail.upsertMessages([
            sampleMessage(accountId: accountId, folderId: folderId, uid: 1, date: earlier),
            sampleMessage(accountId: accountId, folderId: folderId, uid: 2, date: later)
        ])

        let messages = try await mail.messages(folderId: folderId)
        #expect(messages.map(\.uid) == [2, 1])
        #expect(try await mail.maxUID(folderId: folderId) == 2)
    }

    @Test("重复 upsert 同 UID 不产生重复行并保留本地读取状态")
    func messageUpsertKeepsLocalFlags() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()
        try await mail.upsertFolders([sampleFolder(accountId: accountId)])
        let folderId = try #require(try await mail.folders(accountId: accountId).first?.id)

        let message = sampleMessage(accountId: accountId, folderId: folderId, uid: 7, date: Date())
        try await mail.upsertMessages([message])
        let stored = try #require(try await mail.messages(folderId: folderId).first)
        try await mail.setFlags(messageId: stored.id, isRead: true, isStarred: true)

        // 再次同步同 UID（服务端仍为未读）
        try await mail.upsertMessages([message])

        let messages = try await mail.messages(folderId: folderId)
        #expect(messages.count == 1)
        let refreshed = try #require(messages.first)
        #expect(refreshed.id == stored.id)
        #expect(refreshed.isRead)
        #expect(refreshed.isStarred)
    }

    @Test("正文与附件按 messageId 往返")
    func bodyAndAttachmentsRoundTrip() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()
        try await mail.upsertFolders([sampleFolder(accountId: accountId)])
        let folderId = try #require(try await mail.folders(accountId: accountId).first?.id)
        try await mail.upsertMessages([
            sampleMessage(accountId: accountId, folderId: folderId, uid: 1, date: Date())
        ])
        let messageId = try #require(try await mail.messages(folderId: folderId).first?.id)

        try await mail.saveBody(MailBody(messageId: messageId, textBody: "正文", htmlBody: "<p>正文</p>"))
        try await mail.saveAttachments([
            MailAttachment(messageId: messageId, filename: "a.pdf", mimeType: "application/pdf", sizeBytes: 10)
        ])
        try await mail.setBodyState(messageId: messageId, state: .ready)

        let body = try #require(try await mail.body(messageId: messageId))
        #expect(body.textBody == "正文")
        #expect(body.htmlBody == "<p>正文</p>")
        let attachments = try await mail.attachments(messageId: messageId)
        #expect(attachments.count == 1)
        #expect(attachments.first?.filename == "a.pdf")
        #expect(try await mail.message(id: messageId)?.bodyState == .ready)
    }

    @Test("清理文件夹保留 paths 之外的删除")
    func deleteFoldersKeepingPaths() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()
        try await mail.upsertFolders([
            sampleFolder(accountId: accountId, path: "INBOX"),
            sampleFolder(accountId: accountId, path: "OldFolder", role: .other)
        ])

        try await mail.deleteFolders(accountId: accountId, keeping: ["INBOX"])

        let folders = try await mail.folders(accountId: accountId)
        #expect(folders.map(\.path) == ["INBOX"])
    }

    @Test("草稿往返与删除")
    func draftRoundTrip() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()
        let draft = MailDraft(
            accountId: accountId,
            to: [MailAddress(name: "收件人", address: "to@example.com")],
            subject: "草稿主题",
            bodyText: "草稿正文"
        )

        try await mail.saveDraft(draft)
        var drafts = try await mail.drafts(accountId: accountId)
        #expect(drafts.count == 1)
        #expect(drafts.first?.to.first?.address == "to@example.com")
        #expect(drafts.first?.subject == "草稿主题")

        try await mail.deleteDraft(id: draft.id)
        drafts = try await mail.drafts(accountId: accountId)
        #expect(drafts.isEmpty)
    }

    @Test("游标分页按 (date, uid) 稳定续页，不重复也不漏")
    func messagesCursorPagination() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()
        try await mail.upsertFolders([sampleFolder(accountId: accountId)])
        let folderId = try #require(try await mail.folders(accountId: accountId).first?.id)

        // 5 封不同日期：uid 5 最新
        try await mail.upsertMessages((1...5).map {
            sampleMessage(
                accountId: accountId,
                folderId: folderId,
                uid: UInt32($0),
                date: Date(timeIntervalSince1970: Double($0))
            )
        })

        var collected: [UInt32] = []
        var cursor: MailService.MailPageCursor?
        for _ in 0..<4 {
            let page = try await mail.messages(folderId: folderId, before: cursor, limit: 2)
            collected.append(contentsOf: page.map(\.uid))
            guard let last = page.last else { break }
            cursor = MailService.MailPageCursor(date: last.date, uid: last.uid)
        }

        // 逐页取完且顺序与整表一致（无不重复、无遗漏）
        #expect(collected == [5, 4, 3, 2, 1])
        #expect(try await mail.messages(folderId: folderId).map(\.uid) == [5, 4, 3, 2, 1])
    }

    @Test("检索把 % 与 _ 当字面量，不当作 LIKE 通配符")
    func searchEscapesWildcards() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()
        try await mail.upsertFolders([sampleFolder(accountId: accountId)])
        let folderId = try #require(try await mail.folders(accountId: accountId).first?.id)

        var percent = sampleMessage(accountId: accountId, folderId: folderId, uid: 1, date: Date(timeIntervalSince1970: 1))
        percent.subject = "折扣 50% 起"
        var plain = sampleMessage(accountId: accountId, folderId: folderId, uid: 2, date: Date(timeIntervalSince1970: 2))
        plain.subject = "折扣 500 起"
        var underscore = sampleMessage(accountId: accountId, folderId: folderId, uid: 3, date: Date(timeIntervalSince1970: 3))
        underscore.subject = "a_b"
        var plainText = sampleMessage(accountId: accountId, folderId: folderId, uid: 4, date: Date(timeIntervalSince1970: 4))
        plainText.subject = "axb"
        try await mail.upsertMessages([percent, plain, underscore, plainText])

        // 未转义时 `50%` 的模式 `%50%%` 会命中「折扣 500 起」
        let percentHits = try await mail.searchMessages(accountId: accountId, query: "50%")
        #expect(percentHits.map(\.uid) == [1])
        // 未转义时 `a_b` 的模式 `%a_b%` 会命中「axb」
        let underscoreHits = try await mail.searchMessages(accountId: accountId, query: "a_b")
        #expect(underscoreHits.map(\.uid) == [3])
    }

    @Test("正文缓存超限按最久未取淘汰，并把被淘汰邮件置回未下载")
    func bodyCacheTrimEvictsOldest() async throws {
        let queue = try makeMailDatabase()
        let mail = MailService(databaseQueue: queue)
        let accountId = UUID()
        try await mail.upsertFolders([sampleFolder(accountId: accountId)])
        let folderId = try #require(try await mail.folders(accountId: accountId).first?.id)

        try await mail.upsertMessages((1...3).map {
            sampleMessage(
                accountId: accountId,
                folderId: folderId,
                uid: UInt32($0),
                date: Date(timeIntervalSince1970: Double($0))
            )
        })
        let idByUID = Dictionary(
            uniqueKeysWithValues: try await mail.messages(folderId: folderId).map { ($0.uid, $0.id) }
        )
        let body = String(repeating: "x", count: 100)
        for uid in 1...3 {
            let messageId = try #require(idByUID[UInt32(uid)])
            // fetchedAt 按 uid 递增：uid1 最旧、uid3 最新
            try await mail.saveBody(MailBody(
                messageId: messageId,
                textBody: body,
                fetchedAt: Date(timeIntervalSince1970: Double(uid))
            ))
            try await mail.setBodyState(messageId: messageId, state: .ready)
        }

        // 生产上限为 64 MiB；这里用注入上限触发同一裁剪实现
        try await queue.write { db in
            try MailService.trimBodyCache(in: db, maxBytes: 150)
        }

        // 纯文本直接检索原列，不重复保存；300 字节淘汰 uid1、uid2，剩 uid3 的 100 字节。
        let evicted = try #require(idByUID[1])
        #expect(try await mail.body(messageId: evicted) == nil)
        // 显式写 `MailBodyState.none`：`.none` 在可选左值旁会被解析成 `Optional.none`
        #expect(try await mail.message(id: evicted)?.bodyState == MailBodyState.none)
        let kept = try #require(idByUID[3])
        #expect(try await mail.body(messageId: kept) != nil)
        #expect(try await mail.message(id: kept)?.bodyState == .ready)
        let keptCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_bodies")
        }
        #expect(keptCount == 1)
    }
}

// MARK: - Model Helpers

@Suite("Mail model helpers")
struct MailModelTests {

    @Test("空主题与空发件人名称的展示回落")
    func displayFallbacks() {
        let message = MailMessage(accountId: UUID(), folderId: UUID(), uid: 1, subject: "", fromAddress: "a@b.com")
        #expect(message.displaySubject == "(no subject)")
        #expect(message.displayFrom == "a@b.com")
    }

    @Test("地址展示：有名称时含角括号，无名称仅地址")
    func addressDisplay() {
        #expect(MailAddress(name: "张三", address: "z@example.com").display == "张三 <z@example.com>")
        #expect(MailAddress(name: "", address: "z@example.com").display == "z@example.com")
    }
}
