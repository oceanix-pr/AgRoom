import Foundation
import GRDB

/// 记忆服务：绑定单一空间库
public final class MemoryService: @unchecked Sendable {
    private let databaseQueue: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
        self.access = .management
    }

    /// 建表（由 `DatabaseBootstrap` 的迁移器集中调用）
    static func createSchema(_ database: Database) throws {
        try database.create(table: "memories", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("content", .text).notNull()
            t.column("category", .text).notNull().defaults(to: MemoryCategory.other.rawValue)
            t.column("sourceSessionID", .text)
            t.column("sourceMessageID", .text)
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("createdAt", .datetime).notNull()
        }
    }

    /// 旧库升级：补 category 列（默认 other = 行为与旧版一致）。
    /// 已建齐的新库此步为 no-op，可安全重复执行
    static func addCategoryColumn(_ database: Database) throws {
        let columns = try Set(database.columns(in: "memories").map(\.name))
        guard !columns.contains("category") else { return }
        try database.alter(table: "memories") { t in
            t.add(column: "category", .text).notNull().defaults(to: MemoryCategory.other.rawValue)
        }
    }

    static func addSourceColumns(_ database: Database) throws {
        let columns = try Set(database.columns(in: "memories").map(\.name))
        try database.alter(table: "memories") { t in
            if !columns.contains("sourceSessionID") { t.add(column: "sourceSessionID", .text) }
            if !columns.contains("sourceMessageID") { t.add(column: "sourceMessageID", .text) }
        }
    }

    public enum StoreError: Error { case stale, invalidScope }

    private enum Access: Sendable { case management, run(UUID?) }
    private let access: Access

    private init(queue: DatabaseQueue, access: Access) {
        self.databaseQueue = queue
        self.access = access
    }

    func forRun(in workspaceID: UUID?) -> MemoryService {
        if case .run(let bound) = access {
            if workspaceID == nil || bound == workspaceID { return self }
            return MemoryService(queue: databaseQueue, access: .run(nil))
        }
        return MemoryService(queue: databaseQueue, access: .run(workspaceID))
    }

    var runWorkspaceID: UUID? {
        if case .run(let id) = access { return id }
        return nil
    }

    private var rows: QueryInterfaceRequest<MemoryRow> {
        if case .run(let id) = access {
            return MemoryRow.filter(Column("workspaceID") == nil || Column("workspaceID") == id?.uuidString)
        }
        return MemoryRow.all()
    }

    static func migrateRecall(_ db: Database) throws {
        try db.alter(table: "memories") { t in
            t.add(column: "revision", .integer).notNull().defaults(to: 0)
            t.add(column: "alwaysInclude", .boolean).notNull().defaults(to: false)
            for name in ["sourceBasis", "sourceQuote", "workspaceID", "supersededID", "normalizedContent"] {
                t.add(column: name, .text)
            }
            t.add(column: "supersededRevision", .integer)
        }
        try db.execute(sql: """
            CREATE INDEX memory_duplicates ON memories(workspaceID, normalizedContent);
            CREATE INDEX memory_recent ON memories(isEnabled, createdAt DESC, id);
            CREATE INDEX memory_pinned ON memories(workspaceID, createdAt DESC, id) WHERE alwaysInclude = 1 AND category = 'preference';
            CREATE INDEX memory_unindexed ON memories(id) WHERE normalizedContent IS NULL;
            CREATE TABLE memory_terms (
                term TEXT NOT NULL, memoryID TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                PRIMARY KEY(term, memoryID)
            ) WITHOUT ROWID;
            CREATE INDEX memory_terms_by_item ON memory_terms(memoryID);
            CREATE TRIGGER memory_text_changed AFTER UPDATE OF content ON memories WHEN OLD.content != NEW.content BEGIN
                UPDATE memories SET normalizedContent = NULL WHERE id = NEW.id;
            END;
            CREATE TABLE memory_extraction_progress (sessionID TEXT PRIMARY KEY NOT NULL, messageID TEXT NOT NULL);
            CREATE TRIGGER memory_forget_cursor AFTER DELETE ON chat_sessions BEGIN
                DELETE FROM memory_extraction_progress WHERE sessionID = OLD.id;
            END;
            """)
        try rebuildPendingIndex(db)
    }

    /// Keep legacy and out-of-band writes searchable. Normal service writes index in the same transaction.
    private static func rebuildPendingIndex(_ db: Database) throws {
        while true {
            let batch = try Row.fetchAll(db, sql: "SELECT id, content FROM memories WHERE normalizedContent IS NULL LIMIT 128")
            if batch.isEmpty { return }
            for row in batch { try index(db, id: row["id"], content: row["content"]) }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func index(_ db: Database, id: String, content: String) throws {
        try db.execute(sql: "DELETE FROM memory_terms WHERE memoryID = ?", arguments: [id])
        let key = normalized(content)
        let insert = try db.cachedStatement(sql: "INSERT INTO memory_terms(term, memoryID) VALUES (?, ?)")
        for term in KnowledgeRanker.tokenize(key) {
            try insert.execute(arguments: [term, id])
        }
        try db.execute(sql: "UPDATE memories SET normalizedContent = ? WHERE id = ?", arguments: [key, id])
    }

    private static func persist(_ item: MemoryItem, in db: Database) throws {
        guard item.revision >= 0, item.revision < Int.max else { throw StoreError.stale }
        var row = MemoryRow(from: item)
        try row.save(db)
        try index(db, id: row.id, content: row.content)
    }

    public func setEnabled(id: UUID, enabled: Bool) async throws {
        try await databaseQueue.maintenanceWrite { db in
            _ = try self.rows.filter(key: id.uuidString).filter(Column("isEnabled") != enabled)
                .updateAll(db, Column("isEnabled").set(to: enabled), Column("revision") += 1)
        }
    }

    public func updateContent(id: UUID, content: String, category: MemoryCategory) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard var item = try self.rows.filter(key: id.uuidString).fetchOne(db)?.toMemory() else { return }
            item.content = content
            item.category = category
            if category != .preference { item.alwaysInclude = false }
            item.revision += 1
            try Self.persist(item, in: db)
        }
    }

    /// Edits never overwrite an intervening correction or recreate a deleted record.
    public func edit(_ item: MemoryItem) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard let current = try self.rows.filter(key: item.id.uuidString).fetchOne(db)?.toMemory(),
                  current.revision == item.revision else { throw StoreError.stale }
            guard self.permits(item.workspaceID) else { throw StoreError.invalidScope }
            var changed = current
            changed.content = item.content
            changed.category = item.category
            changed.isEnabled = item.isEnabled
            changed.workspaceID = item.workspaceID
            changed.alwaysInclude = item.alwaysInclude && item.category == .preference
            guard changed != current else { return }
            changed.revision += 1
            try Self.persist(changed, in: db)
        }
    }

    private func permits(_ scope: UUID?) -> Bool {
        if case .run(let id) = access { return scope == nil || scope == id }
        return true
    }

    public func save(_ item: MemoryItem) async throws {
        guard permits(item.workspaceID) else { throw StoreError.invalidScope }
        try await databaseQueue.maintenanceWrite { db in
            var next = item
            if let current = try MemoryRow.fetchOne(db, key: item.id.uuidString) {
                guard case .management = self.access, current.revision == item.revision, current.revision < Int.max else { throw StoreError.stale }
                next.revision = current.revision + 1
            }
            try Self.persist(next, in: db)
        }
    }

    /// Backup verification and rollback use the revision in the portable image.
    func restore(_ item: MemoryItem) async throws {
        guard case .management = access else { throw StoreError.invalidScope }
        try await databaseQueue.maintenanceWrite { db in try Self.persist(item, in: db) }
    }

    public func getAll() async throws -> [MemoryItem] {
        try await databaseQueue.read { db in
            try self.rows.order(Column("createdAt").desc, Column("id")).fetchAll(db).compactMap { $0.toMemory() }
        }
    }

    public func getEnabled() async throws -> [MemoryItem] {
        try await databaseQueue.read { db in
            try self.rows.filter(Column("isEnabled") == true).order(Column("createdAt").desc, Column("id"))
                .fetchAll(db).compactMap { $0.toMemory() }
        }
    }

    func list(category: MemoryCategory?, includeDisabled: Bool, limit: Int) async throws -> (items: [MemoryItem], total: Int) {
        try await databaseQueue.read { db in
            var request = self.rows
            if !includeDisabled { request = request.filter(Column("isEnabled") == true) }
            if let category { request = request.filter(Column("category") == category.rawValue) }
            let total = try request.fetchCount(db)
            let items = try request.order(Column("createdAt").desc, Column("id")).limit(limit)
                .fetchAll(db).compactMap { $0.toMemory() }
            return (items, total)
        }
    }

    public func delete(id: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            _ = try self.rows.filter(key: id.uuidString).deleteAll(db)
        }
    }

    public func fetch(id: UUID) async throws -> MemoryItem? {
        try await databaseQueue.read { db in try self.rows.filter(key: id.uuidString).fetchOne(db)?.toMemory() }
    }

    /// Both prompt selection and explicit recall rank the same space-local word/bigram index.
    public func search(_ query: String, category: MemoryCategory? = nil, limit: Int = 10,
                       includePinned: Bool = false, includeDisabled: Bool = false) async throws -> [MemoryItem] {
        let phrase = Self.normalized(String(query.prefix(8_000)))
        let single = phrase.count == 1
        let words = single ? [] : Array(KnowledgeRanker.tokenize(phrase).sorted().prefix(96))
        if words.isEmpty && !single && !phrase.isEmpty && !includePinned { return [] }
        let dirty = try await databaseQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memories WHERE normalizedContent IS NULL)") == true
        }
        if dirty { try await databaseQueue.maintenanceWrite { db in try Self.rebuildPendingIndex(db) } }
        return try await databaseQueue.read { db in
            var arguments = StatementArguments(words)
            var sql: String
            if !words.isEmpty {
                let slots = Array(repeating: "?", count: words.count).joined(separator: ",")
                sql = """
                    WITH hits AS (
                        SELECT memoryID, SUM(MIN(12, length(term))) AS score FROM memory_terms
                        WHERE term IN (\(slots)) GROUP BY memoryID
                    ), candidates AS (
                        SELECT m.*, h.score FROM hits h JOIN memories m ON m.id = h.memoryID
                    """
                if includePinned {
                    sql += " UNION ALL SELECT m.*, 0 FROM memories m WHERE m.alwaysInclude = 1 AND m.category = 'preference' AND NOT EXISTS(SELECT 1 FROM hits h WHERE h.memoryID = m.id)"
                }
                sql += ") SELECT * FROM candidates WHERE 1"
            } else if single {
                sql = "SELECT *, instr(normalizedContent, ?) > 0 AS score FROM memories WHERE (instr(normalizedContent, ?) > 0"
                arguments += [phrase, phrase]
                if includePinned { sql += " OR (alwaysInclude = 1 AND category = 'preference')" }
                sql += ")"
            } else {
                sql = "SELECT *, 0 AS score FROM memories WHERE 1"
                if includePinned || !phrase.isEmpty { sql += " AND alwaysInclude = 1 AND category = 'preference'" }
            }
            if !includeDisabled { sql += " AND isEnabled = 1" }
            if case .run(let id) = self.access {
                sql += " AND (workspaceID IS NULL OR workspaceID = ?)"
                arguments += [id?.uuidString]
            }
            if let category {
                sql += " AND category = ?"
                arguments += [category.rawValue]
            }
            sql += " ORDER BY "
            if includePinned { sql += "(alwaysInclude = 1 AND category = 'preference') DESC, " }
            sql += "score DESC, (workspaceID IS NOT NULL) DESC, createdAt DESC, id LIMIT ?"
            arguments += [max(0, limit)]
            return try MemoryRow.fetchAll(db, sql: sql, arguments: arguments).compactMap { $0.toMemory() }
        }
    }

    public func extractionCursor(sessionID: UUID) async throws -> UUID? {
        try await databaseQueue.read { db in try Self.cursor(db, sessionID: sessionID) }
    }

    private static func cursor(_ db: Database, sessionID: UUID) throws -> UUID? {
        try String.fetchOne(db, sql: "SELECT messageID FROM memory_extraction_progress WHERE sessionID = ?", arguments: [sessionID.uuidString]).flatMap(UUID.init(uuidString:))
    }

    func accepts(_ checkpoint: MemoryExtractionCheckpoint) async throws -> Bool {
        try await databaseQueue.read { db in try Self.accepts(checkpoint, in: db) }
    }

    private static func accepts(_ checkpoint: MemoryExtractionCheckpoint, in db: Database) throws -> Bool {
        let eligible = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM chat_sessions WHERE id = ? AND dataPolicy != ? AND permissionMode != ?)
            """, arguments: [checkpoint.sessionID.uuidString, TaskDataPolicy.localOnly.rawValue, PermissionMode.readOnly.rawValue])
        guard eligible == true else { return false }
        return try cursor(db, sessionID: checkpoint.sessionID) == checkpoint.after
    }

    /// One maintenance transaction owns duplicate detection, replacements, inserts and the checkpoint.
    func commitExtraction(_ drafts: [MemoryItem], checkpoint: MemoryExtractionCheckpoint?) async throws -> [MemoryItem] {
        try await databaseQueue.maintenanceWrite { db in
            if let checkpoint, try !Self.accepts(checkpoint, in: db) { return [] }
            try Self.rebuildPendingIndex(db)
            var saved: [MemoryItem] = []
            for var draft in drafts {
                try Task.checkCancellation()
                guard self.permits(draft.workspaceID) else { throw StoreError.invalidScope }
                let key = Self.normalized(draft.content)
                let duplicate = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memories WHERE workspaceID IS ? AND normalizedContent = ?)",
                                                  arguments: [draft.workspaceID?.uuidString, key])
                guard !key.isEmpty, duplicate != true else { continue }
                if let replacement = draft.supersedes {
                    // Only an explicit correction can supersede an untouched extraction in the same scope.
                    guard let old = try MemoryRow.fetchOne(db, key: replacement.id.uuidString),
                          draft.sourceBasis == .stated, old.sourceBasis != nil, !old.alwaysInclude, old.isEnabled,
                          old.workspaceID == draft.workspaceID?.uuidString, old.revision == replacement.revision,
                          old.revision == 0 else { continue }
                    try db.execute(sql: "UPDATE memories SET isEnabled = 0, revision = revision + 1 WHERE id = ?", arguments: [old.id])
                    draft.supersedes = MemorySupersession(id: replacement.id, revision: old.revision + 1)
                }
                try Self.persist(draft, in: db)
                saved.append(draft)
                if saved.count == MemoryDistiller.maxItemsPerRun { break }
            }
            try Task.checkCancellation()
            if let checkpoint {
                try db.execute(sql: """
                    INSERT INTO memory_extraction_progress(sessionID, messageID) VALUES (?, ?)
                    ON CONFLICT(sessionID) DO UPDATE SET messageID = excluded.messageID
                    """, arguments: [checkpoint.sessionID.uuidString, checkpoint.through.uuidString])
            }
            return saved
        }
    }

    public func undoExtraction(_ items: [MemoryItem]) async throws -> Int {
        try await databaseQueue.maintenanceWrite { db in
            var count = 0
            for item in items {
                let row = self.rows.filter(key: item.id.uuidString)
                guard let current = try row.fetchOne(db)?.toMemory(), current.isEnabled, current.revision == item.revision,
                      current.content == item.content, current.category == item.category, current.workspaceID == item.workspaceID,
                      current.alwaysInclude == item.alwaysInclude, current.sourceMessageID == item.sourceMessageID else { continue }
                _ = try row.updateAll(db, Column("isEnabled").set(to: false), Column("revision") += 1)
                count += 1
                if let old = current.supersedes {
                    _ = try self.rows.filter(key: old.id.uuidString).filter(Column("revision") == old.revision && Column("isEnabled") == false)
                        .updateAll(db, Column("isEnabled").set(to: true), Column("revision") += 1)
                }
            }
            return count
        }
    }
}

private struct MemoryRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "memories"

    var id: String
    var content: String
    var category: String
    var sourceSessionID: String?
    var sourceMessageID: String?
    var isEnabled: Bool
    var createdAt: Date
    var revision: Int
    var alwaysInclude: Bool
    var workspaceID: String?
    var sourceBasis: String?
    var sourceQuote: String?
    var supersededID: String?
    var supersededRevision: Int?

    init(from item: MemoryItem) {
        revision = item.revision
        alwaysInclude = item.alwaysInclude
        workspaceID = item.workspaceID?.uuidString
        sourceBasis = item.sourceBasis?.rawValue
        sourceQuote = item.sourceQuote
        supersededID = item.supersedes?.id.uuidString
        supersededRevision = item.supersedes?.revision
        self.id = item.id.uuidString
        self.content = item.content
        self.category = item.category.rawValue
        self.sourceSessionID = item.sourceSessionID?.uuidString
        self.sourceMessageID = item.sourceMessageID?.uuidString
        self.isEnabled = item.isEnabled
        self.createdAt = item.createdAt
    }

    func toMemory() -> MemoryItem? {
        let project = workspaceID.flatMap(UUID.init(uuidString:))
        guard let uuid = UUID(uuidString: id), workspaceID == nil || project != nil,
              revision >= 0, revision < Int.max else { return nil }
        var item = MemoryItem(
            id: uuid,
            content: content,
            // 未知/空取值回退 other，避免旧数据或手改库导致整条记忆丢失
            category: MemoryCategory(rawValue: category) ?? .other,
            isEnabled: isEnabled
        )
        item.revision = revision
        item.alwaysInclude = alwaysInclude
        item.workspaceID = project
        item.sourceBasis = sourceBasis.flatMap(MemorySourceBasis.init(rawValue:))
        item.sourceQuote = sourceQuote
        if let id = supersededID.flatMap(UUID.init(uuidString:)), let revision = supersededRevision {
            item.supersedes = MemorySupersession(id: id, revision: revision)
        }
        item.createdAt = createdAt
        item.sourceSessionID = sourceSessionID.flatMap(UUID.init(uuidString:))
        item.sourceMessageID = sourceMessageID.flatMap(UUID.init(uuidString:))
        return item
    }
}
