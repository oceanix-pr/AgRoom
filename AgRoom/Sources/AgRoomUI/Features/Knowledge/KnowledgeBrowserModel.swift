import Foundation
import Observation
import AgRoomCore

enum KnowledgeSelection: Codable, Hashable {
    case all, unfiled, base(UUID), folder(UUID), item(UUID)

    var nodeID: KnowledgeNodeID? {
        switch self {
        case .all, .unfiled: nil
        case .base(let id): .base(id)
        case .folder(let id): .folder(id)
        case .item(let id): .item(id)
        }
    }
}

struct KnowledgeTreeRow: Identifiable {
    let selection: KnowledgeSelection
    let title: String
    let icon: String
    let depth: Int
    let expandable: Bool
    let count: Int?
    var id: KnowledgeSelection { selection }
}

@MainActor @Observable
final class KnowledgeBrowserModel {
    let space: AppSpace
    private let makeService: () -> KnowledgeService?
    var service: KnowledgeService? { makeService() }
    private let preferences: UserDefaults
    private var loadGeneration = 0
    private var detailGeneration = 0
    private(set) var snapshot = KnowledgeBrowserSnapshot()
    private(set) var revision = 0
    private(set) var selectedItem: KnowledgeItem?
    private(set) var isLoading = true
    private(set) var loadFailed = false
    private(set) var isLoadingItem = false
    private(set) var itemLoadFailed = false
    private(set) var isMutating = false
    private(set) var isSearching = false
    private(set) var searchOrder: [UUID] = []
    private(set) var searchPreviews: [UUID: String] = [:]
    private(set) var completedSearch = ""
    var errorMessage: String?
    var selectedItemIDs: Set<UUID> = []
    var selection: KnowledgeSelection = .all {
        didSet {
            guard oldValue != selection else { return }
            selectedItemIDs.removeAll()
            detailGeneration += 1
            selectedItem = nil
            revealSelection()
            persistNavigation()
        }
    }
    var expanded: Set<KnowledgeNodeID> = []
    var includeDescendants = true { didSet { if oldValue != includeDescendants { selectedItemIDs.removeAll(); persistNavigation() } } }

    private struct NavigationState: Codable {
        var selection: KnowledgeSelection
        var expanded: Set<KnowledgeNodeID>
        var includeDescendants: Bool
    }

    private var preferenceKey: String { "agroom.knowledge.navigation.\(space.rawValue)" }

    convenience init(service: KnowledgeService?, space: AppSpace, preferences: UserDefaults = .standard) {
        self.init(space: space, preferences: preferences, makeService: { service })
    }

    init(space: AppSpace, preferences: UserDefaults = .standard, makeService: @escaping () -> KnowledgeService?) {
        self.makeService = makeService; self.space = space; self.preferences = preferences
        if let data = preferences.data(forKey: preferenceKey),
           let saved = try? JSONDecoder().decode(NavigationState.self, from: data) {
            // @Observable 把公开属性变成访问器；在 init 中赋值也会执行 didSet。
            // 直接恢复存储字段，避免构造视图时写偏好并触发根视图反复重建。
            _selection = saved.selection
            _expanded = saved.expanded
            _includeDescendants = saved.includeDescendants
        }
    }

    var selectedItemID: UUID? {
        if case .item(let id) = selection { return id }
        return nil
    }

    var selectedBaseID: UUID? {
        let id: UUID? = switch selection {
        case .base(let id): id
        case .folder(let id): snapshot.foldersByID[id]?.baseId
        case .item(let id): snapshot.itemsByID[id]?.baseId
        case .all, .unfiled: nil
        }
        return id.flatMap { value in snapshot.bases.contains(where: { $0.id == value }) ? value : nil }
    }

    var selectedFolderID: UUID? {
        switch selection {
        case .folder(let id): id
        case .item(let id):
            if let item = snapshot.itemsByID[id], let folder = item.folderId,
               snapshot.foldersByID[folder]?.baseId == item.baseId { folder }
            else { nil }
        default: nil
        }
    }

    var scope: KnowledgeSearchScope {
        switch selection {
        case .all: .all
        case .unfiled: .unfiled
        case .base(let id): .base(id)
        case .folder(let id): .folder(id, includeDescendants: includeDescendants)
        case .item:
            if let folder = selectedFolderID { .folder(folder, includeDescendants: includeDescendants) }
            else if let base = selectedBaseID { .base(base) }
            else { .unfiled }
        }
    }

    var scopedItems: [KnowledgeItemSummary] {
        // selection 在每次快照刷新时校验；删除后的短暂缺失不扩大到其他范围。
        (try? snapshot.scopedItems(scope)) ?? []
    }

    var detailIdentity: String {
        guard let id = selectedItemID else { return "" }
        return "\(id):\(snapshot.itemsByID[id]?.updatedAt.timeIntervalSince1970 ?? 0)"
    }

    var visibleRows: [KnowledgeTreeRow] {
        var rows: [KnowledgeTreeRow] = []
        let itemGroups = Dictionary(grouping: snapshot.items, by: \.folderId)
        let children = Dictionary(grouping: snapshot.folders, by: { snapshot.parents[$0.id] })
        var folderCounts: [UUID: Int] = [:]
        for item in snapshot.items {
            if let id = item.folderId, snapshot.foldersByID[id]?.baseId == item.baseId {
                for ancestor in snapshot.ancestors(of: id) { folderCounts[ancestor.id, default: 0] += 1 }
            }
        }
        func appendItem(_ item: KnowledgeItemSummary, depth: Int) {
            rows.append(.init(selection: .item(item.id), title: item.title,
                              icon: item.kind == .wiki ? "text.book.closed" : "doc.text",
                              depth: depth, expandable: false, count: nil))
        }
        func appendFolder(_ folder: KnowledgeFolder, depth: Int) {
            let descendants = children[folder.id] ?? []
            let entries = (itemGroups[folder.id] ?? []).filter { $0.baseId == folder.baseId }
            rows.append(.init(selection: .folder(folder.id), title: folder.name, icon: "folder",
                              depth: depth, expandable: !descendants.isEmpty || !entries.isEmpty,
                              count: folderCounts[folder.id] ?? 0))
            if expanded.contains(.folder(folder.id)) {
                for child in descendants { appendFolder(child, depth: depth + 1) }
                for item in entries { appendItem(item, depth: depth + 1) }
            }
        }
        for base in snapshot.bases {
            let folders = (children[nil] ?? []).filter { $0.baseId == base.id }
            let entries = snapshot.items.filter { item in
                item.baseId == base.id && (item.folderId == nil || snapshot.foldersByID[item.folderId!]?.baseId != base.id)
            }
            rows.append(.init(selection: .base(base.id), title: base.name, icon: "books.vertical",
                              depth: 0, expandable: !folders.isEmpty || !entries.isEmpty,
                              count: snapshot.items.filter { $0.baseId == base.id }.count))
            if expanded.contains(.base(base.id)) {
                for folder in folders { appendFolder(folder, depth: 1) }
                for item in entries { appendItem(item, depth: 1) }
            }
        }
        return rows
    }

    func toggle(_ node: KnowledgeNodeID) {
        if !expanded.insert(node).inserted { expanded.remove(node) }
        persistNavigation()
    }

    func revealSelection() {
        if let base = selectedBaseID { expanded.insert(.base(base)) }
        if let folder = selectedFolderID {
            for ancestor in snapshot.ancestors(of: folder) { expanded.insert(.folder(ancestor.id)) }
        }
    }

    func persistNavigation() {
        let state = NavigationState(selection: selection, expanded: expanded, includeDescendants: includeDescendants)
        if let data = try? JSONEncoder().encode(state) { preferences.set(data, forKey: preferenceKey) }
    }

    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = revision == 0
        loadFailed = false
        defer { if generation == loadGeneration { isLoading = false } }
        guard let service else { loadFailed = true; errorMessage = L.string("error.database"); return }
        do {
            let result = try await service.browserSnapshot()
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            snapshot = result
            revision += 1
            switch selection {
            case .base(let id) where !result.bases.contains(where: { $0.id == id }): selection = .all
            case .folder(let id) where result.foldersByID[id] == nil: selection = .all
            case .item(let id) where result.itemsByID[id] == nil: selection = .all
            default: break
            }
            selectedItemIDs.formIntersection(Set(scopedItems.map(\.id)))
            let valid = Set(result.bases.map { KnowledgeNodeID.base($0.id) } + result.folders.map { .folder($0.id) })
            expanded.formIntersection(valid)
            revealSelection()
            persistNavigation()
        } catch is CancellationError { return }
        catch { guard generation == loadGeneration else { return }; loadFailed = true; show(error) }
    }

    func loadSelectedItem() async {
        detailGeneration += 1
        let generation = detailGeneration
        guard let id = selectedItemID else { selectedItem = nil; isLoadingItem = false; itemLoadFailed = false; return }
        guard let service else {
            selectedItem = nil; isLoadingItem = false; itemLoadFailed = true
            errorMessage = L.string("error.database")
            return
        }
        isLoadingItem = true
        itemLoadFailed = false
        do {
            let item = try await service.get(id: id)
            try Task.checkCancellation()
            guard generation == detailGeneration, id == selectedItemID else { return }
            guard let item else { throw KnowledgeOrganizationError.itemMissing }
            selectedItem = item
            isLoadingItem = false
        } catch is CancellationError { if generation == detailGeneration { isLoadingItem = false } }
        catch { guard generation == detailGeneration else { return }; isLoadingItem = false; itemLoadFailed = true; show(error) }
    }

    func searchIdentity(query: String, kind: KnowledgeKind?) -> String {
        "\(query):\(selection):\(includeDescendants):\(kind?.rawValue ?? ""):\(revision)"
    }

    func search(query: String, kind: KnowledgeKind?) async {
        let identity = searchIdentity(query: query, kind: kind)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let service else {
            isSearching = false; searchOrder = []; searchPreviews = [:]; completedSearch = identity; return
        }
        isSearching = true
        let allowed = Set(scopedItems.filter { kind == nil || $0.kind == kind }.map(\.id))
        do {
            try await Task.sleep(for: .milliseconds(300))
            let result = try await KnowledgeRetrievalService.configured(service: service)
                .search(query: trimmed, limit: 100, allowedItemIDs: allowed)
            try Task.checkCancellation()
            guard identity == searchIdentity(query: query, kind: kind) else { return }
            var seen = Set<UUID>()
            searchOrder = result.passages.map(\.itemID).filter { seen.insert($0).inserted }
            searchPreviews = [:]
            for passage in result.passages where searchPreviews[passage.itemID] == nil {
                searchPreviews[passage.itemID] = String(passage.content.prefix(160))
            }
            completedSearch = identity
            isSearching = false
        } catch is CancellationError { return }
        catch {
            guard identity == searchIdentity(query: query, kind: kind) else { return }
            isSearching = false; completedSearch = identity; searchOrder = []; searchPreviews = [:]; show(error)
        }
    }

    func filteredItems(query: String, kind: KnowledgeKind?) -> [KnowledgeItemSummary] {
        let items = scopedItems.filter { kind == nil || $0.kind == kind }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        guard completedSearch == searchIdentity(query: query, kind: kind) else { return [] }
        let positions = Dictionary(uniqueKeysWithValues: searchOrder.enumerated().map { ($0.element, $0.offset) })
        return items.filter { positions[$0.id] != nil }.sorted { positions[$0.id]! < positions[$1.id]! }
    }

    func perform(_ operation: (KnowledgeService) async throws -> Void) async {
        guard !isMutating, let service else {
            if service == nil { errorMessage = L.string("error.database") }
            return
        }
        isMutating = true
        defer { isMutating = false }
        do { try await operation(service) }
        catch is CancellationError { return }
        catch { show(error) }
        await reload()
    }

    func show(_ error: any Error) {
        HubLogger.shared.warning("Knowledge browser operation failed: \(HubLogger.safeErrorSummary(error))")
        errorMessage = L.actionableError(error, fallbackKey: "knowledge.error.operation")
    }
}
