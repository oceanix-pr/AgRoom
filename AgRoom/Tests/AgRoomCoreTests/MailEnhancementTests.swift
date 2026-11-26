import AppKit
import CryptoKit
import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Mail enhancement boundaries")
struct MailEnhancementTests {
    private func database() throws -> (DatabaseQueue, MailService) {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        return (queue, MailService(databaseQueue: queue))
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-enhancements-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func original(_ name: String) -> Data {
        Data("Message-ID: <\(name)@example.test>\r\nFrom: sender@example.test\r\nSubject: \(name)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nOwned \(name)\r\n".utf8)
    }
    private var archiveDraft: MailImportArchiveDraft { .init(name: "Synthetic archive", inbox: "Inbox", trash: "Trash", archive: "Archive") }

    @Test("Reselected sources resume the same batch and item identities, exclude new mail, and fence stale claims")
    func resumeIndexedBatch() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<3).map { index -> URL in
            let url = root.appendingPathComponent("\(index).eml"); try original("source-\(index)").write(to: url); return url
        }
        let input = try await MailImportReader.index(urls), (_, mail) = try database()
        let mapping = try await mail.reviewImportMapping(input, archiveID: nil, draft: archiveDraft, rules: [:])
        let partial = try await mail.importMappedMessages(input, review: mapping) { done, _ in if done == 1 { await input.access.close() } }
        #expect(partial.results.map(\.status) == [.imported, .failed, .failed])
        let extra = root.appendingPathComponent("extra.eml"); try original("extra").write(to: extra)
        let fresh = try await MailImportReader.index(urls + [extra])
        let review = try await mail.previewImportResume(batchID: partial.id, archiveID: partial.accountID, source: fresh)
        #expect(review.items.map(\.status) == [.finished, .matched, .matched] && review.resumableCount == 2)
        let result = try await mail.resumeImport(review)
        #expect(result.id == partial.id && result.results.map(\.id) == partial.results.map(\.id))
        #expect(result.results.allSatisfy { $0.status == .imported })
        #expect(try await mail.messageCount(in: .space) == 3)
        #expect(try await mail.importBatches(archiveID: partial.accountID).count == 1)
        await #expect(throws: MailImportError.changed) { try await mail.resumeImport(review) }
        await fresh.access.close()
    }

    @Test("Missing and changed reselected originals cannot resume")
    func changedResumeSources() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.eml"), second = root.appendingPathComponent("second.eml")
        try original("first").write(to: first); try original("second").write(to: second)
        let input = try await MailImportReader.index([first, second]), (_, mail) = try database()
        let mapping = try await mail.reviewImportMapping(input, archiveID: nil, draft: archiveDraft, rules: [:])
        let batch = try await mail.importMappedMessages(input, review: mapping) { done, _ in if done == 1 { await input.access.close() } }
        try original("changed").write(to: second)
        let changed = try await MailImportReader.index([first, second])
        let review = try await mail.previewImportResume(batchID: batch.id, archiveID: batch.accountID, source: changed)
        #expect(review.items.map(\.status) == [.finished, .changed] && !review.canResume)
        await #expect(throws: MailImportError.changed) { try await mail.resumeImport(review) }
        let missing = try await MailImportReader.index([first])
        let absent = try await mail.previewImportResume(batchID: batch.id, archiveID: batch.accountID, source: missing)
        #expect(absent.items.map(\.status) == [.finished, .missing])
        await changed.access.close(); await missing.access.close()
    }

    @Test("Archive bundles preserve exact originals and binary attachments, and render only escaped offline text")
    func offlineBundle() throws {
        let attachment = MailDraftAttachment(filename: "<unsafe>#?.bin", mimeType: "application/octet-stream", data: Data([0, 255, 10, 13, 128]))
        let bytes = try MailSmtpAdapter.serializedMessage(.init(from: .init(name: "<Sender>", address: "sender@example.test"),
            to: [], subject: "<script>bad()</script>", bodyText: "Plain <img src=x onerror=bad()> & body", attachments: [attachment]), date: Date())
        let message = MailMessage(accountId: UUID(), folderId: UUID(), uid: 1)
        let labels = MailArchiveLabels(title: "Archive", original: "Original", attachments: "Attachments", from: "From", to: "To", date: "Date", emptyBody: "Empty", generated: "Generated")
        let bundle = try MailArchiveBundle.build(raw: .init(data: bytes, kind: .generated), message: message, labels: labels)
        #expect(bundle.files.first(where: { $0.components == ["message.eml"] })?.data == bytes)
        let binary = try #require(bundle.files.first { $0.components.first == "attachments" })
        #expect(binary.data == attachment.data && binary.components.count == 2 && !binary.components.last!.contains("/"))
        let html = String(decoding: try #require(bundle.files.last?.data), as: UTF8.self)
        #expect(html.contains("default-src 'none'") && html.contains("&lt;script&gt;bad()&lt;/script&gt;"))
        #expect(!html.contains("<script>bad()") && !html.contains("<img src=x"))
        let manifest = try #require(bundle.files.first { $0.components == ["manifest.json"] })
        let object = try #require(try JSONSerialization.jsonObject(with: manifest.data) as? [String: Any])
        #expect(object["originalSHA256"] as? String == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let index = try MailArchiveBundle.index(title: "<Title>", rows: [("<Unsafe>", ["a #", "index.html"], nil), ("Failed", nil, "<error>")])
        let text = String(decoding: index, as: UTF8.self)
        #expect(text.contains("a%20%23/index.html") && text.contains("&lt;error&gt;") && !text.contains("<Unsafe>"))
    }

    @Test("Undo claims are tied to one database, skip later edits, and cannot be applied twice")
    func operationUndo() async throws {
        let (queue, mail) = try database()
        let account = try await mail.createLocalArchive(name: "Undo archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let inbox = try #require(try await mail.folders(accountId: account.id).first { $0.role == .inbox })
        let messages = (0..<2).map { MailMessage(accountId: account.id, folderId: inbox.id, uid: MailService.localUIDFloor + UInt32($0), subject: "Undo \($0)") }
        try await mail.upsertMessages(messages)
        let sync = MailSyncService(accountService: MailAccountService(databaseQueue: queue, space: .work), mail: mail, space: .work,
            coordinator: MailAccountCoordinator(), clientFactory: { _ in MockMailClient() }, passwordProvider: { _ in nil })
        let result = await sync.applyBatch(messageIDs: messages.map(\.id), action: .read(true))
        let receipt = try #require(result.undoReceipt)
        #expect(receipt.count == 2 && result.failures.isEmpty)
        try await mail.setFlags(messageId: messages[1].id, isRead: false, pendingRemote: false)
        let review = try await mail.previewOperationUndo(receipt)
        #expect(review.count == 1 && review.skipped == 1)
        let (_, other) = try database()
        await #expect(throws: MailMoveReviewError.changed) { try await other.previewOperationUndo(receipt) }
        let undone = await sync.undoBatch(review)
        #expect(undone.succeeded == [messages[0].id] && undone.undoReceipt == nil)
        #expect(try await mail.message(id: messages[0].id)?.isRead == false)
        #expect(try await mail.previewOperationUndo(receipt).count == 0)
        let again = await sync.undoBatch(review)
        #expect(again.succeeded.isEmpty)
    }

    @Test("Every supported sort paginates raw sort values without duplicates, omissions or null-date loops")
    func sortedPagination() async throws {
        let (queue, mail) = try database()
        let account = try await mail.createLocalArchive(name: "Sorted archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let folder = try #require(try await mail.folders(accountId: account.id).first { $0.role == .inbox })
        let subjects = ["Zulu", "alpha", "Alpha", "=?UTF-8?B?5Lit5paH?=", "", "alpha", "Bravo"]
        let messages = subjects.enumerated().map { offset, value in
            MailMessage(accountId: account.id, folderId: folder.id, uid: MailService.localUIDFloor + UInt32(offset), subject: value,
                fromName: offset.isMultiple(of: 2) ? "Sender" : "sender", fromAddress: "\(offset)@example.test", date: offset < 2 ? nil : Date(timeIntervalSince1970: Double(offset % 3)))
        }
        try await mail.upsertMessages(messages)
        for order in MailListOrder.allCases {
            let whole = try await mail.messagePage(in: .folder(folder.id), before: nil, limit: 100, order: order)
            var cursor: MailService.MailPageCursor?, ids: [UUID] = []
            for _ in 0..<10 {
                let page = try await mail.messagePage(in: .folder(folder.id), before: cursor, limit: 2, order: order)
                ids += page.messages.map(\.id)
                guard let next = page.cursor else { break }; cursor = next
            }
            #expect(ids == whole.messages.map(\.id) && ids.count == Set(ids).count && ids.count == messages.count)
        }
        #expect(try await queue.read { try MailMessageRow.fetchCount($0) } == messages.count)
    }

    @Test("References preserve local moves, reject replacement and another space, and expose no mail content")
    func sourceReferences() async throws {
        let (_, mail) = try database()
        let account = try await mail.createLocalArchive(name: "Reference archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let folders = try await mail.folders(accountId: account.id)
        let inbox = try #require(folders.first { $0.role == .inbox }), archive = try #require(folders.first { $0.role == .archive })
        var message = MailMessage(accountId: account.id, folderId: inbox.id, uid: MailService.localUIDFloor, messageId: "<reference@test>", subject: "Private secret subject", fromAddress: "private@example.test")
        try await mail.upsertMessages([message])
        let reference = MailSourceReference(message: message, space: .work)
        #expect(try MailSourceReference(url: reference.url) == reference)
        #expect(!reference.url.absoluteString.contains("Private") && !reference.url.absoluteString.contains("private@"))
        await #expect(throws: MailSourceReferenceError.differentSpace) { try await mail.resolveSourceReference(reference, in: .personal) }
        try await mail.moveMessage(id: message.id, toFolderId: archive.id, uid: message.uid)
        #expect(try await mail.resolveSourceReference(reference, in: .work).folderId == archive.id)
        message.folderId = archive.id; message.subject = "Replaced content"
        try await mail.upsertMessages([message])
        await #expect(throws: MailSourceReferenceError.missing) { try await mail.resolveSourceReference(reference, in: .work) }
        for text in [reference.url.absoluteString + "&v1=bad", reference.url.absoluteString + "#fragment", "agroom-mail://other/abc"] {
            #expect(throws: MailSourceReferenceError.invalid) { try MailSourceReference(url: URL(string: text)!) }
        }
    }

    @MainActor @Test("Finder publication uses exact bytes, refuses collisions and changed sources, and closes terminally")
    func finderPublication() async throws {
        let (queue, mail) = try database()
        let account = try await mail.createLocalArchive(name: "Drag archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let inbox = try #require(try await mail.folders(accountId: account.id).first { $0.role == .inbox })
        let message = MailMessage(accountId: account.id, folderId: inbox.id, uid: MailService.localUIDFloor,
            messageId: "<drag@example.test>", subject: "Drag")
        try await mail.upsertMessages([message])
        let bytes = original("drag")
        try await mail.saveRawMessage(id: message.id, raw: .init(data: bytes, kind: .imported))
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = MailFinderDragModel(message: message, hub: hub, space: .work)
        model.prepare()
        for _ in 0..<500 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.error == nil && model.raw?.data == bytes)
        let review = try #require(model.review), root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(model.filename)
        try await model.write(bytes, review: review, to: url)
        #expect(try Data(contentsOf: url) == bytes)
        await #expect(throws: (any Error).self) { try await model.write(Data("replacement".utf8), review: review, to: url) }
        #expect(try Data(contentsOf: url) == bytes)
        try await mail.deleteMessage(id: message.id)
        let other = root.appendingPathComponent("changed.eml")
        await #expect(throws: MailExportError.changed) { try await model.write(bytes, review: review, to: other) }
        #expect(!FileManager.default.fileExists(atPath: other.path))
        model.close(); model.prepare(); #expect(!model.busy && model.raw == nil)
    }

    @Test("Folder subtree export follows actual parent identity and excludes similar prefixes and other accounts")
    func subtreeExport() async throws {
        let (_, mail) = try database()
        let owner = try await mail.createLocalArchive(name: "Tree archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let other = try await mail.createLocalArchive(name: "Other archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let root = MailFolder(accountId: owner.id, path: "Projects", name: "Projects")
        let child = MailFolder(accountId: owner.id, path: "Projects/Child", name: "Child", parentPath: root.path, delimiter: "/")
        let similar = MailFolder(accountId: owner.id, path: "Projects-old", name: "Projects-old")
        let foreign = MailFolder(accountId: other.id, path: "Projects/Child", name: "Child", parentPath: root.path, delimiter: "/")
        try await mail.upsertFolders([root, child, similar, foreign])
        let messages = [root, child, similar, foreign].map { MailMessage(accountId: $0.accountId, folderId: $0.id, uid: MailService.localUIDFloor, subject: $0.path) }
        try await mail.upsertMessages(messages)
        #expect(Set(try await mail.messageIDs(folderId: root.id)) == [messages[0].id])
        #expect(Set(try await mail.messageIDs(folderId: root.id, includingDescendants: true)) == Set(messages.prefix(2).map(\.id)))
    }

    @MainActor @Test("Default signatures apply once only to unsaved empty drafts; stale previews and undo preserve manual edits")
    func composePresets() async throws {
        let (queue, mail) = try database()
        let account = MailAccount(displayName: "Synthetic", emailAddress: "sender@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "sender@example.test")
        try await queue.write { db in var row = MailAccountRow(from: account); try row.insert(db) }
        let signature = MailComposePreset(kind: .signature, name: "Default", body: "User signature")
        let reply = MailComposePreset(kind: .reply, name: "Thanks", body: "Thank you.")
        var values = MailComposePresets(); values.items = [signature, reply]; values.defaultSignatures[account.id.uuidString] = signature.id
        _ = try await mail.saveComposePresets(values, replacing: .init())
        await #expect(throws: MailComposePresetError.changed) { try await mail.saveComposePresets(.init(), replacing: .init()) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let draft = MailDraft(accountId: account.id, quotedText: "> Original quote")
        let model = MailComposeViewModel(draft: draft, space: .work, hub: hub, fromDescription: account.emailAddress, isAIPanelVisible: false)
        await model.loadComposePresets(applyDefault: true)
        #expect(model.bodyText == "\n\n-- \nUser signature" && model.quotedText == draft.quotedText)
        await model.loadComposePresets(applyDefault: true)
        #expect(model.bodyText.components(separatedBy: "User signature").count == 2)
        model.previewPreset(reply)
        let preview = try #require(model.presetPreview)
        model.applyPreset(preview, replacing: false)
        #expect(model.bodyText == "Thank you.\n\n-- \nUser signature" && model.canUndoPreset)
        model.undoPreset(); #expect(model.bodyText == "\n\n-- \nUser signature")
        model.previewPreset(reply); let stale = try #require(model.presetPreview)
        model.bodyText = "Manual edit"; model.applyPreset(stale, replacing: true)
        #expect(model.bodyText == "Manual edit" && model.presetStatus != nil && !model.canUndoPreset)
        var saved = draft; saved.id = UUID()
        try await mail.saveEditableDraft(saved)
        let reopened = MailComposeViewModel(draft: saved, space: .work, hub: hub, fromDescription: account.emailAddress, isAIPanelVisible: false)
        await reopened.loadComposePresets(applyDefault: true); #expect(reopened.bodyText.isEmpty)
        model.onWindowClosed(); reopened.onWindowClosed()
        let otherQueue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(otherQueue)
        #expect(try await MailService(databaseQueue: otherQueue).composePresets().items.isEmpty)
    }

    @MainActor @Test("Import reads a selected server message, preserves quoted boundaries and only saves the selected signature")
    func importSignature() async throws {
        let (queue, mail) = try database()
        let owners = MailAccountService(databaseQueue: queue, space: .work)
        let account = MailAccount(displayName: "Team", emailAddress: "team@example.test", imapHost: "imap.example.test",
                                  smtpHost: "smtp.example.test", username: "team")
        try await owners.save(account, password: nil)
        let sent = RemoteMailFolder(path: "Sent", name: "Sent", role: .sent)
        let summary = RemoteMessageSummary(uid: 70_000, messageId: nil, subject: "Project", from: [], to: [], cc: [],
                                           date: nil, isRead: false, isStarred: false, sizeBytes: 200, snippet: "")
        let body = RemoteMessageBody(textBody: "Private text\r\n-- \r\nTeam 🪴\r\nSupport\r\n\r\nOn Monday someone wrote:\r\n> -- \r\n> Not ours",
                                     htmlBody: nil, attachments: [])
        let mock = MockMailClient(folders: [sent, .init(path: "INBOX", name: "Inbox", role: .inbox)],
            statuses: ["Sent": .init(uidValidity: 4, uidNext: 70_001, messageCount: 1, unreadCount: 1)],
            summaries: ["Sent": [summary]], bodies: [summary.uid: body])
        let sync = MailSyncService(accountService: owners, mail: mail, space: .work, clientFactory: { _ in mock }, passwordProvider: { _ in "fixture" })
        #expect(try await sync.signatureFolders(account: account) == [sent])
        let source = try #require(try await sync.signatureSources(account: account, folder: sent).first)
        #expect(source.subject == summary.subject && source.id == summary.uid)
        #expect(await mock.bodyFetchCount == 0)
        let preview = try await sync.signaturePreview(from: source)
        let signature = (preview.text as NSString).substring(with: try #require(preview.suggestedRange))
        #expect(signature == "Team 🪴\nSupport")
        #expect(await mock.flagCalls.isEmpty)
        #expect(await mock.draftAppendCount == 0)
        let manager = MailComposePresetManager(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work,
                                               importAccountID: account.id)
        await manager.load(openImport: true)
        manager.editImportedSignature(signature, account: account)
        #expect(try await mail.composePresets().items.isEmpty && manager.useImportedAsDefault)
        await manager.saveEditor()
        #expect(try await mail.composePresets().defaultSignature(accountID: account.id)?.body == signature)
        manager.close()
        await mock.configure(statuses: ["Sent": .init(uidValidity: 5, uidNext: 70_001, messageCount: 1, unreadCount: 1)])
        await #expect(throws: MailSignatureImportError.changed) { try await sync.signaturePreview(from: source) }
        let (otherQueue, otherMail) = try database()
        let other = MailSyncService(accountService: .init(databaseQueue: otherQueue, space: .personal), mail: otherMail, space: .personal)
        await #expect(throws: MailSignatureImportError.changed) { try await other.signaturePreview(from: source) }
        let unmarked = try MailSignaturePreview(body: .init(textBody: "", htmlBody: "<div>业务</div><div>本人签名<br>支持团队</div>", attachments: []))
        #expect(unmarked.suggestedRange == nil && unmarked.text.contains("本人签名\n支持团队"))
        let quoted = try MailSignaturePreview(body: .init(textBody: "Hello\n> -- \n> Someone else", htmlBody: nil, attachments: []))
        #expect(quoted.suggestedRange == nil)
    }
}
