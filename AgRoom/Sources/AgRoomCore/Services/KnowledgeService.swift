import Foundation
import GRDB

// MARK: - Knowledge Service

/// 知识库服务：绑定单一空间库（空间隔离红线）。
/// 支持分库管理（knowledge_bases）+ 树形文件夹（knowledge_folders）+ 条目归属。
public final class KnowledgeService: @unchecked Sendable {
    // 只供同模块的派生检索服务复用此固定空间连接。
    let databaseQueue: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    /// 建表 + 旧库升级（由 `DatabaseBootstrap` 的迁移器集中调用）。
    /// 顺序关键：先补旧表缺失列，再建新表与索引——
    /// 否则旧库 knowledge_items 缺 baseId 列时建索引失败，整个迁移事务回滚
    static func createSchema(_ database: Database) throws {
        try migrateIfNeeded(database)
        try createTableIfNeeded(database)
    }

    private static func createTableIfNeeded(_ database: Database) throws {
        try database.create(table: "knowledge_bases", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try database.create(table: "knowledge_folders", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("baseId", .text).notNull()
            t.column("parentId", .text)
            t.column("name", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try database.create(index: "idx_knowledge_folders_base", on: "knowledge_folders", columns: ["baseId"], ifNotExists: true)
        try database.create(table: "knowledge_items", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("content", .text).notNull().defaults(to: "")
            t.column("kind", .text).notNull().defaults(to: "document")
            t.column("tagsJSON", .text).notNull().defaults(to: "[]")
            t.column("baseId", .text)
            t.column("folderId", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try database.create(index: "idx_knowledge_kind", on: "knowledge_items", columns: ["kind"], ifNotExists: true)
        try database.create(index: "idx_knowledge_base", on: "knowledge_items", columns: ["baseId"], ifNotExists: true)
        try database.create(index: "idx_knowledge_folder", on: "knowledge_items", columns: ["folderId"], ifNotExists: true)
    }

    /// 旧库迁移：knowledge_items 补缺失列（kind/tagsJSON/baseId/folderId）。
    /// 必须在建索引之前执行——索引引用的列不存在会导致迁移事务整体回滚
    private static func migrateIfNeeded(_ database: Database) throws {
        guard try database.tableExists("knowledge_items") else { return }
        let columns = try database.columns(in: "knowledge_items").map(\.name)
        if !columns.contains("kind") {
            try database.alter(table: "knowledge_items") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "document")
            }
        }
        if !columns.contains("tagsJSON") {
            try database.alter(table: "knowledge_items") { t in
                t.add(column: "tagsJSON", .text).notNull().defaults(to: "[]")
            }
        }
        if !columns.contains("baseId") {
            try database.alter(table: "knowledge_items") { t in
                t.add(column: "baseId", .text)
            }
        }
        if !columns.contains("folderId") {
            try database.alter(table: "knowledge_items") { t in
                t.add(column: "folderId", .text)
            }
        }
    }

    // MARK: - Bases

    public func getBases() async throws -> [KnowledgeBase] {
        try await databaseQueue.read { db in
            try KnowledgeBaseRow
                .order(Column("sortOrder").asc, Column("createdAt").asc, Column("id").asc)
                .fetchAll(db)
                .compactMap { $0.toBase() }
        }
    }

    public func saveBase(_ base: KnowledgeBase) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard !base.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KnowledgeOrganizationError.emptyName
            }
            var row = KnowledgeBaseRow(from: base)
            if try KnowledgeBaseRow.fetchOne(db, key: row.id) == nil {
                row.sortOrder = try Self.nextOrder(in: "knowledge_bases", db: db)
            }
            try row.save(db)
        }
    }

    /// 删除知识库：级联删除其下全部文件夹与条目
    public func deleteBase(id: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            _ = try KnowledgeFolderRow.filter(Column("baseId") == id.uuidString).deleteAll(db)
            _ = try KnowledgeItemRow.filter(Column("baseId") == id.uuidString).deleteAll(db)
            _ = try KnowledgeBaseRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }

    // MARK: - Folders

    public func getFolders(baseId: UUID) async throws -> [KnowledgeFolder] {
        try await databaseQueue.read { db in
            try KnowledgeFolderRow
                .filter(Column("baseId") == baseId.uuidString)
                .order(Column("sortOrder").asc, Column("createdAt").asc, Column("id").asc)
                .fetchAll(db)
                .compactMap { $0.toFolder() }
        }
    }

    public func saveFolder(_ folder: KnowledgeFolder) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try Self.validateFolder(folder, db: db)
            var row = KnowledgeFolderRow(from: folder)
            if let existing = try KnowledgeFolderRow.fetchOne(db, key: row.id) {
                guard existing.baseId == row.baseId else { throw KnowledgeOrganizationError.invalidParent }
                row.sortOrder = existing.sortOrder
            } else {
                row.sortOrder = try Self.nextOrder(in: "knowledge_folders", db: db)
            }
            try row.save(db)
        }
    }

    /// 删除文件夹：级联删除子树内全部文件夹与条目
    public func deleteFolder(id: UUID, keepingContents: Bool = false) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard let folder = try KnowledgeFolderRow.fetchOne(db, key: id.uuidString) else {
                throw KnowledgeOrganizationError.folderMissing
            }
            if keepingContents {
                try Self.promoteContents(of: folder, db: db)
                _ = try KnowledgeFolderRow.deleteOne(db, key: id.uuidString)
                return
            }
            // 收集子树（含自身）
            var toDelete: Set<String> = [id.uuidString]
            var frontier = [id.uuidString]
            while !frontier.isEmpty {
                let children = try KnowledgeFolderRow
                    .filter(frontier.contains(Column("parentId")))
                    .filter(Column("baseId") == folder.baseId)
                    .fetchAll(db)
                    .map(\.id)
                let new = children.filter { !toDelete.contains($0) }
                toDelete.formUnion(new)
                frontier = new
            }
            _ = try KnowledgeItemRow.filter(toDelete.contains(Column("folderId")))
                .filter(Column("baseId") == folder.baseId).deleteAll(db)
            _ = try KnowledgeFolderRow.filter(toDelete.contains(Column("id"))).deleteAll(db)
        }
    }

    // MARK: - Items

    public func save(_ item: KnowledgeItem, allowedBaseIDs: Set<UUID>? = nil) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard WorkspaceKnowledgeSelection.allows(item.baseId, in: allowedBaseIDs) else { throw WorkspaceProjectError.outsideKnowledgeScope }
            try Self.validateDestination(baseID: item.baseId, folderID: item.folderId, db: db)
            var row = try KnowledgeItemRow(from: item)
            if let existing = try KnowledgeItemRow.fetchOne(db, key: row.id) {
                guard WorkspaceKnowledgeSelection.allows(existing.baseId.flatMap(UUID.init(uuidString:)), in: allowedBaseIDs) else { throw WorkspaceProjectError.outsideKnowledgeScope }
                row.sortOrder = existing.sortOrder
            } else {
                row.sortOrder = try Self.nextOrder(in: "knowledge_items", db: db)
            }
            try row.save(db)
        }
    }

    public func get(id: UUID) async throws -> KnowledgeItem? {
        try await databaseQueue.read { db in
            try KnowledgeItemRow.fetchOne(db, key: id.uuidString)?.toItem()
        }
    }

    /// 全部条目（跨库；检索工具与图谱视图用）
    public func getAll() async throws -> [KnowledgeItem] {
        try await databaseQueue.read { db in
            try KnowledgeItemRow
                .order(Column("updatedAt").desc)
                .fetchAll(db)
                .compactMap { $0.toItem() }
        }
    }

    /// 候选检索：按 token 做 LIKE 预筛（标题 / 正文 / 标签任一命中），
    /// 让精排只处理有限候选集，而不是把整库正文读进内存做全表精排。
    /// token 语义与 `KnowledgeRanker` 的「任一 token 命中即候选」保持一致，
    /// 这里只按 updatedAt 截断候选规模。LIKE 通配符按字面转义
    public func searchCandidates(tokens: [String], limit: Int, allowedItemIDs: Set<UUID>? = nil) async throws -> [KnowledgeItem] {
        try await databaseQueue.read { db in
            try Self.searchCandidates(tokens: tokens, limit: limit, allowedItemIDs: allowedItemIDs, in: db)
        }
    }

    static func searchCandidates(tokens: [String], limit: Int, allowedItemIDs: Set<UUID>?, in db: Database) throws -> [KnowledgeItem] {
        let cleaned = Array(Set(tokens.filter { !$0.isEmpty })).sorted().prefix(Self.maxSearchTokens)
        guard !cleaned.isEmpty, limit > 0, allowedItemIDs?.isEmpty != true else { return [] }
        let allowedJSON = try allowedItemIDs.map { ids in
            String(decoding: try JSONEncoder().encode(ids.map(\.uuidString).sorted()), as: UTF8.self)
        }
        let condition = "(title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\' OR tagsJSON LIKE ? ESCAPE '\\')"
        let whereClause = Array(repeating: condition, count: cleaned.count).joined(separator: " OR ")
        var arguments: [any DatabaseValueConvertible] = []
        for token in cleaned {
            let pattern = "%\(SQLikeEscaping.escape(token))%"
            arguments.append(pattern)
            arguments.append(pattern)
            arguments.append(pattern)
        }
        let scope = allowedJSON == nil ? "" : " AND id IN (SELECT value FROM json_each(?))"
        if let allowedJSON { arguments.append(allowedJSON) }
        arguments.append(limit)
        let sql = "SELECT * FROM knowledge_items WHERE (\(whereClause))\(scope) ORDER BY updatedAt DESC LIMIT ?"
        return try KnowledgeItemRow
            .fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            .compactMap { $0.toItem() }
    }

    /// LIKE 预筛的 token 上限：过长查询不至于拼出天量 OR 条件
    static let maxSearchTokens = 24

    /// 指定知识库的全部条目（folderId 为 nil 时取库内全部；非 nil 时取该文件夹直接条目）
    public func getItems(baseId: UUID, folderId: UUID? = nil) async throws -> [KnowledgeItem] {
        try await databaseQueue.read { db in
            var query = KnowledgeItemRow.filter(Column("baseId") == baseId.uuidString)
            if let folderId {
                query = query.filter(Column("folderId") == folderId.uuidString)
            }
            return try query
                .order(Column("updatedAt").desc)
                .fetchAll(db)
                .compactMap { $0.toItem() }
        }
    }

    public func getItems(kind: KnowledgeKind) async throws -> [KnowledgeItem] {
        try await databaseQueue.read { db in
            try KnowledgeItemRow
                .filter(Column("kind") == kind.rawValue)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
                .compactMap { $0.toItem() }
        }
    }

    public func delete(id: UUID, allowedBaseIDs: Set<UUID>? = nil) async throws {
        try await databaseQueue.maintenanceWrite { db in
            if let row = try KnowledgeItemRow.fetchOne(db, key: id.uuidString) {
                guard WorkspaceKnowledgeSelection.allows(row.baseId.flatMap(UUID.init(uuidString:)), in: allowedBaseIDs) else { throw WorkspaceProjectError.outsideKnowledgeScope }
            }
            _ = try KnowledgeItemRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }

    /// 把未归库的旧条目收编进指定知识库（一次性迁移）
    public func adoptOrphans(into baseId: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(
                sql: "UPDATE knowledge_items SET baseId = ? WHERE baseId IS NULL",
                arguments: [baseId.uuidString]
            )
        }
    }
}

// MARK: - Rows

struct KnowledgeBaseRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "knowledge_bases"

    var id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int

    init(from base: KnowledgeBase) {
        self.id = base.id.uuidString
        self.name = base.name
        self.createdAt = base.createdAt
        self.updatedAt = base.updatedAt
        self.sortOrder = base.sortOrder
    }

    func toBase() -> KnowledgeBase? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var base = KnowledgeBase(id: uuid, name: name)
        base.createdAt = createdAt
        base.updatedAt = updatedAt
        base.sortOrder = sortOrder
        return base
    }
}

struct KnowledgeFolderRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "knowledge_folders"

    var id: String
    var baseId: String
    var parentId: String?
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int

    init(from folder: KnowledgeFolder) {
        self.id = folder.id.uuidString
        self.baseId = folder.baseId.uuidString
        self.parentId = folder.parentId?.uuidString
        self.name = folder.name
        self.createdAt = folder.createdAt
        self.updatedAt = folder.updatedAt
        self.sortOrder = folder.sortOrder
    }

    func toFolder() -> KnowledgeFolder? {
        guard let uuid = UUID(uuidString: id),
              let baseUUID = UUID(uuidString: baseId) else { return nil }
        var folder = KnowledgeFolder(
            id: uuid,
            baseId: baseUUID,
            parentId: parentId.flatMap(UUID.init(uuidString:)),
            name: name
        )
        folder.createdAt = createdAt
        folder.updatedAt = updatedAt
        folder.sortOrder = sortOrder
        return folder
    }
}

struct KnowledgeItemRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "knowledge_items"

    var id: String
    var title: String
    var content: String
    var kind: String
    var tagsJSON: String
    var baseId: String?
    var folderId: String?
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int

    init(from item: KnowledgeItem) throws {
        self.id = item.id.uuidString
        self.title = item.title
        self.content = item.content
        self.kind = item.kind.rawValue
        self.baseId = item.baseId?.uuidString
        self.folderId = item.folderId?.uuidString
        self.createdAt = item.createdAt
        self.updatedAt = item.updatedAt
        self.sortOrder = item.sortOrder
        let data = try JSONEncoder().encode(item.tags)
        self.tagsJSON = String(data: data, encoding: .utf8) ?? "[]"
    }

    func toItem() -> KnowledgeItem? {
        guard let uuid = UUID(uuidString: id),
              let kind = KnowledgeKind(rawValue: kind) else { return nil }
        var tags: [String] = []
        if let data = tagsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            tags = decoded
        }
        var item = KnowledgeItem(
            id: uuid,
            title: title,
            content: content,
            kind: kind,
            tags: tags,
            baseId: baseId.flatMap(UUID.init(uuidString:)),
            folderId: folderId.flatMap(UUID.init(uuidString:))
        )
        item.createdAt = createdAt
        item.updatedAt = updatedAt
        item.sortOrder = sortOrder
        return item
    }
}
