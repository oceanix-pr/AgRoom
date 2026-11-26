import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgRoomCore

/// Owns only its private directory, never the original security-scoped archive.
struct StagedSkillImport<Preview> {
    private let directory: URL
    let zipURL: URL
    let preview: Preview

    init(from source: URL, in root: URL = FileManager.default.temporaryDirectory,
         inspect: (URL) throws -> Preview) throws {
        let directory = root.appendingPathComponent("skill-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let copy = directory.appendingPathComponent("archive.zip")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            self.preview = try inspect(copy)
        } catch {
            Self.remove(directory)
            throw error
        }
        self.directory = directory
        self.zipURL = copy
    }

    func discard() { Self.remove(directory) }

    private static func remove(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { HubLogger.shared.error("Skill import cleanup failed: " + HubLogger.safeErrorSummary(error)) }
    }
}

// MARK: - Skills View

/// 技能页：Anthropic Agent Skills 标准（SKILL.md 格式）。
/// 本页负责导入、编辑和管理技能；AI 新增技能统一从对话界面发起。
public struct SkillsView: View {
    let hub: Hub
    private let space: AppSpace
    private let sourceID: String?

    @Environment(\.scenePhase) private var scenePhase
    /// 工具栏搜索词：过滤技能列表（名称 + 描述）
    @Environment(\.globalSearchText) private var searchText
    @State private var skills: [Skill] = []
    @State private var showingZipImporter = false
    @State private var skillPendingDeletion: Skill?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var editingSkillName: String?
    /// 使用统计（技能名 → 成功加载次数 + 最近使用时间），列表排序与行内展示
    @State private var usageStats: [String: SkillUsageSummary] = [:]
    /// 待确认的 ZIP 导入（临时副本 + 预览信息；确认后才落盘）
    @State private var pendingImport: StagedSkillImport<SkillStore.SkillImportPreview>?
    /// 悬停行（列表 hover 高亮）
    @State private var hoveredSkillName: String?
    /// 导出 ZIP 的技能（fileExporter 目标）
    @State private var exportingSkill: Skill?
    @State private var taskTemplate: SkillTaskTemplate?
    /// 列表栏显示宽度：拖动期间只改这里，拖动结束才写偏好。
    /// 依据与崩溃栈见 `SplitColumnWidth`：布局回调里写观察态会让窗口 abort。
    @State private var listWidth: Double
    private static let listWidthKey = "agroom.skills.listWidth"

    public init(hub: Hub, sourceID: String? = nil) {
        self.space = hub.spaceStore.current; self.sourceID = sourceID
        self.hub = hub
        self._listWidth = State(
            initialValue: SplitColumnWidth.snapshot(
                key: Self.listWidthKey, defaultValue: 320, range: 220...480
            )
        )
    }

    public var body: some View {
        // 两栏常驻（可拖拽分隔）：技能列表 | 编辑器（内部含文件树 + 编辑器）。
        // 编辑器始终挂载（未选技能时内部显示占位），列结构不随选择变化，
        // 避免点击技能瞬间列数改变导致的宽度跳动。
        // 空间不足时只压缩显示，拖动结束才写偏好
        GeometryReader { geo in
            let layout = SplitWidths.resolve(
                available: Double(geo.size.width),
                dividers: 1,
                columns: [
                    SplitWidths.Column(width: listWidth, range: 220...480),
                    SplitWidths.Column(width: 0, range: 320...(.infinity), flexible: true)
                ]
            )
            HStack(spacing: 0) {
                skillList
                    .frame(width: CGFloat(layout[0]))

                SplitDivider(
                    columnWidth: $listWidth,
                    range: 220...480,
                    persistKey: Self.listWidthKey,
                    direction: 1
                )

                SkillEditorView(hub: hub, skillName: editingSkillName) {
                    Task { await load() }
                }
                // 切换技能时重置编辑器全部状态（@State/onAppear 重新初始化），
                // 否则视图复用导致内容停留在上一个技能
                .id(editingSkillName ?? "")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sourceID) {
            await load()
            guard !Task.isCancelled, hub.spaceStore.current == space, let sourceID else { return }
            if skills.contains(where: { $0.name == sourceID }) { editingSkillName = sourceID }
            else { errorMessage = L.errorDescription(SpaceSearchError.missing); showErrorAlert = true }
        }
        // 回到应用时刷新列表：访达里删除/修改技能文件夹后立即反映
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await load() }
            }
        }
        // 导出 ZIP：目标位置选择器
        .fileExporter(
            isPresented: Binding(
                get: { exportingSkill != nil },
                set: { if !$0 { exportingSkill = nil } }
            ),
            document: ExportedSkillDocument(skillName: exportingSkill?.name),
            contentType: .zip,
            defaultFilename: exportingSkill.map { "\($0.name).zip" } ?? "skill.zip"
        ) { result in
            handleZipExport(result)
        }
        // 导入 ZIP 技能包
        .fileImporter(
            isPresented: $showingZipImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            handleZipImport(result)
        }
        .confirmationDialog(
            L.string("chat.delete_confirm.title"),
            isPresented: Binding(
                get: { skillPendingDeletion != nil },
                set: { if !$0 { skillPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("common.delete"), role: .destructive) {
                if let skill = skillPendingDeletion { delete(skill) }
                skillPendingDeletion = nil
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            if let skill = skillPendingDeletion {
                Text(L.format("skills.delete_confirm.message", skill.displayName))
            }
        }
        .onDisappear { cancelImport() }
        // 导入预览确认：名称/描述/文件数/覆盖冲突，确认后才写入技能库
        .confirmationDialog(
            L.string("skills.import.preview.title"),
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { cancelImport() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("skills.import.confirm"), role: .destructive) {
                confirmImport()
            }
            Button(L.string("common.cancel"), role: .cancel) {
                cancelImport()
            }
        } message: {
            if let preview = pendingImport?.preview {
                Text(Self.importPreviewMessage(preview))
            }
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $taskTemplate) { template in
            SkillTaskTemplateView(hub: hub, space: space, template: template) { name in
                editingSkillName = name
                Task { await load() }
            }
        }
    }

    // MARK: - Skill List (第一栏，会话页风格：标题头 + 分隔线 + 白底列表)

    /// 搜索过滤后的技能（名称或描述命中，大小写不敏感），
    /// 按使用频率排序：常用在前（加载次数 ↓ → 最近使用 ↓ → 名称 ↑）
    private var filteredSkills: [Skill] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let base = query.isEmpty
            ? skills
            : skills.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.alias.localizedCaseInsensitiveContains(query)
                    || $0.description.localizedCaseInsensitiveContains(query)
            }
        return base.sorted { lhs, rhs in
            let lhsStats = usageStats[lhs.name]
            let rhsStats = usageStats[rhs.name]
            let lhsLoads = lhsStats?.loads ?? 0
            let rhsLoads = rhsStats?.loads ?? 0
            if lhsLoads != rhsLoads { return lhsLoads > rhsLoads }
            let lhsUsed = lhsStats?.lastUsed ?? .distantPast
            let rhsUsed = rhsStats?.lastUsed ?? .distantPast
            if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
            return lhs.name < rhs.name
        }
    }

    private var skillList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string("skills.title"))
                    .font(MeetTypography.sectionTitle)
                Spacer()
                Menu {
                    ForEach(SkillTaskTemplate.allCases) { template in
                        Button(L.string(template.titleKey)) { taskTemplate = template }
                    }
                } label: { Label(L.string("scenario.templates"), systemImage: "square.on.square") }
                .menuStyle(.borderlessButton).fixedSize()
                Button {
                    ProductRoute.open(space: space, page: "chat", draft: L.string("product.skills.create.prompt"))
                } label: { Label(L.string("product.skills.create"), systemImage: "sparkles") }
                .buttonStyle(.borderless)
                // Import remains available next to the conversation creation entry.
                Button(action: { showingZipImporter = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(L.string("skills.create.zip"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // 标题栏统一高度（与技能编辑器头部一致）
            .columnHeader()

            Divider()

            let visibleSkills = filteredSkills
            if visibleSkills.isEmpty {
                VStack(spacing: 8) {
                    Text(L.string("skills.empty"))
                        .font(MeetTypography.control)
                    Text(L.string("skills.empty.desc"))
                        .font(MeetTypography.secondary)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L.string("product.skills.create")) {
                        ProductRoute.open(space: space, page: "chat", draft: L.string("product.skills.create.prompt"))
                    }.buttonStyle(.borderedProminent)
                    Button(L.string("skills.create.zip")) { showingZipImporter = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(visibleSkills) { skill in
                            row(skill)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 使用统计悬停说明：加载/脚本/失败明细
    private func usageHelp(_ stats: SkillUsageSummary) -> String {
        var parts = [L.format("skills.usage.line", stats.loads)]
        if stats.runs > 0 {
            parts.append(L.format("skills.usage.runs", stats.runs))
        }
        if stats.failures > 0 {
            parts.append(L.format("skills.usage.failures", stats.failures, Int(((stats.failureRate ?? 0) * 100).rounded())))
        }
        return parts.joined(separator: "\n")
    }

    private func row(_ skill: Skill) -> some View {
        let isSelected = editingSkillName == skill.name
        let isHovered = hoveredSkillName == skill.name
        return HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(MeetTypography.control)
                .foregroundStyle(MeetStatusColor.textual)
            VStack(alignment: .leading, spacing: 3) {
                // 第一行：alias 外显（无 alias 时 displayName 回退为 name）；
                // 整行 lineLimit(1)：窄栏下截断而非折行
                HStack(spacing: 6) {
                    Text(skill.displayName)
                        .font(MeetTypography.listTitle)
                        .lineLimit(1)
                        .help(skill.displayName)
                    if !skill.isEnabled {
                        StatusBadge(text: L.string("skills.disabled"), color: .secondary)
                    }
                }
                .lineLimit(1)
                // 第二行：技术名 name（仅 alias 存在时显示，否则与第一行重复）
                if !skill.alias.isEmpty {
                    Text(skill.name)
                        .font(MeetTypography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // 第三行：最后修改时间 + 成功加载次数（失败仅记录不展示，明细见悬停提示）；
                // 窄栏下整行单行截断，日期/统计不折行
                HStack(spacing: 4) {
                    Text(AppDate.string(from: skill.updatedAt))
                    if let stats = usageStats[skill.name], stats.total > 0 {
                        Text("·")
                        Label("\(stats.loads)", systemImage: "arrow.triangle.2.circlepath")
                            .help(usageHelp(stats))
                    }
                }
                .font(MeetTypography.secondary)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Toggle(L.string("common.enabled"), isOn: Binding(
                get: { skill.isEnabled },
                set: { setSkillEnabled(skill, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L.string("skills.enable.help"))
            .accessibilityLabel(L.format("skills.enable.label", skill.displayName))
            HStack(spacing: MeetSpacing.xs) {
                Button(action: { revealInFinder(skill) }) {
                    Image(systemName: "folder")
                        .frame(width: MeetLayout.rowActionSize, height: MeetLayout.rowActionSize)
                }
                .buttonStyle(.plain)
                .help(L.string("skills.reveal"))
                Button(role: .destructive, action: { skillPendingDeletion = skill }) {
                    Image(systemName: "trash")
                        .frame(width: MeetLayout.rowActionSize, height: MeetLayout.rowActionSize)
                }
                .buttonStyle(.plain)
                .help(L.string("common.delete"))
            }
            .foregroundStyle(.secondary)
            .opacity(isHovered || isSelected ? 1 : 0.55)
        }
        .padding(.vertical, MeetSpacing.sm)
        .padding(.horizontal, MeetSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { editingSkillName = skill.name }
        .onHover { hovering in
            hoveredSkillName = hovering ? skill.name : nil
        }
        // 右键菜单：与对话页会话列表交互模式一致
        .contextMenu {
            Button(action: { editingSkillName = skill.name }) {
                Label(L.string("common.open"), systemImage: "pencil")
            }
            Button(action: { revealInFinder(skill) }) {
                Label(L.string("skills.reveal"), systemImage: "folder")
            }
            Button(action: { exportingSkill = skill }) {
                Label(L.string("skills.export_zip"), systemImage: "doc.badge.arrow.down")
            }
            Divider()
            Button(role: .destructive, action: { skillPendingDeletion = skill }) {
                Label(L.string("common.delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func setSkillEnabled(_ skill: Skill, enabled: Bool) {
        guard let store = hub.makeSkillStore(for: space) else {
            errorMessage = L.string("error.database")
            showErrorAlert = true
            return
        }
        do {
            try store.setEnabled(name: skill.name, enabled: enabled)
            // 快照固定使用点击时的空间服务，切换空间后的迟到结果不会改读新空间。
            Task { skills = await store.listSnapshot() }
        } catch {
            errorMessage = Self.describe(error)
            showErrorAlert = true
        }
    }

    private func load() async {
        guard let store = hub.makeSkillStore(for: space) else {
            errorMessage = L.string("error.database")
            showErrorAlert = true
            return
        }
        // 旧数据库技能一次性迁移到技能库（幂等：已存在的同名文件夹跳过）
        if let legacy = try? await hub.makeSkillService(for: space)?.getAll(), !legacy.isEmpty {
            store.migrateFromLegacy(legacy)
        }
        // 后台快照扫描：不在主线程逐个读盘解析 SKILL.md
        let loaded = await store.listSnapshot()
        guard !Task.isCancelled, hub.spaceStore.current == space else { return }
        skills = loaded
        usageStats = SkillUsageLog(skillsDirectoryURL: store.skillsDirectoryURL).usageStats()
    }

    /// 导出 ZIP 结果回调
    private func handleZipExport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard let skill = exportingSkill else { return }
            do {
                try hub.makeSkillStore(for: space)?.exportZip(name: skill.name, to: url)
            } catch {
                errorMessage = Self.describe(error)
                showErrorAlert = true
            }
        case .failure(let error):
            errorMessage = L.errorDescription(error)
            showErrorAlert = true
        }
    }

    /// StoreError 走本地化键；其他错误取 localizedDescription
    static func describe(_ error: Error) -> String {
        if let storeError = error as? SkillStore.StoreError {
            return L.string(storeError.localizationKey)
        }
        return L.errorDescription(error)
    }

    /// 导入预览信息（对话框 message）：名称/描述/文件数 + 覆盖警告
    static func importPreviewMessage(_ preview: SkillStore.SkillImportPreview) -> String {
        var lines = [
            L.format("skills.import.preview.name", preview.name),
            L.format("skills.import.preview.files", preview.fileCount)
        ]
        if !preview.description.isEmpty {
            lines.insert(
                L.format("skills.import.preview.description", String(preview.description.prefix(160))),
                at: 1
            )
        }
        if preview.overwritesExisting {
            lines.append(L.string("skills.import.preview.overwrite"))
        }
        return lines.joined(separator: "\n")
    }

    private func delete(_ skill: Skill) {
        do {
            try hub.makeSkillStore(for: space)?.delete(name: skill.name)
            if editingSkillName == skill.name { editingSkillName = nil }
            Task { await load() }
        } catch {
            errorMessage = Self.describe(error)
            showErrorAlert = true
        }
    }

    /// 导入 ZIP 技能包结果回调：先复制到临时目录并预检（名称/描述/文件数/覆盖冲突），
    /// 弹确认对话框；用户确认后才真正写入技能库
    private func handleZipImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // fileImporter 返回安全域 URL，需显式访问授权
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = hub.makeSkillStore(for: space) else {
                    throw LLMError.configurationError(reason: "Skill store unavailable")
                }
                let staged = try StagedSkillImport(from: url) { try store.inspectZip(from: $0) }
                pendingImport?.discard()
                pendingImport = staged
            } catch {
                errorMessage = Self.describe(error)
                showErrorAlert = true
            }
        case .failure(let error):
            errorMessage = L.errorDescription(error)
            showErrorAlert = true
        }
    }

    /// 确认导入：写入技能库（覆盖同名时 SkillStore 自动快照旧版本）
    private func confirmImport() {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        defer { pending.discard() }
        do {
            guard let store = hub.makeSkillStore(for: space) else {
                throw LLMError.configurationError(reason: "Skill store unavailable")
            }
            editingSkillName = try store.importZip(from: pending.zipURL)
            Task { await load() }
        } catch {
            errorMessage = Self.describe(error)
            showErrorAlert = true
        }
    }

    /// 取消导入：清理临时副本
    private func cancelImport() {
        pendingImport?.discard()
        pendingImport = nil
    }

    /// 在访达中定位技能文件夹（技能包是文件夹，导出/分发直接操作目录）
    private func revealInFinder(_ skill: Skill) {
        guard let store = hub.makeSkillStore(for: space),
              let url = try? store.folderURL(for: skill.name) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Exported Skill Document

/// fileExporter 的占位文档：实际压缩由 SkillStore.exportZip 在回调中完成，
/// 文档自身不承载数据（write 不会被调用，导出 URL 直接交给 store）
struct ExportedSkillDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let skillName: String?

    init(skillName: String?) {
        self.skillName = skillName
    }

    init(configuration: ReadConfiguration) throws {
        self.skillName = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // 真正的 ZIP 由回调里 SkillStore.exportZip 写入目标 URL；此处返回空壳
        FileWrapper(directoryWithFileWrappers: [:])
    }
}

// MARK: - Skill AI Create Sheet

/// The check and synchronous filesystem write run in one MainActor turn.
@MainActor
enum SkillGenerationWriteGate {
    static func perform<Value>(
        originSpace: AppSpace,
        currentSpace: () -> AppSpace,
        write: () throws -> Value
    ) throws -> Value {
        try Task.checkCancellation()
        guard currentSpace() == originSpace else { throw CancellationError() }
        return try write()
    }
}

/// AI 新增技能：用户只需描述"技能要做什么"，
/// AI 按 Anthropic 规范产出 SKILL.md（含 allowed-tools 声明），
/// 需要 Python 业务逻辑时同步编写脚本存入技能包 scripts/。
/// 生成过程有日志展示；需求含糊时 AI 提出一个澄清问题，
/// 等待用户回答最多 60 秒，超时未答则 AI 自行判断继续。
struct SkillAICreateSheet: View {
    /// 生成阶段
    enum Phase: Equatable {
        case input
        case generating
        case clarifying(questions: [String])
    }

    let hub: Hub
    let space: AppSpace
    /// 创建成功回调（技能名）：选中并刷新列表
    let onCreated: (String) -> Void

    init(hub: Hub, onCreated: @escaping (String) -> Void) {
        self.hub = hub
        self.space = hub.spaceStore.current
        self.onCreated = onCreated
    }

    @Environment(\.dismiss) private var dismiss
    @State private var requirement = ""
    @State private var phase: Phase = .input
    /// 过程日志（每行一条，按发生顺序追加）
    @State private var logLines: [String] = []
    /// 深度思考阶段的流式文本（think → chatStream onDelta 实时追加）
    @State private var thinkingText = ""
    /// 生成/审查阶段的流式输出（generate/review → SSE onDelta 实时追加）
    @State private var generatingText = ""
    /// 是否参考空间知识库（检索相关条目注入生成上下文）
    @State private var useKnowledge = false
    /// 联网检索：搜索相关资料，经 LLM 打分门（≥90 分）过滤后注入生成上下文。
    /// 生活/工作空间均可用（双空间仅做数据隔离，不限制此功能）
    @State private var useWebSearch = false
    /// 联网检索产出的上下文（首轮执行，澄清轮复用，避免重复网络请求与打分调用）
    @State private var webContextText: String?
    /// 深度模式：生成后自我审查修订 + 脚本语法校验修复闭环
    @State private var deepMode = true
    /// 澄清回答（与 clarifying.questions 一一对应，未填为空）
    @State private var answers: [String] = []
    @State private var remainingSeconds = 60
    @State private var countdownTask: Task<Void, Never>?
    @State private var runTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    private var isBusy: Bool {
        if case .input = phase { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L.string("skills.create.ai"))
                .font(MeetTypography.pageTitle)
                .fontWeight(.bold)
                .padding(.top, 16)
                .padding(.bottom, 4)
            Text(L.string("skills.create.ai.hint"))
                .font(MeetTypography.secondary)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            TextEditor(text: $requirement)
                .font(MeetTypography.control)
                .frame(minHeight: 90)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .disabled(isBusy)

            // 知识库挂接：检索相关条目作为领域事实注入
            Toggle(isOn: $useKnowledge) {
                Label(L.string("skills.create.ai.knowledge"), systemImage: "books.vertical")
                    .font(MeetTypography.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .disabled(isBusy)
            .help(L.string("skills.create.ai.knowledge.hint"))

            // 联网检索挂接：搜索相关资料经打分门过滤后注入
            Toggle(isOn: $useWebSearch) {
                Label(L.string("skills.create.ai.websearch"), systemImage: "globe")
                    .font(MeetTypography.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .disabled(isBusy)
            .help(L.string("skills.create.ai.websearch.hint"))

            // 深度模式：自我审查 + 脚本校验闭环
            Toggle(isOn: $deepMode) {
                Label(L.string("skills.create.ai.deep"), systemImage: "brain.head.profile")
                    .font(MeetTypography.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .disabled(isBusy)
            .help(L.string("skills.create.ai.deep.hint"))

            processLog
            clarifyCard

            Divider()
                .padding(.top, 12)

            HStack {
                Spacer()
                Button(L.string("common.cancel")) { cancel() }
                    .keyboardShortcut(.cancelAction)
                if case .input = phase {
                    Button(action: { startGeneration(priorAnswer: nil) }) {
                        Label(L.string("skills.create.ai.action"), systemImage: "sparkles")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        // 调大弹窗并支持手动拖拽调整；思考过程不折叠、完整滚动展示
        .frame(minWidth: 640, idealWidth: 760, minHeight: 620, idealHeight: 820)
        .background(SheetResizeEnabler())
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear { cancelRunning() }
    }

    // MARK: - Process Log

    /// 生成过程日志 + 深度思考/生成流式文本：滚动区，新内容自动滚到底
    private var processLog: some View {
        Group {
            if !logLines.isEmpty || !thinkingText.isEmpty || !generatingText.isEmpty {
                ScrollViewReader { proxy in
                    logScrollView
                        .onChange(of: logLines.count) { _, _ in
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        .onChange(of: thinkingText) { _, _ in
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        .onChange(of: generatingText) { _, _ in
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(8)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
    }

    private var logScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                    logRow(line)
                }
                thinkingSection
                generatingSection
                workingRow
                Color.clear
                    .frame(height: 1)
                    .id("bottom")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func logRow(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(MeetTypography.secondary)
                .foregroundColor(.green)
            Text(line)
                .font(MeetTypography.secondary.monospaced())
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 深度思考：流式完整展示（不折叠），带标题行与正文浅底色区分日志行
    @ViewBuilder
    private var thinkingSection: some View {
        if !thinkingText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(L.string("skills.create.ai.thinking.title"), systemImage: "brain.head.profile")
                    .font(MeetTypography.secondary.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(thinkingText)
                    .font(MeetTypography.secondary.monospaced())
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
            }
        }
    }

    /// 生成输出：技能包 JSON 的流式展示（SSE 实时追加；深度模式含审查修订输出）
    @ViewBuilder
    private var generatingSection: some View {
        if !generatingText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(L.string("skills.create.ai.generating.title"), systemImage: "curlybraces.square")
                    .font(MeetTypography.secondary.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(generatingText)
                    .font(MeetTypography.secondary.monospaced())
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
            }
        }
    }

    @ViewBuilder
    private var workingRow: some View {
        if phase == .generating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L.string("skills.create.ai.log.working"))
                    .font(MeetTypography.secondary.monospaced())
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Clarify Card

    /// 澄清问答卡片：AI 的一个问题 + 60 秒倒计时 + 回答输入
    @ViewBuilder
    private var clarifyCard: some View {
        if case .clarifying(let questions) = phase {
            VStack(alignment: .leading, spacing: 8) {
                Label(L.string("skills.create.ai.clarify.title"), systemImage: "questionmark.circle")
                    .font(MeetTypography.control)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                ForEach(Array(questions.enumerated()), id: \.offset) { index, q in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(q)")
                            .font(MeetTypography.listTitle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // 安全绑定：提交/超时会先清空 answers 再切 phase，
                        // 期间文本编辑事务仍可能读旧 Binding，裸下标会越界崩溃
                        TextField(
                            L.string("skills.create.ai.clarify.placeholder"),
                            text: Binding(
                                get: { index < answers.count ? answers[index] : "" },
                                set: { newValue in
                                    if index < answers.count {
                                        answers[index] = newValue
                                    }
                                }
                            ),
                            onCommit: { submitAnswer() }
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
                Text(L.format("skills.create.ai.clarify.countdown", remainingSeconds))
                    .font(MeetTypography.secondary)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button(action: { submitAnswer() }) {
                        Text(L.string("skills.create.ai.clarify.submit"))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasAnyFilledAnswer)
                    Button(action: { submitAnswer(forceTimeout: true) }) {
                        Text(L.string("skills.create.ai.clarify.skip"))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }

    /// 是否至少填写了一题回答（用于启用提交按钮）
    private var hasAnyFilledAnswer: Bool {
        answers.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Generation Flow

    /// 启动/继续生成：priorAnswer 为澄清回答（超时则带超时说明由 AI 自行判断）。
    /// 流程：检索知识库（可选）→ 深度思考（流式展示）→ 生成技能包 → 落盘
    private func startGeneration(priorAnswer: String?) {
        guard phase != .generating, hub.spaceStore.current == space else { return }
        phase = .generating
        appendLog(priorAnswer == nil
            ? L.string("skills.create.ai.log.analyze")
            : L.string("skills.create.ai.log.answered"))
        runTask = Task {
            do {
                guard let provider = try await hub.makeActiveProvider(for: space, source: "skill-design") else {
                    throw LLMError.providerUnavailable
                }
                try Task.checkCancellation()
                guard hub.spaceStore.current == space else { throw CancellationError() }
                guard let store = hub.makeSkillStore(for: space), let scriptSpace = store.space, scriptSpace == space else {
                    throw LLMError.configurationError(reason: "Skill store unavailable")
                }
                let generator = SkillGenerator(provider: provider)

                // 知识库挂接：检索相关条目作为领域事实注入
                var knowledgeContext: String?
                if useKnowledge {
                    appendLog(L.string("skills.create.ai.log.knowledge"))
                    let (context, hitCount) = await Self.retrieveKnowledge(hub: hub, space: space, query: requirement)
                    knowledgeContext = context
                    appendLog(hitCount > 0
                        ? L.format("skills.create.ai.log.knowledge.hit", hitCount)
                        : L.string("skills.create.ai.log.knowledge.empty"))
                }

                // 联网检索挂接：检索词生成 → 引擎抓取 → 合并 Top10 → 打分门过滤。
                // 仅首轮执行（澄清轮复用 webContextText）；每一步失败都降级，不阻断主干
                var webContext: String?
                if useWebSearch {
                    if priorAnswer == nil {
                        appendLog(L.string("skills.create.ai.log.web.search"))
                        webContext = await Self.retrieveWebContext(
                            generator: generator,
                            requirement: requirement,
                            log: { line in appendLog(line) }
                        )
                        webContextText = webContext
                    } else {
                        webContext = webContextText
                    }
                }

                // 深度思考：仅首轮执行（澄清后复用已有思考）
                var thinking: String?
                if priorAnswer == nil {
                    appendLog(L.string("skills.create.ai.log.thinking"))
                    thinking = try await generator.think(
                        requirement: requirement,
                        knowledgeContext: knowledgeContext,
                        webContext: webContext
                    ) { delta in
                        Task { @MainActor in thinkingText += delta }
                    }
                    appendLog(L.string("skills.create.ai.log.thinking.done"))
                } else {
                    thinking = thinkingText.isEmpty ? nil : thinkingText
                }

                appendLog(L.string("skills.create.ai.log.generating"))
                // 最多三轮：初次 → 澄清后 → 模型仍提问则强制自行判断
                var answer = priorAnswer
                for round in 0..<3 {
                    // 每轮重新流式展示生成输出（SSE）
                    generatingText = ""
                    let result = try await generator.generateInteractive(
                        requirement: requirement,
                        priorAnswer: answer,
                        knowledgeContext: knowledgeContext,
                        webContext: webContext,
                        thinking: thinking
                    ) { delta in
                        Task { @MainActor in generatingText += delta }
                    }
                    switch result {
                    case .package(var package):
                        appendLog(L.format(
                            "skills.create.ai.log.package",
                            package.scripts.count
                        ))
                        // 深度模式：自我审查修订（失败回退初稿，不阻断）
                        if deepMode {
                            // 审查输出重新流式展示
                            generatingText = ""
                            package = await Self.reviewPackage(
                                package,
                                generator: generator,
                                requirement: requirement,
                                thinking: thinking,
                                log: { line in appendLog(line) },
                                onDelta: { delta in
                                    Task { @MainActor in generatingText += delta }
                                }
                            )
                        }
                        // 脚本验证闭环：py_compile 语法校验 + 冒烟真实执行 + 失败回喂修复
                        let verified = await Self.validateAndFixScripts(
                            package,
                            space: scriptSpace,
                            generator: generator,
                            log: { line in appendLog(line) }
                        )
                        package = verified.package
                        // 静态校验 + 自动修正（allowed-tools 合法性 / 引用文件指针）
                        let validated = SkillGenerator.validatePackage(package)
                        package = validated.package
                        for warning in validated.warnings {
                            appendLog(warning)
                        }
                        appendLog(L.string("skills.create.ai.log.write"))
                        let savedName = try SkillGenerationWriteGate.perform(
                            originSpace: space,
                            currentSpace: { hub.spaceStore.current }
                        ) {
                            try savePackage(package, into: store, disableForRepair: verified.hasUnrepairedScripts)
                        }
                        if verified.hasUnrepairedScripts {
                            appendLog(L.format("skills.create.ai.log.repair_disabled", savedName))
                        }
                        appendLog(L.format("skills.create.ai.log.done", savedName))
                        stopCountdown()
                        onCreated(savedName)
                        dismiss()
                        return
                    case .needsClarification(let questions):
                        // 已给过回答仍提问 → 最后一轮强制自行判断
                        guard answer == nil, round < 2 else {
                            answer = "(the user cannot answer; use your best judgment)"
                            continue
                        }
                        appendLog(L.string("skills.create.ai.log.clarify"))
                        answers = Array(repeating: "", count: questions.count)
                        phase = .clarifying(questions: questions)
                        startCountdown()
                        runTask = nil
                        return
                    }
                }
                throw SkillGenerator.GeneratorError.invalidJSON
            } catch is CancellationError {
                phase = .input
            } catch {
                phase = .input
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
        }
    }

    /// 检索空间知识库：返回格式化上下文与命中条数（无命中返回 nil）
    static func retrieveKnowledge(hub: Hub, space: AppSpace, query: String) async -> (String?, Int) {
        guard let service = hub.makeKnowledgeService(for: space),
              let items = try? await service.getAll() else { return (nil, 0) }
        let hits = KnowledgeRanker.search(query: query, items: items, limit: 8)
        guard !hits.isEmpty else { return (nil, 0) }
        let context = hits
            .map { "[\($0.title)]\n\(String($0.content.prefix(800)))" }
            .joined(separator: "\n\n")
        return (context, hits.count)
    }

    /// 联网检索环节：检索词生成（LLM）→ 引擎抓取通道并发 → RRF 合并 Top10 →
    /// LLM 打分门（temperature 0）→ 仅保留 ≥ 阈值的结果。
    /// 每一步失败都降级（返回 nil 或空），绝不阻断生成主干；
    /// 打分失败不注入未过滤内容（宁可没有，不可误导）
    static func retrieveWebContext(
        generator: SkillGenerator,
        requirement: String,
        log: @MainActor (String) -> Void
    ) async -> String? {
        // 1) 检索词生成
        let queries: [String]
        do {
            queries = try await generator.generateSearchQueries(requirement: requirement)
        } catch {
            log(L.string("skills.create.ai.log.web.queries.failed"))
            return nil
        }
        guard !queries.isEmpty else {
            log(L.string("skills.create.ai.log.web.queries.failed"))
            return nil
        }
        log(L.format("skills.create.ai.log.web.queries", queries.count))

        // 2) 各检索词并发抓取（单通道失败返回空列表，由合并环节自然降级）
        let channel = DuckDuckGoSearchChannel()
        let resultLists: [[WebSearchResult]] = await withTaskGroup(of: [WebSearchResult].self) { group in
            for query in queries {
                group.addTask { await channel.search(query: query) }
            }
            var lists: [[WebSearchResult]] = []
            for await list in group { lists.append(list) }
            return lists
        }

        // 3) 合并去重取 Top 10（不足不硬凑）
        let merged = WebSearchService.merge(resultLists, limit: 10)
        if merged.isEmpty {
            log(L.string("skills.create.ai.log.web.empty"))
            return nil
        }

        // 4) 打分门
        let scored: [SkillGenerator.ScoredSearchResult]
        do {
            scored = try await generator.scoreSearchResults(requirement: requirement, results: merged)
        } catch {
            log(L.string("skills.create.ai.log.web.score.failed"))
            return nil
        }
        let passing = scored.filter { $0.score >= SkillGenerator.searchScoreThreshold }
        if passing.isEmpty {
            log(L.string("skills.create.ai.log.web.score.none"))
            return nil
        }
        log(L.format("skills.create.ai.log.web.scored", passing.count, merged.count))

        // 5) 格式化为注入上下文（显式标注来源与未核实状态）
        return passing
            .map { result in
                "[\(result.result.title)]\n\(result.result.url)\n\(result.result.snippet)"
            }
            .joined(separator: "\n\n")
    }

    /// 深度模式：自我审查（checklist 批判初稿 → 修订版）。失败时回退初稿（审查是增强而非硬依赖）
    static func reviewPackage(
        _ package: GeneratedSkillPackage,
        generator: SkillGenerator,
        requirement: String,
        thinking: String?,
        log: @MainActor (String) -> Void,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async -> GeneratedSkillPackage {
        do {
            log(L.string("skills.create.ai.log.reviewing"))
            let revised = try await generator.review(
                package: package,
                requirement: requirement,
                thinking: thinking,
                onDelta: onDelta
            )
            log(L.string("skills.create.ai.log.reviewed"))
            return revised
        } catch {
            log(L.string("skills.create.ai.log.review.fallback"))
            return package
        }
    }

    /// 脚本保存前检查：py_compile 语法校验，失败回喂模型修复（每脚本最多 2 轮）。
    /// 只编译，不执行脚本；运行验证由编辑器里的独立入口触发并单独判定 codeExecution 权限。
    static func validateAndFixScripts(
        _ package: GeneratedSkillPackage,
        space: AppSpace,
        generator: SkillGenerator,
        log: @MainActor (String) -> Void
    ) async -> (package: GeneratedSkillPackage, hasUnrepairedScripts: Bool) {
        guard !package.scripts.isEmpty else { return (package, false) }
        let executor = PythonExecutor(space: space, workspaceName: "skill-gen-check")
        guard executor.runtimeStatus.pythonPath != nil else {
            log(L.string("skills.create.ai.log.check.skip"))
            return (package, false)
        }
        var scripts = package.scripts
        var hasUnrepaired = false
        for index in scripts.indices {
            var script = scripts[index]
            for round in 0..<2 {
                log(L.format("skills.create.ai.log.checking", script.path))
                do {
                    guard let result = try await executor.compileCheck(code: script.content) else {
                        log(L.string("skills.create.ai.log.check.skip"))
                        break
                    }
                    // 保存前只验证语法；绝不在这里执行生成脚本的顶层逻辑。
                    var failureText: String?
                    if !result.succeeded {
                        failureText = result.displayOutput.isEmpty ? "exit=\(result.exitCode)" : result.displayOutput
                    }
                    if let failureText {
                        guard round < 1 else {
                            // 第二轮仍失败：不再静默保留——标记不可修复，调用方将禁用该技能
                            hasUnrepaired = true
                            log(L.format("skills.create.ai.log.check.still_failing", script.path))
                            break
                        }
                        log(L.format("skills.create.ai.log.fixing", script.path))
                        let fixed = try await generator.fixScript(path: script.path, content: script.content, errorMessage: failureText)
                        script = GeneratedSkillPackage.ScriptFile(path: script.path, content: fixed)
                        scripts[index] = script
                        continue
                    }
                    log(L.format("skills.create.ai.log.check.pass", script.path))
                    break
                } catch {
                    log(L.string("skills.create.ai.log.check.skip"))
                    break
                }
            }
            scripts[index] = script
        }
        return (GeneratedSkillPackage(skill: package.skill, scripts: scripts, references: package.references), hasUnrepaired)
    }

    /// 落盘：完整包先组装，再原子替换，失败保留旧包；同名冲突自动加序号。
    /// hasUnrepairedScripts=true 时技能以禁用态保存（待人工修复），并在日志中给出指引。
    /// 运行验证不在这里发生；只记录“语法通过/未验证”。
    private func savePackage(_ package: GeneratedSkillPackage, into store: SkillStore, disableForRepair: Bool = false) throws -> String {
        var skill = package.skill
        skill.isEnabled = !disableForRepair
        let finalName = try store.installPackage(
            skill,
            scripts: package.scripts.map { ($0.path, $0.content) },
            references: package.references.map { ($0.path, $0.content) },
            overwrite: false
        )
        let outcome: SkillValidationOutcome
        if disableForRepair {
            outcome = .failed
        } else if package.scripts.isEmpty {
            outcome = .unverified
        } else {
            outcome = .syntaxPassed
        }
        store.saveValidationRecord(
            SkillValidationRecord(
                outcome: outcome,
                scripts: package.scripts.map {
                    SkillScriptValidation(
                        path: $0.path,
                        outcome: disableForRepair ? .failed : .syntaxPassed,
                        message: disableForRepair
                            ? "The generated script still failed syntax checks."
                            : "Syntax OK (not executed)."
                    )
                },
                executed: false,
                detail: disableForRepair
                    ? "Syntax checks still failed after repair attempts."
                    : "Syntax checked only; runtime smoke test has not run."
            ),
            name: finalName
        )
        HubLogger.shared.info("AI skill creation completed")
        return finalName
    }

    // MARK: - Answer & Countdown

    /// 提交回答（可多项）；forceTimeout 或全空时由 AI 自行判断
    private func submitAnswer(forceTimeout: Bool = false) {
        guard case .clarifying(let questions) = phase else { return }
        stopCountdown()
        let filled: [String] = questions.indices.map { i in
            (i < answers.count ? answers[i] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if forceTimeout || filled.allSatisfy(\.isEmpty) {
            appendLog(L.string("skills.create.ai.log.timeout"))
            answers = []
            startGeneration(priorAnswer: "(no answer given; decide yourself using best judgment)")
        } else {
            // 组成“Q1/A1 / Q2/A2 …”给模型，未答项跳过
            let composed = questions.indices.compactMap { i -> String? in
                let a = filled[i]
                guard !a.isEmpty else { return nil }
                return "Q\(i + 1): \(questions[i])\nA\(i + 1): \(a)"
            }.joined(separator: "\n\n")
            answers = []
            startGeneration(priorAnswer: composed)
        }
    }

    /// 60 秒倒计时：每秒递减，归零视作超时自行判断
    private func startCountdown() {
        remainingSeconds = 60
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while remainingSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remainingSeconds -= 1
            }
            submitAnswer(forceTimeout: true)
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }

    /// 取消：关闭弹窗并终止进行中的生成与倒计时
    private func cancel() {
        cancelRunning()
        dismiss()
    }

    /// 仅终止任务（sheet 已在消失，无需再 dismiss）
    private func cancelRunning() {
        runTask?.cancel()
        runTask = nil
        stopCountdown()
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
    }
}

// MARK: - Skill AI Rewrite Sheet

/// AI 重写已有技能：以现有 SKILL.md + 文件清单 + 改进说明为上下文重新生成，
/// 就地覆盖 SKILL.md 与脚本（保留其他资源文件与启用状态）。
/// 同 AI 新增：知识库可选挂接、深度思考流式滚动展示
struct SkillRewriteSheet: View {
    let hub: Hub
    let space: AppSpace
    let skillName: String
    /// 重写应用完成回调（编辑器重新加载）
    let onApplied: () -> Void

    init(hub: Hub, skillName: String, onApplied: @escaping () -> Void) {
        self.hub = hub
        self.space = hub.spaceStore.current
        self.skillName = skillName
        self.onApplied = onApplied
    }

    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @State private var isRunning = false
    @State private var logLines: [String] = []
    @State private var thinkingText = ""
    /// 重写/审查阶段的流式输出（rewrite/review → SSE onDelta 实时追加）
    @State private var generatingText = ""
    @State private var useKnowledge = false
    /// 深度模式：自我审查修订 + 脚本语法校验修复闭环
    @State private var deepMode = true
    /// 注入真实使用反馈（skill_load / 脚本运行成败记录）
    @State private var useUsageFeedback = true
    @State private var runTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    /// AI 改进建议（基于使用失败记录 + SKILL.md）
    @State private var suggestions: [String] = []
    @State private var isLoadingSuggestions = false

    var body: some View {
        VStack(spacing: 0) {
            Text(L.string("skills.rewrite.title"))
                .font(MeetTypography.pageTitle)
                .fontWeight(.bold)
                .padding(.top, 16)
                .padding(.bottom, 4)
            Text(L.string("skills.rewrite.hint"))
                .font(MeetTypography.secondary)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            TextEditor(text: $instruction)
                .font(MeetTypography.control)
                .frame(minHeight: 70)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .disabled(isRunning)

            // AI 改进建议：基于使用失败记录 + 现有 SKILL.md 预生成 3 条可点选指令
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            instruction = suggestion
                            self.suggestions = []
                        } label: {
                            Label(suggestion, systemImage: "lightbulb")
                                .font(MeetTypography.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 22)
                    }
                }
            } else {
                HStack {
                    Button {
                        loadSuggestions()
                    } label: {
                        if isLoadingSuggestions {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L.string("skills.rewrite.suggest"), systemImage: "lightbulb")
                                .font(MeetTypography.secondary)
                        }
                    }
                    .buttonStyle(.link)
                    .disabled(isRunning || isLoadingSuggestions)
                    .padding(.horizontal, 20)
                    Spacer()
                }
            }

            Toggle(isOn: $useKnowledge) {
                Label(L.string("skills.create.ai.knowledge"), systemImage: "books.vertical")
                    .font(MeetTypography.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .disabled(isRunning)
            .help(L.string("skills.create.ai.knowledge.hint"))

            // 真实使用反馈：技能运行成败记录注入重写上下文（越用越深闭环）
            Toggle(isOn: $useUsageFeedback) {
                Label(L.string("skills.rewrite.usage"), systemImage: "chart.line.uptrend.xyaxis")
                    .font(MeetTypography.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .disabled(isRunning)
            .help(L.string("skills.rewrite.usage.hint"))

            // 深度模式：自我审查 + 脚本校验闭环
            Toggle(isOn: $deepMode) {
                Label(L.string("skills.create.ai.deep"), systemImage: "brain.head.profile")
                    .font(MeetTypography.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .disabled(isRunning)
            .help(L.string("skills.create.ai.deep.hint"))

            processLog

            Divider()
                .padding(.top, 12)

            HStack {
                Spacer()
                Button(L.string("common.cancel")) {
                    runTask?.cancel()
                    runTask = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(action: { startRewrite() }) {
                    Label(L.string("skills.rewrite.action"), systemImage: "sparkles")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 620)
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            runTask?.cancel()
            runTask = nil
        }
    }

    // MARK: - Process Log

    private var processLog: some View {
        Group {
            if !logLines.isEmpty || !thinkingText.isEmpty || !generatingText.isEmpty {
                ScrollViewReader { proxy in
                    logScrollView
                        .onChange(of: logLines.count) { _, _ in
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        .onChange(of: thinkingText) { _, _ in
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        .onChange(of: generatingText) { _, _ in
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(8)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
    }

    private var logScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                    logRow(line)
                }
                thinkingSection
                generatingSection
                workingRow
                Color.clear
                    .frame(height: 1)
                    .id("bottom")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func logRow(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(MeetTypography.secondary)
                .foregroundColor(.green)
            Text(line)
                .font(MeetTypography.secondary.monospaced())
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var thinkingSection: some View {
        if !thinkingText.isEmpty {
            Text(thinkingText)
                .font(MeetTypography.secondary.monospaced())
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    /// 重写输出：技能包 JSON 的流式展示（SSE 实时追加；深度模式含审查修订输出）
    @ViewBuilder
    private var generatingSection: some View {
        if !generatingText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(L.string("skills.create.ai.generating.title"), systemImage: "curlybraces.square")
                    .font(MeetTypography.secondary.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(generatingText)
                    .font(MeetTypography.secondary.monospaced())
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
            }
        }
    }

    @ViewBuilder
    private var workingRow: some View {
        if isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L.string("skills.create.ai.log.working"))
                    .font(MeetTypography.secondary.monospaced())
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Rewrite Flow

    /// AI 改进建议：基于使用失败记录 + 当前 SKILL.md 生成 3 条可点选的重写指令
    private func loadSuggestions() {
        guard hub.spaceStore.current == space else { return }
        isLoadingSuggestions = true
        Task { @MainActor in
            defer { isLoadingSuggestions = false }
            do {
                guard let store = hub.makeSkillStore(for: space) else { return }
                guard let provider = try await hub.makeActiveProvider(for: space, source: "skill-design") else {
                    throw LLMError.providerUnavailable
                }
                guard !Task.isCancelled, hub.spaceStore.current == space else { return }
                let skillMD = (try? String(
                    contentsOf: store.folderURL(for: skillName).appendingPathComponent("SKILL.md"),
                    encoding: .utf8
                )) ?? ""
                let feedback = SkillUsageLog(skillsDirectoryURL: store.skillsDirectoryURL)
                    .feedbackSummary(for: skillName) ?? ""
                let generator = AIAssistGenerator(provider: provider)
                let items = try await generator.list(
                    system: """
                    You suggest rewrite instructions for an existing agent skill (SKILL.md format).
                    Based on the current SKILL.md and real-world usage feedback (failures are gold),
                    output EXACTLY 3 numbered suggestions (one line each, under 60 chars, same language as the SKILL.md).
                    Each suggestion must be a concrete, actionable rewrite instruction
                    (e.g. add argument validation to fix the crash, restructure steps, tighten the trigger description).
                    Output format: one suggestion per line as "1. ..." "2. ..." "3. ...".
                    """,
                    user: """
                    Current SKILL.md:
                    \(String(skillMD.prefix(3000)))

                    Real-world usage feedback:
                    \(feedback.isEmpty ? "(no failures recorded — suggest general improvements)" : feedback)
                    """
                )
                suggestions = items.prefix(3).map { String($0.prefix(120)) }
            } catch {
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
        }
    }

    private func startRewrite() {
        guard !isRunning, hub.spaceStore.current == space else { return }
        isRunning = true
        appendLog(L.string("skills.create.ai.log.analyze"))
        runTask = Task {
            do {
                guard let provider = try await hub.makeActiveProvider(for: space, source: "skill-design") else {
                    throw LLMError.providerUnavailable
                }
                try Task.checkCancellation()
                guard hub.spaceStore.current == space else { throw CancellationError() }
                guard let store = hub.makeSkillStore(for: space), let scriptSpace = store.space, scriptSpace == space else {
                    throw LLMError.configurationError(reason: "Skill store unavailable")
                }
                // 现有技能上下文：SKILL.md + 文件清单
                let currentSKILLMD = try store.readFile(name: skillName, relativePath: "SKILL.md")
                let fileList = (try? store.files(for: skillName)) ?? []

                var knowledgeContext: String?
                if useKnowledge {
                    appendLog(L.string("skills.create.ai.log.knowledge"))
                    let query = instruction.isEmpty ? skillName : instruction
                    let (context, hitCount) = await SkillAICreateSheet.retrieveKnowledge(hub: hub, space: space, query: query)
                    knowledgeContext = context
                    appendLog(hitCount > 0
                        ? L.format("skills.create.ai.log.knowledge.hit", hitCount)
                        : L.string("skills.create.ai.log.knowledge.empty"))
                }

                // 真实使用反馈：skill_load / 脚本运行成败记录（失败详情是改进的最硬依据）
                var usageFeedback: String?
                if useUsageFeedback {
                    appendLog(L.string("skills.create.ai.log.usage"))
                    let log = SkillUsageLog(skillsDirectoryURL: store.skillsDirectoryURL)
                    let entries = log.entries(for: skillName)
                    usageFeedback = log.feedbackSummary(for: skillName)
                    appendLog(entries.isEmpty
                        ? L.string("skills.create.ai.log.usage.empty")
                        : L.format("skills.create.ai.log.usage.hit", entries.count))
                }

                // 深度思考：基于现有技能 + 改进说明流式推理
                let generator = SkillGenerator(provider: provider)
                appendLog(L.string("skills.create.ai.log.thinking"))
                let thinkRequirement = """
                Rewrite the existing skill "\(skillName)".
                Improvement instruction: \(instruction.isEmpty ? "(general refinement)" : instruction)
                Current SKILL.md:
                \(currentSKILLMD)
                """
                _ = try await generator.think(
                    requirement: thinkRequirement,
                    knowledgeContext: knowledgeContext
                ) { delta in
                    Task { @MainActor in thinkingText += delta }
                }
                appendLog(L.string("skills.create.ai.log.thinking.done"))
                appendLog(L.string("skills.create.ai.log.generating"))

                var package = try await generator.rewrite(
                    skillName: skillName,
                    currentSKILLMD: currentSKILLMD,
                    fileList: fileList,
                    instruction: instruction,
                    knowledgeContext: knowledgeContext,
                    usageFeedback: usageFeedback
                ) { delta in
                    Task { @MainActor in generatingText += delta }
                }

                // 深度模式：自我审查修订（失败回退初稿，不阻断）
                if deepMode {
                    // 审查输出重新流式展示
                    generatingText = ""
                    package = await SkillAICreateSheet.reviewPackage(
                        package,
                        generator: generator,
                        requirement: thinkRequirement,
                        thinking: thinkingText.isEmpty ? nil : thinkingText,
                        log: { line in appendLog(line) },
                        onDelta: { delta in
                            Task { @MainActor in generatingText += delta }
                        }
                    )
                }
                // 脚本验证闭环：py_compile 语法校验 + 冒烟真实执行 + 失败回喂修复
                let verified = await SkillAICreateSheet.validateAndFixScripts(
                    package,
                    space: scriptSpace,
                    generator: generator,
                    log: { line in appendLog(line) }
                )
                package = verified.package
                // 静态校验 + 自动修正（allowed-tools 合法性 / 引用文件指针）
                let validated = SkillGenerator.validatePackage(package)
                package = validated.package
                for warning in validated.warnings {
                    appendLog(warning)
                }

                appendLog(L.string("skills.create.ai.log.write"))
                try SkillGenerationWriteGate.perform(
                    originSpace: space,
                    currentSpace: { hub.spaceStore.current }
                ) {
                    try applyPackage(package, into: store)
                    // 脚本两轮修复仍失败 → 就地禁用，避免坏技能被调度
                    if verified.hasUnrepairedScripts {
                        try? store.setEnabled(name: skillName, enabled: false)
                        appendLog(L.format("skills.create.ai.log.repair_disabled", skillName))
                    }
                }
                appendLog(L.string("skills.rewrite.log.applied"))
                onApplied()
                dismiss()
            } catch is CancellationError {
                isRunning = false
            } catch {
                isRunning = false
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
        }
    }

    /// 就地覆盖：SKILL.md + 脚本；保留启用状态与其他资源文件。
    /// 先组装完整新包再原子替换；覆盖前自动快照旧版本到 versions/（编辑器「历史版本」可回滚）。
    /// 运行验证不在重写流程中发生。
    private func applyPackage(_ package: GeneratedSkillPackage, into store: SkillStore) throws {
        var skill = package.skill
        skill.name = skillName
        // 保留原启用状态（installPackage 会按 isEnabled 同步停用标记）
        if let original = try store.list().first(where: { $0.name == skillName }) {
            skill.isEnabled = original.isEnabled
        }
        try store.installPackage(
            skill,
            scripts: package.scripts.map { ($0.path, $0.content) },
            references: package.references.map { ($0.path, $0.content) },
            overwrite: true,
            preserveExistingResources: true
        )
        store.saveValidationRecord(
            SkillValidationRecord(
                outcome: package.scripts.isEmpty ? .unverified : .syntaxPassed,
                scripts: package.scripts.map {
                    SkillScriptValidation(path: $0.path, outcome: .syntaxPassed, message: "Syntax OK (not executed).")
                },
                executed: false,
                detail: "Skill rewritten; runtime smoke test has not run."
            ),
            name: skillName
        )
        HubLogger.shared.info("AI skill rewrite completed")
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
    }
}
