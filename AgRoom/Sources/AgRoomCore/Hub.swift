import Foundation

// MARK: - Hub (Composition Root)

/// 组合根：持有空间管理与全局服务。
/// 空间隔离红线：空间内服务（SessionService 等）由 UI 层依据当前空间
/// 从 spaceStore.currentQueue 现取现建，Hub 不缓存空间内服务。
@MainActor
public final class Hub {
    /// 空间管理（当前空间 + 双库挂载）
    public let spaceStore: SpaceStore

    /// LLM 提供者配置服务（全局库，跨空间共享）。非 let：
    /// 全局库故障解除重试后需按新连接重建，否则「重试」后 Provider 仍不可用。
    public private(set) var providerService: ProviderConfigService?
    private let artifactPreviewsRoot: URL?
    private let skillDirectoryRoot: URL?
    private let captureDirectoryRoot: URL?

    /// 重试数据库挂载（UI「重试」入口）：先按故障归属重建库连接，
    /// 再在全局库此前不可用（现已恢复）时重建依赖它的 Provider 服务。
    public func retryDatabases() async {
        await spaceStore.retryCurrentDatabase()
        bindGlobalProviderIfNeeded()
    }

    public func prepare(_ space: AppSpace) async {
        await spaceStore.prepare(space)
        bindGlobalProviderIfNeeded()
    }

    private func bindGlobalProviderIfNeeded() {
        if providerService == nil, let queue = spaceStore.globalQueue {
            providerService = ProviderConfigService(databaseQueue: queue)
            NotificationCenter.default.post(name: ProviderConfigService.configurationDidChange, object: nil)
        }
    }

    public init() {
        // 身份迁移必须早于任何路径读取（数据库/技能目录都在应用支持目录下）
        self.spaceStore = SpaceStore()
        self.artifactPreviewsRoot = nil
        self.skillDirectoryRoot = nil
        self.captureDirectoryRoot = nil
        HubLogger.shared.info("Hub initialized")
    }

    /// Explicit composition for isolated hosts; does not mount production files or run migration side effects.
    init(spaceStore: SpaceStore, providerService: ProviderConfigService? = nil, artifactPreviewsRoot: URL? = nil, skillDirectoryRoot: URL? = nil, captureDirectoryRoot: URL? = nil) {
        self.spaceStore = spaceStore
        self.providerService = providerService
        self.artifactPreviewsRoot = artifactPreviewsRoot
        self.skillDirectoryRoot = skillDirectoryRoot
        self.captureDirectoryRoot = captureDirectoryRoot
    }

    /// MCP settings and credentials are bound to the requested space; never cached in Hub.
    public func makeProductPreferencesService(for space: AppSpace) -> ProductPreferencesService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return ProductPreferencesService(databaseQueue: queue)
    }

    public func noteCaptureRoot(for space: AppSpace) -> URL? {
        if let captureDirectoryRoot { return captureDirectoryRoot.appendingPathComponent(space.rawValue) }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("AgRoom").appendingPathComponent(space.rawValue).appendingPathComponent("note-capture")
    }

    public func makeNoteStore(for space: AppSpace) -> NoteStore? {
        spaceStore.makeNoteStore(for: space)
    }

    public func makeMySQLConnectorService(for space: AppSpace) -> MySQLConnectorService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return MySQLConnectorService(databaseQueue: queue, space: space)
    }

    public func makeMCPServerConfigService(for space: AppSpace) -> MCPServerConfigService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return MCPServerConfigService(databaseQueue: queue, space: space)
    }

    public func makeTaskFileRecoveryStore(for space: AppSpace) -> TaskFileRecoveryStore? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return TaskFileRecoveryStore(space: space, databaseQueue: queue)
    }

    public func makeUsageService(for space: AppSpace) -> UsageService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return UsageService(databaseQueue: queue)
    }

    public func makeUsageRecorder(for space: AppSpace, source: String, sessionID: UUID? = nil) -> ProviderUsageRecorder? {
        guard let service = makeUsageService(for: space) else { return nil }
        return ProviderUsageRecorder(service: service, source: source, sessionID: sessionID)
    }

    public func makeActiveProvider(for space: AppSpace, source: String, sessionID: UUID? = nil, dataPolicy: TaskDataPolicy = .configuredServices) async throws -> CloudProvider? {
        let recorder = makeUsageRecorder(for: space, source: source, sessionID: sessionID)
        var policy = dataPolicy
        if let sessionID {
            guard let service = makeSessionService(for: space) else { throw SpaceServiceError.encodingFailed }
            if let stored = try await service.dataPolicy(id: sessionID) { policy = policy.restricted(by: stored.constraints) }
        }
        return try await providerService?.activeProvider(usageRecorder: recorder)?.restricted(to: policy)
    }

    public func makeConfiguredProvider(for space: AppSpace, configurationID: UUID?, source: String) async throws -> CloudProvider? {
        guard spaceStore.queue(for: space) != nil else { throw SpaceServiceError.encodingFailed }
        guard let configurationID else { return try await makeActiveProvider(for: space, source: source) }
        return try await providerService?.provider(id: configurationID, usageRecorder: makeUsageRecorder(for: space, source: source))
    }

    /// 当前空间的会话服务（空间切换后需重建）
    public func makeSessionService() -> SessionService? {
        makeSessionService(for: spaceStore.current)
    }

    /// 指定空间的会话服务：跨 `await` 的后台任务必须固定到发起时的空间，
    /// 不能用「切换后的 current」重建（那会把 A 空间的结果写进 B 空间）
    public func makeSessionService(for space: AppSpace) -> SessionService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return SessionService(databaseQueue: queue)
    }

    public func makeTaskRunStore(for space: AppSpace) -> ProductTaskRunStore? {
        spaceStore.queue(for: space).map { ProductTaskRunStore(databaseQueue: $0) }
    }

    public func makeGoalStore(for space: AppSpace) -> GoalStore? {
        spaceStore.queue(for: space).map { GoalStore(databaseQueue: $0, space: space) }
    }

    public func makeTaskCenterStore(for space: AppSpace) -> ProductTaskCenterStore? {
        spaceStore.queue(for: space).map { ProductTaskCenterStore(databaseQueue: $0, space: space) }
    }

    public func makeSpaceSearchService(for space: AppSpace) -> SpaceSearchService? {
        guard let queue = spaceStore.queue(for: space),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let root = support.appendingPathComponent("AgRoom", isDirectory: true).appendingPathComponent(space.rawValue, isDirectory: true)
        return SpaceSearchService(databaseQueue: queue, space: space, catalogDirectory: root)
    }

    public func makeJobRunStore(for space: AppSpace) -> ProductJobRunStore? {
        spaceStore.queue(for: space).map { ProductJobRunStore(databaseQueue: $0, space: space) }
    }

    public func makeWorkspaceProjectStore(for space: AppSpace) -> WorkspaceProjectStore? {
        spaceStore.queue(for: space).map { WorkspaceProjectStore(databaseQueue: $0, space: space) }
    }

    public func makeArtifactStore(for space: AppSpace) -> TaskArtifactStore? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        let root: URL
        if let artifactPreviewsRoot { root = artifactPreviewsRoot }
        else {
            guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
            root = support.appendingPathComponent("AgRoom")
        }
        return TaskArtifactStore(databaseQueue: queue, space: space,
            previewRoot: root.appendingPathComponent(space.rawValue).appendingPathComponent("artifact-previews"))
    }

    public func makeBackupService(for space: AppSpace) -> BackupService? {
        guard let queue = spaceStore.queue(for: space), let skills = makeSkillStore(for: space) else { return nil }
        return BackupService.standard(sessionService: SessionService(databaseQueue: queue),
            memoryService: MemoryService(databaseQueue: queue), skillStore: skills, space: space)
    }

    public func makeTeamDiscussionStore(for space: AppSpace) -> TeamDiscussionStore? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return TeamDiscussionStore(databaseQueue: queue)
    }

    /// 当前空间的多智体任务存储（任务板用）
    public func makeTeamTaskStore() -> TeamTaskStore? {
        makeTeamTaskStore(for: spaceStore.current)
    }

    /// 指定空间的团队任务存储：绑定该空间的 `DatabaseQueue`，不缓存。
    public func makeTeamTaskStore(for space: AppSpace) -> TeamTaskStore? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return TeamTaskStore(databaseQueue: queue)
    }

    /// 当前空间的团队写快照存储（回滚/变更审阅用）
    public func makeTeamWriteStore() -> TeamWriteStore? {
        makeTeamWriteStore(for: spaceStore.current)
    }

    public func makeTeamWriteStore(for space: AppSpace) -> TeamWriteStore? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return TeamWriteStore(databaseQueue: queue)
    }

    /// 当前空间的定时任务定义存储（「定时」页用）
    public func makeScheduledTaskStore() -> ScheduledTaskStore? {
        makeScheduledTaskStore(for: spaceStore.current)
    }

    /// 指定空间的定时任务定义存储：绑定该空间连接，不缓存。
    public func makeScheduledTaskStore(for space: AppSpace) -> ScheduledTaskStore? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return ScheduledTaskStore(databaseQueue: queue)
    }

    /// 当前空间的定时运行记录存储
    public func makeScheduledRunStore() -> ScheduledRunStore? {
        makeScheduledRunStore(for: spaceStore.current)
    }

    public func makeScheduledRunStore(for space: AppSpace) -> ScheduledRunStore? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return ScheduledRunStore(databaseQueue: queue)
    }

    /// 当前空间的智体服务
    public func makeAgentService() -> AgentService? {
        makeAgentService(for: spaceStore.current)
    }

    /// 指定空间的智体服务
    public func makeAgentService(for space: AppSpace) -> AgentService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return AgentService(databaseQueue: queue)
    }

    /// 当前空间的技能库（Anthropic 标准文件夹制，空间物理隔离）
    public func makeSkillStore() -> SkillStore? {
        makeSkillStore(for: spaceStore.current)
    }

    /// 指定空间的技能库：后台任务（审核记录、别名缓存刷新）须固定到发起时的空间
    public func makeSkillStore(for space: AppSpace) -> SkillStore? {
        if let skillDirectoryRoot {
            return SkillStore(directoryURL: skillDirectoryRoot.appendingPathComponent(space.rawValue).appendingPathComponent("skills"))
        }
        guard let supportDir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = supportDir
            .appendingPathComponent("AgRoom", isDirectory: true)
            .appendingPathComponent(space.rawValue, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        return SkillStore(directoryURL: dir)
    }

    /// 当前空间的旧版技能数据库服务（仅供向技能库迁移使用）
    public func makeSkillService() -> SkillService? {
        makeSkillService(for: spaceStore.current)
    }

    /// 指定空间的旧版技能数据库服务
    public func makeSkillService(for space: AppSpace) -> SkillService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return SkillService(databaseQueue: queue)
    }

    /// 当前空间的记忆服务
    public func makeMemoryService() -> MemoryService? {
        makeMemoryService(for: spaceStore.current)
    }

    /// 指定空间的记忆服务：自动提炼等后台后处理须固定到发起时的空间
    public func makeMemoryService(for space: AppSpace) -> MemoryService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return MemoryService(databaseQueue: queue)
    }

    /// 当前空间的知识库服务
    public func makeKnowledgeService() -> KnowledgeService? {
        makeKnowledgeService(for: spaceStore.current)
    }

    /// 指定空间的知识库服务
    public func makeKnowledgeService(for space: AppSpace) -> KnowledgeService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return KnowledgeService(databaseQueue: queue)
    }

    /// Native app definitions and state live in a physically separate space directory.
    public func makeNativeAppStore(for space: AppSpace) -> NativeAppStore? {
        guard spaceStore.queue(for: space) != nil,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return NativeAppStore(directoryURL: support.appendingPathComponent("AgRoom", isDirectory: true)
            .appendingPathComponent(space.rawValue, isDirectory: true).appendingPathComponent("apps", isDirectory: true), space: space)
    }

    public func makeNativeAppResources(for space: AppSpace) -> NativeAppResources? {
        guard let service = makeKnowledgeService(for: space) else { return nil }
        return NativeAppResources(space: space, knowledge: service)
    }

    public func makeNativeAppDraftStore(for space: AppSpace) -> NativeAppDraftStore? {
        guard let apps = makeNativeAppStore(for: space) else { return nil }
        return NativeAppDraftStore(directoryURL: apps.directoryURL.deletingLastPathComponent()
            .appendingPathComponent("app-drafts", isDirectory: true), space: space)
    }

    /// 当前空间的邮箱账号服务（密码存 Keychain，键带空间前缀）
    public func makeMailAccountService() -> MailAccountService? {
        makeMailAccountService(for: spaceStore.current)
    }

    /// 指定空间的邮箱账号服务：跨 `await` 的操作需固定到发起时的空间，
    /// 不能用「切换后的 current」重建（那会让迟到回调读写另一个空间的数据）。
    public func makeMailAccountService(for space: AppSpace) -> MailAccountService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return MailAccountService(databaseQueue: queue, space: space)
    }

    /// 当前空间的邮件本地持久化服务（纯读写，不做网络）
    public func makeMailService() -> MailService? {
        makeMailService(for: spaceStore.current)
    }

    /// 指定空间的邮件本地持久化服务
    public func makeMailService(for space: AppSpace) -> MailService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return MailService(databaseQueue: queue)
    }

    /// 当前空间的邮件同步服务（协议网络 + 本地持久化编排）
    public func makeMailSyncService() -> MailSyncService? {
        makeMailSyncService(for: spaceStore.current)
    }

    /// 指定空间的邮件同步服务
    public func makeMailSyncService(for space: AppSpace) -> MailSyncService? {
        guard let queue = spaceStore.queue(for: space) else { return nil }
        return MailSyncService(
            accountService: MailAccountService(databaseQueue: queue, space: space),
            mail: MailService(databaseQueue: queue),
            space: space,
            // 进程级共享协调器：UI 与引擎各自现建的同步服务共用同一把账号租约
            // （键含空间，不违反空间隔离；也不缓存任何空间内服务）。
            coordinator: .shared
        )
    }
}
