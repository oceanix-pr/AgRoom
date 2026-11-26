import Foundation
import GRDB

extension KnowledgeService {
    static func addHierarchyColumns(_ db: Database) throws {
        for table in ["knowledge_bases", "knowledge_folders", "knowledge_items"] {
            if try !db.columns(in: table).contains(where: { $0.name == "sortOrder" }) {
                try db.alter(table: table) { $0.add(column: "sortOrder", .integer).notNull().defaults(to: 0) }
            }
        }
        try db.create(index: "idx_knowledge_folder_tree", on: "knowledge_folders",
                      columns: ["baseId", "parentId", "sortOrder"], ifNotExists: true)
        try db.create(index: "idx_knowledge_item_tree", on: "knowledge_items",
                      columns: ["baseId", "folderId", "sortOrder"], ifNotExists: true)
    }

    /// 读取同一空间的一致快照，SQLite 只返回正文前缀，不加载整库正文。
    public func browserSnapshot() async throws -> KnowledgeBrowserSnapshot {
        try await databaseQueue.read { db in
            let bases = try KnowledgeBaseRow.order(Column("sortOrder"), Column("createdAt"), Column("id"))
                .fetchAll(db).compactMap { $0.toBase() }
            let folders = try KnowledgeFolderRow.order(Column("sortOrder"), Column("createdAt"), Column("id"))
                .fetchAll(db).compactMap { $0.toFolder() }
            let summaries = try KnowledgeItemRow.fetchAll(db, sql: """
                SELECT id, title, substr(content, 1, 160) AS content, kind, tagsJSON,
                       baseId, folderId, createdAt, updatedAt, sortOrder
                FROM knowledge_items ORDER BY sortOrder, createdAt, id
                """).compactMap { $0.toItem().map(KnowledgeItemSummary.init) }
            return KnowledgeBrowserSnapshot(bases: bases, folders: folders, items: summaries)
        }
    }

    /// Resolve scope using only hierarchy metadata and item identities. Keep legacy orphan/cycle handling
    /// consistent with the browser's tree when the requested folder includes descendants.
    func scopedItemIDs(_ scope: KnowledgeSearchScope, limitedTo allowed: Set<UUID>?) async throws -> Set<UUID>? {
        guard scope != .all else { return allowed }
        return try await databaseQueue.read { db in
            try Self.scopedItemIDs(scope, limitedTo: allowed, in: db)
        }
    }

    static func scopedItemIDs(_ scope: KnowledgeSearchScope, limitedTo allowed: Set<UUID>?, in db: Database) throws -> Set<UUID>? {
        var predicate: String
        var args: StatementArguments = []
        switch scope {
        case .all: return allowed
        case .unfiled:
            predicate = "NOT EXISTS (SELECT 1 FROM knowledge_bases b WHERE b.id = knowledge_items.baseId)"
        case .base(let id):
            guard try KnowledgeBaseRow.exists(db, key: id.uuidString) else { throw KnowledgeOrganizationError.baseMissing }
            predicate = "baseId = ?"
            args += [id.uuidString]
        case .folder(let id, let recursive):
            guard let folder = try KnowledgeFolderRow.fetchOne(db, key: id.uuidString)?.toFolder() else {
                throw KnowledgeOrganizationError.folderMissing
            }
            var ids: Set<UUID> = [id]
            if recursive {
                let folders = try KnowledgeFolderRow.filter(Column("baseId") == folder.baseId.uuidString)
                    .fetchAll(db).compactMap { $0.toFolder() }
                ids = KnowledgeBrowserSnapshot(folders: folders).descendantIDs(of: id)
            }
            predicate = "baseId = ? AND folderId IN (SELECT value FROM json_each(?))"
            args += [folder.baseId.uuidString, String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)]
        }
        if let allowed {
            predicate += " AND id IN (SELECT value FROM json_each(?))"
            args += [String(decoding: try JSONEncoder().encode(allowed), as: UTF8.self)]
        }
        let ids = try String.fetchAll(db, sql: "SELECT id FROM knowledge_items WHERE " + predicate, arguments: args)
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }

    /// 编辑正文只更新内容列，避免过期编辑表单撤销刚完成的目录移动或复活已删条目。
    public func updateContent(_ item: KnowledgeItem) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard try KnowledgeItemRow.fetchOne(db, key: item.id.uuidString) != nil else {
                throw KnowledgeOrganizationError.itemMissing
            }
            let tags = String(decoding: try JSONEncoder().encode(item.tags), as: UTF8.self)
            try db.execute(sql: """
                UPDATE knowledge_items SET title = ?, content = ?, kind = ?, tagsJSON = ?, updatedAt = ? WHERE id = ?
                """, arguments: [item.title, item.content, item.kind.rawValue, tags, Date(), item.id.uuidString])
        }
    }

    public func renameBase(id: UUID, name: String) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KnowledgeOrganizationError.emptyName }
            guard try KnowledgeBaseRow.fetchOne(db, key: id.uuidString) != nil else { throw KnowledgeOrganizationError.baseMissing }
            try db.execute(sql: "UPDATE knowledge_bases SET name = ?, updatedAt = ? WHERE id = ?", arguments: [name, Date(), id.uuidString])
        }
    }

    public func renameFolder(id: UUID, name: String) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard let row = try KnowledgeFolderRow.fetchOne(db, key: id.uuidString), var folder = row.toFolder() else {
                throw KnowledgeOrganizationError.folderMissing
            }
            folder.name = name
            try Self.validateFolder(folder, db: db)
            try db.execute(sql: "UPDATE knowledge_folders SET name = ?, updatedAt = ? WHERE id = ?", arguments: [name, Date(), id.uuidString])
        }
    }

    public func getItems(ids: Set<UUID>) async throws -> [KnowledgeItem] {
        guard !ids.isEmpty else { return [] }
        let json = Self.idJSON(ids)
        return try await databaseQueue.read { db in
            try KnowledgeItemRow.fetchAll(db, sql: """
                SELECT * FROM knowledge_items WHERE id IN (SELECT value FROM json_each(?)) ORDER BY sortOrder, createdAt, id
                """, arguments: [json]).compactMap { $0.toItem() }
        }
    }

    /// 跨库移动仍限于此服务固定的空间连接；整个子树与条目归属一次提交。
    public func moveItems(_ ids: [UUID], toBase baseID: UUID?, folder folderID: UUID?) async throws {
        var seen = Set<UUID>()
        let ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        try await databaseQueue.maintenanceWrite { db in
            try Self.validateDestination(baseID: baseID, folderID: folderID, db: db)
            let found = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_items WHERE id IN (SELECT value FROM json_each(?))",
                                        arguments: [Self.idJSON(Set(ids))]) ?? 0
            guard found == ids.count else { throw KnowledgeOrganizationError.itemMissing }
            var order = try Self.nextOrder(in: "knowledge_items", db: db)
            for id in ids {
                try db.execute(sql: "UPDATE knowledge_items SET baseId = ?, folderId = ?, sortOrder = ? WHERE id = ?",
                               arguments: [baseID?.uuidString, folderID?.uuidString, order, id.uuidString])
                order += 1
            }
        }
    }

    public func move(_ node: KnowledgeNodeID, toBase baseID: UUID?, folder folderID: UUID?) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try Self.validateDestination(baseID: baseID, folderID: folderID, db: db)
            switch node {
            case .base:
                throw KnowledgeOrganizationError.invalidParent
            case .item(let id):
                guard try KnowledgeItemRow.fetchOne(db, key: id.uuidString) != nil else {
                    throw KnowledgeOrganizationError.itemMissing
                }
                try db.execute(sql: "UPDATE knowledge_items SET baseId = ?, folderId = ?, sortOrder = ? WHERE id = ?",
                               arguments: [baseID?.uuidString, folderID?.uuidString,
                                           try Self.nextOrder(in: "knowledge_items", db: db), id.uuidString])
            case .folder(let id):
                guard let baseID else { throw KnowledgeOrganizationError.invalidParent }
                guard let row = try KnowledgeFolderRow.fetchOne(db, key: id.uuidString), var folder = row.toFolder() else {
                    throw KnowledgeOrganizationError.folderMissing
                }
                let folders = try KnowledgeFolderRow.fetchAll(db).compactMap { $0.toFolder() }
                let snapshot = KnowledgeBrowserSnapshot(folders: folders)
                let subtree = snapshot.descendantIDs(of: id)
                guard folderID.map({ !subtree.contains($0) }) ?? true else { throw KnowledgeOrganizationError.cycle }
                folder.baseId = baseID
                folder.parentId = folderID
                try Self.validateFolder(folder, db: db)
                let ids = Self.idJSON(subtree)
                try db.execute(sql: "UPDATE knowledge_folders SET baseId = ? WHERE id IN (SELECT value FROM json_each(?))",
                               arguments: [baseID.uuidString, ids])
                try db.execute(sql: "UPDATE knowledge_items SET baseId = ? WHERE folderId IN (SELECT value FROM json_each(?))",
                               arguments: [baseID.uuidString, ids])
                try db.execute(sql: "UPDATE knowledge_folders SET parentId = ?, sortOrder = ?, updatedAt = ? WHERE id = ?",
                               arguments: [folderID?.uuidString, try Self.nextOrder(in: "knowledge_folders", db: db), Date(), id.uuidString])
            }
        }
    }

    /// 在同类兄弟节点中调整位置；写事务重新读取顺序，避免并发拖动覆盖过期列表。
    public func reorder(_ node: KnowledgeNodeID, earlier: Bool) async throws {
        try await databaseQueue.maintenanceWrite { db in
            let table: String
            let id: UUID
            let predicate: String
            let scope: StatementArguments
            switch node {
            case .base(let value):
                table = "knowledge_bases"; id = value; predicate = "1"; scope = []
            case .folder(let value):
                guard let folder = try KnowledgeFolderRow.fetchOne(db, key: value.uuidString) else {
                    throw KnowledgeOrganizationError.folderMissing
                }
                table = "knowledge_folders"; id = value
                predicate = "baseId = ? AND parentId IS ?"; scope = [folder.baseId, folder.parentId]
            case .item(let value):
                guard let item = try KnowledgeItemRow.fetchOne(db, key: value.uuidString) else {
                    throw KnowledgeOrganizationError.itemMissing
                }
                table = "knowledge_items"; id = value
                predicate = "baseId IS ? AND folderId IS ?"; scope = [item.baseId, item.folderId]
            }
            // table 与 predicate 只来自上面的固定枚举分支，不接受外部 SQL 标识符。
            var ids = try String.fetchAll(db, sql: "SELECT id FROM \(table) WHERE \(predicate) ORDER BY sortOrder, createdAt, id", arguments: scope)
            guard let index = ids.firstIndex(of: id.uuidString) else { throw KnowledgeOrganizationError.baseMissing }
            let target = earlier ? index - 1 : index + 1
            guard ids.indices.contains(target) else { return }
            ids.swapAt(index, target)
            for (position, key) in ids.enumerated() {
                try db.execute(sql: "UPDATE \(table) SET sortOrder = ? WHERE id = ?", arguments: [position, key])
            }
        }
    }

    static func validateDestination(baseID: UUID?, folderID: UUID?, db: Database) throws {
        if let baseID, try KnowledgeBaseRow.fetchOne(db, key: baseID.uuidString) == nil {
            throw KnowledgeOrganizationError.baseMissing
        }
        if let folderID {
            guard let folder = try KnowledgeFolderRow.fetchOne(db, key: folderID.uuidString) else {
                throw KnowledgeOrganizationError.folderMissing
            }
            guard folder.baseId == baseID?.uuidString else { throw KnowledgeOrganizationError.invalidParent }
        }
    }

    static func validateFolder(_ folder: KnowledgeFolder, db: Database) throws {
        guard !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeOrganizationError.emptyName
        }
        try validateDestination(baseID: folder.baseId, folderID: folder.parentId, db: db)
        var seen: Set<String> = [folder.id.uuidString]
        var cursor = folder.parentId?.uuidString
        while let id = cursor {
            guard seen.insert(id).inserted else { throw KnowledgeOrganizationError.cycle }
            guard let ancestor = try KnowledgeFolderRow.fetchOne(db, key: id) else { throw KnowledgeOrganizationError.folderMissing }
            guard ancestor.baseId == folder.baseId.uuidString else { throw KnowledgeOrganizationError.invalidParent }
            cursor = ancestor.parentId
        }
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM knowledge_folders
                WHERE baseId = ? AND parentId IS ? AND name = ? COLLATE NOCASE AND id != ?)
            """, arguments: [folder.baseId.uuidString, folder.parentId?.uuidString, folder.name, folder.id.uuidString]) == true {
            throw KnowledgeOrganizationError.duplicateFolder
        }
    }

    static func promoteContents(of folder: KnowledgeFolderRow, db: Database) throws {
        let children = try KnowledgeFolderRow.filter(Column("parentId") == folder.id)
            .filter(Column("baseId") == folder.baseId).fetchAll(db)
        for child in children {
            guard var value = child.toFolder() else { continue }
            value.parentId = folder.parentId.flatMap(UUID.init(uuidString:))
            try validateFolder(value, db: db)
            try db.execute(sql: "UPDATE knowledge_folders SET parentId = ?, sortOrder = ? WHERE id = ?",
                           arguments: [folder.parentId, try nextOrder(in: "knowledge_folders", db: db), child.id])
        }
        try db.execute(sql: "UPDATE knowledge_items SET folderId = ?, sortOrder = sortOrder + ? WHERE folderId = ? AND baseId = ?",
                       arguments: [folder.parentId, try nextOrder(in: "knowledge_items", db: db), folder.id, folder.baseId])
    }

    static func nextOrder(in table: String, db: Database) throws -> Int {
        // 内部调用点仅传入三张固定知识表。
        try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM \(table)") ?? 0
    }

    static func idJSON(_ ids: Set<UUID>) -> String {
        // UUID 字符串只包含十六进制数字和连字符，不需要通用 JSON 字符串转义。
        "[" + ids.map { "\"\($0.uuidString)\"" }.sorted().joined(separator: ",") + "]"
    }
}
