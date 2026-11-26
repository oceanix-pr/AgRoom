import AppKit
import Foundation
import GRDB
import PDFKit
import SwiftUI
import Testing
import Vision
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Mail export planning", .serialized)
struct MailExportPlanTests {
    private func fixture() async throws -> (DatabaseQueue, MailService, MailAccount, MailFolder) {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let account = MailAccount(displayName: "Same account", emailAddress: "reader@example.test", imapHost: "imap.example.test",
            smtpHost: "smtp.example.test", username: "reader@example.test")
        try await MailAccountService(databaseQueue: queue, space: .work).save(account, password: nil)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox", role: .inbox)
        let mail = MailService(databaseQueue: queue); try await mail.upsertFolders([folder])
        return (queue, mail, account, folder)
    }

    private func message(_ account: MailAccount, _ folder: MailFolder, uid: UInt32 = 1, subject: String = "Same subject") -> MailMessage {
        .init(accountId: account.id, folderId: folder.id, uid: uid, messageId: "<\(uid)@example.test>", subject: subject,
            fromName: "Sender", fromAddress: "sender@example.test", date: Date(timeIntervalSince1970: 1_700_000_000), sizeBytes: 1234)
    }
    private func raw(_ message: MailMessage) -> Data {
        Data("Message-ID: \(message.messageId!)\r\nFrom: sender@example.test\r\nSubject: \(message.subject)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nOriginal content \(message.uid)\r\n".utf8)
    }
    private func options(format: MailExportFormat = .eml, naming: MailExportNaming = .subject,
                         grouping: MailExportGrouping = .flat, name: String = "Review") -> MailExportLayoutOptions {
        .init(format: format, naming: naming, grouping: grouping, directoryName: name, timeZoneIdentifier: "UTC",
            labels: .init(undated: "Undated", untitled: "Untitled", volumeBase: "mail"))
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test("Preflight distinguishes local recovery, eligible downloads, unknown sizes and offline sources without reading content")
    func preparation() async throws {
        let (_, mail, account, folder) = try await fixture()
        let cached = message(account, folder)
        var missing = message(account, folder, uid: 2); missing.sizeBytes = 0
        let archive = try await mail.createLocalArchive(name: "Offline", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let offlineFolder = try #require(try await mail.folders(accountId: archive.id).first)
        var offline = message(archive, offlineFolder); offline.uid = MailService.localUIDFloor
        try await mail.upsertMessages([cached, missing, offline])
        try await mail.saveRawMessage(id: cached.id, raw: .init(data: raw(cached), kind: .received))
        let review = try await mail.reviewExport(ids: [cached.id, missing.id, cached.id, offline.id])
        #expect(review.sources.map(\.message.id) == [cached.id, missing.id, offline.id])
        let eml = review.preparation(for: .eml)
        #expect(eml.missingLocal == 2 && eml.downloadCandidates == 1 && eml.unavailableLocally == 1)
        #expect(eml.knownDownloadBytes == 0 && eml.unknownSizes == 1)
        let pdf = review.preparation(for: .pdf)
        #expect(pdf.missingLocal == 2 && pdf.knownDownloadBytes == nil && pdf.unknownSizes == 1)
        #expect(try await mail.body(messageId: cached.id) == nil)
    }

    @Test("Reviews bind the exact database connection and naming identity while tolerating flags and cache eviction")
    func reviewIdentity() async throws {
        let (queue, mail, account, folder) = try await fixture()
        let item = message(account, folder); try await mail.upsertMessages([item])
        let review = try await mail.reviewExport(ids: [item.id])
        try await queue.write { db in try db.execute(sql: "UPDATE mail_messages SET isRead=1 WHERE id=?", arguments: [item.id.uuidString]) }
        try await mail.saveRawMessage(id: item.id, raw: .init(data: raw(item), kind: .received))
        try await mail.saveBody(.init(messageId: item.id, textBody: "Cached"))
        try await mail.validateExport(review)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM mail_bodies WHERE messageId=?", arguments: [item.id.uuidString])
            try db.execute(sql: "DELETE FROM mail_raw_messages WHERE messageID=?", arguments: [item.id.uuidString])
        }
        try await mail.validateExport(review)
        let copied = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(copied)
        let backup = try await SpaceDatabaseBackupStore(queue: queue, space: "work").export()
        let target = SpaceDatabaseBackupStore(queue: copied, space: "work")
        let restoration = try await target.plan(backup, sourceSpace: "work")
        _ = try await target.apply(restoration, willCommit: { _ in })
        #expect(try await MailService(databaseQueue: copied).message(id: item.id)?.id == item.id)
        await #expect(throws: MailExportError.changed) { try await MailService(databaseQueue: copied).validateExport(review) }
        try await queue.write { db in try db.execute(sql: "UPDATE mail_messages SET subject=? WHERE id=?", arguments: ["Changed", item.id.uuidString]) }
        await #expect(throws: MailExportError.changed) { try await mail.validateExport(review) }
    }

    @Test("Pending folder changes allow local backup while excluding new server reads, and incomplete hierarchies still permit flat export")
    func pendingAndHierarchy() async throws {
        let (queue, mail, account, _) = try await fixture()
        let folder = MailFolder(accountId: account.id, path: "Missing/Leaf", name: "Leaf", parentPath: "Missing", delimiter: "/")
        try await mail.upsertFolders([folder])
        let item = message(account, folder); try await mail.upsertMessages([item])
        let retained = raw(item)
        try await mail.saveRawMessage(id: item.id, raw: .init(data: retained, kind: .received))
        let plan = try await mail.reviewFolderMutation(accountID: account.id, kind: .create, name: "New folder")
        _ = try await mail.beginFolderMutation(plan, serverStatuses: [:])
        let review = try await mail.reviewExport(ids: [item.id])
        #expect(!review.allowsNetwork && !review.hasCompleteHierarchy)
        _ = try MailExportLayout.build(review: review, options: options())
        #expect(throws: MailExportError.changed) { try MailExportLayout.build(review: review, options: options(grouping: .accountFolder)) }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let mock = MockMailClient()
        let sync = MailSyncService(accountService: .init(databaseQueue: queue, space: .work), mail: mail, space: .work,
            attachmentDirectory: root, clientFactory: { _ in mock }, passwordProvider: { _ in Issue.record("Backup read credentials"); return nil })
        #expect(try await sync.rawMessage(messageId: item.id, downloadIfNeeded: true, exportReview: review).data == retained)
        #expect(await mock.connectCount == 0)
    }

    @Test("Layouts preserve distinct account owners and resolve Unicode, file and directory collisions before saving")
    func layoutCollisions() async throws {
        let (queue, mail, account, folder) = try await fixture()
        var other = account; other.id = UUID()
        try await MailAccountService(databaseQueue: queue, space: .work).save(other, password: nil)
        let otherFolder = MailFolder(accountId: other.id, path: "INBOX", name: folder.name, role: .inbox)
        try await mail.upsertFolders([otherFolder])
        let items = [message(account, folder, subject: "Résumé"), message(account, folder, uid: 2, subject: "Re\u{301}sume\u{301}"), message(other, otherFolder)]
        try await mail.upsertMessages(items)
        let review = try await mail.reviewExport(ids: items.map(\.id))
        let flat = try MailExportLayout.build(review: review, options: options())
        #expect(Set(flat.entries.map { MailExportDestination.nameKey($0.path) }).count == 3)
        #expect(flat.entries[1].path.contains(" (2).eml"))
        let grouped = try MailExportLayout.build(review: review, options: options(naming: .dateSenderSubject, grouping: .accountFolder))
        #expect(grouped.entries[0].components[0] != grouped.entries[2].components[0])
        #expect(grouped.entries[0].path.contains("2023-11-14 - Sender - Résumé.eml"))
        #expect(throws: MailExportError.invalidLayout) { try MailExportLayout.build(review: review, options: options(name: "..")) }
        #expect(grouped.entries.allSatisfy { $0.components.allSatisfy { !$0.contains("/") && $0 != ".." } })
    }

    @Test("Planned writes keep exact paths and reject collisions, unowned directories and directory replacement")
    func plannedPublication() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try MailExportDestination.namedBatch(in: root, name: "Review")
        let directory = await target.directoryURL, data = Data("retained".utf8)
        let first = try await target.writePlanned(data, components: ["Inbox", "same.eml"])
        #expect(first.path.hasSuffix("/Review/Inbox/same.eml"))
        await #expect(throws: (any Error).self) { try await target.writePlanned(data, components: ["Inbox", "same.eml"]) }
        await #expect(throws: (any Error).self) { try await target.writePlanned(data, components: ["..", "escape.eml"]) }
        await #expect(throws: (any Error).self) { try await target.writePlanned(data, components: ["export-report.json"]) }
        let inbox = directory.appendingPathComponent("Inbox")
        try FileManager.default.moveItem(at: inbox, to: directory.appendingPathComponent("Old"))
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await target.writePlanned(data, components: ["Inbox", "second.eml"]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
        #expect(throws: (any Error).self) { try MailExportDestination.namedBatch(in: root, name: "Review") }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("External"), withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await target.writePlanned(data, components: ["External", "mail.eml"]) }
        let manifest = directory.appendingPathComponent("export-report.json"), foreign = Data("user file".utf8)
        try foreign.write(to: manifest)
        await #expect(throws: (any Error).self) { try await target.writeReceipt(data, suggestedName: "export-report.json") }
        #expect(try Data(contentsOf: manifest) == foreign)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("export-report (2).json").path))
        let long = try MailExportDestination.batch(in: root, prefix: String(repeating: "邮件", count: 100))
        #expect(await long.directoryURL.lastPathComponent.utf8.count <= 160)
    }

    @Test("Export body publication rolls back as one transaction and retains only unambiguous attachment identities")
    func atomicExportCache() async throws {
        let (queue, mail, account, folder) = try await fixture()
        let item = message(account, folder); try await mail.upsertMessages([item])
        let unique = MailAttachment(messageId: item.id, filename: "unique.png", mimeType: "image/png", sizeBytes: 3,
            contentId: "<pixel>", localPath: "/synthetic/unique.png", isInline: true, partID: "2")
        let duplicate = MailAttachment(messageId: item.id, filename: "repeat.bin", mimeType: "application/octet-stream",
            localPath: "/synthetic/repeat.bin", partID: "3")
        try await mail.saveAttachments([unique, duplicate])
        let review = try await mail.reviewExport(ids: [item.id])
        let body = RemoteMessageBody(textBody: "Restored content", htmlBody: nil, references: "<thread@example.test>", attachments: [
            .init(filename: unique.filename, mimeType: unique.mimeType, sizeBytes: 0, contentId: "pixel", isInline: true, partID: "local:0"),
            .init(filename: duplicate.filename, mimeType: duplicate.mimeType, sizeBytes: 0, contentId: nil, isInline: false, partID: "local:1"),
            .init(filename: duplicate.filename, mimeType: duplicate.mimeType, sizeBytes: 0, contentId: nil, isInline: false, partID: "local:2")])
        _ = try await mail.saveExportBody(body, messageID: item.id, review: review, snippet: "Restored snippet")
        let restored = try await mail.attachments(messageId: item.id)
        #expect(restored.count == 3)
        #expect(restored.first { $0.filename == unique.filename }?.id == unique.id)
        #expect(restored.first { $0.filename == unique.filename }?.localPath == unique.localPath)
        #expect(restored.filter { $0.filename == duplicate.filename }.allSatisfy { $0.id != duplicate.id && $0.localPath == nil })
        try await queue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_export_attachment BEFORE INSERT ON mail_attachments WHEN NEW.filename='blocked.bin' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        }
        let rejected = RemoteMessageBody(textBody: "Must roll back", htmlBody: nil, references: "<wrong@example.test>", attachments: [
            .init(filename: "blocked.bin", mimeType: "application/octet-stream", sizeBytes: 0, contentId: nil, isInline: false, partID: "local:0")])
        await #expect(throws: (any Error).self) { try await mail.saveExportBody(rejected, messageID: item.id, review: review, snippet: "Wrong snippet") }
        #expect(try await mail.body(messageId: item.id)?.textBody == body.textBody)
        #expect(try await mail.message(id: item.id)?.references == body.references)
        #expect(try await mail.attachments(messageId: item.id).count == 3)
        try await queue.write { db in try db.execute(sql: "UPDATE mail_messages SET uid=99 WHERE id=?", arguments: [item.id.uuidString]) }
        await #expect(throws: MailExportError.changed) { try await mail.saveExportBody(body, messageID: item.id, review: review, snippet: "Stale") }
        var stale = try #require(restored.first); stale.localPath = "/stale"
        await #expect(throws: MailExportError.changed) { try await mail.saveExportAttachment(stale, review: review) }
        #expect(try await mail.attachments(messageId: item.id).allSatisfy { $0.localPath != "/stale" })
    }

    @MainActor
    @Test("The export saves exactly the reviewed grouped paths, preserves bytes and freezes options before the save dialog")
    func groupedExport() async throws {
        let (queue, mail, account, folder) = try await fixture()
        let items = [message(account, folder), message(account, folder, uid: 2)]
        try await mail.upsertMessages(items)
        for item in items { try await mail.saveRawMessage(id: item.id, raw: .init(data: raw(item), kind: .received)) }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = MailTransferModel(request: .init(content: .messages(items.map(\.id))), hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        defer { model.close() }
        model.grouping = .accountFolder; model.naming = .dateSubject; model.directoryName = "Reviewed folder"
        model.downloadMissing = false; await model.prepare()
        let layout = try #require(model.layout)
        model.chooseDestination = { panel in
            #expect(panel is NSOpenPanel)
            model.format = .pdf; model.grouping = .month; model.naming = .dateSenderSubject; model.directoryName = "Changed while choosing"
            return .selected(root)
        }
        model.start(); await wait(model)
        #expect(model.results.compactMap(\.file) == layout.entries.map(\.path))
        let destination = try #require(model.destination)
        #expect(destination.lastPathComponent == layout.directoryName)
        for (item, result) in zip(items, model.results) {
            let file = try #require(result.file)
            #expect(try Data(contentsOf: destination.appendingPathComponent(file)) == raw(item))
        }
        let report = try JSONDecoder().decode([MailTransferItem].self, from: Data(contentsOf: destination.appendingPathComponent("export-report.json")))
        #expect(report.compactMap(\.file) == layout.entries.map(\.path))
    }

    @MainActor
    @Test("Retrying a partially saved grouped export keeps the selected layout and writes only unsaved mail into a new reviewed directory")
    func groupedRetry() async throws {
        let (queue, mail, account, folder) = try await fixture()
        let items = [message(account, folder), message(account, folder, uid: 2)]
        try await mail.upsertMessages(items)
        try await mail.saveRawMessage(id: items[0].id, raw: .init(data: raw(items[0]), kind: .received))
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = MailTransferModel(request: .init(content: .messages(items.map(\.id))), hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        defer { model.close() }
        model.grouping = .month; model.naming = .dateSubject; model.downloadMissing = false
        await model.prepare(); model.chooseDestination = { _ in .selected(root) }; model.start(); await wait(model)
        #expect(model.results.filter { $0.file != nil }.map(\.id) == [items[0].id])
        let firstRoot = try #require(model.destination), firstFile = try #require(model.results[0].file)
        let report = try Data(contentsOf: firstRoot.appendingPathComponent("export-report.json"))
        try await mail.saveRawMessage(id: items[1].id, raw: .init(data: raw(items[1]), kind: .received))
        await model.prepareFailedItems()
        #expect(model.count == 1 && model.grouping == .month && model.naming == .dateSubject)
        #expect(model.layout?.isDirectory == true && model.layout?.directoryName != firstRoot.lastPathComponent)
        let planned = try #require(model.layout?.entries.first?.path)
        model.start(); await wait(model)
        #expect(model.results.map(\.id) == [items[1].id] && model.results.first?.file == planned)
        let retryRoot = try #require(model.destination)
        #expect(try Data(contentsOf: retryRoot.appendingPathComponent(planned)) == raw(items[1]))
        #expect(try Data(contentsOf: firstRoot.appendingPathComponent(firstFile)) == raw(items[0]))
        #expect(try Data(contentsOf: firstRoot.appendingPathComponent("export-report.json")) == report)
    }

    @MainActor
    @Test("An account changed in the save dialog requires fresh review and cannot open a connection or create an output folder")
    func staleDestinationReview() async throws {
        let (queue, mail, account, folder) = try await fixture()
        let items = [message(account, folder), message(account, folder, uid: 2)]
        try await mail.upsertMessages(items)
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = MockMailClient()
        let sync = MailSyncService(accountService: .init(databaseQueue: queue, space: .work), mail: mail, space: .work,
            attachmentDirectory: root, clientFactory: { _ in client }, passwordProvider: { _ in Issue.record("Stale review read credentials"); return nil })
        let model = MailTransferModel(request: .init(content: .messages(items.map(\.id))), hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        defer { model.close() }
        model.makeSyncService = { sync }; await model.prepare()
        let review = try #require(model.review)
        model.chooseDestination = { _ in
            var changed = account; changed.imapHost = "changed.example.test"
            try! await MailAccountService(databaseQueue: queue, space: .work).save(changed, password: nil)
            return .selected(root)
        }
        model.start(); await wait(model)
        #expect(model.needsReview && !model.prepared && model.results.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: MailExportError.changed) { try await sync.rawMessage(messageId: items[0].id, downloadIfNeeded: true, exportReview: review) }
        #expect(await client.connectCount == 0)
    }

    @MainActor
    @Test("Retained remote originals restore an evicted body and CID attachment offline and export a readable PDF")
    func offlinePDF() async throws {
        let (queue, mail, account, folder) = try await fixture()
        var item = message(account, folder); item.hasAttachments = true
        try await mail.upsertMessages([item])
        let original = Data("Message-ID: \(item.messageId!)\r\nFrom: sender@example.test\r\nSubject: Offline\r\nMIME-Version: 1.0\r\nContent-Type: multipart/related; boundary=example\r\n\r\n--example\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Recovered offline content</p><img src=\"cid:pixel\">\r\n--example\r\nContent-Type: image/png; name=pixel.png\r\nContent-Disposition: inline; filename=pixel.png\r\nContent-ID: <pixel>\r\nContent-Transfer-Encoding: base64\r\n\r\niVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8XcAAAAASUVORK5CYII=\r\n--example--\r\n".utf8)
        try await mail.saveRawMessage(id: item.id, raw: .init(data: original, kind: .received))
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = MockMailClient()
        let sync = MailSyncService(accountService: .init(databaseQueue: queue, space: .work), mail: mail, space: .work,
            attachmentDirectory: root, clientFactory: { _ in client }, passwordProvider: { _ in Issue.record("Offline export read credentials"); return nil })
        let review = try await mail.reviewExport(ids: [item.id])
        #expect(review.preparation(for: .pdf).missingLocal == 0)
        let body = try await sync.bodyForExport(messageId: item.id, downloadIfNeeded: false, review: review)
        #expect(body.htmlBody?.contains("Recovered offline content") == true)
        let attachment = try #require(try await mail.attachments(messageId: item.id).first)
        let image = try await sync.downloadAttachment(messageId: item.id, attachmentID: attachment.id, downloadIfNeeded: false, exportReview: review)
        #expect(try Data(contentsOf: image).starts(with: [137, 80, 78, 71]))
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = MailTransferModel(request: .init(content: .messages([item.id])), hub: hub, space: .work)
        defer { model.close() }
        model.makeSyncService = { sync }; model.format = .pdf; model.downloadMissing = false; await model.prepare()
        let output = root.appendingPathComponent("offline.pdf")
        model.chooseDestination = { _ in .selected(output) }; model.start(); await wait(model)
        #expect(model.results.first?.file != nil)
        #expect(PDFDocument(url: output)?.string?.contains("Recovered offline content") == true)
        #expect(await client.connectCount == 0)
    }

    @Test("Export body completion is explicit and refuses a missing known UIDVALIDITY before reading body or attachment content")
    func networkBodyIdentity() async throws {
        let (queue, mail, account, originalFolder) = try await fixture()
        var folder = originalFolder; folder.uidValidity = 10
        let folderID = folder.id
        try await mail.upsertFolders([folder])
        try await queue.write { db in try db.execute(sql: "UPDATE mail_folders SET uidValidity=10 WHERE id=?", arguments: [folderID.uuidString]) }
        let item = message(account, folder); try await mail.upsertMessages([item])
        let remote = RemoteMessageBody(textBody: "Downloaded body", htmlBody: nil, attachments: [])
        let mock = MockMailClient(statuses: [folder.path: .init(uidValidity: 10, uidNext: 2, messageCount: 1, unreadCount: 1)], bodies: [item.uid: remote])
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sync = MailSyncService(accountService: .init(databaseQueue: queue, space: .work), mail: mail, space: .work,
            attachmentDirectory: root, clientFactory: { _ in mock }, passwordProvider: { _ in "fixture" })
        let review = try await mail.reviewExport(ids: [item.id])
        try #require(review.source(item.id)?.folder.uidValidity == 10)
        await #expect(throws: MailExportError.incomplete) { try await sync.bodyForExport(messageId: item.id, downloadIfNeeded: false, review: review) }
        #expect(await mock.connectCount == 0)
        #expect(try await sync.bodyForExport(messageId: item.id, downloadIfNeeded: true, review: review).textBody == remote.textBody)
        #expect(await mock.bodyFetchCount == 1)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM mail_bodies WHERE messageId=?", arguments: [item.id.uuidString])
            try db.execute(sql: "UPDATE mail_messages SET bodyState=? WHERE id=?", arguments: [MailBodyState.none.rawValue, item.id.uuidString])
        }
        await mock.configure(statuses: [folder.path: .init(uidValidity: nil, uidNext: 2, messageCount: 1, unreadCount: 1)])
        await #expect(throws: MailExportError.changed) { try await sync.bodyForExport(messageId: item.id, downloadIfNeeded: true, review: review) }
        #expect(await mock.bodyFetchCount == 1)
        #expect(try await mail.body(messageId: item.id) == nil)
        #expect(try await mail.message(id: item.id)?.bodyState == MailBodyState.none)
        let attachment = MailAttachment(messageId: item.id, filename: "image.png", mimeType: "image/png", partID: "2")
        try await mail.saveAttachments([attachment])
        await #expect(throws: MailExportError.changed) { try await sync.downloadAttachment(messageId: item.id, attachmentID: attachment.id, exportReview: review) }
        await #expect(throws: MailExportError.changed) { try await sync.rawMessage(messageId: item.id, downloadIfNeeded: true, exportReview: review) }
        #expect(await mock.attachmentDownloadCount == 0)
        #expect(await mock.rawFetchCount == 0)
        #expect(try await mail.attachments(messageId: item.id).first?.localPath == nil)
    }

    @Test("An attachment restored from a received original can refresh its server part after raw cache eviction")
    func attachmentAfterRawEviction() async throws {
        let (queue, mail, account, folder) = try await fixture()
        var item = message(account, folder); item.hasAttachments = true
        try await mail.upsertMessages([item])
        let original = Data("Message-ID: \(item.messageId!)\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=parts\r\n\r\n--parts\r\nContent-Type: text/plain\r\n\r\nOffline body\r\n--parts\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=unique.bin\r\nContent-Transfer-Encoding: base64\r\n\r\nYWJj\r\n--parts--\r\n".utf8)
        try await mail.saveRawMessage(id: item.id, raw: .init(data: original, kind: .received))
        let remote = RemoteMessageBody(textBody: "Server body", htmlBody: nil, attachments: [
            .init(filename: "unique.bin", mimeType: "application/octet-stream", sizeBytes: 3, contentId: nil, isInline: false, partID: "2")])
        let mock = MockMailClient(bodies: [item.uid: remote])
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sync = MailSyncService(accountService: .init(databaseQueue: queue, space: .work), mail: mail, space: .work,
            attachmentDirectory: root, clientFactory: { _ in mock }, passwordProvider: { _ in "fixture" })
        let review = try await mail.reviewExport(ids: [item.id])
        _ = try await sync.bodyForExport(messageId: item.id, downloadIfNeeded: false, review: review)
        let local = try #require(try await mail.attachments(messageId: item.id).first)
        #expect(local.partID?.hasPrefix("local:") == true)
        let messageID = item.id
        try await queue.write { db in try db.execute(sql: "DELETE FROM mail_raw_messages WHERE messageID=?", arguments: [messageID.uuidString]) }
        await #expect(throws: MailExportError.incomplete) { try await sync.downloadAttachment(messageId: item.id, attachmentID: local.id, downloadIfNeeded: false, exportReview: review) }
        #expect(await mock.connectCount == 0)
        let output = try await sync.downloadAttachment(messageId: item.id, attachmentID: local.id, exportReview: review)
        #expect(!((try Data(contentsOf: output)).isEmpty))
        #expect(await mock.bodyFetchCount == 1)
        #expect(await mock.attachmentDownloadCount == 1)
        #expect(try await mail.attachments(messageId: item.id).first?.partID == "2")
    }

    @MainActor
    @Test("Grouped MBOX volumes avoid all reviewed child-directory names and keep original result order and bytes")
    func groupedMbox() async throws {
        let (queue, mail, account, folder) = try await fixture()
        let child = MailFolder(accountId: account.id, path: "INBOX/mail-0002.mbox", name: "mail-0002.mbox", parentPath: "INBOX")
        try await mail.upsertFolders([child])
        let first = message(account, folder), second = message(account, folder, uid: 2), third = message(account, child, uid: 3)
        let items = [first, third, second]
        try await mail.upsertMessages(items)
        for item in items { try await mail.saveRawMessage(id: item.id, raw: .init(data: raw(item), kind: .received)) }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = MailTransferModel(request: .init(content: .messages(items.map(\.id))), hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        defer { model.close() }
        model.format = .mbox; model.grouping = .accountFolder; model.downloadMissing = false
        model.mboxPartByteLimit = try items.map { try MailMboxCodec.encode(raw($0), date: $0.date).data.count }.max()!
        await model.prepare()
        let layout = try #require(model.layout)
        #expect(layout.groups[0].volumeBase != "mail")
        model.chooseDestination = { _ in .selected(root) }; model.start(); await wait(model)
        #expect(model.results.map(\.id) == items.map(\.id))
        let destination = try #require(model.destination)
        for (item, result) in zip(items, model.results) {
            let file = try #require(result.file)
            var originals: [Data] = []
            try MailMboxCodec.decode(Data(contentsOf: destination.appendingPathComponent(file))) { _, data in originals.append(data) }
            #expect(originals == [raw(item)])
            #expect(result.originalSHA256 != nil && result.originalByteCount == raw(item).count)
        }
        #expect(model.results[2].file?.contains("-0002.mbox") == true)
    }

    @MainActor
    @Test("The preview searches beyond its first page and closing invalidates pending preparation")
    func previewPagingAndClose() async throws {
        let (queue, mail, account, folder) = try await fixture()
        let items = (1...215).map { message(account, folder, uid: UInt32($0), subject: "Subject-\($0)") }
        try await mail.upsertMessages(items)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = MailTransferModel(request: .init(content: .messages(items.map(\.id))), hub: hub, space: .work)
        defer { model.close() }
        await model.prepare(); await waitPaths(model)
        #expect(model.visiblePaths.count == 100 && model.matchingPaths == 215)
        model.showMorePaths(); await waitPaths(model)
        #expect(model.visiblePaths.count == 200)
        model.previewQuery = "Subject-214"; await waitPaths(model)
        #expect(model.visiblePaths.map(\.id) == [items[213].id])
        model.directoryName = ".."; await waitLayout(model)
        #expect(!model.prepared && model.error != nil)
        let closed = MailTransferModel(request: .init(content: .messages(items.map(\.id))), hub: hub, space: .work)
        let prepare = Task { await closed.prepare() }; closed.close(); await prepare.value
        closed.chooseDestination = { _ in Issue.record("Closed preview opened a save dialog"); return .cancelled }
        closed.start()
        #expect(!closed.prepared && !closed.busy && closed.layout == nil)
    }

    @MainActor
    @Test("Native export controls change the reviewed layout and render local-only options in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeExportOptions() async throws {
        _ = NSApplication.shared
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let (queue, mail, account, folder) = try await fixture()
            let items = [message(account, folder), message(account, folder, uid: 2, subject: "Second subject")]
            try await mail.upsertMessages(items)
            try await mail.saveRawMessage(id: items[0].id, raw: .init(data: raw(items[0]), kind: .received))
            let model = MailTransferModel(request: .init(content: .messages(items.map(\.id))), hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
            let host = NSHostingView(rootView: MailTransferView(model: model).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { model.close(); window.close() }
            try await waitUntil { model.prepared && !model.filteringPaths }
            try await settle(host)
            try await pressText(L.string("mail.export.grouping.accountFolder"), in: window)
            try await waitUntil { model.grouping == .accountFolder && model.prepared }
            try await pressText(L.string("mail.export.naming.dateSenderSubject"), in: window)
            try await waitUntil { model.naming == .dateSenderSubject && model.prepared }
            try await editField(value: model.directoryName, to: "Native review", host: host, window: window)
            try await waitUntil { model.directoryName == "Native review" && model.prepared && !model.filteringPaths }
            #expect(model.layout?.directoryName == "Native review")
            #expect(model.layout?.entries.allSatisfy { $0.path.contains("2023-") && $0.path.contains("Sender") && $0.path.contains("Same account/Inbox/") } == true)
            try await editField(value: model.previewQuery, placeholder: L.string("mail.export.paths.search"), to: "Second subject", host: host, window: window)
            try await waitUntil { model.previewQuery == "Second subject" && !model.filteringPaths }
            #expect(model.visiblePaths.map(\.id) == [items[1].id])
            try await editField(value: "Second subject", placeholder: L.string("mail.export.paths.search"), to: "", host: host, window: window)
            try await waitUntil { model.previewQuery.isEmpty && !model.filteringPaths }
            try await settle(host)
            try await capture(window, name: "mail-export-options-" + language.rawValue, expected: L.string("mail.export.title"))
            try await pressText(L.string("mail.export.mbox"), in: window)
            try await waitUntil { model.format == .mbox && model.prepared && !model.filteringPaths }
            #expect(model.layout?.groups.count == 1 && model.visiblePaths.first?.path.hasSuffix("mail-0001.mbox") == true)
            try await settle(host)
            try await capture(window, name: "mail-export-volumes-" + language.rawValue, expected: L.string("mail.export.title"))
            var disabled = account; disabled.isEnabled = false
            try await MailAccountService(databaseQueue: queue, space: .work).save(disabled, password: nil)
            await model.prepare(); try await settle(host)
            #expect(!model.canDownload)
            try await capture(window, name: "mail-export-offline-" + language.rawValue, expected: L.string("mail.export.offlineOnly"))
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
            try #require(window.performKeyEquivalent(with: escape))
            #expect(!model.prepared && !model.busy)
        }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Native export state did not settle")
    }
    @MainActor private func settle(_ view: NSView) async throws {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    @MainActor private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
    @MainActor private func pressText(_ title: String, in window: NSWindow) async throws {
        let view = try #require(window.contentView), data = try imageData(window)
        let language = LanguageManager.shared.activeLanguageCode
        let point = try await Task.detached { () throws -> CGPoint in
            try autoreleasepool {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.customWords = [title]
                request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]
                try VNImageRequestHandler(data: data).perform([request])
                for observation in (request.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let indices = candidate.string.indices.filter { !candidate.string[$0].isWhitespace }
                    let compact = String(indices.map { candidate.string[$0] }), target = String(title.filter { !$0.isWhitespace })
                    guard let match = compact.range(of: target, options: [.caseInsensitive, .widthInsensitive]), !match.isEmpty else { continue }
                    let start = compact.distance(from: compact.startIndex, to: match.lowerBound), end = compact.distance(from: compact.startIndex, to: match.upperBound)
                    let range = indices[start]..<candidate.string.index(after: indices[end - 1])
                    if let box = try candidate.boundingBox(for: range) { return .init(x: box.boundingBox.midX, y: box.boundingBox.midY) }
                }
                throw NativeControlFailure(title: title, visible: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
            }
        }.value
        try click(view.convert(NSPoint(x: point.x * view.bounds.width, y: (view.isFlipped ? 1 - point.y : point.y) * view.bounds.height), to: nil), in: window)
    }
    private struct NativeControlFailure: Error { let title: String; let visible: [String] }
    @MainActor private func click(_ location: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
    @MainActor private func accessibilityNodes(in view: NSView) -> [any NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject, depth: Int = 0) -> [any NSAccessibilityProtocol] {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var nodes: [any NSAccessibilityProtocol] = []
            if let node = object as? any NSAccessibilityProtocol {
                nodes.append(node)
                for child in node.accessibilityChildren() ?? [] { nodes += visit(child as AnyObject, depth: depth + 1) }
            }
            if let native = object as? NSView { for child in native.subviews { nodes += visit(child, depth: depth + 1) } }
            return nodes
        }
        return visit(view)
    }
    @MainActor private func editField(value: String, placeholder: String? = nil, to replacement: String, host: NSView, window: NSWindow) async throws {
        if let field = allViews(host).compactMap({ $0 as? NSTextField }).first(where: {
            $0.isEditable && $0.stringValue == value && (placeholder == nil || $0.placeholderString == placeholder)
        }) { try #require(window.makeFirstResponder(field)) }
        else if let field = accessibilityNodes(in: host).first(where: {
            $0.accessibilityRole() == .textField && $0.accessibilityValue() as? String == value && $0.accessibilityFrame().width > 0
        }) {
            let frame = field.accessibilityFrame()
            try click(window.convertPoint(fromScreen: .init(x: frame.midX, y: frame.midY)), in: window)
        } else { try await pressText(value.isEmpty ? (placeholder ?? "") : value, in: window) }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil); editor.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(nil)
        try await settle(host)
    }
    @MainActor private func imageData(_ window: NSWindow) throws -> Data {
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let surface = NSImage(size: bitmap.size), foreground = NSImage(size: bitmap.size)
        foreground.addRepresentation(bitmap); surface.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: bitmap.size).fill()
            foreground.draw(in: NSRect(origin: .zero, size: bitmap.size), from: .zero, operation: .sourceOver, fraction: 1)
        }
        surface.unlockFocus()
        let tiff = try #require(surface.tiffRepresentation), opaque = try #require(NSBitmapImageRep(data: tiff))
        return try #require(opaque.representation(using: .png, properties: [:]))
    }
    @MainActor private func capture(_ window: NSWindow, name: String, expected: String) async throws {
        let data = try imageData(window)
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        let language = LanguageManager.shared.activeLanguageCode
        let visible = try await Task.detached {
            try autoreleasepool {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]
                try VNImageRequestHandler(data: data).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            }
        }.value
        #expect(String(visible.filter { !$0.isWhitespace }).contains(String(expected.filter { !$0.isWhitespace })), Comment(rawValue: visible))
    }

    @MainActor private func wait(_ model: MailTransferModel) async {
        for _ in 0..<500 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.busy, Comment(rawValue: String(describing: model.error)))
    }
    @MainActor private func waitPaths(_ model: MailTransferModel) async {
        for _ in 0..<500 where model.filteringPaths { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.filteringPaths)
    }
    @MainActor private func waitLayout(_ model: MailTransferModel) async {
        for _ in 0..<500 {
            if model.layout != nil || model.error != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.layout != nil || model.error != nil)
    }
}
