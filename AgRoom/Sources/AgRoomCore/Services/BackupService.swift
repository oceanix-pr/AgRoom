import CryptoKit
import Foundation
import Darwin

public struct BackupCoverageItem: Codable, Equatable, Sendable, Identifiable {
    public let kind: String
    public let records: Int
    public var files: Int = 0
    public var id: String { kind }
    public init(kind: String, records: Int, files: Int = 0) { self.kind = kind; self.records = records; self.files = files }
}

public enum BackupWarning: String, Codable, Sendable {
    case legacyPartial, credentialsRequired, tasksPaused, externalWorkspacesOmitted, protectedMailDrafts, metricsPending, restorePointPending, omittedLinks, missingAttachments, taskHistoryRebuilt
}

public struct BackupRestorePoint: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let sessions: Int
    public let memories: Int
    public let skills: Int
    public let files: Int
}

// MARK: - Backup Models

/// 备份清单：包内首文件，导出时写入、恢复时先校验。
///
/// 恢复的**第一步**就是读懂它：格式版本、来源空间与每个数据段的大小/条数/校验和。
/// 只有清单声明且校验通过的段才会被写入，因此「包里有什么」和「恢复会写什么」
/// 是同一份声明，不存在凭猜测逐段尝试的空间。
public struct BackupManifest: Codable, Sendable, Equatable {

    /// 包内一个数据段的描述。
    public struct Section: Codable, Sendable, Equatable {
        /// 相对包根的路径（如 `sessions.json`、`skills`）。
        public let path: String
        /// 该段记录条数（目录段为条目数）。
        public let count: Int
        /// 校验用字节数；目录段为全部文件字节之和。
        public let byteCount: Int
        /// SHA-256 十六进制摘要；目录段为按路径排序的逐文件摘要再摘要。
        public let sha256: String

        public init(path: String, count: Int, byteCount: Int, sha256: String) {
            self.path = path
            self.count = count
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public let formatVersion: Int
    public let appVersion: String
    /// 来源空间（work/personal）：恢复前核对，避免把生活数据写进工作空间。
    public let space: String
    public let createdAt: Date
    public let sessionCount: Int
    public let memoryCount: Int
    public let skillCount: Int
    /// 数据段清单；缺失时（老包）按无校验处理并明确告知调用方。
    public let sections: [Section]?
    public let coverage: [BackupCoverageItem]?

    public init(
        formatVersion: Int,
        appVersion: String,
        space: String,
        createdAt: Date,
        sessionCount: Int,
        memoryCount: Int,
        skillCount: Int,
        sections: [Section]? = nil,
        coverage: [BackupCoverageItem]? = nil
    ) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.space = space
        self.createdAt = createdAt
        self.sessionCount = sessionCount
        self.memoryCount = memoryCount
        self.skillCount = skillCount
        self.sections = sections
        self.coverage = coverage
    }
}

/// 导出结果摘要
public struct BackupSummary: Sendable, Equatable {
    public let url: URL
    public let sessions: Int
    public let memories: Int
    public let skills: Int
    /// 收进包内的附件文件数（0 = 包内没有附件）
    public let attachments: Int
    /// 包内登记的工作区数（含默认工作区）
    public let workspaces: Int
    public var coverage: [BackupCoverageItem] = []
}

/// 恢复结果摘要（同名技能走覆盖导入，快照可回滚）
public struct RestoreSummary: Sendable, Equatable {
    public let sessions: Int
    public let memories: Int
    public let skills: Int
    /// 已在当前空间落地的附件数
    public let attachments: Int
    /// 重绑定到当前空间已有工作区的非默认工作区数（匹配不到的会话回退默认工作区）
    public let workspaces: Int
    public let manifest: BackupManifest
    /// 恢复过程中回滚掉的写入数量（0 = 未触发回滚）
    public let rolledBack: Int
    public var coverage: [BackupCoverageItem] = []
    public var verificationSucceeded = false
    public var warnings: [BackupWarning] = []
    public var restorePointID: UUID?
}

/// 备份包内的附件引用：原绝对路径 ↔ 包内相对文件。
/// 换机后原路径通常已失效，恢复时据此把附件重新落地到当前空间并改写消息里的路径
struct BackupAttachmentEntry: Codable, Sendable, Equatable {
    /// 导出时的绝对路径
    let originalPath: String
    /// 包内相对路径（如 `attachments/1-report.pdf`）
    let file: String
}

/// 恢复预检结果：真正写入之前先把「包里有什么、能不能写」讲清楚。
public struct RestorePlan: Sendable, Equatable {
    public let manifest: BackupManifest
    /// 来源空间与本机空间不一致（界面需让用户确认）
    public let spaceMismatch: Bool
    /// 校验未通过的段（不为空则拒绝恢复）
    public let corruptSections: [String]
    /// 老包没有段清单，无法做完整性校验
    public let integrityUnverified: Bool
    /// 会被覆盖的同名技能
    public let conflictingSkills: [String]
    /// 包内附件条目数（v3 起；老包为 0）
    public let attachmentCount: Int
    /// 包内工作区条目数（v3 起；老包为 0）
    public let workspaceCount: Int
    public var coverage: [BackupCoverageItem] = []
    public var preservedMailDrafts = 0
    public var warnings: [BackupWarning] = []
    /// Hash of the exact frozen archive that was inspected.
    public var packageFingerprint: String = ""
    public var conflictingApps: [String] = []
    public var omittedPaths: [String] = []
}

public enum BackupError: LocalizedError, Equatable {
    case manifestMissing
    case unsupportedFormat(Int)
    case dittoFailed(status: Int32)
    /// 恢复时数据段损坏（文件在但解不开）：中止而非静默跳过，防止「以为恢复好了实际丢数据」
    case corruptSection(String, String)
    /// 备份包来自另一个空间，且调用方没有明确同意跨空间恢复
    case spaceMismatch(backup: String, current: String)
    /// 预检未通过（校验和不符等），一个字节都没写
    case preflightFailed(String)
    /// 恢复中途失败并已完整回滚；原始数据保持恢复前状态
    case rolledBack(String)
    /// 回滚不完整：部分写入未能还原，恢复材料保留在 recoveryPath，需人工处置。
    /// 与 `rolledBack` 的差别是「原数据未变」在此不成立，不能对用户谎称已还原
    case restoreIncomplete(String, recoveryPath: String)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "Backup package is missing manifest.json"
        case .unsupportedFormat(let version):
            return "Backup format version \(version) is not supported by this app version"
        case .dittoFailed(let status):
            return "Archive operation failed (ditto exit \(status))"
        case .corruptSection(let section, let reason):
            return "Backup section \(section) is corrupt: \(reason)"
        case .spaceMismatch(let backup, let current):
            return "This backup was created in the \(backup) space but is being restored into \(current)."
        case .preflightFailed(let reason):
            return "Backup verification failed (nothing was restored): \(reason)"
        case .rolledBack(let reason):
            return "Restore failed and was fully rolled back; existing data is unchanged: \(reason)"
        case .restoreIncomplete(let reason, let recoveryPath):
            return "Restore failed and rollback was incomplete; recovery material kept at \(recoveryPath): \(reason)"
        }
    }
}

/// 恢复的持久化恢复记录（before-image）：写入前落盘，进程退出后可据此继续回滚。
/// 只存在于本空间目录，不进入备份包，不写入任何密钥
private struct RestoreRecoveryRecord: Codable, Sendable {
    /// 单条数据库记录：before 为 nil 表示本次新增（回滚删除），否则回滚写回旧值
    struct DatabaseEntry: Codable, Sendable {
        let id: String
        let before: ChatSession?
        var afterDigest: String?
    }
    struct MemoryEntry: Codable, Sendable {
        let id: String
        let before: MemoryItem?
        var afterDigest: String?
    }
    /// 单个技能：backupFolder 为恢复目录内的相对路径；nil 表示本次新增（回滚删除）
    struct SkillEntry: Codable, Sendable {
        let name: String
        let backupFolder: String?
        var beforeDigest: String?
        var afterDigest: String?
    }
    var sessions: [DatabaseEntry]
    var memories: [MemoryEntry]
    var skills: [SkillEntry]
    /// 本次恢复新建的附件文件绝对路径（回滚时删除）；旧记录缺该字段解码为 nil
    var attachments: [String]?
    /// Only receipts missing before this restore may be removed by recovery.
    var usageIDs: [String]?
    var database: SpaceDatabaseRestorePlan?
    var restoreID: UUID?
    var committed: Bool?
    var createdAt: Date?
    var assets: SpaceAssetsRestorePlan?
    var attachmentReceipts: [String: BackupFileIO.Receipt]?
    var verificationMetricRecorded: Bool?
}

/// 回滚结果：complete = 全部还原；incomplete = 仍有未还原项（材料必须保留）
private enum RollbackOutcome: Sendable {
    case complete
    case incomplete([String])
}

// MARK: - Backup Service

/// 当前空间的业务记录、应用、附件和项目资料打包为可核对、可回退的备份。
/// 不含 API 密钥与 Provider 配置（凭据留在钥匙串，永不入备份包）。
/// 打包/解包复用系统 ditto（与技能导入同通道，兼容 Finder 压缩结构）。
///
/// 完整性契约：
/// - 导出写入 `manifest.json` 段清单（路径、条数、字节数、SHA-256）；
/// - 恢复**先预检**（清单 → 格式版本 → 归属空间 → 逐段校验和 → 同名技能冲突），
///   预检不通过时一个字节都不写；
/// - 预检通过后按「附件落地 → 会话 → 记忆 → 技能」顺序写入，任一步失败即回滚已写入的部分，
///   恢复前状态保持不变（不再留下半恢复结果）。
/// - 附件与工作区在本机重建：附件按需重新落地到当前空间目录并改写消息路径（换机可用），
///   会话工作区按同路径/同名重绑到当前空间已有工作区，匹配不到时回退默认工作区。
///
/// 完整性边界的诚实说明：清单里的 SHA-256 是**无密钥校验和**，只用于发现传输/落盘
/// 过程中的意外损坏，**不构成来源认证**——任何能改写包的人都能同时改写清单与校验和。
/// 因此它不能被当作「包来自可信来源」的证据。
public final class BackupService: @unchecked Sendable {

    static let currentFormatVersion = 6

    /// 从该版本起，`manifest.json` 必须携带段清单（缺失视为损坏而非「无内容」）。
    static let sectionsRequiredVersion = 2

    /// 解包后允许的最大文件数：防「压缩炸弹」把临时目录塞满。
    static let maxExtractedFileCount = 50_000
    /// 解包后允许的最大总字节数（2 GiB）：超限直接拒绝，不继续读入内存。
    static let maxExtractedByteCount = 2 * 1024 * 1024 * 1024
    static let maximumJSONSectionBytes = 256 * 1024 * 1024

    private let sessionService: SessionService
    private var usageService: UsageService { sessionService.makeUsageService() }
    private func databaseStore(blobs: SpaceBackupBlobs? = nil) -> SpaceDatabaseBackupStore {
        SpaceDatabaseBackupStore(queue: sessionService.databaseQueue, space: spaceName, blobs: blobs)
    }
    private func recoveryDatabase(at root: URL) -> SpaceDatabaseBackupStore {
        databaseStore(blobs: SpaceBackupBlobs(root: root.appendingPathComponent("database-blobs")))
    }
    private let memoryService: MemoryService
    private let skillStore: SkillStore
    private let spaceName: String
    private let prepareExport: (@Sendable () async throws -> Void)?
    /// 当前空间的工作区列表提供者：导出附带工作区映射，恢复据此重绑定会话归属。
    /// 工作区注册表在主 actor，故以异步闭包注入，Core 不直接持有 UI/主 actor 依赖
    private let workspacesProvider: (@Sendable () async -> [ChatWorkspace])?
    private let adoptWorkspaces: (@Sendable ([ChatWorkspace]) async throws -> Void)?
    private let removeWorkspaces: (@Sendable ([ChatWorkspace]) async throws -> Void)?
    private let fileAreaService: FileAreaService
    private var spaceAssets: SpaceAssetsBackupStore? {
        AppSpace(rawValue: spaceName).map { .init(space: $0, spaceRoot: skillStore.skillsDirectoryURL.deletingLastPathComponent(), fileArea: fileAreaService) }
    }
    /// 非音频附件落地目录（nil = 当前空间的标准附件目录）
    private let explicitAttachmentsDirectory: URL?
    /// 音频附件落地目录（nil = MeetMemo 归档目录）
    private let explicitAudioDirectory: URL?
    private let fileManager = FileManager.default

    public init(
        sessionService: SessionService,
        memoryService: MemoryService,
        skillStore: SkillStore,
        spaceName: String,
        workspacesProvider: (@Sendable () async -> [ChatWorkspace])? = nil,
        attachmentsDirectory: URL? = nil,
        audioDirectory: URL? = nil,
        fileAreaService: FileAreaService? = nil,
        adoptWorkspaces: (@Sendable ([ChatWorkspace]) async throws -> Void)? = nil,
        removeWorkspaces: (@Sendable ([ChatWorkspace]) async throws -> Void)? = nil,
        prepareExport: (@Sendable () async throws -> Void)? = nil
    ) {
        self.sessionService = sessionService
        self.memoryService = memoryService
        self.skillStore = skillStore
        self.spaceName = spaceName
        self.workspacesProvider = workspacesProvider
        self.explicitAttachmentsDirectory = attachmentsDirectory
        self.explicitAudioDirectory = audioDirectory
        self.fileAreaService = fileAreaService ?? FileAreaService(baseDirectory: skillStore.skillsDirectoryURL.deletingLastPathComponent().appendingPathComponent("file-area"))
        self.adoptWorkspaces = adoptWorkspaces
        self.removeWorkspaces = removeWorkspaces
        self.prepareExport = prepareExport
    }

    @MainActor
    static func standard(sessionService: SessionService, memoryService: MemoryService, skillStore: SkillStore, space: AppSpace) -> BackupService {
        BackupService(sessionService: sessionService, memoryService: memoryService, skillStore: skillStore, spaceName: space.rawValue,
            workspacesProvider: { await MainActor.run { WorkspaceRegistry.shared.workspaces(for: space) } },
            fileAreaService: .standard,
            adoptWorkspaces: { entries in try await MainActor.run { try WorkspaceRegistry.shared.adoptRestored(entries, in: space) } },
            removeWorkspaces: { entries in try await MainActor.run { try WorkspaceRegistry.shared.removeRestored(entries, in: space) } },
            prepareExport: { try await JobCenter.shared.archiveHistory(to: ProductJobRunStore(databaseQueue: sessionService.databaseQueue, space: space)) })
    }

    /// 非音频附件落地目录
    private var attachmentsDirectory: URL {
        explicitAttachmentsDirectory ?? AttachmentService.attachmentsDirectory(space: spaceName)
    }

    /// 音频附件落地目录
    private var audioDirectory: URL {
        explicitAudioDirectory ?? AttachmentService.meetMemoDirectory
    }

    // MARK: - Export

    /// 导出当前空间全部数据到 zip：
    /// 结构 manifest.json / sessions.json / memories.json / workspaces.json /
    /// attachment-map.json / attachments/ / skills/
    /// progress 粗粒度回调（0…1，供 JobCenter 进度条）
    public func export(
        to destination: URL,
        includeExternalWorkspaces: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> BackupSummary {
        // Serial history migration must finish before taking the exclusive lease;
        // its queue does not inherit task-local maintenance ownership.
        try await BackupContentCancellation.run {
            try await prepareExport?()
            return try await ResourceMaintenance.withExclusive(maintenanceKeys) {
                try await self.exportUnderLease(to: destination, includeExternalWorkspaces: includeExternalWorkspaces, progress: progress)
            }
        }
    }

    private var maintenanceKeys: [String] { [sessionService.maintenanceKey, skillStore.maintenanceKey] + (spaceAssets?.maintenanceKeys ?? []) }

    private func exportUnderLease(to destination: URL, includeExternalWorkspaces: Bool, progress: (@Sendable (Double) -> Void)?) async throws -> BackupSummary {
        try await recoverInterruptedRestoreIfNeeded()
        let sourceSessions = try await sessionService.getAll()
        let sessions = sourceSessions.map(Self.portableSession)
        guard sessions.allSatisfy({ $0.messageLoadHealth == .healthy }) else {
            throw BackupError.preflightFailed("A conversation contains damaged messages. Repair or export its raw recovery material before creating a backup.")
        }
        let memories = try await memoryService.getAll()
        // 技能列举失败直接中止导出：宁可不出包，不出「无技能」的假完整备份
        let skills = try skillStore.list()
        progress?(0.15)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { Self.removeQuietly(staging) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var sections: [BackupManifest.Section] = []

        let sessionsData = try encoder.encode(sessions)
        try Self.write(sessionsData, to: staging, file: "sessions.json")
        sections.append(Self.section(path: "sessions.json", data: sessionsData, count: sessions.count))

        let memoriesData = try encoder.encode(memories)
        try Self.write(memoriesData, to: staging, file: "memories.json")
        sections.append(Self.section(path: "memories.json", data: memoriesData, count: memories.count))
        let usage = try await usageService.exportRecords()
        let usageData = try encoder.encode(usage)
        try Self.write(usageData, to: staging, file: "usage.json")
        sections.append(Self.section(path: "usage.json", data: usageData, count: usage.count))
        let contentRoot = staging.appendingPathComponent("space-blobs")
        _ = try AppDirectory(url: contentRoot, create: true)
        let packageContents = SpaceBackupBlobs(root: contentRoot)
        let spaceData = try await databaseStore(blobs: packageContents).export()
        let spaceBytes = try JSONEncoder().encode(spaceData)
        try Self.write(spaceBytes, to: staging, file: "space-data.json")
        sections.append(Self.section(path: "space-data.json", data: spaceBytes, count: spaceData.recordCount))
        try packageContents.validateInventory(spaceData.blobReferences)
        sections.append(Self.directorySection(path: "space-blobs", root: contentRoot, count: spaceData.blobReferences.count))
        progress?(0.35)

        // 工作区映射：恢复时据此把会话重新挂回当前空间的同路径/同名工作区
        let workspaces = await workspacesProvider?() ?? []
        let workspacesData = try encoder.encode(workspaces)
        try Self.write(workspacesData, to: staging, file: "workspaces.json")
        sections.append(Self.section(path: "workspaces.json", data: workspacesData, count: workspaces.count))
        let assets: SpaceAssetsArchive
        if let spaceAssets { assets = try await spaceAssets.export(to: staging, workspaces: workspaces, includeExternal: includeExternalWorkspaces) }
        else { assets = SpaceAssetsArchive(space: spaceName) }
        let assetsData = try JSONEncoder().encode(assets)
        guard assetsData.count <= SpaceAssetsBackupStore.maximumInventoryBytes else { throw NativeAppError(.tooLarge) }
        try Self.write(assetsData, to: staging, file: "space-assets.json")
        sections.append(Self.section(path: "space-assets.json", data: assetsData, count: assets.recordCount))
        let assetsRoot = staging.appendingPathComponent("space-assets")
        if fileManager.fileExists(atPath: assetsRoot.path) {
            sections.append(Self.directorySection(path: "space-assets", root: assetsRoot, count: assets.apps.count + assets.files.count))
        }

        // 附件段：把消息引用到且仍在磁盘上的附件收进包内（换机后可重建），
        // 并写「原路径 ↔ 包内文件」映射。文件已不存在时如实不收，也不写进清单
        let attachmentsRoot = staging.appendingPathComponent("attachments", isDirectory: true)
        var attachmentEntries: [BackupAttachmentEntry] = []
        var seenAttachmentPaths = Set<String>()
        for session in sessions {
            for message in session.messages {
                for attachment in message.allAttachments {
                    guard seenAttachmentPaths.insert(attachment.path).inserted else { continue }
                    let source = URL(fileURLWithPath: attachment.path)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    let fileName = "\(attachmentEntries.count + 1)-\(source.lastPathComponent)"
                    do {
                        let input = try AppDirectory(url: source.deletingLastPathComponent(), create: false)
                        let output = try AppDirectory(url: attachmentsRoot, create: true)
                        try BackupFileIO.copy(source.lastPathComponent, from: input, to: output, as: fileName, limit: Self.maxExtractedByteCount)
                    } catch {
                        // 单个附件拷不动不阻断整包，但绝不写进清单（避免恢复端以为包内有内容）
                        throw BackupError.preflightFailed("A conversation attachment could not be backed up. Check file access and retry.")
                    }
                    attachmentEntries.append(BackupAttachmentEntry(
                        originalPath: attachment.path,
                        file: "attachments/\(fileName)"
                    ))
                }
            }
        }
        let attachmentMapData = try encoder.encode(attachmentEntries)
        try Self.write(attachmentMapData, to: staging, file: "attachment-map.json")
        sections.append(Self.section(
            path: "attachment-map.json", data: attachmentMapData, count: attachmentEntries.count
        ))
        if !attachmentEntries.isEmpty {
            sections.append(Self.directorySection(
                path: "attachments", root: attachmentsRoot, count: attachmentEntries.count
            ))
        }
        progress?(0.5)

        // 技能整库拷贝（含 versions/ 快照与 references/scripts 资源）
        let skillsSource = skillStore.skillsDirectoryURL
        if fileManager.fileExists(atPath: skillsSource.path) {
            try fileManager.copyItem(
                at: skillsSource,
                to: staging.appendingPathComponent("skills", isDirectory: true)
            )
            sections.append(Self.directorySection(
                path: "skills",
                root: staging.appendingPathComponent("skills", isDirectory: true),
                count: skills.count
            ))
        }
        progress?(0.6)

        let manifest = BackupManifest(
            formatVersion: Self.currentFormatVersion,
            appVersion: Self.appVersion,
            space: spaceName,
            createdAt: Date(),
            sessionCount: sessions.count,
            memoryCount: memories.count,
            skillCount: skills.count,
            sections: sections,
            coverage: Self.coverage(spaceData, sessions: sessions.count, memories: memories.count, skills: skills.count,
                attachments: attachmentEntries.count, workspaces: workspaces.count, usage: usage.count, assets: assets,
                missingAttachments: seenAttachmentPaths.count - attachmentEntries.count)
        )
        try Self.write(encoder.encode(manifest), to: staging, file: "manifest.json")

        // 先写同目录临时包，打包成功后再原子替换目标（NSSavePanel 已确认覆盖）。
        // 旧实现先 removeItem(destination) 再 ditto：ditto 失败或中途强退时新旧备份两失，
        // 违反「文件写入原子化」与「破坏性操作先可逆后不可逆」两条硬性规范。
        // 临时包与目标同目录 → 同卷，replaceItemAt/moveItem 才是原子操作
        let tempArchive = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).agroom-tmp")
        defer {
            // 成功替换后临时包已不存在，跳过清理以免误报日志；失败路径上清掉半成品包
            if fileManager.fileExists(atPath: tempArchive.path) {
                Self.removeQuietly(tempArchive)
            }
        }
        try Self.validateExtractedTree(at: staging)
        try await Self.runDitto(["-c", "-k", "--sequesterRsrc", staging.path, tempArchive.path])
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempArchive)
        } else {
            try fileManager.moveItem(at: tempArchive, to: destination)
        }
        progress?(1.0)

        return BackupSummary(
            url: destination,
            sessions: sessions.count,
            memories: memories.count,
            skills: skills.count,
            attachments: attachmentEntries.count,
            workspaces: workspaces.count,
            coverage: manifest.coverage ?? []
        )
    }

    // MARK: - Restore

    /// 恢复预检：解包到临时目录，校验清单、格式版本、归属空间与逐段校验和。
    ///
    /// **不写入任何数据**。调用方（界面/工具）据此展示「将要恢复什么、有什么风险」，
    /// 用户确认后将 `packageFingerprint` 传给 `restore`，绑定同一个已检验的包。
    public func inspect(from zipURL: URL) async throws -> RestorePlan {
        try await BackupContentCancellation.run { try await inspectPackage(from: zipURL) }
    }

    private func inspectPackage(from zipURL: URL) async throws -> RestorePlan {
        let frozen = try freeze(zipURL)
        defer { Self.removeQuietly(frozen.root) }
        let staging = try await extract(frozen.url)
        defer { Self.removeQuietly(staging) }
        var result = try await plan(staging: staging)
        result.packageFingerprint = frozen.fingerprint
        return result
    }

    /// 从备份包恢复到当前空间。
    ///
    /// - Parameters:
    ///   - zipURL: 备份包
    ///   - allowCrossSpace: 包来自另一个空间时是否允许继续（默认拒绝）
    ///
    /// 流程：解包 → 预检（校验和/空间/格式）→ 写入 → 失败回滚。
    /// 预检不通过时不会写入任何数据；写入阶段失败时回滚已写入部分并抛
    /// `BackupError.rolledBack`，恢复前状态保持不变。
    public func restore(
        from zipURL: URL,
        allowCrossSpace: Bool = false,
        expectedFingerprint: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> RestoreSummary {
        try await BackupContentCancellation.run {
            try await ResourceMaintenance.withExclusive(maintenanceKeys) {
                try await self.restoreUnderLease(from: zipURL, allowCrossSpace: allowCrossSpace, expectedFingerprint: expectedFingerprint, progress: progress)
            }
        }
    }

    private func restoreUnderLease(from zipURL: URL, allowCrossSpace: Bool,
        expectedFingerprint: String?,
        progress: (@Sendable (Double) -> Void)?) async throws -> RestoreSummary {
        // 先把上次中断遗留的恢复收尾：进程退出后再次恢复时继续回滚，
        // 避免半恢复状态被当成现状在此之上继续叠加
        try await recoverInterruptedRestoreIfNeeded()

        let attemptID = UUID()
        _ = await recordRestoreMetric(.restoreAttempted, id: "restore-attempt:" + attemptID.uuidString)

        let frozen = try freeze(zipURL)
        defer { Self.removeQuietly(frozen.root) }
        if let expectedFingerprint, frozen.fingerprint != expectedFingerprint {
            throw BackupError.preflightFailed("The backup changed after inspection. Inspect it again before confirming restore.")
        }
        let staging = try await extract(frozen.url)
        defer { Self.removeQuietly(staging) }
        progress?(0.15)

        let plan = try await plan(staging: staging)
        if plan.spaceMismatch, !allowCrossSpace {
            throw BackupError.spaceMismatch(backup: plan.manifest.space, current: spaceName)
        }
        if !plan.corruptSections.isEmpty {
            throw BackupError.preflightFailed(
                "corrupt sections: \(plan.corruptSections.joined(separator: ", "))"
            )
        }
        progress?(0.25)

        let decoder = Self.decoder()
        var sessions = try decodeSessions(staging: staging, decoder: decoder).map(Self.portableSession)
        for index in sessions.indices { sessions[index].autoReviewEnabled = false }
        let memories = try decodeMemories(staging: staging, decoder: decoder)
        let attachmentEntries = try decodeAttachments(staging: staging, decoder: decoder)
        let workspaces = try decodeWorkspaces(staging: staging, decoder: decoder)
        let usageURL = staging.appendingPathComponent("usage.json")
        let usage = fileManager.fileExists(atPath: usageURL.path)
            ? try decoder.decode([ProviderUsageRecord].self, from: Data(contentsOf: usageURL)) : []
        let spaceData = try decodeSpaceData(staging: staging)
        let assets = try decodeAssets(staging: staging)
        let originalWorkspaceIDs = Dictionary(sessions.map { ($0.id, $0.workspaceId) }, uniquingKeysWith: { first, _ in first })

        // 工作区重绑定：包内工作区 → 当前空间已有工作区（不凭空创建目录）
        var reboundWorkspaces = 0
        var workspaceMappings: [String: String] = [:]
        if let workspacesProvider {
            let rebound = Self.rebindWorkspaces(
                sessions: &sessions,
                source: workspaces,
                target: await workspacesProvider()
            )
            reboundWorkspaces = rebound.count; workspaceMappings = rebound.mappings
        }

        // 附件落地：换机后原路径已失效，从包内重建到当前空间目录并改写消息里的路径。
        // 该阶段失败即清理本次已落地文件并抛错，此时尚未写入任何会话/记忆
        progress?(0.3)

        // 恢复材料目录（本空间目录下）：写入前先建立 before-image 记录，失败可完整还原
        let recoveryRoot = recoveryDirectoryURL
        try? fileManager.removeItem(at: recoveryRoot)
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)

        var record = RestoreRecoveryRecord(sessions: [], memories: [], skills: [])
        record.restoreID = attemptID
        record.createdAt = Date()
        if let assets, let spaceAssets {
            record.assets = try await spaceAssets.prepare(assets, staging: staging, id: record.restoreID!, recovery: recoveryRoot)
        }
        record.usageIDs = try await usageService.missingIDs(usage.map(\.id))
        for session in sessions {
            let before = try await sessionService.fetch(id: session.id)
            guard before?.messageLoadHealth == nil || before?.messageLoadHealth == .healthy else {
                throw BackupError.preflightFailed("Repair the destination conversation before restoring over it.")
            }
            record.sessions.append(.init(id: session.id.uuidString, before: before))
        }
        for memory in memories {
            let before = try await memoryService.fetch(id: memory.id)
            record.memories.append(.init(id: memory.id.uuidString, before: before))
        }

        let attachmentPlan = try prepareAttachments(entries: attachmentEntries, staging: staging)
        let attachmentResult = (rewrites: attachmentPlan.rewrites, created: attachmentPlan.created)
        var pathMappings = record.assets?.pathMappings ?? [:]
        pathMappings.merge(attachmentResult.rewrites) { _, attachment in attachment }
        if !pathMappings.isEmpty {
            for index in sessions.indices { Self.rewriteAttachments(in: &sessions[index], with: pathMappings, targetSpace: AppSpace(rawValue: spaceName)) }
        }
        record.attachments = attachmentResult.created
        record.attachmentReceipts = Dictionary(attachmentPlan.copies.map { ($0.destination.path, $0.receipt) }, uniquingKeysWith: { first, _ in first })
        if let assetPlan = record.assets {
            workspaceMappings.merge(assetPlan.workspaceMappings ?? [:]) { _, restored in restored }
            for index in sessions.indices {
                guard let sourceID = originalWorkspaceIDs[sessions[index].id] ?? workspaces.first(where: { $0.isDefault })?.id.uuidString,
                      let normalized = UUID(uuidString: sourceID)?.uuidString,
                      let restoredID = assetPlan.workspaceMappings?[normalized] else { continue }
                sessions[index].workspaceId = restoredID
            }
        }
        if let target = AppSpace(rawValue: spaceName) {
            for sessionIndex in sessions.indices {
                for messageIndex in sessions[sessionIndex].messages.indices {
                    var message = sessions[sessionIndex].messages[messageIndex]
                    let context = message.contextReport?.resourceContext?.rebinding(space: target, workspaceMappings: workspaceMappings)
                    message.contextReport?.resourceContext = context
                    if var variations = message.variations {
                        for index in variations.indices {
                            let context = variations[index].contextReport?.resourceContext?.rebinding(space: target, workspaceMappings: workspaceMappings)
                            variations[index].contextReport?.resourceContext = context
                        }
                        message.variations = variations
                    }
                    sessions[sessionIndex].messages[messageIndex] = message
                }
            }
        }
        var (taskDatabase, _) = try ProductTaskRunStore.augmentBackup(spaceData, sessions: sessions, sourceSpace: plan.manifest.space)
        let recoveryDatabase = recoveryDatabase(at: recoveryRoot)
        if !taskDatabase.blobReferences.isEmpty {
            guard let target = recoveryDatabase.blobs else { throw BackupError.preflightFailed("Recovery content storage is unavailable") }
            let source = SpaceBackupBlobs(root: staging.appendingPathComponent("space-blobs"))
            let references = taskDatabase.blobReferences
            let mapping = try await Task.detached { try target.copy(references, from: source) }.value
            taskDatabase = try taskDatabase.replacingBlobReferences(mapping)
        }
        record.database = try await recoveryDatabase.plan(taskDatabase, sourceSpace: plan.manifest.space, pathMappings: pathMappings, workspaceMappings: workspaceMappings)
        for index in record.sessions.indices {
            record.sessions[index].afterDigest = try recoveryDigest(sessions[index])
        }
        for index in record.memories.indices {
            record.memories[index].afterDigest = try recoveryDigest(memories[index])
        }
        // 记录落盘：进程在此之后被杀，重启后仍能据此继续回滚
        try persistRecoveryRecord(record, root: recoveryRoot)
        progress?(0.4)

        var writeError: Error?
        var importedSkills = 0
        var overwrittenSkills = 0

        do {
            try applyAttachments(attachmentPlan, staging: staging)
            if let assetPlan = record.assets, let spaceAssets { try await spaceAssets.apply(assetPlan, staging: staging) }
            if let databasePlan = record.database {
                let beforeDatabaseWrite = record
                record.database = try await recoveryDatabase.apply(databasePlan) { observed in
                    var durable = beforeDatabaseWrite
                    durable.database = observed
                    try self.persistRecoveryRecord(durable, root: recoveryRoot)
                }
            }
            for (index, session) in sessions.enumerated() {
                try await sessionService.save(session)
                progress?(0.4 + 0.2 * Double(index + 1) / Double(max(sessions.count, 1)))
            }
            for (index, memory) in memories.enumerated() {
                try await memoryService.save(memory)
                progress?(0.6 + 0.1 * Double(index + 1) / Double(max(memories.count, 1)))
            }

            let skillsRoot = staging.appendingPathComponent("skills", isDirectory: true)
            if fileManager.fileExists(atPath: skillsRoot.path) {
                let importable = skillImportEntries(in: skillsRoot)
                for (index, entry) in importable.enumerated() {
                    let overwrote = try importSkillWithRecoveryPoint(
                        entry: entry, record: &record, recoveryRoot: recoveryRoot
                    )
                    if overwrote { overwrittenSkills += 1 } else { importedSkills += 1 }
                    progress?(0.7 + 0.3 * Double(index + 1) / Double(max(importable.count, 1)))
                }
            }
            // One transaction, idempotent by request identity; restoring never rewinds existing usage.
            try await usageService.importRecords(usage)
            if let assetPlan = record.assets { try await adoptWorkspaces?(assetPlan.workspaces) }
            try await sessionService.invalidateRestoredSnapshots(ids: sessions.map(\.id))
            try await verifyRestored(record: record, usage: usage)
        } catch {
            writeError = error
        }

        if let writeError {
            let outcome = await rollbackSafely(record: record, recoveryRoot: recoveryRoot)
            switch outcome {
            case .complete:
                Self.removeQuietly(recoveryRoot)
                HubLogger.shared.error("Restore failed and was fully rolled back")
                throw BackupError.rolledBack(writeError.localizedDescription)
            case .incomplete:
                // 回滚不完整：材料必须保留并暴露路径，绝不谎称「原数据未变」
                HubLogger.shared.error(
                    "Restore rollback incomplete; recovery material retained in the originating space"
                )
                throw BackupError.restoreIncomplete(
                    writeError.localizedDescription,
                    recoveryPath: recoveryRoot.path
                )
            }
        }

        record.committed = true
        try persistRecoveryRecord(record, root: recoveryRoot)
        var warnings = plan.warnings
        record.verificationMetricRecorded = await recordRestoreMetric(.restoreVerified, id: "restore-verified:" + attemptID.uuidString)
        do {
            try persistRecoveryRecord(record, root: recoveryRoot)
            if record.verificationMetricRecorded != true { warnings.append(.metricsPending) }
            try finalizeRestorePoint(record: record, root: recoveryRoot)
        } catch { warnings.append(.restorePointPending); HubLogger.shared.warning("Verified restore point finalization will be retried") }
        NotificationCenter.default.post(name: .agroomSpaceRestored, object: spaceName)
        return RestoreSummary(
            sessions: sessions.count,
            memories: memories.count,
            skills: importedSkills + overwrittenSkills,
            attachments: attachmentResult.rewrites.count,
            workspaces: reboundWorkspaces,
            manifest: plan.manifest,
            rolledBack: 0,
            coverage: plan.coverage,
            verificationSucceeded: true,
            warnings: warnings,
            restorePointID: record.restoreID
        )
    }

    /// 处理上次中断遗留的恢复记录：完成回滚后清理；回滚不完整则保留材料并报错。
    /// 进程在恢复中途被杀时，恢复入口先调用它，避免半恢复结果被当成现状
    public func recoverInterruptedRestoreIfNeeded() async throws {
        try await ResourceMaintenance.withExclusive(maintenanceKeys) { try await self.recoverUnderLease() }
    }

    private func recoverUnderLease() async throws {
        let root = recoveryDirectoryURL
        let recordURL = root.appendingPathComponent("recovery.json")
        guard fileManager.fileExists(atPath: recordURL.path) else { return }
        let decoder = Self.recoveryDecoder()
        guard let data = try? AppDirectory(url: root, create: false).read("recovery.json", limit: Self.maxExtractedByteCount),
              var record = try? decoder.decode(RestoreRecoveryRecord.self, from: data) else {
            throw BackupError.restoreIncomplete(
                "interrupted restore record is unreadable",
                recoveryPath: root.path
            )
        }
        if record.committed == true {
            if record.verificationMetricRecorded != true, let id = record.restoreID {
                record.verificationMetricRecorded = await recordRestoreMetric(.restoreVerified, id: "restore-verified:" + id.uuidString)
                try persistRecoveryRecord(record, root: root)
            }
            try finalizeRestorePoint(record: record, root: root)
            return
        }
        switch await rollbackSafely(record: record, recoveryRoot: root) {
        case .complete:
            Self.removeQuietly(root)
            HubLogger.shared.info("Interrupted restore rolled back from recovery record")
        case .incomplete(let failures):
            throw BackupError.restoreIncomplete(
                "interrupted restore rollback incomplete: " + failures.joined(separator: "; "),
                recoveryPath: root.path
            )
        }
    }

    // MARK: - Preflight Helpers

    /// 解包到临时目录（调用方负责清理）；顺带清掉 Finder 的资源叉目录。
    private func extract(_ zipURL: URL) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try await Self.runDitto(["-x", "-k", zipURL.path, staging.path])
        } catch {
            Self.removeQuietly(staging)
            throw error
        }
        let macosx = staging.appendingPathComponent("__MACOSX", isDirectory: true)
        if fileManager.fileExists(atPath: macosx.path) {
            Self.removeQuietly(macosx)
        }
        // 解包后立刻核对体积与链接范围：超大包或逃逸链接在下一步读取前就拒绝
        try Self.validateExtractedTree(at: staging)
        return staging
    }

    // MARK: - Extraction Safety（解包安全）

    /// 解包树的安全边界：文件数/总字节数上限；不接纳链接或特殊文件。
    ///
    /// 放在读取任何段之前：否则「压缩炸弹」会先撑爆磁盘，逃逸链接会把读取引向
    /// 包外的任意文件（如通过 `sessions.json` 指向 `~/.ssh/id_rsa`）。
    /// 只统计普通文件；链接自身不计字节，但链接目标必须落在包内。
    static func validateExtractedTree(at root: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { return }

        var fileCount = 0
        var entryCount = 0
        var totalBytes = 0
        for case let url as URL in enumerator {
            entryCount += 1
            guard entryCount <= maxExtractedFileCount else { throw BackupError.preflightFailed("Backup package has too many entries") }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw BackupError.preflightFailed("Backup packages cannot contain links or special files")
            }
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            if fileCount > maxExtractedFileCount {
                throw BackupError.preflightFailed(
                    "package contains too many files (limit \(maxExtractedFileCount))"
                )
            }
            let size = values.fileSize ?? 0
            if size < 0 || size > maxExtractedByteCount - totalBytes {
                throw BackupError.preflightFailed(
                    "package is too large (limit \(maxExtractedByteCount) bytes)"
                )
            }
            totalBytes += size
        }
    }

    /// 预检：清单 → 版本 → 校验和 → 空间 → 同名技能冲突。
    private func plan(staging: URL) async throws -> RestorePlan {
        let manifest = try Self.readManifest(from: staging)
        guard manifest.formatVersion <= Self.currentFormatVersion else {
            throw BackupError.unsupportedFormat(manifest.formatVersion)
        }

        var corrupt: [String] = []
        let sections = manifest.sections ?? []
        // 新版格式要求段清单：缺失即拒绝，不能按「包里没内容」静默放过
        if manifest.formatVersion >= Self.sectionsRequiredVersion, manifest.sections == nil {
            throw BackupError.preflightFailed(
                "format v\(manifest.formatVersion) requires a section list in manifest.json"
            )
        }
        for section in sections {
            // 段路径必须留在包内：否则清单可把读取引向任意绝对路径
            try Self.validateRelativePath(section.path)
            let url = staging.appendingPathComponent(section.path)
            guard fileManager.fileExists(atPath: url.path) else {
                corrupt.append("\(section.path) (missing)")
                continue
            }
            if section.path.hasSuffix("/") || Self.isDirectory(url) {
                if Self.directoryDigest(url) != section.sha256 || Self.directoryByteCount(url) != section.byteCount {
                    corrupt.append("\(section.path) (checksum mismatch)")
                }
                continue
            }
            guard let data = try? AppDirectory(url: staging, create: false).read(section.path, limit: Self.maximumJSONSectionBytes) else {
                corrupt.append("\(section.path) (unreadable)")
                continue
            }
            if Self.digest(data) != section.sha256 {
                corrupt.append("\(section.path) (checksum mismatch)")
            } else if data.count != section.byteCount {
                // 清单自述的字节数与实际不符（即便校验和一致也说明清单本身不可信）
                corrupt.append("\(section.path) (byte count mismatch)")
            } else if let declared = Self.jsonArrayCount(data), declared != section.count {
                // 清单自述的条数与内容不符：防止「声明导入 N 条、实际 M 条」
                corrupt.append("\(section.path) (record count \(declared) != declared \(section.count))")
            }
        }
        // 声明与包内容互相核对：缺失必需段或有未声明段都拒绝（仅新版格式）
        if manifest.formatVersion >= Self.sectionsRequiredVersion {
            try Self.validateSectionCoverage(
                sections: sections,
                staging: staging,
                formatVersion: manifest.formatVersion
            )
        }

        // 同名技能冲突：覆盖前把完整原值保存到当前空间的恢复点。
        let conflicting = (try? conflictingSkillNames(staging: staging)) ?? []

        let spaceData = try decodeSpaceData(staging: staging)
        let assets = try decodeAssets(staging: staging)
        var conflictingApps: [String] = []
        if let assets {
            if let spaceAssets {
                try spaceAssets.validate(assets, staging: staging, sourceSpace: manifest.space)
                conflictingApps = try await spaceAssets.conflicts(assets, staging: staging)
            }
            else if assets.recordCount != 0 { throw BackupError.preflightFailed("Space assets are unavailable for this space") }
            if assets.recordCount != sections.first(where: { $0.path == "space-assets.json" })?.count { corrupt.append("space-assets.json (record count mismatch)") }
        }
        let preservedMailDrafts: Int
        if let spaceData {
            let refs = spaceData.blobReferences
            let declaredContents = sections.first { $0.path == "space-blobs" }
            guard refs.isEmpty || (manifest.formatVersion >= 6 && declaredContents != nil) else {
                throw BackupError.preflightFailed("Database content references require the current package format")
            }
            let contents: SpaceBackupBlobs?
            if let declaredContents {
                let source = SpaceBackupBlobs(root: staging.appendingPathComponent("space-blobs"))
                try source.validateInventory(refs)
                if declaredContents.count != refs.count { corrupt.append("space-blobs (record count mismatch)") }
                contents = source
            } else { contents = SpaceBackupBlobs(root: staging.appendingPathComponent("space-blobs")) }
            preservedMailDrafts = try await databaseStore(blobs: contents).inspect(spaceData, sourceSpace: manifest.space)
            if sections.first(where: { $0.path == "space-data.json" })?.count != spaceData.recordCount {
                corrupt.append("space-data.json (record count mismatch)")
            }
        } else { preservedMailDrafts = 0 }
        var warnings: [BackupWarning] = []
        if spaceData == nil { warnings.append(.legacyPartial) }
        if let spaceData {
            if spaceData.count("mail_accounts") + spaceData.count("mcp_servers") + spaceData.count("mysql_connections") > 0 { warnings.append(.credentialsRequired) }
            warnings.append(.tasksPaused)
        }
        if preservedMailDrafts > 0 { warnings.append(.protectedMailDrafts) }
        if !(assets?.omittedWorkspaces.isEmpty ?? true) { warnings.append(.externalWorkspacesOmitted) }
        if !(assets?.omittedLinks.isEmpty ?? true) { warnings.append(.omittedLinks) }
        let missingAttachments: Int
        if !corrupt.contains(where: { $0.hasPrefix("sessions.json") || $0.hasPrefix("attachment-map.json") }) {
            let sourceSessions = try decodeSessions(staging: staging, decoder: Self.decoder())
            let (_, rebuilt) = try ProductTaskRunStore.augmentBackup(spaceData, sessions: sourceSessions.map(Self.portableSession), sourceSpace: manifest.space)
            if rebuilt > 0 { warnings.append(.taskHistoryRebuilt) }
            let attachmentMap = try decodeAttachments(staging: staging, decoder: Self.decoder())
            let referenced = Set(sourceSessions.flatMap(\.messages).flatMap(\.allAttachments).map(\.path))
            guard Set(attachmentMap.map(\.originalPath)).count == attachmentMap.count,
                  Set(attachmentMap.map(\.originalPath)).isSubset(of: referenced) else { throw BackupError.preflightFailed("Invalid attachment inventory") }
            missingAttachments = referenced.count - attachmentMap.count
            if sourceSessions.count != manifest.sessionCount { corrupt.append("sessions.json (manifest count mismatch)") }
        } else { missingAttachments = manifest.coverage?.first(where: { $0.kind == "missingAttachments" })?.records ?? 0 }
        if missingAttachments > 0 { warnings.append(.missingAttachments) }
        let coverage = Self.coverage(spaceData, sessions: manifest.sessionCount, memories: manifest.memoryCount,
            skills: manifest.skillCount, attachments: sections.first { $0.path == "attachment-map.json" }?.count ?? 0,
            workspaces: sections.first { $0.path == "workspaces.json" }?.count ?? 0,
            usage: sections.first { $0.path == "usage.json" }?.count ?? 0, assets: assets, missingAttachments: missingAttachments)
        if let declared = manifest.coverage, declared != coverage { corrupt.append("manifest.json (coverage mismatch)") }
        return RestorePlan(
            manifest: manifest,
            spaceMismatch: manifest.space != spaceName,
            corruptSections: corrupt,
            integrityUnverified: manifest.sections == nil,
            conflictingSkills: conflicting,
            attachmentCount: sections.first { $0.path == "attachment-map.json" }?.count ?? 0,
            workspaceCount: sections.first { $0.path == "workspaces.json" }?.count ?? 0,
            coverage: coverage,
            preservedMailDrafts: preservedMailDrafts,
            warnings: warnings,
            conflictingApps: conflictingApps,
            omittedPaths: (assets?.omittedWorkspaces ?? []) + (assets?.omittedLinks ?? [])
        )
    }

    /// 段路径必须是包内相对路径：拒绝绝对路径与 `..` 组件，避免目录穿越。
    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw BackupError.preflightFailed("section path must be relative: \(path)")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else {
            throw BackupError.preflightFailed("section path escapes the package: \(path)")
        }
    }

    /// 声明与包内容互相核对（新版格式）：必需段必须在清单里；包内的数据段必须在清单里。
    /// 后者防止「包比声明多」——用户会以为导入了实际没写进去的内容。
    ///
    /// 必需段随格式版本演进：v3 起工作区映射与附件映射也必须在清单里声明
    /// （即便内容为空数组），否则恢复端无法区分「本就没有这项」与「这项被明丢了」。
    /// 默认按 v2 判定，供旧格式（v2，sectionsRequiredVersion）调用方沿用
    static func validateSectionCoverage(
        sections: [BackupManifest.Section],
        staging: URL,
        formatVersion: Int = 2
    ) throws {
        var required = formatVersion >= 3
            ? ["sessions.json", "memories.json", "workspaces.json", "attachment-map.json"]
            : ["sessions.json", "memories.json"]
        if formatVersion >= 4 { required.append("usage.json") }
        if formatVersion >= 5 { required.append("space-data.json") }
        if formatVersion >= 5 { required.append("space-assets.json") }
        if formatVersion >= 6 { required.append("space-blobs") }
        let known = [
            "sessions.json", "memories.json", "workspaces.json",
            "attachment-map.json", "skills", "attachments", "usage.json", "space-data.json", "space-assets.json", "space-assets", "space-blobs"
        ]
        let declared = Set(sections.map {
            $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        })
        guard declared.count == sections.count, declared.isSubset(of: Set(known)),
              sections.allSatisfy({ $0.count >= 0 && $0.byteCount >= 0 }) else {
            throw BackupError.preflightFailed("Invalid or duplicate backup sections")
        }
        for name in required where !declared.contains(name) {
            throw BackupError.preflightFailed("manifest is missing required section \(name)")
        }
        for name in known where !declared.contains(name) {
            let url = staging.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                throw BackupError.preflightFailed("package contains undeclared section \(name)")
            }
        }
    }

    /// 顶层是 JSON 数组的数据段返回其条数；其他形态（对象/非 JSON）返回 nil。
    private static func jsonArrayCount(_ data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return (root as? [Any])?.count
    }

    private func conflictingSkillNames(staging: URL) throws -> [String] {
        let skillsRoot = staging.appendingPathComponent("skills", isDirectory: true)
        guard fileManager.fileExists(atPath: skillsRoot.path) else { return [] }
        let entries = (try? fileManager.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var names: [String] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            guard fileManager.fileExists(atPath: entry.appendingPathComponent("SKILL.md").path) else { continue }
            if let target = try? skillStore.folderURL(for: entry.lastPathComponent), fileManager.fileExists(atPath: target.path) {
                names.append(entry.lastPathComponent)
            }
        }
        return names.sorted()
    }

    private static func readManifest(from staging: URL) throws -> BackupManifest {
        guard let data = try? AppDirectory(url: staging, create: false).read("manifest.json", limit: 1024 * 1024),
              let manifest = try? decoder().decode(BackupManifest.self, from: data) else {
            throw BackupError.manifestMissing
        }
        return manifest
    }

    /// 会话段：文件缺失按 0 处理（老包兼容），文件在但解码失败 → 中止报错。
    private func decodeSessions(staging: URL, decoder: JSONDecoder) throws -> [ChatSession] {
        let url = staging.appendingPathComponent("sessions.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            return try decoder.decode([ChatSession].self, from: Data(contentsOf: url))
        } catch {
            throw BackupError.corruptSection("sessions.json", error.localizedDescription)
        }
    }

    private func decodeMemories(staging: URL, decoder: JSONDecoder) throws -> [MemoryItem] {
        let url = staging.appendingPathComponent("memories.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            return try decoder.decode([MemoryItem].self, from: Data(contentsOf: url))
        } catch {
            throw BackupError.corruptSection("memories.json", error.localizedDescription)
        }
    }

    private func decodeSpaceData(staging: URL) throws -> SpaceDatabaseBackup? {
        let root = try AppDirectory(url: staging, create: false)
        guard root.exists("space-data.json") else { return nil }
        do { return try JSONDecoder().decode(SpaceDatabaseBackup.self, from: root.read("space-data.json", limit: SpaceDatabaseBackupStore.maximumBytes)) }
        catch { throw BackupError.corruptSection("space-data.json", "Invalid space database data") }
    }

    private func decodeAssets(staging: URL) throws -> SpaceAssetsArchive? {
        let root = try AppDirectory(url: staging, create: false)
        guard root.exists("space-assets.json") else { return nil }
        do { return try JSONDecoder().decode(SpaceAssetsArchive.self, from: root.read("space-assets.json", limit: SpaceAssetsBackupStore.maximumInventoryBytes)) }
        catch { throw BackupError.corruptSection("space-assets.json", "Invalid space asset inventory") }
    }

    private static func coverage(_ database: SpaceDatabaseBackup?, sessions: Int, memories: Int,
        skills: Int, attachments: Int, workspaces: Int, usage: Int, assets: SpaceAssetsArchive? = nil, missingAttachments: Int = 0) -> [BackupCoverageItem] {
        var result: [BackupCoverageItem] = [
            .init(kind: "sessions", records: sessions), .init(kind: "memories", records: memories),
            .init(kind: "skills", records: skills), .init(kind: "attachments", records: 0, files: attachments),
            .init(kind: "workspaces", records: workspaces), .init(kind: "usage", records: usage)
        ]
        if let database {
            for (kind, tables) in [
                ("agents", ["agents"]), ("knowledge", ["knowledge_items"]),
                ("mail", ["mail_accounts", "mail_messages", "mail_drafts"]),
                ("schedules", ["scheduled_tasks", "scheduled_runs"]),
                ("connections", ["mcp_servers", "mysql_connections"]),
                ("preferences", ["product_preferences", "product_events", "workspace_projects"]), ("tasks", ["team_tasks", "product_task_runs", "product_job_runs"]),
                ("artifacts", ["artifact_versions"])
            ] { result.append(.init(kind: kind, records: tables.reduce(0) { $0 + database.count($1) })) }
        }
        if let assets {
            result += [
                .init(kind: "apps", records: assets.apps.count + assets.drafts.count,
                    files: assets.apps.reduce(0) { $0 + $1.files }),
                .init(kind: "projectFiles", records: assets.projects.count, files: assets.files.filter { $0.kind == .project }.count),
                .init(kind: "databases", records: assets.files.filter { $0.kind == .database }.count),
                .init(kind: "knowledgeAssets", records: 0, files: assets.files.filter { $0.kind == .knowledge }.count),
                .init(kind: "skillHistory", records: 0, files: assets.files.filter { $0.kind == .skillHistory }.count),
                .init(kind: "omittedWorkspaces", records: assets.omittedWorkspaces.count),
                .init(kind: "omittedLinks", records: assets.omittedLinks.count)
            ]
        }
        if missingAttachments > 0 { result.append(.init(kind: "missingAttachments", records: missingAttachments)) }
        return result
    }

    private func verifyRestored(record: RestoreRecoveryRecord, usage: [ProviderUsageRecord]) async throws {
        for entry in record.sessions {
            guard let id = UUID(uuidString: entry.id), let current = try await sessionService.fetch(id: id),
                  try recoveryDigest(current) == entry.afterDigest else {
                throw BackupError.preflightFailed("Restored conversation verification failed")
            }
        }
        for entry in record.memories {
            guard let id = UUID(uuidString: entry.id), let current = try await memoryService.fetch(id: id),
                  try recoveryDigest(current) == entry.afterDigest else {
                throw BackupError.preflightFailed("Restored memory verification failed")
            }
        }
        guard try await usageService.missingIDs(usage.map(\.id)).isEmpty else {
            throw BackupError.preflightFailed("Restored usage verification failed")
        }
        if let database = record.database { try await recoveryDatabase(at: recoveryDirectoryURL).verify(database) }
        if let assets = record.assets, let spaceAssets { try await spaceAssets.verify(assets) }
        for entry in record.skills {
            guard let expected = entry.afterDigest, Self.directoryDigest(try skillStore.folderURL(for: entry.name)) == expected else {
                throw BackupError.preflightFailed("Restored skill verification failed")
            }
        }
        for (path, expected) in record.attachmentReceipts ?? [:] {
            let url = URL(fileURLWithPath: path)
            let current = try BackupFileIO.receipt(url.lastPathComponent, in: AppDirectory(url: url.deletingLastPathComponent(), create: false), limit: Self.maxExtractedByteCount)
            guard current.sha256 == expected.sha256 else { throw BackupError.preflightFailed("Restored attachment verification failed") }
        }
    }

    private func freeze(_ url: URL) throws -> (root: URL, url: URL, fingerprint: String) {
        let source = try AppDirectory(url: url.deletingLastPathComponent(), create: false)
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("agroom-backup-input-" + UUID().uuidString)
        let target = try AppDirectory(url: temporary, create: true)
        do {
            let receipt = try BackupFileIO.copy(url.lastPathComponent, from: source, to: target, as: "backup.zip", limit: Self.maxExtractedByteCount)
            return (temporary, temporary.appendingPathComponent("backup.zip"), receipt.sha256)
        } catch { Self.removeQuietly(temporary); throw error }
    }

    private func recordRestoreMetric(_ kind: ProductEventKind, id: String) async -> Bool {
        do {
            guard try await sessionService.databaseQueue.read({ try $0.tableExists("product_events") }) else { return true }
            try await ProductPreferencesService(databaseQueue: sessionService.databaseQueue).record(kind, id: id)
            return true
        } catch { HubLogger.shared.warning("Restore metric could not be saved; recovery will retry"); return false }
    }

    private struct AttachmentRestorePlan {
        struct Copy { let packed: String; let destination: URL; let receipt: BackupFileIO.Receipt }
        var rewrites: [String: String] = [:]
        var copies: [Copy] = []
        var created: [String] { copies.map { $0.destination.path } }
    }

    private func prepareAttachments(entries: [BackupAttachmentEntry], staging: URL) throws -> AttachmentRestorePlan {
        let root = try AppDirectory(url: staging, create: false)
        var plan = AttachmentRestorePlan()
        for entry in entries {
            guard entry.file.hasPrefix("attachments/"), entry.originalPath.hasPrefix("/"), plan.rewrites[entry.originalPath] == nil else {
                throw BackupError.preflightFailed("Invalid attachment inventory")
            }
            let expected = try BackupFileIO.receipt(entry.file, in: root, limit: Self.maxExtractedByteCount)
            let original = URL(fileURLWithPath: entry.originalPath)
            let directory = AttachmentService.isAudio(url: original) ? audioDirectory : attachmentsDirectory
            if Self.standardizedPath(original.deletingLastPathComponent()) == Self.standardizedPath(directory),
               let currentDirectory = try? AppDirectory(url: directory, create: false),
               let current = try? BackupFileIO.receipt(original.lastPathComponent, in: currentDirectory, limit: Self.maxExtractedByteCount),
               current.sha256 == expected.sha256 {
                plan.rewrites[entry.originalPath] = entry.originalPath
                continue
            }
            let target = directory.appendingPathComponent(UUID().uuidString + "-" + original.lastPathComponent)
            plan.copies.append(.init(packed: entry.file, destination: target, receipt: expected))
            plan.rewrites[entry.originalPath] = target.path
        }
        return plan
    }

    private func applyAttachments(_ plan: AttachmentRestorePlan, staging: URL) throws {
        let root = try AppDirectory(url: staging, create: false)
        for copy in plan.copies {
            let target = try AppDirectory(url: copy.destination.deletingLastPathComponent(), create: true)
            try BackupFileIO.copy(copy.packed, from: root, to: target, as: copy.destination.lastPathComponent,
                limit: Self.maxExtractedByteCount, expected: copy.receipt)
        }
    }

    /// 附件映射段：文件缺失按空处理（v2 老包没有此段），文件在但解码失败 → 中止报错
    private func decodeAttachments(staging: URL, decoder: JSONDecoder) throws -> [BackupAttachmentEntry] {
        let url = staging.appendingPathComponent("attachment-map.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            return try decoder.decode([BackupAttachmentEntry].self, from: Data(contentsOf: url))
        } catch {
            throw BackupError.corruptSection("attachment-map.json", error.localizedDescription)
        }
    }

    /// 工作区映射段：文件缺失按空处理（v2 老包没有此段），文件在但解码失败 → 中止报错
    private func decodeWorkspaces(staging: URL, decoder: JSONDecoder) throws -> [ChatWorkspace] {
        let url = staging.appendingPathComponent("workspaces.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            return try decoder.decode([ChatWorkspace].self, from: Data(contentsOf: url))
        } catch {
            throw BackupError.corruptSection("workspaces.json", error.localizedDescription)
        }
    }

    // MARK: - Restore Rebuild（附件落地与工作区重绑定）

    /// 会话工作区重绑定：包内工作区 → 当前空间已有工作区。
    /// 默认工作区映射到当前空间默认工作区；非默认工作区按同路径或同名复用已有登记；
    /// 匹配不到的会话回退默认工作区（`workspaceId = nil`），不凭空创建目录。
    /// 返回重绑定成功的非默认工作区数
    private static func rebindWorkspaces(
        sessions: inout [ChatSession],
        source: [ChatWorkspace],
        target: [ChatWorkspace]
    ) -> (count: Int, mappings: [String: String]) {
        guard let targetDefault = target.first(where: { $0.isDefault }) else { return (0, [:]) }
        var remap: [String: UUID] = [:]
        var rebound = 0
        for workspace in source {
            if workspace.isDefault {
                remap[workspace.id.uuidString] = targetDefault.id
                continue
            }
            let sourcePath = standardizedPath(URL(fileURLWithPath: workspace.path))
            let match = target.first { standardizedPath(URL(fileURLWithPath: $0.path)) == sourcePath }
                ?? target.first {
                    !$0.isDefault && $0.name.caseInsensitiveCompare(workspace.name) == .orderedSame
                }
            guard let match else { continue }
            remap[workspace.id.uuidString] = match.id
            rebound += 1
        }
        for index in sessions.indices {
            guard let current = sessions[index].workspaceId else { continue }
            sessions[index].workspaceId = remap[current]?.uuidString
        }
        return (rebound, remap.mapValues(\.uuidString))
    }

    /// 按「原路径 → 新路径」改写消息附件的落地路径（id / 名称 / 图片标记保持不变）
    private static func rewriteAttachments(in session: inout ChatSession, with rewrites: [String: String], targetSpace: AppSpace?) {
        func remapAttachments(_ values: [ChatAttachment]?) -> [ChatAttachment]? {
            values?.map { attachment in
                ChatAttachment(id: attachment.id, name: attachment.name,
                    path: rewrites[attachment.path] ?? attachment.path, isImage: attachment.isImage,
                    importWarning: attachment.importWarning,
                    sourceArtifactVersionID: attachment.sourceArtifactVersionID,
                    sourceArtifactSpace: attachment.sourceArtifactVersionID == nil ? attachment.sourceArtifactSpace : targetSpace)
            }
        }
        func remap(_ entries: [DispatcherTraceEntry]?) -> [DispatcherTraceEntry]? {
            entries?.map { entry in
                func mapped(_ value: TaskArtifact) -> TaskArtifact {
                    var copy = value; copy.path = rewrites[value.path] ?? value.path
                    if copy.sourceSpace != nil { copy.sourceSpace = targetSpace }
                    return copy
                }
                return DispatcherTraceEntry(toolName: entry.toolName, argumentsPreview: entry.argumentsPreview,
                    resultPreview: entry.resultPreview, argumentsFull: entry.argumentsFull, resultFull: entry.resultFull,
                    artifact: entry.artifact.map(mapped), artifacts: entry.producedArtifacts?.map(mapped), citations: entry.citations, duration: entry.duration, succeeded: entry.succeeded, inferReferences: false)
            }
        }
        for index in session.messages.indices {
            session.messages[index].trace = remap(session.messages[index].trace)
            if var versions = session.messages[index].variations {
                for variation in versions.indices {
                    versions[variation].trace = remap(versions[variation].trace)
                    versions[variation].attachments = remapAttachments(versions[variation].attachments)
                }
                session.messages[index].variations = versions
            }
            session.messages[index].attachments = remapAttachments(session.messages[index].attachments)
        }
    }

    private static func portableSession(_ source: ChatSession) -> ChatSession {
        var session = source
        session.pendingConfirmation = nil
        session.pendingQuestion = nil
        let interrupted: Set<TaskRunStatus> = [.running, .waitingForConfirmation, .waitingForInput]
        for index in session.messages.indices {
            session.messages[index].clearProviderHistory()
            if let status = session.messages[index].runStatus, interrupted.contains(status) { session.messages[index].runStatus = .recoveryRequired }
            if var variations = session.messages[index].variations {
                for index in variations.indices {
                    if let status = variations[index].runStatus, interrupted.contains(status) { variations[index].runStatus = .recoveryRequired }
                }
                session.messages[index].variations = variations
            }
        }
        return session
    }

    private static func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 回滚到恢复记录描述的恢复前状态：覆盖项写回 before-image，新增项删除。
    /// 逐项收集失败原因；全部成功才返回 `.complete`，否则必须保留恢复材料
    private func rollback(record: RestoreRecoveryRecord, recoveryRoot: URL) async -> RollbackOutcome {
        var failures: [String] = []
        do { try await usageService.removeRestoredRecords(record.usageIDs ?? []) }
        catch { failures.append("Usage receipt rollback failed") }
        if let database = record.database {
            do { try await recoveryDatabase(at: recoveryRoot).rollback(database) }
            catch { failures.append("Space database rollback failed") }
        }
        for entry in record.sessions.reversed() {
            do {
                if let expected = entry.afterDigest, let id = UUID(uuidString: entry.id) {
                    let current = try await sessionService.fetch(id: id)
                    let digest = try current.map { try recoveryDigest($0) }
                    if digest == (try entry.before.map { try recoveryDigest($0) }) { continue }
                    guard digest == expected else { throw MaintenanceError.busy }
                }
                if let before = entry.before {
                    try await sessionService.save(before)
                } else if let id = UUID(uuidString: entry.id) {
                    try await sessionService.delete(id: id)
                }
            } catch {
                failures.append("session \(entry.id): \(error.localizedDescription)")
            }
        }
        for entry in record.memories.reversed() {
            do {
                if let expected = entry.afterDigest, let id = UUID(uuidString: entry.id) {
                    let current = try await memoryService.fetch(id: id)
                    let digest = try current.map { try recoveryDigest($0) }
                    if digest == (try entry.before.map { try recoveryDigest($0) }) { continue }
                    guard digest == expected else { throw MaintenanceError.busy }
                }
                if let before = entry.before {
                    try await memoryService.save(before)
                } else if let id = UUID(uuidString: entry.id) {
                    try await memoryService.delete(id: id)
                }
            } catch {
                failures.append("memory \(entry.id): \(error.localizedDescription)")
            }
        }
        for entry in record.skills.reversed() {
            do {
                let target = try skillStore.folderURL(for: entry.name)
                if let expected = entry.afterDigest {
                    let current = fileManager.fileExists(atPath: target.path) ? Self.directoryDigest(target) : nil
                    if current == entry.beforeDigest { continue }
                    guard current == expected else { throw MaintenanceError.busy }
                }
                if let backupRelative = entry.backupFolder {
                    try restoreSkillFolder(
                        name: entry.name,
                        backupRelative: backupRelative,
                        recoveryRoot: recoveryRoot
                    )
                } else {
                    // 本次新增：删除即还原（不存在视为已还原）
                    if fileManager.fileExists(atPath: target.path) { try skillStore.delete(name: entry.name) }
                }
            } catch {
                failures.append("skill \(entry.name): \(error.localizedDescription)")
            }
        }
        if let assets = record.assets, let spaceAssets {
            do {
                try await removeWorkspaces?(assets.workspaces)
                try await spaceAssets.rollback(assets, recovery: recoveryRoot)
            } catch { failures.append("Space files or mini-app rollback failed") }
        }
        // 本次新建的附件文件：删除即还原（不存在视为已还原）
        for path in (record.attachments ?? []).reversed() {
            do {
                if fileManager.fileExists(atPath: path) {
                    if let expected = record.attachmentReceipts?[path] {
                        let url = URL(fileURLWithPath: path)
                        try BackupFileIO.removeUnchanged(url.lastPathComponent, in: AppDirectory(url: url.deletingLastPathComponent(), create: false), expected: expected, limit: Self.maxExtractedByteCount)
                    } else { try fileManager.removeItem(atPath: path) }
                }
            } catch {
                failures.append(
                    "attachment \(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return failures.isEmpty ? .complete : .incomplete(failures)
    }

    /// A cancelled import still must finish rollback. The original maintenance
    /// leases remain held while this uncancelled child owns the same lease keys.
    private func rollbackSafely(record: RestoreRecoveryRecord, recoveryRoot: URL) async -> RollbackOutcome {
        let owned = ResourceMaintenance.owned
        return await Task.detached {
            await ResourceMaintenance.$owned.withValue(owned) {
                await BackupContentCancellation.$current.withValue(nil) {
                    await self.rollback(record: record, recoveryRoot: recoveryRoot)
                }
            }
        }.value
    }

    // MARK: - Recovery Material（恢复材料）
    private func recoveryDigest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    /// 恢复材料目录：本空间目录下，独立于技能与数据库文件，不进入备份包
    private var recoveryDirectoryURL: URL {
        skillStore.skillsDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("backup-restore-recovery", isDirectory: true)
    }

    private func persistRecoveryRecord(_ record: RestoreRecoveryRecord, root: URL) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(record)
        guard data.count <= Self.maxExtractedByteCount else { throw BackupError.preflightFailed("Recovery metadata exceeds its size limit") }
        try AppDirectory(url: root, create: true).write(data, name: "recovery.json")
    }

    /// Recovery needs full timestamp precision for CAS checks. Accept the old
    /// ISO dates too, but write native reference-date doubles from now on.
    private static func recoveryDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: number) }
            let string = try value.decode(String.self)
            let format = ISO8601DateFormatter()
            if let date = format.date(from: string) { return date }
            format.formatOptions.insert(.withFractionalSeconds)
            guard let date = format.date(from: string) else { throw BackupError.preflightFailed("Invalid recovery timestamp") }
            return date
        }
        return decoder
    }

    private var restorePointsDirectory: URL {
        skillStore.skillsDirectoryURL.deletingLastPathComponent().appendingPathComponent("restore-points")
    }

    private func finalizeRestorePoint(record: RestoreRecoveryRecord, root: URL) throws {
        guard record.committed == true, let id = record.restoreID else { Self.removeQuietly(root); return }
        let parent = try AppDirectory(url: restorePointsDirectory, create: true)
        let source = try AppDirectory(url: root.deletingLastPathComponent(), create: false)
        let name = id.uuidString.lowercased()
        guard !parent.exists(name), renameatx_np(source.fd, root.lastPathComponent, parent.fd, name, UInt32(RENAME_EXCL)) == 0,
              fsync(parent.fd) == 0, fsync(source.fd) == 0 else { throw NativeAppError(.storage) }
        let points = try restorePointRecords()
        for point in points.dropFirst(7) {
            do { try parent.removeTree(point.0.id.uuidString.lowercased()) }
            catch { HubLogger.shared.warning("An older restore point could not be pruned") }
        }
    }

    private func restorePointRecords() throws -> [(BackupRestorePoint, RestoreRecoveryRecord)] {
        guard fileManager.fileExists(atPath: restorePointsDirectory.path) else { return [] }
        let root = try AppDirectory(url: restorePointsDirectory, create: false)
        var points: [(BackupRestorePoint, RestoreRecoveryRecord)] = []
        for name in try root.names() {
            guard let id = UUID(uuidString: name) else { continue }
            let child = try root.child(name, create: false)
            var record = try Self.recoveryDecoder().decode(RestoreRecoveryRecord.self, from: child.read("recovery.json", limit: Self.maxExtractedByteCount))
            guard record.committed == true, record.restoreID == id, let createdAt = record.createdAt else { continue }
            if let database = record.database {
                let pointRoot = restorePointsDirectory.appendingPathComponent(name)
                let normalized = try recoveryDatabase(at: pointRoot).normalized(database)
                if normalized != database { record.database = normalized; try persistRecoveryRecord(record, root: pointRoot) }
            }
            points.append((.init(id: id, createdAt: createdAt, sessions: record.sessions.count, memories: record.memories.count,
                skills: record.skills.count, files: (record.attachments?.count ?? 0) + (record.assets?.files.count ?? 0)), record))
        }
        return points.sorted { $0.0.createdAt > $1.0.createdAt }
    }

    public func restorePoints() async throws -> [BackupRestorePoint] {
        try await BackupContentCancellation.run {
            try await ResourceMaintenance.withExclusive(maintenanceKeys) {
                try await self.recoverUnderLease()
                let records = try self.restorePointRecords()
                for (point, saved) in records where saved.verificationMetricRecorded == false {
                    if await self.recordRestoreMetric(.restoreVerified, id: "restore-verified:" + point.id.uuidString) {
                        var updated = saved; updated.verificationMetricRecorded = true
                        try self.persistRecoveryRecord(updated, root: self.restorePointsDirectory.appendingPathComponent(point.id.uuidString.lowercased()))
                    }
                }
                return records.map(\.0)
            }
        }
    }

    /// Undo the last imported values only while their durable after-images match.
    /// Moving the point into the active journal makes interrupted undo recoverable.
    public func undoRestorePoint(id: UUID) async throws {
        try await BackupContentCancellation.run {
            try await ResourceMaintenance.withExclusive(maintenanceKeys) {
                try await self.recoverUnderLease()
                guard let (_, saved) = try self.restorePointRecords().first(where: { $0.0.id == id }) else {
                    throw BackupError.preflightFailed("Restore point is no longer available")
                }
                try await self.checkRollback(record: saved, recoveryRoot: self.restorePointsDirectory.appendingPathComponent(id.uuidString.lowercased()))
                let points = try AppDirectory(url: self.restorePointsDirectory, create: false)
                let target = try AppDirectory(url: self.recoveryDirectoryURL.deletingLastPathComponent(), create: false)
                guard !target.exists(self.recoveryDirectoryURL.lastPathComponent),
                      renameatx_np(points.fd, id.uuidString.lowercased(), target.fd, self.recoveryDirectoryURL.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                    throw MaintenanceError.busy
                }
                var active = saved; active.committed = false
                try self.persistRecoveryRecord(active, root: self.recoveryDirectoryURL)
                switch await self.rollbackSafely(record: active, recoveryRoot: self.recoveryDirectoryURL) {
                case .complete:
                    Self.removeQuietly(self.recoveryDirectoryURL)
                    NotificationCenter.default.post(name: .agroomSpaceRestored, object: self.spaceName)
                case .incomplete:
                    throw BackupError.restoreIncomplete("Restore point undo needs recovery", recoveryPath: self.recoveryDirectoryURL.path)
                }
            }
        }
    }

    private func checkRollback(record: RestoreRecoveryRecord, recoveryRoot: URL) async throws {
        for entry in record.sessions {
            guard let id = UUID(uuidString: entry.id), let current = try await sessionService.fetch(id: id),
                  try recoveryDigest(current) == entry.afterDigest else { throw MaintenanceError.busy }
        }
        for entry in record.memories {
            guard let id = UUID(uuidString: entry.id), let current = try await memoryService.fetch(id: id),
                  try recoveryDigest(current) == entry.afterDigest else { throw MaintenanceError.busy }
        }
        if let database = record.database { try await recoveryDatabase(at: recoveryRoot).verify(database) }
        if let assets = record.assets, let spaceAssets { try await spaceAssets.verify(assets) }
        if let workspaces = record.assets?.workspaces, let workspacesProvider {
            let current = await workspacesProvider()
            guard workspaces.allSatisfy(current.contains) else { throw MaintenanceError.busy }
        }
        for skill in record.skills {
            guard let expected = skill.afterDigest, Self.directoryDigest(try skillStore.folderURL(for: skill.name)) == expected else { throw MaintenanceError.busy }
        }
        for (path, expected) in record.attachmentReceipts ?? [:] {
            let url = URL(fileURLWithPath: path)
            let current = try BackupFileIO.receipt(url.lastPathComponent, in: AppDirectory(url: url.deletingLastPathComponent(), create: false), limit: Self.maxExtractedByteCount)
            guard current.sha256 == expected.sha256 else { throw MaintenanceError.busy }
        }
    }

    /// 备份包 skills/ 段中可导入的技能文件夹（含 SKILL.md），按名称排序保证确定性
    private func skillImportEntries(in skillsRoot: URL) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory
                && fileManager.fileExists(atPath: entry.appendingPathComponent("SKILL.md").path)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 导入技能前先建立恢复点：覆盖时整目录拷贝旧技能，新增时记 nil；并落盘记录。
    /// 返回是否覆盖了已有同名技能
    private func importSkillWithRecoveryPoint(
        entry: URL,
        record: inout RestoreRecoveryRecord,
        recoveryRoot: URL
    ) throws -> Bool {
        guard let targetName = targetSkillName(for: entry) else {
            throw BackupError.corruptSection(entry.lastPathComponent, "missing or invalid SKILL.md")
        }
        let target = try skillStore.folderURL(for: targetName)
        let exists = fileManager.fileExists(atPath: target.path)
        if exists {
            let backupRelative = "skills/\(targetName)"
            let backupURL = recoveryRoot.appendingPathComponent(backupRelative, isDirectory: true)
            try? fileManager.removeItem(at: backupURL)
            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: target, to: backupURL)
            record.skills.append(.init(name: targetName, backupFolder: backupRelative, beforeDigest: Self.directoryDigest(target), afterDigest: Self.directoryDigest(entry)))
        } else {
            record.skills.append(.init(name: targetName, backupFolder: nil, afterDigest: Self.directoryDigest(entry)))
        }
        try persistRecoveryRecord(record, root: recoveryRoot)
        try replaceSkillFolder(name: targetName, source: entry)
        return exists
    }

    /// 由源文件夹的 SKILL.md 推导导入后的技能文件夹名（与 SkillStore.importFolder 同一规则）
    private func targetSkillName(for sourceURL: URL) -> String? {
        let skillMD = sourceURL.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillMD, encoding: .utf8),
              let skill = try? SkillDocument.parse(text) else { return nil }
        let name = skill.isNameValid ? skill.name : Skill.slugify(skill.name)
        return name.isEmpty ? nil : name
    }

    /// 从恢复点原子还原技能文件夹：先在同目录暂存副本，再整体替换，
    /// 避免「删旧后拷贝失败」丢新旧两版
    private func restoreSkillFolder(name: String, backupRelative: String, recoveryRoot: URL) throws {
        let backup = recoveryRoot.appendingPathComponent(backupRelative, isDirectory: true)
        try replaceSkillFolder(name: name, source: backup)
    }

    private func replaceSkillFolder(name: String, source: URL) throws {
        let target = try skillStore.folderURL(for: name)
        let root = try AppDirectory(url: target.deletingLastPathComponent(), create: true)
        let temporary = ".restore-skill-" + UUID().uuidString
        let staged = target.deletingLastPathComponent().appendingPathComponent(temporary)
        try fileManager.copyItem(at: source, to: staged)
        defer { if fileManager.fileExists(atPath: staged.path) { Self.removeQuietly(staged) } }
        let flags = root.exists(name) ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renameatx_np(root.fd, temporary, root.fd, name, flags) == 0, fsync(root.fd) == 0 else { throw NativeAppError(.storage) }
        skillStore.invalidateSnapshot()
    }

    // MARK: - Helpers

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func write(_ data: Data, to directory: URL, file: String) throws {
        guard data.count <= maximumJSONSectionBytes else { throw NativeAppError(.tooLarge) }
        try data.write(to: directory.appendingPathComponent(file), options: .atomic)
    }

    /// 文件段的清单项。
    private static func section(path: String, data: Data, count: Int) -> BackupManifest.Section {
        BackupManifest.Section(path: path, count: count, byteCount: data.count, sha256: digest(data))
    }

    /// 目录段的清单项：逐文件（相对路径升序）的摘要再摘要，任何文件变化都会改变结果。
    private static func directorySection(path: String, root: URL, count: Int) -> BackupManifest.Section {
        BackupManifest.Section(
            path: path,
            count: count,
            byteCount: directoryByteCount(root),
            sha256: directoryDigest(root)
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 目录整体摘要：逐个文件「相对路径 + 大小 + 内容摘要」拼接后再摘要。
    private static func directoryDigest(_ root: URL) -> String {
        var accumulator = SHA256()
        let directory = try? AppDirectory(url: root, create: false)
        for (relative, url) in sortedFiles(root) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let contentDigest: String
            if let directory,
               let receipt = try? BackupFileIO.receipt(String(relative.drop(while: { $0 == "/" })), in: directory, limit: maxExtractedByteCount) {
                contentDigest = receipt.sha256
            } else {
                contentDigest = "unreadable"
            }
            accumulator.update(data: Data("\(relative)|\(size)|\(contentDigest)\n".utf8))
        }
        return accumulator.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func directoryByteCount(_ root: URL) -> Int {
        sortedFiles(root).reduce(0) { total, item in
            let attributes = try? FileManager.default.attributesOfItem(atPath: item.1.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            return total + size
        }
    }

    private static func sortedFiles(_ root: URL) -> [(String, URL)] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var files: [(String, URL)] = []
        let prefix = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            let path = url.standardizedFileURL.path
            files.append((String(path.dropFirst(prefix.count)), url))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 临时目录清理（失败仅记日志，不影响主流程）
    private static func removeQuietly(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            HubLogger.shared.error("Staging cleanup failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    /// 系统 ditto（与技能导入同通道），后台队列执行不阻塞调用线程；
    /// 非零退出码抛错
    private static func runDitto(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        // 取消传播：任务取消时主动终止 ditto 进程树（大目录压缩可能耗时较久）
        let gate = CancellationGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                        // 取消可能先于 run 抵达（此时 terminate 无进程可杀），启动后补判断
                        if gate.isCancelled {
                            ProcessTerminator.terminate(process: process, label: "backup-ditto")
                        }
                        process.waitUntilExit()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    if gate.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: BackupError.dittoFailed(status: process.terminationStatus))
                    }
                }
            }
        } onCancel: {
            gate.markCancelled()
            ProcessTerminator.terminate(process: process, label: "backup-ditto")
        }
    }

    private static var appVersion: String {
        let bundle = Bundle.main.infoDictionary
        let short = bundle?["CFBundleShortVersionString"] as? String ?? "0"
        return short
    }
}

// MARK: - Auto Backup Policy

/// 自动备份策略（F14）：启动时到期检查 → 逐空间出包 → 轮换旧包。
/// 纯策略与文件操作在此（Core），触发与本地化文案在 UI 层（RootView），
/// 因为 JobCenter 作业名需要 L.string（UI 模块）。
public enum AutoBackupPolicy {
    /// 开关（UserDefaults；缺席时视为开启——数据保全特性不应默认关闭）
    public static let enabledKey = "agroom.autoBackup.enabled"
    /// 上次成功时间戳键前缀（**按空间**记录：某空间失败不拖累另一个空间重试）
    public static let lastRunPrefix = "agroom.autoBackup.lastRun."
    /// 触发间隔：每日一次（启动时检查，长期不开 App 则下次启动补跑）
    public static let interval: TimeInterval = 24 * 60 * 60
    /// 每空间保留份数
    public static let keepCount = 7

    /// 某空间的上次成功时间键。
    public static func lastRunKey(space: AppSpace) -> String {
        lastRunPrefix + space.rawValue
    }

    /// 到期判断（纯函数，可测）：从未跑过 → 到期
    public static func isDue(
        lastRun: Date?,
        now: Date = Date(),
        interval: TimeInterval = AutoBackupPolicy.interval
    ) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }

    /// 轮换（纯函数，可测）：按修改时间新→旧，返回超出保留份数应删除的文件
    public static func filesToPrune(
        _ urls: [URL],
        keep: Int = AutoBackupPolicy.keepCount
    ) -> [URL] {
        let fileManager = FileManager.default
        let archives = urls
            .filter { $0.pathExtension.lowercased() == "zip" }
            .map { url -> (url: URL, modified: Date) in
                let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
                return (url, modified)
            }
            .sorted { $0.modified > $1.modified }
        guard archives.count > keep else { return [] }
        return archives.dropFirst(keep).map(\.url)
    }

    /// 自动备份目标目录：~/Documents/AgRoomBackups/
    public static func destinationDirectory() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return documents.appendingPathComponent("AgRoomBackups", isDirectory: true)
    }

    /// 删除超出保留份数的旧备份
    public static func prune(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
