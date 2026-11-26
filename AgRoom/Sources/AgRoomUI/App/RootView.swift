import SwiftUI
import AppKit
import AgRoomCore

// MARK: - Space Theme

/// 空间视觉标识（UI 层）：不同强调色防止"忘了在哪个空间"
extension AppSpace {
    public var tint: Color {
        switch self {
        case .personal: return .purple
        case .work: return .blue
        }
    }
}

// MARK: - Nav Item

/// 导航项；未实现的页面在侧栏标注「即将推出」，不做假交互
///
/// 对外公开：App 层（菜单栏）通过 `AppNavigation` 以页名寻址主窗口页面。
public enum HubNavItem: String, CaseIterable, Identifiable {
    case chat
    case mail
    case notes
    case apps
    case agents
    case team
    case scheduled
    case tools
    case files
    case knowledge
    case memory
    case python
    case database
    case browser
    case ocr
    case audio
    case images
    case markdown
    case usage
    case settings
    case help

    public var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .tools: return "nav.skills"
        default: return "nav.\(rawValue)"
        }
    }

    var iconName: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .notes: return "note.text"
        case .mail: return "envelope"
        case .apps: return "square.grid.3x3"
        case .agents: return "person.2"
        case .team: return "person.3"
        case .scheduled: return "calendar.badge.clock"
        case .files: return "folder"
        case .knowledge: return "books.vertical"
        case .memory: return "brain.head.profile"
        case .tools: return "wand.and.stars"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .database: return "cylinder.split.1x2"
        case .browser: return "globe"
        case .ocr: return "text.viewfinder"
        case .audio: return "waveform"
        case .images: return "photo"
        case .markdown: return "doc.richtext"
        case .usage: return "chart.bar"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }

    /// 帮助页功能导览图标底色；主侧栏使用单色线条图标。
    var iconTint: Color {
        switch self {
        case .chat: return .blue
        case .notes: return .yellow
        case .mail: return .cyan
        case .apps: return .purple
        case .agents: return .purple
        case .team: return .indigo
        case .scheduled: return .orange
        case .files: return .accentColor
        case .knowledge: return .orange
        case .memory: return .pink
        case .tools: return .indigo
        case .python: return .green
        case .database: return .teal
        case .browser: return .cyan
        case .ocr: return .mint
        case .audio: return .red
        case .images: return .yellow
        case .markdown: return .brown
        case .usage: return .green
        case .settings: return .gray
        case .help: return .teal
        }
    }

    /// 尚未实现的页面（诚实标注，不做假交互）。当前全部导航项均已实现。
    var isComingSoon: Bool {
        false
    }

    /// 系统内置能力页（Python/OCR/音频/图片/Markdown）不在侧栏展示：
    /// 它们是调度 Agent 的底层能力，由智能体按需调用，无需独立入口。
    /// 浏览器同样不设独立入口：对话过程中经工具执行轨迹面板的浏览器页签打开
    var isVisibleInSidebar: Bool {
        switch self {
        case .python, .ocr, .audio, .images, .markdown, .browser:
            return false
        default:
            return true
        }
    }
}

/// Chinese section names and navigation labels remain two characters per row.
enum HubNavSection: String, CaseIterable {
    case common, resources, abilities, system
    var labelKey: String { "nav.group." + rawValue }
    var items: [HubNavItem] {
        switch self {
        case .common: [.chat, .mail, .notes, .apps]
        case .resources: [.files, .knowledge, .memory, .database]
        case .abilities: [.team, .agents, .tools, .scheduled]
        case .system: [.usage, .settings, .help]
        }
    }
}

// MARK: - Apple Palette

/// Apple 官方配色（随深浅色模式自动适配）
enum ApplePalette {
    /// 侧栏背景：浅色 #F5F5F7，深色 #2C2C2E（Apple 官方灰阶）
    static let sidebarBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
            : NSColor(red: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
    }))
}

// MARK: - Global Search Environment

/// 工具栏全局搜索词：RootView 工具栏搜索框产生，各功能页按自己的语义消费过滤
private struct GlobalSearchKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    var globalSearchText: String {
        get { self[GlobalSearchKey.self] }
        set { self[GlobalSearchKey.self] = newValue }
    }
}

/// 清除工具栏全局搜索词的动作：功能页（如对话页「新建对话」）在需要让新建项可见时调用
private struct ClearGlobalSearchKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

private struct SetGlobalSearchKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var setGlobalSearch: @MainActor @Sendable (String) -> Void {
        get { self[SetGlobalSearchKey.self] }
        set { self[SetGlobalSearchKey.self] = newValue }
    }
    var clearGlobalSearch: @MainActor @Sendable () -> Void {
        get { self[ClearGlobalSearchKey.self] }
        set { self[ClearGlobalSearchKey.self] = newValue }
    }
}

/// 搜索能力属于当前页面；无搜索语义的页面不占用工具栏位置。
private struct PageSearchModifier: ViewModifier {
    @Binding var text: String
    let placeholderKey: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let placeholderKey {
            content.searchable(text: $text, placement: .toolbar, prompt: Text(L.string(placeholderKey)))
        } else {
            content
        }
    }
}

// MARK: - Chat View Model Cache

/// 对话视图模型缓存：按空间持有 ChatViewModel，切换功能页签时对话状态不丢失。
/// （引用类型容器：body 内懒创建不触碰 @State 存储本身，避免渲染期状态突变）
@MainActor
private final class ChatViewModelCache {
    private var models: [AppSpace: ChatViewModel] = [:]

    func model(for space: AppSpace, hub: Hub) -> ChatViewModel {
        if let cached = models[space] { return cached }
        // 显式传入空间：模型归属不受创建时刻 current 变化影响
        let model = ChatViewModel(hub: hub, space: space)
        models[space] = model
        return model
    }
}

@MainActor
private final class NotesModelCache {
    func restore(space: AppSpace) {
        guard let model = models[space] else { return }
        model.invalidateRestoredSettings()
        Task { await model.loadTranscriptionSettings() }
    }
    func deactivate(except space: AppSpace) { for (key, model) in models where key != space { model.deactivateSpaceResources() } }
    private var models: [AppSpace: NotesModel] = [:]
    func model(for space: AppSpace, hub: Hub) -> NotesModel {
        if let model = models[space] { return model }
        let model = NotesLifecycle.retained(space: space,hub: hub) ?? NotesModel(hub: hub, space: space)
        models[space] = model
        return model
    }
}

// MARK: - Mail View Model Cache

/// 邮箱视图模型缓存：按空间持有 MailViewModel，切换功能页签时邮箱状态不丢失。
@MainActor
private final class MailViewModelCache {
    private var models: [AppSpace: MailViewModel] = [:]

    func model(for space: AppSpace, hub: Hub) -> MailViewModel {
        if let cached = models[space] { return cached }
        let model = MailViewModel(hub: hub, space: space)
        models[space] = model
        return model
    }

    /// 空间切走后取消其余空间模型的在途任务：仅重建视图不能证明旧异步任务已结束，
    /// 这些任务的迟到回调必须被作废（模型本身保留，切回时状态仍在）。
    func cancelPendingWork(except space: AppSpace) {
        for (key, model) in models where key != space {
            model.cancelPendingWork()
        }
    }
}

// MARK: - Root View

/// 应用主外壳：完整侧栏 / 图标窄栏与功能区。
public struct RootView: View {
    let hub: Hub
    @State private var selection: HubNavItem = .chat
    @State private var sourceRoute: ProductRoute?
    @State private var mailReferenceError: String?
    @State private var mailReferenceGeneration = UUID()
    @State private var spaceSearchPresentation: SpaceSearchPresentation?
    @State private var searchArtifactPresentation: SearchArtifactPresentation?
    @State private var searchTaskPresentation: SearchTaskPresentation?
    @State private var pendingSearchRoute: ProductRoute?
    @State private var pendingSearchCommand: (AppSpace, SpaceSearchAction)?
    @State private var languageManager = LanguageManager.shared
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 首次启动引导标志（P5）
    @AppStorage("agroom.onboarding_completed") private var onboardingCompleted = false
    @State private var showingFirstTask = false
    @State private var firstTaskGuidanceHidden: Bool?
    @State private var firstTaskGuidanceSpace: AppSpace?
    @State private var firstTaskGuidanceLoadID = UUID()
    @State private var firstTaskGuidanceError: String?
    /// 只保存全局布局偏好，不携带空间数据；重开窗口或切换语言后沿用上次状态。
    @AppStorage(SidebarVisibilityPreference.collapsedKey) private var sidebarCollapsed = false
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        SidebarVisibilityPreference.binding($sidebarCollapsed)
    }
    /// 工具栏全局搜索词（各页面按自己的语义过滤）
    @State private var searchText = ""
    /// 待审批的团队写请求数：侧栏「协作」红点，提醒用户去任务板处理。
    @State private var pendingTeamApprovals = 0
    /// 对话视图模型缓存（按空间隔离）：切页签再回来时正在运行的对话不丢失
    @State private var chatModelCache = ChatViewModelCache()
    /// 邮箱视图模型缓存（按空间隔离）：切页签再回来时邮箱状态不丢失
    @State private var notesModelCache = NotesModelCache()
    @State private var mailModelCache = MailViewModelCache()
    /// 主侧栏初始宽度：中文短标签使用紧凑列宽，英文为较长标签保留空间。
    /// 拖拽宽度只保留在当前窗口；布局回调不写观察态或持久化偏好。
    private var sidebarWidths: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) {
        languageManager.activeLanguageCode == "en"
            ? (190, 200, 260)
            : (140, 160, 220)
    }

    public init(hub: Hub) {
        self.hub = hub
    }

    /// 当前页面搜索框的 placeholder 本地化键；nil 表示该页无搜索（不显示搜索框）
    /// 选中项就是当前内容页，避免侧栏高亮与实际页面分离。
    private var searchPlaceholderKey: String? {
        switch selection {
        case .chat: return "search.sessions"
        case .notes: return "notes.search"
        case .mail: return "search.mail"
        case .apps: return "apps.search"
        case .agents: return "search.agents"
        case .team: return "team.search"
        case .files: return "search.files"
        case .knowledge: return "knowledge.search"
        case .memory: return "search.memories"
        case .tools: return "search.skills"
        case .database: return "search.databases"
        default: return nil
        }
    }

    @AppStorage(KnowledgeEmbeddingSettings.enabledKey) private var embeddingEnabled = true
    @AppStorage(KnowledgeEmbeddingSettings.modelPathKey) private var embeddingModelPath = KnowledgeEmbeddingSettings.defaultModelURL.path

    public var body: some View {
        Group {
            if let issue = hub.spaceStore.databaseIssue {
                DatabaseUnavailableOverlay(issue: issue, hub: hub)
                    .safeAreaInset(edge: .top) { SpaceSwitcher(spaceStore: hub.spaceStore).frame(width: 220) }
            } else if hub.spaceStore.currentQueue != nil {
                mountedWorkspace
            } else {
                ProgressView(L.string("db.mounting")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1120, minHeight: 640)
        .task(id: hub.spaceStore.current) { await hub.prepare(hub.spaceStore.current) }
        .task { installJobCompletionNotifications() }
        .task { await runAutoBackupIfDue() }
        .onOpenURL { url in if url.scheme?.lowercased() == MailSourceReference.scheme { openMailReference(url) } }
        .environment(\.openURL, OpenURLAction { url in MailReferenceRoute.open(url) ? .handled : .systemAction })
        .onReceive(NotificationCenter.default.publisher(for: MailReferenceRoute.notification)) { notification in
            if let url = notification.object as? URL { openMailReference(url) }
        }
        .alert(L.string("mail.reference.title"), isPresented: Binding(get: { mailReferenceError != nil }, set: { if !$0 { mailReferenceError = nil } })) {
            Button(L.string("common.close"), role: .cancel) { mailReferenceError = nil }
        } message: { Text(mailReferenceError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .agroomSpaceRestored)) { notification in
            guard let name = notification.object as? String, let space = AppSpace(rawValue: name) else { return }
            notesModelCache.restore(space: space)
        }
        // 空间切换：取消其余空间邮箱模型的在途任务，作废其迟到回调
        // （视图已按空间重建，但旧异步任务不会自动结束）
        .onChange(of: hub.spaceStore.current) { oldValue, newValue in
            mailReferenceGeneration = UUID(); mailReferenceError = nil
            sourceRoute = nil
            firstTaskGuidanceError = nil
            pendingSearchRoute = nil; pendingSearchCommand = nil
            spaceSearchPresentation = nil; searchArtifactPresentation = nil; searchTaskPresentation = nil
            WorkspaceRegistry.shared.releaseAccess(for: oldValue)
            mailModelCache.cancelPendingWork(except: newValue)
            notesModelCache.deactivate(except: newValue)
            NativeAppLifecycle.synchronize(space: newValue)
        }
    }

    private var mountedWorkspace: some View {
        SidebarNavigationLayout(columnVisibility: columnVisibility, sidebarWidths: sidebarWidths, reduceMotion: reduceMotion) {
            sidebar
        } compactSidebar: {
            CompactSidebar(
                spaceStore: hub.spaceStore,
                selection: selection,
                pendingTeamApprovals: pendingTeamApprovals,
                onSelect: selectNavigationItem
            )
        } detail: {
            detail
                // 空间切换时整体重建，确保所有状态重新绑定新空间库
                .id(hub.spaceStore.current)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 工具栏搜索词下发：各功能页按自己的语义过滤列表
                .environment(\.globalSearchText, searchText)
                // 清除搜索词的动作下发：需要「新建后可见」的功能页调用
                .environment(\.clearGlobalSearch) { searchText = "" }
                .environment(\.setGlobalSearch) { searchText = $0 }
        }
        // 标题栏属于整个窗口，背景和底线不随主侧栏宽窄改变归属。
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1 / displayScale)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // 工具栏后台作业指示器（有作业时出现：进行中计数/完成勾 + 列表 popover）
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pendingSearchRoute = nil; pendingSearchCommand = nil
                    spaceSearchPresentation = .init(space: hub.spaceStore.current)
                } label: { Label(L.string("search.space.title"), systemImage: "magnifyingglass") }
                    .help(L.string("search.space.shortcut"))
                    .disabled(isFirstTaskPresented)
            }
            ToolbarItem(placement: .primaryAction) {
                ReadingTextSizeControl()
            }
            ToolbarItem(placement: .primaryAction) {
                JobIndicatorView(hub: hub, model: chatModelCache.model(for: hub.spaceStore.current, hub: hub))
                    .id(hub.spaceStore.current)
            }
        }
        .task { await pollTeamApprovals() }
        .task(id: "\(hub.spaceStore.current.rawValue):\(embeddingEnabled):\(embeddingModelPath)") {
            await KnowledgeIndexJobs.monitor(hub: hub)
        }
        .task(id: hub.spaceStore.current.rawValue) { await KnowledgeGraphJobs.monitor(hub: hub) }
        .task(id: hub.spaceStore.current) {
            let model = mailModelCache.model(for: hub.spaceStore.current, hub: hub)
            await model.autoSync.monitor()
        }
        // App 层隐藏可见窗口标题，保留窗口身份；此处只在支持列表搜索的页面显示搜索栏。
        // 标题栏底部分隔线由整个分栏视图顶边的水平细线常驻绘制。
        .modifier(PageSearchModifier(text: $searchText, placeholderKey: searchPlaceholderKey))
        // 切换页面清空搜索词：不同页面的搜索语义不同，残留词会造成困惑
        .onReceive(NotificationCenter.default.publisher(for: ProductRoute.notification)) { notification in
            guard let route = notification.object as? ProductRoute else { return }
            AppNavigation.shared.markDelivered(route)
            applyRoute(route)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppNavigation.CommandRequest.notification)) { notification in
            guard let request = notification.object as? AppNavigation.CommandRequest else { return }
            AppNavigation.shared.consume(request)
            guard request.space == hub.spaceStore.current, !isFirstTaskPresented else { return }
            performMenuCommand(request.command)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("agroom.product.firstTask"))) { _ in showingFirstTask = true }
        .task(id: hub.spaceStore.current) { await loadFirstTaskGuidance() }
        .onReceive(NotificationCenter.default.publisher(for: ProductPreferencesService.didChange)) { _ in
            Task { await loadFirstTaskGuidance() }
            Task { await mailModelCache.model(for: hub.spaceStore.current, hub: hub).autoSync.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProductTaskRunStore.didChange)) { _ in
            Task { await loadFirstTaskGuidance() }
        }
        // 主窗口未挂载时（窗口已关闭）菜单发起的跳转在此补发，避免路由被丢弃
        .onAppear {
            AppNavigation.shared.registerSpaceProvider { hub.spaceStore.current }
            AppNavigation.shared.deliverPendingIfNeeded(space: hub.spaceStore.current)
            AppNavigation.shared.deliverCommandIfNeeded(space: hub.spaceStore.current)
        }
        // 最小宽度须容纳主侧栏与详情页内部多栏，避免窄窗口挤压正文与输入区。
        .frame(minWidth: 1120, idealWidth: 1200, minHeight: 640, idealHeight: 760)
        // 守护进程后台执行横幅：有后台任务时悬于顶部（完成后自动消失并刷新会话）
        .overlay(alignment: .top) {
            if DaemonSupervisor.shared.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(L.string("banner.daemon.running"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: DaemonSupervisor.shared.isRunning)
        .tint(hub.spaceStore.current.tint)
        .environment(languageManager)
        .id(languageManager.version)
        .sheet(item: $spaceSearchPresentation, onDismiss: finishSpaceSearch) { context in
            spaceSearchSheet(context)
        }
        .sheet(item: $searchArtifactPresentation) { context in searchArtifactSheet(context) }
        .sheet(item: $searchTaskPresentation) { context in
            TaskCenterPanel(hub: hub, model: chatModelCache.model(for: context.space, hub: hub), initialJobID: context.jobID).id(context.space)
        }
        .sheet(isPresented: Binding(
            get: { isFirstTaskPresented },
            set: { if !$0 { finishFirstTaskPresentation(in: hub.spaceStore.current, skipped: true) } }
        )) {
            let presentedSpace = hub.spaceStore.current
            OnboardingView(hub: hub) { request in
                finishFirstTaskPresentation(in: presentedSpace, skipped: request == nil)
                guard let request else { return }
                let space = request.space
                guard space == hub.spaceStore.current else { return }
                let model = chatModelCache.model(for: space, hub: hub)
                selection = .chat
                Task { await model.startFirstTask(request) }
            }.id(hub.spaceStore.current)
        }
        .alert(L.string("common.error"), isPresented: Binding(
            get: { firstTaskGuidanceError != nil }, set: { if !$0 { firstTaskGuidanceError = nil } }
        )) { Button(L.string("common.ok")) { firstTaskGuidanceError = nil } }
        message: { Text(firstTaskGuidanceError ?? "") }
    }

    private var isFirstTaskPresented: Bool {
        showingFirstTask || (!onboardingCompleted && firstTaskGuidanceSpace == hub.spaceStore.current && firstTaskGuidanceHidden == false)
    }

    private func loadFirstTaskGuidance() async {
        let space = hub.spaceStore.current, ticket = UUID()
        firstTaskGuidanceLoadID = ticket
        do {
            guard let preferences = hub.makeProductPreferencesService(for: space) else { return }
            let state = try await preferences.firstTaskGuidance()
            guard !Task.isCancelled, firstTaskGuidanceLoadID == ticket, hub.spaceStore.current == space else { return }
            if firstTaskGuidanceSpace != space { firstTaskGuidanceSpace = space }
            if firstTaskGuidanceHidden != !state.shouldOfferNewTask { firstTaskGuidanceHidden = !state.shouldOfferNewTask }
        } catch {
            guard !Task.isCancelled, firstTaskGuidanceLoadID == ticket, hub.spaceStore.current == space else { return }
            HubLogger.shared.warning("First task guidance load failed: \(HubLogger.safeErrorSummary(error))")
            firstTaskGuidanceError = L.actionableError(error, fallbackKey: "error.database")
        }
    }

    private func finishFirstTaskPresentation(in space: AppSpace, skipped: Bool) {
        guard space == hub.spaceStore.current else { return }
        onboardingCompleted = true
        showingFirstTask = false
        guard skipped else { return }
        firstTaskGuidanceLoadID = UUID()
        firstTaskGuidanceSpace = space
        firstTaskGuidanceHidden = true
        // The preference service is captured before suspension; a later space
        // switch cannot dismiss the other space's guidance.
        let preferences = hub.makeProductPreferencesService(for: space)
        Task {
            do { try await preferences?.hideFirstTaskGuidance() }
            catch {
                guard hub.spaceStore.current == space else { return }
                firstTaskGuidanceError = L.string("error.database")
            }
        }
    }

    /// 菜单 / ⌘⌥S 与显式工具栏按钮使用同一展开状态，收起后保留图标窄栏。
    private func toggleSidebar() {
        SidebarVisibilityAction.toggle(columnVisibility)
    }

    private func selectNavigationItem(_ item: HubNavItem) {
        mailReferenceGeneration = UUID()
        sourceRoute = nil
        searchText = ""
        selection = item
    }

    /// 应用页面跳转路由：校验空间 → 解析页名 → 切页（对话页额外处理会话与草稿）
    ///
    /// 路由来源有两处：UI 层内的 `ProductRoute.open`，以及 App 层菜单经
    /// `AppNavigation` 发起的跳转；两者语义一致，统一在此落地。
    private func applyRoute(_ route: ProductRoute) {
        mailReferenceGeneration = UUID()
        guard route.space == hub.spaceStore.current else { return }
        if let id = route.artifactVersionID { searchArtifactPresentation = .init(space: route.space, versionID: id); return }
        if route.showTasks { searchTaskPresentation = .init(space: route.space, jobID: route.runID); return }
        guard let page = HubNavItem(rawValue: route.page) else { return }
        searchText = route.searchQuery ?? ""
        sourceRoute = route
        selection = page
        if page == .chat {
            let model = chatModelCache.model(for: route.space, hub: hub)
            Task {
                await model.load()
                guard route.space == hub.spaceStore.current, sourceRoute?.id == route.id, selection == page else { return }
                if let id = route.sessionID {
                    await model.openTaskSource(sessionID: id, messageID: route.messageID)
                }
                guard route.space == hub.spaceStore.current, sourceRoute?.id == route.id, selection == page else { return }
                if let draft = route.draft {
                    await model.prepareProductDraft(draft, workspaceID: route.workspaceID, mode: route.draftMode) {
                        route.space == hub.spaceStore.current && sourceRoute?.id == route.id && selection == page
                    }
                }
            }
        } else if page == .mail, let id = route.contentID.flatMap(UUID.init(uuidString:)) {
            let model = mailModelCache.model(for: route.space, hub: hub)
            Task {
                await model.openSearchSource(id, reference: route.mailReference) {
                    route.space == hub.spaceStore.current && sourceRoute?.id == route.id && selection == page
                }
            }
        }
    }

    private func openMailReference(_ url: URL) {
        let token = UUID(); mailReferenceGeneration = token
        let space = hub.spaceStore.current
        Task {
            do {
                let reference = try MailSourceReference(url: url)
                guard reference.space == space else { throw MailSourceReferenceError.differentSpace }
                await hub.prepare(space)
                guard token == mailReferenceGeneration, space == hub.spaceStore.current, !Task.isCancelled else { return }
                guard let mail = hub.makeMailService(for: space) else { throw MailSourceReferenceError.missing }
                let message = try await mail.resolveSourceReference(reference, in: space)
                guard token == mailReferenceGeneration, space == hub.spaceStore.current, !Task.isCancelled else { return }
                applyRoute(.init(space: space, page: "mail", contentID: message.id.uuidString, mailReference: reference))
            } catch {
                if token == mailReferenceGeneration, space == hub.spaceStore.current, !Task.isCancelled { mailReferenceError = MailErrorText.message(for: error) }
            }
        }
    }

    @ViewBuilder private func spaceSearchSheet(_ context: SpaceSearchPresentation) -> some View {
        if let service = hub.makeSpaceSearchService(for: context.space) {
            let model = chatModelCache.model(for: context.space, hub: hub)
            SpaceSearchView(model: SpaceSearchModel(service: service, includeHidden: model.showHiddenSessions,
                isCurrent: { hub.spaceStore.current == context.space }), onOpen: { value in
                    guard context.space == hub.spaceStore.current else { return }
                    pendingSearchRoute = SpaceSearchRoutes.source(value); spaceSearchPresentation = nil
                }, onQuote: { value in
                    guard context.space == hub.spaceStore.current else { throw SpaceSearchError.invalidScope }
                    pendingSearchRoute = ProductRoute(space: context.space, page: "chat", draft: SearchReferenceDraft.text(value))
                    spaceSearchPresentation = nil
                }, onAction: { action in
                    guard context.space == hub.spaceStore.current else { return }
                    pendingSearchCommand = (context.space, action); spaceSearchPresentation = nil
                })
        } else { Text(L.string("error.database")).padding() }
    }

    private func finishSpaceSearch() {
        let route = pendingSearchRoute, command = pendingSearchCommand
        pendingSearchRoute = nil; pendingSearchCommand = nil
        if let route { applyRoute(route); return }
        guard let (space, action) = command, hub.spaceStore.current == space else { return }
        switch action {
        case .firstTask: showingFirstTask = true
        case .taskCenter: searchTaskPresentation = .init(space: space)
        case .newChat:
            let model = chatModelCache.model(for: space, hub: hub)
            applyRoute(.init(space: space, page: "chat", draft: "", workspaceID: model.workspace(forSession: model.activeSessionId)?.id))
        default: applyRoute(.init(space: space, page: action.rawValue))
        }
    }

    private func performMenuCommand(_ command: AppMenuCommand) {
        let space = hub.spaceStore.current
        switch command {
        case .newChat: applyRoute(.init(space: space, page: "chat", draft: ""))
        case .search:
            pendingSearchRoute = nil; pendingSearchCommand = nil
            spaceSearchPresentation = .init(space: space)
        case .taskCenter: searchTaskPresentation = .init(space: space)
        case .artifactLibrary: searchArtifactPresentation = .init(space: space)
        case .toggleSidebar: toggleSidebar()
        case .noteRecording, .notePaste:
            applyRoute(.init(space: space,page: "notes"))
            let model = notesModelCache.model(for: space,hub: hub)
            guard !model.busy else { model.error = L.string("notes.capture.busy"); return }
            Task {
                await model.loadTranscriptionSettings()
                guard hub.spaceStore.current == space else { return }
                if command == .notePaste { model.pasteNote() }
                else { if model.draft == nil { await model.create() }; model.toggleRecording() }
            }
        case .noteScreenshot:
            applyRoute(.init(space: space, page: "notes"))
            let model = notesModelCache.model(for: space, hub: hub)
            guard !model.busy, !model.recording else { model.error = L.string("notes.capture.busy"); return }
            Task {
                guard hub.spaceStore.current == space else { return }
                await model.create()
                guard hub.spaceStore.current == space else { return }
                model.captureSelection()
            }
        }
    }

    @ViewBuilder private func searchArtifactSheet(_ context: SearchArtifactPresentation) -> some View {
        if let store = hub.makeArtifactStore(for: context.space) {
            let model = chatModelCache.model(for: context.space, hub: hub)
            ArtifactLibraryView(store: store, includeHidden: model.showHiddenSessions,
                roots: { model.taskWorkspace(id: $0.workspaceID)?.folderURLs ?? [] }, onOpenSource: { record in
                    Task {
                        let run = try? await hub.makeTaskRunStore(for: context.space)?.run(id: record.runID)
                        guard hub.spaceStore.current == context.space else { return }
                        searchArtifactPresentation = nil
                        ProductRoute.open(space: context.space, page: "chat", sessionID: record.sessionID,
                            messageID: run?.sessionID == record.sessionID ? run?.messageID : nil)
                    }
                }, onUse: { record in Task { await model.recordProductEvent(.artifactUsed, taskID: record.runID) } },
                onContinue: { artifact, url, record in
                    Task {
                        guard await model.prepareArtifactContinuation(artifact, sessionID: record.sessionID, workspaceID: record.workspaceID,
                            snapshot: url, store: store), hub.spaceStore.current == context.space else { return }
                        searchArtifactPresentation = nil
                        ProductRoute.open(space: context.space, page: "chat", sessionID: model.activeSessionId)
                    }
                }, initialVersionID: context.versionID)
        } else { Text(L.string("error.database")).padding() }
    }

    /// 自动备份（F14）：启动时到期检查 → 逐空间后台出包 → 轮换旧包。
    ///
    /// 成功时间**按空间**记录（`AutoBackupPolicy.lastRunKey(space:)`）：某个空间出包失败
    /// 时只让它自己次日重试，不会被另一个空间的成功顺带跳过。失败同时保留在作业中心
    /// 并触发「失败必达」通知。
    private func runAutoBackupIfDue() async {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: AutoBackupPolicy.enabledKey) as? Bool ?? true
        guard enabled, let destinationDir = AutoBackupPolicy.destinationDirectory() else { return }

        let due = AppSpace.allCases.filter { space in
            let last = defaults.object(forKey: AutoBackupPolicy.lastRunKey(space: space)) as? Date
            return AutoBackupPolicy.isDue(lastRun: last)
        }
        guard !due.isEmpty else { return }

        do {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        } catch {
            let failure = error as NSError
            HubLogger.shared.error("Auto backup directory create failed (\(failure.domain): \(failure.code))")
            return
        }

        let stamp = Self.backupStamp()

        // 逐空间出包（空间隔离：服务现取现建，不入 Hub）
        for space in due {
            await hub.prepare(space)
            guard !Task.isCancelled else { return }
            guard let service = hub.makeBackupService(for: space) else {
                HubLogger.shared.warning("Auto backup skipped: space is unavailable")
                continue
            }
            let url = destinationDir.appendingPathComponent("AgRoom-\(space.rawValue)-\(stamp).zip")
            let job = JobCenter.shared.submitTracked(
                name: L.string("jobs.auto.name") + " · \(space.rawValue)",
                kind: "backup-auto", space: space, origin: "settings", historyStore: hub.makeJobRunStore(for: space)
            ) { ctx in
                let summary = try await service.export(to: url, progress: { ctx.reportProgress($0) })
                let text = await MainActor.run {
                    L.format(
                        "settings.backup.done.export",
                        summary.sessions,
                        summary.memories,
                        summary.skills,
                        summary.attachments,
                        summary.workspaces
                    )
                }
                ctx.reportResult(text)
                ctx.reportResultURL(url)
            }
            Task {
                for await receipt in job.completion where receipt.job.state == .succeeded && receipt.historySaved {
                    UserDefaults.standard.set(Date(), forKey: AutoBackupPolicy.lastRunKey(space: space))
                }
            }
        }

        // 轮换：每空间保留最近 N 份（按修改时间）
        if let existing = try? FileManager.default.contentsOfDirectory(
            at: destinationDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for space in AppSpace.allCases {
                let spaceArchives = existing.filter { $0.lastPathComponent.hasPrefix("AgRoom-\(space.rawValue)-") }
                AutoBackupPolicy.prune(AutoBackupPolicy.filesToPrune(spaceArchives))
            }
        }

        HubLogger.shared.info("Auto backup submitted for \(due.count) of \(AppSpace.allCases.count) space(s)")
    }

    /// 备份文件名时间戳（与设置页导出同风格）
    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }

    /// 安装后台作业完成通知钩子（应用级一次）：
    /// 失败必达；成功仅当应用非前台时投递（前台时用户看得到指示器，不打扰）
    private func installJobCompletionNotifications() {
        JobCenter.shared.onCompletion = { job in
            let shouldNotify: Bool
            switch job.state {
            case .failed:
                shouldNotify = true
            case .succeeded:
                shouldNotify = await MainActor.run { !NSApplication.shared.isActive }
            default:
                shouldNotify = false
            }
            guard shouldNotify else { return }
            let service = NotificationService()
            switch job.state {
            case .succeeded:
                _ = try? await service.send(
                    title: L.string("jobs.notify.succeeded.title"),
                    body: L.format("jobs.notify.succeeded.body", job.name),
                    category: .background
                )
            case .failed:
                _ = try? await service.send(
                    title: L.string("jobs.notify.failed.title"),
                    body: L.format("jobs.notify.failed.body", job.name, job.errorText ?? ""),
                    category: .background
                )
            default:
                break
            }
        }
    }

    // MARK: - Sidebar（macOS 系统设置风格行）

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 空间切换器在侧栏顶部（默认标题栏样式：交通灯在标题栏，
            // 无需避让，侧栏内容从顶部自然开始）
            SpaceSwitcher(spaceStore: hub.spaceStore)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)

            // 不用 List(selection:)：系统高亮（AppKit 层）与行内容（SwiftUI 层）不同帧更新，
            // 是菜单项切换闪烁的根源。选中态由 SettingsStyleRow 自绘（高亮胶囊与文字同层同动画），
            // 仅保留 sidebar 样式的原生布局与 hover。
            List {
                ForEach(HubNavSection.allCases, id: \.self) { section in
                    Section(L.string(section.labelKey)) {
                        ForEach(section.items) { item in
                            Button { selectNavigationItem(item) } label: {
                                SettingsStyleRow(
                                    item: item,
                                    isSelected: selection == item,
                                    badgeCount: item == .team ? pendingTeamApprovals : 0
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("nav." + item.rawValue)
                            .accessibilityAddTraits(selection == item ? [.isSelected] : [])
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // 隐藏 List 自带背景，统一使用 Apple 官方配色
            .scrollContentBackground(.hidden)
        }
        .background(ApplePalette.sidebarBackground)
    }

    private func pollTeamApprovals() async {
        while !Task.isCancelled {
            pendingTeamApprovals = await TeamApprovalCenter.shared
                .pendingRequests(space: hub.spaceStore.current.rawValue)
                .count
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .chat:
            ChatView(hub: hub, viewModel: chatModelCache.model(for: hub.spaceStore.current, hub: hub))
        case .notes:
            NotesView(model: notesModelCache.model(for: hub.spaceStore.current, hub: hub))
                .id(hub.spaceStore.current)
        case .mail:
            MailView(hub: hub, viewModel: mailModelCache.model(for: hub.spaceStore.current, hub: hub))
        case .apps:
            AppsView(hub: hub, sourceID: sourceRoute?.page == "apps" ? sourceRoute?.contentID : nil).id(sourceRoute?.id)
        case .agents:
            AgentsView(hub: hub, sourceID: sourceRoute?.page == "agents" ? sourceRoute?.contentID.flatMap(UUID.init(uuidString:)) : nil).id(sourceRoute?.id)
        case .team:
            TeamTasksView(hub: hub, source: sourceRoute?.page == "team" ? sourceRoute : nil)
        case .scheduled:
            ScheduledTasksView(hub: hub, source: sourceRoute?.page == "scheduled" ? sourceRoute : nil)
        case .files:
            FilesView(hub: hub)
        case .knowledge:
            KnowledgeView(hub: hub, source: sourceRoute?.page == "knowledge" ? sourceRoute : nil)
        case .memory:
            MemoryView(hub: hub, sourceID: sourceRoute?.page == "memory" ? sourceRoute?.contentID.flatMap(UUID.init(uuidString:)) : nil).id(sourceRoute?.id)
        case .tools:
            SkillsView(hub: hub, sourceID: sourceRoute?.page == "tools" ? sourceRoute?.contentID : nil).id(sourceRoute?.id)
        case .python:
            PythonView(hub: hub)
                .id(hub.spaceStore.current)
        case .database:
            DatabasesView(hub: hub)
        case .browser:
            BrowserView(hub: hub)
        case .ocr:
            OCRView(hub: hub)
        case .audio:
            AudioView(hub: hub)
        case .images:
            ImageViewerView(hub: hub)
        case .markdown:
            MarkdownEditorView(hub: hub)
        case .usage:
            UsageView(hub: hub)
        case .settings:
            let tab = sourceRoute?.settingsTab
            SettingsView(hub: hub, notesModel: notesModelCache.model(for: hub.spaceStore.current, hub: hub), initialTab: tab)
                .id(tab == nil ? nil : sourceRoute?.id)
                .id(hub.spaceStore.current)
        case .help:
            HelpView(hub: hub)
        }
    }
}

// MARK: - Sidebar Layout

enum SidebarVisibilityPreference {
    static let collapsedKey = "agroom.sidebar.collapsed"

    static func binding(_ collapsed: Binding<Bool>) -> Binding<NavigationSplitViewVisibility> {
        Binding {
            collapsed.wrappedValue ? .detailOnly : .all
        } set: { visibility in
            // 自动布局不覆盖用户明确选择的展开 / 收起偏好。
            guard visibility == .all || visibility == .detailOnly else { return }
            collapsed.wrappedValue = visibility == .detailOnly
        }
    }
}

@MainActor
enum SidebarVisibilityAction {
    static func toggle(_ visibility: Binding<NavigationSplitViewVisibility>) {
        // 动画由布局容器统一管理，工具栏、菜单与快捷键只改变同一个目标状态。
        visibility.wrappedValue = visibility.wrappedValue == .detailOnly ? .all : .detailOnly
    }
}

/// 完整导航与图标窄栏共用同一个可变宽容器，避免原生列收起与图标栏插入各自动画。
/// detail 和两种导航均保持挂载；切换只改变宽度、透明度和交互可见性。
struct SidebarNavigationLayout<Sidebar: View, CompactSidebar: View, Detail: View>: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let sidebarWidths: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat)
    let reduceMotion: Bool
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var compactSidebar: CompactSidebar
    @ViewBuilder var detail: Detail

    @Environment(\.displayScale) private var displayScale
    @State private var resizedSidebarWidth: CGFloat?
    @GestureState private var resizeTranslation: CGFloat = 0

    private var isCollapsed: Bool { columnVisibility == .detailOnly }
    private var expandedSidebarWidth: CGFloat {
        clampedSidebarWidth((resizedSidebarWidth ?? sidebarWidths.ideal) + resizeTranslation)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    sidebar
                        .frame(width: expandedSidebarWidth)
                        .opacity(isCollapsed ? 0 : 1)
                        .allowsHitTesting(!isCollapsed)
                        .disabled(isCollapsed)
                        .accessibilityHidden(isCollapsed)
                    compactSidebar
                        .frame(width: 64)
                        .opacity(isCollapsed ? 1 : 0)
                        .allowsHitTesting(isCollapsed)
                        .disabled(!isCollapsed)
                        .accessibilityHidden(!isCollapsed)
                }
                .frame(width: isCollapsed ? 64 : expandedSidebarWidth, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(ApplePalette.sidebarBackground)
                .clipped()

                sidebarDivider

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 必须覆盖整个横向布局，才能让详情位移与侧栏宽度使用同一进度。
            // 只对展开状态加动画；窗口缩放、分隔条拖拽和页面内部状态不触发此动画。
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: isCollapsed)
            .toolbar { sidebarToggle }
        }
    }

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, sidebarWidths.minimum), sidebarWidths.maximum)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1 / displayScale)
            .overlay {
                if !isCollapsed {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                        }
                        .gesture(
                            // 分隔条本身会移动，使用固定坐标避免位移被重复抵消。
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .updating($resizeTranslation) { value, translation, _ in
                                    translation = value.translation.width
                                }
                                .onEnded { value in
                                    resizedSidebarWidth = clampedSidebarWidth(
                                        (resizedSidebarWidth ?? sidebarWidths.ideal) + value.translation.width
                                    )
                                }
                        )
                }
            }
            .accessibilityHidden(true)
    }

    @ToolbarContentBuilder
    private var sidebarToggle: some ToolbarContent {
        // 固定归属窗口，避免每次切换都卸载 / 重装 NSToolbarItem 并重新求解标题栏约束。
        ToolbarItem(id: "sidebar.visibility", placement: .cancellationAction) {
            Button {
                SidebarVisibilityAction.toggle($columnVisibility)
            } label: {
                Label(L.string("menu.toggle_sidebar"), systemImage: "sidebar.left")
            }
            .help(L.string("menu.toggle_sidebar"))
            .accessibilityIdentifier("toolbar.sidebar.toggle")
        }
    }
}

struct CompactSidebar: View {
    let spaceStore: SpaceStore
    let selection: HubNavItem
    let pendingTeamApprovals: Int
    let onSelect: (HubNavItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SpaceSwitcher(spaceStore: spaceStore, isCompact: true)
                .padding(.vertical, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(HubNavSection.allCases, id: \.self) { section in
                            VStack(spacing: 4) {
                                ForEach(section.items) { item in
                                    Button { onSelect(item) } label: {
                                        SettingsStyleRow(
                                            item: item,
                                            isSelected: selection == item,
                                            badgeCount: item == .team ? pendingTeamApprovals : 0,
                                            isCompact: true
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help(L.string(item.labelKey))
                                    .accessibilityLabel(L.string(item.labelKey))
                                    .accessibilityValue(item == .team && pendingTeamApprovals > 0
                                        ? String(format: L.string("team.approval.chat.pending_count"), pendingTeamApprovals) : "")
                                    .accessibilityIdentifier("nav." + item.rawValue)
                                    .accessibilityAddTraits(selection == item ? [.isSelected] : [])
                                    .id(item)
                                }
                            }
                            if section != .system {
                                Divider()
                                    .padding(.horizontal, 8)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selection, initial: true) { _, item in
                    proxy.scrollTo(item, anchor: .center)
                }
            }
        }
        .background(ApplePalette.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.compact")
    }
}

// MARK: - Database Unavailable Overlay

/// 数据库不可用遮罩：展示失败原因与数据库文件路径，
/// 并提供「在访达中显示 / 打开备份文件夹 / 重试」三个恢复入口
private struct DatabaseUnavailableOverlay: View {
    let issue: SpaceStore.DatabaseIssue
    let hub: Hub

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Label(L.string("db.unavailable.title"), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundColor(.orange)
                Text(L.string("db.unavailable.body"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(L.string("db.unavailable.reason")): \(issue.reason)")
                    Text("\(L.string("db.unavailable.path")): \(issue.path)")
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(L.string("db.unavailable.openFolder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: issue.path)])
                    }
                    Button(L.string("db.unavailable.openBackups")) {
                        guard let directory = AutoBackupPolicy.destinationDirectory() else { return }
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(directory)
                    }
                    Button(L.string("db.unavailable.retry")) {
                        Task { await hub.retryDatabases() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(maxWidth: 460, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(40)
        }
    }
}

// MARK: - Space Switcher

/// 完整侧栏显示图标与空间名；图标窄栏用当前空间图标切换空间。
struct SpaceSwitcher: View {
    @Bindable var spaceStore: SpaceStore
    var isCompact = false

    var body: some View {
        if isCompact {
            Button(action: {
                // 切换到另一个空间
                let nextSpace: AppSpace = (spaceStore.current == .work) ? .personal : .work
                spaceStore.switchTo(nextSpace)
            }) {
                Image(systemName: spaceStore.current.iconName)
                    .symbolRenderingMode(.palette)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(spaceStore.current.tint)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .frame(width: 44, height: 34)
            .background(spaceStore.current.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            .help(L.string(spaceStore.current.nameKey) + " · " + L.string("space.switch"))
            .accessibilityLabel(L.string("space.switch"))
            .accessibilityValue(L.string(spaceStore.current.nameKey))
            .accessibilityIdentifier("space.switch")
        } else {
            expandedSwitcher
        }
    }

    private var expandedSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(AppSpace.allCases) { space in
                let isSelected = spaceStore.current == space
                Button(action: { spaceStore.switchTo(space) }) {
                    HStack(spacing: MeetSpacing.xs) {
                        Image(systemName: space.iconName)
                        Text(L.string(space.nameKey + ".short"))
                    }
                        .font(MeetTypography.secondary.weight(isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? space.tint.opacity(0.16) : Color.clear)
                        )
                        .foregroundColor(isSelected ? space.tint : .secondary)
                }
                .buttonStyle(.plain)
                .help(L.string(space.nameKey))
                .accessibilityLabel(L.string(space.nameKey))
            }

        }
        .padding(3)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
        .help(L.string("space.isolation_note"))
    }
}

// MARK: - Nav Row

/// 简洁导航行：单色线条图标放在 28pt 对齐区域内，配合 15pt 文本。
/// 选中态自绘：高亮胶囊与文字同处一层、共用同一动画，杜绝双层不同帧的闪烁
private struct SettingsStyleRow: View {
    let item: HubNavItem
    let isSelected: Bool
    var badgeCount: Int = 0
    var isCompact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) {
                    if badgeCount > 0 {
                        Text(badgeCount > 9 ? "9+" : "\(badgeCount)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .background(Color.red, in: Capsule())
                            .offset(x: 5, y: -3)
                    }
                }
            if !isCompact {
                Text(L.string(item.labelKey))
                    .font(MeetTypography.navigation.weight(isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: LanguageManager.shared.activeLanguageCode != "en", vertical: false)
                    .help(L.string(item.labelKey))
                Spacer(minLength: 0)
                if item.isComingSoon {
                    Text(L.string("common.coming_soon"))
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        // 胶囊背景与文字变色同层同步过渡（选中态唯一来源，无可失步的双层）
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Coming Soon View

/// 诚实占位页：明确标注即将推出，不做假交互
struct ComingSoonView: View {
    let labelKey: String

    var body: some View {
        ContentUnavailableView {
            Label(L.string(labelKey), systemImage: "hammer")
        } description: {
            Text(L.string("common.coming_soon"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
