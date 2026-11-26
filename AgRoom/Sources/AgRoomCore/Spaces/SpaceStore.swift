import Foundation
import Observation
import GRDB

// MARK: - App Space

/// 双空间定义（顶层架构约束）：生活空间与工作空间物理隔离，
/// 防止个人事务在工作会议投屏时被看到。
public enum AppSpace: String, CaseIterable, Sendable, Codable, Identifiable {
    case personal
    case work

    public var id: String { rawValue }

    /// 空间数据库文件名（每空间独立 sqlite，物理隔离）
    public var databaseFileName: String {
        switch self {
        case .personal: return "personal.sqlite"
        case .work: return "work.sqlite"
        }
    }

    /// 本地化 key
    public var nameKey: String {
        switch self {
        case .personal: return "space.personal"
        case .work: return "space.work"
        }
    }

    /// 空间标识符图标
    public var iconName: String {
        switch self {
        case .personal: return "house.fill"
        case .work: return "briefcase.fill"
        }
    }
}

// MARK: - Space Store

/// 空间管理：当前空间状态 + 按空间惰性挂载数据库连接。
/// 隔离红线：不存在跨空间读写 API，服务只拿到单一空间的 DatabaseQueue。
@MainActor
@Observable
public final class SpaceStore {

    /// UserDefaults 键
    public enum StorageKeys {
        public static let currentSpace = "agroom.current_space"
        public static let defaultSpace = "agroom.default_space"
    }

    /// 全局库文件名（非隐私数据：LLM 提供者配置等）
    nonisolated static let globalDatabaseFileName = "global.sqlite"

    /// 数据库不可用状态（打开或迁移失败）：UI 据此展示原因、路径与恢复入口
    public struct DatabaseIssue: Error, Sendable, Equatable {
        public let fileName: String
        public let path: String
        public let reason: String
    }

    /// 当前空间（切换时 UI 通过 .id 重建全部功能页）
    public private(set) var selectionGeneration: UInt64 = 0
    public private(set) var current: AppSpace

    /// 全局共享库（LLM 提供者配置等非隐私数据）。非 let：全局库重试成功后需替换连接，
    /// 让依赖它的组合服务（Provider）按新连接重建。
    public private(set) var globalQueue: DatabaseQueue?

    /// 全局库的不可用状态（nil = 正常）。**与空间故障分开存储**：
    /// 全局库是跨空间共享的前置依赖，它的故障不能随「打开某个健康空间库」被清掉。
    public private(set) var globalIssue: DatabaseIssue?

    /// 当前空间的数据库不可用状态（nil = 正常）；迁移失败时该库不参与任何服务构造。
    ///
    /// **按空间记录、按当前空间暴露**：全局只留一条「最近一次」的问题在于，切到一个
    /// 健康空间后那条错误仍会继续遮挡界面（覆盖层读的就是这个属性），而健康空间的
    /// 服务其实已经可用。全局库故障优先于空间故障展示（它是两者的共同前置）。
    public var databaseIssue: DatabaseIssue? {
        globalIssue ?? issues[current]
    }

    /// 各空间的数据库不可用状态（按空间独立；健康空间不留残影）
    private var issues: [AppSpace: DatabaseIssue] = [:]

    /// 指定空间的有效故障态（nil = 该空间正常）：全局故障优先，否则为该空间自身的故障。
    public func issue(for space: AppSpace) -> DatabaseIssue? {
        globalIssue ?? issues[space]
    }

    /// 注入故障态（测试用）：验证「故障按空间隔离、切到健康空间不被遮挡」。
    func setIssueForTesting(_ issue: DatabaseIssue?, for space: AppSpace) {
        issues[space] = issue
    }

    /// 注入全局库故障态（测试用）：验证「全局故障独立存储、打开健康空间不清除它」。
    func setGlobalIssueForTesting(_ issue: DatabaseIssue?) {
        globalIssue = issue
    }

    struct MountedDatabase: Sendable {
        let queue: DatabaseQueue
        let cipher: NoteContentCipher
    }

    typealias OpenDatabase = @Sendable (String) -> Result<MountedDatabase, DatabaseIssue>
    private var mounted: [AppSpace: MountedDatabase] = [:]
    @ObservationIgnored private var mounts: [String: Task<Void, Never>] = [:]
    private let open: OpenDatabase?
    private let persistsSelection: Bool

    init(space: AppSpace, databaseQueue: DatabaseQueue) {
        current = space
        persistsSelection = false
        open = nil
        mounted[space] = MountedDatabase(queue: databaseQueue, cipher: .plaintext)
    }

    init(current: AppSpace, persistsSelection: Bool = false, open: @escaping OpenDatabase) {
        self.current = current
        self.persistsSelection = persistsSelection
        self.open = open
    }

    public convenience init() {
        let stored = UserDefaults.standard.string(forKey: StorageKeys.currentSpace)
        self.init(current: stored.flatMap(AppSpace.init(rawValue:)) ?? .work, persistsSelection: true, open: Self.openDatabase)
    }

    /// 切换空间（持久化选择；UI 侧依据 current 变化重建页面）
    public func switchTo(_ space: AppSpace) {
        guard space != current else { return }
        selectionGeneration &+= 1
        current = space
        if persistsSelection { UserDefaults.standard.set(space.rawValue, forKey: StorageKeys.currentSpace) }
        HubLogger.shared.info("Switched to space: \(space.rawValue)")
    }

    /// Reads only authenticated, published connections. Rendering and service creation never open files.
    public func queue(for space: AppSpace) -> DatabaseQueue? {
        guard issue(for: space) == nil else { return nil }
        return mounted[space]?.queue
    }

    func makeNoteStore(for space: AppSpace) -> NoteStore? {
        guard issue(for: space) == nil, let database = mounted[space] else { return nil }
        return NoteStore(databaseQueue: database.queue, cipher: database.cipher)
    }

    /// All simultaneous callers for a file await the same authentication and publication.
    @discardableResult
    public func prepare(_ space: AppSpace) async -> DatabaseQueue? {
        guard open != nil else { return queue(for: space) }
        if globalQueue == nil && globalIssue == nil { await mount(nil) }
        guard globalIssue == nil, globalQueue != nil else { return nil }
        if mounted[space] == nil && issues[space] == nil { await mount(space) }
        return queue(for: space)
    }

    private func mount(_ space: AppSpace?) async {
        let file = space?.databaseFileName ?? Self.globalDatabaseFileName
        if let task = mounts[file] { await task.value; return }
        guard let open else { return }
        let task = Task {
            let result = await Task.detached(priority: .userInitiated) { open(file) }.value
            switch (space, result) {
            case (.some(let space), .success(let database)):
                mounted[space] = database
                issues[space] = nil
            case (.some(let space), .failure(let issue)):
                mounted[space] = nil
                issues[space] = issue
            case (nil, .success(let database)):
                globalQueue = database.queue
                globalIssue = nil
            case (nil, .failure(let issue)):
                globalQueue = nil
                globalIssue = issue
            }
            mounts[file] = nil
        }
        mounts[file] = task
        await task.value
    }

    @discardableResult
    public func retryCurrentDatabase() async -> DatabaseIssue? {
        let space = current
        guard open != nil else { return issue(for: space) }
        if globalIssue != nil { globalIssue = nil; globalQueue = nil }
        if issues[space] != nil { issues[space] = nil; mounted[space] = nil }
        _ = await prepare(space)
        return issue(for: space)
    }

    /// 当前空间的数据库连接
    public var currentQueue: DatabaseQueue? {
        queue(for: current)
    }

    /// Keep GRDB implementation symbols inside Core and resolve the requested
    /// space explicitly rather than consulting the mutable current selection.
    public func databasePath(for space: AppSpace) -> String? {
        queue(for: space)?.path
    }

    /// 当前空间数据库文件路径（供 SQL 工作台等按路径访问）
    public var currentDatabasePath: String? {
        Self.databasePath(fileName: current.databaseFileName)
    }

    /// 数据库文件绝对路径（纯路径计算，不创建目录）
    nonisolated static func databasePath(fileName: String) -> String? {
        guard let supportDir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return supportDir
            .appendingPathComponent("AgRoom", isDirectory: true)
            .appendingPathComponent(fileName)
            .path
    }

    /// 应用支持目录（~/Library/Application Support/AgRoom）：
    /// 技能/数据库/技能用量日志等空间数据均在此，作为 shell_run 的默认工作目录
    public var currentDirectoryURL: URL? {
        guard let supportDir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let url = supportDir.appendingPathComponent("AgRoom", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Private

    /// 打开数据库并立即运行集中迁移。
    /// 迁移失败返回 nil + 不可用状态：该库不参与任何服务构造，
    /// 消除「启动看似成功、稍后随机报错」的失败模式
    nonisolated private static func openDatabase(fileName: String) -> Result<MountedDatabase, DatabaseIssue> {
        do {
            let supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let appDir = supportDir.appendingPathComponent("AgRoom", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            let dbURL = appDir.appendingPathComponent(fileName)

            var config = Configuration()
            // 跨进程写退避：App 与 Daemon 同时打开同一空间库文件，WAL 只解决读并发，
            // 写冲突仍会抛 SQLITE_BUSY。GRDB 默认 busyMode = .immediateError（立即失败），
            // 因此长写事务（同步大文件夹、备份）期间另一进程的写入会直接报错。
            // 改为有限等待：冲突时阻塞至多 5s 再放弃，消掉「随机写失败」这一失败模式
            config.busyMode = .timeout(5)
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                try db.execute(sql: "PRAGMA foreign_keys=ON")
            }
            let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
            var cipher = NoteContentCipher.plaintext
            if fileName == globalDatabaseFileName {
                try DatabaseBootstrap.prepareGlobal(queue)
            } else {
                try DatabaseBootstrap.prepareSpace(queue)
                if let space = AppSpace.allCases.first(where: { $0.databaseFileName == fileName }) {
                    cipher = try NoteContentCipher.database(queue, space: space.rawValue)
                    try NoteContentCipher.protect(queue, cipher: cipher)
                }
            }
            return .success(MountedDatabase(queue: queue, cipher: cipher))
        } catch {
            HubLogger.shared.error("Database setup error (\(fileName)): \(HubLogger.safeErrorSummary(error))")
            return .failure(DatabaseIssue(
                    fileName: fileName,
                    path: Self.databasePath(fileName: fileName) ?? fileName,
                    reason: error.localizedDescription
            ))
        }
    }
}
