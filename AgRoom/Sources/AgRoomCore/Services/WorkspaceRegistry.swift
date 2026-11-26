import Foundation

// MARK: - Workspace Registry

/// 工作区注册表：全局持久化「名称 ↔ 目录」映射，供对话列表分组与会话写入根使用。
///
/// 规则：
/// - 每个空间各有一个默认工作区，目录为受管区下的 `default-chat/<space>`，
///   首次启动自动创建并登记，不可移除。
/// - 新增工作区在受管区 `files/` 下创建同名文件夹（如新增 test → `<受管区>/files/test`）。
/// - 添加已有工作区保留系统选择器返回的 URL，按空间保存书签并在后续访问时恢复。
/// - 工作区列表按空间隔离：读写 API 都要求显式传入空间。
///
/// 存储：`~/Library/Application Support/AgRoom/workspaces.json`（原子替换，条目带空间标记）。
/// 访问方全部位于主 actor（对话页、文件页与引擎组装），故整体主 actor 隔离，不引入额外锁。
@MainActor
public final class WorkspaceRegistry {

    /// 标准实例（App 全局单例；目录与 `FileAreaService.standard` 对齐）
    public static let shared = WorkspaceRegistry()
    public static let didChange = Notification.Name("AgRoom.WorkspaceRegistry.didChange")

    public enum WorkspaceError: LocalizedError, Equatable, Sendable {
        /// 名称非法（空、`.`、`..` 或含 `/`、`:`）
        case invalidName
        /// 目标不是已存在的文件夹
        case notDirectory(String)
        /// 位置过于宽泛或属于系统/应用私有数据，不能整体授权给 Agent
        case unsafeLocation(String)
        /// 目标目录无读写权限（需用户授权）
        case notWritable(String)
        /// 注册表当前不可写（此前的读故障未解决，写盘会被拒绝）
        case registryUnavailable
        /// 注册表写盘失败（序列化或磁盘写入错误）
        case registryWriteFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Invalid workspace name (empty, '.', '..' or contains '/' / ':')."
            case .notDirectory(let path):
                return "Not a folder: \(path)"
            case .unsafeLocation(let path):
                return "This location cannot be used as a workspace: \(path)"
            case .notWritable(let path):
                return "No read/write permission for: \(path)"
            case .registryUnavailable:
                return "Workspace registry is unreadable; changes are not persisted."
            case .registryWriteFailed(let reason):
                return "Failed to write workspace registry: \(reason)"
            }
        }
    }

    private let fileURL: URL
    private let fileAreaService: FileAreaService
    private var cache: [ChatWorkspace]? {
        didSet {
            guard let oldValue, let cache, oldValue != cache else { return }
            for space in AppSpace.allCases where oldValue.filter({ $0.space == space }) != cache.filter({ $0.space == space }) {
                notifyChange(in: space)
            }
        }
    }
    private let accessCoordinator: WorkspaceAccessCoordinator
    public private(set) var accessIssues: Set<UUID> = [] {
        didSet {
            guard oldValue != accessIssues, let cache else { return }
            let changed = oldValue.symmetricDifference(accessIssues)
            for space in Set(cache.filter { changed.contains($0.id) }.map(\.space)) { notifyChange(in: space) }
        }
    }

    private func notifyChange(in space: AppSpace) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["space": space.rawValue])
    }

    public init(fileURL: URL? = nil, fileAreaService: FileAreaService = .standard) {
        let supportDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.fileURL = fileURL
            ?? supportDir
                .appendingPathComponent("AgRoom", isDirectory: true)
                .appendingPathComponent("workspaces.json")
        self.fileAreaService = fileAreaService
        self.accessCoordinator = WorkspaceAccessCoordinator(root: self.fileURL.deletingLastPathComponent())
    }

    internal init(fileURL: URL, fileAreaService: FileAreaService, accessCoordinator: WorkspaceAccessCoordinator) {
        self.fileURL = fileURL
        self.fileAreaService = fileAreaService
        self.accessCoordinator = accessCoordinator
    }

    // MARK: - Read

    /// 指定空间的工作区（默认工作区恒在首位）
    public func workspaces(for space: AppSpace) -> [ChatWorkspace] {
        var list = allWorkspaces()
        var changed = false
        for index in list.indices where list[index].space == space {
            do {
                let resolved = list[index].isDefault ? list[index].url : try accessCoordinator.restore(list[index])
                if resolved.path != list[index].path {
                    list[index].path = resolved.path
                    changed = true
                }
                for folderIndex in list[index].referencedFolders.indices {
                    let folder = list[index].referencedFolders[folderIndex]
                    let url = try accessCoordinator.restore(id: folder.id, space: space, path: folder.path)
                    try validateFolder(url, for: space)
                    if folder.path != url.path {
                        list[index].referencedFolders[folderIndex].path = url.path
                        changed = true
                    }
                }
                accessIssues.remove(list[index].id)
            } catch {
                accessIssues.insert(list[index].id)
            }
        }
        if changed {
            do { try persistOrThrow(list); cache = list }
            catch { HubLogger.shared.error("Workspace relocation could not be persisted") }
        }
        return list.filter { $0.space == space }
    }

    /// 运行装配不能把恢复失败的登记当作可访问根，也不能静默切到另一个项目。
    @discardableResult
    public func requireAccess(to path: String, in space: AppSpace, workspaceID: UUID? = nil) throws -> ChatWorkspace {
        let list = workspaces(for: space)
        let normalized = Self.normalized(path)
        guard let workspace = list.first(where: {
            (workspaceID == nil || $0.id == workspaceID) && FileAreaService.isInside(URL(fileURLWithPath: normalized), root: $0.url)
        }),
              !accessIssues.contains(workspace.id) else { throw WorkspaceError.notWritable(path) }
        for root in workspace.folderURLs { try validateFolder(root, for: space) }
        return workspace
    }

    public func releaseAccess(for space: AppSpace) { accessCoordinator.releaseAccess(for: space) }

    /// 恢复失败后，用户在系统选择器中重新确认目录，保留会话的工作区身份。
    public func reauthorize(id: UUID, in space: AppSpace, selectedURL: URL) throws {
        var list = allWorkspaces()
        guard let index = list.firstIndex(where: { $0.id == id && $0.space == space && !$0.isDefault }) else {
            throw WorkspaceError.notDirectory(selectedURL.path)
        }
        let resolved = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isAcceptableWorkspaceRoot(resolved) else { throw WorkspaceError.unsafeLocation(resolved.path) }
        let didStart = selectedURL.startAccessingSecurityScopedResource()
        defer { if didStart { selectedURL.stopAccessingSecurityScopedResource() } }
        try Self.probeReadWrite(at: resolved)
        list[index].path = resolved.path
        try accessCoordinator.register(selectedURL, workspace: list[index])
        try persistOrThrow(list)
        cache = list
        accessIssues.remove(id)
        _ = try accessCoordinator.restore(list[index])
    }

    /// 指定空间的默认工作区
    public func defaultWorkspace(for space: AppSpace) -> ChatWorkspace? {
        workspaces(for: space).first(where: { $0.isDefault })
    }

    /// 按 id 解析工作区；nil、未知 id 或跨空间 id 都回退该空间的默认工作区
    public func workspace(id: UUID?, in space: AppSpace) -> ChatWorkspace? {
        guard let id, let match = workspaces(for: space).first(where: { $0.id == id }) else {
            return defaultWorkspace(for: space)
        }
        return match
    }

    /// 目录已不存在的工作区 id（文件页删除/改名后据此显示「失效」，避免静默回退）
    public func brokenWorkspaceIds() -> Set<UUID> {
        Set(allWorkspaces().filter { !Self.isExistingDirectory($0.path) }.map(\.id)).union(accessIssues)
    }

    /// 全部空间登记的工作区目录（文件页据此扩展可读受管根）
    public func allWorkspaceRoots() -> [URL] {
        allWorkspaces().flatMap(\.folderURLs)
    }

    /// 必须来自系统目录选择器；引用属于单一工作区，不能因同空间登记而隐式共享。
    public func addReferencedFolders(_ urls: [URL], to workspaceID: UUID, in space: AppSpace) throws {
        var list = allWorkspaces()
        guard let index = list.firstIndex(where: { $0.id == workspaceID && $0.space == space }) else {
            throw WorkspaceError.registryUnavailable
        }
        var added: [WorkspaceFolderReference] = []
        do {
            for selectedURL in urls {
                let started = selectedURL.startAccessingSecurityScopedResource()
                defer { if started { selectedURL.stopAccessingSecurityScopedResource() } }
                let resolved = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
                try validateFolder(resolved, for: space)
                guard !list[index].folderURLs.contains(where: { $0.path == resolved.path }) else { continue }
                let folder = WorkspaceFolderReference(path: resolved.path)
                try accessCoordinator.register(selectedURL, id: folder.id, space: space, path: folder.path)
                added.append(folder)
                list[index].referencedFolders.append(folder)
            }
            try persistOrThrow(list)
        } catch {
            for folder in added { try? accessCoordinator.revoke(id: folder.id, space: space) }
            throw error
        }
        cache = list
    }

    public func removeReferencedFolder(_ folderID: UUID, from workspaceID: UUID, in space: AppSpace) throws {
        var list = allWorkspaces()
        guard let index = list.firstIndex(where: { $0.id == workspaceID && $0.space == space }),
              list[index].referencedFolders.contains(where: { $0.id == folderID }) else { return }
        list[index].referencedFolders.removeAll { $0.id == folderID }
        try persistOrThrow(list)
        cache = list
        try accessCoordinator.revoke(id: folderID, space: space)
    }

    private func validateFolder(_ url: URL, for space: AppSpace) throws {
        guard Self.isExistingDirectory(url.path) else { throw WorkspaceError.notDirectory(url.path) }
        let otherSpaces = AppSpace.allCases.filter { $0 != space }
        let forbidden = ScriptSandbox.privateRoots(space: space)
            + otherSpaces.flatMap { fileAreaService.defaultWriteRoots(for: $0) + [fileAreaService.defaultChatRoot(for: $0)] }
        guard Self.isAcceptableWorkspaceRoot(url), ScriptSandbox.permitsProjectRoot(url), !forbidden.contains(where: {
            FileAreaService.isInside(url, root: $0) || FileAreaService.isInside($0, root: url)
        }) else { throw WorkspaceError.unsafeLocation(url.path) }
    }

    // MARK: - Mutate

    /// Backup restore may register only freshly materialized folders under the
    /// target space's managed restore namespace. It cannot grant external access.
    func adoptRestored(_ entries: [ChatWorkspace], in space: AppSpace) throws {
        let root = fileAreaService.defaultChatRoot(for: space).appendingPathComponent("Restored")
        var list = allWorkspaces()
        for entry in entries {
            guard entry.space == space, !entry.isDefault, !entry.name.isEmpty,
                  entry.folderURLs.allSatisfy({ FileAreaService.isInside($0, root: root) }) else { throw WorkspaceError.unsafeLocation(entry.path) }
            for url in entry.folderURLs { _ = try AppDirectory(url: url, create: false); try validateFolder(url, for: space) }
            if let current = list.first(where: { $0.id == entry.id }) {
                guard current == entry else { throw WorkspaceError.registryUnavailable }
            } else {
                guard !list.contains(where: { $0.path == entry.path && $0.space != space }) else { throw WorkspaceError.registryUnavailable }
                list.append(entry)
            }
        }
        try persistOrThrow(list); cache = list
    }

    func removeRestored(_ entries: [ChatWorkspace], in space: AppSpace) throws {
        var list = allWorkspaces()
        for entry in entries {
            guard entry.space == space, !entry.isDefault else { throw WorkspaceError.registryUnavailable }
            if let current = list.first(where: { $0.id == entry.id }) {
                guard current == entry else { throw WorkspaceError.registryUnavailable }
                list.removeAll { $0.id == entry.id && $0.space == space }
            }
        }
        try persistOrThrow(list); cache = list
    }

    /// 新增工作区：在受管区 files/ 下创建同名文件夹并登记到指定空间。
    /// 同名工作区或同名目录已存在时直接复用，不覆盖已有内容。
    @discardableResult
    public func createWorkspace(named rawName: String, for space: AppSpace) throws -> ChatWorkspace {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateName(name)
        if let match = workspaces(for: space).first(where: {
            !$0.isDefault && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return match
        }
        let resolved = fileAreaService.filesRoot
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        if let match = workspaces(for: space).first(where: { $0.path == resolved.path }) {
            return match
        }
        if !FileManager.default.fileExists(atPath: resolved.path) {
            do {
                try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
            } catch {
                throw WorkspaceError.notWritable(resolved.path)
            }
        }
        return append(ChatWorkspace(name: name, path: resolved.path, space: space))
    }

    /// 添加已有工作区：接受任意目录（含 `~/Documents` 之外），登记前探测读写权限。
    /// 同一空间内同一路径已登记时直接复用。
    @discardableResult
    public func addExistingWorkspace(path rawPath: String, for space: AppSpace) throws -> ChatWorkspace {
        guard let url = FileAreaService.expandHome(rawPath) else {
            throw WorkspaceError.notDirectory(rawPath)
        }
        return try registerWorkspace(url: url, for: space, preserveAccess: false)
    }

    /// UI 必须传入选择器的原始 URL，不能丢弃它的安全作用域只留下 path。
    @discardableResult
    public func addExistingWorkspace(url: URL, for space: AppSpace) throws -> ChatWorkspace {
        try registerWorkspace(url: url, for: space, preserveAccess: true)
    }

    private func registerWorkspace(url: URL, for space: AppSpace, preserveAccess: Bool) throws -> ChatWorkspace {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isExistingDirectory(resolved.path) else {
            throw WorkspaceError.notDirectory(resolved.path)
        }
        // 安全底线：不能把整个磁盘、主目录本身或系统/应用私有数据目录整体授权给 Agent。
        // 其余位置（代码仓库的常见位置）一律允许，可写性由下面的读写探测把关
        guard Self.isAcceptableWorkspaceRoot(resolved) else {
            throw WorkspaceError.unsafeLocation(resolved.path)
        }
        try Self.probeReadWrite(at: resolved)
        let existing = allWorkspaces().first { $0.space == space && $0.path == resolved.path }
        let workspace = existing ?? ChatWorkspace(name: resolved.lastPathComponent, path: resolved.path, space: space)
        if preserveAccess { try accessCoordinator.register(url, workspace: workspace) }
        var list = allWorkspaces()
        if existing == nil { list.append(workspace) }
        try persistOrThrow(list)
        cache = list
        accessIssues.remove(workspace.id)
        _ = try accessCoordinator.restore(workspace)
        return workspace
    }

    /// 移出工作区：仅移除登记，不动磁盘目录；默认工作区不可移除。
    /// 写盘失败向上抛出——界面不得呈现「移除成功」而重启后又回来
    public func removeWorkspace(id: UUID) throws {
        var list = allWorkspaces()
        guard let index = list.firstIndex(where: { $0.id == id }), !list[index].isDefault else { return }
        try accessCoordinator.revoke(list[index])
        list.remove(at: index)
        try persistOrThrow(list)
        cache = list
    }

    /// 文件页改名目录后同步：登记路径与显示名跟随目录新位置
    public func relocate(from oldPath: String, to newPath: String) {
        let old = Self.normalized(oldPath)
        let new = Self.normalized(newPath)
        var list = allWorkspaces()
        guard let index = list.firstIndex(where: { $0.path == old }), !list[index].isDefault else { return }
        list[index].path = new
        list[index].name = URL(fileURLWithPath: new).lastPathComponent
        persist(list)
        cache = list
    }

    /// 文件页删除目录后同步：移出指向该目录的工作区登记（默认工作区不受影响）
    public func unregister(path: String) {
        let target = Self.normalized(path)
        var list = allWorkspaces()
        let before = list.count
        list.removeAll { !$0.isDefault && $0.path == target }
        guard list.count != before else { return }
        persist(list)
        cache = list
    }

    // MARK: - Private

    /// 全部空间的工作区（默认工作区在前，按空间顺序）
    private func allWorkspaces() -> [ChatWorkspace] {
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    private func append(_ workspace: ChatWorkspace) -> ChatWorkspace {
        var list = allWorkspaces()
        list.append(workspace)
        persist(list)
        cache = list
        return workspace
    }

    /// 读取磁盘并保证两个空间的默认工作区存在且指向受管区 `default-chat/<space>`。
    ///
    /// 解码失败时**保留现场**：把原文件另存为 `.corrupt-<时间戳>` 并记下故障状态，
    /// 绝不用默认列表覆盖它。旧实现里 `try?` 吞掉解码错误后直接 `persist(list)`，
    /// 用户的全部工作区登记会被一份「只有默认工作区」的列表永久替换掉。
    private func load() -> [ChatWorkspace] {
        var stored: [ChatWorkspace] = []
        if let data = try? Data(contentsOf: fileURL) {
            do {
                stored = try JSONDecoder().decode([ChatWorkspace].self, from: data)
            } catch {
                let preserved = preserveCorruptFile()
                loadIssue = .decodeFailed(
                    path: fileURL.path,
                    preservedPath: preserved,
                    reason: error.localizedDescription
                )
                HubLogger.shared.error(
                    "Workspace registry is unreadable; preservation \(preserved == nil ? "failed" : "succeeded"): "
                        + HubLogger.safeErrorSummary(error)
                )
                // 只返回默认工作区，且**不写盘**——把决定权留给用户
                return Self.defaults(fileAreaService: fileAreaService)
            }
        }
        loadIssue = nil
        var defaults: [ChatWorkspace] = []
        for space in AppSpace.allCases {
            let path = fileAreaService.defaultChatRoot(for: space).path
            if let existing = stored.first(where: { $0.isDefault && $0.space == space }) {
                var updated = existing
                updated.path = path
                defaults.append(updated)
            } else {
                defaults.append(ChatWorkspace(name: "", path: path, isDefault: true, space: space))
            }
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let list = defaults + stored.filter { !$0.isDefault }
        persist(list)
        return list
    }

    /// 注册表加载故障：界面据此提示用户「登记没有丢，只是读不出来」。
    public enum LoadIssue: Sendable, Equatable {
        /// 文件存在但解不开；原文件已另存到 `preservedPath`（nil = 另存也失败）
        case decodeFailed(path: String, preservedPath: String?, reason: String)
    }

    /// 最近一次加载故障（nil = 正常）；出现后**本进程不再写注册表**，避免覆盖现场
    public private(set) var loadIssue: LoadIssue?

    /// 把无法解码的注册表另存到同目录的时间戳文件，返回新路径。
    private func preserveCorruptFile() -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
        do {
            try FileManager.default.copyItem(at: fileURL, to: target)
            return target.path
        } catch {
            HubLogger.shared.error("Workspace registry preservation failed: \(HubLogger.safeErrorSummary(error))")
            return nil
        }
    }

    /// 仅默认工作区（读不出注册表时的最小可用集合，不写入磁盘）
    private static func defaults(fileAreaService: FileAreaService) -> [ChatWorkspace] {
        AppSpace.allCases.map { space in
            ChatWorkspace(
                name: "",
                path: fileAreaService.defaultChatRoot(for: space).path,
                isDefault: true,
                space: space
            )
        }
    }

    private func persist(_ list: [ChatWorkspace]) {
        do {
            try persistOrThrow(list)
        } catch {
            HubLogger.shared.error("Workspace registry write failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    /// 写入注册表并把失败向上抛出（移除登记等需要「界面一致性」的路径使用）。
    /// 读故障未解决前拒绝写盘：任何一次写入都会把用户原文件（唯一的恢复依据）覆盖掉
    private func persistOrThrow(_ list: [ChatWorkspace]) throws {
        guard loadIssue == nil else { throw WorkspaceError.registryUnavailable }
        let data: Data
        do {
            data = try JSONEncoder().encode(list)
        } catch {
            throw WorkspaceError.registryWriteFailed(error.localizedDescription)
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw WorkspaceError.registryWriteFailed(error.localizedDescription)
        }
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 是否可作为工作区根：拒绝覆盖范围过大或存放系统/应用私有数据的位置。
    /// - 文件系统根与用户主目录本身：授权即等于把整个磁盘 / 账号交给 Agent
    /// - `~/Library`、`/System`、`/Library`：系统与应用私有数据（含本应用的数据库与技能目录）
    ///
    /// 其余位置一律允许（代码仓库常见位置都在此列）；能否真正读写由 `probeReadWrite` 判定，
    /// 受系统保护的目录会因此失败并提示用户授权。
    nonisolated static func isAcceptableWorkspaceRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath().path
        if path == "/" || path == home { return false }
        let disallowedPrefixes = [home + "/Library", "/System", "/Library"]
        return !disallowedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    nonisolated static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\u{0}") else {
            throw WorkspaceError.invalidName
        }
    }

    /// 读写探测：在目录内创建并删除临时文件；失败即视为无写权限（触发用户授权）
    nonisolated static func probeReadWrite(at url: URL) throws {
        let probe = url.appendingPathComponent(".agroom-perm-probe-\(UUID().uuidString)")
        do {
            try Data("probe".utf8).write(to: probe, options: .atomic)
        } catch {
            throw WorkspaceError.notWritable(url.path)
        }
        try? FileManager.default.removeItem(at: probe)
    }
}
