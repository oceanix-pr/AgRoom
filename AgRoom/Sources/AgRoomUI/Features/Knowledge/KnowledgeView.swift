import SwiftUI
import AppKit
import Combine
import AgRoomCore

/// 知识库：空间内统一目录树、范围检索、阅读、编辑与受控整理。
public struct KnowledgeView: View {
    private let providerService: ProviderConfigService?
    private let usageRecorder: ProviderUsageRecorder?
    private let graphUsageRecorder: ProviderUsageRecorder?
    private let jobHistoryStore: ProductJobRunStore?
    private let jobCenter: JobCenter
    private let source: ProductRoute?
    private let isCurrentSpace: @MainActor () -> Bool
    private let chooseImportFiles: (@MainActor () async -> [URL]?)?
    @State private var model: KnowledgeBrowserModel
    @Environment(\.globalSearchText) private var searchText
    @AppStorage("agroom.knowledge.paneWidth") private var paneWidth: Double = 270
    @State private var paneDragStart: Double?
    @State private var kindFilter: KnowledgeKind?
    @State private var viewMode: ViewMode = .list
    @State private var showingNew = false
    @State private var showingAIGenerate = false
    @State private var importContext: KnowledgeImportContext?
    @State private var editingItem: KnowledgeItem?
    @State private var generatedDraft: KnowledgeItem?
    @State private var draftBaseID: UUID?
    @State private var draftFolderID: UUID?
    @State private var nameSheet: NameSheetContext?
    @State private var moveRequest: KnowledgeMoveRequest?
    @State private var pendingDeletion: KnowledgeNodeID?
    @State private var graph: KnowledgeGraph?
    @State private var graphRevision = 0
    @State private var graphFailed = false
    @State private var showGraphSettings = false
    @State private var graphFocus: String?
    @State private var graphEvidence: KnowledgeGraph.Edge?
    @State private var includeGraphTags = true
    @State private var includeGraphSimilarity = true
    @State private var includeGraphRelations = true
    @State private var includeExcludedRelations = false
    @AppStorage(KnowledgeEmbeddingSettings.modelPathKey) private var embeddingPath = KnowledgeEmbeddingSettings.defaultModelURL.path
    @AppStorage(KnowledgeEmbeddingSettings.enabledKey) private var embeddingEnabled = true

    enum ViewMode: String, CaseIterable { case list, graph }

    public init(hub: Hub) { self.init(hub: hub, source: nil) }

    init(hub: Hub, source: ProductRoute?) {
        providerService = hub.providerService
        let space = hub.spaceStore.current
        isCurrentSpace = { hub.spaceStore.current == space }
        chooseImportFiles = nil
        usageRecorder = hub.makeUsageRecorder(for: space, source: "knowledge-design")
        graphUsageRecorder = hub.makeUsageRecorder(for: space, source: "knowledge-graph")
        jobHistoryStore = hub.makeJobRunStore(for: space)
        jobCenter = .shared
        self.source = source
        _model = State(initialValue: KnowledgeBrowserModel(space: space, makeService: { hub.makeKnowledgeService(for: space) }))
    }

    init(model: KnowledgeBrowserModel, jobCenter: JobCenter, providerService: ProviderConfigService? = nil,
         chooseImportFiles: (@MainActor () async -> [URL]?)? = nil) {
        self.usageRecorder = nil
        self.graphUsageRecorder = nil
        self.jobHistoryStore = nil
        self.jobCenter = jobCenter
        self.source = nil
        self.providerService = providerService
        self.isCurrentSpace = { true }
        self.chooseImportFiles = chooseImportFiles
        _model = State(initialValue: model)
    }

    private var filteredItems: [KnowledgeItemSummary] { model.filteredItems(query: searchText, kind: kindFilter) }
    private var searchIdentity: String { model.searchIdentity(query: searchText, kind: kindFilter) }
    private var isWaitingForSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.completedSearch != searchIdentity
    }

    public var body: some View {
        HStack(spacing: 0) {
            KnowledgeTreeSidebar(model: model, onAction: handleTreeAction, onDrop: handleDrop)
                .frame(width: min(max(paneWidth, 210), 440))
            paneDivider
            VStack(spacing: 0) {
                breadcrumb
                Divider()
                header
                Divider()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: source?.id) {
            await model.reload()
            guard !Task.isCancelled, isCurrentSpace(), let source, source.space == model.space,
                  let id = source.contentID.flatMap(UUID.init(uuidString:)) else { return }
            viewMode = .list; kindFilter = nil
            model.selection = .item(id)
        }
        .task(id: model.detailIdentity) { await model.loadSelectedItem() }
        .task(id: searchIdentity) { await model.search(query: searchText, kind: kindFilter) }
        .onChange(of: searchText) { _, _ in model.selectedItemIDs.removeAll() }
        .onChange(of: kindFilter) { _, _ in model.selectedItemIDs.removeAll() }
        .onChange(of: viewMode) { _, _ in model.selectedItemIDs.removeAll() }
        .onChange(of: filteredItems.map(\.id)) { _, visible in model.selectedItemIDs.formIntersection(Set(visible)) }
        .onReceive(NotificationCenter.default.publisher(for: KnowledgeGraphService.didChange)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in graphRevision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: KnowledgeImportService.didChange)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)) { notification in
                guard notification.object as? String == model.space.rawValue else { return }
                Task { await model.reload() }
            }
        .sheet(item: $importContext) { context in
            if let service = model.service {
                KnowledgeImportSheet(model: KnowledgeImportModel(service: KnowledgeImportService(service: service, space: model.space),
                    baseID: context.baseID, folderID: context.folderID, sourceID: context.sourceID, jobs: jobCenter, isCurrentSpace: isCurrentSpace), chooseSources: chooseImportFiles) {
                        Task { await model.reload() }
                    }
            }
        }
        .sheet(isPresented: $showGraphSettings) {
            if let service = model.service {
                KnowledgeGraphSettingsSheet(service: service, providerService: providerService, recorder: graphUsageRecorder, space: model.space, historyStore: jobHistoryStore)
            }
        }
        .sheet(item: $graphEvidence) { edge in
            if let service = model.service { KnowledgeGraphEvidenceSheet(edge: edge, service: service, space: model.space) }
        }
        .sheet(isPresented: $showingNew) {
            KnowledgeFormSheet(item: nil, baseId: draftBaseID, folderId: draftFolderID,
                               sourceContext: .scoped(to: model.space)) { try await saveItem($0, isNew: true) }
        }
        .sheet(item: $editingItem) { item in
            KnowledgeFormSheet(item: item, sourceContext: .scoped(to: model.space)) { try await saveItem($0, isNew: false) }
        }
        .sheet(item: $generatedDraft) { draft in
            KnowledgeFormSheet(item: draft, sourceContext: .scoped(to: model.space)) { try await saveItem($0, isNew: true) }
        }
        .sheet(isPresented: $showingAIGenerate) {
            KnowledgeAIGenerateSheet(providerService: providerService, usageRecorder: usageRecorder, service: model.service, scope: model.scope) { draft in
                var result = draft
                result.baseId = draftBaseID
                result.folderId = draftFolderID
                generatedDraft = result
            }
        }
        .sheet(item: $nameSheet) { context in
            NameInputSheet(context: context) { try await saveName(context, name: $0) }
        }
        .sheet(item: $moveRequest) { request in
            KnowledgeMoveSheet(snapshot: model.snapshot, node: request.node, itemCount: request.itemIDs?.count ?? 1) { baseID, folderID in
                guard let service = model.service else { throw LLMError.configurationError(reason: "Database unavailable") }
                if let ids = request.itemIDs { try await service.moveItems(ids, toBase: baseID, folder: folderID) }
                else { try await service.move(request.node, toBase: baseID, folder: folderID) }
                model.selectedItemIDs.removeAll()
                await model.reload()
            }
        }
        .confirmationDialog(L.string("chat.delete_confirm.title"), isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if case .folder = pendingDeletion {
                Button(L.string("knowledge.folder.remove_only")) { deletePending(keepingContents: true) }
                Button(L.string("knowledge.folder.delete_all"), role: .destructive) { deletePending() }
            } else {
                Button(L.string("common.delete"), role: .destructive) { deletePending() }
            }
            Button(L.string("common.cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deletionMessage)
        }
        .alert(L.string("common.error"), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(L.string("common.ok"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var paneDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 4).contentShape(Rectangle())
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if paneDragStart == nil { paneDragStart = paneWidth }
                    paneWidth = min(max(210, (paneDragStart ?? paneWidth) + value.translation.width), 440)
                }.onEnded { _ in paneDragStart = nil })
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal) {
            HStack(spacing: MeetSpacing.sm) {
                crumb(L.string("knowledge.folder.all"), selection: .all)
                if model.selection == .unfiled || (model.selectedItemID != nil && model.selectedBaseID == nil) {
                    separator
                    crumb(L.string("knowledge.unfiled"), selection: .unfiled)
                }
                if let base = model.snapshot.bases.first(where: { $0.id == model.selectedBaseID }) {
                    separator
                    crumb(base.name, selection: .base(base.id))
                }
                if let id = model.selectedFolderID {
                    ForEach(model.snapshot.ancestors(of: id)) { folder in
                        separator
                        crumb(folder.name, selection: .folder(folder.id))
                    }
                }
                if let id = model.selectedItemID, let item = model.snapshot.itemsByID[id] {
                    separator
                    Text(item.title).font(MeetTypography.control).foregroundStyle(.primary).lineLimit(1)
                }
            }
            .padding(.horizontal, MeetSpacing.lg)
            .frame(height: ColumnHeaderMetrics.height)
        }
        .scrollIndicators(.hidden)
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
    }

    private func crumb(_ title: String, selection: KnowledgeSelection) -> some View {
        Button { model.selection = selection } label: { Text(title).lineLimit(1) }
            .font(MeetTypography.control).buttonStyle(.plain)
            .foregroundStyle(model.selection == selection ? .primary : .secondary)
    }

    private var header: some View {
        HStack(spacing: MeetSpacing.md) {
            if model.selectedItemID != nil {
                Button { selectParent() } label: { Label(L.string("knowledge.back"), systemImage: "arrow.left") }
                Spacer(minLength: MeetSpacing.sm)
                if let item = model.selectedItem {
                    Button { editingItem = item } label: { Label(L.string("knowledge.edit"), systemImage: "pencil") }
                    Menu {
                        Button(L.string("knowledge.move")) { moveRequest = .init(node: .item(item.id)) }
                        Button(L.string("common.delete"), role: .destructive) { pendingDeletion = .item(item.id) }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(L.string("knowledge.actions"))
                }
            } else {
                Text(L.format(model.selectedItemIDs.isEmpty ? "knowledge.entry_count" : "knowledge.selection.count",
                              model.selectedItemIDs.isEmpty ? filteredItems.count : model.selectedItemIDs.count))
                    .font(MeetTypography.secondary).foregroundStyle(.secondary)
                if !model.selectedItemIDs.isEmpty {
                    Button(L.string("knowledge.move")) { moveSelected(model.selectedItemIDs) }
                    Button { model.selectedItemIDs.removeAll() } label: { Image(systemName: "xmark.circle") }
                        .help(L.string("knowledge.selection.clear"))
                }
                if case .folder = model.selection {
                    Toggle(L.string("knowledge.include_descendants"), isOn: $model.includeDescendants)
                        .toggleStyle(.checkbox).fixedSize()
                }
                Spacer(minLength: MeetSpacing.sm)
                if model.selectedItemIDs.isEmpty {
                    Picker(L.string("knowledge.form.kind"), selection: $kindFilter) {
                        Text(L.string("knowledge.filter.all")).tag(KnowledgeKind?.none)
                        Text(L.string("knowledge.kind.document")).tag(KnowledgeKind?.some(.document))
                        Text(L.string("knowledge.kind.wiki")).tag(KnowledgeKind?.some(.wiki))
                    }
                    .labelsHidden().frame(maxWidth: 115)
                    Picker(L.string("knowledge.view"), selection: $viewMode) {
                        Image(systemName: "list.bullet").tag(ViewMode.list).help(L.string("knowledge.mode.list"))
                        Image(systemName: "point.3.connected.trianglepath.dotted").tag(ViewMode.graph).help(L.string("knowledge.mode.graph"))
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 76)
                }
            }
            Menu {
                Button(L.string("knowledge.add")) { captureDestination(); showingNew = true }
                Button(L.string("knowledge.import")) { importFiles() }
                Button(L.string("knowledge.ai.generate")) { captureDestination(); showingAIGenerate = true }
                if let baseID = model.selectedBaseID {
                    Divider()
                    Button(L.string("knowledge.folder.new")) {
                        nameSheet = .newFolder(base: baseID, parent: model.selectedFolderID)
                    }
                }
                Button(L.string("knowledge.base.new")) { nameSheet = .newBase() }
                Divider()
                Button(L.string("knowledge.refresh")) { Task { await model.reload() } }
            } label: { Image(systemName: "plus") }
            .help(L.string("knowledge.add")).accessibilityLabel(L.string("knowledge.add"))
        }
        .font(MeetTypography.control)
        .buttonStyle(.borderless)
        .disabled(model.isMutating)
        .padding(.horizontal, MeetSpacing.lg)
        .frame(minHeight: ColumnHeaderMetrics.height)
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.loadFailed {
            ContentUnavailableView {
                Label(L.string("knowledge.load.failed"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(L.string("knowledge.load.failed.help"))
            } actions: {
                Button(L.string("common.retry")) { Task { await model.reload() } }
            }
        } else if model.selectedItemID != nil {
            if model.itemLoadFailed {
                ContentUnavailableView {
                    Label(L.string("common.error"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(L.string("knowledge.error.operation"))
                } actions: {
                    Button(L.string("common.retry")) { Task { await model.loadSelectedItem() } }
                }
            } else if model.isLoadingItem || model.selectedItem == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let item = model.selectedItem {
                document(item)
            }
        } else if isWaitingForSearch {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredItems.isEmpty {
            ContentUnavailableView(L.string("knowledge.empty"), systemImage: "books.vertical",
                                   description: Text(L.format("knowledge.empty.desc", L.dispatcherName())))
        } else if viewMode == .list {
            let selectionPayload = dragPayload(ids: filteredItems.map(\.id).filter(model.selectedItemIDs.contains))
            List(selection: $model.selectedItemIDs) {
                ForEach(filteredItems) { item in
                    itemRow(item, selectionPayload: selectionPayload).tag(item.id)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button(L.string("knowledge.open")) { model.selection = .item(id) }
                    Button(L.string("knowledge.edit")) { edit(id) }
                    Button(L.string("common.delete"), role: .destructive) { pendingDeletion = .item(id) }
                }
                if !ids.isEmpty { Button(L.string("knowledge.move")) { moveSelected(ids) } }
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { model.selection = .item(id) }
            }
            .help(L.string("knowledge.selection.help"))
            .onKeyPress(.return) {
                guard model.selectedItemIDs.count == 1, let id = model.selectedItemIDs.first else { return .ignored }
                model.selection = .item(id)
                return .handled
            }
        } else {
            graphContent
        }
    }

    private func itemRow(_ item: KnowledgeItemSummary, selectionPayload: String) -> some View {
        HStack(alignment: .top, spacing: MeetSpacing.md) {
            Button {
                if !model.selectedItemIDs.insert(item.id).inserted { model.selectedItemIDs.remove(item.id) }
            } label: {
                Image(systemName: model.selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(MeetTypography.navigation)
                    .foregroundStyle(model.selectedItemIDs.contains(item.id) ? Color.white : Color.secondary)
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.format("knowledge.selection.toggle", item.title))
            .accessibilityAddTraits(model.selectedItemIDs.contains(item.id) ? .isSelected : [])
            Image(systemName: item.kind == .wiki ? "text.book.closed" : "doc.text")
                .font(MeetTypography.navigation)
                .foregroundStyle(item.kind == .wiki ? MeetStatusColor.textual : MeetStatusColor.resource)
                .frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: MeetSpacing.xs) {
                HStack(spacing: MeetSpacing.sm) {
                    Text(item.title).font(MeetTypography.listTitle).lineLimit(1).help(item.title)
                    StatusBadge(text: L.string(item.kind == .wiki ? "knowledge.kind.wiki" : "knowledge.kind.document"),
                                color: item.kind == .wiki ? MeetStatusColor.textual : MeetStatusColor.resource)
                }
                Text((searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.preview : model.searchPreviews[item.id] ?? item.preview)
                    .replacingOccurrences(of: "\n", with: " "))
                    .font(MeetTypography.secondary).foregroundStyle(.secondary).lineLimit(1)
                Text(path(for: item)).font(MeetTypography.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: MeetSpacing.sm)
            Text(AppDate.dateString(from: item.updatedAt)).font(MeetTypography.secondary).foregroundStyle(.secondary)
        }
        .padding(.vertical, MeetSpacing.sm)
        .contentShape(Rectangle())
        .draggable(model.selectedItemIDs.contains(item.id) ? selectionPayload : dragPayload(ids: [item.id]))
    }

    private func document(_ item: KnowledgeItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MeetSpacing.lg) {
                Text(item.title).font(MeetTypography.pageTitle).textSelection(.enabled)
                HStack(spacing: MeetSpacing.sm) {
                    StatusBadge(text: L.string(item.kind == .wiki ? "knowledge.kind.wiki" : "knowledge.kind.document"),
                                color: item.kind == .wiki ? MeetStatusColor.textual : MeetStatusColor.resource)
                    Text(item.tags.joined(separator: " · ")).lineLimit(2)
                    Spacer()
                    Text(AppDate.dateString(from: item.updatedAt))
                }
                .font(MeetTypography.secondary).foregroundStyle(.secondary)
                Divider()
                if let service = model.service {
                    KnowledgeSourceMaintenanceView(item: item, service: KnowledgeImportService(service: service, space: model.space)) { sourceID in
                        importContext = KnowledgeImportContext(baseID: item.baseId, folderID: item.folderId, sourceID: sourceID)
                    }.id(item.id)
                }
                MarkdownView(text: item.content, documentID: item.id.uuidString, sourceContext: .scoped(to: model.space))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(MeetSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var graphContent: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack { graphFilters; Spacer(); graphActions }
                VStack(alignment: .leading) { graphFilters; graphActions }
            }.font(MeetTypography.control).padding(MeetSpacing.sm)
            Divider()
            if graphFailed {
                ContentUnavailableView {
                    Label(L.string("graph.error.general"), systemImage: "exclamationmark.triangle")
                } actions: { Button(L.string("common.retry")) { graphRevision += 1 } }
            } else if let graph {
                KnowledgeGraphCanvas(graph: graph, onOpenEntry: { model.selection = .item($0) }, onFocus: { graphFocus = $0 })
                let relations = graph.edges.filter { $0.kind == .relation && (graphFocus == nil || $0.from == graphFocus || $0.to == graphFocus || $0.evidence?.itemID.uuidString == graphFocus) }
                if !relations.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(relations) { edge in
                                let from = graph.nodes.first { $0.id == edge.from }?.label ?? ""
                                let to = graph.nodes.first { $0.id == edge.to }?.label ?? ""
                                let relation = [from, edge.label ?? "", to].joined(separator: " → ")
                                Button { graphEvidence = edge } label: {
                                    Text(relation)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.buttonStyle(.link)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(MeetSpacing.md)
                    }.font(MeetTypography.control).frame(maxHeight: 140)
                }
                Text(L.string("graph.legend")).font(MeetTypography.secondary).foregroundStyle(.secondary).padding(8)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: "\(searchIdentity):\(graphRevision):\(includeGraphTags):\(includeGraphSimilarity):\(includeGraphRelations):\(includeExcludedRelations):\(embeddingEnabled):\(embeddingPath)") {
            graph = nil
            graphFailed = false
            guard let service = model.service else { return }
            let ids = Set(filteredItems.map(\.id))
            do {
                let items = try await service.getItems(ids: ids)
                let paths = Dictionary(uniqueKeysWithValues: filteredItems.map { ($0.id, path(for: $0) + " / " + $0.title) })
                let identity = await Task.detached { try? KnowledgeEmbeddingSettings.load().makeProvider().indexIdentity }.value
                let result = try await KnowledgeGraphService(service: service).graph(items: items, paths: paths, modelIdentity: identity,
                    includeTags: includeGraphTags, includeSimilarity: includeGraphSimilarity, includeRelations: includeGraphRelations, includeExcluded: includeExcludedRelations)
                try Task.checkCancellation()
                graph = result
            } catch is CancellationError { return }
            catch { graphFailed = true }
        }
    }

    private var graphFilters: some View {
        HStack {
            Toggle(L.string("graph.filter.tags"), isOn: $includeGraphTags)
            Toggle(L.string("graph.filter.similarity"), isOn: $includeGraphSimilarity)
            Toggle(L.string("graph.filter.relations"), isOn: $includeGraphRelations)
            Toggle(L.string("graph.filter.excluded"), isOn: $includeExcludedRelations)
        }.toggleStyle(.checkbox)
    }
    private var graphActions: some View {
        HStack {
            Button(L.string("graph.build.title")) { showGraphSettings = true }
            Button { graphRevision += 1 } label: { Image(systemName: "arrow.clockwise") }.help(L.string("knowledge.refresh"))
        }
    }

    private func path(for item: KnowledgeItemSummary) -> String {
        let path = model.snapshot.path(for: item)
        return path.isEmpty ? L.string("knowledge.unfiled") : path.joined(separator: " / ")
    }

    private func captureDestination() { draftBaseID = model.selectedBaseID; draftFolderID = model.selectedFolderID }

    private func moveSelected(_ ids: Set<UUID>) {
        let ordered = filteredItems.map(\.id).filter { ids.contains($0) }
        guard !ordered.isEmpty else { return }
        moveRequest = .init(items: ordered)
    }

    private func dragPayload(ids: [UUID]) -> String {
        return "agroom-knowledge-items:\(model.space.rawValue):" + ids.map(\.uuidString).joined(separator: ",")
    }

    private func selectParent() {
        if let folder = model.selectedFolderID { model.selection = .folder(folder) }
        else if let base = model.selectedBaseID { model.selection = .base(base) }
        else { model.selection = .unfiled }
    }

    private func edit(_ id: UUID) {
        Task {
            do {
                guard let item = try await model.service?.get(id: id) else { throw KnowledgeOrganizationError.itemMissing }
                editingItem = item
            } catch { model.show(error) }
        }
    }

    private func saveItem(_ item: KnowledgeItem, isNew: Bool) async throws {
        guard let service = model.service else { throw LLMError.configurationError(reason: "Database unavailable") }
        if isNew { try await service.save(item) } else { try await service.updateContent(item) }
        await model.reload()
        model.selection = .item(item.id)
    }

    private func handleTreeAction(_ action: KnowledgeTreeAction) {
        switch action {
        case .newBase: nameSheet = .newBase()
        case .newFolder(let base, let parent): nameSheet = .newFolder(base: base, parent: parent)
        case .rename(.base(let id)):
            if let base = model.snapshot.bases.first(where: { $0.id == id }) { nameSheet = .renameBase(base) }
        case .rename(.folder(let id)):
            if let folder = model.snapshot.foldersByID[id] { nameSheet = .renameFolder(folder) }
        case .rename(.item(let id)): edit(id)
        case .delete(let node): pendingDeletion = node
        case .move(let node): moveRequest = .init(node: node)
        case .reorder(let node, let earlier): Task { await model.perform { try await $0.reorder(node, earlier: earlier) } }
        }
    }

    private func saveName(_ context: NameSheetContext, name: String) async throws {
        guard let service = model.service else { throw LLMError.configurationError(reason: "Database unavailable") }
        switch context.purpose {
        case .newBase:
            let base = KnowledgeBase(name: name)
            try await service.saveBase(base)
            await model.reload()
            model.selection = .base(base.id)
        case .renameBase(let base):
            try await service.renameBase(id: base.id, name: name)
            await model.reload()
        case .newFolder(let base, let parent):
            let folder = KnowledgeFolder(baseId: base, parentId: parent, name: name)
            try await service.saveFolder(folder)
            await model.reload()
            model.selection = .folder(folder.id)
        case .renameFolder(let folder):
            try await service.renameFolder(id: folder.id, name: name)
            await model.reload()
        }
    }

    private var deletionMessage: String {
        switch pendingDeletion {
        case .item(let id):
            return L.format("knowledge.delete_confirm.message", model.snapshot.itemsByID[id]?.title ?? "")
        case .base(let id):
            let name = model.snapshot.bases.first(where: { $0.id == id })?.name ?? ""
            let folderCount = model.snapshot.folders.filter { $0.baseId == id }.count
            let itemCount = model.snapshot.items.filter { $0.baseId == id }.count
            return L.format("knowledge.base.delete_counts", name, folderCount, itemCount)
        case .folder(let id):
            let ids = model.snapshot.descendantIDs(of: id)
            let count = model.snapshot.items.filter { $0.folderId.map(ids.contains) == true }.count
            return L.format("knowledge.folder.delete_counts", model.snapshot.foldersByID[id]?.name ?? "", ids.count - 1, count)
        case nil: return ""
        }
    }

    private func deletePending(keepingContents: Bool = false) {
        guard let node = pendingDeletion else { return }
        pendingDeletion = nil
        Task {
            await model.perform { service in
                switch node {
                case .base(let id): try await service.deleteBase(id: id)
                case .folder(let id): try await service.deleteFolder(id: id, keepingContents: keepingContents)
                case .item(let id): try await service.delete(id: id)
                }
            }
        }
    }

    private func handleDrop(_ values: [String], baseID: UUID?, folderID: UUID?) -> Bool {
        guard !model.isMutating, !values.isEmpty else { return false }
        var ids: [UUID] = []
        var folder: UUID?
        for value in values {
            guard value.count <= 400_000 else { return false }
            let fields = value.split(separator: ":").map(String.init)
            guard fields.count >= 3, fields[1] == model.space.rawValue else { return false }
            if fields[0] == "agroom-knowledge-items", fields.count == 3 {
                let parts = fields[2].split(separator: ",")
                let parsed = parts.compactMap { UUID(uuidString: String($0)) }
                guard !parsed.isEmpty, parsed.count == parts.count else { return false }
                ids += parsed
            } else if fields[0] == "agroom-knowledge", fields.count == 4, let id = UUID(uuidString: fields[3]) {
                if fields[2] == "item" { ids.append(id) }
                else if fields[2] == "folder", values.count == 1 { folder = id }
                else { return false }
            } else { return false }
        }
        if let folder {
            guard ids.isEmpty, baseID != nil, model.snapshot.foldersByID[folder] != nil else { return false }
            Task { await model.perform { try await $0.move(.folder(folder), toBase: baseID, folder: folderID) } }
        } else {
            guard !ids.isEmpty, ids.allSatisfy({ model.snapshot.itemsByID[$0] != nil }) else { return false }
            let captured = ids
            Task { await model.perform { try await $0.moveItems(captured, toBase: baseID, folder: folderID) } }
        }
        return true
    }

    private func importFiles() {
        importContext = KnowledgeImportContext(baseID: model.selectedBaseID, folderID: model.selectedFolderID)
    }
}

// MARK: - Name Input Sheet Context

/// 名称输入弹窗上下文：新建/重命名 库与文件夹共用
@MainActor
struct NameSheetContext: Identifiable {
    enum Purpose {
        case newBase
        case renameBase(KnowledgeBase)
        case newFolder(base: UUID, parent: UUID?)
        case renameFolder(KnowledgeFolder)
    }

    let id = UUID()
    let purpose: Purpose

    static func newBase() -> NameSheetContext { .init(purpose: .newBase) }
    static func newFolder(base: UUID, parent: UUID?) -> NameSheetContext { .init(purpose: .newFolder(base: base, parent: parent)) }
    static func renameBase(_ base: KnowledgeBase) -> NameSheetContext { .init(purpose: .renameBase(base)) }
    static func renameFolder(_ folder: KnowledgeFolder) -> NameSheetContext { .init(purpose: .renameFolder(folder)) }

    var title: String {
        switch purpose {
        case .newBase: return L.string("knowledge.base.new")
        case .renameBase: return L.string("knowledge.base.rename")
        case .newFolder: return L.string("knowledge.folder.new")
        case .renameFolder: return L.string("knowledge.folder.rename")
        }
    }

    var initialText: String {
        switch purpose {
        case .renameBase(let base): return base.name
        case .renameFolder(let folder): return folder.name
        default: return ""
        }
    }
}

/// 单字段名称输入弹窗
struct NameInputSheet: View {
    let context: NameSheetContext
    let onSave: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(context.title)
                .font(MeetTypography.pageTitle)

            TextField(L.string("agents.form.name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
                .disabled(isSaving)

            if let errorMessage { Text(errorMessage).font(MeetTypography.control).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(L.string("common.save")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { name = context.initialText }
        .interactiveDismissDisabled(isSaving)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            do { try await onSave(trimmed); dismiss() }
            catch {
                errorMessage = L.actionableError(error, fallbackKey: "knowledge.error.operation")
                isSaving = false
            }
        }
    }
}

// MARK: - AI Generate Sheet

/// AI 搜寻生成知识：输入主题（+补充要求），模型检索库内相关知识作上下文，
/// 流式生成结构化知识文档；生成完毕交给 KnowledgeFormSheet 供用户编辑保存。
struct KnowledgeAIGenerateSheet: View {
    let providerService: ProviderConfigService?
    let usageRecorder: ProviderUsageRecorder?
    let service: KnowledgeService?
    let scope: KnowledgeSearchScope
    let onGenerated: (KnowledgeItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var instructions = ""
    @State private var isGenerating = false
    @State private var output = ""
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var generationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Text(L.string("knowledge.ai.generate"))
                .font(MeetTypography.pageTitle)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                Section {
                    TextField(L.string("knowledge.ai.topic"), text: $topic)
                        .disabled(isGenerating)
                    TextField(L.string("knowledge.ai.instructions"), text: $instructions)
                        .disabled(isGenerating)
                } header: {
                    Text(L.string("knowledge.ai.form.meta"))
                }
                Section {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if output.isEmpty && !isGenerating {
                                    Text(L.string("knowledge.ai.placeholder"))
                                        .font(MeetTypography.secondary)
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                                } else {
                                    Text(L.string("knowledge.ai.thinking"))
                                        .font(MeetTypography.secondary)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                    Text(output.isEmpty ? "…" : output)
                                        .font(MeetTypography.control.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id("aiOutput")
                                }
                            }
                            .padding(8)
                        }
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                        .onChange(of: output) { _, _ in
                            proxy.scrollTo("aiOutput", anchor: .bottom)
                        }
                    }
                } header: {
                    Text(L.string("knowledge.ai.process"))
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Text(L.string("knowledge.ai.generating"))
                        .font(MeetTypography.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L.string("common.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isGenerating)
                Button(L.string("knowledge.ai.generate.button"), action: generate)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 720, height: 620)
        .onDisappear { generationTask?.cancel() }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func generate() {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else { return }
        isGenerating = true
        output = ""
        generationTask = Task {
            do {
                guard let provider = try await providerService?.activeProvider(usageRecorder: usageRecorder) else {
                    throw LLMError.providerUnavailable
                }
                // 检索库内相关知识作上下文（AI 搜寻：先查库，再综合生成）
                var knowledgeContext = ""
                if let service {
                    let result = try await KnowledgeRetrievalService.configured(service: service).search(query: trimmedTopic, scope: scope)
                    knowledgeContext = result.passages
                        .map { "- \($0.title) (passage \($0.ordinal + 1)): \($0.content)" }
                        .joined(separator: "\n")
                }

                let system = """
                You are a knowledge curator for the user's knowledge base.
                Research and compose a well-structured knowledge document in Markdown about the given topic.
                Requirements:
                - Start with a one-paragraph summary.
                - Use clear section headings (##) and sub-points; include tables or lists where they help.
                - Cover key concepts, facts, methods, common pitfalls and best practices.
                - Be accurate and concrete; do NOT fabricate specifics (numbers, quotes, citations) you are unsure of — mark uncertainty explicitly.
                - Write in the language of the topic text.
                - Output ONLY the document content, no meta commentary.
                """
                var userText = "Topic: \(trimmedTopic)"
                if !instructions.trimmingCharacters(in: .whitespaces).isEmpty {
                    userText += "\n\nAdditional requirements from the user: \(instructions)"
                }
                if !knowledgeContext.isEmpty {
                    userText += "\n\nExisting knowledge in the base (use as reliable domain facts):\n\(knowledgeContext)"
                }

                let reply = try await provider.chatStream(
                    messages: [
                        EngineMessage(role: .system, text: system),
                        EngineMessage(role: .user, text: userText)
                    ],
                    tools: [],
                    config: LLMConfig(maxTokens: 8192, temperature: 0.5),
                    onDelta: { delta in
                        Task { @MainActor in
                            output += delta
                        }
                    }
                )
                let content = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !content.isEmpty else {
                    throw LLMError.configurationError(reason: "empty generation output")
                }
                let draft = KnowledgeItem(
                    title: trimmedTopic,
                    content: content,
                    kind: .document,
                    tags: ["AI"],
                    baseId: nil,
                    folderId: nil
                )
                isGenerating = false
                dismiss()
                onGenerated(draft)
            } catch is CancellationError { isGenerating = false }
            catch {
                isGenerating = false
                errorMessage = L.actionableError(error, fallbackKey: "error.actionable.knowledge_generate")
                showErrorAlert = true
            }
        }
    }
}

// MARK: - Knowledge Form Sheet

struct KnowledgeFormSheet: View {
    let item: KnowledgeItem?
    /// 新建时的归属（编辑时以 item 自身归属为准）
    var baseId: UUID? = nil
    var folderId: UUID? = nil
    var sourceContext = MarkdownSourceContext()
    var isNewDraft = false
    let onSave: (KnowledgeItem) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind: KnowledgeKind = .document
    @State private var tagsText = ""
    @State private var content = ""
    @AppStorage(ReadingTypography.preferenceKey) private var readingPointSize = ReadingTypography.defaultSize
    @State private var preview = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(item == nil || isNewDraft ? L.string("knowledge.add") : L.string("knowledge.edit"))
                .font(MeetTypography.pageTitle)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                Section(L.string("knowledge.form.meta")) {
                    TextField(L.string("agents.form.name"), text: $title)
                    Picker(L.string("knowledge.form.kind"), selection: $kind) {
                        Text(L.string("knowledge.kind.document")).tag(KnowledgeKind.document)
                        Text(L.string("knowledge.kind.wiki")).tag(KnowledgeKind.wiki)
                    }
                    TextField(L.string("knowledge.form.tags"), text: $tagsText)
                        .help(L.string("knowledge.form.tags.help"))
                }
                Section(L.string("knowledge.form.content")) {
                    if preview {
                        ScrollView {
                            MarkdownView(text: content, documentID: item?.id.uuidString ?? "knowledge-draft", sourceContext: sourceContext)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 200)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                    } else {
                        TextEditor(text: $content)
                            .font(.system(size: ReadingTypography(pointSize: readingPointSize).bodySize, design: .monospaced))
                            .frame(minHeight: 200)
                    }
                    HStack {
                        Spacer()
                        Button(preview ? L.string("knowledge.preview.edit") : L.string("knowledge.preview.show")) {
                            preview.toggle()
                        }
                        .font(MeetTypography.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            if let errorMessage {
                Text(errorMessage).font(MeetTypography.control).foregroundStyle(.red).padding(.horizontal, 20)
            }

            Divider()

            HStack {
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(L.string("common.save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 640, height: 640)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            guard let item else { return }
            title = item.title
            kind = item.kind
            tagsText = item.tags.joined(separator: ", ")
            content = item.content
        }
    }

    private func save() {
        var updated = item ?? KnowledgeItem(
            title: title,
            baseId: baseId,
            folderId: folderId
        )
        updated.title = title
        updated.kind = kind
        updated.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        updated.content = content
        updated.updatedAt = Date()
        guard !isSaving else { return }
        isSaving = true
        let result = updated
        Task {
            do { try await onSave(result); dismiss() }
            catch {
                if error is ScheduledExperienceError { errorMessage = L.errorDescription(error) }
                else { errorMessage = L.actionableError(error, fallbackKey: "knowledge.error.operation") }
                isSaving = false
            }
        }
    }
}
