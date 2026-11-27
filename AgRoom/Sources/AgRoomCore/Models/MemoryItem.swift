import Foundation

// MARK: - Memory Category

/// 记忆类别：存储值为稳定英文 slug，展示文案由 UI 层按三语本地化。
/// 「自动判断」不是类别值，而是新增记忆时让模型判定类别的模式（见 MemoryDistiller.classify）
public enum MemoryCategory: String, Codable, CaseIterable, Sendable {
    /// 用户偏好（口味、风格、习惯）
    case preference
    /// 关于用户/项目的客观事实
    case fact
    /// 已做出的决定与结论
    case decision
    /// 人物、项目、系统等实体
    case entity
    /// 无法归入以上各类
    case other

    /// 模型提示词里约定的取值说明（面向模型不本地化）
    public static var promptTaxonomy: String {
        "preference = user tastes, styles or habits; "
            + "fact = objective facts about the user or their projects; "
            + "decision = conclusions or choices already made; "
            + "entity = people, projects, systems or other named things; "
            + "other = anything that does not fit the above"
    }
}

// MARK: - Memory Item

public enum MemorySourceBasis: String, Codable, Sendable {
    case stated, inferred
}

public struct MemorySupersession: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
}

/// 长期记忆条目：注入调度上下文，并可通过调度工具检索/保存
public struct MemoryItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public var category: MemoryCategory
    public var isEnabled: Bool
    public var createdAt: Date
    public var sourceSessionID: UUID?
    public var sourceMessageID: UUID?
    public var sourceBasis: MemorySourceBasis?
    public var sourceQuote: String?
    public var workspaceID: UUID?
    public var alwaysInclude = false
    public var revision = 0
    public var supersedes: MemorySupersession?

    var promptDescription: String {
        let scope = workspaceID == nil ? "" : "[Current workspace] "
        let basis = sourceBasis == .inferred ? "[Model inference] " : ""
        return scope + basis + content
    }

    public init(
        id: UUID = UUID(),
        content: String,
        category: MemoryCategory = .other,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.isEnabled = isEnabled
        self.createdAt = Date()
    }

    /// 旧备份（`memories.json`）没有 category 字段：缺列回退 `.other`，
    /// 未知取值同样回退，保证历史数据可解码
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        let raw = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        category = MemoryCategory(rawValue: raw) ?? .other
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceSessionID = try container.decodeIfPresent(UUID.self, forKey: .sourceSessionID)
        sourceMessageID = try container.decodeIfPresent(UUID.self, forKey: .sourceMessageID)
        sourceBasis = try container.decodeIfPresent(MemorySourceBasis.self, forKey: .sourceBasis)
        sourceQuote = try container.decodeIfPresent(String.self, forKey: .sourceQuote)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        alwaysInclude = try container.decodeIfPresent(Bool.self, forKey: .alwaysInclude) ?? false
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        supersedes = try container.decodeIfPresent(MemorySupersession.self, forKey: .supersedes)
    }

    // Keep historical recovery-point fingerprints stable for records with no new metadata.
    private enum CodingKeys: String, CodingKey {
        case id, content, category, isEnabled, createdAt, sourceSessionID, sourceMessageID
        case sourceBasis, sourceQuote, workspaceID, alwaysInclude, revision, supersedes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(content, forKey: .content)
        try c.encode(category, forKey: .category)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(sourceSessionID, forKey: .sourceSessionID)
        try c.encodeIfPresent(sourceMessageID, forKey: .sourceMessageID)
        try c.encodeIfPresent(sourceBasis, forKey: .sourceBasis)
        try c.encodeIfPresent(sourceQuote, forKey: .sourceQuote)
        try c.encodeIfPresent(workspaceID, forKey: .workspaceID)
        if alwaysInclude { try c.encode(true, forKey: .alwaysInclude) }
        if revision != 0 { try c.encode(revision, forKey: .revision) }
        try c.encodeIfPresent(supersedes, forKey: .supersedes)
    }
}
