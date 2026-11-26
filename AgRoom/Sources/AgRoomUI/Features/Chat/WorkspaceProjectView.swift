import Observation
import SwiftUI
import AgRoomCore

@MainActor @Observable
final class WorkspaceProjectModel {
    let workspace: ChatWorkspace
    private let store: WorkspaceProjectStore?
    private let knowledge: KnowledgeService?
    private let skills: @MainActor () async -> [Skill]
    private let isCurrent: @MainActor () -> Bool
    private let allowsChanges: @MainActor () -> Bool
    private var visible = true
    private var generation = UUID()
    private var revision: UUID?
    var configuration = WorkspaceProjectConfiguration()
    private(set) var bases: [KnowledgeBase] = []
    private(set) var catalog: [Skill] = []
    private(set) var ready = false
    private(set) var saving = false
    var errorText: String?

    init(hub: Hub, workspace: ChatWorkspace, isCurrent: @escaping @MainActor () -> Bool, allowsChanges: @escaping @MainActor () -> Bool = { true }) {
        self.workspace = workspace; store = hub.makeWorkspaceProjectStore(for: workspace.space)
        knowledge = hub.makeKnowledgeService(for: workspace.space); self.isCurrent = isCurrent
        self.allowsChanges = allowsChanges
        skills = { await hub.makeSkillStore(for: workspace.space)?.listSnapshot() ?? [] }
    }
    var canEdit: Bool { isCurrent() && allowsChanges() }
    var canSave: Bool { ready && visible && canEdit && !saving && configuration.isValid }
    func load() async {
        let ticket = UUID(); generation = ticket; visible = true; ready = false
        do {
            guard isCurrent(), let store, store.space == workspace.space, let knowledge else { throw WorkspaceProjectError.wrongWorkspace }
            let project = try await store.project(workspaceID: workspace.id)
            let bases = try await knowledge.getBases(), catalog = await skills()
            guard visible, generation == ticket, isCurrent(), !Task.isCancelled else { return }
            configuration = project?.configuration ?? .init(); revision = project?.revision
            self.bases = bases; self.catalog = catalog; ready = true; errorText = nil
        } catch { if visible, generation == ticket { errorText = L.errorDescription(error) } }
    }
    func save() async -> Bool {
        guard canSave, let store else { errorText = L.errorDescription(WorkspaceProjectError.changed); return false }
        saving = true; defer { saving = false }
        let ticket = generation, value = configuration, expected = revision
        do {
            let saved = try await store.save(value, workspaceID: workspace.id, expectedRevision: expected)
            guard visible, generation == ticket, isCurrent(), !Task.isCancelled else { return false }
            revision = saved.revision; configuration = saved.configuration; errorText = nil
            return true
        } catch { if visible, generation == ticket { errorText = L.errorDescription(error) }; return false }
    }
    func close() { visible = false; generation = UUID() }
}

struct WorkspaceProjectView: View {
    private enum Section: Hashable { case project, mcp }

    @Environment(\.dismiss) private var dismiss
    @State private var model: WorkspaceProjectModel
    @State private var pending: Task<Void,Never>?
    @State private var section = Section.project
    private let mcpService: MCPServerConfigService?
    private let mcpSessionID: UUID?
    private let mcpReport: RequestContextReport?
    private let permissionMode: PermissionMode
    private let isRunning: Bool
    let onSaved: () -> Void

    init(hub: Hub, workspace: ChatWorkspace, mcpSessionID: UUID? = nil, mcpReport: RequestContextReport? = nil,
         permissionMode: PermissionMode = .workspaceWrite, isRunning: Bool = false,
         isCurrent: @escaping @MainActor () -> Bool, allowsChanges: @escaping @MainActor () -> Bool = { true }, onSaved: @escaping () -> Void) {
        self.init(model: WorkspaceProjectModel(hub: hub, workspace: workspace, isCurrent: isCurrent, allowsChanges: allowsChanges),
                  mcpService: hub.makeMCPServerConfigService(for: workspace.space), mcpSessionID: mcpSessionID,
                  mcpReport: mcpReport, permissionMode: permissionMode, isRunning: isRunning, onSaved: onSaved)
    }

    init(model: WorkspaceProjectModel, mcpService: MCPServerConfigService? = nil, mcpSessionID: UUID? = nil,
         mcpReport: RequestContextReport? = nil, permissionMode: PermissionMode = .workspaceWrite, isRunning: Bool = false,
         onSaved: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.mcpService = mcpService; self.mcpSessionID = mcpSessionID; self.mcpReport = mcpReport
        self.permissionMode = permissionMode; self.isRunning = isRunning; self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L.string("project.title")).font(.title2.bold())
                Spacer()
                Text(model.workspace.space == .work ? L.string("space.work") : L.string("space.personal")).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.workspace.isDefault ? L.string("workspace.default.name") : model.workspace.name).font(.headline)
            Picker(L.string("project.title"), selection: $section) {
                Text(L.string("project.tab.details")).tag(Section.project)
                Text(L.string("project.tab.mcp")).tag(Section.mcp)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("project.sections")
            Divider()
            if section == .project {
                projectContent
            } else {
                Text(L.string("project.mcp.help")).font(.caption).foregroundStyle(.secondary)
                ChatMCPToolsView(service: mcpService, space: model.workspace.space, report: mcpReport,
                    permissionMode: permissionMode, isRunning: isRunning)
                    .id(mcpSessionID)
            }
            Divider()
            HStack {
                Button(L.string("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.saving)
                if section == .project {
                    Button(L.string("common.refresh")) { Task { await model.load() } }.disabled(model.saving)
                }
                Spacer()
                if model.saving { ProgressView().controlSize(.small) }
                Button(L.string("common.save")) {
                    pending = Task { if await model.save() { onSaved(); dismiss() }; pending = nil }
                }.buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }.padding(20).frame(width: 680, height: 720)
            .task { await model.load() }
            .interactiveDismissDisabled(model.saving)
            .onDisappear { model.close(); pending?.cancel(); pending = nil }
    }

    private var projectContent: some View {
        @Bindable var model = model
        return Group {
            Text(L.string("project.help")).font(.caption).foregroundStyle(.secondary)
            if !model.canEdit { Text(L.string("project.busy")).font(.caption).foregroundStyle(.orange) }
            if !model.ready {
                if model.errorText == nil { ProgressView() }
                Button(L.string("common.refresh")) { Task { await model.load() } }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L.string("project.instructions")).font(.headline)
                        TextEditor(text: $model.configuration.instructions).frame(minHeight: 150)
                            .padding(4).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                        Text(L.format("project.instructions.limit", model.configuration.instructions.count)).font(.caption).foregroundStyle(model.configuration.instructions.count > 12_000 ? .red : .secondary)
                        Divider()
                        Text(L.string("project.knowledge")).font(.headline)
                        Toggle(L.string("project.knowledge.all"), isOn: Binding(get: { model.configuration.knowledgeBaseIDs == nil }, set: {
                            model.configuration.knowledgeBaseIDs = $0 ? nil : []
                        }))
                        if let selected = model.configuration.knowledgeBaseIDs {
                            if model.bases.isEmpty { Text(L.string("project.knowledge.empty")).font(.caption).foregroundStyle(.secondary) }
                            ForEach(model.bases) { base in
                                Toggle(base.name, isOn: Binding(get: { model.configuration.knowledgeBaseIDs?.contains(base.id) == true }, set: { selected in
                                    var values = Set(model.configuration.knowledgeBaseIDs ?? [])
                                    if selected { values.insert(base.id) } else { values.remove(base.id) }
                                    model.configuration.knowledgeBaseIDs = values.sorted { $0.uuidString < $1.uuidString }
                                })).disabled(!selected.contains(base.id) && selected.count >= 128)
                            }
                            ForEach(selected.filter { id in !model.bases.contains { $0.id == id } }, id: \.self) { id in
                                HStack {
                                    Text(L.format("project.knowledge.missing", id.uuidString)).font(.caption).foregroundStyle(.orange)
                                    Spacer()
                                    Button(L.string("project.remove")) { model.configuration.knowledgeBaseIDs?.removeAll { $0 == id } }
                                }
                            }
                            Text(L.string("project.knowledge.selected.help")).font(.caption).foregroundStyle(.secondary)
                            Text(L.format("project.knowledge.limit", selected.count)).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Text(L.string("project.skills")).font(.headline)
                        Text(L.string("project.skills.help")).font(.caption).foregroundStyle(.secondary)
                        ForEach(model.catalog, id: \.name) { skill in
                            Toggle(skill.alias.isEmpty ? skill.name : skill.alias, isOn: Binding(get: { model.configuration.preferredSkillNames.contains(skill.name) }, set: { selected in
                                if selected { model.configuration.preferredSkillNames.append(skill.name) }
                                else { model.configuration.preferredSkillNames.removeAll { $0 == skill.name } }
                            })).disabled((!skill.isEnabled || model.configuration.preferredSkillNames.count >= 64) && !model.configuration.preferredSkillNames.contains(skill.name))
                            if !skill.isEnabled { Text(L.string("project.skills.disabled")).font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(model.configuration.preferredSkillNames.filter { name in !model.catalog.contains { $0.name == name } }, id: \.self) { name in
                            HStack {
                                Text(L.format("project.skills.missing", name)).font(.caption).foregroundStyle(.orange)
                                Spacer()
                                Button(L.string("project.remove")) { model.configuration.preferredSkillNames.removeAll { $0 == name } }
                            }
                        }
                        if model.catalog.isEmpty { Text(L.string("project.skills.empty")).font(.caption).foregroundStyle(.secondary) }
                        Text(L.format("project.skills.limit", model.configuration.preferredSkillNames.count)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).disabled(model.saving || !model.canEdit)
                }
            }
            if let error = model.errorText { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}
