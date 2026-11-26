import AppKit
import CryptoKit
import Foundation
import GRDB
import PDFKit
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Mail portability")
struct MailPortabilityTests {
    private func fixture() async throws -> (DatabaseQueue, MailService, MailMessage) {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let account = MailAccount(displayName: "Synthetic", emailAddress: "reader@example.test", imapHost: "imap.example.test",
            smtpHost: "smtp.example.test", username: "reader@example.test")
        try await MailAccountService(databaseQueue: queue, space: .work).save(account, password: nil)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox", role: .inbox)
        let mail = MailService(databaseQueue: queue); try await mail.upsertFolders([folder])
        let message = MailMessage(accountId: account.id, folderId: folder.id, uid: 1,
            messageId: "<original@example.test>", subject: "Same subject", fromAddress: "sender@example.test", bodyState: .ready)
        try await mail.upsertMessages([message])
        return (queue, mail, message)
    }

    private func original(_ id: String = "original") -> Data {
        Data("Message-ID: <\(id)@example.test>\r\nFrom: sender@example.test\r\nSubject: Keep original\r\nX-Unknown: keep me\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nExact bytes.\r\nFrom quoted content\r\n".utf8)
    }

    @Test("Raw bytes survive cache eviction and portable backup; deletion removes them")
    func persistenceAndBackup() async throws {
        let (queue, mail, message) = try await fixture()
        let data = original()
        try await mail.saveRawMessage(id: message.id, raw: .init(data: data, kind: .received))
        try await mail.saveBody(.init(messageId: message.id, textBody: "Cached body"))
        try await queue.write { db in try MailService.trimBodyCache(in: db, maxBytes: 1) }
        #expect(try await mail.body(messageId: message.id) == nil)
        #expect(try await mail.rawMessage(id: message.id)?.data == data)
        var stale = message; stale.uid = 99
        await #expect(throws: MailExportError.self) { try await mail.saveRawMessage(id: message.id, raw: .init(data: Data("wrong".utf8), kind: .received), expected: stale) }
        #expect(try await mail.rawMessage(id: message.id)?.data == data)
        let source = SpaceDatabaseBackupStore(queue: queue, space: "work")
        let backup = try await source.export()
        #expect(backup.count("mail_raw_messages") == 1)
        let restoredQueue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(restoredQueue)
        let target = SpaceDatabaseBackupStore(queue: restoredQueue, space: "work")
        let plan = try await target.plan(backup, sourceSpace: "work")
        _ = try await target.apply(plan, willCommit: { _ in })
        #expect(try await MailService(databaseQueue: restoredQueue).rawMessage(id: message.id)?.data == data)
        try await mail.deleteMessage(id: message.id)
        #expect(try await mail.rawMessage(id: message.id) == nil)
        await #expect(throws: (any Error).self) { try await mail.saveRawMessage(id: message.id, raw: .init(data: data, kind: .received)) }
    }

    @Test("Old databases receive the raw schema without losing mail")
    func schemaUpgrade() async throws {
        let (queue, mail, message) = try await fixture()
        try await queue.write { db in
            try db.execute(sql: "DROP TABLE mail_raw_messages")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v9_mail_raw_messages'")
        }
        try DatabaseBootstrap.prepareSpace(queue)
        try DatabaseBootstrap.prepareSpace(queue)
        #expect(try await mail.message(id: message.id)?.subject == message.subject)
        try await mail.saveRawMessage(id: message.id, raw: .init(data: original(), kind: .received))
        #expect(try await mail.exportCoverage(ids: [message.id]).raw == 1)
    }

    @Test("Destinations reject changed files, replaced directories and symlinks, and keep duplicate names")
    func safePublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.eml")
        try Data("old".utf8).write(to: existing)
        let single = try MailExportDestination(directory: root, filename: existing.lastPathComponent)
        try Data("user edit".utf8).write(to: existing)
        await #expect(throws: (any Error).self) { try await single.write(Data("new".utf8), suggestedName: "ignored") }
        #expect(try Data(contentsOf: existing) == Data("user edit".utf8))
        let folder = try MailExportDestination(directory: root)
        let first = try await folder.write(original(), suggestedName: "../../same.eml")
        let second = try await folder.write(original(), suggestedName: "../../same.eml")
        #expect(first.deletingLastPathComponent().path == root.path && first != second)
        #expect(try Data(contentsOf: first) == original())
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) { try MailExportDestination(directory: link) }
        let old = root.appendingPathComponent("old"), current = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        let frozen = try MailExportDestination(directory: current)
        try FileManager.default.moveItem(at: current, to: old)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await frozen.write(original(), suggestedName: "mail.eml") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: current.path).isEmpty)
        #expect(MailExportDestination.safeName(String(repeating: "长", count: 100)).utf8.count <= 160)
    }

    @MainActor
    @Test("The actual export flow preserves EML bytes, reports partial content and cancels without writing")
    func exportFlow() async throws {
        let (queue, mail, first) = try await fixture()
        var second = first; second.id = UUID(); second.uid = 2; second.messageId = "<second@example.test>"
        try await mail.upsertMessages([second])
        try await mail.saveRawMessage(id: first.id, raw: .init(data: original(), kind: .received))
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MailTransferModel(request: .init(content: .messages([first.id, second.id])), hub: hub, space: .work)
        await model.prepare(); model.downloadMissing = false
        #expect(model.coverage?.raw == 1 && model.coverage?.total == 2)
        model.chooseDestination = { _ in .cancelled }
        model.start(); await wait(model)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        model.chooseDestination = { _ in .selected(root) }
        model.start(); await wait(model)
        #expect(model.results.count == 2 && model.results.filter { $0.file != nil }.count == 1)
        let destination = try #require(model.destination)
        let exported = try #require(model.results.first?.file)
        #expect(try Data(contentsOf: destination.appendingPathComponent(exported)) == original())
        let report = try JSONDecoder().decode([MailTransferItem].self, from: Data(contentsOf: destination.appendingPathComponent("export-report.json")))
        #expect(report.count == 2 && report[1].error != nil)
        #expect(try await mail.rawMessage(id: second.id) == nil)
        try await mail.saveRawMessage(id: second.id, raw: .init(data: original("second"), kind: .received))
        await model.prepareFailedItems()
        #expect(model.count == 1 && model.coverage?.total == 1)
        let recovered = root.appendingPathComponent("recovered.eml")
        model.chooseDestination = { _ in .selected(recovered) }
        model.start(); await wait(model)
        #expect(model.results.count == 1 && model.results.first?.id == second.id)
        #expect(try Data(contentsOf: recovered) == original("second"))
        #expect(try Data(contentsOf: destination.appendingPathComponent(exported)) == original())
    }

    @MainActor
    private func wait(_ model: MailTransferModel) async {
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.busy)
    }

    @Test("Source pages preserve readable UTF-8 boundaries and full headers without changing original bytes")
    func sourceDocument() throws {
        let headers = "Message-ID: <source@example.test>\r\nX-Unknown: folded\r\n continuation\r\nContent-Type: text/plain; charset=utf-8"
        let source = headers + "\r\n\r\n" + String(repeating: "甲😀&<script>plain text</script>\n", count: 6000)
        let bytes = Data(source.utf8)
        let document = try MailSourceDocument(raw: .init(data: bytes, kind: .received))
        #expect(document.text(headersOnly: true, page: 0) == headers)
        #expect(document.pageCount(headersOnly: false) > 1)
        let all = (0..<document.pageCount(headersOnly: false)).map { document.text(headersOnly: false, page: $0) }.joined()
        #expect(all == source && document.raw.data == bytes)
        let binary = try MailSourceDocument(raw: .init(data: Data([65, 10, 10, 255, 0]), kind: .imported))
        #expect(binary.text(headersOnly: true, page: 0) == "A")
        #expect(binary.raw.data == Data([65, 10, 10, 255, 0]))
    }

    @MainActor
    @Test("Source viewing stays in its fixed space, reads offline and requires an explicit action before retrieving originals")
    func sourceModel() async throws {
        let (queue, mail, message) = try await fixture()
        try await mail.saveRawMessage(id: message.id, raw: .init(data: original(), kind: .received))
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = MailSourceModel(request: .init(messageID: message.id, headersOnly: true), hub: hub, space: .work)
        var attempts = 0
        model.makeSyncService = { attempts += 1; return nil }
        model.load()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.text.contains("X-Unknown: keep me") && !model.text.contains("Exact bytes."))
        #expect(attempts == 0 && model.error == nil)
        model.headersOnly = false
        #expect(model.text.contains("Exact bytes."))
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        let personal = MailSourceModel(request: .init(messageID: message.id, headersOnly: false),
            hub: Hub(spaceStore: SpaceStore(space: .personal, databaseQueue: isolated)), space: .personal)
        personal.load()
        for _ in 0..<100 where personal.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(personal.document == nil && personal.error != nil)
        var missing = message; missing.id = UUID(); missing.uid = 2; missing.messageId = "<missing@example.test>"
        try await mail.upsertMessages([missing])
        let absent = MailSourceModel(request: .init(messageID: missing.id, headersOnly: true), hub: hub, space: .work)
        absent.makeSyncService = { attempts += 1; return nil }
        absent.load()
        for _ in 0..<100 where absent.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(absent.document == nil && absent.error == nil && attempts == 0)
        absent.load(download: true)
        for _ in 0..<100 where absent.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(attempts == 1 && absent.error != nil)
        model.load(); model.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!model.busy && model.error == nil && model.document?.raw.data == original())
    }

    @MainActor
    @Test("Native source viewer shows full headers and plain source in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeSourceLayouts() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let (queue, mail, message) = try await fixture()
        try await mail.saveRawMessage(id: message.id, raw: .init(data: original(), kind: .received))
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let model = MailSourceModel(request: .init(messageID: message.id, headersOnly: true), hub: hub, space: .work)
            let host = NSHostingView(rootView: MailSourceView(model: model).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            for state in ["headers", "original"] {
                if state == "original" { model.headersOnly = false }
                for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
                let source = try #require(textViews(host).first { $0.string.contains("X-Unknown: keep me") })
                #expect(!source.isEditable && !source.isRichText && !source.isAutomaticLinkDetectionEnabled)
                #expect(source.string.contains("Exact bytes.") == (state == "original"))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("mail-source-\(state)-\(language.rawValue).png"))
            }
            model.cancel(); window.close()
        }
    }

    @MainActor
    @Test("Native MBOX preview and partial-result report render in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeMboxLayouts() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let (queue, mail, first) = try await fixture()
        var second = first; second.id = UUID(); second.uid = 2; second.messageId = "<other@example.test>"
        try await mail.upsertMessages([second]); try await mail.saveRawMessage(id: first.id, raw: .init(data: original(), kind: .received))
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let model = MailTransferModel(request: .init(content: .messages([first.id, second.id])), hub: hub, space: .work)
            model.format = .mbox; model.downloadMissing = false; await model.prepare()
            model.chooseDestination = { _ in .selected(directory) }
            let host = NSHostingView(rootView: MailTransferView(model: model).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            for state in ["preview", "report"] {
                if state == "report" { model.start(); await wait(model) }
                for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("mail-mbox-\(state)-\(language.rawValue).png"))
            }
            window.close()
        }
    }

    @Test("Mboxrd round trips original binary octets, quoted From lines and blank endings")
    func mboxOctets() throws {
        for newline in ["\n", "\r\n"] {
            for ending in ["", newline, newline + newline] {
                var raw = Data(("From: sender@example.test" + newline + "Subject: Fixture" + newline + newline
                    + "From body" + newline + ">From quoted" + newline + ">>From nested" + newline).utf8)
                raw.append(contentsOf: [0, 255, 1]); raw.append(Data((newline + ending).utf8))
                let record = try MailMboxCodec.encode(raw, date: nil)
                var decoded: [Data] = []
                try MailMboxCodec.decode(record.data) { _, data in decoded.append(data) }
                #expect(decoded == [raw])
                #expect(record.originalByteCount == raw.count)
                #expect(record.originalSHA256 == SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
            }
        }
        #expect(throws: MailExportError.self) { try MailMboxCodec.encode(Data("Subject: Fixture\n\nNo newline".utf8), date: nil) }
        #expect(throws: MailExportError.self) { try MailMboxCodec.encode(Data("Content-Length: 4\n\nBody\n".utf8), date: nil) }
    }

    @MainActor
    @Test("MBOX export splits only at record boundaries and reports incomplete originals without claiming success")
    func mboxExportFlow() async throws {
        let (queue, mail, first) = try await fixture()
        var second = first; second.id = UUID(); second.uid = 2; second.messageId = "<second@example.test>"
        var missing = first; missing.id = UUID(); missing.uid = 3; missing.messageId = "<missing@example.test>"
        try await mail.upsertMessages([second, missing])
        let raw = original(), other = original("second")
        try await mail.saveRawMessage(id: first.id, raw: .init(data: raw, kind: .received))
        try await mail.saveRawMessage(id: second.id, raw: .init(data: other, kind: .received))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = MailTransferModel(request: .init(content: .messages([first.id, second.id, missing.id])), hub: hub, space: .work)
        model.format = .mbox; model.downloadMissing = false
        model.mboxPartByteLimit = try max(MailMboxCodec.encode(raw, date: nil).data.count, MailMboxCodec.encode(other, date: nil).data.count)
        await model.prepare()
        model.chooseDestination = { _ in .cancelled }; model.start(); await wait(model)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        model.chooseDestination = { _ in .selected(root) }; model.start(); await wait(model)
        #expect(model.error == nil && model.results.count == 3)
        #expect(model.results.map(\.id) == [first.id, second.id, missing.id])
        #expect(model.results[2].file == nil && model.results[2].error != nil)
        let destination = try #require(model.destination)
        for (index, bytes) in [raw, other].enumerated() {
            let file = try #require(model.results[index].file)
            let data = try Data(contentsOf: destination.appendingPathComponent(file))
            var decoded: [Data] = []; try MailMboxCodec.decode(data) { _, record in decoded.append(record) }
            #expect(decoded == [bytes] && data.count <= model.mboxPartByteLimit)
            #expect(model.results[index].originalByteCount == bytes.count)
            #expect(model.results[index].originalSHA256?.count == 64)
        }
        #expect(Set(model.results.compactMap(\.file)).count == 2)
        let report = try JSONDecoder().decode([MailTransferItem].self, from: Data(contentsOf: destination.appendingPathComponent("export-report.json")))
        #expect(report.count == 3 && report[0].originalSHA256 == model.results[0].originalSHA256)
        try await mail.saveRawMessage(id: missing.id, raw: .init(data: original("missing"), kind: .received))
        await model.prepareFailedItems(); model.mboxPartByteLimit = MailService.rawMessageByteLimit
        let retry = root.appendingPathComponent("retry.mbox")
        model.chooseDestination = { _ in .selected(retry) }; model.start(); await wait(model)
        #expect(model.results.count == 1 && model.results.first?.id == missing.id && model.results.first?.file != nil)
        var retried: [Data] = []; try MailMboxCodec.decode(Data(contentsOf: retry)) { _, data in retried.append(data) }
        #expect(retried == [original("missing")])
    }

    @MainActor
    @Test("Cancelling a blocked MBOX download keeps saved parts and marks buffered and pending messages unsaved")
    func mboxCancellation() async throws {
        let (queue, mail, first) = try await fixture()
        var second = first; second.id = UUID(); second.uid = 2; second.messageId = "<second@example.test>"
        var pending = first; pending.id = UUID(); pending.uid = 3; pending.messageId = "<pending@example.test>"
        try await mail.upsertMessages([second, pending])
        let raw = original()
        for id in [first.id, second.id] { try await mail.saveRawMessage(id: id, raw: .init(data: raw, kind: .received)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let client = MockMailClient(hangPoint: .folderStatus)
        let sync = MailSyncService(accountService: .init(databaseQueue: queue, space: .work), mail: mail, space: .work,
            attachmentDirectory: root, clientFactory: { _ in client }, passwordProvider: { _ in "fixture" })
        let model = MailTransferModel(request: .init(content: .messages([first.id, second.id, pending.id])), hub: hub, space: .work)
        model.makeSyncService = { sync }; model.format = .mbox
        model.mboxPartByteLimit = try MailMboxCodec.encode(raw, date: nil).data.count
        await model.prepare(); model.chooseDestination = { _ in .selected(root) }
        model.start()
        for _ in 0..<300 {
            if await client.connectCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.connectCount == 1 && model.progress == 2 && model.busy)
        model.cancel(); await wait(model)
        let diagnostic = String(describing: model.results) + " | " + String(describing: model.error)
        try #require(model.results.count == 3, Comment(rawValue: diagnostic))
        #expect(model.results[0].file != nil)
        #expect(model.results[1].file == nil && model.results[2].file == nil)
        let destination = try #require(model.destination)
        let report = try JSONDecoder().decode([MailTransferItem].self, from: Data(contentsOf: destination.appendingPathComponent("export-report.json")))
        #expect(report.filter { $0.file != nil }.count == 1 && report.filter { $0.error != nil }.count == 2)
        #expect(await client.disconnectCount > 0)
    }

    @MainActor
    @Test("Saving all attachments uses local cache without a part ID, keeps same names, and preserves its manifest")
    func attachmentSaveFlow() async throws {
        let (queue, mail, message) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("work-cache"), exports = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var attachments: [MailAttachment] = []
        for index in 1...2 {
            let part = cache.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: part, withIntermediateDirectories: false)
            let file = part.appendingPathComponent("export-report.json")
            try Data("Attachment \(index)".utf8).write(to: file)
            attachments.append(.init(messageId: message.id, filename: file.lastPathComponent, mimeType: "application/json",
                sizeBytes: 12, localPath: file.path))
        }
        try await mail.saveAttachments(attachments)
        let mock = MockMailClient()
        let sync = MailSyncService(accountService: .init(databaseQueue: queue, space: .work), mail: mail, space: .work,
            attachmentDirectory: cache, clientFactory: { _ in mock }, passwordProvider: { _ in nil })
        let model = MailTransferModel(request: .init(content: .attachments(message.id, attachments.map(\.id))),
            hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        model.makeSyncService = { sync }; model.chooseDestination = { _ in .selected(exports) }
        await model.prepare(); model.start(); await wait(model)
        #expect(model.error == nil && model.results.allSatisfy { $0.error == nil })
        #expect(Set(model.results.compactMap(\.file)).count == 2)
        let destination = try #require(model.destination)
        for (index, result) in model.results.enumerated() {
            let filename = try #require(result.file)
            #expect(filename != "export-report.json")
            #expect(try Data(contentsOf: destination.appendingPathComponent(filename)) == Data("Attachment \(index + 1)".utf8))
        }
        #expect(try JSONDecoder().decode([MailTransferItem].self, from: Data(contentsOf: destination.appendingPathComponent("export-report.json"))).count == 2)
        #expect(await mock.connectCount == 0)
    }

    @MainActor
    @Test("PDF uses native pagination and includes the last line of long mail")
    func paginatedPDF() async throws {
        _ = NSApplication.shared
        let message = MailMessage(accountId: UUID(), folderId: UUID(), uid: 1, subject: "PDF mail fixture", fromAddress: "sender@example.test")
        let body = MailBody(messageId: message.id, textBody: (1...180).map { "Line \($0): retained content." }.joined(separator: "\n"))
        let data = try await MailPDFRenderer().render(message: message, body: body, space: .work)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount > 1)
        #expect(document.string?.contains("PDF mail fixture") == true)
        #expect(document.string?.contains("Line 180") == true)
        if let path = ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] {
            let root = URL(fileURLWithPath: path)
            try data.write(to: root.appendingPathComponent("mail-paginated.pdf"))
            for index in [0, document.pageCount - 1] {
                let image = try #require(document.page(at: index)).thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox)
                let tiff = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: tiff))
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("mail-pdf-page-\(index).png"))
            }
        }
    }
}
