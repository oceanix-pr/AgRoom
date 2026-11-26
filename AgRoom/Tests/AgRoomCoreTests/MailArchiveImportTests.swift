import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Local mail archive imports")
struct MailArchiveImportTests {
    private actor UndoReview {
        var value: MailImportUndoPlan?
        func set(_ value: MailImportUndoPlan) { self.value = value }
    }
    private struct Fixture {
        let queue: DatabaseQueue
        let mail: MailService
        let accounts: MailAccountService
        let archive: MailAccount
        let root: URL
        let client: MockMailClient
        let sync: MailSyncService
    }
    private func fixture() async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue), accounts = MailAccountService(databaseQueue: queue, space: .work)
        let archive = try await mail.createLocalArchive(name: "Imported fixtures", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let client = MockMailClient()
        let sync = MailSyncService(accountService: accounts, mail: mail, space: .work, attachmentDirectory: root.appendingPathComponent("cache"),
            clientFactory: { _ in client }, passwordProvider: { _ in "unused" })
        return .init(queue: queue, mail: mail, accounts: accounts, archive: archive, root: root, client: client, sync: sync)
    }
    private func eml(_ body: String = "Body", subject: String = "Import fixture", attachment: Bool = false) throws -> Data {
        try MailSmtpAdapter.serializedMessage(.init(from: .init(name: "Synthetic", address: "from@example.test"),
            to: [.init(name: "Peer", address: "to@example.test")], subject: subject, bodyText: body,
            messageId: "<same-id@example.test>", attachments: attachment ? [.init(filename: "测试.bin", mimeType: "application/octet-stream", data: Data([0, 255, 1, 2]))] : []),
            date: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func preview(_ f: Fixture, data: [Data]) throws -> MailImportPreview {
        let files = try data.enumerated().map { index, bytes in
            let file = f.root.appendingPathComponent("fixture-\(index).eml"); try bytes.write(to: file); return file
        }
        return try MailImportReader.read(files)
    }

    @Test("Preview is read-only; exact-content duplicates are skipped while same Message-ID variants survive")
    func dedupAndIsolation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try eml(), second = try eml("Different body")
        let input = try preview(f, data: [first, first, second])
        let checked = try await f.mail.importPreview(input, archiveID: f.archive.id)
        #expect(checked.duplicates.count == 1)
        #expect(try await f.mail.importBatches(archiveID: f.archive.id).isEmpty)
        let batch = try await f.mail.importMessages(checked, archiveID: f.archive.id)
        #expect(batch.results.filter { $0.status == .imported }.count == 2)
        #expect(batch.results.filter { $0.status == .duplicate }.count == 1)
        let messageID = try #require(batch.results.first?.messageID)
        #expect(try await f.mail.rawMessage(id: messageID)?.data == first)
        #expect(try await f.mail.rawMessage(id: messageID)?.kind == .imported)
        #expect(try await f.mail.importPreview(input, archiveID: f.archive.id).duplicates.count == 3)
        #expect(try await f.mail.importPreview(checked, archiveID: nil).duplicates.count == 1)
        let other = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(other)
        let personal = MailService(databaseQueue: other)
        #expect(try await personal.rawMessage(id: messageID) == nil)
        await #expect(throws: MailImportError.self) { try await personal.importMessages(input, archiveID: f.archive.id) }
    }

    @Test("Archive attachments and evicted bodies reopen without a server, and archive writes remain local")
    func offlineAndSyncGuards() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let input = try preview(f, data: [eml(attachment: true)])
        let batch = try await f.mail.importMessages(input, archiveID: f.archive.id)
        let id = try #require(batch.results.first?.messageID)
        let part = try #require(try await f.mail.attachments(messageId: id).first)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("fixture-0.eml"))
        let saved = try await f.sync.downloadAttachment(messageId: id, attachmentID: part.id)
        #expect(try Data(contentsOf: saved) == Data([0, 255, 1, 2]))
        try await f.queue.write { db in try db.execute(sql: "DELETE FROM mail_bodies WHERE messageId=?", arguments: [id.uuidString]) }
        #expect(try await f.sync.loadBody(messageId: id).textBody?.contains("Body") == true)
        let folders = try await f.mail.folders(accountId: f.archive.id)
        let inbox = try #require(folders.first { $0.role == .inbox }), trash = try #require(folders.first { $0.role == .trash })
        await #expect(throws: MailImportError.self) { try await f.sync.syncAccount(accountId: f.archive.id) }
        await #expect(throws: MailImportError.self) { try await f.mail.clearMessages(folderId: inbox.id) }
        await #expect(throws: MailImportError.self) { try await f.mail.deleteFolders(accountId: f.archive.id, keeping: []) }
        await #expect(throws: MailImportError.self) { try await f.accounts.save(f.archive, password: "must-not-persist") }
        let tools = MailToolFactory.build(accountService: f.accounts, mailService: f.mail, syncService: f.sync)
        let list = try #require(tools.first { $0.definition.name == "mail_accounts_list" })
        #expect(try await list.execute(argumentsJSON: "{}").contains("local archive; offline; cannot send"))
        let json = "{\"accountId\":\"\(f.archive.id.uuidString)\",\"to\":\"peer@example.test\",\"subject\":\"Fixture\",\"body\":\"Body\"}"
        let draftTool = try #require(tools.first { $0.definition.name == "mail_save_draft" })
        await #expect(throws: LLMError.self) { try await draftTool.execute(argumentsJSON: json) }
        let sendTool = try #require(tools.first { $0.definition.name == "mail_send" })
        await #expect(throws: ToolExecutionFailure.self) { try await sendTool.execute(argumentsJSON: json) }
        #expect(try await f.mail.drafts(accountId: f.archive.id).isEmpty)
        #expect(try await f.mail.message(id: id) != nil)
        #expect(inbox.totalCount == 1 && inbox.unreadCount == 1)
        try await f.sync.setRead(messageId: id, isRead: true)
        try await f.sync.moveMessage(messageId: id, toFolderId: trash.id)
        #expect(try await f.mail.message(id: id)?.folderId == trash.id)
        try await f.sync.deleteMessage(messageId: id)
        #expect(try await f.mail.message(id: id) == nil)
        #expect(await f.client.connectCount == 0)
    }

    @Test("Directory imports preserve hierarchy and reject symbolic and hard linked source files")
    func foldersAndUnsafeFiles() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let selected = f.root.appendingPathComponent("Customers/2026")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let original = selected.appendingPathComponent("mail.eml"); try eml().write(to: original)
        try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("link.eml"), withDestinationURL: original)
        let input = try MailImportReader.read([f.root.appendingPathComponent("Customers")])
        #expect(input.candidates.count == 1 && input.failures.count == 1)
        let batch = try await f.mail.importMessages(input, archiveID: f.archive.id)
        let messageID = try #require(batch.results.first?.messageID)
        let message = try #require(try await f.mail.message(id: messageID))
        let folders = try await f.mail.folders(accountId: f.archive.id)
        #expect(folders.first { $0.id == message.folderId }?.path == "import/Customers/2026")
        #expect(folders.first { $0.path == "import/Customers/2026" }?.parentPath == "import/Customers")
        try FileManager.default.linkItem(at: original, to: selected.appendingPathComponent("hard.eml"))
        let rejected = try MailImportReader.read([original])
        #expect(rejected.candidates.isEmpty && rejected.failures.count == 1)
    }

    @Test("MBOX separates records and reverses one mboxrd escape without reparsing the original bytes")
    func mboxRecords() throws {
        let raw = Data("From: sender@example.test\nSubject: One\n\n>From original\n>>From quoted\nEnd\n\nFrom sender@example.test Tue Nov 14 22:13:20 2023\nSubject: Two\n\nSecond\n\n".utf8)
        let mbox = Data("From sender@example.test Tue Nov 14 22:13:20 2023\n".utf8) + raw
        var records: [Data] = []
        try MailMboxCodec.decode(mbox) { _, data in records.append(data) }
        #expect(records.count == 2)
        #expect(String(decoding: records[0], as: UTF8.self).contains("\nFrom original\n>From quoted\nEnd\n"))
        #expect(String(decoding: records[1], as: UTF8.self) == "Subject: Two\n\nSecond\n")
        #expect(throws: MailImportError.self) { try MailMboxCodec.decode(Data("Not mbox".utf8)) { _, _ in } }
        #expect(throws: MailImportError.self) { try MailMboxCodec.decode(Data("From test date\nContent-Length: 200\n\nBody\n".utf8)) { _, _ in } }
    }

    @Test("MBOX files import into a named folder with source positions and truncated lengths stay visible")
    func mboxFileImport() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("Mailbox.mbox")
        let record = "From test@example.test Tue Nov 14 22:13:20 2023\nSubject: Fixture\nFrom: test@example.test\n\nBody\n\n"
        try Data((record + record.replacingOccurrences(of: "Body", with: "Other")).utf8).write(to: file)
        let preview = try MailImportReader.read([file])
        #expect(preview.candidates.count == 2 && preview.failures.isEmpty)
        #expect(preview.candidates.last?.source == "Mailbox.mbox#2")
        let batch = try await f.mail.importMessages(preview, archiveID: f.archive.id)
        let id = try #require(batch.results.last?.messageID)
        #expect(try await f.mail.rawMessage(id: id)?.data == preview.candidates.last?.data)
        #expect(try await f.mail.folders(accountId: f.archive.id).first { $0.path == "import/Mailbox" }?.totalCount == 2)
        try Data("From test date\nContent-Length: 20\n\nBody\n".utf8).write(to: file)
        let unsupported = try MailImportReader.read([file])
        #expect(unsupported.candidates.isEmpty && unsupported.failures.first?.error == .invalidMessage)
    }

    @Test("Legacy accounts and serialized metadata migrate as IMAP, retaining their existing identity")
    func migration() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let service = MailAccountService(databaseQueue: queue, space: .work)
        let account = MailAccount(displayName: "Legacy", emailAddress: "reader@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "reader@example.test")
        try await service.save(account, password: nil)
        try await queue.write { db in
            try db.execute(sql: "DROP TABLE mail_import_entries")
            try db.execute(sql: "DROP TABLE mail_import_origins")
            try db.execute(sql: "DROP TABLE mail_import_batches")
            try db.execute(sql: "ALTER TABLE mail_accounts DROP COLUMN sourceKind")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v11_mail_local_archives'")
        }
        try DatabaseBootstrap.prepareSpace(queue); try DatabaseBootstrap.prepareSpace(queue)
        #expect(try await service.account(id: account.id)?.sourceKind == .imap)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        json.removeValue(forKey: "sourceKind")
        let old = try JSONDecoder().decode(MailAccount.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.isLocalArchive && old.id == account.id)
    }

    @Test("Cancellation keeps committed mail and a durable report of the remaining items")
    func cancellationAndReceipt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let input = try preview(f, data: [eml("One"), eml("Two"), eml("Three")])
        let task = Task {
            try await f.mail.importMessages(input, archiveID: f.archive.id) { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let batch = try await task.value
        #expect(batch.state == .cancelled)
        #expect(batch.results.filter { $0.status == .imported }.count == 1)
        #expect(batch.results.filter { $0.status == .unprocessed }.count == 2)
        let read = try #require(try await f.mail.importBatches(archiveID: f.archive.id).first)
        #expect(read.state == .cancelled && read.results.first?.messageID == batch.results.first?.messageID)
        var interrupted = read; interrupted.state = .running
        for index in interrupted.results.indices { interrupted.results[index].status = .unprocessed; interrupted.results[index].messageID = nil }
        let payload = try JSONEncoder().encode(interrupted)
        try await f.queue.write { db in try db.execute(sql: "UPDATE mail_import_batches SET payload=? WHERE id=?", arguments: [payload, batch.id.uuidString]) }
        let recovered = try #require(try await f.mail.importBatches(archiveID: f.archive.id).first)
        #expect(recovered.results.first?.status == .imported && recovered.results.first?.messageID == batch.results.first?.messageID)
        var retry = input; retry.candidates = Array(input.candidates.dropFirst())
        let finished = try await f.mail.importMessages(retry, archiveID: f.archive.id)
        #expect(finished.results.allSatisfy { $0.status == .imported })
        let entryCount = try await f.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_import_entries") }
        #expect(entryCount == 3)
    }

    @Test("Backups restore archives, original messages, origins and deduplication independently of server accounts")
    func backupRestore() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let input = try preview(f, data: [eml()])
        let batch = try await f.mail.importMessages(input, archiveID: f.archive.id)
        let snapshot = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let restored = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(restored)
        let store = SpaceDatabaseBackupStore(queue: restored, space: "work")
        _ = try await store.apply(store.plan(snapshot, sourceSpace: "work"), willCommit: { _ in })
        let accounts = MailAccountService(databaseQueue: restored, space: .work), mail = MailService(databaseQueue: restored)
        #expect(try await accounts.account(id: f.archive.id)?.isLocalArchive == true)
        #expect(try await accounts.account(id: f.archive.id)?.isEnabled == true)
        #expect(try await mail.rawMessage(id: #require(batch.results.first?.messageID))?.data == input.candidates.first?.data)
        #expect(try await mail.importPreview(input, archiveID: f.archive.id).duplicates.count == 1)
        try await accounts.delete(id: f.archive.id)
        #expect(try await mail.importBatches(archiveID: f.archive.id).isEmpty)
    }

    @Test("Undo skips messages changed after review, preserves other batches, and its receipt survives backup")
    func undoReviewedBatch() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let batch = try await f.mail.importMessages(preview(f, data: [eml("One"), eml("Two"), eml("One")]), archiveID: f.archive.id)
        let other = try await f.mail.importMessages(preview(f, data: [eml("Other")]), archiveID: f.archive.id)
        let changed = try #require(batch.results[0].messageID), removed = try #require(batch.results[1].messageID)
        let unrelated = try #require(other.results.first?.messageID)
        let plan = try await f.mail.previewImportUndo(batchID: batch.id, archiveID: f.archive.id)
        #expect(plan.count == 2)
        try await f.mail.setFlags(messageId: changed, isRead: true)
        let result = try await f.mail.undoImport(plan)
        #expect(result.removed == [removed] && result.skipped == [changed])
        #expect(try await f.mail.message(id: changed) != nil)
        #expect(try await f.mail.message(id: removed) == nil)
        #expect(try await f.mail.message(id: unrelated) != nil)
        #expect(try await f.mail.undoImport(plan) == result)
        let snapshot = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let restored = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(restored)
        let store = SpaceDatabaseBackupStore(queue: restored, space: "work")
        _ = try await store.apply(store.plan(snapshot, sourceSpace: "work"), willCommit: { _ in })
        let mail = MailService(databaseQueue: restored)
        #expect(try await mail.importBatches(archiveID: f.archive.id).first { $0.id == batch.id }?.undo == result)
        #expect(try await mail.message(id: removed) == nil)
    }

    @Test("Cancellation before undo leaves both messages and its durable marker untouched")
    func cancelledUndo() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let batch = try await f.mail.importMessages(preview(f, data: [eml("One"), eml("Two")]), archiveID: f.archive.id)
        let plan = try await f.mail.previewImportUndo(batchID: batch.id, archiveID: f.archive.id)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.mail.undoImport(plan)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await f.mail.importBatches(archiveID: f.archive.id).first?.undo == nil)
        #expect(try await f.mail.folders(accountId: f.archive.id).first { $0.role == .inbox }?.totalCount == 2)
    }

    @Test("Undo of a running import stops later rows and cannot be overwritten by the importer's final receipt")
    func undoStopsImporter() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let preview = try preview(f, data: [eml("One"), eml("Two"), eml("Three")])
        await #expect(throws: MailImportError.self) {
            try await f.mail.importMessages(preview, archiveID: f.archive.id) { done, _ in
                if done == 1 {
                    do {
                        let batch = try #require(try await f.mail.importBatches(archiveID: f.archive.id).first)
                        let plan = try await f.mail.previewImportUndo(batchID: batch.id, archiveID: f.archive.id)
                        _ = try await f.mail.undoImport(plan)
                    } catch { Issue.record(error) }
                }
            }
        }
        let stored = try #require(try await f.mail.importBatches(archiveID: f.archive.id).first)
        #expect(stored.undo?.removed.count == 1 && stored.state == .cancelled)
        #expect(try await f.mail.folders(accountId: f.archive.id).first { $0.role == .inbox }?.totalCount == 0)
    }

    @Test("An undo review cannot silently include messages imported after that review")
    func staleUndoReview() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let input = try preview(f, data: [eml("One"), eml("Two")])
        let review = UndoReview()
        let batch = try await f.mail.importMessages(input, archiveID: f.archive.id) { done, _ in
            do {
                if done == 1 {
                    let current = try #require(try await f.mail.importBatches(archiveID: f.archive.id).first)
                    await review.set(try await f.mail.previewImportUndo(batchID: current.id, archiveID: f.archive.id))
                } else {
                    let plan = try #require(await review.value)
                    await #expect(throws: MailImportError.self) { try await f.mail.undoImport(plan) }
                }
            } catch { Issue.record(error) }
        }
        #expect(batch.results.filter { $0.status == .imported }.count == 2)
        #expect(try await f.mail.importBatches(archiveID: f.archive.id).first?.undo == nil)
        #expect(try await f.mail.folders(accountId: f.archive.id).first { $0.role == .inbox }?.totalCount == 2)
    }

    @MainActor
    @Test("Import UI checks indexed sources before writing and a local-only source has no compose or sync action")
    func importModel() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try eml()
        _ = try preview(f, data: [original])
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let model = MailImportModel(hub: hub, space: .work, archiveID: f.archive.id)
        await model.load()
        model.readFiles([f.root.appendingPathComponent("fixture-0.eml")])
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.preview?.candidates.count == 1 && model.error == nil)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("fixture-0.eml"))
        model.start()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.batch?.results.first?.error == .changed)
        try original.write(to: f.root.appendingPathComponent("fixture-0.eml"))
        model.readFiles([f.root.appendingPathComponent("fixture-0.eml")])
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        model.start()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.batch?.results.first?.status == .imported && model.error == nil)
        let viewModel = MailViewModel(hub: hub, space: .work)
        await viewModel.loadIfNeeded()
        #expect(!viewModel.canSync && viewModel.newDraft() == nil)
        #expect(model.history.count == 2)
        let sender = MailAccount(displayName: "Sending account", emailAddress: "to@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "to@example.test")
        try await f.accounts.save(sender, password: nil)
        await viewModel.reloadAccounts()
        let id = try #require(model.batch?.results.first?.messageID)
        let message = try #require(try await f.mail.message(id: id))
        let reply = viewModel.replyAllDraft(for: message)
        #expect(reply.accountId == sender.id && reply.sourceMessageId == message.id)
        #expect(!reply.to.contains { $0.address == sender.emailAddress })
        try await f.accounts.delete(id: sender.id)
        #expect(try await f.mail.message(id: id) != nil)
        model.prepareUndo()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        let review = try #require(model.undoPlan)
        #expect(try await f.mail.message(id: id) != nil)
        model.dismissUndo()
        model.confirmUndo(review)
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await f.mail.message(id: id) == nil)
        #expect(model.batch?.undo?.removed == [id] && !model.canUndo && !model.canRetry)
    }

    @MainActor
    @Test("Import checkboxes freeze only selected mail, keep hidden selections and ignore unknown IDs")
    func importSelection() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try preview(f, data: [eml("First"), eml("Second"), eml("Third")])
        let model = MailImportModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue)), space: .work, archiveID: f.archive.id)
        await model.load()
        model.readFiles((0...2).map { f.root.appendingPathComponent("fixture-\($0).eml") })
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        let candidates = try #require(model.preview?.candidates)
        #expect(candidates.count == 3 && model.selectedIDs.count == 3)
        model.setSelected(UUID(), selected: true)
        model.setSelected(candidates[1].id, selected: false)
        #expect(model.selectedIDs.count == 2)
        #expect(model.selectedByteCount == Int64(candidates[0].byteCount + candidates[2].byteCount))
        let access = try #require(model.preview?.access)
        let expectedOriginals = [try await access.original(candidates[0].id).data, try await access.original(candidates[2].id).data]
        model.folderFilter = "unavailable folder"
        #expect(model.visibleCandidates.isEmpty && model.selectedCandidates.count == 2)
        model.selectVisible(false)
        #expect(model.selectedCandidates.count == 2)
        model.folderFilter = nil
        model.after = Date(timeIntervalSince1970: 1_700_000_001)
        #expect(model.visibleCandidates.isEmpty && model.selectedCandidates.count == 2)
        model.after = nil
        await model.refreshMapping()
        model.start()
        model.setSelected(candidates[0].id, selected: false)
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        let batch = try #require(model.batch)
        #expect(Set(batch.results.map(\.id)) == [candidates[0].id, candidates[2].id])
        #expect(batch.results.allSatisfy { $0.status == .imported })
        var originals: [Data] = []
        for result in batch.results {
            let id = try #require(result.messageID)
            let raw = try #require(try await f.mail.rawMessage(id: id))
            originals.append(raw.data)
        }
        #expect(Set(originals) == Set(expectedOriginals))
    }

    @MainActor
    @Test("Native import preview and report render in all three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeImportLayouts() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try preview(f, data: [eml(subject: "跨团队项目评审 / Cross-team project review"), eml("Other", subject: "附件与交付安排 / Delivery")])
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let archive = try await f.mail.createLocalArchive(name: "Imported fixtures", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
            let model = MailImportModel(hub: hub, space: .work, archiveID: archive.id)
            await model.load()
            model.readFiles([f.root.appendingPathComponent("fixture-0.eml"), f.root.appendingPathComponent("fixture-1.eml")])
            for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
            let host = NSHostingView(rootView: MailImportView(model: model).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            for state in ["preview", "report", "undone"] {
                if state == "report" {
                    model.start()
                    for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
                }
                if state == "undone" {
                    model.prepareUndo()
                    for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
                    let plan = try #require(model.undoPlan)
                    model.dismissUndo(); model.confirmUndo(plan)
                    for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
                    #expect(model.batch?.undo?.removed.count == 2)
                }
                for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("mail-import-\(state)-\(language.rawValue).png"))
            }
            window.close()
        }
    }
}
