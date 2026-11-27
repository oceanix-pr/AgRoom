import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
import Vision
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
@Suite("Mail import inspection and batch navigation")
struct MailImportReviewTests {
    private struct Fixture {
        let queue: DatabaseQueue
        let mail: MailService
        let hub: Hub
        let archive: MailAccount
        let root: URL
    }
    private func fixture() async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue)
        let archive = try await mail.createLocalArchive(name: "Reviewed archive", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return .init(queue: queue, mail: mail, hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), archive: archive, root: root)
    }
    private func eml(_ text: String = "Original body", subject: String = "Review fixture", attachment: Bool = false) throws -> Data {
        try MailSmtpAdapter.serializedMessage(.init(from: .init(name: "Sender", address: "from@example.test"), to: [.init(name: "Recipient", address: "to@example.test")],
            subject: subject, bodyText: text, messageId: "<reused@example.test>",
            attachments: attachment ? [.init(filename: "交付附件.bin", mimeType: "application/octet-stream", data: Data([0, 255, 2, 3]))] : []), date: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func input(_ f: Fixture, _ values: [Data]) throws -> MailImportPreview {
        let urls = try values.enumerated().map { index, data in
            let file = f.root.appendingPathComponent("source-\(index).eml"); try data.write(to: file); return file
        }
        return try MailImportReader.read(urls)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }

    @Test("Duplicate previews distinguish an earlier candidate from a stored original, and durable links are identity checked")
    func duplicateCorrespondence() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try eml(attachment: true), different = try eml("Same Message-ID, different original")
        let preview = try input(f, [original, original, different])
        let checked = try await f.mail.importPreview(preview, archiveID: f.archive.id)
        #expect(checked.duplicateMatches[preview.candidates[1].id] == .candidate(preview.candidates[0].id))
        #expect(try await f.mail.importBatches(archiveID: f.archive.id).isEmpty)
        let inspection = try MailImportReader.inspect(original)
        #expect(inspection.envelope.to.first?.address == "to@example.test" && inspection.body.textBody?.contains("Original body") == true)
        #expect(inspection.body.attachments.count == 1 && inspection.body.attachments[0].filename == "交付附件.bin")
        let batch = try await f.mail.importMessages(checked, archiveID: f.archive.id)
        let first = try #require(batch.results[0].messageID), duplicate = batch.results[1]
        #expect(duplicate.status == .duplicate && duplicate.messageID == first && duplicate.originalIdentity?.byteCount == original.count)
        let rechecked = try await f.mail.importPreview(preview, archiveID: f.archive.id)
        #expect(rechecked.duplicateMatches[preview.candidates[0].id] == .existing(first))
        let resolved = try await f.mail.importResultMessage(batchID: batch.id, archiveID: f.archive.id, itemID: duplicate.id)
        #expect(resolved.message.id == first && resolved.data == original)
        let archiveFolder = try #require(try await f.mail.folders(accountId: f.archive.id).first { $0.role == .archive })
        try await f.hub.makeMailSyncService(for: .work)?.moveMessage(messageId: first, toFolderId: archiveFolder.id)
        #expect(try await f.mail.importDuplicate(candidate: preview.candidates[0], archiveID: f.archive.id).folder.id == archiveFolder.id)
        let other = try await f.mail.createLocalArchive(name: "Other", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        await #expect(throws: MailImportError.changed) { try await f.mail.importResultMessage(batchID: batch.id, archiveID: other.id, itemID: duplicate.id) }
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        await #expect(throws: MailImportError.changed) { try await MailService(databaseQueue: isolated).importDuplicate(candidate: preview.candidates[0], archiveID: f.archive.id) }
        try await f.mail.saveRawMessage(id: first, raw: .init(data: different, kind: .imported))
        await #expect(throws: MailImportError.changed) { try await f.mail.importResultMessage(batchID: batch.id, archiveID: f.archive.id, itemID: duplicate.id) }
        try await f.mail.deleteMessage(id: first)
        _ = try await f.mail.importMessages(try input(f, [original]), archiveID: f.archive.id)
        await #expect(throws: MailImportError.changed) { try await f.mail.importResultMessage(batchID: batch.id, archiveID: f.archive.id, itemID: duplicate.id) }
    }

    @Test("Batch queries contain only mail actually created by the batch, survive movement and backup, and respect undo")
    func batchQueryAndBackup() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try eml(), later = try eml("Later body")
        let first = try await f.mail.importMessages(input(f, [original]), archiveID: f.archive.id)
        let second = try await f.mail.importMessages(input(f, [original, later, later]), archiveID: f.archive.id)
        let created = try #require(second.results.first { $0.status == .imported }?.messageID)
        let location = MailQueryLocation.importBatch(archiveID: f.archive.id, batchID: second.id)
        #expect(try await f.mail.messageIDs(in: location) == [created])
        let firstID = try #require(first.results.first?.messageID)
        #expect(try await f.mail.importResultMessage(batchID: second.id, archiveID: f.archive.id, itemID: second.results[0].id).message.id == firstID)
        let archiveFolder = try #require(try await f.mail.folders(accountId: f.archive.id).first { $0.role == .archive })
        try await f.hub.makeMailSyncService(for: .work)?.moveMessage(messageId: created, toFolderId: archiveFolder.id)
        #expect(try await f.mail.messageIDs(in: location) == [created])
        let saved = MailSavedSearch(name: "This import", filter: .init(), location: location)
        try await f.mail.saveSearch(saved)
        let backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let restoredQueue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(restoredQueue)
        let store = SpaceDatabaseBackupStore(queue: restoredQueue, space: "work")
        var corrupted = backup
        let tableIndex = try #require(corrupted.tables.firstIndex { $0.name == "mail_import_batches" })
        let payloadIndex = try #require(corrupted.tables[tableIndex].columns.firstIndex(of: "payload"))
        let idIndex = try #require(corrupted.tables[tableIndex].columns.firstIndex(of: "id"))
        let rowIndex = try #require(corrupted.tables[tableIndex].rows.firstIndex { $0[idIndex].string == second.id.uuidString })
        var invalid = second
        invalid.results[0].originalIdentity = .init(folder: "", sha256: "invalid", byteCount: 1)
        corrupted.tables[tableIndex].rows[rowIndex][payloadIndex] = .blob(try JSONEncoder().encode(invalid))
        await #expect(throws: (any Error).self) { try await store.plan(corrupted, sourceSpace: "work") }
        #expect(try await MailService(databaseQueue: restoredQueue).messageCount(in: .space) == 0)
        _ = try await store.apply(store.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        let restored = MailService(databaseQueue: restoredQueue)
        #expect(try await restored.savedSearches().first?.location == location)
        #expect(try await restored.importResultMessage(batchID: second.id, archiveID: f.archive.id, itemID: second.results[2].id).message.id == created)
        let undo = try await restored.previewImportUndo(batchID: second.id, archiveID: f.archive.id)
        _ = try await restored.undoImport(undo)
        #expect(try await restored.messageIDs(in: location).isEmpty)
        #expect(try await restored.importResultMessage(batchID: second.id, archiveID: f.archive.id, itemID: second.results[0].id).message.id == firstID)
        await #expect(throws: MailImportError.changed) { try await restored.importResultMessage(batchID: second.id, archiveID: f.archive.id, itemID: second.results[2].id) }
    }

    @Test("Old receipts remain decodable without invented duplicate links, and the batch index migrates without changing mail")
    func legacyReceiptsAndMigration() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try eml()
        let batch = try await f.mail.importMessages(input(f, [original, original]), archiveID: f.archive.id)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        var rows = try #require(object["results"] as? [[String: Any]])
        for index in rows.indices {
            rows[index]["originalIdentity"] = nil
            if rows[index]["status"] as? String == "duplicate" { rows[index]["messageID"] = nil }
        }
        object["results"] = rows
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MailImportBatch.self, from: old)
        #expect(decoded.results.allSatisfy { $0.originalIdentity == nil })
        try await f.queue.write { db in
            try db.execute(sql: "UPDATE mail_import_batches SET payload=? WHERE id=?", arguments: [old, batch.id.uuidString])
            try db.execute(sql: "DROP INDEX mail_import_origin_batch")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v16_mail_import_review'")
        }
        try DatabaseBootstrap.prepareSpace(f.queue); try DatabaseBootstrap.prepareSpace(f.queue)
        #expect(try await f.mail.importResultMessage(batchID: batch.id, archiveID: f.archive.id, itemID: batch.results[0].id).data == original)
        await #expect(throws: MailImportError.changed) { try await f.mail.importResultMessage(batchID: batch.id, archiveID: f.archive.id, itemID: batch.results[1].id) }
        #expect(try await f.queue.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='mail_import_origin_batch')") } == true)
    }

    @Test("Import review preserves the selection and owned originals, resolves live matches, and filters result statuses")
    func reviewModel() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try eml(attachment: true)
        _ = try await f.mail.importMessages(input(f, [original]), archiveID: f.archive.id)
        let model = MailImportModel(hub: f.hub, space: .work, archiveID: f.archive.id)
        await model.load()
        _ = try input(f, [original, original])
        model.readFiles([f.root.appendingPathComponent("source-0.eml"), f.root.appendingPathComponent("source-1.eml")])
        try await waitUntil { !model.busy }
        let candidate = try #require(model.preview?.candidates.first)
        model.setSelected(candidate.id, selected: false)
        let selection = model.selectedIDs
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("source-0.eml"))
        model.inspectCandidate(candidate.id)
        let inspection = try #require(model.inspection)
        await inspection.load()
        #expect(inspection.content == nil && inspection.error != nil && model.selectedIDs == selection && !inspection.canReveal)
        model.inspectDuplicate(candidate.id)
        let duplicate = try #require(model.inspection)
        await duplicate.load()
        #expect(inspection.content == nil && duplicate.caption.contains(f.archive.displayName) && duplicate.canReveal)
        var opened: UUID?
        model.onRevealMessage = { opened = $0; return true }
        await duplicate.reveal()
        #expect(opened != nil && model.selectedIDs == selection)
        #expect(try await f.mail.messageCount(in: .space) == 1)
        model.dismissInspection(); await model.refreshMapping(); model.start()
        try await waitUntil { !model.busy }
        #expect(model.batch?.results.count == 1 && model.batch?.results.first?.status == .duplicate)
        model.resultStatusFilter = .imported; #expect(model.visibleResults.isEmpty)
        model.resultStatusFilter = .duplicate; #expect(model.visibleResults.count == 1)
        var revealed: MailImportBatchContext?
        model.onRevealBatch = { revealed = $0; return true }
        model.revealBatch(); try await waitUntil { !model.busy }
        #expect(revealed?.id == model.batch?.id && revealed?.accountID == f.archive.id)
        model.cancel()
    }

    @Test("Cancelled inspections discard late source delivery and cancel an in-flight reveal")
    func inspectionCancellation() async throws {
        let data = try eml(), source = MailImportInspectionSource(data: data, caption: "Owned bytes")
        var delivery: CheckedContinuation<MailImportInspectionSource, Error>?
        let pending = MailImportInspectionModel(readSource: { try await withCheckedThrowingContinuation { delivery = $0 } })
        let load = Task { await pending.load() }
        try await waitUntil { delivery != nil }
        pending.cancel(); delivery?.resume(returning: source); await load.value
        #expect(pending.content == nil && pending.error == nil && !pending.isLoading)
        var revealing = false, navigated = false
        let model = MailImportInspectionModel(readSource: { source }, revealSource: {
            revealing = true; try await Task.sleep(for: .seconds(30)); navigated = true
        })
        await model.load()
        let reveal = Task { await model.reveal() }
        try await waitUntil { revealing }
        model.cancel(); await reveal.value
        #expect(!navigated && !model.isRevealing && model.content == nil)
    }

    @Test("Batch navigation pages and exports the entire batch, retains its saved filter, and exits through its account")
    func batchModelPaging() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let values = try (0..<221).map { try eml("Body \($0)", subject: $0 == 50 ? "Needle" : "Bulk \($0)") }
        let batch = try await f.mail.importMessages(input(f, values), archiveID: f.archive.id)
        let ids = Set(batch.results.compactMap(\.messageID))
        let model = MailViewModel(hub: f.hub, space: .work)
        #expect(await model.openImportBatch(archiveID: f.archive.id, batchID: batch.id))
        #expect(model.isImportBatch && model.messages.count == 200 && model.hasMoreMessages && model.coverage == nil)
        #expect(Set(try #require(await model.exportSearchIDs())) == ids)
        await model.loadMoreMessages()
        #expect(model.messages.count == 221 && Set(model.messages.map(\.id)) == ids)
        await model.updateListFilter(.init(query: "Needle"), scope: .importBatch)
        #expect(model.messages.count == 1)
        #expect(await model.saveSearch(name: "Batch needle", filter: model.listFilter, scope: .importBatch))
        let saved = try #require(model.savedSearches.first)
        await model.selectAccount(f.archive.id)
        #expect(!model.isImportBatch && model.importBatchContext == nil && !model.availableSearchScopes.contains(.importBatch))
        #expect(await model.applySearch(saved))
        #expect(model.isImportBatch && model.messages.count == 1 && model.importBatchContext?.id == batch.id)
        #expect(await !model.openImportBatch(archiveID: f.archive.id, batchID: UUID(), isCurrent: { false }))
        #expect(model.messages.count == 1 && model.importBatchContext?.id == batch.id)
        let missing = try #require(model.messages.first?.id)
        await model.selectMessage(missing)
        try await f.mail.deleteMessage(id: missing)
        #expect(await !model.openSearchSource(missing, isCurrent: { true }))
        #expect(model.errorText != nil && model.importBatchContext?.id == batch.id)
        model.cancelPendingWork()
    }

    @Test("Native import preview, matching originals, results and batch navigation work in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeReviewWorkflow() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try eml("Already retained original", subject: "Existing review / 已有邮件")
        let delivery = try eml("New delivery content for inspection", subject: "Delivery review / 交付邮件", attachment: true)
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let archive = try await f.mail.createLocalArchive(name: "Review \(language.rawValue)", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
            _ = try await f.mail.importMessages(input(f, [original]), archiveID: archive.id)
            _ = try input(f, [original, delivery, delivery])
            let model = MailImportModel(hub: f.hub, space: .work, archiveID: archive.id)
            let reader = MailViewModel(hub: f.hub, space: .work)
            model.onImported = { [weak model] accountID in
                if let batch = model?.batch { await reader.openImportBatch(archiveID: accountID, batchID: batch.id) }
            }
            var revealedBatch: UUID?
            model.onRevealBatch = { context in
                revealedBatch = context.id
                return await reader.openImportBatch(archiveID: context.accountID, batchID: context.id)
            }
            await model.load()
            model.readFiles((0..<3).map { f.root.appendingPathComponent("source-\($0).eml") })
            try await waitUntil { !model.busy }
            let selection = model.selectedIDs
            let host = NSHostingView(rootView: MailImportView(model: model).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { model.cancel(); reader.cancelPendingWork(); window.attachedSheet?.close(); window.close() }
            try await layout(window)
            try snapshot(window, directory: directory, name: "mail-import-review-preview-\(language.rawValue)")
            try await press(L.string("mail.import.inspect.action"), in: window, occurrence: 1, minX: 0.55)
            try await waitUntil { model.inspection?.content != nil && window.attachedSheet != nil }
            #expect(model.inspection?.content?.body.attachments.count == 1 && model.inspection?.content?.envelope.subject == "Delivery review / 交付邮件")
            let candidateSheet = try #require(window.attachedSheet)
            try await layout(candidateSheet)
            try snapshot(candidateSheet, directory: directory, name: "mail-import-inspection-\(language.rawValue)")
            try await press(L.format("mail.attachments.count", 1), in: candidateSheet, leadingEdge: true)
            try await layout(candidateSheet)
            #expect(try await renderedText(candidateSheet).contains(".bin"))
            try snapshot(candidateSheet, directory: directory, name: "mail-import-inspection-\(language.rawValue)")
            try await press(L.string("common.close"), in: candidateSheet)
            try await waitUntil { model.inspection == nil && window.attachedSheet == nil }
            try await layout(window)
            try await press(L.string("mail.import.duplicate.inspect"), in: window, minX: 0.55)
            try await waitUntil { model.inspection?.content != nil && window.attachedSheet != nil }
            #expect(model.inspection?.canReveal == true && model.inspection?.caption.contains(archive.displayName) == true)
            let duplicateSheet = try #require(window.attachedSheet)
            try await layout(duplicateSheet)
            try snapshot(duplicateSheet, directory: directory, name: "mail-import-duplicate-\(language.rawValue)")
            try await press(L.string("common.close"), in: duplicateSheet)
            try await waitUntil { model.inspection == nil && window.attachedSheet == nil }
            #expect(model.selectedIDs == selection)
            try await layout(window)
            try await press(L.string("mail.import.start"), in: window, minX: 0.55, maxY: 0.1)
            try await waitUntil { !model.busy && model.batch != nil }
            #expect(model.batch?.results.filter { $0.status == .imported }.count == 1 && reader.isImportBatch && reader.messages.count == 1)
            try await layout(window)
            try snapshot(window, directory: directory, name: "mail-import-review-results-\(language.rawValue)")
            try await press(L.string("mail.import.viewBatch"), in: window)
            try await waitUntil { !model.busy && revealedBatch == model.batch?.id }
            let main = NSHostingView(rootView: MailView(hub: f.hub, viewModel: reader).frame(width: 1100, height: 680).background(Color(nsColor: .windowBackgroundColor)))
            let mailbox = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            mailbox.isReleasedWhenClosed = false; mailbox.contentView = main
            try await layout(mailbox)
            try snapshot(mailbox, directory: directory, name: "mail-import-batch-\(language.rawValue)")
            #expect(reader.queryLocation == .importBatch(archiveID: archive.id, batchID: try #require(model.batch?.id)))
            model.cancel(); reader.cancelPendingWork(); mailbox.close(); window.close()
        }
    }

    @MainActor
    @Test("Native MBOX format choices reread ambiguous originals and preserve the chosen bytes in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeMboxVariants() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let source = f.root.appendingPathComponent("variant.mbox"), body = ">From original quote\nOwned native MBOX body\n"
            let original = Data(("From: sender@example.test\nSubject: Variant native\nContent-Length: \(body.utf8.count)\n\n" + body).utf8)
            try (Data("From sender@example.test Tue Nov 14 22:13:20 2023\n".utf8) + original + Data([10])).write(to: source)
            let model = MailImportModel(hub: f.hub, space: .work, archiveID: f.archive.id)
            let host = NSHostingView(rootView: MailImportView(model: model).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { model.close(); window.close() }
            await model.load(); model.readFiles([source]); try await waitUntil { !model.busy && model.requiresMboxChoice }
            try await layout(window)
            try snapshot(window, directory: directory, name: "mail-mbox-variant-required-\(language.rawValue)")
            try await press(L.string("mail.import.mbox.variant.mboxcl2"), in: window, maxY: 0.95)
            try await waitUntil { !model.busy && model.mboxVariant == .mboxcl2 && model.preview?.candidates.count == 1 }
            let indexed = try #require(model.preview), candidate = try #require(indexed.candidates.first)
            #expect(try await indexed.access.original(candidate.id).data == original)
            #expect(try await f.mail.importBatches(archiveID: f.archive.id).isEmpty)
            try await layout(window)
            try snapshot(window, directory: directory, name: "mail-mbox-variant-preview-\(language.rawValue)")
            try await press(L.string("mail.import.start"), in: window, minX: 0.55, maxY: 0.1)
            try await waitUntil { !model.busy && model.batch != nil }
            let result = try #require(model.batch?.results.first), id = try #require(result.messageID)
            #expect(try await f.mail.rawMessage(id: id)?.data == original)
            try await layout(window)
            try snapshot(window, directory: directory, name: "mail-mbox-variant-results-\(language.rawValue)")
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
            try #require(window.performKeyEquivalent(with: escape))
            #expect(model.preview == nil && model.batch == nil)
        }
    }

    @Test("Native folder mapping exposes invalid rules, refreshes actual targets, and imports to the confirmed folder in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeFolderMapping() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let data = try eml("Mapping native fixture", subject: "Mapping / 文件夹映射")
            _ = try input(f, [data])
            let model = MailImportModel(hub: f.hub, space: .work, archiveID: f.archive.id)
            await model.load(); model.readFiles([f.root.appendingPathComponent("source-0.eml")])
            try await waitUntil { !model.busy && model.canStart }
            let host = NSHostingView(rootView: MailImportView(model: model).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { model.close(); window.close() }
            try await layout(window)
            let editTitle = String(L.string("mail.import.mapping.edit").prefix(language == .english ? 6 : 2))
            try await press(editTitle, in: window, leadingEdge: true)
            try await layout(window)
            try snapshot(window, directory: directory, name: "mail-import-mapping-expanded-\(language.rawValue)")
            try await press(L.string("mail.import.mapping.mode.path"), in: window, minX: 0.45)
            try await waitUntil { !model.mappingBusy && model.mappingError != nil }
            #expect(!model.canStart && model.mappingSources.count == 1)
            try await layout(window)
            try snapshot(window, directory: directory, name: "mail-import-mapping-invalid-\(language.rawValue)")
            try await press(String(L.string("mail.import.mapping.path").prefix(language == .english ? 8 : 2)), in: window)
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("Delivery/2026", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil)
            try await waitUntil { model.canStart && model.mappingReview?.rows.first?.displayPath == "Delivery / 2026" }
            try await layout(window)
            #expect(model.canStart && model.mappingReview?.rows.first?.displayPath == "Delivery / 2026")
            try snapshot(window, directory: directory, name: "mail-import-mapping-preview-\(language.rawValue)")
            try await press(String(L.string("mail.import.mapping.mode.inbox").prefix(language == .english ? 5 : 2)), in: window)
            try await waitUntil { model.canStart && model.mappingReview?.rows.first?.path == ["Inbox"] }
            try await layout(window)
            try await press(editTitle, in: window, leadingEdge: true)
            try await layout(window)
            try await press(L.string("mail.import.start"), in: window, minX: 0.55, maxY: 0.1)
            try await waitUntil { !model.busy && model.batch != nil }
            let id = try #require(model.batch?.results.first?.messageID)
            let folders = try await f.mail.folders(accountId: f.archive.id)
            #expect(try await f.mail.message(id: id)?.folderId == folders.first { $0.role == .inbox }?.id)
            #expect(try await f.mail.rawMessage(id: id)?.data == data)
            #expect(!folders.contains { $0.path.hasPrefix("import/Delivery") })
        }
    }

    private func layout(_ window: NSWindow) async throws {
        for _ in 0..<15 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }

    private func snapshot(_ window: NSWindow, directory: URL, name: String) throws {
        let view = try #require(window.contentView), bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func renderedText(_ window: NSWindow) async throws -> String {
        let view = try #require(window.contentView), bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        return try await Task.detached {
            try autoreleasepool {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]; request.customWords = ["交付附件.bin"]
                try VNImageRequestHandler(data: data).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            }
        }.value
    }

    private func press(_ title: String, in window: NSWindow, occurrence: Int = 0, minX: CGFloat = 0, maxY: CGFloat = 1, leadingEdge: Bool = false) async throws {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:])), language = LanguageManager.shared.activeLanguageCode
        let exactPreview = title == L.string("mail.import.inspect.action")
        let (points, visible) = try await Task.detached { () throws -> ([CGPoint], [String]) in
            try autoreleasepool {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]
                request.customWords = [title]
                try VNImageRequestHandler(data: data).perform([request])
                let observations = request.results ?? []
                let points = observations.compactMap { observation -> CGPoint? in
                  for text in observation.topCandidates(1) {
                    let indices = text.string.indices.filter { !text.string[$0].isWhitespace }
                    let compact = String(indices.map { text.string[$0] }), target = String(title.filter { !$0.isWhitespace })
                    // The import description also contains “Preview” in English.
                    // Only the button's whole label identifies a preview control.
                    if exactPreview && compact.caseInsensitiveCompare(target) != .orderedSame { continue }
                    guard let match = compact.range(of: target, options: [.caseInsensitive, .widthInsensitive]), !match.isEmpty else { continue }
                    let start = compact.distance(from: compact.startIndex, to: match.lowerBound), end = compact.distance(from: compact.startIndex, to: match.upperBound)
                    let range = indices[start]..<text.string.index(after: indices[end - 1])
                    guard let box = try? text.boundingBox(for: range), box.boundingBox.minX >= minX, box.boundingBox.midY <= maxY else { continue }
                    return .init(x: box.boundingBox.midX, y: box.boundingBox.midY)
                  }
                  return nil
                }.sorted { $0.y > $1.y }
                return (points, observations.compactMap { $0.topCandidates(1).first?.string })
            }
        }.value
        try #require(points.indices.contains(occurrence), "Visible control not found: \(title); rendered text: \(visible)")
        let point = points[occurrence]
        let location = view.convert(NSPoint(x: leadingEdge ? 24 : point.x * view.bounds.width,
            y: (view.isFlipped ? 1 - point.y : point.y) * view.bounds.height), to: nil)
        try window.sendTestClick(at: location, matching: title)
    }

}
