import SwiftUI
import AgRoomCore
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - App Appearance

/// 外观偏好：跟随系统/浅色/深色（UserDefaults 持久化，App 启动与切换时应用）
public enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    /// 应用到 AppKit 全局外观（nil = 跟随系统）；NSApp 为 MainActor 隔离
    @MainActor public static func apply(_ appearance: AppAppearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Int 钳制扩展

extension Int {
    /// 钳制到闭区间内（越界取最近端点）
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Settings View

/// 设置分类：固定名称与顺序，不随助手昵称变化。
public enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case providers
    case assistant
    case notes
    case knowledge
    case tools
    case security
    case data

    var titleKey: String {
        switch self {
        case .general: "settings.tab.general"
        case .providers: "settings.tab.providers"
        case .notes: "notes.settings.title"
        case .assistant: "settings.category.assistant"
        case .knowledge: "settings.category.knowledge"
        case .tools: "settings.category.tools"
        case .security: "settings.category.security"
        case .data: "settings.category.data"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .providers: "server.rack"
        case .notes: "waveform.and.mic"
        case .assistant: "bubble.left.and.bubble.right"
        case .knowledge: "books.vertical"
        case .tools: "wrench.and.screwdriver"
        case .security: "lock.shield"
        case .data: "externaldrive"
        }
    }
}

/// 设置页使用分类列表与单一内容表单，避免 TabView + grouped Form 的 AppKit 布局环。
public struct SettingsView: View {
    let hub: Hub
    private let space: AppSpace
    private let productPreferences: ProductPreferencesService?

    @State private var notesModel: NotesModel
    @State private var notePanel: String?
    @State private var languageManager = LanguageManager.shared
    @State private var selectedTab: SettingsTab = .general
    @State private var showingPythonEnvironment = false
    @State private var mcpSettingsSpace: AppSpace?
    @Environment(\.scenePhase) private var scenePhase
    /// 调度 Agent 回复语言（默认 system：跟随系统语言；@AppStorage 持久化）
    @AppStorage("agroom.agentReplyLanguage") private var agentReplyLanguage: AppLanguage = .system
    /// 调度 Agent 昵称（与 DispatcherSettings.nicknameKey 共用 UserDefaults 键）
    @AppStorage(DispatcherSettings.nicknameKey) private var dispatcherNickname = ""
    /// Application capability switches; model generation parameters live in the global database.
    @AppStorage(DispatcherSettings.teamTasksEnabledKey) private var teamTasksEnabled = false
    @AppStorage(DispatcherSettings.teamWritesEnabledKey) private var teamWritesEnabled = false
    @AppStorage(DispatcherSettings.scheduledTasksEnabledKey) private var scheduledTasksEnabled = false
    /// 调度 Agent 人设（预设 + 自定义描述）
    @AppStorage(DispatcherSettings.personaKey) private var dispatcherPersona: DispatcherPersona = .standard
    @AppStorage(DispatcherSettings.personaCustomTextKey) private var personaCustomText: String = ""
    /// 自定义人设 AI 展开进行中
    @State private var isExpandingPersona = false
    /// 快捷提示 AI 推荐进行中
    @State private var isGeneratingPrompts = false
    /// 全局日期格式（默认 system：跟随系统格式）
    @AppStorage(AppDateFormat.storageKey) private var dateFormat: AppDateFormat = .system
    @AppStorage(AppDateFormat.customPatternKey) private var dateFormatCustom: String = "yyyy-MM-dd HH:mm"
    /// 当前空间能力摘要，完整启用管理在技能/智体页
    @State private var skills: [Skill] = []
    /// 当前空间的智体摘要
    @State private var agents: [Agent] = []
    @State private var providers: [LLMProviderConfig] = []
    @State private var movingProviderID: UUID?
    @State private var providerLoadID = UUID()
    @State private var editingProvider: LLMProviderConfig?
    @State private var showingNewProvider = false
    @State private var providerPendingDeletion: LLMProviderConfig?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    /// 常用问句固定到本页发起空间，模型回调不能随空间切换改写归属。
    @State private var quickPrompts: [String] = []
    @State private var quickPromptSaveTask: Task<Void, Never>?
    @State private var hasLegacyQuickPrompts = false
    @State private var showingLegacyPromptMigration = false
    /// 脚本与权限完整页面（仅当前空间）
    @State private var showingScriptPermissions = false
    @State private var showingGlobalLegacyRecovery = false
    /// 备份/恢复状态（操作反馈显示在 Section 内）
    @State private var backupStatus: String?
    @State private var isBackingUp = false
    @State private var includeExternalBackupFiles = false
    /// 本次提交的备份作业 id（作业流回调里匹配它刷新状态行）
    @State private var currentBackupJobId: UUID?
    /// 待恢复的备份文件（选中后弹确认，确认才执行）
    /// 已通过预检、等待用户确认的恢复请求
    @State private var restorePlan: RestorePrompt?

    /// 恢复确认请求：备份包 + 预检结论。
    private struct RestorePrompt: Identifiable {
        let id = UUID()
        let url: URL
        let plan: RestorePlan
    }

    /// 外观偏好（切换即时生效；App 启动时在 AppDelegate 应用）
    @AppStorage("agroom.appearance") private var appearance: AppAppearance = .system
    @State private var interfaceTypography = InterfaceTypographyPreferences.shared
    @AppStorage(MenuBarRobotSettings.animationEnabledKey) private var menuBarAnimationEnabled = true
    /// 登录自启动（SMAppService 注册状态）
    @State private var launchAtLogin = false
    /// 通知分类开关（Core 层 UserDefaults 持久化）
    @State private var agentNotificationsEnabled = true
    @State private var backgroundNotificationsEnabled = true
    @State private var scheduledNotificationsEnabled = true
    /// 显示隐藏对话（与对话页列表过滤共用键 chat.showHiddenSessions）
    @AppStorage("chat.showHiddenSessions") private var showHiddenSessions = false
    /// 输入区免责声明开关（与对话页共用键 chat.showDisclaimer；个人使用可关）
    @AppStorage("chat.showDisclaimer") private var showDisclaimer = true
    /// 自动备份开关（F14；缺席视为开启，与 AutoBackupPolicy 读取逻辑一致）
    @AppStorage(AutoBackupPolicy.enabledKey) private var autoBackupEnabled = true
    /// 新建会话默认权限模式（只影响之后创建的会话）
    @AppStorage(DispatcherSettings.defaultPermissionModeKey) private var defaultPermissionModeRaw = PermissionMode.workspaceWrite.rawValue
    /// 桥层权限状态（展示用；去系统设置授权后切回页签刷新）
    @State private var remindersAuthorized = false
    @State private var notificationsAuthorized = false

    /// Only an explicitly confirmed migration may read the ambiguous legacy list.
    static let quickPromptsLimit = ProductPreferencesService.quickPromptsLimit

    public init(hub: Hub, initialTab: SettingsTab? = nil) {
        self.hub = hub
        self._notesModel = State(initialValue: NotesModel(hub: hub, space: hub.spaceStore.current))
        self.space = hub.spaceStore.current
        self.productPreferences = hub.makeProductPreferencesService(for: hub.spaceStore.current)
        self._selectedTab = State(initialValue: initialTab ?? .general)
    }

    init(hub: Hub, notesModel: NotesModel, initialTab: SettingsTab? = nil) {
        self.init(hub: hub, initialTab: initialTab)
        self._notesModel = State(initialValue: notesModel)
    }

    public var body: some View {
        HStack(spacing: 0) {
            categoryList
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(L.string(selectedTab.titleKey))
                    .font(MeetTypography.pageTitle)
                    .padding(20)
                Divider()
                selectedContent
                    .id(selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: Binding(get: { notePanel != nil }, set: { if !$0 { notePanel = nil } })) {
            VStack(spacing: 0) {
                HStack {
                    Text(L.string(notePanel == "privacy" ? "notes.privacy" : notePanel == "mcp" ? "notes.mcp" : "notes.portability")).font(.headline)
                    Spacer()
                    Button(L.string("common.close")) { notePanel = nil }
                }.padding(16)
                if notePanel == "privacy" { NotesLocalModelsView(model: notesModel, page: .privacy, embedded: true) }
                else { NotesToolsView(model: notesModel, page: notePanel == "mcp" ? .mcp : .data, embedded: true) }
            }.frame(width: 680, height: 680)
        }
        .onChange(of: hub.spaceStore.current) { _, _ in notePanel = nil }
        .task { await load() }
        .task { await observeBackupJobs() }
        .confirmationDialog(L.string("product.prompts.legacy.title"), isPresented: $showingLegacyPromptMigration, titleVisibility: .visible) {
            Button(L.string("product.prompts.legacy.import")) { migrateLegacyPrompts() }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.format("product.prompts.legacy.help", L.string(space.nameKey)))
        }
        .task(id: selectedTab) {
            if selectedTab == .security { await loadSystemState() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadSystemState() } }
        }
        .sheet(isPresented: $showingPythonEnvironment) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.string("settings.tab.python")).font(.headline)
                        Text(currentSpaceCaption).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L.string("common.close")) { showingPythonEnvironment = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
                Divider()
                PythonEnvironmentTab(hub: hub)
                    .id(hub.spaceStore.current)
            }
            .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
        }
        .sheet(item: $mcpSettingsSpace) { space in
            MCPSettingsView(service: hub.makeMCPServerConfigService(for: space), space: space)
        }
        .onChange(of: hub.spaceStore.current) { _, _ in mcpSettingsSpace = nil }
        .sheet(isPresented: $showingNewProvider) {
            ProviderFormSheet(hub: hub, provider: nil) {
                showingNewProvider = false
                Task { await load() }
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderFormSheet(hub: hub, provider: provider) {
                editingProvider = nil
                Task { await load() }
            }
        }
        .sheet(isPresented: $showingScriptPermissions) {
            ScriptPermissionsView(hub: hub, space: hub.spaceStore.current)
        }
        .sheet(isPresented: $showingGlobalLegacyRecovery) {
            GlobalLegacyRecoverySheet(store: .standard)
        }
        .onChange(of: hub.spaceStore.current) { _, _ in showingGlobalLegacyRecovery = false }
        .confirmationDialog(
            L.string("settings.provider.delete_confirm.title"),
            isPresented: Binding(
                get: { providerPendingDeletion != nil },
                set: { if !$0 { providerPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("common.delete"), role: .destructive) {
                if let provider = providerPendingDeletion {
                    delete(provider)
                }
                providerPendingDeletion = nil
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.string("settings.provider.delete_confirm.message"))
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var currentSpaceCaption: String {
        L.format("settings.scope.space", L.string(hub.spaceStore.current.nameKey))
    }

    private var categoryList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(L.string(tab.titleKey), systemImage: tab.symbol)
                            .font(.body)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                            .background(
                                selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(L.string(tab.titleKey))
                    .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
                }
            }
            .padding(12)
        }
        .frame(width: languageManager.usesCompactLabels ? 180 : 250)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel(L.string("settings.categories"))
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .general: generalTab
        case .providers: providersTab
        case .notes: NotesSettingsView(model: notesModel)
        case .assistant: assistantTab
        case .knowledge: KnowledgeEmbeddingSettingsView(hub: hub)
        case .tools: toolsTab
        case .security: securityTab
        case .data: dataTab
        }
    }

    // MARK: - 通用与数据

    private var generalTab: some View {
        Form {
            GlobalHotkeySettingsSection()
            Section {
                Picker(L.string("settings.appearance"), selection: $appearance) {
                    Text(L.string("settings.appearance.system")).tag(AppAppearance.system)
                    Text(L.string("settings.appearance.light")).tag(AppAppearance.light)
                    Text(L.string("settings.appearance.dark")).tag(AppAppearance.dark)
                }
                .pickerStyle(.menu)
                .onChange(of: appearance) { _, newValue in
                    AppAppearance.apply(newValue)
                }

                Picker(L.string("settings.interface.size"), selection: $interfaceTypography.isLarge) {
                    Text(L.string("settings.interface.standard")).tag(false)
                    Text(L.string("settings.interface.large")).tag(true)
                }
                .pickerStyle(.menu)

                Toggle(L.string("settings.menuBar.animation"), isOn: $menuBarAnimationEnabled)
                    .help(L.string("settings.menuBar.animation.help"))
            } header: {
                Text(L.string("settings.appearance"))
            } footer: {
                Text(L.string("settings.interface.description"))
            }

            Section {
                ReadingTextSizeEditor()
            } header: {
                Text(L.string("settings.reading.size"))
            } footer: {
                Text(L.string("settings.reading.description"))
            }

            Section {
                Picker(L.string("settings.language"), selection: Binding(
                    get: { languageManager.currentLanguage },
                    set: { languageManager.currentLanguage = $0 }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang == .system ? L.string("settings.appearance.system") : lang.nativeDisplayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text(L.string("settings.language"))
            } footer: {
                Text(L.string("settings.scope.global"))
            }

            // 日期格式：全局统一（默认系统格式）
            Section {
                Picker(L.string("settings.dateformat.style"), selection: $dateFormat) {
                    Text(L.string("settings.dateformat.system")).tag(AppDateFormat.system)
                    Text("2026-08-28 21:30").tag(AppDateFormat.iso)
                    Text("2026/08/28 21:30").tag(AppDateFormat.slash)
                    Text("08/28/2026, 9:30 PM").tag(AppDateFormat.us)
                    Text("28.08.2026 21:30").tag(AppDateFormat.eu)
                    Text(L.string("settings.dateformat.custom")).tag(AppDateFormat.custom)
                }
                if dateFormat == .custom {
                    TextField(
                        L.string("settings.dateformat.custom.placeholder"),
                        text: $dateFormatCustom
                    )
                    .fontDesign(.monospaced)
                    .help(L.string("settings.dateformat.custom.help"))
                    LabeledContent(
                        L.string("settings.dateformat.preview"),
                        value: AppDate.string(from: Date())
                    )
                }
            } header: {
                Text(L.string("settings.dateformat"))
            } footer: {
                Text(L.string("settings.dateformat.desc"))
            }

            Section(L.string("settings.startup")) {
                Toggle(L.string("settings.launchAtLogin"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isOn in setLaunchAtLogin(isOn) }
            }

            Section {
                Toggle(L.format("settings.notifications.agent", L.dispatcherName()), isOn: $agentNotificationsEnabled)
                    .onChange(of: agentNotificationsEnabled) { _, isOn in
                        NotificationService.setEnabled(isOn, for: .agent)
                    }
                Toggle(L.string("settings.notifications.background"), isOn: $backgroundNotificationsEnabled)
                    .onChange(of: backgroundNotificationsEnabled) { _, isOn in
                        NotificationService.setEnabled(isOn, for: .background)
                    }
                Toggle(L.string("settings.notifications.scheduled"), isOn: $scheduledNotificationsEnabled)
                    .onChange(of: scheduledNotificationsEnabled) { _, isOn in
                        NotificationService.setEnabled(isOn, for: .scheduled)
                    }
            } header: {
                Text(L.string("settings.notifications.title"))
            } footer: {
                Text(L.format("settings.notifications.desc", L.dispatcherName()))
            }

            // 关于
            Section(L.string("settings.about")) {
                LabeledContent(L.string("settings.version"), value: appVersion)
            }
        }
        .formStyle(.grouped)
    }

    private var dataTab: some View {
        Form {
            Section(L.string("notes.settings.data")) {
                Button(L.string("notes.portability")) { notePanel = "data" }
                Text(L.string("notes.settings.data.hint")).font(.caption).foregroundStyle(.secondary)
            }
            ProductMetricsSection(service: productPreferences, isCurrent: { hub.spaceStore.current == space })
            Section {
                // 自动备份（F14）：每日启动时检查，所有空间出包到文稿并轮换
                Toggle(isOn: $autoBackupEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.string("settings.backup.auto"))
                        Text(L.string("settings.backup.auto.desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text(L.string("settings.backup.auto"))
            } footer: {
                Text(L.string("settings.scope.global"))
            }

            // Manual export and restore stay bound to the space that opened settings.
            Section {
                Toggle(L.string("product.backup.include_external"), isOn: $includeExternalBackupFiles)
                    .disabled(isBackingUp)
                Text(L.string("product.backup.include_external.help")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(L.string("settings.backup.export")) {
                        exportBackup()
                    }
                    .disabled(isBackingUp)

                    Button(L.string("settings.backup.restore")) {
                        chooseRestoreFile()
                    }
                    .disabled(isBackingUp)

                    if isBackingUp {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let backupStatus {
                    Text(backupStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(L.string("settings.backup.manual"))
            } footer: {
                Text(L.string("settings.backup.desc") + "\n" + currentSpaceCaption)
            }
            .sheet(item: $restorePlan) { prompt in
                ProductBackupRestorePreview(plan: prompt.plan, confirm: {
                    restoreBackup(from: prompt.url, allowCrossSpace: prompt.plan.spaceMismatch, fingerprint: prompt.plan.packageFingerprint)
                    restorePlan = nil
                }, cancel: { restorePlan = nil })
            }
            ProductRestorePointsSection(service: backupService, space: space)

            Section {
                Button(L.string("settings.legacy_evidence.open")) {
                    showingGlobalLegacyRecovery = true
                }
                Text(L.string("settings.legacy_evidence.entry_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L.string("settings.legacy_evidence.section"))
            } footer: {
                Text(L.string("settings.scope.global"))
            }

            // 隐私与数据
            Section(L.string("settings.privacy")) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L.string("settings.privacy.local"), systemImage: "internaldrive")
                    Label(L.string("settings.privacy.keychain"), systemImage: "key")
                    Label(L.string("settings.privacy.network"), systemImage: "network")
                    Label(L.string("settings.privacy.spaces"), systemImage: "square.on.square.dashed")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Backup & Restore

    /// 备份文件名时间戳（yyyyMMdd-HHmm）
    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    private var backupService: BackupService? { hub.makeBackupService(for: space) }

    /// 导出备份：NSSavePanel 选位置 → 提交 JobCenter 后台作业（打 zip + 进度 + 结果文案）
    private func exportBackup() {
        guard let service = backupService else {
            backupStatus = L.string("error.database")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "AgRoom-Backup-\(Self.backupStamp()).zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBackingUp = true
        backupStatus = L.string("settings.backup.working")
        let includeExternal = includeExternalBackupFiles
        currentBackupJobId = JobCenter.shared.submit(
            name: L.string("jobs.backup.export.name"),
            kind: "backup-export", space: space, origin: "settings", historyStore: hub.makeJobRunStore(for: space)
        ) { ctx in
            let summary: BackupSummary
            do { summary = try await service.export(to: url, includeExternalWorkspaces: includeExternal, progress: { ctx.reportProgress($0) }) }
            catch { throw ProductBackupUIError(message: await MainActor.run { L.errorDescription(error) }) }
            let text = await MainActor.run {
                L.format(
                    "settings.backup.done.export",
                    summary.sessions,
                    summary.memories,
                    summary.skills,
                    summary.attachments,
                    summary.workspaces
                ) + "\n" + ProductBackupPresentation.coverage(summary.coverage)
            }
            ctx.reportResult(text)
            ctx.reportResultURL(url)
        }
    }

    /// 选择备份文件 → 预检（不写数据）→ 确认对话框 → 恢复
    private func chooseRestoreFile() {
        guard let service = backupService else {
            backupStatus = L.string("error.database")
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 先预检再把结论摆给用户：包里有什么、会不会覆盖、能不能通过校验
        isBackingUp = true
        backupStatus = L.string("settings.backup.inspecting")
        currentBackupJobId = JobCenter.shared.submit(
            name: L.string("jobs.backup.inspect.name"),
            kind: "backup-inspect", space: space, origin: "settings", historyStore: hub.makeJobRunStore(for: space)
        ) { ctx in
            let plan: RestorePlan
            do { plan = try await service.inspect(from: url) }
            catch { throw ProductBackupUIError(message: await MainActor.run { L.errorDescription(error) }) }
            // 文案构造要回主 actor（L.format 是主 actor 隔离的）
            let text = await MainActor.run { () -> String in
                if !plan.corruptSections.isEmpty {
                    return L.format(
                        "settings.backup.inspect.corrupt",
                        plan.corruptSections.joined(separator: ", ")
                    )
                }
                return L.format(
                    "settings.backup.inspect.summary",
                    plan.manifest.sessionCount,
                    plan.manifest.memoryCount,
                    plan.manifest.skillCount,
                    plan.attachmentCount,
                    plan.workspaceCount
                )
            }
            ctx.reportResult(text)
            await MainActor.run {
                restorePlan = RestorePrompt(url: url, plan: plan)
            }
        }
    }

    private func restoreBackup(from url: URL, allowCrossSpace: Bool, fingerprint: String) {
        guard let service = backupService else { return }
        isBackingUp = true
        backupStatus = L.string("settings.backup.working")
        currentBackupJobId = JobCenter.shared.submit(
            name: L.string("jobs.backup.restore.name"),
            kind: "backup-restore", space: space, origin: "settings", historyStore: hub.makeJobRunStore(for: space)
        ) { ctx in
            let summary: RestoreSummary
            do {
                summary = try await service.restore(from: url, allowCrossSpace: allowCrossSpace,
                    expectedFingerprint: fingerprint, progress: { ctx.reportProgress($0) })
            } catch { throw ProductBackupUIError(message: await MainActor.run { L.errorDescription(error) }) }
            let text = await MainActor.run {
                L.format(
                    "settings.backup.done.restore",
                    summary.sessions,
                    summary.memories,
                    summary.skills,
                    summary.attachments,
                    summary.workspaces
                ) + "\n" + L.string("product.backup.verified") + "\n"
                    + ProductBackupPresentation.coverage(summary.coverage) + "\n"
                    + ProductBackupPresentation.warnings(summary.warnings)
            }
            ctx.reportResult(text)
        }
    }

    /// 订阅作业流：跟踪当前备份作业状态（完成/失败/取消刷新 Section 状态行）
    private func observeBackupJobs() async {
        for await snapshot in JobCenter.shared.stream() {
            guard let id = currentBackupJobId,
                  let job = snapshot.first(where: { $0.id == id }) else { continue }
            if job.state == .awaitingSave {
                isBackingUp = false
                backupStatus = L.string("jobs.history.failed")
            } else if job.state.isFinished {
                isBackingUp = false
                switch job.state {
                case .succeeded:
                    backupStatus = job.resultText
                case .failed:
                    backupStatus = L.string("settings.backup.failed") + (job.errorText ?? "")
                case .cancelled:
                    backupStatus = nil
                default:
                    break
                }
                currentBackupJobId = nil
            } else {
                isBackingUp = true
            }
        }
    }

    // MARK: - System & Permissions

    /// 登录自启动开关（SMAppService；失败回读实际状态避免 UI 与系统不同步）
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            HubLogger.shared.error("Launch-at-login toggle failed: \(HubLogger.safeErrorSummary(error))")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// 权限状态徽章：色点 + 本地化文案
    private func permissionBadge(granted: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(granted
                 ? L.string("settings.permissions.granted")
                 : L.string("settings.permissions.denied"))
                .foregroundStyle(.secondary)
        }
    }

    /// 加载系统状态（自启动 / 通知开关 / 桥层权限）
    private func loadSystemState() async {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        agentNotificationsEnabled = NotificationService.isEnabled(.agent)
        backgroundNotificationsEnabled = NotificationService.isEnabled(.background)
        scheduledNotificationsEnabled = NotificationService.isEnabled(.scheduled)
        remindersAuthorized = RemindersService().isAuthorized
        notificationsAuthorized = await NotificationService.isAuthorized
    }

    // MARK: - Tab: 常用问句

    /// 常用问句管理：行内编辑、删除、新增；上限 20 条（footer 显示计数）
    private var quickPromptsSection: some View {
        Section {
            ForEach(quickPrompts.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    TextField(
                        L.string("settings.quickprompts.placeholder"),
                        text: Binding(
                            get: { quickPrompts.indices.contains(index) ? quickPrompts[index] : "" },
                            set: { newValue in
                                guard quickPrompts.indices.contains(index) else { return }
                                quickPrompts[index] = newValue
                                saveQuickPrompts()
                            }
                        )
                    )
                    Button {
                        guard quickPrompts.indices.contains(index) else { return }
                        quickPrompts.remove(at: index)
                        saveQuickPrompts()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help(L.string("common.delete"))
                }
            }
            .onDelete { offsets in
                quickPrompts.remove(atOffsets: offsets)
                saveQuickPrompts()
            }

            // 新增：达到上限后禁用
            Button {
                guard quickPrompts.count < Self.quickPromptsLimit else { return }
                quickPrompts.append("")
                saveQuickPrompts()
            } label: {
                Label(L.string("settings.quickprompts.add"), systemImage: "plus.circle")
            }
            .disabled(quickPrompts.count >= Self.quickPromptsLimit)

            // AI 推荐：基于近期会话高频意图生成快捷提示（去重后追加）
            Button {
                generateQuickPrompts()
            } label: {
                if isGeneratingPrompts {
                    ProgressView().controlSize(.small)
                } else {
                    Label(L.string("settings.quickprompts.recommend"), systemImage: "sparkles")
                }
            }
            .disabled(isGeneratingPrompts || quickPrompts.count >= Self.quickPromptsLimit)
            if hasLegacyQuickPrompts {
                Button(L.string("product.prompts.legacy.import")) { showingLegacyPromptMigration = true }
            }
        } header: {
            Text(L.string("settings.quickprompts.title"))
        } footer: {
            Text(L.string("settings.quickprompts.desc") + "\n" + L.format("settings.scope.space", L.string(space.nameKey)) + "\n"
                + L.format("settings.quickprompts.count", "\(quickPrompts.count)", "\(Self.quickPromptsLimit)"))
        }
    }

    private var assistantTab: some View {
        Form {
            personaSection
            capabilitiesSection
            quickPromptsSection
            Section(L.string("settings.chat.display")) {
                Toggle(L.string("settings.chat.showHidden"), isOn: $showHiddenSessions)
                Toggle(L.string("settings.chat.showDisclaimer"), isOn: $showDisclaimer)
            }
        }
        .formStyle(.grouped)
    }

    private var personaSection: some View {
        // 调度 Agent 人设：预设风格或自定义描述，注入系统提示词 [Persona] 段
        Section {
            // 昵称（F：@AppStorage 与 DispatcherSettings.nickname 共用键，改后所有展示点即取即生效）
            TextField(L.string("settings.persona.nickname"), text: $dispatcherNickname)
            Text(L.string("settings.persona.nickname.help"))
                .font(.caption)
                .foregroundColor(.secondary)
            Picker(L.format("settings.agent_language", L.dispatcherName()), selection: $agentReplyLanguage) {
                Text(L.string("settings.agent_language.system")).tag(AppLanguage.system)
                ForEach(AppLanguage.allCases.filter { $0 != .system }, id: \.self) { lang in
                    Text(lang.nativeDisplayName).tag(lang)
                }
            }
            .pickerStyle(.menu)
            Picker(L.string("settings.persona.style"), selection: $dispatcherPersona) {
                Text(L.string("settings.persona.standard")).tag(DispatcherPersona.standard)
                Text(L.string("settings.persona.concise")).tag(DispatcherPersona.concise)
                Text(L.string("settings.persona.detailed")).tag(DispatcherPersona.detailed)
                Text(L.string("settings.persona.professional")).tag(DispatcherPersona.professional)
                Text(L.string("settings.persona.creative")).tag(DispatcherPersona.creative)
                Text(L.string("settings.persona.custom")).tag(DispatcherPersona.custom)
            }
            if dispatcherPersona == .custom {
                // AI 展开：把一句话期望展开为完整人设描述（覆盖原文本）
                HStack {
                    Button {
                        expandPersona()
                    } label: {
                        if isExpandingPersona {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L.string("settings.persona.expand"), systemImage: "wand.and.stars")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.link)
                    .disabled(isExpandingPersona || personaCustomText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $personaCustomText)
                        .font(.body)
                        // 固定高度：分组表单里 minHeight 的贪婪尺寸会引发布局环
                        .frame(height: 100)
                        .scrollContentBackground(.hidden)
                    if personaCustomText.isEmpty {
                        Text(L.string("settings.persona.custom.placeholder"))
                            .font(.body)
                            .foregroundColor(.secondary.opacity(0.6))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
        } header: {
            Text(L.format("settings.persona", L.dispatcherName()))
        } footer: {
            Text(L.string("settings.persona.desc") + "\n" + L.string("settings.scope.global"))
        }
    }

    private var capabilitiesSection: some View {
        Section {
            LabeledContent(L.string("settings.persona.skills")) {
                HStack {
                    Text(L.format("settings.capabilities.count", skills.filter(\.isEnabled).count, skills.count))
                        .foregroundStyle(.secondary)
                    Button(L.string("settings.capabilities.manageSkills")) {
                        ProductRoute.open(space: hub.spaceStore.current, page: HubNavItem.tools.rawValue)
                    }
                }
            }
            LabeledContent(L.string("settings.persona.agents")) {
                HStack {
                    Text(L.format("settings.capabilities.count", agents.filter(\.isEnabled).count, agents.count))
                        .foregroundStyle(.secondary)
                    Button(L.string("settings.capabilities.manageAgents")) {
                        ProductRoute.open(space: hub.spaceStore.current, page: HubNavItem.agents.rawValue)
                    }
                }
            }
        } header: {
            Text(L.string("settings.capabilities.title"))
        } footer: {
            Text(currentSpaceCaption + "\n" + L.string("settings.capabilities.desc"))
        }
    }

    // MARK: - 工具与自动化

    private var toolsTab: some View {
        Form {
            Section(L.string("notes.mcp")) {
                Button(L.string("notes.settings.mcp.manage")) { notePanel = "mcp" }
                Text(L.string("notes.mcp.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(L.string("mcp.manage")) { mcpSettingsSpace = hub.spaceStore.current }
                Text(L.string("mcp.description")).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(L.string("mcp.title"))
            } footer: {
                Text(currentSpaceCaption)
            }
            Section {
                Button(L.string("settings.python.manage")) { showingPythonEnvironment = true }
                Text(L.string("settings.python.manage.desc"))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(L.string("settings.tab.python"))
            } footer: {
                Text(L.string("settings.scope.global") + "\n" + currentSpaceCaption)
            }
            Section {
                Toggle(isOn: $teamTasksEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.string("settings.dispatcher.team"))
                        Text(L.string("settings.dispatcher.team.desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $teamWritesEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.string("settings.dispatcher.teamWrites"))
                        Text(L.string("settings.dispatcher.teamWrites.desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(!teamTasksEnabled)
            } header: {
                Text(L.string("settings.automation.team"))
            } footer: {
                Text(L.string("settings.scope.global"))
            }
            Section {
                Toggle(isOn: $scheduledTasksEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.string("settings.dispatcher.schedules"))
                        Text(L.string("settings.dispatcher.schedules.desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: scheduledTasksEnabled) { _, value in
                    ScheduledTaskCenter.shared.schedulingSettingChanged(to: value)
                }
            } header: {
                Text(L.string("settings.automation.scheduled"))
            } footer: {
                Text(L.string("settings.scope.global"))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 权限与安全

    private var securityTab: some View {
        Form {
            Section(L.string("notes.privacy")) {
                Button(L.string("notes.settings.privacy.manage")) { notePanel = "privacy" }
                Text(L.string("notes.privacy.hint")).font(.caption).foregroundStyle(.secondary)
            }
            // 新建会话默认权限模式：只影响之后创建的会话；已有会话保持自己的选择
            Section {
                LabeledContent(L.string("settings.permission.default")) {
                    PermissionControl(
                        configuration: PermissionConfiguration(
                            mode: PermissionMode(rawValue: defaultPermissionModeRaw) ?? .workspaceWrite,
                            autoReviewEnabled: false),
                        options: PermissionPreset.defaultOptions,
                        onSelectPreset: { preset in
                            guard PermissionPreset.defaultOptions.contains(preset),
                                  let configuration = preset.configuration else { return }
                            defaultPermissionModeRaw = configuration.mode.rawValue
                        }
                    )
                }
                Text(L.string("settings.permission.desc"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if (PermissionMode(rawValue: defaultPermissionModeRaw) ?? .workspaceWrite) == .dangerFullAccess {
                    Text(L.string("settings.permission.fullAccess.warning"))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } header: {
                Text(L.string("settings.permission.defaults"))
            } footer: {
                Text(L.string("settings.permission.footer"))
            }

            scriptPermissionsSection
            // 桥层权限状态（只读展示；授权操作在对应功能首次使用时触发）
            Section {
                LabeledContent(L.string("settings.permissions.reminders")) {
                    permissionBadge(granted: remindersAuthorized)
                }
                LabeledContent(L.string("settings.permissions.notifications")) {
                    permissionBadge(granted: notificationsAuthorized)
                }
                Button(L.string("settings.permissions.open_settings")) {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
                    )
                }
            } header: {
                Text(L.string("settings.permissions.system"))
            } footer: {
                Text(L.string("settings.permissions.desc") + "\n" + L.string("settings.scope.global"))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 脚本与权限入口

    /// 只提供入口：规则与记录页面固定绑定当前空间，不再跨空间枚举。
    private var scriptPermissionsSection: some View {
        Section {
            Button(L.string("settings.scriptPermissions.open")) {
                showingScriptPermissions = true
            }
            Text(currentSpaceCaption + "\n" + L.string("settings.scriptPermissions.desc"))
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text(L.string("settings.scriptPermissions.title"))
        }
    }

    // MARK: - Tab: 模型服务

    /// 快速接入预设清单（不含「无」）
    private var quickAccessPresets: [ProviderPreset] {
        ProviderPreset.allCases.filter { $0 != .none }
    }

    /// 快速接入行输入的 API Key（暂存内存，勾选启用时才落 Keychain）
    @State private var presetAPIKeys: [ProviderPreset: String] = [:]
    @State private var addingPresets: Set<ProviderPreset> = []

    /// 快速接入行：已添加 → 启用开关；未添加 → API Key 输入 + 勾选即添加
    private func quickAccessRow(_ preset: ProviderPreset) -> some View {
        let existing = providers.first(where: { $0.endpoint == preset.endpoint })
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                    .font(.body)
                if let existing {
                    Text(existing.model.isEmpty ? existing.endpoint : "\(existing.endpoint) · \(existing.model)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(preset.endpoint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            // 未添加且需要 Key：勾选前先填 Key
            if existing == nil && preset.needsAPIKey {
                SecureField(
                    L.string("settings.provider.apikey"),
                    text: Binding(
                        get: { presetAPIKeys[preset] ?? "" },
                        set: { presetAPIKeys[preset] = $0 }
                    )
                )
                .frame(width: 180)
            }
            Toggle("", isOn: Binding(
                get: { existing?.isEnabled ?? false },
                set: { enable in toggleQuickAccess(preset, existing: existing, enable: enable) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(L.string("common.enabled"))
            .disabled(addingPresets.contains(preset))
        }
    }

    /// 快速接入开关：勾选创建/启用，取消勾选停用
    private func toggleQuickAccess(_ preset: ProviderPreset, existing: LLMProviderConfig?, enable: Bool) {
        guard !addingPresets.contains(preset) else { return }
        if let existing {
            var updated = existing
            updated.isEnabled = enable
            Task {
                try? await hub.providerService?.save(updated, apiKey: nil)
                await load()
            }
            return
        }
        guard enable else { return }
        let key = presetAPIKeys[preset] ?? ""
        // 云端供应商必须先填 Key；本地服务（Ollama/LM Studio/vLLM）直接可用
        if preset.needsAPIKey && key.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = L.string("settings.provider.quickaccess.needkey")
            showErrorAlert = true
            return
        }
        var config = LLMProviderConfig(
            name: preset.displayName,
            endpoint: preset.endpoint,
            model: preset.defaultModel,
            isEnabled: true
        )
        addingPresets.insert(preset)
        Task {
            defer { addingPresets.remove(preset) }
            do {
                if preset == .kimi {
                    let models = try await CloudProvider(config: config, apiKey: key).listModels()
                    guard let selected = preset.availableDefault(in: models) else {
                        throw LLMError.configurationError(reason: L.string("settings.provider.fetchmodels.empty"))
                    }
                    config.model = selected
                }
                try await hub.providerService?.save(config, apiKey: key.isEmpty ? nil : key)
                presetAPIKeys[preset] = nil
                await load()
            } catch {
                errorMessage = L.actionableError(error, fallbackKey: "settings.provider.test_fail")
                showErrorAlert = true
            }
        }
    }

    private var providersTab: some View {
        Form {
            if providers.isEmpty {
                quickAccessSection
                providerListSection
            } else {
                providerListSection
                modelParametersSection
                Section {
                    DisclosureGroup(L.string("settings.provider.quickaccess")) {
                        ForEach(quickAccessPresets, id: \.self) { preset in
                            quickAccessRow(preset)
                        }
                    }
                } footer: {
                    Text(L.string("settings.provider.quickaccess.desc"))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modelParametersSection: some View {
        Section {
            if let service = hub.providerService?.modelParameters {
                ModelParameterSettingsView(providers: providers, service: service)
            }
        } header: {
            Text(L.string("model.parameters.title"))
        } footer: {
            Text(L.string("model.parameters.footer"))
        }
    }

    private var quickAccessSection: some View {
        // 快速接入：预置供应商（填 API Key + 勾选启用即完成配置）
        Section {
            ForEach(quickAccessPresets, id: \.self) { preset in
                quickAccessRow(preset)
            }
        } header: {
            Text(L.string("settings.provider.quickaccess"))
        } footer: {
            Text(L.string("settings.provider.quickaccess.desc"))
        }
    }

    private var providerListSection: some View {
        // LLM 提供者
        Section {
            if providers.isEmpty {
                Text(L.string("settings.providers.empty"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(providers) { provider in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                            .font(.body)
                        Text("\(provider.endpoint) · \(provider.model)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !provider.isEnabled {
                        Text("⏸")
                            .foregroundColor(.secondary)
                    }
                    Button { moveProvider(provider, direction: .up) } label: {
                        Image(systemName: "arrow.up").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L.format("settings.provider.move_up", provider.chatDisplayName))
                    .accessibilityLabel(L.format("settings.provider.move_up", provider.chatDisplayName))
                    .accessibilityIdentifier("settings.provider.move.up.\(provider.id.uuidString)")
                    .disabled(movingProviderID != nil || providers.first?.id == provider.id)
                    Button { moveProvider(provider, direction: .down) } label: {
                        Image(systemName: "arrow.down").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L.format("settings.provider.move_down", provider.chatDisplayName))
                    .accessibilityLabel(L.format("settings.provider.move_down", provider.chatDisplayName))
                    .accessibilityIdentifier("settings.provider.move.down.\(provider.id.uuidString)")
                    .disabled(movingProviderID != nil || providers.last?.id == provider.id)
                    Button(action: { editingProvider = provider }) {
                        Image(systemName: "pencil")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive, action: { providerPendingDeletion = provider }) {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text(L.string("settings.providers"))
                if movingProviderID != nil { ProgressView().controlSize(.mini).accessibilityLabel(L.string("settings.provider.reordering")) }
                Spacer()
                Button(action: { showingNewProvider = true }) {
                    Label(L.string("settings.provider.add"), systemImage: "plus")
                        .font(.caption)
                }
            }
        } footer: {
            Text(L.string("settings.scope.global") + "\n" + L.string("settings.provider.order.help"))
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    // MARK: - Tab: 流量
    // 流量统计已从设置页移出：独立导航入口「流量」（RootView HubNavItem.usage → UsageView）

    private func load() async {
        await loadSkills()
        await loadAgents()
        await loadSystemState()
        hasLegacyQuickPrompts = LegacyQuickPromptMigration.isAvailable()
        do {
            guard let productPreferences else { throw SpaceServiceError.encodingFailed }
            quickPrompts = try await productPreferences.quickPrompts()
        } catch {
            errorMessage = L.string("product.prompts.save.failed")
            showErrorAlert = true
        }
        await loadProviders()
    }

    private func loadProviders() async {
        guard movingProviderID == nil else { return }
        let ticket = UUID(), space = hub.spaceStore.current
        providerLoadID = ticket
        do {
            guard let service = hub.providerService else { throw SpaceServiceError.encodingFailed }
            let values = try await service.getAll()
            guard !Task.isCancelled, providerLoadID == ticket, movingProviderID == nil, hub.spaceStore.current == space else { return }
            if providers != values { providers = values }
        } catch {
            guard !Task.isCancelled, providerLoadID == ticket, hub.spaceStore.current == space else { return }
            errorMessage = L.string("error.database")
            showErrorAlert = true
        }
    }

    private func moveProvider(_ provider: LLMProviderConfig, direction: ProviderConfigService.MoveDirection) {
        guard movingProviderID == nil else { return }
        movingProviderID = provider.id
        providerLoadID = UUID() // Discard any read that started before the move.
        let service = hub.providerService, space = hub.spaceStore.current
        Task {
            defer { movingProviderID = nil }
            do {
                guard let service else { throw SpaceServiceError.encodingFailed }
                let values = try await service.move(id: provider.id, direction: direction)
                guard hub.spaceStore.current == space else { return }
                providers = values
            } catch {
                guard hub.spaceStore.current == space else { return }
                var messageKey = error is ProviderConfigService.OrderingError ? "settings.provider.order.changed" : "settings.provider.order.failed"
                do {
                    if let service {
                        let values = try await service.getAll()
                        guard hub.spaceStore.current == space else { return }
                        providers = values
                    }
                } catch { messageKey = "settings.provider.order.failed" }
                guard hub.spaceStore.current == space else { return }
                errorMessage = L.string(messageKey)
                showErrorAlert = true
            }
        }
    }

    /// 当前空间的能力摘要使用后台快照，避免在主线程扫描技能目录。
    private func loadSkills() async {
        guard let store = hub.makeSkillStore() else { skills = []; return }
        skills = await store.listSnapshot()
    }

    /// 自定义人设 AI 展开：一句话期望 → 完整人设描述（语气/格式/边界），覆盖原文本
    private func expandPersona() {
        let requirement = personaCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirement.isEmpty, !isExpandingPersona else { return }
        let originSpace = space
        isExpandingPersona = true
        Task { @MainActor in
            defer { isExpandingPersona = false }
            do {
                guard let provider = try await hub.makeActiveProvider(for: originSpace, source: "settings-assist") else {
                    throw LLMError.providerUnavailable
                }
                let expanded = try await AIAssistGenerator(provider: provider).text(
                    system: """
                    You write dispatcher persona prompts for a macOS AI assistant hub.
                    The user gives a one-line expectation (possibly already a draft). Expand it into a complete
                    persona description: tone of voice, answer structure (prose vs bullets vs tables),
                    level of detail, proactivity boundaries (when to ask vs act), and what to avoid.
                    80-200 words, same language as the input. Output ONLY the persona text.
                    """,
                    user: requirement
                )
                guard hub.spaceStore.current == originSpace, !Task.isCancelled else { return }
                personaCustomText = expanded
            } catch {
                if hub.spaceStore.current == originSpace {
                    errorMessage = L.actionableError(error, fallbackKey: "error.actionable.provider_connection")
                    showErrorAlert = true
                }
            }
        }
    }

    /// 快捷提示 AI 推荐：扫描近期会话的 user 消息，聚类高频意图生成快捷提示（去重追加）
    private func generateQuickPrompts() {
        isGeneratingPrompts = true
        Task { @MainActor in
            defer { isGeneratingPrompts = false }
            do {
                guard let provider = try await hub.makeActiveProvider(for: space, source: "settings-assist") else {
                    throw LLMError.providerUnavailable
                }
                // 近期会话 user 消息采样（最多 60 条、每条截 80 字，控制注入体积）
                let sessions = (try? await hub.makeSessionService(for: space)?.getAll()) ?? []
                var userMessages: [String] = []
                for session in sessions {
                    for message in session.messages where message.role == .user {
                        let clipped = String(message.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                        if !clipped.isEmpty {
                            userMessages.append(clipped)
                        }
                    }
                }
                let samples = userMessages.suffix(60).joined(separator: "\n")
                let generator = AIAssistGenerator(provider: provider)
                let items = try await generator.list(
                    system: """
                    You write quick-prompt suggestions for a macOS AI assistant hub.
                    Based on the user's recent chat messages, identify recurring intents and output 5 quick prompts
                    that would save typing. Each is ONE short reusable instruction (under 40 chars, same language as the messages,
                    directly actionable, no placeholders). Output one per line as "1. ..." to "5. ...".
                    """,
                    user: samples.isEmpty
                        ? "(no chat history available — suggest generally useful prompts for a personal AI workspace)"
                        : samples
                )
                guard hub.spaceStore.current == space, !Task.isCancelled else { return }
                let existing = Set(quickPrompts.map { $0.trimmingCharacters(in: .whitespaces) })
                for item in items
                where !existing.contains(item) && quickPrompts.count < Self.quickPromptsLimit {
                    quickPrompts.append(item)
                }
                saveQuickPrompts()
            } catch {
                if hub.spaceStore.current == space {
                    errorMessage = L.actionableError(error, fallbackKey: "error.actionable.provider_connection")
                    showErrorAlert = true
                }
            }
        }
    }

    private func saveQuickPrompts() {
        quickPromptSaveTask?.cancel()
        let values = quickPrompts
        quickPromptSaveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                guard let productPreferences else { throw SpaceServiceError.encodingFailed }
                try await productPreferences.saveQuickPrompts(values)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = L.string("product.prompts.save.failed")
                showErrorAlert = true
            }
        }
    }

    private func migrateLegacyPrompts() {
        quickPromptSaveTask?.cancel()
        Task {
            do {
                guard let productPreferences else { throw SpaceServiceError.encodingFailed }
                try await LegacyQuickPromptMigration.migrate(to: productPreferences)
                quickPrompts = try await productPreferences.quickPrompts()
                hasLegacyQuickPrompts = false
            } catch {
                errorMessage = L.string("product.prompts.save.failed")
                showErrorAlert = true
            }
        }
    }

    /// 加载当前空间智体摘要
    private func loadAgents() async {
        agents = (try? await hub.makeAgentService()?.getAll()) ?? []
    }

    private func delete(_ provider: LLMProviderConfig) {
        Task {
            do {
                try await hub.providerService?.delete(id: provider.id)
                await load()
            } catch {
                errorMessage = L.actionableError(error, fallbackKey: "error.actionable.provider_save")
                showErrorAlert = true
            }
        }
    }
}

// MARK: - Provider Preset

/// 提供者预设：快捷填充完整端点（含 API 路径），避免只填域名导致 404。
/// needsAPIKey=false 的本地服务（Ollama/LM Studio/vLLM）勾选启用即可用
enum ProviderPreset: String, CaseIterable {
    case none
    case deepseek
    case glm
    case qwen
    case kimi
    case minimax
    case mimo
    case openai
    case anthropic
    case ollama
    case lmstudio
    case vllm

    var displayName: String {
        switch self {
        case .none: return "—"
        case .deepseek: return "DeepSeek"
        case .glm: return "GLM（智谱）"
        case .qwen: return "Qwen（通义千问）"
        case .kimi: return "Kimi（月之暗面）"
        case .minimax: return "MiniMax"
        case .mimo: return "MiMo（小米）"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama（本地）"
        case .lmstudio: return "LM Studio（本地）"
        case .vllm: return "vLLM（本地）"
        }
    }

    var endpoint: String {
        switch self {
        case .none: return ""
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .kimi: return "https://api.moonshot.cn/v1/chat/completions"
        case .minimax: return "https://api.minimaxi.com/v1/chat/completions"
        case .mimo: return "https://api.xiaomimimo.com/v1/chat/completions"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .ollama: return "http://localhost:11434/v1/chat/completions"
        case .lmstudio: return "http://localhost:1234/v1/chat/completions"
        case .vllm: return "http://localhost:8000/v1/chat/completions"
        }
    }

    var defaultModel: String {
        switch self {
        case .none: return ""
        case .deepseek: return "deepseek-flash"
        case .glm: return "glm-4-flash"
        case .qwen: return "qwen-plus"
        case .kimi: return "kimi-k3.1-pro"
        case .minimax: return "MiniMax-M1"
        case .mimo: return "mimo-v2.5-pro"
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-sonnet-20241022"
        // 本地服务模型名随部署而变：留空，靠「检查可用模型」选取
        case .ollama, .lmstudio, .vllm: return ""
        }
    }

    func availableDefault(in models: [String]) -> String? {
        if models.contains(defaultModel) { return defaultModel }
        if self == .kimi, models.contains("kimi-k3") { return "kimi-k3" }
        if self == .kimi, models.contains("kimi-k3.1-pro-highspeed") { return "kimi-k3.1-pro-highspeed" }
        return models.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted().first
    }

    /// 本地推理服务无需 API Key
    var needsAPIKey: Bool {
        switch self {
        case .ollama, .lmstudio, .vllm: return false
        default: return true
        }
    }
}

// MARK: - Provider Form Sheet

/// 提供者表单：端点强校验 + API Key 仅存 Keychain + 真实连接测试
struct ProviderFormSheet: View {
    let hub: Hub
    let provider: LLMProviderConfig?
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPreset: ProviderPreset = .none
    @State private var saving = false
    @State private var name = ""
    @State private var alias = ""
    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var isEnabled = true
    @State private var isTesting = false
    @State private var testResultMessage: String?
    @State private var testSucceeded = false
    /// 能力检查：提供方可用模型列表
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var modelsFetchError: String?
    /// 账户余额查询（仅 DeepSeek / Kimi 等开放余额接口的厂商）
    @State private var balance: ProviderBalance?
    @State private var isFetchingBalance = false
    @State private var balanceFetchError: String?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    init(hub: Hub, provider: LLMProviderConfig?, onDone: @escaping () -> Void) {
        self.hub = hub
        self.provider = provider
        self.onDone = onDone
        _selectedPreset = State(initialValue: provider.flatMap { configuration in
            ProviderPreset.allCases.first { $0.endpoint == configuration.endpoint }
        } ?? .none)
        _name = State(initialValue: provider?.name ?? "")
        _alias = State(initialValue: provider?.alias ?? "")
        _endpoint = State(initialValue: provider?.endpoint ?? "")
        _model = State(initialValue: provider?.model ?? "")
        _isEnabled = State(initialValue: provider?.isEnabled ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(provider == nil ? L.string("settings.provider.add") : L.string("settings.provider.edit"))
                .font(.title3)
                .fontWeight(.bold)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                // 预设快捷填充：选择后自动写入完整端点（含 API 路径）与默认模型
                Picker(L.string("settings.provider.preset"), selection: Binding(
                    get: { selectedPreset },
                    set: { preset in
                        selectedPreset = preset
                        guard preset != .none else { return }
                        endpoint = preset.endpoint
                        model = preset.defaultModel
                        if name.isEmpty { name = preset.displayName }
                    }
                )) {
                    ForEach(ProviderPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }

                TextField(L.string("settings.provider.name"), text: $name)
                TextField(L.string("settings.provider.alias"), text: Binding(
                    get: { alias },
                    set: { alias = String($0.prefix(LLMProviderConfig.maxAliasLength)) }
                ), prompt: Text(L.format("settings.provider.alias.placeholder", LLMProviderConfig.maxAliasLength)))
                    .help(L.string("settings.provider.alias.help"))
                    .accessibilityIdentifier("settings.provider.alias")
                TextField(L.string("settings.provider.endpoint"), text: $endpoint)
                    .fontDesign(.monospaced)
                    .help(L.string("settings.provider.endpoint.help"))
                TextField(L.string("settings.provider.model"), text: $model)
                    .accessibilityIdentifier("settings.provider.model")
                SecureField(
                    provider == nil ? L.string("settings.provider.apikey") : L.string("settings.provider.apikey.placeholder"),
                    text: $apiKey
                )
                Toggle(L.string("common.enabled"), isOn: $isEnabled)

                // 能力检查：拉取提供方 /models 列表，点选填入 model 字段
                HStack(spacing: 10) {
                    Button(action: fetchModels) {
                        if isFetchingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L.string("settings.provider.fetchmodels"), systemImage: "sparkle.magnifyingglass")
                        }
                    }
                    .disabled(isFetchingModels || endpoint.isEmpty)

                    if isFetchingModels {
                        Text(L.string("settings.provider.fetchmodels.loading"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let error = modelsFetchError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                }
                if !availableModels.isEmpty {
                    Picker(L.string("settings.provider.model.pick"), selection: $model) {
                        Text(L.string("settings.provider.model.manual")).tag("")
                        ForEach(availableModels, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }

                // 账户余额：仅对开放余额接口的厂商显示（DeepSeek / Kimi）
                if CloudProvider.supportsBalanceQuery(endpoint: endpoint) {
                    HStack(spacing: 10) {
                        Button(action: fetchBalance) {
                            if isFetchingBalance {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(L.string("settings.provider.fetchbalance"), systemImage: "yensign.circle")
                            }
                        }
                        .disabled(isFetchingBalance || endpoint.isEmpty)

                        if isFetchingBalance {
                            Text(L.string("settings.provider.fetchbalance.loading"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if let error = balanceFetchError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }
                    }
                    if let balance {
                        VStack(alignment: .leading, spacing: 2) {
                            if let total = balance.total {
                                HStack(spacing: 6) {
                                    Text(L.string("settings.provider.balance.total"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(formattedAmount(total))
                                        .font(.callout)
                                        .foregroundColor(balance.isAvailable ? .primary : .red)
                                }
                            }
                            if !balance.isAvailable {
                                Text(L.string("settings.provider.balance.insufficient"))
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            ForEach(Array(balance.items.filter { $0.label != .total }.enumerated()), id: \.offset) { _, item in
                                HStack(spacing: 6) {
                                    Text(balanceLabel(item.label))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(formattedAmount(item))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button(action: testConnection) {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L.string("common.test"), systemImage: "bolt.horizontal")
                        }
                    }
                    .disabled(isTesting || endpoint.isEmpty)

                    if let result = testResultMessage {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(testSucceeded ? .green : .red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(saving)

            Divider()

            HStack {
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(L.string("common.save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 560)
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 表单值构造配置（编辑时保留原 id）
    private func currentConfig() -> LLMProviderConfig {
        if let provider {
            var updated = provider
            updated.name = name
            updated.alias = alias
            updated.endpoint = endpoint
            updated.model = model
            updated.isEnabled = isEnabled
            return updated
        }
        return LLMProviderConfig(name: name, endpoint: endpoint, model: model, isEnabled: isEnabled, alias: alias)
    }

    private func effectiveAPIKey() -> String {
        if !apiKey.isEmpty { return apiKey }
        if let provider {
            return KeychainService.loadAPIKey(for: provider.id) ?? ""
        }
        return ""
    }

    /// 能力检查：拉取 /models 列表供选择（本地服务如 Ollama/LM Studio 由此选模型）
    private func fetchModels() {
        isFetchingModels = true
        modelsFetchError = nil
        let config = currentConfig()
        let key = effectiveAPIKey()
        Task {
            do {
                let provider = CloudProvider(config: config, apiKey: key)
                let models = try await provider.listModels()
                await MainActor.run {
                    isFetchingModels = false
                    guard currentConfig().endpoint == config.endpoint else { return }
                    availableModels = models
                    if self.provider == nil, selectedPreset == .kimi, model == config.model,
                       model == selectedPreset.defaultModel, let available = selectedPreset.availableDefault(in: models) {
                        model = available
                    }
                    if models.isEmpty {
                        modelsFetchError = L.string("settings.provider.fetchmodels.empty")
                    }
                }
            } catch {
                await MainActor.run {
                    isFetchingModels = false
                    availableModels = []
                    modelsFetchError = L.actionableError(error, fallbackKey: "error.actionable.provider_connection")
                }
            }
        }
    }

    /// 账户余额查询（仅 DeepSeek / Kimi 等开放余额接口的厂商）
    private func fetchBalance() {
        isFetchingBalance = true
        balanceFetchError = nil
        let config = currentConfig()
        let key = effectiveAPIKey()
        Task {
            do {
                let client = CloudProvider(config: config, apiKey: key)
                let result = try await client.fetchBalance()
                await MainActor.run {
                    isFetchingBalance = false
                    balance = result
                }
            } catch {
                await MainActor.run {
                    isFetchingBalance = false
                    balance = nil
                    balanceFetchError = L.actionableError(error, fallbackKey: "error.actionable.balance_lookup")
                }
            }
        }
    }

    /// 余额明细项标题
    private func balanceLabel(_ label: ProviderBalance.ItemLabel) -> String {
        switch label {
        case .total: return L.string("settings.provider.balance.total")
        case .granted: return L.string("settings.provider.balance.granted")
        case .toppedUp: return L.string("settings.provider.balance.toppedup")
        }
    }

    /// 按币种加符号展示金额（金额本身保留提供方返回的原始字符串）
    private func formattedAmount(_ item: ProviderBalance.Item) -> String {
        switch item.currency.uppercased() {
        case "CNY": return "¥\(item.amount)"
        case "USD": return "$\(item.amount)"
        default: return "\(item.amount) \(item.currency)"
        }
    }

    /// 真实连接测试（最小请求验证端点/密钥/模型）
    private func testConnection() {
        isTesting = true
        testResultMessage = nil
        let config = currentConfig()
        let key = effectiveAPIKey()
        Task {
            guard let service = hub.providerService else {
                await MainActor.run {
                    isTesting = false
                    testSucceeded = false
                    testResultMessage = L.string("error.database")
                }
                return
            }
            let result = await service.testConnection(config: config, apiKey: key, usageRecorder: hub.makeUsageRecorder(for: hub.spaceStore.current, source: "connection-test"))
            await MainActor.run {
                isTesting = false
                switch result {
                case .success(let response):
                    testSucceeded = true
                    testResultMessage = L.string(response == "image-model-metadata" ? "settings.provider.image_test_ok" : "settings.provider.test_ok")
                case .failure(let error):
                    testSucceeded = false
                    testResultMessage = "\(L.string("settings.provider.test_fail")): \(L.actionableError(error, fallbackKey: "error.actionable.provider_connection"))"
                }
            }
        }
    }

    private func save() {
        guard !saving else { return }
        // 保存前强制校验端点安全性（不依赖 UI 提示）
        do {
            try EndpointSafety.validate(endpoint)
        } catch {
            errorMessage = L.string("error.endpoint.insecure")
            showErrorAlert = true
            return
        }
        var configuration = currentConfig()
        let keyToSave = apiKey.isEmpty ? nil : apiKey
        let chooseKimi = provider == nil && selectedPreset == .kimi && endpoint == selectedPreset.endpoint
            && model == selectedPreset.defaultModel && keyToSave != nil
        saving = true
        Task {
            defer { saving = false }
            do {
                if chooseKimi, let keyToSave {
                    let list = try await CloudProvider(config: configuration, apiKey: keyToSave).listModels()
                    guard let chosen = ProviderPreset.kimi.availableDefault(in: list) else {
                        throw LLMError.configurationError(reason: L.string("settings.provider.fetchmodels.empty"))
                    }
                    configuration.model = chosen
                }
                try await hub.providerService?.save(configuration, apiKey: keyToSave)
                await MainActor.run { onDone() }
            } catch {
                await MainActor.run {
                    errorMessage = L.actionableError(error, fallbackKey: "error.actionable.provider_save")
                    showErrorAlert = true
                }
            }
        }
    }
}
