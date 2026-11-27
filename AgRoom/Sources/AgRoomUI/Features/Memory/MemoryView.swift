import SwiftUI
import AgRoomCore

// MARK: - Memory Category Presentation

extension MemoryCategory {
    /// 类别展示名（三语本地化；数据库里仍存英文 slug）。
    /// `L.string` 是主线程隔离的，故与其它本地化展示点一样限定 MainActor
    @MainActor
    var localizedLabel: String { L.string("memory.category.\(rawValue)") }
}

/// 新增记忆时的类别选择：「自动判断」表示交给模型判定，不是可落库的类别值
enum MemoryCategoryChoice: Hashable, Identifiable {
    case auto
    case value(MemoryCategory)

    var id: String {
        switch self {
        case .auto: return "auto"
        case .value(let category): return category.rawValue
        }
    }

    @MainActor
    var label: String {
        switch self {
        case .auto: return L.string("memory.category.auto")
        case .value(let category): return category.localizedLabel
        }
    }

    static let all: [MemoryCategoryChoice] = MemoryCategory.allCases.map(MemoryCategoryChoice.value) + [.auto]
    static let initial = MemoryCategoryChoice.value(.other)

    func category(for text: String, recipient: CloudProvider?) async -> MemoryCategory? {
        switch self {
        case .value(let category): return category
        case .auto:
            guard let recipient else { return nil }
            return await MemoryDistiller.classify(text, provider: recipient)
        }
    }
}

struct MemoryScopePicker: View {
    @Binding var selection: UUID?
    let workspaces: [ChatWorkspace]

    var body: some View {
        Picker(L.string("memory.scope"), selection: $selection) {
            Text(L.string("memory.scope.space")).tag(UUID?.none)
            ForEach(workspaces) { workspace in Text(workspace.name).tag(Optional(workspace.id)) }
            if let selection, !workspaces.contains(where: { $0.id == selection }) {
                Text(L.string("memory.scope.missing")).tag(Optional(selection))
            }
        }
    }
}

// MARK: - Memory View

/// 管理当前空间的长期记忆，可按类别筛选、逐条启用或停用。
public struct MemoryView: View {
    let hub: Hub
    private let space: AppSpace
    private let sourceID: UUID?
    /// 工具栏搜索使用与聊天相同的本地记忆索引。
    @Environment(\.globalSearchText) private var searchText

    @State private var memories: [MemoryItem] = []
    @State private var editingMemory: MemoryItem?
    @State private var newContent = ""
    @State private var newCategory = MemoryCategoryChoice.initial
    @State private var newWorkspaceID: UUID?
    @State private var workspaces: [ChatWorkspace] = []
    @State private var classificationProvider: CloudProvider?
    @State private var providerVersion = 0
    /// nil = 全部类别
    @State private var categoryFilter: MemoryCategory?
    @State private var isAddingMemory = false
    @State private var updatingEnabledIDs: Set<UUID> = []
    @State private var memoryPendingDeletion: MemoryItem?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    public init(hub: Hub, sourceID: UUID? = nil) {
        self.space = hub.spaceStore.current; self.sourceID = sourceID
        self.hub = hub
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 新增输入区
            HStack(alignment: .center, spacing: 8) {
                TextField(L.string("memory.placeholder"), text: $newContent, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .onSubmit { addMemory() }

                Picker("", selection: $newCategory) {
                    ForEach(MemoryCategoryChoice.all) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 110)
                .disabled(isAddingMemory)

                MemoryScopePicker(selection: $newWorkspaceID, workspaces: workspaces)
                    .labelsHidden().frame(maxWidth: 160).disabled(isAddingMemory)
                Button(action: addMemory) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(isAddingMemory
                    || (newCategory == .auto && classificationProvider == nil)
                    || newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if newCategory == .auto {
                Text(classificationProvider.map { L.format("memory.classify.recipient", $0.displayDestination) }
                     ?? L.string("memory.classify.unavailable"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // 类别筛选（与工具栏搜索词叠加生效）
            HStack(spacing: 8) {
                Text(L.string("memory.category.label"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $categoryFilter) {
                    Text(L.string("memory.filter.all")).tag(MemoryCategory?.none)
                    ForEach(MemoryCategory.allCases, id: \.self) { category in
                        Text(category.localizedLabel).tag(MemoryCategory?.some(category))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            let visibleMemories = memories.filter { categoryFilter == nil || $0.category == categoryFilter }
            if visibleMemories.isEmpty {
                ContentUnavailableView(
                    L.string("memory.empty"),
                    systemImage: "brain.head.profile",
                    description: Text(L.string("memory.empty.desc")
                        + (searchText.isEmpty ? "" : " · " + L.string("search.no_match")))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleMemories) { memory in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(memory.content)
                                        .font(MeetTypography.listTitle)
                                        .lineLimit(3)
                                        .foregroundStyle(memory.isEnabled ? Color.primary : .secondary)
                                    // MeetMemo 风格胶囊：启用绿/停用灰
                                    StatusBadge(
                                        text: L.string(memory.isEnabled ? "memory.status.enabled" : "memory.status.disabled"),
                                        color: memory.isEnabled ? MeetStatusColor.positive : .secondary
                                    )
                                    StatusBadge(text: memory.category.localizedLabel, color: .secondary)
                                }
                                Text(AppDate.string(from: memory.createdAt))
                                    .font(MeetTypography.secondary)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(L.string(memory.isEnabled ? "memory.disable" : "memory.enable")) {
                                toggleEnabled(memory)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                            .accessibilityLabel(L.format(memory.isEnabled ? "memory.disable.label" : "memory.enable.label", memory.content))
                            .disabled(updatingEnabledIDs.contains(memory.id))
                            Button { editingMemory = memory } label: { Image(systemName: "square.and.pencil") }
                                .buttonStyle(.plain).help(L.string("product.memory.edit"))
                            Button(role: .destructive, action: { memoryPendingDeletion = memory }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, MeetSpacing.xs)
                    }
                }
            }
        }
        .task(id: searchText) { await load() }
        .task(id: sourceID) {
            workspaces = WorkspaceRegistry.shared.workspaces(for: space)
            guard let sourceID else { return }
            let target = try? await hub.makeMemoryService(for: space)?.fetch(id: sourceID)
            guard !Task.isCancelled, hub.spaceStore.current == space else { return }
            if let target { categoryFilter = nil; editingMemory = target }
            else { errorMessage = L.errorDescription(SpaceSearchError.missing); showErrorAlert = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceRegistry.didChange)) { _ in
            workspaces = WorkspaceRegistry.shared.workspaces(for: space)
        }
        .onReceive(NotificationCenter.default.publisher(for: ProviderConfigService.configurationDidChange)) { _ in
            classificationProvider = nil
            providerVersion += 1
        }
        .task(id: newCategory == .auto ? providerVersion : nil) {
            classificationProvider = nil
            guard newCategory == .auto else { return }
            let provider = try? await hub.makeActiveProvider(for: space, source: "memory-classification")
            guard !Task.isCancelled, newCategory == .auto, hub.spaceStore.current == space else { return }
            classificationProvider = provider
        }
        .sheet(item: $editingMemory) { memory in
            if let service = hub.makeMemoryService(for: space) {
                MemoryEditorSheet(memory: memory, service: service, sessionService: hub.makeSessionService(for: space), workspaces: workspaces) { Task { await load() } }
            }
        }
        .confirmationDialog(
            L.string("chat.delete_confirm.title"),
            isPresented: Binding(
                get: { memoryPendingDeletion != nil },
                set: { if !$0 { memoryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("common.delete"), role: .destructive) {
                if let memory = memoryPendingDeletion { delete(memory) }
                memoryPendingDeletion = nil
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.string("memory.delete_confirm.message"))
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        guard let service = hub.makeMemoryService(for: space) else {
            errorMessage = L.string("error.actionable.memory_load")
            showErrorAlert = true
            return
        }
        do {
            let query = searchText
            let loaded = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try await service.getAll() : try await service.search(query, limit: Int.max, includeDisabled: true)
            guard !Task.isCancelled, hub.spaceStore.current == space, query == searchText else { return }
            memories = loaded
        } catch {
            if !Task.isCancelled, hub.spaceStore.current == space {
                errorMessage = L.actionableError(error, fallbackKey: "error.actionable.memory_load")
                showErrorAlert = true
            }
        }
    }

    private func addMemory() {
        let content = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isAddingMemory else { return }
        let choice = newCategory
        let recipient = classificationProvider
        guard choice != .auto || recipient != nil else { return }
        let scope = newWorkspaceID
        isAddingMemory = true
        Task {
            defer { isAddingMemory = false }
            do {
                guard let service = hub.makeMemoryService(for: space) else {
                    errorMessage = L.string("error.actionable.memory_change")
                    showErrorAlert = true
                    return
                }
                guard let category = await choice.category(for: content, recipient: recipient) else { return }
                guard !Task.isCancelled, hub.spaceStore.current == space else { return }
                var item = MemoryItem(content: content, category: category)
                item.workspaceID = scope
                try await service.save(item)
                if newContent.trimmingCharacters(in: .whitespacesAndNewlines) == content {
                    newContent = ""
                }
                await load()
            } catch {
                if hub.spaceStore.current == space {
                    errorMessage = L.actionableError(error, fallbackKey: "error.actionable.memory_change")
                    showErrorAlert = true
                }
            }
        }
    }

    private func toggleEnabled(_ memory: MemoryItem) {
        guard hub.spaceStore.current == space else { return }
        guard let service = hub.makeMemoryService(for: space) else {
            errorMessage = L.string("error.actionable.memory_change")
            showErrorAlert = true
            return
        }
        guard updatingEnabledIDs.insert(memory.id).inserted else { return }
        Task {
            defer { updatingEnabledIDs.remove(memory.id) }
            do {
                try await service.setEnabled(id: memory.id, enabled: !memory.isEnabled)
                await load()
            } catch {
                if hub.spaceStore.current == space {
                    errorMessage = L.actionableError(error, fallbackKey: "error.actionable.memory_change")
                    showErrorAlert = true
                }
            }
        }
    }

    private func delete(_ memory: MemoryItem) {
        let service = hub.makeMemoryService(for: space)
        Task {
            do {
                guard let service else {
                    errorMessage = L.string("error.actionable.memory_change")
                    showErrorAlert = true
                    return
                }
                try await service.delete(id: memory.id)
                await load()
            } catch {
                if hub.spaceStore.current == space {
                    errorMessage = L.actionableError(error, fallbackKey: "error.actionable.memory_change")
                    showErrorAlert = true
                }
            }
        }
    }
}
