import Foundation

// MARK: - Knowledge Kind

public enum KnowledgeKind: String, Codable, CaseIterable, Sendable {
    /// 知识库：资料/文档型条目
    case document
    /// 知识 Wiki：沉淀的经验/方法型条目
    case wiki
}

// MARK: - Knowledge Base

/// 知识库（分库）：一个空间下可有多个独立知识库
public struct KnowledgeBase: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sortOrder: Int = 0

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    private enum CodingKeys: String, CodingKey { case id, name, createdAt, updatedAt, sortOrder }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

// MARK: - Knowledge Folder

/// 知识库文件夹：树形结构（parentId 为 nil 表示根级）
public struct KnowledgeFolder: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    /// 所属知识库
    public var baseId: UUID
    /// 父文件夹（nil = 根级）
    public var parentId: UUID?
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sortOrder: Int = 0

    public init(id: UUID = UUID(), baseId: UUID, parentId: UUID? = nil, name: String) {
        self.id = id
        self.baseId = baseId
        self.parentId = parentId
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    private enum CodingKeys: String, CodingKey { case id, baseId, parentId, name, createdAt, updatedAt, sortOrder }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        baseId = try values.decode(UUID.self, forKey: .baseId)
        parentId = try values.decodeIfPresent(UUID.self, forKey: .parentId)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

// MARK: - Knowledge Item

/// 知识条目：Markdown 内容 + 标签；图谱节点与 RAG 检索的数据源
public struct KnowledgeItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var content: String
    public var kind: KnowledgeKind
    public var tags: [String]
    /// 所属知识库（nil = 当前空间的未分类区域）
    public var baseId: UUID?
    /// 所在文件夹（nil = 库根级/未分组）
    public var folderId: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var currentRevisionID: UUID? = nil
    public var sortOrder: Int = 0

    public init(
        id: UUID = UUID(),
        title: String,
        content: String = "",
        kind: KnowledgeKind = .document,
        tags: [String] = [],
        baseId: UUID? = nil,
        folderId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.kind = kind
        self.tags = tags
        self.baseId = baseId
        self.folderId = folderId
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, kind, tags, baseId, folderId, createdAt, updatedAt, currentRevisionID, sortOrder
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
        kind = try values.decodeIfPresent(KnowledgeKind.self, forKey: .kind) ?? .document
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        baseId = try values.decodeIfPresent(UUID.self, forKey: .baseId)
        folderId = try values.decodeIfPresent(UUID.self, forKey: .folderId)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        currentRevisionID = try values.decodeIfPresent(UUID.self, forKey: .currentRevisionID)
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    /// 内容中通过 [[条目名]] 显式引用的其他条目标题
    public var explicitReferences: [String] {
        var result: [String] = []
        var scanner = content[...]
        while let openRange = scanner.range(of: "[[") {
            let afterOpen = scanner[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: "]]") else { break }
            let reference = afterOpen[..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !reference.isEmpty {
                result.append(reference)
            }
            scanner = afterOpen[closeRange.upperBound...]
        }
        return result
    }
}
