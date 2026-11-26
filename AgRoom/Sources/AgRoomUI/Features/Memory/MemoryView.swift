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

    /// 下拉顺序：自动判断在首位，其余按枚举顺序
    static let all: [MemoryCategoryChoice] = [.auto] + MemoryCategory.allCases.map(MemoryCategoryChoice.value)
}

// MARK: - Memory View

/// 管理当前空间的长期记忆，可按类别筛选、逐条启用或停用。
public struct MemoryView: View {
    let hub: Hub
    private let space: AppSpace
    private let sourceID: UUID?
    /// 工具栏搜索词：过滤记忆列表（内容命中，大小写不敏感）
    @Environment(\.globalSearchText) private var searchText

    @State private var memories: [MemoryItem] = []
    @State private var editingMemory: MemoryItem?
    @State private var newContent = ""
    @State private var newCategory: MemoryCategoryChoice = .auto
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

                Button(action: addMemory) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(isAddingMemory
                    || newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

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

            let visibleMemories = filteredMemories
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
        .task(id: sourceID) {
            await load()
            guard !Task.isCancelled, hub.spaceStore.current == space, let sourceID else { return }
            if let target = memories.first(where: { $0.id == sourceID }) { categoryFilter = nil; editingMemory = target }
            else { errorMessage = L.errorDescription(SpaceSearchError.missing); showErrorAlert = true }
        }
        .sheet(item: $editingMemory) { memory in
            if let service = hub.makeMemoryService(for: space) {
                MemoryEditorSheet(memory: memory, service: service, sessionService: hub.makeSessionService(for: space)) { Task { await load() } }
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

    /// 搜索词 + 类别筛选后的记忆（内容命中，大小写不敏感）
    private var filteredMemories: [MemoryItem] {
        var result = memories
        if let categoryFilter {
            result = result.filter { $0.category == categoryFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return result }
        return result.filter {
            $0.content.localizedCaseInsensitiveContains(query)
        }
    }

    private func load() async {
        guard let service = hub.makeMemoryService(for: space) else {
            errorMessage = L.string("error.actionable.memory_load")
            showErrorAlert = true
            return
        }
        do {
            let loaded = try await service.getAll()
            guard !Task.isCancelled, hub.spaceStore.current == space else { return }
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
        isAddingMemory = true
        Task {
            defer { isAddingMemory = false }
            do {
                guard let service = hub.makeMemoryService(for: space) else {
                    errorMessage = L.string("error.actionable.memory_change")
                    showErrorAlert = true
                    return
                }
                let category = await resolveCategory(for: choice, content: content)
                guard !Task.isCancelled, hub.spaceStore.current == space else { return }
                try await service.save(MemoryItem(content: content, category: category))
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

    /// 「自动判断」交给模型归类；无可用提供者或归类失败时回退「其他」，不阻断保存
    private func resolveCategory(for choice: MemoryCategoryChoice, content: String) async -> MemoryCategory {
        switch choice {
        case .value(let category):
            return category
        case .auto:
            guard let provider = try? await hub.makeActiveProvider(for: space, source: "memory-classification") else { return .other }
            return await MemoryDistiller.classify(content, provider: provider)
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
