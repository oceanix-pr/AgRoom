import SwiftUI
import AppKit
import AgRoomCore

/// The sheet item carries both the operation and its configuration snapshot.
enum MCPServerEditorContext: Identifiable, Sendable {
    case create(MCPServerConfig)
    case edit(MCPServerConfig)

    var id: UUID { config.id }

    var config: MCPServerConfig {
        switch self {
        case .create(let config), .edit(let config): config
        }
    }

    var isCreating: Bool {
        if case .create = self { return true }
        return false
    }

    func save(_ draft: MCPServerConfig, token: String?, service: MCPServerConfigService) async throws -> MCPServerConfig {
        try await service.save(draft, token: token, creating: isCreating)
    }
}

/// Fixed-space sheet: late probes/saves never resolve services from Hub.current.
@MainActor
struct MCPSettingsView: View {
    let service: MCPServerConfigService?
    let space: AppSpace
    @Environment(\.dismiss) private var dismiss
    @State private var unresolved: [MCPUncertainSubmission] = []
    @State private var acknowledging: MCPUncertainSubmission?
    @State private var servers: [MCPServerConfig] = []
    @State private var editing: MCPServerEditorContext?
    @State private var deleting: MCPServerConfig?
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var action: Task<Void, Never>?
    @State private var imported: [MCPImportedConnection] = []
    @State private var importedToken = ""
    @State private var choosingImport = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.string("mcp.title")).font(.headline)
                    Text(L.format("settings.scope.space", L.string(space.nameKey)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            Form {
                Section {
                    Text(L.string("mcp.description"))
                    Button(L.string("mcp.add")) { editing = .create(MCPServerConfig()) }
                        .disabled(service == nil || busy || servers.count >= MCPServerConfig.maximumServers)
                    Button(L.string("mcp.import"), systemImage: "doc.on.clipboard") { importConnection() }
                        .disabled(service == nil || busy || servers.count >= MCPServerConfig.maximumServers)
                    Text(L.string("mcp.import.help")).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if servers.isEmpty {
                        Text(L.string("mcp.empty")).foregroundStyle(.secondary)
                    }
                    ForEach(servers) { server in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(server.name).fontWeight(.medium)
                                Text(L.string(server.isEnabled
                                    ? (server.selectedToolNames.isEmpty ? "mcp.enabled.empty.short" : "mcp.enabled")
                                    : "mcp.disabled"))
                                    .font(.caption)
                                    .foregroundStyle(server.isEnabled && server.selectedToolNames.isEmpty ? Color.orange : Color.secondary)
                                Spacer()
                                Button(L.string("mcp.edit")) { editing = .edit(server) }
                                Button(role: .destructive) { deleting = server } label: {
                                    Image(systemName: "trash")
                                }
                                .help(L.string("mcp.delete"))
                            }
                            Text(server.endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(L.format("mcp.selected.count", server.selectedToolNames.count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .disabled(busy)
                    }
                } footer: {
                    Text(L.string("mcp.foreground"))
                }
                if !unresolved.isEmpty {
                    Section(L.string("mcp.uncertain.title")) {
                        ForEach(unresolved) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.serverName + " · " + item.toolName)
                                    Text(item.startedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L.string("mcp.uncertain.review")) { acknowledging = item }.disabled(busy)
                            }
                        }
                    }
                }
                if busy { ProgressView().controlSize(.small) }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                        Button(L.string("mcp.reload")) { reload() }.disabled(busy)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 500, idealHeight: 640)
        .task { await load() }
        .onDisappear { action?.cancel() }
        .sheet(item: $editing, onDismiss: { importedToken = ""; reload() }) { context in
            if let service {
                MCPServerEditor(service: service, context: context, initialToken: importedToken) {
                    editing = nil
                }
            }
        }
        .confirmationDialog(L.string("mcp.import.choose"), isPresented: $choosingImport, titleVisibility: .visible) {
            ForEach(imported) { connection in
                Button(connection.config.name) { openImported(connection) }
            }
            Button(L.string("common.cancel"), role: .cancel) { imported = [] }
        }
        .onChange(of: choosingImport) { _, showing in if !showing { imported = [] } }
        .confirmationDialog(L.string("mcp.uncertain.verify"), isPresented: Binding(
            get: { acknowledging != nil }, set: { if !$0 { acknowledging = nil } }
        ), titleVisibility: .visible, presenting: acknowledging) { item in
            Button(L.string("mcp.uncertain.acknowledge")) {
                guard let service else { return }
                busy = true
                action = Task {
                    defer { busy = false }
                    do { try await service.acknowledgeSubmission(item.id) }
                    catch { errorMessage = L.errorDescription(error) }
                    await load()
                }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { item in
            Text(L.format("mcp.uncertain.detail", item.serverName, item.toolName))
        }
        .confirmationDialog(L.string("mcp.delete.title"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button(L.string("mcp.delete"), role: .destructive) {
                guard let server = deleting, let service else { return }
                deleting = nil
                busy = true
                action = Task {
                    do { try await service.delete(server) }
                    catch { errorMessage = L.errorDescription(error) }
                    await load()
                    busy = false
                }
            }
        } message: {
            Text(L.format("mcp.delete.message", deleting?.name ?? ""))
        }
    }

    private func reload() {
        errorMessage = nil
        action?.cancel()
        action = Task { await load() }
    }

    private func importConnection() {
        do {
            let values = try MCPConnectionImport.parse(NSPasteboard.general.string(forType: .string) ?? "")
            if values.count == 1, let connection = values.first { openImported(connection) }
            else { imported = values; choosingImport = true }
        } catch { errorMessage = L.errorDescription(error) }
    }

    private func openImported(_ connection: MCPImportedConnection) {
        importedToken = connection.token
        editing = .create(connection.config)
        imported = []
    }

    private func load() async {
        guard let service else { errorMessage = L.string("mcp.error.storage"); return }
        do {
            let values = try await service.getAll()
            let receipts = try await service.uncertainSubmissions()
            try Task.checkCancellation()
            servers = values
            unresolved = receipts
        } catch is CancellationError {
        } catch { errorMessage = L.errorDescription(error) }
    }
}

@MainActor
private struct MCPServerEditor: View {
    let service: MCPServerConfigService
    let context: MCPServerEditorContext
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MCPServerConfig
    @State private var token = ""
    @State private var probing = false
    @State private var saving = false
    @State private var probeSucceeded = false
    @State private var probeErrorMessage: String?
    @State private var saveErrorMessage: String?
    @State private var action: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var toolSearch = ""
    @State private var selectedOnly = false

    private var visibleTools: [MCPToolDescriptor] {
        draft.tools.filter { tool in
            (!selectedOnly || draft.selectedToolNames.contains(tool.name)) &&
            (toolSearch.isEmpty || tool.name.localizedCaseInsensitiveContains(toolSearch)
             || tool.description.localizedCaseInsensitiveContains(toolSearch))
        }
    }

    init(service: MCPServerConfigService, context: MCPServerEditorContext, initialToken: String = "", onSaved: @escaping () -> Void) {
        self.service = service
        self.context = context
        self.onSaved = onSaved
        _draft = State(initialValue: context.config)
        _token = State(initialValue: initialToken)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string(context.isCreating ? "mcp.add" : "mcp.edit.title")).font(.headline)
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }.disabled(saving)
                    .keyboardShortcut(.cancelAction)
                Button(L.string("common.save")) { save() }
                    .disabled(probing || saving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (try? draft.validatedEndpoint()) == nil)
            }
            .padding(16)
            Divider()
            Form {
                if let saveErrorMessage {
                    Section {
                        Text(saveErrorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    } header: {
                        Text(L.string("mcp.save.failed"))
                    }
                }
                Section {
                    TextField(L.string("mcp.name"), text: $draft.name)
                    TextField(L.string("mcp.endpoint"), text: $draft.endpoint)
                        .fontDesign(.monospaced)
                        .autocorrectionDisabled()
                    Picker(L.string("mcp.authentication"), selection: $draft.authentication) {
                        Text(L.string("mcp.auth.none")).tag(MCPServerConfig.Authentication.none)
                        Text(L.string("mcp.auth.bearer")).tag(MCPServerConfig.Authentication.bearer)
                    }
                    if draft.authentication == .bearer {
                        SecureField(L.string(context.isCreating ? "mcp.token" : "mcp.token.keep"), text: $token)
                    }
                    Toggle(L.string("mcp.enable"), isOn: $draft.isEnabled)
                    if draft.isEnabled && draft.selectedToolNames.isEmpty {
                        Label(L.string("mcp.enabled.empty"), systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                } footer: {
                    Text(L.string("mcp.endpoint.help"))
                }
                Section {
                    HStack {
                        Button(L.string("mcp.discover")) { discover() }
                            .disabled(probing || saving || (try? draft.validatedEndpoint()) == nil)
                        if probing {
                            ProgressView().controlSize(.small)
                            Button(L.string("common.cancel")) { cancelProbe() }
                        }
                    }
                    if probeSucceeded {
                        Label(L.format("mcp.discovered.count", draft.tools.count), systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    if let probeErrorMessage {
                        Text(probeErrorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                } footer: {
                    Text(L.string("mcp.discover.help"))
                }
                Section {
                    if draft.tools.isEmpty {
                        Text(L.string("mcp.tools.empty")).foregroundStyle(.secondary)
                    } else {
                        TextField(L.string("mcp.tools.search"), text: $toolSearch)
                        Toggle(L.string("mcp.tools.selected_only"), isOn: $selectedOnly)
                        HStack {
                            Text(L.format("mcp.selected.count", draft.selectedToolNames.count))
                            Spacer()
                            Button(L.string("mcp.select.all")) { draft.selectedToolNames = Set(draft.tools.map(\.name)) }
                                .disabled(draft.tools.count > MCPServerConfig.maximumSelectedTools)
                            Button(L.string("mcp.select.none")) { draft.selectedToolNames = [] }
                        }
                        if visibleTools.isEmpty { Text(L.string("mcp.tools.no_matches")).foregroundStyle(.secondary) }
                        ForEach(visibleTools) { tool in
                            Toggle(isOn: Binding(
                                get: { draft.selectedToolNames.contains(tool.name) },
                                set: { selected in
                                    if selected { draft.selectedToolNames.insert(tool.name) }
                                    else { draft.selectedToolNames.remove(tool.name) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tool.name).fontDesign(.monospaced)
                                    if !tool.description.isEmpty {
                                        Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            }
                            .disabled(!draft.selectedToolNames.contains(tool.name)
                                && draft.selectedToolNames.count >= MCPServerConfig.maximumSelectedTools)
                        }
                    }
                    if draft.rejectedToolCount > 0 {
                        Text(L.format("mcp.tools.rejected", draft.rejectedToolCount))
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text(L.string("mcp.tools"))
                } footer: {
                    Text(L.string("mcp.tools.help"))
                }
                .disabled(probing)
            }
            .formStyle(.grouped)
            .disabled(saving)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 720)
        .interactiveDismissDisabled(saving)
        .onDisappear { action?.cancel() }
        .onChange(of: draft.endpoint) { _, _ in invalidateConnection() }
        .onChange(of: draft.authentication) { _, _ in invalidateConnection() }
        .onChange(of: token) { _, _ in invalidateConnection() }
    }

    private func invalidateConnection() {
        cancelProbe()
        draft.tools = []
        draft.selectedToolNames = []
        draft.catalogProtocolVersion = nil
        draft.rejectedToolCount = 0
    }

    private func cancelProbe() {
        generation = UUID()
        action?.cancel()
        action = nil
        probing = false
        probeSucceeded = false
        probeErrorMessage = nil
    }

    private func discover() {
        cancelProbe()
        var config = draft
        config.endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.isEmpty ? nil : token
        let identity = generation
        probing = true
        action = Task {
            do {
                let catalog = try await service.discover(config: config, token: credential)
                guard !Task.isCancelled, identity == generation else { return }
                let unchanged = Set(catalog.tools.filter { tool in
                    config.tools.contains(where: { $0.fingerprint == tool.fingerprint })
                }.map(\.name))
                draft.tools = catalog.tools
                draft.selectedToolNames = config.selectedToolNames.intersection(unchanged)
                draft.catalogProtocolVersion = catalog.protocolVersion
                draft.rejectedToolCount = catalog.rejectedToolCount
                probeSucceeded = true
            } catch {
                guard !Task.isCancelled, identity == generation else { return }
                probeErrorMessage = L.errorDescription(error)
            }
            probing = false
            action = nil
        }
    }

    private func save() {
        saveErrorMessage = nil
        saving = true
        let config = draft
        let credential = token.isEmpty ? nil : token
        action = Task {
            do {
                _ = try await context.save(config, token: credential, service: service)
                onSaved()
            } catch {
                if let mcp = error as? MCPError, mcp.code == .configurationChanged {
                    saveErrorMessage = L.string("mcp.save.configurationChanged")
                } else {
                    saveErrorMessage = L.errorDescription(error)
                }
                saving = false
            }
        }
    }
}
