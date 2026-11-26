import SwiftUI
import AgRoomCore

/// Owns only remote connection state; SQLite paths and SQL execution never enter this workspace.
@MainActor @Observable
final class MySQLConnectionsModel {
    enum ConnectionStatus: String { case unverified, loading, verified, failed }
    let service: MySQLConnectorService
    private(set) var connections: [MySQLConnectionConfig] = []
    private(set) var selected: UUID?
    private(set) var tables: HostDataTable?
    private(set) var columns: HostDataTable?
    private(set) var selectedTable: String?
    private(set) var busy = false
    private(set) var deleting = false
    var error: String?
    private var statuses: [UUID: ConnectionStatus] = [:]
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var reloadID = UUID()

    init(service: MySQLConnectorService) { self.service = service }
    var selectedConnection: MySQLConnectionConfig? { connections.first { $0.id == selected } }
    func status(for config: MySQLConnectionConfig) -> ConnectionStatus { statuses[config.id] ?? .unverified }

    func reload(selecting preferredID: UUID? = nil) async {
        let requestID = UUID()
        reloadID = requestID
        do {
            let values = try await service.connections()
            try Task.checkCancellation()
            guard reloadID == requestID else { return }
            let previous = selectedConnection
            statuses = statuses.filter { id, _ in
                values.first { $0.id == id } == connections.first { $0.id == id }
            }
            connections = values
            let wanted = preferredID ?? selected
            let next = values.first { $0.id == wanted } ?? values.first
            selected = next?.id
            if previous != next || tables == nil || preferredID != nil { load(table: nil) }
        } catch is CancellationError {
        } catch {
            guard reloadID == requestID else { return }
            self.error = L.errorDescription(error)
        }
    }

    func select(_ id: UUID?) {
        guard selected != id else { return }
        cancel()
        selected = id
        load(table: nil)
    }
    func selectTable(_ table: String?) {
        guard selectedTable != table else { return }
        selectedTable = table
        columns = nil
        if let table { load(table: table) }
    }
    func cancel() {
        generation = UUID(); reloadID = UUID()
        operation?.cancel(); operation = nil; busy = false
        if let selected, statuses[selected] == .loading { statuses[selected] = .unverified }
    }
    func load(table: String?) {
        cancel()
        columns = nil
        if table == nil { tables = nil; selectedTable = nil }
        guard let config = selectedConnection, !deleting else { return }
        let requestID = generation
        busy = true; error = nil; statuses[config.id] = .loading
        operation = Task {
            do {
                let result = try await service.metadata(config, table: table)
                try Task.checkCancellation()
                guard generation == requestID, selectedConnection == config else { return }
                if table == nil { tables = result } else { columns = result }
                statuses[config.id] = .verified
                busy = false; operation = nil
                if table == nil { selectTable(result.rows.first?.id) }
            } catch {
                guard generation == requestID, !Task.isCancelled else { return }
                statuses[config.id] = .failed
                self.error = L.errorDescription(error)
                busy = false; operation = nil
            }
        }
    }
    func delete(_ config: MySQLConnectionConfig) async {
        guard !deleting else { return }
        cancel()
        tables = nil; columns = nil; selectedTable = nil
        deleting = true; error = nil
        defer { deleting = false }
        do {
            try await service.delete(config)
            // Reconcile only after storage commits. A failed removal retains the connection.
            deleting = false
            await reload()
        } catch { self.error = L.errorDescription(error) }
    }
}

/// Reused inline in the remote workspace and in native app connection-management sheets.
struct MySQLConnectionsView: View {
    let service: MySQLConnectorService
    var showsCloseButton = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.globalSearchText) private var searchText
    @State private var model: MySQLConnectionsModel
    @State private var editing: MySQLConnectionConfig?
    @State private var creating = false
    @State private var removing: MySQLConnectionConfig?
    @State private var savedID: UUID?

    init(service: MySQLConnectorService, showsCloseButton: Bool = true) {
        self.service = service
        self.showsCloseButton = showsCloseButton
        _model = State(initialValue: MySQLConnectionsModel(service: service))
    }
    private var filteredConnections: [MySQLConnectionConfig] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.connections : model.connections.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.database.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.string("mysql.manage")).font(.title2.bold())
                Spacer()
                Text(L.string(service.space.nameKey)).foregroundStyle(.secondary)
                Button(L.string("mysql.add"), systemImage: "plus") {
                    creating = true; editing = MySQLConnectionConfig()
                }.disabled(model.busy || model.deleting)
                if showsCloseButton { Button(L.string("common.close")) { dismiss() } }
            }
            Text(L.string("mysql.description")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                connectionList.frame(width: 260)
                Divider()
                metadataArea.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(16)
        .frame(minWidth: showsCloseButton ? 760 : 0, minHeight: showsCloseButton ? 500 : 0)
        .task { await model.reload() }
        .onDisappear { model.cancel() }
        .sheet(item: $editing, onDismiss: {
            let preferred = savedID; savedID = nil
            Task { await model.reload(selecting: preferred) }
        }) { config in
            MySQLConnectionEditor(service: service, initial: config, creating: creating) { savedID = $0.id }
        }
        .alert(L.string("mysql.deleteConfirm"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L.string("common.cancel"), role: .cancel) { removing = nil }
            Button(L.string("mysql.remove"), role: .destructive) {
                guard let config = removing else { return }
                removing = nil
                Task { await model.delete(config) }
            }
        } message: {
            Text(L.format("mysql.deleteMessage", removing?.name ?? ""))
        }
    }
    private var connectionList: some View {
        List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
            ForEach(filteredConnections) { config in
                VStack(alignment: .leading, spacing: 5) {
                    Text(config.name).font(.headline)
                    Text("\(config.host):\(config.port) / \(config.database)").font(.caption).foregroundStyle(.secondary)
                    statusLabel(model.status(for: config))
                    HStack {
                        Button(L.string("mysql.edit")) { creating = false; editing = config }
                        Button(L.string("mysql.remove"), role: .destructive) { removing = config }
                    }.buttonStyle(.borderless).disabled(model.busy || model.deleting)
                }.padding(.vertical, 4).tag(config.id)
            }
        }.disabled(model.deleting)
        .overlay {
            if model.connections.isEmpty {
                Text(L.string("mysql.connections.empty")).font(.callout).foregroundStyle(.secondary).padding()
            }
        }
    }
    private func statusLabel(_ status: MySQLConnectionsModel.ConnectionStatus) -> some View {
        let icon: String = switch status {
        case .unverified: "questionmark.circle"
        case .loading: "arrow.triangle.2.circlepath"
        case .verified: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
        return Label(L.string("mysql.status." + status.rawValue), systemImage: icon)
            .font(.caption).foregroundStyle(status == .failed ? Color.red : Color.secondary)
    }
    private var metadataArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let config = model.selectedConnection {
                    Text(config.database).font(.headline)
                    statusLabel(model.status(for: config))
                }
                Spacer()
                Button(L.string("mysql.loadTables"), systemImage: "arrow.clockwise") { model.load(table: nil) }
                    .disabled(model.selected == nil || model.busy || model.deleting)
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button(L.string("common.cancel")) { model.cancel() }
                }
                if model.deleting { ProgressView().controlSize(.small) }
            }
            if let tables = model.tables {
                if tables.rows.isEmpty {
                    Text(L.string("mysql.tables.empty")).foregroundStyle(.secondary)
                } else {
                    List(tables.rows, selection: Binding(get: { model.selectedTable }, set: { model.selectTable($0) })) { row in
                        VStack(alignment: .leading) {
                            Text(row.title)
                            Text(row.fields["comment"]?.string ?? "").font(.caption).foregroundStyle(.secondary)
                        }.tag(row.id)
                    }.frame(minHeight: 120, idealHeight: 170, maxHeight: 230).disabled(model.deleting)
                }
            } else if !model.busy {
                Text(L.string(model.selected == nil ? "mysql.selection.empty" : "mysql.metadata.unloaded"))
                    .foregroundStyle(.secondary)
            }
            if let columns = model.columns {
                ScrollView([.vertical, .horizontal]) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            ForEach(columns.columns, id: \.self) { Text(L.string("apps.column." + $0)).font(.caption.bold()) }
                        }
                        ForEach(columns.rows) { row in
                            GridRow {
                                ForEach(columns.columns, id: \.self) { Text(row.fields[$0]?.string ?? "").font(.caption).textSelection(.enabled) }
                            }
                        }
                    }
                }.frame(minHeight: 120)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MySQLConnectionEditor: View {
    let service: MySQLConnectorService
    let creating: Bool
    let onSave: (MySQLConnectionConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var config: MySQLConnectionConfig
    @State private var password = ""
    @State private var replacePassword: Bool
    @State private var error: String?
    @State private var tested = false
    @State private var busy = false
    @State private var operation: Task<Void, Never>?

    init(service: MySQLConnectorService, initial: MySQLConnectionConfig, creating: Bool, onSave: @escaping (MySQLConnectionConfig) -> Void) {
        self.service = service; self.creating = creating; self.onSave = onSave
        _config = State(initialValue: initial); _replacePassword = State(initialValue: creating)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string(creating ? "mysql.add" : "mysql.edit")).font(.title2.bold())
            Form {
                TextField(L.string("mysql.name"), text: $config.name)
                TextField(L.string("mysql.host"), text: $config.host)
                TextField(L.string("mysql.port"), value: $config.port, format: .number.grouping(.never))
                TextField(L.string("mysql.database"), text: $config.database)
                TextField(L.string("mysql.username"), text: $config.username)
                Toggle(L.string("mysql.tls"), isOn: $config.requiresTLS)
                if !creating { Toggle(L.string("mysql.replacePassword"), isOn: $replacePassword) }
                if replacePassword { SecureField(L.string("mysql.password"), text: $password) }
            }.textFieldStyle(.roundedBorder).disabled(busy)
            Text(L.string("mysql.security")).font(.caption).foregroundStyle(.secondary)
            Text(L.string("mysql.saveHelp")).font(.caption).foregroundStyle(.secondary)
            if tested { Label(L.string("mysql.tested"), systemImage: "checkmark.circle").foregroundStyle(.green) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Button(L.string("mysql.test")) { run(save: false) }.disabled(busy)
                Spacer()
                Button(L.string("common.cancel")) { operation?.cancel(); dismiss() }
                Button(L.string("mysql.save")) { run(save: true) }.buttonStyle(.borderedProminent).disabled(busy)
            }
        }.padding(24).frame(width: 480)
        .onDisappear { operation?.cancel(); password = "" }
        .onChange(of: config) { _, _ in tested = false }
        .onChange(of: password) { _, _ in tested = false }
        .onChange(of: replacePassword) { _, _ in tested = false }
    }
    private func run(save: Bool) {
        let input = config, secret = replacePassword ? password : nil
        busy = true; error = nil; tested = false
        operation = Task {
            do {
                if save {
                    let saved = try await service.save(input, password: secret, creating: creating)
                    try Task.checkCancellation(); onSave(saved); dismiss()
                } else {
                    try await service.test(input, password: secret)
                    try Task.checkCancellation(); tested = true
                }
            } catch { if !Task.isCancelled { self.error = L.errorDescription(error) } }
            busy = false
        }
    }
}
