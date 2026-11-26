import CryptoKit
import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Mail import folder mapping")
struct MailImportMappingTests {
    private let draft = MailImportArchiveDraft(name: "Mapped archive", inbox: "Inbox", trash: "Trash", archive: "Archive")
    private func service() throws -> (DatabaseQueue, MailService) {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        return (queue, MailService(databaseQueue: queue))
    }
    private func preview(_ folders: [String], sameOriginal: Bool = false) throws -> MailImportPreview {
        var preview = MailImportPreview()
        for (index, folder) in folders.enumerated() {
            let data = try MailSmtpAdapter.serializedMessage(.init(from: .init(name: "", address: "from@example.test"), to: [.init(name: "", address: "to@example.test")],
                subject: "Mapped \(sameOriginal ? 0 : index)", bodyText: "Owned original \(sameOriginal ? 0 : index)", messageId: "<mapping@example.test>"),
                date: Date(timeIntervalSince1970: 1_700_000_000))
            preview.candidates.append(.init(id: UUID(), source: "source-\(index).eml", folder: folder, envelope: try MailFoundationAdapter.importedEnvelope(data),
                data: data, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
            preview.byteCount += data.count
        }
        return preview
    }

    @Test("Review is read-only, creates shared hierarchies only on import, and retains original source identities")
    func reviewedNewArchive() async throws {
        let (queue, mail) = try service(), input = try preview(["Projects/2025", "Projects/2026", "Flat", ""])
        let review = try await mail.reviewImportMapping(input, archiveID: nil, draft: draft,
            rules: [MailImportMappingSource.key("Flat"): .inbox, MailImportMappingSource.key(""): .path("Delivery/2026")])
        #expect(review.isNewArchive && review.rows.count == 4)
        #expect(try await queue.read { try MailAccountRow.fetchCount($0) } == 0)
        #expect(try await queue.read { try MailFolderRow.fetchCount($0) } == 0)
        #expect(try await mail.importBatches(archiveID: review.account.id).isEmpty)
        let batch = try await mail.importMappedMessages(input, review: review)
        #expect(batch.results.allSatisfy { $0.status == .imported })
        let folders = try await mail.folders(accountId: review.account.id)
        #expect(folders.filter { $0.path == "import/Projects" }.count == 1)
        for (index, result) in batch.results.enumerated() {
            let id = try #require(result.messageID), message = try #require(try await mail.message(id: id))
            let actual = try #require(folders.first { $0.id == message.folderId })
            let expected = try #require(review.rows.first { $0.source.source == input.candidates[index].folder })
            #expect(actual.name == expected.path.last)
            #expect(result.originalIdentity?.folder == input.candidates[index].folder)
            #expect(try await mail.rawMessage(id: id)?.data == input.candidates[index].data)
        }
        await #expect(throws: MailImportError.changed) { try await mail.importMappedMessages(input, review: review) }
    }

    @Test("Existing folder rules use real ancestry; duplicate imports do not move old messages or create unused paths")
    func duplicatesAndExisting() async throws {
        let (queue, mail) = try service(), input = try preview(["Original", "Original"], sameOriginal: true)
        let archive = try await mail.createLocalArchive(name: draft.name, inboxName: draft.inbox, trashName: draft.trash, archiveName: draft.archive)
        let parent = MailFolder(accountId: archive.id, path: "parent", name: "Actual parent", isContainer: true)
        let child = MailFolder(accountId: archive.id, path: "parent/child", name: "Actual child", parentPath: parent.path)
        try await queue.write { db in
            var p = MailFolderRow(from: parent); try p.insert(db)
            var c = MailFolderRow(from: child); try c.insert(db)
        }
        let targets = try await mail.importMappingTargets(archiveID: archive.id)
        #expect(targets.choices.first { $0.id == child.id }?.path == [parent.name, child.name])
        #expect(!targets.choices.contains { $0.id == parent.id })
        let review = try await mail.reviewImportMapping(input, archiveID: archive.id, draft: draft,
            rules: [MailImportMappingSource.key("Original"): .existing(child.id)])
        let batch = try await mail.importMappedMessages(input, review: review)
        #expect(batch.results.map(\.status) == [.imported, .duplicate])
        let id = try #require(batch.results[0].messageID)
        #expect(try await mail.message(id: id)?.folderId == child.id)
        let retryReview = try await mail.reviewImportMapping(input, archiveID: archive.id, draft: draft,
            rules: [MailImportMappingSource.key("Original"): .path("Unused/New")])
        let retried = try await mail.importMappedMessages(input, review: retryReview)
        #expect(retried.results.allSatisfy { $0.status == .duplicate && $0.messageID == id })
        #expect(try await mail.message(id: id)?.folderId == child.id)
        #expect(try await mail.folders(accountId: archive.id).allSatisfy { !$0.path.hasPrefix("import/Unused") })
        let undo = try await mail.previewImportUndo(batchID: batch.id, archiveID: archive.id)
        #expect(undo.count == 1)
        #expect(try await mail.undoImport(undo).removed == [id])
    }

    @Test("Stale targets, occupied proposed paths, and foreign queues cannot write an initial batch")
    func staleReviews() async throws {
        let (queue, mail) = try service(), input = try preview([""])
        let archive = try await mail.createLocalArchive(name: draft.name, inboxName: draft.inbox, trashName: draft.trash, archiveName: draft.archive)
        let inbox = try #require(try await mail.folders(accountId: archive.id).first { $0.role == .inbox })
        let review = try await mail.reviewImportMapping(input, archiveID: archive.id, draft: draft, rules: [:])
        try await queue.write { db in try db.execute(sql: "UPDATE mail_folders SET name='Renamed' WHERE id=?", arguments: [inbox.id.uuidString]) }
        await #expect(throws: MailImportError.changed) { try await mail.importMappedMessages(input, review: review) }
        #expect(try await mail.importBatches(archiveID: archive.id).isEmpty)
        let proposed = try await mail.reviewImportMapping(input, archiveID: archive.id, draft: draft,
            rules: [MailImportMappingSource.key(""): .path("Proposed")])
        try await queue.write { db in
            var row = MailFolderRow(from: .init(accountId: archive.id, path: "import/Proposed", name: "Proposed")); try row.insert(db)
        }
        await #expect(throws: MailImportError.changed) { try await mail.importMappedMessages(input, review: proposed) }
        let (other, otherMail) = try service()
        try await other.write { db in var account = MailAccountRow(from: archive); try account.insert(db) }
        await #expect(throws: MailImportError.changed) { try await otherMail.importMappedMessages(input, review: review) }
        #expect(try await otherMail.messageCount(in: .space) == 0)
        #expect(try await mail.messageCount(in: .space) == 0)
    }

    @Test("Review binds the exact selection and content; invalid paths and unselected folder placeholders fail closed")
    func invalidPlans() async throws {
        let (_, mail) = try service(), input = try preview(["Source", "Source"])
        let review = try await mail.reviewImportMapping(input, archiveID: nil, draft: draft, rules: [:])
        var changed = input; changed.candidates.removeLast()
        await #expect(throws: MailImportError.changed) { try await mail.importMappedMessages(changed, review: review) }
        changed = input; changed.candidates[1] = input.candidates[0]
        await #expect(throws: MailImportError.changed) { try await mail.importMappedMessages(changed, review: review) }
        for rule in [MailImportFolderRule.path("../Other"), .path("a//b"), .path(""), .existing(nil)] {
            await #expect(throws: MailImportError.mappingInvalid) {
                try await mail.reviewImportMapping(input, archiveID: nil, draft: draft, rules: [MailImportMappingSource.key("Source"): rule])
            }
        }
        let candidate = input.candidates[0]
        var corrupt = input
        corrupt.candidates[0] = .init(id: candidate.id, source: candidate.source, folder: candidate.folder, envelope: candidate.envelope,
            data: Data(repeating: 0, count: candidate.data.count), sha256: candidate.sha256)
        await #expect(throws: MailImportError.changed) { try await mail.importMappedMessages(corrupt, review: review) }
        #expect(try await mail.messageCount(in: .space) == 0)
    }

    @Test("New archive and initial receipt roll back together when storing the batch fails")
    func atomicInitialReceipt() async throws {
        let (queue, mail) = try service(), input = try preview([""])
        let review = try await mail.reviewImportMapping(input, archiveID: nil, draft: draft, rules: [:])
        try await queue.write { db in
            try db.execute(sql: "CREATE TRIGGER mapping_receipt_failure BEFORE INSERT ON mail_import_batches BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        await #expect(throws: (any Error).self) { try await mail.importMappedMessages(input, review: review) }
        #expect(try await queue.read { try MailAccountRow.fetchCount($0) } == 0)
        #expect(try await queue.read { try MailFolderRow.fetchCount($0) } == 0)
    }

    @Test("A folder created for the first message cannot be silently recreated after deletion during the batch")
    func targetDeletedMidBatch() async throws {
        let (queue, mail) = try service(), input = try preview(["Source", "Source"])
        let review = try await mail.reviewImportMapping(input, archiveID: nil, draft: draft, rules: [:])
        let batch = try await mail.importMappedMessages(input, review: review) { done, _ in
            if done == 1 {
                try? await queue.write { db in try db.execute(sql: "DELETE FROM mail_folders WHERE accountId=? AND path='import/Source'", arguments: [review.account.id.uuidString]) }
            }
        }
        #expect(batch.results[1].status == .failed && batch.results[1].error == .changed)
        #expect(try await mail.folders(accountId: review.account.id).allSatisfy { $0.path != "import/Source" })
    }

    @Test("Cancellation keeps committed mapped mail and a fresh retry only creates the remaining destinations")
    func cancelAndRetry() async throws {
        let (_, mail) = try service(), input = try preview(["A", "B", "B"])
        let review = try await mail.reviewImportMapping(input, archiveID: nil, draft: draft,
            rules: [MailImportMappingSource.key("B"): .path("Later/Delivery")])
        let task = Task {
            try await mail.importMappedMessages(input, review: review) { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let batch = try await task.value
        #expect(batch.state == .cancelled && batch.results.map(\.status) == [.imported, .unprocessed, .unprocessed])
        #expect(try await mail.importBatches(archiveID: batch.accountID).first?.state == .cancelled)
        #expect(try await mail.folders(accountId: batch.accountID).allSatisfy { !$0.path.hasPrefix("import/Later") })
        var remaining = input; remaining.candidates.removeFirst()
        let revised = try await mail.reviewImportMapping(remaining, archiveID: batch.accountID, draft: draft,
            rules: [MailImportMappingSource.key("B"): .path("Later/Delivery")])
        let finished = try await mail.importMappedMessages(remaining, review: revised)
        #expect(finished.results.allSatisfy { $0.status == .imported })
        #expect(try await mail.messageCount(in: .space) == 3)
        let undo = try await mail.previewImportUndo(batchID: batch.id, archiveID: batch.accountID)
        #expect(try await mail.undoImport(undo).removed.count == 1)
        #expect(try await mail.messageCount(in: .space) == 2)
    }

    @Test("Canonically equivalent source folder spellings keep distinct mapping and deduplication identities")
    func exactSourceSpellings() async throws {
        let (_, mail) = try service(), input = try preview(["caf\u{00e9}", "cafe\u{0301}"], sameOriginal: true)
        let review = try await mail.reviewImportMapping(input, archiveID: nil, draft: draft, rules: [:])
        #expect(review.rows.count == 2 && Set(review.rows.map(\.id)).count == 2)
        let batch = try await mail.importMappedMessages(input, review: review)
        #expect(batch.results.allSatisfy { $0.status == .imported })
        #expect(try await mail.folders(accountId: batch.accountID).filter { $0.path.hasPrefix("import/") }.count == 2)
    }

    @MainActor
    @Test("Editing mappings invalidates confirmation immediately; placeholders remain editable, and closing cancels review")
    func mappingModel() async throws {
        let (queue, mail) = try service()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-map-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try preview([""]), source = root.appendingPathComponent("owned.eml")
        try input.candidates[0].data.write(to: source)
        let model = MailImportModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        model.readFiles([source])
        try await wait { !model.busy }
        #expect(model.canStart && model.mappingReview?.isNewArchive == true)
        let key = MailImportMappingSource.key("")
        model.setMappingRule(key, rule: .existing(nil))
        #expect(!model.canStart && model.mappingReview == nil)
        model.start(); #expect(!model.busy)
        await model.refreshMapping()
        #expect(model.mappingError != nil && model.mappingSources.count == 1 && !model.canStart)
        model.setMappingRule(key, rule: .path("Delivery/2026"))
        await model.refreshMapping()
        #expect(model.mappingReview?.rows.first?.path == ["Delivery", "2026"])
        model.start()
        model.setMappingRule(key, rule: .inbox)
        try await wait { !model.busy }
        let batch = try #require(model.batch), id = try #require(batch.results.first?.messageID)
        let folders = try await mail.folders(accountId: batch.accountID)
        #expect(try await mail.message(id: id)?.folderId == folders.first { $0.path == "import/Delivery/2026" }?.id)
        model.close(); model.setMappingRule(key, rule: .path("AfterClose")); await model.refreshMapping(); model.start()
        #expect(model.mappingReview == nil && model.mappingRules.isEmpty && !model.canStart)
        #expect(try await mail.messageCount(in: .space) == 1)
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
