import CoreGraphics
import CoreText
import Foundation
import GRDB
import ImageIO
import PDFKit
import Synchronization
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Knowledge source import lifecycle")
struct KnowledgeImportLifecycleTests {
    private struct Stack: Sendable {
        let root: URL
        let db: DatabaseQueue
        let knowledge: KnowledgeService
        let imports: KnowledgeImportService
        let jobs: JobCenter
    }
    private func stack(_ space: AppSpace = .work) throws -> Stack {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-import-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db)
        let service = KnowledgeService(databaseQueue: db)
        return .init(root: root, db: db, knowledge: service, imports: KnowledgeImportService(service: service, space: space),
            jobs: JobCenter(historyFileURL: root.appendingPathComponent("jobs.json")))
    }
    private func file(_ text: String, in s: Stack, name: String = "notes.txt") throws -> URL {
        let url = s.root.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    private func save(_ preview: KnowledgeImportPreview, in s: Stack, decision: KnowledgeImportDecision = .save) async throws -> UUID? {
        let batch = try await s.imports.beginBatch(candidates: [preview.candidate], baseID: nil, folderID: nil, options: preview.options)
        return try await s.imports.commit(preview, decision: decision, batchID: batch.id, taskID: preview.candidate.id)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw KnowledgeImportError.timedOut
    }
    private actor ExtractionGate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func pause() async { started = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test("Preview writes no knowledge; duplicates skip, updates preserve location, and source loss retains extracted versions")
    func importUpdateAndLoss() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let url = try file("Release read-only first. Lin finishes on Wednesday.", in: s)
        let preview = try await s.imports.prepare(url: url)
        #expect(preview.disposition == .new && preview.extraction.content.contains("Wednesday"))
        #expect(try await s.knowledge.getAll().isEmpty)
        _ = try await save(preview, in: s)
        let item = try #require(try await s.knowledge.getAll().first)
        let source = try #require(try await s.imports.sources(itemID: item.id).first)
        #expect(try await s.imports.prepare(url: url).disposition == .unchanged)
        let duplicateURL = try file(preview.extraction.content, in: s, name: "duplicate.md")
        let duplicate = try await s.imports.prepare(url: duplicateURL)
        #expect(duplicate.disposition == .duplicate)
        _ = try await save(duplicate, in: s, decision: .skip)
        #expect(try await s.knowledge.getAll().count == 1)
        try Data("The release date is Friday. Confirm the backup first.".utf8).write(to: url)
        #expect(try await s.imports.checkSource(source.id).state == .changed)
        let update = try await s.imports.prepare(url: url)
        #expect(update.disposition == .update)
        let base = KnowledgeBase(name: "Destination"); try await s.knowledge.saveBase(base)
        try await s.knowledge.moveItems([item.id], toBase: base.id, folder: nil)
        _ = try await save(update, in: s)
        let moved = try #require(try await s.knowledge.get(id: item.id))
        #expect(moved.baseId == base.id && moved.content.contains("Friday"))
        try FileManager.default.removeItem(at: url)
        #expect(try await s.imports.checkSource(source.id).state == .missing)
        let versions = try await s.imports.revisions(itemID: item.id)
        #expect(versions.count == 2 && versions.contains { $0.item.content.contains("Wednesday") })
        #expect(try await s.knowledge.get(id: item.id)?.content == moved.content)
        try await s.knowledge.delete(id: item.id)
        #expect(try await s.imports.sources(itemID: item.id).isEmpty)
        #expect(try await s.imports.revisions(itemID: item.id).isEmpty)
    }

    @Test("A preview cannot overwrite later edits; explicit conflict replacement retains edited text as a version")
    func editConflicts() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let url = try file("Source v1", in: s)
        _ = try await save(s.imports.prepare(url: url), in: s)
        var edited = try #require(try await s.knowledge.getAll().first)
        edited.content = "My own edited interpretation"; edited.title = "My title"; edited.tags = ["keep"]
        try await s.knowledge.updateContent(edited)
        try Data("Source v2".utf8).write(to: url)
        let conflict = try await s.imports.prepare(url: url)
        #expect(conflict.disposition == .conflict)
        edited.content = "A later manual edit"; try await s.knowledge.updateContent(edited)
        await #expect(throws: KnowledgeImportError.conflict) { _ = try await save(conflict, in: s) }
        #expect(try await s.knowledge.get(id: edited.id)?.content == edited.content)
        let fresh = try await s.imports.prepare(url: url)
        _ = try await save(fresh, in: s)
        let replaced = try #require(try await s.knowledge.get(id: edited.id))
        #expect(replaced.content == "Source v2" && replaced.title == "My title" && replaced.tags == ["keep"])
        let versions = try await s.imports.revisions(itemID: edited.id)
        #expect(versions.contains { $0.origin == "manual" && $0.item.content == "A later manual edit" })
        #expect(versions.contains { $0.origin == "import" && $0.item.content == "Source v1" })
    }

    @Test("Source changes stop commit; receipts are atomic and idempotent, and preview ownership cannot cross spaces")
    func commitIntegrity() async throws {
        let s = try stack(), other = try stack(.personal)
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: other.root) }
        let url = try file("Actual evidence", in: s)
        let preview = try await s.imports.prepare(url: url)
        let batch = try await s.imports.beginBatch(candidates: [preview.candidate], baseID: nil, folderID: nil, options: preview.options)
        try Data("Changed after preview".utf8).write(to: url)
        await #expect(throws: KnowledgeImportError.changed) { _ = try await s.imports.commit(preview, decision: .save, batchID: batch.id, taskID: preview.id) }
        #expect(try await s.knowledge.getAll().isEmpty)
        await #expect(throws: KnowledgeImportError.permission) { _ = try await other.imports.commit(preview, decision: .copy, batchID: batch.id, taskID: preview.id) }
        try Data("Actual evidence".utf8).write(to: url)
        try await s.db.write { try $0.execute(sql: "CREATE TRIGGER reject_import_receipt BEFORE UPDATE ON knowledge_import_tasks BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        await #expect(throws: (any Error).self) { _ = try await s.imports.commit(preview, decision: .save, batchID: batch.id, taskID: preview.id) }
        #expect(try await s.knowledge.getAll().isEmpty)
        #expect(try await s.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM knowledge_revisions") } == 0)
        try await s.db.write { try $0.execute(sql: "DROP TRIGGER reject_import_receipt") }
        let revision = try await s.imports.commit(preview, decision: .save, batchID: batch.id, taskID: preview.id)
        try FileManager.default.removeItem(at: url)
        #expect(try await s.imports.commit(preview, decision: .save, batchID: batch.id, taskID: preview.id) == revision)
        #expect(try await s.knowledge.getAll().count == 1)
        #expect(try await s.imports.tasks(batchID: batch.id).first?.state == .committed)
        #expect(try await other.knowledge.getAll().isEmpty)
    }

    @Test("Text encoding, source limits and unsafe links fail without creating entries")
    func boundedInputs() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let utf16 = s.root.appendingPathComponent("utf16.txt")
        try #require("中文资料和 UTF-16 编码".data(using: .utf16)).write(to: utf16)
        #expect(try await s.imports.prepare(url: utf16).extraction.content.contains("中文资料"))
        let empty = try file("  \n", in: s, name: "empty.txt")
        await #expect(throws: KnowledgeImportError.empty) { _ = try await s.imports.prepare(url: empty) }
        let huge = try file("", in: s, name: "huge.txt")
        let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: UInt64(KnowledgeSourceFile.maximumBytes + 1)); try handle.close()
        await #expect(throws: KnowledgeImportError.tooLarge) { _ = try await s.imports.prepare(url: huge) }
        let linked = s.root.appendingPathComponent("linked.txt"); try FileManager.default.linkItem(at: utf16, to: linked)
        await #expect(throws: KnowledgeImportError.permission) { _ = try await s.imports.prepare(url: linked) }
        #expect(try await s.knowledge.getAll().isEmpty)
    }

    @Test("Genuine image-only PDF and PNG sources are OCRed locally with page locations, while text-only mode reports no text")
    func scannedPDF() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let width = 1200, height = 600
        let bitmap = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 42, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "AGROOM SOURCE 2048", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        bitmap.textPosition = CGPoint(x: 60, y: 400); CTLineDraw(line, bitmap)
        let image = try #require(bitmap.makeImage()), buffer = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: buffer)), bounds = CGRect(x: 0, y: 0, width: 600, height: 300)
        var box = bounds
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil); pdf.draw(image, in: bounds); pdf.endPDFPage(); pdf.closePDF()
        let url = s.root.appendingPathComponent("scan.pdf"); try (buffer as Data).write(to: url)
        #expect(PDFDocument(data: buffer as Data)?.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        var textOnly = KnowledgeImportOptions(); textOnly.ocr = .textOnly
        await #expect(throws: KnowledgeImportError.empty) { _ = try await s.imports.prepare(url: url, options: textOnly) }
        let result = try await s.imports.prepare(url: url)
        #expect(result.extraction.content.contains("2048"))
        #expect(result.extraction.blocks.first?.location.page == 1 && result.extraction.warnings.contains("ocr:1"))
        let pngURL = s.root.appendingPathComponent("scan.png")
        let destination = try #require(CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let png = try await s.imports.prepare(url: pngURL)
        #expect(png.extraction.content.contains("2048") && png.extraction.warnings == ["ocr"])
        await #expect(throws: KnowledgeImportError.empty) { _ = try await s.imports.prepare(url: pngURL, options: textOnly) }
        #expect(try await s.knowledge.getAll().isEmpty)
        _ = try await save(result, in: s)
        #expect(try await s.knowledge.getAll().first?.content.contains("2048") == true)
    }

    @MainActor @Test("The batch UI model detects internal duplicates before saving and records the selected skip action")
    func batchPreviewAndDecisions() async throws {
        let s = try stack(); defer { try? FileManager.default.removeItem(at: s.root) }
        let first = try file("Same source evidence", in: s, name: "one.txt")
        let second = try file("Same source evidence", in: s, name: "two.md")
        let model = KnowledgeImportModel(service: s.imports, baseID: nil, folderID: nil, jobs: s.jobs)
        model.prepare([first, second])
        try await wait { !model.working && model.rows.count == 2 }
        #expect(model.errorText == nil && model.rows.allSatisfy { $0.state == .ready })
        #expect(model.rows[0].decision == .save && model.rows[1].preview?.disposition == .duplicate && model.rows[1].decision == .skip)
        #expect(try await s.knowledge.getAll().isEmpty)
        var didFinish = false
        model.commit { didFinish = true }
        try await wait { !model.working && didFinish }
        #expect(model.rows[0].state == .saved && model.rows[1].state == .skipped)
        #expect(try await s.knowledge.getAll().count == 1)
        let batch = try #require(model.batch)
        #expect(try await s.imports.tasks(batchID: batch.id).map(\.state) == [.committed, .skipped])
        let jobs = s.jobs.history()
        #expect(Set(jobs.map(\.kind)) == ["knowledge-import-prepare", "knowledge-import-commit"])
        #expect(jobs.allSatisfy { $0.space == .work && $0.origin == "knowledge" && $0.state == .succeeded && $0.progress == 1 })
        let history = try await ProductTaskCenterStore(databaseQueue: s.db, space: .work).page(source: .job)
        #expect(Set(history.items.map(\.sourceID)) == Set(jobs.map(\.id)))
        await model.forget(batch.id)
        #expect(model.rows.isEmpty && model.batch == nil)
        #expect(try await s.knowledge.getAll().count == 1)
        model.cancel()
    }

    @MainActor @Test("Task-center cancellation of a queued import never starts extraction or leaves the preview busy")
    func queuedImportCancellation() async throws {
        let s = try stack(), entered = Mutex(0)
        defer { try? FileManager.default.removeItem(at: s.root) }
        let blockers = (0..<JobCenter.maxConcurrentJobs).map { index in
            s.jobs.submit(name: "Occupied slot \(index)", kind: "fixture", space: .work) { _ in
                entered.withLock { $0 += 1 }
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { for id in blockers { s.jobs.cancel(id: id) } }
        try await wait { entered.withLock { $0 } == JobCenter.maxConcurrentJobs }
        let url = try file("Not extracted while queued", in: s)
        let model = KnowledgeImportModel(service: s.imports, baseID: nil, folderID: nil, jobs: s.jobs)
        model.prepare([url])
        try await wait { model.activeJobID != nil }
        let id = try #require(model.activeJobID)
        #expect(s.jobs.snapshot().first { $0.id == id }?.state == .queued)
        s.jobs.cancel(id: id)
        try await wait { !model.working }
        #expect(model.rows.first?.state == .failed && model.rows.first?.error == L.string("jobs.state.cancelled"))
        #expect(try await s.imports.batches().isEmpty)
        #expect(try await s.knowledge.getAll().isEmpty)
        #expect(try await s.imports.makeJobRunStore().run(id: id)?.state == .cancelled)
        for id in blockers { s.jobs.cancel(id: id) }
        try await wait { blockers.allSatisfy { id in s.jobs.snapshot().contains { $0.id == id && $0.state.isFinished } } }
        model.cancel()
    }

    @MainActor @Test("Failed start receipts prevent import work; saving history never replays extraction")
    func importStartReceiptFailure() async throws {
        let s = try stack(), extracted = Mutex(0)
        defer { try? FileManager.default.removeItem(at: s.root) }
        let url = try file("Not read before a durable receipt", in: s)
        let service = KnowledgeImportService(service: s.knowledge, space: .work) { snapshot, _ in
            extracted.withLock { $0 += 1 }
            return .init(title: "Receipt fixture", blocks: [.init(text: String(decoding: snapshot.data, as: UTF8.self))], parser: "fixture")
        }
        try await s.db.write { try $0.execute(sql: "CREATE TRIGGER reject_import_job_start BEFORE INSERT ON product_job_runs BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        let model = KnowledgeImportModel(service: service, baseID: nil, folderID: nil, jobs: s.jobs)
        model.prepare([url])
        try await wait { !model.working }
        let pending = try #require(s.jobs.snapshot().first)
        #expect(pending.state == .awaitingSave && model.errorText == L.string("jobs.history.failed"))
        #expect(model.rows.first?.state == .failed && extracted.withLock { $0 } == 0)
        #expect(try await s.imports.batches().isEmpty)
        #expect(try await s.knowledge.getAll().isEmpty)
        try await s.db.write { try $0.execute(sql: "DROP TRIGGER reject_import_job_start") }
        #expect(await s.jobs.retryHistoryPersistence(id: pending.id))
        #expect(try await service.makeJobRunStore().run(id: pending.id)?.state == .failed)
        #expect(extracted.withLock { $0 } == 0)
        model.prepare([url])
        try await wait { !model.working }
        #expect(model.rows.first?.state == .ready && extracted.withLock { $0 } == 1)
        #expect(try await s.knowledge.getAll().isEmpty)
        model.cancel()
    }

    @MainActor @Test("Completed knowledge stays saved when the job receipt fails, and history retry does not duplicate it")
    func importTerminalReceiptFailure() async throws {
        let s = try stack(), other = try stack(.personal)
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: other.root) }
        let url = try file("Committed exactly once", in: s)
        let model = KnowledgeImportModel(service: s.imports, baseID: nil, folderID: nil, jobs: s.jobs)
        model.prepare([url]); try await wait { !model.working }
        try await s.db.write { try $0.execute(sql: "CREATE TRIGGER reject_import_job_finish BEFORE UPDATE ON product_job_runs BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        model.commit {}
        try await wait { !model.working }
        let pending = try #require(s.jobs.snapshot().first { $0.kind == "knowledge-import-commit" })
        #expect(pending.state == .awaitingSave && model.errorText == L.string("jobs.history.failed"))
        #expect(model.rows.first?.state == .saved && !model.canCommit)
        let item = try #require(try await s.knowledge.getAll().first)
        #expect(try await s.imports.revisions(itemID: item.id).count == 1)
        try await s.db.write { try $0.execute(sql: "DROP TRIGGER reject_import_job_finish") }
        #expect(await s.jobs.retryHistoryPersistence(id: pending.id))
        #expect(try await s.imports.makeJobRunStore().run(id: pending.id)?.state == .succeeded)
        #expect(try await s.knowledge.getAll().count == 1)
        #expect(try await s.imports.revisions(itemID: item.id).count == 1)
        #expect(try await ProductTaskCenterStore(databaseQueue: other.db, space: .personal).page(source: .job).items.isEmpty)
        model.cancel()
    }

    @MainActor @Test("A repaired source can retry the same failed batch, while closing an immediate retry prevents extraction")
    func repairedSourceRetry() async throws {
        let s = try stack(), extractionCount = Mutex(0)
        defer { try? FileManager.default.removeItem(at: s.root) }
        let url = s.root.appendingPathComponent("repaired.txt")
        let service = KnowledgeImportService(service: s.knowledge, space: .work) { snapshot, _ in
            extractionCount.withLock { $0 += 1 }
            return .init(title: "Repaired", blocks: [.init(text: String(decoding: snapshot.data, as: UTF8.self))], parser: "fixture")
        }
        let model = KnowledgeImportModel(service: service, baseID: nil, folderID: nil, jobs: s.jobs)
        model.prepare([url])
        try await wait { !model.working }
        let row = try #require(model.rows.first), batch = try #require(model.batch)
        #expect(row.state == .failed && row.error != nil)
        #expect(try await service.tasks(batchID: batch.id).first?.state == .failed)
        try Data("Repaired source evidence".utf8).write(to: url)
        model.retry(row.id); model.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(extractionCount.withLock { $0 } == 0 && model.rows.first?.state == .failed)
        #expect(try await s.knowledge.getAll().isEmpty)
        model.appear(); model.retry(row.id)
        try await wait { !model.working }
        #expect(model.rows.first?.state == .ready && model.rows.first?.error == nil)
        #expect(model.batch?.id == batch.id && extractionCount.withLock { $0 } == 1)
        var finished = false
        model.commit { finished = true }
        try await wait { !model.working && finished }
        #expect(try await service.tasks(batchID: batch.id).first?.state == .committed)
        #expect(try await s.knowledge.getAll().map(\.content) == ["Repaired source evidence"])
        model.cancel()
    }

    @MainActor @Test("Closing a suspended extraction cancels its receipt and never saves or updates another space")
    func cancelledPreparation() async throws {
        let s = try stack(), other = try stack(.personal), gate = ExtractionGate()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: other.root) }
        let url = try file("Paused evidence", in: s)
        let service = KnowledgeImportService(service: s.knowledge, space: .work) { snapshot, _ in
            await gate.pause()
            try Task.checkCancellation()
            return .init(title: "Paused", blocks: [.init(text: String(decoding: snapshot.data, as: UTF8.self))], parser: "fixture")
        }
        let model = KnowledgeImportModel(service: service, baseID: nil, folderID: nil, jobs: s.jobs)
        model.prepare([url])
        for _ in 0..<300 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.started)
        let batch = try #require(model.batch)
        model.cancel()
        var receipt: KnowledgeImportTask?
        for _ in 0..<300 {
            receipt = try await service.tasks(batchID: batch.id).first
            if receipt?.state == .cancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(receipt?.state == .cancelled && !model.working)
        await gate.release()
        #expect(try await s.knowledge.getAll().isEmpty)
        #expect(try await other.knowledge.getAll().isEmpty)
    }

    @Test("Source versions and receipts survive portable restore and rollback, while file grants never travel")
    func portableLifecycle() async throws {
        let s = try stack(), target = try stack(.personal)
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: target.root) }
        let url = try file("Portable extracted content", in: s)
        let preview = try await s.imports.prepare(url: url)
        _ = try await save(preview, in: s)
        let item = try #require(try await s.knowledge.getAll().first)
        let source = try #require(try await s.imports.sources(itemID: item.id).first)
        var batch = try #require(try await s.imports.batches().first)
        batch.candidates[0].bookmark = Data("old machine grant must not travel".utf8)
        let changedBatch = batch
        try await s.db.write { db in try db.execute(sql: "UPDATE knowledge_import_batches SET payload=? WHERE id=?", arguments: [try JSONEncoder().encode(changedBatch), changedBatch.id.uuidString]) }
        let archive = try await SpaceDatabaseBackupStore(queue: s.db, space: "work").export()
        #expect(archive.count("knowledge_sources") == 1 && archive.count("knowledge_revisions") == 1)
        let store = SpaceDatabaseBackupStore(queue: target.db, space: "personal")
        let plan = try await store.plan(archive, sourceSpace: "work")
        let applied = try await store.apply(plan, willCommit: { _ in })
        try await store.verify(applied)
        #expect(try await target.knowledge.get(id: item.id)?.content == preview.extraction.content)
        #expect(try await target.imports.revisions(itemID: item.id).first?.blocks.first?.text == preview.extraction.content)
        #expect(try await target.imports.batches().first?.candidates.first?.bookmark == nil)
        #expect(try await target.imports.checkSource(source.id).state == .needsSelection)
        try await store.rollback(applied)
        #expect(try await target.knowledge.getAll().isEmpty)
        #expect(try await target.imports.sources(itemID: item.id).isEmpty)
        #expect(try await s.knowledge.getAll().count == 1)
    }
}
