import SwiftUI
import AgRoomCore

// MARK: - Files View Model

/// 文件区页视图模型：目录树缓存 + 当前目录内容 + 内部拷贝粘贴板。
/// 读全部走 FileAreaService（受管根校验 + 隐藏标志）；写操作经 UI 触发（用户主权，不受技能工作区限制）
@MainActor
final class FilesViewModel: ObservableObject {

    /// 受管文件区服务：根 = 受管区（`~/Documents/AgRoom`），含登记工作区的追加根
    private(set) var service: FileAreaService
    private let workspaceRoots: () -> [URL]

    /// 当前选中的文件夹（树节点选择；初始为 files 根）
    @Published var selectedFolder: URL
    /// 当前文件夹内容（含隐藏项，展示层按 showHidden 过滤）
    @Published var entries: [FileAreaEntry] = []
    /// A failed directory read must not look like an empty folder.
    @Published var loadError: String?
    /// 显示隐藏项开关（Finder 同款隐藏标志条目）
    @Published var showHidden = false
    /// 树节点展开状态（文件夹路径集合）
    @Published var expandedFolders: Set<String> = []
    /// 文件夹 → 子文件夹列表缓存（树渲染用；写操作后整体失效）
    @Published var childrenCache: [String: [FileAreaEntry]] = [:]
    /// 内部拷贝板：标记的源条目（粘贴 = 拷贝到当前文件夹）
    @Published var copiedURL: URL?
    /// 受管区之外的登记工作区目录：作为树的一级节点展示（否则这些目录不可达）
    @Published var externalWorkspaceEntries: [FileAreaEntry] = []

    init(
        service: FileAreaService = .standard,
        workspaceRoots: @escaping () -> [URL] = { WorkspaceRegistry.shared.allWorkspaceRoots() }
    ) {
        self.service = service
        self.workspaceRoots = workspaceRoots
        self.selectedFolder = service.filesRoot
        do { try service.ensureRoots() }
        catch { loadError = L.actionableError(error, fallbackKey: "error.actionable.files") }
        syncManagedRoots()
        loadEntries()
        loadChildrenIfNeeded(service.filesRoot)
    }

    var currentFolderURL: URL { selectedFolder }

    /// 受管区根（树根）：一级节点为 files / default-chat / workspace / privatespace
    var rootURL: URL { service.baseDirectory }

    /// 把登记工作区纳入可读受管根，并生成受管区之外工作区的树节点。
    /// 文件区是公共可读范围，故这里取全部空间登记的工作区目录
    func syncManagedRoots() {
        let extras = workspaceRoots()
        let updated = FileAreaService(baseDirectory: service.baseDirectory, additionalRoots: extras)
        service = updated
        externalWorkspaceEntries = extras
            .filter {
                !FileAreaService.isInside($0, root: updated.baseDirectory)
                    && FileManager.default.fileExists(atPath: $0.path)
            }
            .map { Self.externalEntry(for: $0) }
    }

    /// 受管区之外的工作区目录 → 树节点条目
    private static func externalEntry(for url: URL) -> FileAreaEntry {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FileAreaEntry(
            url: url,
            isDirectory: true,
            byteSize: nil,
            modifiedAt: attrs?[.modificationDate] as? Date,
            isHidden: false
        )
    }

    /// 当前目录展示条目（隐藏项跟随开关）
    var displayEntries: [FileAreaEntry] {
        entries.filter { showHidden || !$0.isHidden }
    }

    func navigate(to folder: URL) {
        guard folder != selectedFolder else { return }
        selectedFolder = folder
        loadError = nil
        loadEntries()
    }

    func loadEntries() {
        do { entries = try service.entries(at: currentFolderURL.path, includeHidden: true) }
        catch {
            entries = []
            loadError = L.actionableError(error, fallbackKey: "error.actionable.files")
        }
    }

    /// 写操作后统一刷新：失效树缓存 + 重载当前目录；
    /// 选中目录被删/改名时回退到 files 根
    func refresh() {
        loadError = nil
        if !FileManager.default.fileExists(atPath: selectedFolder.path) {
            selectedFolder = service.filesRoot
        }
        childrenCache.removeAll()
        loadChildrenIfNeeded(service.filesRoot)
        loadEntries()
    }

    func loadChildrenIfNeeded(_ folder: URL) {
        let key = folder.path
        guard childrenCache[key] == nil else { return }
        do {
            childrenCache[key] = try service.entries(at: folder.path, includeHidden: true)
                .filter(\.isDirectory)
        } catch {
            loadError = L.actionableError(error, fallbackKey: "error.actionable.files")
        }
    }

    /// 树中显示的子文件夹（隐藏文件夹跟随开关）
    func displaySubfolders(of folder: URL) -> [FileAreaEntry] {
        (childrenCache[folder.path] ?? []).filter { showHidden || !$0.isHidden }
    }

    func toggleExpanded(_ folder: URL) {
        if expandedFolders.contains(folder.path) {
            expandedFolders.remove(folder.path)
        } else {
            expandedFolders.insert(folder.path)
            loadChildrenIfNeeded(folder)
        }
    }
}

// MARK: - Files View

/// 文件管理页：两栏式（左 = 树状文件夹结构，右 = 当前文件夹内容表格）。
/// 根目录 ~/Documents/AgRoom/files；文件与文件夹均支持拷贝/复制/粘贴/删除/重命名（含扩展名）/隐藏/显示。
/// 技能可指定其中文件夹为工作区（技能编辑器配置），调度 Agent 的写类工具受该范围约束
public struct FilesView: View {
    let hub: Hub

    @StateObject private var viewModel = FilesViewModel()
    @Environment(\.globalSearchText) private var searchText

    /// 右栏表格选中条目 ID（单选）
    @State private var selectedEntryID: FileAreaEntry.ID?
    /// 新建文件夹对话框
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    /// 重命名对话框（完整名称，扩展名可改）
    @State private var renameTarget: FileAreaEntry?
    @State private var renameText = ""
    /// 删除确认
    @State private var deleteTarget: FileAreaEntry?
    @State private var errorMessage: String?
    @State private var showError = false
    /// 左栏树显示宽度：拖动期间只改这里，拖动结束才写偏好。
    /// 依据与崩溃栈见 `SplitColumnWidth`：布局回调里写观察态会让窗口 abort。
    @State private var treeWidth: Double
    private static let treeWidthKey = "agroom.files.treeWidth"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var selectedEntry: FileAreaEntry? {
        viewModel.displayEntries.first { $0.id == selectedEntryID }
    }

    public init(hub: Hub) {
        self.hub = hub
        self._treeWidth = State(
            initialValue: SplitColumnWidth.snapshot(
                key: Self.treeWidthKey, defaultValue: 240, range: 180...420
            )
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let loadError = viewModel.loadError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(MeetTypography.control)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L.string("common.retry")) {
                        viewModel.syncManagedRoots()
                        viewModel.refresh()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }
            Divider()
            // 空间不足时只压缩显示，拖动结束才写偏好
            GeometryReader { geo in
                let layout = SplitWidths.resolve(
                    available: Double(geo.size.width),
                    dividers: 1,
                    columns: [
                        SplitWidths.Column(width: treeWidth, range: 180...420),
                        SplitWidths.Column(width: 0, range: 320...(.infinity), flexible: true)
                    ]
                )
                HStack(spacing: 0) {
                    folderTree
                        .frame(width: CGFloat(layout[0]))

                    SplitDivider(
                        columnWidth: $treeWidth,
                        range: 180...420,
                        persistKey: Self.treeWidthKey,
                        direction: 1
                    )

                    contentPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            // 登记工作区可能变动（对话页新增/移出）：先同步受管根再刷新
            viewModel.syncManagedRoots()
            viewModel.refresh()
        }
        // 新建文件夹
        .alert(L.string("files.new_folder.title"), isPresented: $showingNewFolder) {
            TextField(L.string("files.new_folder.placeholder"), text: $newFolderName)
            Button(L.string("common.create")) { createFolder() }
            Button(L.string("common.cancel"), role: .cancel) {}
        }
        // 重命名（完整名称含扩展名，扩展名可修改）
        .alert(
            L.format("files.rename.title", renameTarget?.name ?? ""),
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField(L.string("files.rename.placeholder"), text: $renameText)
            Button(L.string("common.save")) { performRename() }
            Button(L.string("common.cancel"), role: .cancel) { renameTarget = nil }
        }
        // 删除确认（移入系统废纸篓）
        .alert(
            L.format("files.delete.title", deleteTarget?.name ?? ""),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button(L.string("files.delete.confirm"), role: .destructive) { performDelete() }
            Button(L.string("common.cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteWarning)
        }
        .alert(L.string("files.error"), isPresented: $showError) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header（当前路径 + 操作按钮）

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.string("files.managed_area"))
                    .font(MeetTypography.sectionTitle)
                Text(currentPathLabel)
                    .font(MeetTypography.secondary.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .columnHeader()
    }

    /// 路径展示：受管区根显示完整路径，其余以 ~ 缩写
    private var currentPathLabel: String {
        let current = viewModel.currentFolderURL.path
        let base = viewModel.service.baseDirectory.path
        guard current != base else { return base }
        return "~" + current.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "")
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button(action: { showingNewFolder = true; newFolderName = "" }) {
                Label(L.string("files.new_folder"), systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .help(L.string("files.new_folder.hint"))

            Divider().frame(height: 16)

            Button(action: copySelection) {
                Label(L.string("files.copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(selectedEntry == nil)
            .keyboardShortcut("c", modifiers: .command)
            .help(L.string("files.copy.hint"))

            Button(action: pasteIntoCurrent) {
                Label(L.string("files.paste"), systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.copiedURL == nil)
            .keyboardShortcut("v", modifiers: .command)
            .help(pasteHint)

            Button(action: duplicateSelection) {
                Label(L.string("files.duplicate"), systemImage: "plus.square.on.square")
            }
            .buttonStyle(.bordered)
            .disabled(selectedEntry == nil)
            .keyboardShortcut("d", modifiers: .command)
            .help(L.string("files.duplicate.hint"))

            Button(action: beginRename) {
                Label(L.string("files.rename"), systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .disabled(selectedEntry == nil)
            .help(L.string("files.rename.hint"))

            Button(action: toggleHiddenSelection) {
                Label(
                    selectedEntry?.isHidden == true ? L.string("files.show") : L.string("files.hide"),
                    systemImage: selectedEntry?.isHidden == true ? "eye" : "eye.slash"
                )
            }
            .buttonStyle(.bordered)
            .disabled(selectedEntry == nil)
            .help(L.string("files.hide.hint"))

            Button(action: { deleteTarget = selectedEntry }) {
                Label(L.string("files.delete"), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(selectedEntry == nil)
            .keyboardShortcut(.delete, modifiers: [])
            .help(L.string("files.delete.hint"))

            Divider().frame(height: 16)

            Toggle(isOn: $viewModel.showHidden) {
                Label(L.string("files.show_hidden"), systemImage: "eye.trianglebadge.exclamationmark")
            }
            .toggleStyle(.button)
            .help(L.string("files.show_hidden.hint"))

            Button(action: revealInFinder) {
                Label(L.string("files.reveal"), systemImage: "externaldrive")
            }
            .buttonStyle(.bordered)
            .help(L.string("files.reveal.hint"))
        }
    }

    private var pasteHint: String {
        guard let url = viewModel.copiedURL else { return L.string("files.paste.hint_empty") }
        return L.format("files.paste.hint", url.lastPathComponent)
    }

    /// 删除确认文案：目标是登记的工作区目录时额外提示会同时移出工作区列表
    private var deleteWarning: String {
        guard let target = deleteTarget, isRegisteredWorkspace(target.url) else {
            return L.string("files.delete.desc")
        }
        return L.string("files.delete.workspace_desc")
    }

    /// url 是否正是某个登记工作区的根目录
    private func isRegisteredWorkspace(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return WorkspaceRegistry.shared.allWorkspaceRoots().contains {
            $0.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }

    // MARK: - Folder Tree（左栏：树状文件夹结构）

    private var folderTree: some View {
        List(selection: Binding(
            get: { viewModel.selectedFolder as URL? },
            set: { if let folder = $0 { viewModel.navigate(to: folder) } }
        )) {
            FolderTreeRow(
                viewModel: viewModel,
                folder: nil,
                rootName: L.string("files.managed_area"),
                onNewFolderInside: newFolderInside,
                onRename: renameEntry,
                onDelete: { deleteTarget = $0 }
            )
            // 受管区之外的登记工作区目录：作为一级节点展示，否则在树中不可达
            ForEach(viewModel.externalWorkspaceEntries) { entry in
                FolderTreeRow(
                    viewModel: viewModel,
                    folder: entry,
                    rootName: entry.name,
                    isProtectedRoot: true,
                    onNewFolderInside: newFolderInside,
                    onRename: renameEntry,
                    onDelete: { deleteTarget = $0 }
                )
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 在指定文件夹内新建子文件夹（先导航过去再弹输入框）
    private func newFolderInside(_ folder: URL) {
        viewModel.navigate(to: folder)
        newFolderName = ""
        showingNewFolder = true
    }

    // MARK: - Content Pane（右栏：当前文件夹内容表格）

    @ViewBuilder
    private var contentPane: some View {
        let visible = filteredEntries
        if visible.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? L.string("files.empty") : L.string("search.no_match"),
                systemImage: "folder",
                description: Text(L.string("files.empty.desc"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(visible, selection: $selectedEntryID) {
                TableColumn(L.string("files.name")) { entry in
                    nameCell(entry)
                }
                TableColumn(L.string("files.size")) { entry in
                    Text(entry.isDirectory
                         ? "—"
                         : ByteCountFormatter.string(fromByteCount: Int64(entry.byteSize ?? 0), countStyle: .file))
                        .foregroundStyle(.secondary)
                        .font(MeetTypography.secondary)
                }
                TableColumn(L.string("files.modified")) { entry in
                    Text(entry.modifiedAt.map { Self.dateFormatter.string(from: $0) } ?? "")
                        .foregroundStyle(.secondary)
                        .font(MeetTypography.secondary)
                }
            }
            .contextMenu(forSelectionType: FileAreaEntry.ID.self) { ids in
                let entry = visible.first { $0.id == ids.first }
                entryContextMenu(for: entry)
            } primaryAction: { ids in
                if let entry = visible.first(where: { $0.id == ids.first }) {
                    openEntry(entry)
                }
            }
        }
    }

    /// 工具栏搜索过滤：文件名/文件夹名命中（大小写不敏感）
    private var filteredEntries: [FileAreaEntry] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return viewModel.displayEntries }
        return viewModel.displayEntries.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
        }
    }

    private func nameCell(_ entry: FileAreaEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.blue : .secondary)
            Text(entry.name)
                .font(MeetTypography.listTitle)
                .foregroundStyle(entry.isHidden ? .secondary : .primary)
                .lineLimit(1)
            if entry.isHidden {
                StatusBadge(text: L.string("files.hidden"), color: .secondary)
            }
        }
    }

    @ViewBuilder
    private func entryContextMenu(for entry: FileAreaEntry?) -> some View {
        if let entry {
            Button(L.string("files.open")) { openEntry(entry) }
            Divider()
            Button(L.string("files.copy")) { copyEntry(entry) }
            Button(L.string("files.duplicate")) { duplicateEntry(entry) }
            Divider()
            Button(L.string("files.rename")) { renameEntry(entry) }
            Button(entry.isHidden ? L.string("files.show") : L.string("files.hide")) {
                toggleHidden(entry)
            }
            Divider()
            Button(L.string("files.reveal")) { revealEntryInFinder(entry) }
            Button(L.string("files.delete"), role: .destructive) { deleteTarget = entry }
        } else {
            Button(L.string("files.new_folder")) { showingNewFolder = true; newFolderName = "" }
            Button(L.string("files.paste")) { pasteIntoCurrent() }
                .disabled(viewModel.copiedURL == nil)
        }
    }

    // MARK: - Actions

    /// 打开条目：文件夹在左侧树定位并进入；文件用系统默认应用打开
    private func openEntry(_ entry: FileAreaEntry) {
        if entry.isDirectory {
            viewModel.navigate(to: entry.url)
            selectedEntryID = nil
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    private func copySelection() {
        guard let entry = selectedEntry else { return }
        copyEntry(entry)
    }

    private func copyEntry(_ entry: FileAreaEntry) {
        viewModel.copiedURL = entry.url
    }

    private func pasteIntoCurrent() {
        guard let source = viewModel.copiedURL else { return }
        do {
            _ = try viewModel.service.copyItem(
                from: source.path,
                toDirectory: viewModel.currentFolderURL.path
            )
            viewModel.refresh()
        } catch {
            showFailure(error)
        }
    }

    private func duplicateSelection() {
        guard let entry = selectedEntry else { return }
        duplicateEntry(entry)
    }

    private func duplicateEntry(_ entry: FileAreaEntry) {
        do {
            _ = try viewModel.service.copyItem(
                from: entry.url.path,
                toDirectory: entry.url.deletingLastPathComponent().path
            )
            viewModel.refresh()
        } catch {
            showFailure(error)
        }
    }

    private func beginRename() {
        guard let entry = selectedEntry else { return }
        renameEntry(entry)
    }

    private func renameEntry(_ entry: FileAreaEntry) {
        renameText = entry.name
        renameTarget = entry
    }

    private func performRename() {
        guard let entry = renameTarget else { return }
        renameTarget = nil
        do {
            let renamed = try viewModel.service.rename(at: entry.url.path, to: renameText)
            // 工作区目录改名后同步登记路径，避免会话仍指向失效目录
            WorkspaceRegistry.shared.relocate(from: entry.url.path, to: renamed.path)
            viewModel.refresh()
            selectedEntryID = nil
        } catch {
            showFailure(error)
        }
    }

    private func toggleHiddenSelection() {
        guard let entry = selectedEntry else { return }
        toggleHidden(entry)
    }

    private func toggleHidden(_ entry: FileAreaEntry) {
        do {
            try viewModel.service.setHidden(!entry.isHidden, at: entry.url.path)
            viewModel.refresh()
        } catch {
            showFailure(error)
        }
    }

    private func performDelete() {
        guard let entry = deleteTarget else { return }
        deleteTarget = nil
        do {
            try viewModel.service.delete(at: entry.url.path)
            // 工作区目录删除后同步移出登记（目录在废纸篓，恢复后可重新添加）
            WorkspaceRegistry.shared.unregister(path: entry.url.path)
            viewModel.refresh()
            selectedEntryID = nil
        } catch {
            showFailure(error)
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try viewModel.service.createFolder(
                at: viewModel.currentFolderURL.path,
                name: name
            )
            newFolderName = ""
            viewModel.refresh()
        } catch {
            showFailure(error)
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: viewModel.currentFolderURL.path)
    }

    private func revealEntryInFinder(_ entry: FileAreaEntry) {
        NSWorkspace.shared.selectFile(entry.url.path, inFileViewerRootedAtPath: entry.url.deletingLastPathComponent().path)
    }

    private func showFailure(_ error: Error) {
        errorMessage = L.actionableError(error, fallbackKey: "error.actionable.files")
        showError = true
    }
}

// MARK: - Folder Tree Row

/// 树节点行：folder 为 nil 表示受管区根节点。
/// 子文件夹懒加载（onAppear 读目录一次并缓存）；空文件夹不显示展开箭头。
/// 右键菜单动作经闭包上抛到页面（对话框与刷新都在页面层管理）
private struct FolderTreeRow: View {
    @ObservedObject var viewModel: FilesViewModel
    let folder: FileAreaEntry?
    let rootName: String
    /// 受保护的一级根（受管区之外的工作区目录）：不可改名 / 删除
    var isProtectedRoot: Bool = false
    let onNewFolderInside: (URL) -> Void
    let onRename: (FileAreaEntry) -> Void
    let onDelete: (FileAreaEntry) -> Void

    private var url: URL { folder?.url ?? viewModel.service.baseDirectory }
    private var name: String { folder?.name ?? rootName }
    private var isHidden: Bool { folder?.isHidden ?? false }

    /// 缓存命中后才知道有没有子文件夹；未加载完先按有箭头渲染（加载后自动纠正）
    private var subfolders: [FileAreaEntry] {
        viewModel.displaySubfolders(of: url)
    }

    var body: some View {
        Group {
            if subfolders.isEmpty && viewModel.childrenCache[url.path] != nil {
                labelContent
            } else {
                DisclosureGroup(isExpanded: expandBinding) {
                    ForEach(subfolders) { child in
                        FolderTreeRow(
                            viewModel: viewModel,
                            folder: child,
                            rootName: rootName,
                            onNewFolderInside: onNewFolderInside,
                            onRename: onRename,
                            onDelete: onDelete
                        )
                    }
                } label: {
                    labelContent
                }
            }
        }
        .tag(url)
    }

    private var labelContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(MeetTypography.secondary)
                .foregroundStyle(.blue)
            Text(name)
                .font(MeetTypography.control)
                .lineLimit(1)
                .foregroundStyle(isHidden ? .secondary : .primary)
            if isHidden {
                Text(L.string("files.hidden"))
                    .font(MeetTypography.secondary)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .onAppear { viewModel.loadChildrenIfNeeded(url) }
        .contextMenu { menu }
    }

    private var expandBinding: Binding<Bool> {
        Binding(
            get: { viewModel.expandedFolders.contains(url.path) },
            set: { _ in viewModel.toggleExpanded(url) }
        )
    }

    @ViewBuilder
    private var menu: some View {
        Button(L.string("files.new_folder_inside")) {
            onNewFolderInside(url)
        }
        if let folder {
            Divider()
            if !isProtectedRoot {
                Button(L.string("files.rename")) { onRename(folder) }
            }
            Button(folder.isHidden ? L.string("files.show") : L.string("files.hide")) {
                do {
                    try viewModel.service.setHidden(!folder.isHidden, at: folder.url.path)
                    viewModel.refresh()
                } catch { }
            }
            if !isProtectedRoot {
                Button(L.string("files.delete"), role: .destructive) { onDelete(folder) }
            }
        }
    }
}
