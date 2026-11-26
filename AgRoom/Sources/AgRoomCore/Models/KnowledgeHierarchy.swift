import Foundation

/// 组织操作只使用稳定 ID；同名条目不影响移动、排序和定位。
public enum KnowledgeNodeID: Codable, Hashable, Sendable {
    case base(UUID)
    case folder(UUID)
    case item(UUID)
}

public enum KnowledgeSearchScope: Equatable, Sendable {
    case all
    case unfiled
    case base(UUID)
    case folder(UUID, includeDescendants: Bool)
}

public enum KnowledgeOrganizationError: String, Error, LocalizedError, Sendable {
    case baseMissing, folderMissing, itemMissing, invalidParent, cycle, duplicateFolder, emptyName

    public var errorDescription: String? {
        switch self {
        case .baseMissing: "The knowledge base no longer exists. Refresh and choose another base."
        case .folderMissing: "The folder no longer exists. Refresh and choose another folder."
        case .itemMissing: "The entry no longer exists. Refresh the knowledge list."
        case .invalidParent: "The destination folder must belong to the selected knowledge base."
        case .cycle: "A folder cannot be moved into itself or one of its descendants."
        case .duplicateFolder: "A folder with this name already exists at the destination. Rename it first."
        case .emptyName: "Enter a name before saving."
        }
    }
}

/// 浏览树只读取短摘要；正文由 get(id:) 在打开条目时加载。
public struct KnowledgeItemSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let preview: String
    public let kind: KnowledgeKind
    public let tags: [String]
    public let baseId: UUID?
    public let folderId: UUID?
    public let updatedAt: Date
    public let sortOrder: Int

    public init(item: KnowledgeItem) {
        id = item.id; title = item.title; preview = String(item.content.prefix(160))
        kind = item.kind; tags = item.tags; baseId = item.baseId; folderId = item.folderId
        updatedAt = item.updatedAt; sortOrder = item.sortOrder
    }
}

/// 同一读事务的空间快照；修复视图中的孤立父节点和环，保证旧数据始终可见。
/// 容错只影响派生树，不静默改写原始目录关系。
public struct KnowledgeBrowserSnapshot: Sendable {
    public let bases: [KnowledgeBase]
    public let folders: [KnowledgeFolder]
    public let items: [KnowledgeItemSummary]
    public let parents: [UUID: UUID]
    public let foldersByID: [UUID: KnowledgeFolder]
    public let itemsByID: [UUID: KnowledgeItemSummary]

    public init(bases: [KnowledgeBase] = [], folders: [KnowledgeFolder] = [], items: [KnowledgeItemSummary] = []) {
        self.bases = bases; self.folders = folders; self.items = items
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        foldersByID = byID
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var safeParents: [UUID: UUID] = [:]
        for folder in folders {
            if let parent = folder.parentId, let existing = byID[parent], existing.baseId == folder.baseId {
                safeParents[folder.id] = parent
            }
        }
        var finished = Set<UUID>()
        for folder in folders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where !finished.contains(folder.id) {
            var path = Set<UUID>()
            var cursor: UUID? = folder.id
            while let id = cursor, !finished.contains(id) {
                guard path.insert(id).inserted else {
                    safeParents[id] = nil
                    break
                }
                cursor = safeParents[id]
            }
            finished.formUnion(path)
        }
        parents = safeParents
    }

    public func childFolders(baseID: UUID, parentID: UUID?) -> [KnowledgeFolder] {
        folders.filter { $0.baseId == baseID && parents[$0.id] == parentID }
    }

    public func ancestors(of folderID: UUID) -> [KnowledgeFolder] {
        var path: [KnowledgeFolder] = []
        var cursor: UUID? = folderID
        while let id = cursor, let folder = foldersByID[id] {
            path.append(folder)
            cursor = parents[id]
        }
        return path.reversed()
    }

    public func descendantIDs(of folderID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [folderID]
        var frontier = [folderID]
        let children = Dictionary(grouping: folders, by: { parents[$0.id] })
        while let id = frontier.popLast() {
            for folder in children[id] ?? [] where result.insert(folder.id).inserted {
                frontier.append(folder.id)
            }
        }
        return result
    }

    public func scopedItems(_ scope: KnowledgeSearchScope) throws -> [KnowledgeItemSummary] {
        switch scope {
        case .all: return items
        case .unfiled:
            let known = Set(bases.map(\.id))
            return items.filter { $0.baseId.map { !known.contains($0) } ?? true }
        case .base(let id):
            guard bases.contains(where: { $0.id == id }) else { throw KnowledgeOrganizationError.baseMissing }
            return items.filter { $0.baseId == id }
        case .folder(let id, let recursive):
            guard let folder = foldersByID[id] else { throw KnowledgeOrganizationError.folderMissing }
            let ids = recursive ? descendantIDs(of: id) : [id]
            return items.filter { $0.baseId == folder.baseId && $0.folderId.map(ids.contains) == true }
        }
    }

    public func path(for item: KnowledgeItemSummary) -> [String] {
        var result = bases.first(where: { $0.id == item.baseId }).map { [$0.name] } ?? []
        if let folder = item.folderId, foldersByID[folder]?.baseId == item.baseId {
            result += ancestors(of: folder).map(\.name)
        }
        return result
    }
}
