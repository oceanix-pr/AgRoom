import SwiftUI
import AgRoomCore

struct NativeAppRenderer: View {
    @Bindable var model: NativeAppRuntime
    @State private var showingFiles = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.preview {
                HStack {
                    if !(model.definition.scripts ?? [:]).isEmpty {
                        Menu {
                            Text(L.string(model.authorizationState.localizationKey))
                            if let date = model.authorizationGrantedAt {
                                Text(L.format("apps.script.authorization.grantedAt", date.formatted(date: .abbreviated, time: .shortened)))
                            }
                            Text(L.string("apps.script.authorization.scope"))
                            Button(L.string("apps.script.authorization.retry")) { model.retryCodeReview() }
                            Button(L.string("apps.script.authorization.revoke"), role: .destructive) { model.revokeCodeAuthorization() }
                                .disabled(!model.codeReviewed)
                        } label: {
                            Label(L.string(model.authorizationState.localizationKey),
                                  systemImage: model.codeReviewed ? "checkmark.shield" : "shield")
                                .font(.caption).foregroundStyle(model.codeReviewed ? Color.green : Color.secondary)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(!model.isReady || !model.isActive || model.isBusy)
                        .help(L.string("apps.script.authorization.scope"))
                    }
                    if model.definition.dataSources.values.contains(where: { $0.kind == .records }) {
                        Text(L.string(model.editors.isEmpty ? "apps.record.creating" : "apps.record.editing"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L.string("apps.files.title"), systemImage: "folder") { showingFiles = model.openFiles() }
                        .disabled(!model.isReady || !model.isActive || model.isBusy)
                }.padding(12)
                Divider()
            }
            ScrollView {
                NativeAppNodeView(node: model.definition.views, model: model)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            .disabled(!model.isReady || !model.isActive || model.isBusy)
            if model.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    if model.isReviewingCode { Text(L.string("apps.script.review.running")).font(.caption) }
                    Button(L.string("apps.script.stop")) { model.stopOperation() }
                }.padding(8)
            }
            if model.preview, !(model.definition.scripts ?? [:]).isEmpty {
                Text(L.string("apps.script.preview")).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if !model.scriptArtifacts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.string("apps.script.artifacts")).font(.headline)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(model.scriptArtifacts) { artifact in
                                HStack {
                                    Text(artifact.name).lineLimit(2)
                                    Spacer()
                                    Button(L.string("apps.script.saveArtifact")) { model.saveArtifact(artifact) }
                                        .disabled(model.isBusy || !model.isActive)
                                }
                            }
                        }
                    }.frame(maxHeight: 180)
                    Text(L.string("apps.script.artifacts.temporary")).font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            if !model.scriptDiagnostics.isEmpty {
                DisclosureGroup(L.string("apps.script.diagnostics")) {
                    ScrollView { Text(model.scriptDiagnostics).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 160)
                }.padding(.horizontal, 12)
            }
            if model.queries.values.contains(where: { $0.isContentTruncated }) {
                Text(L.string("apps.query.truncated")).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if let status = model.statusKey {
                Label(L.string(status), systemImage: "checkmark.circle").foregroundStyle(.green).padding(8)
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button(L.string("common.retry")) { Task { await model.retry() } }
                }.padding(12)
            }
        }
        .sheet(item: Binding(get: { model.pending }, set: { value in
            if value == nil, let command = model.pending { model.decide(command, approved: false) }
        })) { command in
            NativeAppConfirmationView(command: command, space: model.space, decide: { model.decide(command, approved: $0) },
                authorizeVersion: { model.decide(command, approved: true, authorizeVersion: true) })
        }
        .sheet(isPresented: $showingFiles, onDismiss: { model.closeFiles() }) {
            if let files = model.filesModel {
                NativeAppFilesView(model: files,
                    recordID: model.editors.count == 1 ? model.editors.values.first?.id : nil)
            }
        }
        .onChange(of: model.isActive) { _, active in if !active { showingFiles = false } }
    }
}

/// Only the finite node enum reaches SwiftUI. The small layout tree is erased at
/// component boundaries; resource rows keep a concrete type and stable record IDs.
private struct NativeAppNodeView: View {
    let node: NativeAppDefinition.Node
    @Bindable var model: NativeAppRuntime
    var expandsButton = false
    @State private var showingConnections = false

    var body: some View {
        rendered.onChange(of: model.isActive) { _, active in if !active { showingConnections = false } }
    }
    private var label: String { node.textKey.map(model.text) ?? "" }

    private var rendered: AnyView {
        switch node.type {
        case .vstack:
            return AnyView(VStack(alignment: .leading, spacing: 14) {
                ForEach(node.children ?? []) { NativeAppNodeView(node: $0, model: model) }
            }.frame(maxWidth: .infinity, alignment: .topLeading))
        case .hstack:
            return AnyView(HStack(alignment: .top, spacing: 20) {
                ForEach(node.children ?? []) {
                    NativeAppNodeView(node: $0, model: model,
                        expandsButton: node.children?.allSatisfy { $0.type == .button } == true)
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading))
        case .divider: return AnyView(Divider())
        case .text:
            return AnyView(Text(node.binding.map { model.resolve($0).string } ?? label)
                .font(node.style == .title ? .title2.bold() : node.style == .headline ? .headline : .body)
                .foregroundStyle(node.style == .secondary ? Color.secondary : Color.primary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading))
        case .textField:
            return AnyView(TextField(label, text: stringBinding).textFieldStyle(.roundedBorder).accessibilityLabel(label))
        case .textEditor:
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.callout).foregroundStyle(.secondary)
                TextEditor(text: stringBinding).font(.body).frame(minHeight: 180, idealHeight: 240)
                    .padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    .accessibilityLabel(label)
            })
        case .toggle:
            return AnyView(Toggle(label, isOn: Binding(get: {
                model.values[node.stateKey ?? ""] == .bool(true)
            }, set: { model.setValue(.bool($0), key: node.stateKey ?? "") })))
        case .picker:
            return AnyView(Picker(label, selection: stringBinding) {
                ForEach(node.options ?? [], id: \.self) { option in Text(model.text(option)).tag(option) }
            })
        case .filePicker:
            return AnyView(Picker(label, selection: stringBinding) {
                Text(L.string("apps.script.selectFile")).tag("")
                if let current = model.values[node.stateKey ?? ""]?.string, !current.isEmpty,
                   !model.availableFiles.contains(where: { $0.id.uuidString == current }) {
                    Text(L.string("apps.script.fileUnavailable")).tag(current)
                }
                ForEach(model.availableFiles) { file in Text(file.name).tag(file.id.uuidString) }
            }.disabled(model.preview))
        case .resourcePicker:
            return AnyView(HStack {
                Picker(label, selection: Binding<UUID?>(get: { model.selectedResources[node.resource ?? ""]?.id }, set: {
                    model.selectResource(node.resource ?? "", id: $0)
                })) {
                    Text(L.string("apps.capability.selectResource")).tag(UUID?.none)
                    ForEach(model.connections) { connection in
                        Text(connection.name + " · " + connection.database).tag(Optional(connection.id))
                    }
                }.disabled(model.preview)
                Button(L.string("mysql.manage")) { showingConnections = true }.disabled(model.preview || model.isBusy)
            }.sheet(isPresented: $showingConnections, onDismiss: { Task { await model.reloadConnections() } }) {
                if let service = model.mysqlConnector { MySQLConnectionsView(service: service) }
            })
        case .button:
            return AnyView(Button { model.perform(node.action ?? "") } label: {
                Text(label).frame(maxWidth: expandsButton ? .infinity : nil, minHeight: expandsButton ? 28 : nil)
            }
                .disabled(!model.boardActionEnabled(node.action ?? ""))
                .disabled(model.preview && model.definition.actions[node.action ?? ""].map {
                    [.saveKnowledge, .saveRecord, .deleteRecord, .saveFile, .runPython, .callCapability, .sequence].contains($0.type)
                } == true))
        case .list:
            if let query = model.queries[node.source ?? ""] {
                return AnyView(NativeAppResourceList(query: query, preview: model.preview))
            }
            return AnyView(EmptyView())
        case .table:
            return AnyView(NativeAppResultTable(query: model.queries[node.source ?? ""]))
        case .board:
            return AnyView(NativeAppBoardView(boardID: node.board ?? "", model: model))
        }
    }

    private var stringBinding: Binding<String> {
        Binding(get: { model.values[node.stateKey ?? ""]?.string ?? "" },
                set: { model.setValue(.string($0), key: node.stateKey ?? "") })
    }
}

private struct NativeAppResultTable: View {
    let query: NativeAppQueryModel?
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let query, let dataset = query.dataset {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack {
                        ForEach(dataset.columns, id: \.self) { key in
                            Text(L.string("apps.column." + key)).font(.caption.bold()).frame(width: 160, alignment: .leading)
                        }
                    }.padding(6)
                    ForEach(dataset.rows) { row in
                        Button { query.select(row.stableUUID) } label: {
                            HStack {
                                ForEach(dataset.columns, id: \.self) { key in
                                    Text(row.fields[key]?.string ?? "").lineLimit(2).frame(width: 160, alignment: .leading)
                                }
                            }.padding(6).background(query.selectedID == row.stableUUID ? Color.accentColor.opacity(0.12) : .clear)
                        }.buttonStyle(.plain)
                    }
                    if dataset.hasMore { Text(L.string("apps.capability.more")).font(.caption).foregroundStyle(.secondary) }
                }
            } else { Text(L.string("apps.capability.empty")).foregroundStyle(.secondary) }
        }.frame(minHeight: 140, maxHeight: 340)
    }
}

private struct NativeAppResourceList: View {
    @Bindable var query: NativeAppQueryModel
    let preview: Bool

    var body: some View {
        VStack(spacing: 8) {
            if query.items.isEmpty, !query.isLoading {
                ContentUnavailableView(L.string(preview ? "apps.preview.data" : query.source.kind == .records ? "apps.record.empty" : "apps.query.empty"),
                    systemImage: query.source.kind == .records ? "note.text" : "books.vertical")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(query.items) { item in
                            Button { query.select(item.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.headline).lineLimit(2)
                                    Text(item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(query.selectedID == item.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if query.isLoading { ProgressView().controlSize(.small) }
            if let error = query.error { Text(error).font(.caption).foregroundStyle(.red) }
            if query.hasMore { Button(L.string("apps.query.more")) { query.loadMore() }.disabled(query.isLoading) }
        }.frame(minWidth: 180, idealWidth: 260, maxWidth: .infinity, minHeight: 220, maxHeight: 420)
            .padding(8).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct NativeAppPreview: View {
    @State private var model: NativeAppRuntime
    init(definition: NativeAppDefinition, space: AppSpace) {
        _model = State(initialValue: NativeAppRuntime(definition: definition, space: space, preview: true))
    }
    var body: some View {
        NativeAppRenderer(model: model).task { await model.activate() }.onDisappear { model.suspend() }
    }
}
