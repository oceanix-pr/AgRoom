import Darwin
import Foundation

// MARK: - File Area Entry

/// 文件区条目（文件或文件夹）：列表与树视图共用的展示模型
public struct FileAreaEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let byteSize: Int?
    public let modifiedAt: Date?
    public let isHidden: Bool

    public init(
        url: URL,
        isDirectory: Bool,
        byteSize: Int? = nil,
        modifiedAt: Date? = nil,
        isHidden: Bool = false
    ) {
        self.url = url
        self.isDirectory = isDirectory
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.isHidden = isHidden
    }

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

// MARK: - File Area Service

/// 文件区服务：统一管理 ~/Documents/AgRoom 下的三个根目录
/// - files：用户文件树（「文件」页的根；技能可指定其中文件夹作为工作区）
/// - workspace：工作空间（work）的技能默认工作区
/// - privatespace：生活空间（personal）的技能默认工作区
///
/// 路径安全：所有操作先标准化并解析符号链接，再校验落在受管根内（防目录穿越与符号链接逃逸）。
/// 隐藏采用 macOS 原生 BSD chflags UF_HIDDEN 标志（Finder 同款，不改动文件名）。
public final class FileAreaService: @unchecked Sendable {

    public enum AreaError: LocalizedError, Equatable {
        case unsafePath
        case notFound(String)
        case invalidName
        case alreadyExists(String)
        case operationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsafePath:
                return "Path is outside this workspace's referenced folders. "
                    + "Ask the user to explicitly add the folder to this workspace's folder references, then start a new turn. "
                    + "Do not switch permission modes and do not retry the same unchanged path."
            case .notFound(let path):
                return "Not found: \(path)"
            case .invalidName:
                return "Invalid name (empty, '.', '..' or contains '/' / ':')."
            case .alreadyExists(let name):
                return "An item named '\(name)' already exists."
            case .operationFailed(let path):
                return "Operation failed: \(path)"
            }
        }
    }

    /// 标准实例（~/Documents/AgRoom 三根）
    public static let standard = FileAreaService()

    /// 对话默认工作区目录名（受管区下）
    public static let defaultChatFolderName = "default-chat"

    public let baseDirectory: URL
    /// 用户文件树根（「文件」页根目录；技能工作区在此之下）
    public let filesRoot: URL
    /// work 空间的默认工作区
    public let workspaceRoot: URL
    /// personal 空间的默认工作区
    public let privateRoot: URL
    /// 对话默认工作区父目录（受管区下的 default-chat；其下按空间分 work / personal）
    public let defaultChatRoot: URL
    /// 追加受管根：登记到 ~/Documents 内的已有工作区目录（超出基础根时）
    public let additionalRoots: [URL]
    /// nil 用于文件管理页；对话必须传入当前工作区的明确根，不继承公共父目录。
    public let scopedRoots: [URL]?
    private let scopedIdentities: [String: TaskDirectoryIdentity]

    public init(baseDirectory: URL? = nil, additionalRoots: [URL] = [], scopedRoots: [URL]? = nil) {
        let base = baseDirectory ?? Self.documentsDirectory
            .appendingPathComponent("AgRoom", isDirectory: true)
        self.baseDirectory = base
        self.filesRoot = base.appendingPathComponent("files", isDirectory: true)
        self.workspaceRoot = base.appendingPathComponent("workspace", isDirectory: true)
        self.privateRoot = base.appendingPathComponent("privatespace", isDirectory: true)
        self.defaultChatRoot = base.appendingPathComponent(
            Self.defaultChatFolderName, isDirectory: true
        )
        self.additionalRoots = additionalRoots
        self.scopedRoots = scopedRoots?.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.scopedIdentities = Dictionary((self.scopedRoots ?? []).compactMap { root in
            (try? TaskDirectoryIdentity.capture(root)).map { (root.path, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// 指定空间的对话默认工作区目录（`default-chat/<space>`）
    public func defaultChatRoot(for space: AppSpace) -> URL {
        defaultChatRoot.appendingPathComponent(space.rawValue, isDirectory: true)
    }

    /// 登记工作区（追加受管根）的工具描述补充：为空串表示没有额外根。
    /// 读类工具的描述必须如实反映"用户登记的任意目录同样可读写"，
    /// 否则模型会以为自己读不到仓库而放弃
    public var registeredRootsNote: String {
        if let scopedRoots {
            return "Only this workspace's referenced folders are accessible: "
                + scopedRoots.map(\.path).joined(separator: ", ") + ". Other registered workspaces are not accessible. "
        }
        guard !additionalRoots.isEmpty else { return "" }
        return "User-registered workspaces are readable too: "
            + additionalRoots.map(\.path).joined(separator: ", ") + ". "
    }

    /// 基于当前服务派生出带额外受管根的新实例（用于把会话工作区纳入读写范围）
    public func merging(additionalRoots roots: [URL]) -> FileAreaService {
        FileAreaService(baseDirectory: baseDirectory, additionalRoots: additionalRoots + roots, scopedRoots: scopedRoots)
    }

    public func scoped(to roots: [URL]) -> FileAreaService {
        FileAreaService(baseDirectory: baseDirectory, scopedRoots: roots.filter(ScriptSandbox.permitsProjectRoot))
    }

    public var defaultReadRoot: URL { scopedRoots?.first ?? filesRoot }

    /// 用户「文稿」目录（受管区默认父目录）
    public static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
    }

    /// 受管根：读操作的允许范围，同时是「不可删除/改名」的根集合。
    /// 首项是受管区根（文件页树根），下含 files / workspace / privatespace / default-chat，
    /// 以及两个空间的对话默认工作区目录（`default-chat/<space>`）——避免默认工作区
    /// 被文件页改名或删除后会话静默落到其他目录
    public var managedRoots: [URL] {
        if let scopedRoots { return scopedRoots }
        return [baseDirectory, filesRoot, workspaceRoot, privateRoot, defaultChatRoot]
            + AppSpace.allCases.map { defaultChatRoot(for: $0) }
            + additionalRoots
    }

    /// 当前空间的默认写根：work → workspace，personal → privatespace
    public func defaultWriteRoots(for space: AppSpace) -> [URL] {
        [space == .personal ? privateRoot : workspaceRoot]
    }

    /// 建三个根目录（幂等）
    public func ensureRoots() throws {
        if scopedRoots != nil { return }
        for root in managedRoots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    // MARK: - Path Resolution

    /// 展开路径：支持 ~ 与 ~/…；相对路径返回 nil（文件区一律用绝对路径，避免歧义）
    public static func expandHome(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    /// url 是否落在 root 内（两侧都做标准化 + 符号链接解析，防逃逸）
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let a = url.standardizedFileURL.resolvingSymlinksInPath().path
        let b = root.standardizedFileURL.resolvingSymlinksInPath().path
        return a == b || a.hasPrefix(b + "/")
    }

    private func isRootItself(_ url: URL) -> Bool {
        managedRoots.contains {
            $0.standardizedFileURL.resolvingSymlinksInPath().path
                == url.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }

    /// 解析并校验路径：必须落在任一受管根内（读操作范围）
    public func resolveManaged(_ path: String) throws -> URL {
        guard let url = Self.expandHome(path) else { throw AreaError.unsafePath }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard managedRoots.contains(where: { Self.isInside(resolved, root: $0) }) else {
            throw AreaError.unsafePath
        }
        if let scopedRoots {
            guard !url.standardizedFileURL.pathComponents.contains(".agroom-runs"), !resolved.pathComponents.contains(".agroom-runs"),
                  !ScriptSandbox.legacyRunRoots(in: scopedRoots).contains(where: { Self.isInside(resolved, root: $0) }),
                  let root = scopedRoots.filter({ Self.isInside(resolved, root: $0) }).max(by: { $0.path.count < $1.path.count }),
                  scopedIdentities[root.path]?.matches(root) == true else { throw AreaError.unsafePath }
        }
        return resolved
    }

    private func protectLegacyRuns(inside source: URL) throws {
        guard let scopedRoots else { return }
        if ScriptSandbox.legacyRunRoots(in: scopedRoots).contains(where: { Self.isInside($0, root: source) }) {
            throw AreaError.unsafePath
        }
    }

    /// A tree operation affects descendants too. A granted parent cannot transfer
    /// another space's folder, internal run data, or a nested workspace root.
    func treeSource(_ path: String, space: AppSpace?, changesLocation: Bool) throws -> URL {
        let source = try resolveManaged(path)
        try protectLegacyRuns(inside: source)
        if changesLocation, managedRoots.contains(where: { Self.isInside($0, root: source) }) {
            throw AreaError.unsafePath
        }
        if let space {
            guard let raw = Self.expandHome(path), raw.standardizedFileURL.path == source.path,
                  !path.split(separator: "/").contains("..") else { throw AreaError.unsafePath }
            let other: AppSpace = space == .work ? .personal : .work
            let privateRoots = ScriptSandbox.privateRoots(space: space) + defaultWriteRoots(for: other)
                + [defaultChatRoot(for: other)]
            guard !privateRoots.contains(where: { Self.isInside(source, root: $0) || Self.isInside($0, root: source) }) else {
                throw AreaError.unsafePath
            }
        }
        return source
    }

    /// Pin both parents and refuse replacement if another writer takes the name.
    private func relocate(_ source: URL, to target: URL) throws {
        let from = try AppDirectory(url: source.deletingLastPathComponent(), create: false)
        let to = try AppDirectory(url: target.deletingLastPathComponent(), create: false)
        _ = try resolveManaged(source.path)
        _ = try resolveManaged(target.path)
        if renameatx_np(from.fd, source.lastPathComponent, to.fd, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 { return }
        // FileManager also supports moving between volumes. Pin the existing
        // source by file ID for that operation and preserve its no-overwrite contract.
        guard errno == EXDEV, let reference = (source as NSURL).fileReferenceURL() else {
            throw AreaError.operationFailed(target.lastPathComponent)
        }
        try to.verifyIdentity(at: target.deletingLastPathComponent())
        try FileManager.default.moveItem(at: reference, to: target)
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Listing

    /// 列出目录内容（文件夹在前，按名称排序）；includeHidden=false 时过滤隐藏项
    public func entries(at path: String, includeHidden: Bool = true) throws -> [FileAreaEntry] {
        let dir = try resolveManaged(path)
        guard directoryExists(dir) else { throw AreaError.notFound(path) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var result: [FileAreaEntry] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            if name == ".agroom-runs", scopedRoots != nil { continue }
            // 隐藏判定：chflags UF_HIDDEN 或点前缀名（.DS_Store 等），与 Finder 行为一致
            let hidden = Self.hasHiddenFlag(url) || name.hasPrefix(".")
            if hidden && !includeHidden { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            result.append(FileAreaEntry(
                url: url,
                isDirectory: isDir.boolValue,
                byteSize: isDir.boolValue ? nil : (attrs?[.size] as? Int),
                modifiedAt: attrs?[.modificationDate] as? Date,
                isHidden: hidden
            ))
        }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Folder / File Operations

    /// 名称校验（文件与文件夹共用；重命名允许改扩展名，因为校验的是完整名称）
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\u{0}") else {
            throw AreaError.invalidName
        }
    }

    /// 新建文件夹（parent 必须是受管目录）
    public func createFolder(at parentPath: String, name: String) throws -> URL {
        let parent = try resolveManaged(parentPath)
        guard directoryExists(parent) else { throw AreaError.notFound(parentPath) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateName(trimmed)
        let target = parent.appendingPathComponent(trimmed, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) {
            throw AreaError.alreadyExists(trimmed)
        }
        do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
        catch { throw AreaError.operationFailed(trimmed) }
        return target
    }

    /// 删除文件或文件夹：移入系统废纸篓（Finder「放回原处」可恢复）；受管根本身不可删。
    /// 返回废纸篓内的新位置（同名冲突时系统自动加编号）
    @discardableResult
    public func delete(at path: String, space: AppSpace? = nil) throws -> URL? {
        let url = try treeSource(path, space: space, changesLocation: true)
        guard !isRootItself(url) else { throw AreaError.unsafePath }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AreaError.notFound(path) }
        var trashedURL: NSURL?
        do {
            guard let reference = (url as NSURL).fileReferenceURL() else { throw AreaError.unsafePath }
            _ = try treeSource(path, space: space, changesLocation: true)
            try FileManager.default.trashItem(at: reference, resultingItemURL: &trashedURL)
        } catch {
            throw AreaError.operationFailed(url.lastPathComponent)
        }
        return trashedURL as URL?
    }

    /// 永久删除（绕过废纸篓，不可恢复）：供测试与显式的不可逆清理场景使用
    public func deletePermanently(at path: String) throws {
        let url = try resolveManaged(path)
        try protectLegacyRuns(inside: url)
        guard !isRootItself(url) else { throw AreaError.unsafePath }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AreaError.notFound(path) }
        do { try FileManager.default.removeItem(at: url) }
        catch { throw AreaError.operationFailed(url.lastPathComponent) }
    }

    /// 重命名（文件或文件夹；newName 为完整名称，扩展名可随之修改；受管根本身不可改名）
    public func rename(at path: String, to newName: String, space: AppSpace? = nil) throws -> URL {
        let url = try treeSource(path, space: space, changesLocation: true)
        guard !isRootItself(url) else { throw AreaError.unsafePath }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AreaError.notFound(path) }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateName(trimmed)
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if target.path == url.path { return url }
        if FileManager.default.fileExists(atPath: target.path) {
            throw AreaError.alreadyExists(trimmed)
        }
        do { try relocate(url, to: target) }
        catch { throw AreaError.operationFailed(trimmed) }
        return target
    }

    /// 拷贝到目标目录（名称冲突自动追加 " 2"、" 3" …）
    public func copyItem(from sourcePath: String, toDirectory destPath: String, space: AppSpace? = nil) throws -> URL {
        let source = try treeSource(sourcePath, space: space, changesLocation: false)
        let destDir = try resolveManaged(destPath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw AreaError.notFound(sourcePath) }
        guard directoryExists(destDir) else { throw AreaError.notFound(destPath) }
        let target = Self.uniqueDestination(in: destDir, for: source.lastPathComponent)
        guard !Self.isInside(destDir, root: source), let reference = (source as NSURL).fileReferenceURL() else { throw AreaError.unsafePath }
        _ = try resolveManaged(target.path)
        do { try FileManager.default.copyItem(at: reference, to: target) }
        catch { throw AreaError.operationFailed(source.lastPathComponent) }
        return target
    }

    /// 移动到目标目录（名称冲突自动追加序号；源与目标相同目录视为无操作）
    public func moveItem(from sourcePath: String, toDirectory destPath: String, space: AppSpace? = nil) throws -> URL? {
        let source = try treeSource(sourcePath, space: space, changesLocation: true)
        let destDir = try resolveManaged(destPath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw AreaError.notFound(sourcePath) }
        guard directoryExists(destDir) else { throw AreaError.notFound(destPath) }
        if source.deletingLastPathComponent().path == destDir.path { return nil }
        let target = Self.uniqueDestination(in: destDir, for: source.lastPathComponent)
        guard !Self.isInside(destDir, root: source) else { throw AreaError.unsafePath }
        do { try relocate(source, to: target) }
        catch { throw AreaError.operationFailed(source.lastPathComponent) }
        return target
    }

    /// 目标名冲突时的自动改名（原名后加流水号 " 2"、" 3" …；找不到空位回退短 UUID）。
    /// copy/move 与对话产物落盘（file_write）共用，保证"绝不静默覆盖"语义一致
    public static func uniqueDestination(in dir: URL, for name: String) -> URL {
        let direct = dir.appendingPathComponent(name)
        let fm = FileManager.default
        if !fm.fileExists(atPath: direct.path) { return direct }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for index in 2...100 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = dir.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: url.path) { return url }
        }
        return dir.appendingPathComponent("\(base) \(UUID().uuidString.prefix(6))")
    }

    // MARK: - Hidden (BSD chflags)

    /// BSD chflags 的 UF_HIDDEN 位（Finder 隐藏标志）
    private static let hiddenFlag: UInt32 = 0x8000

    private static func statFlags(_ path: String) -> UInt32? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_flags
    }

    private static func hasHiddenFlag(_ url: URL) -> Bool {
        guard let flags = statFlags(url.path) else { return false }
        return (flags & hiddenFlag) != 0
    }

    public func isHidden(at path: String) -> Bool {
        guard let url = try? resolveManaged(path) else { return false }
        return Self.hasHiddenFlag(url)
    }

    /// 设置/取消 Finder 隐藏（chflags hidden / nohidden 等价，不改动文件名）
    public func setHidden(_ hidden: Bool, at path: String) throws {
        let url = try resolveManaged(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AreaError.notFound(path) }
        guard var flags = Self.statFlags(url.path) else { throw AreaError.operationFailed(url.lastPathComponent) }
        if hidden { flags |= Self.hiddenFlag } else { flags &= ~Self.hiddenFlag }
        guard chflags(url.path, flags) == 0 else {
            throw AreaError.operationFailed(url.lastPathComponent)
        }
    }

    // MARK: - Text I/O

    private static let maxFileBytes = 200_000

    /// 读文本文件（体积超限拒绝；二进制读取失败按错误返回）
    public func readText(at path: String) throws -> String {
        let url = try resolveManaged(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AreaError.notFound(path) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > Self.maxFileBytes {
            throw AreaError.operationFailed("file too large (\(size) bytes)")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AreaError.operationFailed("not readable as UTF-8 text (binary?)")
        }
        return String(text.prefix(Self.maxFileBytes))
    }

    /// 写文本文件（父目录不存在时自动创建；返回写入的 URL）。
    /// 命名冲突不覆盖：自动改名（原名后加流水号 " 2"、" 3" …）
    public func writeText(at path: String, content: String) throws -> URL {
        let url = try resolveManaged(path)
        guard !isRootItself(url), !directoryExists(url), let root = managedRoots.map({ $0.standardizedFileURL.resolvingSymlinksInPath() })
            .filter({ url.path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) else { throw AreaError.unsafePath }
        if scopedRoots == nil { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let data = Data(content.utf8)
        // A creation receipt (and a subsequent undo) must never refer to a file
        // another writer created between choosing the name and publishing it.
        for _ in 0..<8 {
            let destination = Self.uniqueDestination(in: url.deletingLastPathComponent(), for: url.lastPathComponent)
            do {
                try SecureFileWriter.write(data, to: destination, root: root, policy: .createOnly, expectedRoot: scopedIdentities[root.path])
                return destination
            } catch SecureFileWriter.WriteError.targetChanged {
                _ = try resolveManaged(path)
            } catch { throw AreaError.operationFailed(destination.lastPathComponent) }
        }
        throw AreaError.operationFailed(url.lastPathComponent)
    }

    /// 创建多级目录（受管根内）
    public func createDirectory(at path: String) throws -> URL {
        let url = try resolveManaged(path)
        do {
            if let roots = scopedRoots {
                guard let root = roots.filter({ Self.isInside(url, root: $0) }).max(by: { $0.path.count < $1.path.count }),
                      let identity = scopedIdentities[root.path] else { throw AreaError.unsafePath }
                var folder = try AppDirectory(url: root, create: false)
                var info = stat()
                guard fstat(folder.fd, &info) == 0, UInt64(bitPattern: Int64(info.st_dev)) == identity.device,
                      UInt64(info.st_ino) == identity.inode else { throw AreaError.unsafePath }
                for component in url.pathComponents.dropFirst(root.pathComponents.count) {
                    if mkdirat(folder.fd, component, 0o777) != 0, errno != EEXIST {
                        throw AreaError.operationFailed(component)
                    }
                    folder = try folder.child(component, create: false)
                }
                try folder.verifyIdentity(at: url)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        catch { throw AreaError.operationFailed(url.lastPathComponent) }
        return url
    }

    /// 递归列出 files 根下的所有文件夹相对路径（技能工作区选择器用）。
    /// 防御性上限：深度 ≤ 8 层、总数 ≤ 500 个，超大目录树截断不拖垮 UI
    public func folderPathsUnderFilesRoot() -> [String] {
        // contentsOfDirectory 返回的子路径会解析符号链接（/var → /private/var），
        // 根路径必须同样解析后再算前缀长度，否则相对路径错位
        let rootPath = filesRoot.standardizedFileURL.resolvingSymlinksInPath().path
        var result: [String] = []
        var queue: [(url: URL, depth: Int)] = [(filesRoot, 0)]
        while let (dir, depth) = queue.popLast(), result.count < 500 {
            guard depth < 8,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  ) else { continue }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
                let relative = childPath.hasPrefix(rootPath + "/")
                    ? String(childPath.dropFirst(rootPath.count + 1))
                    : child.lastPathComponent
                result.append(relative)
                queue.append((child, depth + 1))
            }
        }
        return result
    }
}
