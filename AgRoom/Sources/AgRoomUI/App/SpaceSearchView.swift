import Foundation
import Observation
import SwiftUI
import AgRoomCore

@MainActor @Observable
final class SpaceSearchModel {
    let service: SpaceSearchService
    let includeHidden: Bool
    private let isCurrent: @MainActor () -> Bool
    var query = ""
    var kind: SpaceSearchKind?
    var selectedID: String?
    private(set) var hits: [SpaceSearchHit] = []
    private(set) var preview: SpaceSearchPreview?
    private(set) var hasMore = false
    private(set) var unavailable: Set<SpaceSearchKind> = []
    private(set) var loading = false
    private(set) var loadingPreview = false
    var errorText: String?
    private var generation = UUID()
    private var previewGeneration = UUID()
    private var visible = true
    var commands: Bool { query.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
    var key: String { query + ":" + (kind?.rawValue ?? "all") }
    var selected: SpaceSearchHit? { hits.first { $0.id == selectedID } }
    var active: Bool { visible && isCurrent() && !Task.isCancelled }

    init(service: SpaceSearchService, includeHidden: Bool = false, isCurrent: @escaping @MainActor () -> Bool) {
        self.service = service; self.includeHidden = includeHidden; self.isCurrent = isCurrent
    }

    func load(reset: Bool = true) async {
        let ticket = UUID(); generation = ticket
        let key = key
        if reset { hits = []; selectedID = nil; preview = nil; hasMore = false; unavailable = [] }
        guard active, !commands, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { loading = false; return }
        loading = true; errorText = nil
        defer { if generation == ticket { loading = false } }
        do {
            if reset { try await Task.sleep(for: .milliseconds(200)) }
            let page = try await service.search(query, kind: kind, before: reset ? nil : hits.last,
                includeHidden: includeHidden, language: LanguageManager.shared.activeLanguageCode)
            guard active, generation == ticket, self.key == key else { return }
            if reset { hits = page.hits }
            else { let existing = Set(hits.map(\.id)); hits += page.hits.filter { !existing.contains($0.id) } }
            unavailable.formUnion(page.unavailableSources); hasMore = page.hasMore
            if selectedID == nil { selectedID = hits.first?.id }
        } catch is CancellationError {}
        catch { if active, generation == ticket, self.key == key { errorText = L.errorDescription(error) } }
    }

    func loadPreview() async {
        let ticket = UUID(); previewGeneration = ticket
        preview = nil; loadingPreview = false
        guard active, let hit = selected else { return }
        loadingPreview = true
        defer { if previewGeneration == ticket { loadingPreview = false } }
        do {
            let value = try await service.preview(hit, includeHidden: includeHidden, language: LanguageManager.shared.activeLanguageCode)
            guard active, previewGeneration == ticket, selectedID == hit.id else { return }
            preview = value; errorText = nil
        } catch is CancellationError {}
        catch { if active, previewGeneration == ticket, selectedID == hit.id { errorText = L.errorDescription(error) } }
    }

    func quote() async -> SpaceSearchPreview? {
        guard active, let preview, preview.canQuote, selectedID == preview.hit.id else { return nil }
        let ticket = previewGeneration
        do {
            let value = try await service.reference(preview, includeHidden: includeHidden, language: LanguageManager.shared.activeLanguageCode)
            guard active, previewGeneration == ticket, selectedID == value.hit.id else { return nil }
            return value
        } catch is CancellationError { return nil }
        catch { if active, previewGeneration == ticket { errorText = L.errorDescription(error) }; return nil }
    }
    func cancel() { visible = false; generation = UUID(); previewGeneration = UUID(); loading = false; loadingPreview = false }
    func activate() { visible = true }
}

enum SpaceSearchAction: String, CaseIterable, Identifiable {
    case newChat, firstTask, taskCenter, knowledge, memory, tools, apps, mail, agents, team, scheduled, files, settings
    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .newChat: L.string("chat.new")
        case .firstTask: L.string("product.setup.title")
        case .taskCenter: L.string("product.tasks")
        default: L.string("nav." + (self == .tools ? "skills" : rawValue))
        }
    }
    var icon: String {
        switch self {
        case .newChat: "plus.bubble"
        case .firstTask: "sparkles"
        case .taskCenter: "checklist"
        default: HubNavItem(rawValue: rawValue)?.iconName ?? "arrow.up.forward.app"
        }
    }
}

enum SearchReferenceDraft {
    @MainActor
    static func text(_ preview: SpaceSearchPreview) -> String {
        let heading = L.format("search.space.reference.heading", L.string("search.space.kind." + preview.hit.kind.rawValue),
            preview.hit.title.replacingOccurrences(of: "\n", with: " "))
        let lines = (heading + "\n" + preview.content).components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        return lines + (preview.truncated ? "\n\n" + L.string("search.space.excerpt") : "")
    }
}

struct SpaceSearchView: View {
    @State private var model: SpaceSearchModel
    var allowsActions = true
    let onOpen: @MainActor (SpaceSearchPreview) -> Void
    let onQuote: @MainActor (SpaceSearchPreview) throws -> Void
    var onAction: @MainActor (SpaceSearchAction) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var quoteTask: Task<Void, Never>?

    init(model: SpaceSearchModel, allowsActions: Bool = true, onOpen: @escaping @MainActor (SpaceSearchPreview) -> Void,
         onQuote: @escaping @MainActor (SpaceSearchPreview) throws -> Void, onAction: @escaping @MainActor (SpaceSearchAction) -> Void = { _ in }) {
        _model = State(initialValue: model); self.allowsActions = allowsActions
        self.onOpen = onOpen; self.onQuote = onQuote; self.onAction = onAction
    }

    private var actions: [SpaceSearchAction] {
        guard allowsActions, model.query.isEmpty || model.commands else { return [] }
        let query = model.query.trimmingCharacters(in: .whitespaces).drop(while: { $0 == ">" }).trimmingCharacters(in: .whitespaces)
        return SpaceSearchAction.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.string("search.space.title")).font(.title2.bold())
                Text(L.string(model.service.space.nameKey)).foregroundStyle(model.service.space.tint)
                Spacer()
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField(L.string("search.space.placeholder"), text: $model.query).focused($focused)
                    .accessibilityIdentifier("search.space.query")
                    .onSubmit {
                        if let action = actions.first { onAction(action) }
                        else if let preview = model.preview { onOpen(preview) }
                    }
                Picker(L.string("search.space.source"), selection: $model.kind) {
                    Text(L.string("product.tasks.all_sources")).tag(Optional<SpaceSearchKind>.none)
                    ForEach(SpaceSearchKind.allCases, id: \.self) { Text(L.string("search.space.kind." + $0.rawValue)).tag(Optional($0)) }
                }.frame(width: 180).disabled(model.commands)
            }
            Text(L.string("search.space.scope")).font(.caption).foregroundStyle(.secondary)
            if !model.unavailable.isEmpty {
                Text(L.format("search.space.partial", model.unavailable.map { L.string("search.space.kind." + $0.rawValue) }.sorted().joined(separator: "、")))
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    if !actions.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(actions) { action in
                                    Button { onAction(action) } label: {
                                        Label(action.title, systemImage: action.icon).frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain).padding(7).accessibilityIdentifier("search.space.action." + action.rawValue)
                                }
                            }
                        }
                    } else {
                        List(model.hits, selection: $model.selectedID) { hit in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.title.isEmpty ? L.string("search.space.untitled") : hit.title).font(.headline).lineLimit(2)
                                Text(L.string("search.space.kind." + hit.kind.rawValue)).font(.caption).foregroundStyle(.secondary)
                                if !hit.isEnabled { Text(L.string("search.space.disabled")).font(.caption).foregroundStyle(.orange) }
                                Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }.padding(.vertical, 4).tag(hit.id)
                        }.listStyle(.plain)
                        if model.hasMore { Button(L.string("search.space.more")) { Task { await model.load(reset: false) } }.disabled(model.loading) }
                    }
                    if model.loading { ProgressView().controlSize(.small) }
                }.frame(width: 290)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let preview = model.preview {
                        Text(preview.hit.title).font(.headline).textSelection(.enabled)
                        Text(L.string("search.space.kind." + preview.hit.kind.rawValue)).font(.caption).foregroundStyle(.secondary)
                        if preview.truncated { Text(L.string("search.space.excerpt")).font(.caption).foregroundStyle(.orange) }
                        ScrollView { Text(preview.content).readingBodyFont().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) }
                            .id(preview.revision)
                        HStack {
                            Button(L.string("search.space.open_source")) { onOpen(preview) }
                            Spacer()
                            Button(L.string("search.space.quote")) {
                                quoteTask = Task {
                                    defer { quoteTask = nil }
                                    if let value = await model.quote() {
                                        do { try onQuote(value) } catch { model.errorText = L.errorDescription(error) }
                                    }
                                }
                            }.buttonStyle(.borderedProminent).disabled(!preview.canQuote || quoteTask != nil)
                        }
                        Text(L.string("search.space.quote.help")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L.string(model.loadingPreview ? "search.space.loading" : "search.space.empty"))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let error = model.errorText {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button(L.string("common.retry")) { Task { if model.selectedID == nil { await model.load() } else { await model.loadPreview() } } }.controlSize(.small)
                }
            }
        }.padding(20).frame(minWidth: 840, idealWidth: 960, minHeight: 600, idealHeight: 700)
        .onAppear { model.activate(); focused = true }
        .task(id: model.key) { await model.load() }
        .task(id: model.selectedID) { await model.loadPreview() }
        .onDisappear { quoteTask?.cancel(); quoteTask = nil; model.cancel() }
    }
}

struct SpaceSearchPresentation: Identifiable {
    let id = UUID()
    let space: AppSpace
}

struct SearchReferencePresentation: Identifiable {
    let id = UUID()
    let space: AppSpace
    let sessionID: UUID?
}

struct SearchTaskPresentation: Identifiable {
    let id = UUID()
    let space: AppSpace
    var jobID: UUID? = nil
}

struct SearchArtifactPresentation: Identifiable {
    let id = UUID()
    let space: AppSpace
    var versionID: UUID? = nil
}

@MainActor enum SpaceSearchRoutes {
    static func source(_ value: SpaceSearchPreview) -> ProductRoute {
        let hit = value.hit
        switch hit.kind {
        case .conversation:
            return .init(space: hit.space, page: "chat", sessionID: hit.parentID.flatMap(UUID.init(uuidString:)), messageID: UUID(uuidString: hit.sourceID))
        case .task:
            return .init(space: hit.space, page: "chat", sessionID: hit.parentID.flatMap(UUID.init(uuidString:)), messageID: hit.secondaryID.flatMap(UUID.init(uuidString:)), runID: UUID(uuidString: hit.sourceID))
        case .team: return .init(space: hit.space, page: "team", taskID: UUID(uuidString: hit.sourceID))
        case .scheduled: return .init(space: hit.space, page: "scheduled", taskID: hit.parentID.flatMap(UUID.init(uuidString:)), runID: UUID(uuidString: hit.sourceID))
        case .artifact: return .init(space: hit.space, page: "files", artifactVersionID: UUID(uuidString: hit.sourceID))
        case .job: return .init(space: hit.space, page: "chat", runID: UUID(uuidString: hit.sourceID), showTasks: true)
        default:
            let page: String
            switch hit.kind {
            case .skill: page = "tools"
            case .app: page = "apps"
            case .agent: page = "agents"
            default: page = hit.kind.rawValue
            }
            return .init(space: hit.space, page: page, contentID: hit.sourceID)
        }
    }
}
