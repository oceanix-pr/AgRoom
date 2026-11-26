import Foundation
import GRDB
import Synchronization

/// Import receipts, source references and extracted versions live in one space.
/// File reads happen before transactions; a preview never expands tool authority.
public final class KnowledgeImportService: Sendable {
    public static let didChange = Notification.Name("agroom.knowledge.importChanged")
    public let space: AppSpace
    private let service: KnowledgeService
    private let extract: @Sendable (KnowledgeFileSnapshot, KnowledgeImportOptions) async throws -> KnowledgeExtraction
    private var queue: DatabaseQueue { service.databaseQueue }
    public func makeJobRunStore() -> ProductJobRunStore { ProductJobRunStore(databaseQueue: queue, space: space) }
    public init(service: KnowledgeService, space: AppSpace) {
        self.service = service; self.space = space
        self.extract = { try await KnowledgeDocumentExtractor.extract($0, options: $1) }
    }
    init(service: KnowledgeService, space: AppSpace,
         extract: @escaping @Sendable (KnowledgeFileSnapshot, KnowledgeImportOptions) async throws -> KnowledgeExtraction) {
        self.service = service; self.space = space; self.extract = extract
    }

    static func createSchema(_ db: Database) throws {
        try db.create(table: "knowledge_revisions", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("itemID", .text).notNull().references("knowledge_items", onDelete: .cascade)
            t.column("createdAt", .datetime).notNull()
            t.column("payload", .blob).notNull()
        }
        try db.create(index: "idx_knowledge_revisions_item", on: "knowledge_revisions", columns: ["itemID", "createdAt"], ifNotExists: true)
        try db.create(table: "knowledge_sources", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("itemID", .text).notNull().references("knowledge_items", onDelete: .cascade)
            t.column("sourceKey", .text).notNull().unique()
            t.column("payload", .blob).notNull()
        }
        try db.create(index: "idx_knowledge_sources_item", on: "knowledge_sources", columns: ["itemID"], ifNotExists: true)
        try db.create(table: "knowledge_import_batches", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("createdAt", .datetime).notNull()
            t.column("payload", .blob).notNull()
        }
        try db.create(table: "knowledge_import_tasks", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("batchID", .text).notNull().references("knowledge_import_batches", onDelete: .cascade)
            t.column("payload", .blob).notNull()
        }
    }

    static func fingerprint(_ item: KnowledgeItem) -> String {
        let values = [item.title, item.content, item.kind.rawValue] + item.tags
        return KnowledgeSourceFile.digest((try? JSONEncoder().encode(values)) ?? Data())
    }

    public func prepare(url: URL, options: KnowledgeImportOptions = .init(), sourceID: UUID? = nil,
                        considering previews: [KnowledgeImportPreview] = []) async throws -> KnowledgeImportPreview {
        try Task.checkCancellation()
        guard previews.allSatisfy({ $0.space == space }) else { throw KnowledgeImportError.permission }
        let space = space
        let extract = extract
        let job = Task.detached {
            let snapshot = try KnowledgeSourceFile.read(url, space: space)
            let extraction: KnowledgeExtraction
            do { extraction = try await extract(snapshot, options) }
            catch OCRService.OCRError.noTextFound { throw KnowledgeImportError.empty }
            catch OCRService.OCRError.cannotLoadImage { throw KnowledgeImportError.unreadable }
            return (snapshot.url, snapshot.data.count, snapshot.hash, extraction)
        }
        let (resolved, size, hash, extraction) = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        try Task.checkCancellation()
        let key = KnowledgeSourceFile.digest(Data(resolved.path.utf8))
        return try await queue.read { db in
            let source: KnowledgeSource?
            if let sourceID { source = try Self.source(sourceID, db: db) }
            else if let data = try Data.fetchOne(db, sql: "SELECT payload FROM knowledge_sources WHERE sourceKey=?", arguments: [key]) { source = try JSONDecoder().decode(KnowledgeSource.self, from: data) }
            else { source = nil }
            if sourceID != nil && source == nil { throw KnowledgeImportError.sourceMissing }
            let existing = try source.flatMap { try KnowledgeItemRow.fetchOne(db, key: $0.itemID.uuidString)?.toItem() }
            let disposition: KnowledgeImportDisposition
            if let source, let existing {
                let imported = try Self.revision(source.importedRevisionID, db: db)
                if imported == nil || Self.fingerprint(existing) != Self.fingerprint(imported!.item) { disposition = .conflict }
                else if source.hash == hash && source.profile == options.identity { disposition = .unchanged }
                else { disposition = .update }
            } else {
                let duplicate = try KnowledgeItemRow.fetchOne(db, sql: "SELECT * FROM knowledge_items WHERE content=? LIMIT 1", arguments: [extraction.content])?.toItem()
                disposition = duplicate == nil && !previews.contains(where: { $0.extraction.content == extraction.content }) ? .new : .duplicate
                let candidate = KnowledgeImportCandidate(path: resolved.path, rootPath: resolved.deletingLastPathComponent().path, size: Int64(size), supported: true)
                return KnowledgeImportPreview(id: candidate.id, space: space, selectedURL: url, candidate: candidate, extraction: extraction, sourceHash: hash,
                    disposition: disposition, source: nil, existingItem: duplicate, expectedContentHash: duplicate.map(Self.fingerprint), options: options)
            }
            let candidate = KnowledgeImportCandidate(path: resolved.path, rootPath: resolved.deletingLastPathComponent().path, size: Int64(size), supported: true)
            return KnowledgeImportPreview(id: candidate.id, space: space, selectedURL: url, candidate: candidate, extraction: extraction, sourceHash: hash,
                disposition: disposition, source: source, existingItem: existing, expectedContentHash: existing.map(Self.fingerprint), options: options)
        }
    }

    public func beginBatch(candidates: [KnowledgeImportCandidate], baseID: UUID?, folderID: UUID?, options: KnowledgeImportOptions) async throws -> KnowledgeImportBatch {
        try Task.checkCancellation()
        guard !candidates.isEmpty, candidates.count <= 50 else { throw KnowledgeImportError.tooLarge }
        var sanitized = candidates
        for index in sanitized.indices {
            sanitized[index].bookmark = nil
            let url = try KnowledgeSourceFile.validatedURL(URL(fileURLWithPath: sanitized[index].path), space: space)
            sanitized[index].path = url.path; sanitized[index].rootPath = url.deletingLastPathComponent().path
        }
        let batch = KnowledgeImportBatch(baseID: baseID, folderID: folderID, options: options, candidates: sanitized)
        try await cancellableWrite { db in
            try KnowledgeService.validateDestination(baseID: baseID, folderID: folderID, db: db)
            try db.execute(sql: "INSERT INTO knowledge_import_batches(id,createdAt,payload) VALUES(?,?,?)", arguments: [batch.id.uuidString, batch.createdAt, try JSONEncoder().encode(batch)])
            for candidate in batch.candidates {
                let task = KnowledgeImportTask(id: candidate.id, batchID: batch.id, candidate: candidate)
                try Self.saveTask(task, db: db)
            }
        }
        await notify()
        return batch
    }

    public func batches(limit: Int = 20) async throws -> [KnowledgeImportBatch] {
        try await queue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM knowledge_import_batches ORDER BY createdAt DESC LIMIT ?", arguments: [min(50, max(1, limit))])
                .map { try JSONDecoder().decode(KnowledgeImportBatch.self, from: $0) }
        }
    }

    public func tasks(batchID: UUID) async throws -> [KnowledgeImportTask] {
        try await queue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM knowledge_import_tasks WHERE batchID=? ORDER BY rowid", arguments: [batchID.uuidString])
                .map { try JSONDecoder().decode(KnowledgeImportTask.self, from: $0) }
        }
    }

    public func setTaskState(id: UUID, state: KnowledgeImportTask.State, error: KnowledgeImportError? = nil) async throws {
        try await cancellableWrite { db in
            guard var task = try Self.task(id, db: db) else { throw KnowledgeImportError.targetMissing }
            guard !task.isFinished else { return }
            task.state = state; task.errorCode = error?.rawValue; task.updatedAt = Date()
            try Self.saveTask(task, db: db)
        }
        await notify()
    }

    /// The receipt and content commit together. Retrying the same task cannot
    /// duplicate an entry, even if cancellation arrived after the actual commit.
    @discardableResult
    public func commit(_ preview: KnowledgeImportPreview, decision: KnowledgeImportDecision, batchID: UUID, taskID: UUID) async throws -> UUID? {
        guard preview.space == space else { throw KnowledgeImportError.permission }
        if let done = try await queue.read({ try Self.task(taskID, db: $0) }), done.isFinished {
            guard done.batchID == batchID else { throw KnowledgeImportError.targetMissing }
            return done.revisionID
        }
        try Task.checkCancellation()
        if decision != .skip {
            let space = space
            let read = Task.detached { try KnowledgeSourceFile.read(preview.selectedURL, space: space) }
            let actual = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
            guard actual.url.path == preview.candidate.path, actual.hash == preview.sourceHash else { throw KnowledgeImportError.changed }
        }
        let cancelled = Mutex(false)
        let result = try await withTaskCancellationHandler {
            try await queue.maintenanceWrite { db -> UUID? in
                guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                guard var task = try Self.task(taskID, db: db), task.batchID == batchID,
                      let batchData = try Data.fetchOne(db, sql: "SELECT payload FROM knowledge_import_batches WHERE id=?", arguments: [batchID.uuidString]) else { throw KnowledgeImportError.targetMissing }
                if task.isFinished { return task.revisionID }
                let batch = try JSONDecoder().decode(KnowledgeImportBatch.self, from: batchData)
                guard batch.options == preview.options, task.candidate.path == preview.candidate.path else { throw KnowledgeImportError.changed }
                if decision == .skip {
                    task.state = .skipped; task.updatedAt = Date(); try Self.saveTask(task, db: db); return nil
                }
                guard preview.extraction.content.utf8.count <= KnowledgeDocumentExtractor.maximumContentBytes,
                      !preview.extraction.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KnowledgeImportError.empty }
                let key = KnowledgeSourceFile.digest(Data(preview.candidate.path.utf8))
                var source = try preview.source.flatMap { try Self.source($0.id, db: db) }
                var item: KnowledgeItem
                var parentID: UUID?
                if decision == .save, let expected = preview.existingItem, preview.source != nil {
                    guard let current = try KnowledgeItemRow.fetchOne(db, key: expected.id.uuidString)?.toItem(),
                          Self.fingerprint(current) == preview.expectedContentHash,
                          source?.importedRevisionID == preview.source?.importedRevisionID else { throw KnowledgeImportError.conflict }
                    item = current
                    parentID = source?.importedRevisionID
                    if let last = parentID.flatMap({ try? Self.revision($0, db: db) }), Self.fingerprint(current) != Self.fingerprint(last.item) {
                        let manual = KnowledgeRevision(item: current, extraction: .init(title: current.title, blocks: [.init(text: current.content)], parser: "user-edit"), origin: "manual", sourceID: source?.id, parentID: parentID)
                        try Self.saveRevision(manual, db: db); parentID = manual.id
                    }
                    item.content = preview.extraction.content; item.updatedAt = Date()
                } else {
                    try KnowledgeService.validateDestination(baseID: batch.baseID, folderID: batch.folderID, db: db)
                    if decision == .save {
                        guard try Data.fetchOne(db, sql: "SELECT payload FROM knowledge_sources WHERE sourceKey=?", arguments: [key]) == nil else { throw KnowledgeImportError.conflict }
                        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_items WHERE content=?", arguments: [preview.extraction.content]) == 0 else { throw KnowledgeImportError.conflict }
                    }
                    item = KnowledgeItem(title: preview.extraction.title, content: preview.extraction.content, baseId: batch.baseID, folderId: batch.folderID)
                    item.sortOrder = try KnowledgeService.nextOrder(in: "knowledge_items", db: db)
                    source = nil
                }
                var row = try KnowledgeItemRow(from: item); try row.save(db)
                let sourceID = source?.id ?? UUID()
                let revision = KnowledgeRevision(item: item, extraction: preview.extraction, origin: "import", sourceID: sourceID,
                    assetHash: preview.sourceHash, parentID: parentID)
                try Self.saveRevision(revision, db: db)
                let canonicalExists = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_sources WHERE sourceKey=?", arguments: [key]) ?? 0) > 0
                let isCopy = source?.key.contains(":copy:") == true || (decision == .copy && (preview.source != nil || canonicalExists))
                let sourceKey = isCopy ? key + ":copy:" + sourceID.uuidString : key
                if let owner = try String.fetchOne(db, sql: "SELECT id FROM knowledge_sources WHERE sourceKey=?", arguments: [sourceKey]), owner != sourceID.uuidString { throw KnowledgeImportError.conflict }
                let updated = KnowledgeSource(id: sourceID, itemID: item.id, key: sourceKey, path: preview.candidate.path,
                    hash: preview.sourceHash, profile: preview.options.identity, importedRevisionID: revision.id, collectionID: nil,
                    missing: false, suppressed: false, updatedAt: Date())
                try db.execute(sql: "INSERT INTO knowledge_sources(id,itemID,sourceKey,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET sourceKey=excluded.sourceKey,payload=excluded.payload", arguments: [updated.id.uuidString, item.id.uuidString, updated.key, try JSONEncoder().encode(updated)])
                task.candidate = preview.candidate; task.candidate.bookmark = nil
                task.state = .committed; task.revisionID = revision.id; task.errorCode = nil; task.updatedAt = Date()
                try Self.saveTask(task, db: db)
                guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                return revision.id
            }
        } onCancel: { cancelled.withLock { $0 = true } }
        await notify()
        return result
    }

    public func sources(itemID: UUID) async throws -> [KnowledgeSource] {
        try await queue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM knowledge_sources WHERE itemID=? LIMIT 100", arguments: [itemID.uuidString])
                .map { try JSONDecoder().decode(KnowledgeSource.self, from: $0) }
        }
    }

    public func revisions(itemID: UUID, limit: Int = 5) async throws -> [KnowledgeRevision] {
        try await queue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM knowledge_revisions WHERE itemID=? ORDER BY createdAt DESC,rowid DESC LIMIT ?", arguments: [itemID.uuidString, min(20, max(1, limit))])
                .map { try JSONDecoder().decode(KnowledgeRevision.self, from: $0) }
        }
    }

    public func checkSource(_ sourceID: UUID) async throws -> KnowledgeSourceStatus {
        try Task.checkCancellation()
        let (source, edited) = try await queue.read { db -> (KnowledgeSource, Bool) in
            guard let source = try Self.source(sourceID, db: db), let current = try KnowledgeItemRow.fetchOne(db, key: source.itemID.uuidString)?.toItem() else { throw KnowledgeImportError.sourceMissing }
            let original = try Self.revision(source.importedRevisionID, db: db)
            return (source, original.map { Self.fingerprint($0.item) != Self.fingerprint(current) } ?? true)
        }
        if source.requiresSelection == true { return KnowledgeSourceStatus(source: source, state: .needsSelection, edited: edited) }
        let space = space
        let read = Task.detached { try KnowledgeSourceFile.read(URL(fileURLWithPath: source.path), space: space).hash }
        let state: KnowledgeSourceStatus.State
        do {
            let hash = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
            state = hash == source.hash ? .current : .changed
        } catch KnowledgeImportError.sourceMissing { state = .missing }
        catch KnowledgeImportError.permission { state = .needsSelection }
        catch is CancellationError { throw CancellationError() }
        catch { state = .failed }
        try Task.checkCancellation()
        try await cancellableWrite { db in
            guard var current = try Self.source(sourceID, db: db), current.importedRevisionID == source.importedRevisionID else { return }
            current.missing = state == .missing
            try db.execute(sql: "UPDATE knowledge_sources SET payload=? WHERE id=?", arguments: [try JSONEncoder().encode(current), sourceID.uuidString])
        }
        return KnowledgeSourceStatus(source: source, state: state, edited: edited)
    }

    public func forgetBatch(_ id: UUID) async throws {
        try await queue.maintenanceWrite { try $0.execute(sql: "DELETE FROM knowledge_import_batches WHERE id=?", arguments: [id.uuidString]) }
        await notify()
    }

    private func cancellableWrite<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await queue.maintenanceWrite { db in
                guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                let result = try updates(db)
                guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                return result
            }
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    private static func task(_ id: UUID, db: Database) throws -> KnowledgeImportTask? {
        try Data.fetchOne(db, sql: "SELECT payload FROM knowledge_import_tasks WHERE id=?", arguments: [id.uuidString]).map { try JSONDecoder().decode(KnowledgeImportTask.self, from: $0) }
    }
    private static func source(_ id: UUID, db: Database) throws -> KnowledgeSource? {
        try Data.fetchOne(db, sql: "SELECT payload FROM knowledge_sources WHERE id=?", arguments: [id.uuidString]).map { try JSONDecoder().decode(KnowledgeSource.self, from: $0) }
    }
    private static func revision(_ id: UUID, db: Database) throws -> KnowledgeRevision? {
        try Data.fetchOne(db, sql: "SELECT payload FROM knowledge_revisions WHERE id=?", arguments: [id.uuidString]).map { try JSONDecoder().decode(KnowledgeRevision.self, from: $0) }
    }
    private static func saveRevision(_ value: KnowledgeRevision, db: Database) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= 16 * 1024 * 1024 else { throw KnowledgeImportError.tooLarge }
        try db.execute(sql: "INSERT INTO knowledge_revisions(id,itemID,createdAt,payload) VALUES(?,?,?,?)", arguments: [value.id.uuidString, value.item.id.uuidString, value.createdAt, payload])
    }
    private static func saveTask(_ value: KnowledgeImportTask, db: Database) throws {
        try db.execute(sql: "INSERT INTO knowledge_import_tasks(id,batchID,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [value.id.uuidString, value.batchID.uuidString, try JSONEncoder().encode(value)])
    }
    private func notify() async { await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: space.rawValue) } }
}
