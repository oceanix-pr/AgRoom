import SwiftUI
import AgRoomCore

// MARK: - Skill Editor

/// 技能包编辑器：左侧文件树 + 右侧文本编辑器，
/// 技能文件夹内所有文件（SKILL.md / examples/ / references/ / scripts/ …）均可在此直接编辑保存。
/// skillName 为 nil 时显示占位（三栏结构常驻，避免选/不选技能时列数变化导致宽度跳动）
struct SkillEditorView: View {
    let hub: Hub
    let skillName: String?
    let onSkillChanged: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var store: SkillStore?
    @State private var files: [String] = []
    @State private var selectedPath: String = "SKILL.md"
    @State private var content: String = ""
    @State private var savedContent: String = ""
    @State private var isBinary = false
    @State private var newFileName = ""
    @State private var showingNewFile = false
    @State private var filePendingDeletion: String?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    /// 脏状态保护：切换文件前弹三选一（保存/放弃/取消）
    @State private var pendingPathAfterDirty: String?
    /// 编辑器实际已加载的文件路径（脏状态时用于回滚 List 选中态）
    @State private var loadedPath = "SKILL.md"
    /// SKILL.md 编辑/预览切换（预览复用对话页 MarkdownView）
    @State private var previewMode = false
    /// AI 重写技能 sheet
    @State private var showingRewrite = false
    /// 版本历史 sheet（versions/ 快照列表 + 回滚）
    @State private var showingVersions = false
    /// AI 润色当前文件 sheet
    @State private var showingPolish = false
    /// 文件树栏显示宽度：拖动期间只改这里，拖动结束才写偏好。
    /// 依据与崩溃栈见 `SplitColumnWidth`：布局回调里写观察态会让窗口 abort。
    @State private var treeWidth: Double
    private static let treeWidthKey = "agroom.skills.treeWidth"
    /// 当前技能的工作区（SKILL.md frontmatter workspace-folder；nil = 默认工作区）
    @State private var currentWorkspace: String?
    /// 工作区候选：files 根下的文件夹相对路径（打开时加载一次）
    @State private var workspaceFolderPaths: [String] = []
    /// 当前空间登记的工作区（与对话工作区同一套，选择器与显示名共用）
    @State private var workspaces: [ChatWorkspace] = []
    /// 保存验证状态：语法通过 ≠ 运行通过；超时/跳过不能显示为通过
    @State private var validation = SkillValidationRecord.unverified
    @State private var isValidating = false
    @State private var showingRuntimeValidationConfirmation = false

    private let fileAreaService = FileAreaService.standard

    init(hub: Hub, skillName: String?, onSkillChanged: @escaping () -> Void) {
        self.hub = hub
        self.skillName = skillName
        self.onSkillChanged = onSkillChanged
        self._treeWidth = State(
            initialValue: SplitColumnWidth.snapshot(
                key: Self.treeWidthKey, defaultValue: 240, range: 160...360
            )
        )
    }

    private var markdownSourceContext: MarkdownSourceContext {
        guard let store, let space = store.space, let skillName,
              let folder = try? store.folderURL(for: skillName) else { return MarkdownSourceContext() }
        let base = folder.appendingPathComponent(loadedPath).deletingLastPathComponent()
        return .scoped(to: space, baseURL: base, additionalRoots: [folder])
    }

    private var isDirty: Bool { !isBinary && content != savedContent }
    private var isSkillMD: Bool { selectedPath == "SKILL.md" }
    private var hasSkill: Bool { skillName != nil }

    /// 工作区显示名：登记工作区用其展示名；files 根内显示相对路径；否则原样。
    /// 目录已不存在时追加「失效」标记，避免解析失败后静默回退而无提示
    private var workspaceDisplay: String {
        guard let workspace = currentWorkspace else { return L.string("skills.workspace.none") }
        let exists = FileManager.default.fileExists(atPath: workspace)
        let invalidSuffix = exists ? "" : " · \(L.string("workspace.invalid"))"

        if let match = workspaces.first(where: { $0.path == workspace }) {
            let name = match.isDefault ? L.string("workspace.default.name") : match.name
            return name + invalidSuffix
        }
        let root = fileAreaService.filesRoot.path
        if workspace == root {
            return URL(fileURLWithPath: root).lastPathComponent + invalidSuffix
        }
        if workspace.hasPrefix(root + "/") {
            return String(workspace.dropFirst(root.count + 1)) + invalidSuffix
        }
        return workspace + invalidSuffix
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // 空间不足时只压缩显示，拖动结束才写偏好
            GeometryReader { geo in
                let layout = SplitWidths.resolve(
                    available: Double(geo.size.width),
                    dividers: 1,
                    columns: [
                        SplitWidths.Column(width: treeWidth, range: 160...360),
                        SplitWidths.Column(width: 0, range: 320...(.infinity), flexible: true)
                    ]
                )
                HStack(spacing: 0) {
                    fileTree
                        .frame(width: CGFloat(layout[0]))

                    SplitDivider(
                        columnWidth: $treeWidth,
                        range: 160...360,
                        persistKey: Self.treeWidthKey,
                        direction: 1
                    )

                    editorPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            store = hub.makeSkillStore()
            workspaceFolderPaths = fileAreaService.folderPathsUnderFilesRoot()
            workspaces = WorkspaceRegistry.shared.workspaces(for: hub.spaceStore.current)
            guard hasSkill else { return }
            reloadFiles(selecting: "SKILL.md")
            reloadValidation()
        }
        // AI 重写技能（基于现有内容重新生成，就地覆盖 SKILL.md 与脚本）
        .sheet(isPresented: $showingRewrite) {
            if let skillName {
                SkillRewriteSheet(hub: hub, skillName: skillName) {
                    reloadFiles(selecting: "SKILL.md")
                    onSkillChanged()
                }
            }
        }
        // 版本历史：versions/ 快照列表 + 回滚（重写/导入/回滚前自动快照）
        .sheet(isPresented: $showingVersions) {
            if let skillName {
                SkillVersionsSheet(hub: hub, skillName: skillName) {
                    reloadFiles(selecting: "SKILL.md")
                    onSkillChanged()
                }
            }
        }
        // AI 润色当前文件（先快照，润色结果直接落盘并刷新编辑器）
        .sheet(isPresented: $showingPolish) {
            if let skillName {
                SkillPolishSheet(
                    hub: hub,
                    skillName: skillName,
                    path: selectedPath,
                    content: content
                ) {
                    reloadFiles(selecting: selectedPath)
                    onSkillChanged()
                }
            }
        }
        // 回到应用时刷新文件树（有未保存修改时不打扰）
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, hasSkill, !isDirty else { return }
            reloadFiles(selecting: selectedPath)
        }
        // 隐藏按钮承载 ⌘S 保存
        .background(
            Button("") { saveCurrentFile() }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        // 脏状态保护：切换文件前确认（保存/放弃修改/取消切换）
        .confirmationDialog(
            L.string("skills.editor.dirty.title"),
            isPresented: Binding(
                get: { pendingPathAfterDirty != nil },
                set: { if !$0 { pendingPathAfterDirty = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("skills.editor.dirty.save")) {
                saveCurrentFile()
                proceedPendingSwitch()
            }
            Button(L.string("skills.editor.dirty.discard"), role: .destructive) {
                proceedPendingSwitch()
            }
            Button(L.string("common.cancel"), role: .cancel) {
                pendingPathAfterDirty = nil
            }
        } message: {
            Text(L.format("skills.editor.dirty.message", selectedPath))
        }
        // 新建文件
        .alert(L.string("skills.editor.new_file"), isPresented: $showingNewFile) {
            TextField(L.string("skills.editor.new_file.placeholder"), text: $newFileName)
            Button(L.string("common.ok")) { createFile() }
                .disabled(newFileName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.string("skills.editor.new_file.help"))
        }
        // 删除文件确认（SKILL.md 不可删）
        .confirmationDialog(
            L.string("chat.delete_confirm.title"),
            isPresented: Binding(
                get: { filePendingDeletion != nil },
                set: { if !$0 { filePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("common.delete"), role: .destructive) {
                if let path = filePendingDeletion { deleteFile(path) }
                filePendingDeletion = nil
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            if let path = filePendingDeletion {
                Text(L.format("skills.editor.delete_file.message", path))
            }
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        // 运行验证是独立执行步骤：必须由用户明确确认，不会随保存自动发生。
        .confirmationDialog(
            L.string("skills.validation.run.confirm.title"),
            isPresented: $showingRuntimeValidationConfirmation,
            titleVisibility: .visible
        ) {
            Button(L.string("skills.validation.run.confirm.action"), role: .destructive) {
                runRuntimeValidation()
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.string("skills.validation.run.confirm.message"))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(MeetStatusColor.textual)
            Text(skillName ?? L.string("skills.editor.none"))
                .font(MeetTypography.sectionTitle)
                .foregroundStyle(hasSkill ? .primary : .secondary)
            if hasSkill {
                StatusBadge(text: "SKILL.md", color: MeetStatusColor.textual)
                // 工作区选择：指定文件夹后技能写类文件工具受限其中（frontmatter workspace-folder）
                workspaceMenu
                validationBadge
            }
            Spacer()
            if isDirty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                    Text(L.string("skills.editor.unsaved"))
                        .font(MeetTypography.secondary)
                        .foregroundStyle(.tertiary)
                }
            }
            if hasSkill {
                // 保存前检查只编译；运行验证必须走独立确认，结果不混用。
                Button {
                    runSyntaxValidation()
                } label: {
                    Label(L.string("skills.validation.check_syntax"), systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .disabled(isValidating || scriptPaths.isEmpty)
                .help(L.string("skills.validation.check_syntax.hint"))
                Button {
                    showingRuntimeValidationConfirmation = true
                } label: {
                    Label(L.string("skills.validation.run"), systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
                .disabled(isValidating || scriptPaths.isEmpty || isDirty)
                .help(isDirty
                    ? L.string("skills.validation.save_first")
                    : L.string("skills.validation.run.hint"))
                // 历史版本：versions/ 快照列表 + 回滚（AI 重写/导入覆盖前自动备份）
                Button(action: { showingVersions = true }) {
                    Label(L.string("skills.editor.versions"), systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .help(L.string("skills.editor.versions.hint"))
                // AI 重写：基于现有技能内容 + 改进说明重新生成（脏状态下禁用，防丢未保存修改）
                Button(action: { showingRewrite = true }) {
                    Label(L.string("skills.rewrite.action.short"), systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(isDirty)
                .help(isDirty ? L.string("skills.rewrite.dirty_hint") : L.string("skills.rewrite.hint"))
            }
            Button(L.string("common.save")) { saveCurrentFile() }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // 标题栏统一高度（与技能列表头一致）
        .columnHeader()
    }

    // MARK: - Validation

    private var scriptPaths: [String] {
        files.filter { $0.hasSuffix(".py") }
    }

    private var validationBadge: some View {
        let label: String
        let color: Color
        switch validation.outcome {
        case .unverified:
            label = L.string("skills.validation.unverified")
            color = .secondary
        case .syntaxPassed:
            label = L.string("skills.validation.syntax_passed")
            color = MeetStatusColor.resource
        case .runtimePassed:
            label = L.string("skills.validation.runtime_passed")
            color = MeetStatusColor.positive
        case .failed:
            label = L.string("skills.validation.failed")
            color = MeetStatusColor.negative
        case .timedOut:
            label = L.string("skills.validation.timed_out")
            color = MeetStatusColor.negative
        case .runtimeUnavailable:
            label = L.string("skills.validation.runtime_unavailable")
            color = MeetStatusColor.resource
        }
        return StatusBadge(text: label, color: color)
            .help(validation.detail.isEmpty ? label : validation.detail)
    }

    private func reloadValidation() {
        guard let store, let skillName else {
            validation = .unverified
            return
        }
        validation = store.validationRecord(name: skillName)
    }

    private func runSyntaxValidation() {
        guard let store, let skillName, !isValidating else { return }
        isValidating = true
        Task {
            // 与运行期一致：使用本技能库所属空间的环境，运行验证才能看到已安装的依赖
            let executor = PythonExecutor(space: store.space, workspaceName: "skill-validation")
            let service = SkillValidationService(store: store, executor: executor)
            let record = await service.syntaxCheck(name: skillName)
            await MainActor.run {
                validation = record
                isValidating = false
            }
        }
    }

    /// 显式运行验证：用户确认后逐个脚本真实执行；任一失败/超时都记录为失败状态。
    /// 该入口本身就是用户对 `.codeExecution` 的明确授权，不会由保存或生成自动触发。
    private func runRuntimeValidation() {
        guard let store, let skillName, !isValidating, !scriptPaths.isEmpty else { return }
        isValidating = true
        let paths = scriptPaths
        Task {
            let executor = PythonExecutor(space: store.space, workspaceName: "skill-validation")
            let service = SkillValidationService(store: store, executor: executor)
            var last: SkillValidationRecord = .unverified
            for path in paths {
                last = await service.smokeTest(name: skillName, relativePath: path)
                if last.outcome == .failed || last.outcome == .timedOut { break }
            }
            await MainActor.run {
                validation = last
                isValidating = false
            }
        }
    }

    // MARK: - Workspace Picker（技能工作区）

    /// 工作区菜单：默认工作区（清除声明）+ 本空间登记的工作区 + files 根下文件夹清单；
    /// 写入 SKILL.md frontmatter workspace-folder（脏状态下禁用，防丢未保存修改）
    private var workspaceMenu: some View {
        Menu {
            Button {
                setWorkspace(nil)
            } label: {
                Label(L.string("skills.workspace.none"), systemImage: "tray")
            }
            if !workspaces.isEmpty {
                Divider()
                ForEach(workspaces) { workspace in
                    Button(workspace.isDefault ? L.string("workspace.default.name") : workspace.name) {
                        setWorkspace(workspace.path)
                    }
                }
            }
            if !workspaceFolderPaths.isEmpty {
                Divider()
                ForEach(workspaceFolderPaths, id: \.self) { relative in
                    Button(relative) {
                        setWorkspace(fileAreaService.filesRoot.appendingPathComponent(relative).path)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "archivebox")
                    .font(MeetTypography.secondary)
                Text(workspaceDisplay)
                    .font(MeetTypography.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isDirty)
        .help(isDirty ? L.string("skills.workspace.dirty_hint") : L.string("skills.workspace.hint"))
    }

    /// 读取当前 SKILL.md 的工作区声明（frontmatter workspace-folder）
    private func loadWorkspaceValue() {
        guard let store, let skillName,
              let text = try? store.readFile(name: skillName, relativePath: "SKILL.md"),
              let skill = try? SkillDocument.parse(text) else {
            currentWorkspace = nil
            return
        }
        currentWorkspace = skill.workspaceFolder
    }

    /// 更新工作区：磁盘 SKILL.md 解析 → 改 workspace-folder → 重渲染写回 → 刷新编辑器
    private func setWorkspace(_ folder: String?) {
        guard let store, let skillName, !isDirty,
              let text = try? store.readFile(name: skillName, relativePath: "SKILL.md"),
              var skill = try? SkillDocument.parse(text) else { return }
        skill.workspaceFolder = folder
        do {
            try store.writeFile(
                name: skillName,
                relativePath: "SKILL.md",
                content: SkillDocument.render(skill)
            )
            currentWorkspace = folder
            reloadFiles(selecting: "SKILL.md")
            onSkillChanged()
        } catch {
            errorMessage = L.errorDescription(error)
            showErrorAlert = true
        }
    }

    // MARK: - File Tree

    /// 按顶层目录分组的文件路径：{"": [根文件], "scripts": [...], "references": [...]}
    private var groupedFiles: [(directory: String, paths: [String])] {
        var groups: [String: [String]] = [:]
        for path in files {
            let dir = path.contains("/")
                ? String(path[..<path.firstIndex(of: "/")!])
                : ""
            groups[dir, default: []].append(path)
        }
        // SKILL.md 之外的根文件归入 "" 组；目录按名称排序，根文件组最后
        return groups
            .sorted { lhs, rhs in
                if lhs.key.isEmpty { return false }
                if rhs.key.isEmpty { return true }
                return lhs.key < rhs.key
            }
            .map { (directory: $0.key, paths: $0.value.sorted()) }
    }

    @ViewBuilder
    private var fileTree: some View {
        if hasSkill {
            List(selection: $selectedPath) {
                // SKILL.md 永远置顶
                Section {
                    fileRow("SKILL.md", isSkillMD: true)
                        .tag("SKILL.md")
                }
                ForEach(groupedFiles, id: \.directory) { group in
                    Section(group.directory.isEmpty ? " " : group.directory) {
                        ForEach(group.paths, id: \.self) { path in
                            fileRow(path, isSkillMD: false)
                                .tag(path)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // 会话页风格：白底（隐藏 sidebar 材质背景）
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: selectedPath) { _, newPath in
                requestSwitch(to: newPath)
            }
        } else {
            // 未选技能：占位（列结构常驻，宽度约束与有技能时一致）
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(MeetTypography.pageTitle)
                    .foregroundStyle(.tertiary)
                Text(L.string("skills.editor.tree.placeholder"))
                    .font(MeetTypography.secondary)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func displayName(for path: String, isSkillMD: Bool) -> String {
        if isSkillMD { return "SKILL.md" }
        guard let slash = path.firstIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private func fileRow(_ path: String, isSkillMD: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isSkillMD ? "doc.badge.gearshape" : iconName(for: path))
                .font(MeetTypography.secondary)
                .foregroundStyle(.secondary)
            Text(displayName(for: path, isSkillMD: isSkillMD))
                .font(MeetTypography.secondary.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !isSkillMD {
                Button(action: { filePendingDeletion = path }) {
                    Image(systemName: "trash")
                        .font(MeetTypography.secondary)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
    }

    private func iconName(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "txt": return "doc.text"
        case "sh", "bash", "zsh": return "terminal"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "csv": return "tablecells"
        default: return "doc"
        }
    }

    // MARK: - Editor Pane

    @ViewBuilder
    private var editorPane: some View {
        if !hasSkill {
            // 未选技能：占位（三栏常驻，编辑列结构不消失）
            ContentUnavailableView {
                Label(L.string("skills.editor.placeholder"), systemImage: "wand.and.stars")
            } description: {
                Text(L.string("skills.editor.placeholder.desc"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            editorPaneContent
        }
    }

    private var editorPaneContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(selectedPath)
                    .font(MeetTypography.secondary.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                // SKILL.md 专属：编辑/预览切换（预览复用对话页 Markdown 渲染）
                if isSkillMD && !isBinary {
                    Button(action: { previewMode.toggle() }) {
                        Label(
                            previewMode
                                ? L.string("skills.editor.edit_mode")
                                : L.string("skills.editor.preview"),
                            systemImage: previewMode ? "pencil" : "eye"
                        )
                        .font(MeetTypography.secondary)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDirty)
                    .help(isDirty ? L.string("skills.editor.preview.dirty") : "")
                }
                Button(action: { showingNewFile = true; newFileName = "" }) {
                    Label(L.string("skills.editor.new_file"), systemImage: "doc.badge.plus")
                        .font(MeetTypography.secondary)
                }
                .buttonStyle(.bordered)
                // AI 润色当前文件（二进制/超限文件不可用；脏状态下禁用，防覆盖未保存修改）
                Button(action: { showingPolish = true }) {
                    Label(L.string("skills.editor.polish"), systemImage: "wand.and.stars")
                        .font(MeetTypography.secondary)
                }
                .buttonStyle(.bordered)
                .disabled(isDirty || isBinary || previewMode)
                .help(isDirty ? L.string("skills.rewrite.dirty_hint") : L.string("skills.editor.polish.hint"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if isBinary {
                ContentUnavailableView(
                    L.string("skills.editor.binary"),
                    systemImage: "doc.zipper",
                    description: Text(L.string("skills.editor.binary.desc"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isSkillMD && previewMode {
                // SKILL.md 预览：与对话页一致的 Markdown 渲染（含 frontmatter 剥离）
                ScrollView {
                    MarkdownView(text: content, documentID: (skillName ?? "") + "/" + loadedPath, strippingFrontmatter: true, sourceContext: markdownSourceContext)
                        .padding(12)
                }
            } else {
                TextEditor(text: $content)
                    .font(MeetTypography.secondary.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
            }
        }
        // 切换文件退出预览态
        .onChange(of: loadedPath) { _, _ in
            previewMode = false
        }
    }

    /// SKILL.md 预览用：剥离 frontmatter（--- ... ---），只渲染正文
    static func bodyMarkdown(from text: String) -> String {
        MarkdownParser.bodyWithoutFrontmatter(text)
    }

    // MARK: - Actions

    /// 切换文件前路由：有未保存修改先弹三选一，否则直接加载
    private func requestSwitch(to path: String) {
        guard isDirty, path != loadedPath else {
            loadedPath = path
            loadFile(path)
            return
        }
        // 脏状态：回滚 List 选中到当前已加载文件，确认后再真正切换
        pendingPathAfterDirty = path
        selectedPath = loadedPath
    }

    /// 确认后执行挂起的切换（保存/放弃两条路径共用）
    private func proceedPendingSwitch() {
        guard let path = pendingPathAfterDirty else { return }
        pendingPathAfterDirty = nil
        loadedPath = path
        selectedPath = path
        loadFile(path)
    }

    private func reloadFiles(selecting path: String) {
        guard let skillName else { return }
        files = (try? store?.files(for: skillName)) ?? []
        selectedPath = path
        loadedPath = path
        loadFile(path)
        loadWorkspaceValue()
        reloadValidation()
    }

    private func loadFile(_ path: String) {
        guard let store, let skillName else { return }
        isBinary = false
        // 超过读取上限的文件禁止编辑（防止保存时静默截断丢数据）
        if let url = try? store.folderURL(for: skillName).appendingPathComponent(path),
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 200_000 {
            content = ""
            savedContent = ""
            isBinary = true
            return
        }
        do {
            let text = try store.readFile(name: skillName, relativePath: path)
            content = text
            savedContent = text
        } catch {
            // 非 UTF-8 可解码文件按二进制处理（只读提示）
            content = ""
            savedContent = ""
            isBinary = true
        }
    }

    private func saveCurrentFile() {
        guard let store, let skillName, !isBinary, isDirty else { return }
        // SKILL.md 保存前校验 frontmatter，防止写坏整个技能
        if selectedPath == "SKILL.md" {
            do {
                _ = try SkillDocument.parse(content)
            } catch {
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
                return
            }
        }
        do {
            try store.writeFile(name: skillName, relativePath: selectedPath, content: content)
            savedContent = content
            // 内容变化后旧验证结论不再可信；运行验证必须重新执行。
            if selectedPath == "SKILL.md" || selectedPath.hasSuffix(".py") {
                store.saveValidationRecord(
                    SkillValidationRecord(
                        outcome: .unverified,
                        detail: "The skill changed; run syntax and runtime checks again."
                    ),
                    name: skillName
                )
                reloadValidation()
            }
            onSkillChanged()
        } catch {
            errorMessage = L.errorDescription(error)
            showErrorAlert = true
        }
    }

    private func createFile() {
        let path = newFileName.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, let store, let skillName else { return }
        do {
            try store.writeFile(name: skillName, relativePath: path, content: "")
            reloadFiles(selecting: path)
            onSkillChanged()
        } catch {
            errorMessage = L.errorDescription(error)
            showErrorAlert = true
        }
    }

    private func deleteFile(_ path: String) {
        guard let store, let skillName else { return }
        do {
            try store.deleteFile(name: skillName, relativePath: path)
            reloadFiles(selecting: "SKILL.md")
            onSkillChanged()
        } catch {
            errorMessage = L.errorDescription(error)
            showErrorAlert = true
        }
    }
}

// MARK: - Skill Versions Sheet

/// 版本历史：列出 versions/ 快照（新→旧），点击回滚。
/// 回滚前自动快照当前状态（保底可撤销），编辑器随之刷新
struct SkillVersionsSheet: View {
    let hub: Hub
    let skillName: String
    /// 回滚完成回调（编辑器重新加载文件树与内容）
    let onRolledBack: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var versions: [SkillStore.SkillVersion] = []
    @State private var pendingRollback: SkillStore.SkillVersion?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    var body: some View {
        VStack(spacing: 0) {
            Text(L.string("skills.editor.versions"))
                .font(MeetTypography.pageTitle)
                .fontWeight(.bold)
                .padding(.top, 16)
                .padding(.bottom, 4)
            Text(L.string("skills.editor.versions.hint"))
                .font(MeetTypography.secondary)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            if versions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(MeetTypography.pageTitle)
                        .foregroundStyle(.tertiary)
                    Text(L.string("skills.editor.versions.empty"))
                        .font(MeetTypography.secondary)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(versions) { version in
                        HStack {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppDate.string(from: version.date))
                                    .font(MeetTypography.secondary.monospaced())
                                Text(version.id)
                                    .font(MeetTypography.secondary)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button(action: { pendingRollback = version }) {
                                Label(L.string("skills.editor.versions.rollback"), systemImage: "arrow.uturn.backward")
                                    .font(MeetTypography.secondary)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: .infinity)
            }

            Divider()
                .padding(.top, 12)
            HStack {
                Spacer()
                Button(L.string("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 440)
        .onAppear(perform: load)
        .confirmationDialog(
            L.string("skills.editor.versions.rollback"),
            isPresented: Binding(
                get: { pendingRollback != nil },
                set: { if !$0 { pendingRollback = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("skills.editor.versions.rollback"), role: .destructive) {
                if let version = pendingRollback { rollback(version) }
                pendingRollback = nil
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            if let version = pendingRollback {
                Text(L.format(
                    "skills.editor.versions.rollback.message",
                    AppDate.string(from: version.date)
                ))
            }
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() {
        versions = (try? hub.makeSkillStore()?.listVersions(name: skillName)) ?? []
    }

    private func rollback(_ version: SkillStore.SkillVersion) {
        do {
            try hub.makeSkillStore()?.rollback(name: skillName, versionId: version.id)
            load()
            onRolledBack()
        } catch {
            errorMessage = SkillsView.describe(error)
            showErrorAlert = true
        }
    }
}

// MARK: - Skill Polish Sheet

/// AI 润色单个文件：以当前文件全文 + 改进说明调用 SkillGenerator.polishFile，
/// 结果直接落盘（覆盖前自动快照到 versions/），编辑器随之刷新
struct SkillPolishSheet: View {
    let hub: Hub
    let space: AppSpace
    let skillName: String
    /// 当前打开的文件（编辑器已保存版本；脏状态被入口禁用）
    let path: String
    let content: String
    /// 应用完成回调（编辑器重新加载文件）
    let onApplied: () -> Void

    init(hub: Hub, skillName: String, path: String, content: String, onApplied: @escaping () -> Void) {
        self.hub = hub
        self.space = hub.spaceStore.current
        self.skillName = skillName
        self.path = path
        self.content = content
        self.onApplied = onApplied
    }

    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    var body: some View {
        VStack(spacing: 0) {
            Text(L.string("skills.editor.polish"))
                .font(MeetTypography.pageTitle)
                .fontWeight(.bold)
                .padding(.top, 16)
                .padding(.bottom, 4)
            Text(L.format("skills.editor.polish.hint.file", path))
                .font(MeetTypography.secondary)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            TextEditor(text: $instruction)
                .font(MeetTypography.control)
                .frame(minHeight: 80)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .disabled(isRunning)

            if isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L.string("skills.editor.polish.running"))
                        .font(MeetTypography.secondary)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 10)
            }

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
                Button(action: { startPolish() }) {
                    Label(L.string("skills.editor.polish.apply"), systemImage: "wand.and.stars")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 300, idealHeight: 340)
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

    private func startPolish() {
        guard !isRunning, hub.spaceStore.current == space else { return }
        isRunning = true
        runTask = Task {
            do {
                guard let provider = try await hub.makeActiveProvider(for: space, source: "skill-edit") else {
                    throw LLMError.providerUnavailable
                }
                try Task.checkCancellation()
                guard hub.spaceStore.current == space else { throw CancellationError() }
                guard let store = hub.makeSkillStore(for: space), store.space == space else {
                    throw LLMError.configurationError(reason: "Skill store unavailable")
                }
                let polished = try await SkillGenerator(provider: provider)
                    .polishFile(path: path, content: content, instruction: instruction)
                try Self.applyPolishedContent(
                    polished,
                    to: store,
                    skillName: skillName,
                    path: path,
                    originSpace: space,
                    currentSpace: { hub.spaceStore.current }
                )
                HubLogger.shared.info("AI skill file polish completed")
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

    @MainActor
    static func applyPolishedContent(
        _ polished: String,
        to store: SkillStore,
        skillName: String,
        path: String,
        originSpace: AppSpace,
        currentSpace: () -> AppSpace
    ) throws {
        try SkillGenerationWriteGate.perform(originSpace: originSpace, currentSpace: currentSpace) {
            guard store.space == originSpace else { throw CancellationError() }
            // 快照失败时保留旧内容，不能无版本保护地继续覆盖。
            _ = try store.snapshotVersion(name: skillName)
            try store.writeFile(name: skillName, relativePath: path, content: polished)
        }
    }
}
