import Darwin
import Foundation

/// 工作区长期访问只属于登记它的空间。书签保存在该空间目录，
/// 执行器仍按次获取临时授权，不复用长期令牌或另一空间的授权。
@MainActor
public final class WorkspaceAccessCoordinator {
    private struct Record: Codable {
        let bookmark: Data
        let device: UInt64
        let inode: UInt64
    }
    public enum AccessError: Error, Sendable {
        case unavailable, unsafeLocation, directoryReplaced
    }

    private let root: URL
    struct Bookmarks {
        var create: (URL) throws -> Data
        var resolve: (Data) throws -> (URL, Bool)
        static var system: Self {
            Self(create: { try $0.bookmarkData(options: [.withSecurityScope]) }, resolve: { data in
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
                return (url, stale)
            })
        }
    }
    private let bookmarks: Bookmarks
    private var active: [String: URL] = [:]

    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.bookmarks = .system }
    init(root: URL, bookmarks: Bookmarks) { self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.bookmarks = bookmarks }

    /// 只接受 UI 已选中的 URL。原始 security-scoped URL 必须保留到书签建立完成。
    public func register(_ selectedURL: URL, workspace: ChatWorkspace) throws {
        try register(selectedURL, id: workspace.id, space: workspace.space, path: workspace.path)
    }

    func register(_ selectedURL: URL, id: UUID, space: AppSpace, path: String) throws {
        let didStart = selectedURL.startAccessingSecurityScopedResource()
        defer { if didStart { selectedURL.stopAccessingSecurityScopedResource() } }
        let resolved = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard WorkspaceRegistry.isAcceptableWorkspaceRoot(resolved), resolved.path == path else {
            throw AccessError.unsafeLocation
        }
        let identity = try TaskDirectoryIdentity.capture(resolved)
        do {
            let bookmark = try bookmarks.create(selectedURL)
            try update(space: space) { records in
                records[id.uuidString] = Record(bookmark: bookmark, device: identity.device, inode: identity.inode)
            }
        } catch { throw AccessError.unavailable }
    }

    /// 书签可以跟随同一个目录的移动，但不能把同路径的新目录当成旧授权。
    /// 旧登记没有书签时保持旧语义，不替用户扩大登记范围。
    public func restore(_ workspace: ChatWorkspace) throws -> URL {
        try restore(id: workspace.id, space: workspace.space, path: workspace.path)
    }

    func restore(id: UUID, space: AppSpace, path: String) throws -> URL {
        let key = space.rawValue + ":" + id.uuidString
        guard let record = try read(space: space)[id.uuidString] else { return URL(fileURLWithPath: path) }
        let (url, stale) = try bookmarks.resolve(record.bookmark)
        let didStart = url.startAccessingSecurityScopedResource()
        do {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard WorkspaceRegistry.isAcceptableWorkspaceRoot(resolved) else { throw AccessError.unsafeLocation }
            let identity = try TaskDirectoryIdentity.capture(resolved)
            guard identity.device == record.device, identity.inode == record.inode else { throw AccessError.directoryReplaced }
            // 打开目录检验实际读取能力；不创建探测文件，因而只读任务也可恢复访问。
            let descriptor = open(resolved.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw AccessError.unavailable }
            close(descriptor)
            if stale {
                let refreshed = try bookmarks.create(url)
                try update(space: space) { records in
                    records[id.uuidString] = Record(bookmark: refreshed, device: record.device, inode: record.inode)
                }
            }
            if didStart {
                active.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
                active[key] = url
            }
            return resolved
        } catch {
            if didStart { url.stopAccessingSecurityScopedResource() }
            active.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    public func revoke(_ workspace: ChatWorkspace) throws {
        try revoke(id: workspace.id, space: workspace.space)
        for folder in workspace.referencedFolders { try revoke(id: folder.id, space: workspace.space) }
    }

    func revoke(id: UUID, space: AppSpace) throws {
        try update(space: space) { $0.removeValue(forKey: id.uuidString) }
        let key = space.rawValue + ":" + id.uuidString
        active.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
    }

    /// 空间切换后释放其长期访问；正在运行的执行器持有自己按次准备的 scope。
    public func releaseAccess(for space: AppSpace) {
        for key in active.keys.filter({ $0.hasPrefix(space.rawValue + ":") }) {
            active.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
        }
    }

    private func location(_ space: AppSpace) -> URL {
        root.appendingPathComponent(space.rawValue).appendingPathComponent("workspace-access.json")
    }

    private func read(space: AppSpace) throws -> [String: Record] {
        let url = location(space)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw AccessError.unavailable }
            return [:]
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw AccessError.unavailable }
        let data = try ScriptFileIdentity.read(url, root: root, limit: 4 * 1024 * 1024)
        return try JSONDecoder().decode([String: Record].self, from: data)
    }

    private func update(space: AppSpace, _ change: (inout [String: Record]) -> Void) throws {
        let url = location(space)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard try url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AccessError.unavailable
        }
        // 稳定锁文件序列化 App/Daemon 的读改写；I/O 不放在进程内状态锁中。
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AccessError.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, flock(descriptor, LOCK_EX) == 0 else { throw AccessError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        var records = try read(space: space)
        change(&records)
        let data = try JSONEncoder().encode(records)
        let policy: SecureFileWriter.WritePolicy = FileManager.default.fileExists(atPath: url.path)
            ? .matching(try ScriptFileIdentity.read(url, root: url.deletingLastPathComponent(), limit: 4 * 1024 * 1024)) : .createOnly
        try SecureFileWriter.write(data, to: url, root: url.deletingLastPathComponent(), policy: policy)
    }
}
