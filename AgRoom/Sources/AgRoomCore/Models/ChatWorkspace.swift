import Foundation

// MARK: - Chat Workspace

/// 对话工作区：主目录与显式引用的文件夹共同构成会话文件访问范围。
///
/// 工作区按空间隔离：生活/工作空间各自拥有一套工作区列表（含各自默认工作区）；
/// 目录本身属于公共文件区，隐私数据仍留在各空间数据库内。默认工作区目录固定为
/// 受管区下的 `default-chat/<space>`。
public struct ChatWorkspace: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    /// 展示名称：默认工作区为空串，界面按当前语言本地化显示「默认」
    public var name: String
    /// 绝对路径
    public var path: String
    /// 是否为默认工作区（每个空间恒有一个、不可移除）
    public var isDefault: Bool
    /// 归属空间（工作区列表按空间隔离）
    public var space: AppSpace
    public var referencedFolders: [WorkspaceFolderReference]

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        isDefault: Bool = false,
        space: AppSpace,
        referencedFolders: [WorkspaceFolderReference] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isDefault = isDefault
        self.space = space
        self.referencedFolders = referencedFolders
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var folderURLs: [URL] { [url] + referencedFolders.map(\.url) }

    // 旧数据兼容：早期版本无 space 字段，按工作空间归属解码
    enum CodingKeys: String, CodingKey { case id, name, path, isDefault, space, referencedFolders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        space = try c.decodeIfPresent(AppSpace.self, forKey: .space) ?? .work
        referencedFolders = try c.decodeIfPresent([WorkspaceFolderReference].self, forKey: .referencedFolders) ?? []
    }
}

public struct WorkspaceFolderReference: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }
}
