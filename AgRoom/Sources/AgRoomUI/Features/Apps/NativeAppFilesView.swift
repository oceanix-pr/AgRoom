import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AgRoomCore

@MainActor @Observable
final class NativeAppFilesModel {
    let workspace: NativeAppWorkspace
    let space: AppSpace
    private(set) var files: [NativeAppFile] = []
    private(set) var busy = false
    private(set) var pending: NativeAppPendingCommand?
    var error: String?
    private var task: Task<Void, Never>?
    private var engine: DispatcherEngine?
    private var active = true
    private var generation = UUID()

    init(workspace: NativeAppWorkspace, space: AppSpace) { self.workspace = workspace; self.space = space }

    func reload() async {
        let request = generation
        do {
            let files = try await workspace.files()
            guard active, request == generation, !Task.isCancelled else { return }
            self.files = files
        } catch { if active, request == generation { self.error = L.errorDescription(error) } }
    }

    func importFile(_ url: URL, recordID: UUID?) {
        guard active, !busy else { return }
        busy = true; error = nil
        let request = generation
        task = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await NativeAppWorkspace.readSelectedFile(url)
                try Task.checkCancellation()
                guard active, request == generation else { return }
                let command = try workspace.makeSaveFileCommand(space: space, name: url.lastPathComponent, data: data, recordID: recordID)
                let description = L.format("apps.files.confirm.import", ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                try await prepare(command, title: url.lastPathComponent, content: description, titleKey: "apps.files.import")
            } catch {
                guard active, request == generation, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); busy = false
            }
        }
    }

    func delete(_ file: NativeAppFile) {
        guard active, !busy else { return }
        busy = true; error = nil
        let request = generation
        task = Task {
            do {
                try await prepare(workspace.makeDeleteFileCommand(space: space, file: file),
                    title: file.name, content: L.string("apps.files.confirm.delete"), titleKey: "apps.files.delete")
            } catch {
                guard active, request == generation, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); busy = false
            }
        }
    }

    private func prepare(_ command: (DispatcherEngine, ToolCallRaw), title: String, content: String, titleKey: String) async throws {
        let request = generation
        engine = command.0
        let outcome = try await command.0.executeCommand(command.1)
        try Task.checkCancellation()
        guard active, generation == request else { return }
        if case .needsConfirmation = outcome, let id = command.0.pendingApprovalID {
            pending = NativeAppPendingCommand(id: id, engine: command.0, title: title, content: content, titleKey: titleKey)
        } else { await finish(outcome) }
    }

    func decide(_ command: NativeAppPendingCommand, approved: Bool) {
        guard active, pending?.id == command.id else { return }
        pending = nil
        let request = generation
        task = Task {
            do {
                let outcome = try await command.engine.resume(.confirmed(approvalID: command.id, approved: approved, alwaysAllow: false, persistRule: false))
                try Task.checkCancellation()
                guard active, generation == request else { return }
                if approved { await finish(outcome) }
                else { busy = false; engine = nil }
            } catch {
                guard active, generation == request, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); busy = false; engine = nil
            }
        }
    }

    private func finish(_ outcome: DispatcherOutcome) async {
        busy = false; engine = nil
        if case .finished(_, _, let trace, _, _, _, _) = outcome, trace.last?.succeeded == true { await reload() }
        else { error = L.string("apps.command.failed") }
    }

    func export(_ file: NativeAppFile, to url: URL) {
        guard active, !busy else { return }
        busy = true; error = nil
        let request = generation
        task = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await workspace.fileData(id: file.id)
                try Task.checkCancellation()
                guard active, request == generation else { return }
                try await Task.detached { try data.write(to: url, options: .atomic) }.value
                guard active, request == generation else { return }
                busy = false
            } catch {
                guard active, request == generation, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); busy = false
            }
        }
    }

    func suspend() {
        active = false; generation = UUID()
        engine?.revokeTaskAuthorization(); engine = nil
        task?.cancel(); task = nil; pending = nil; busy = false
    }
}

struct NativeAppFilesView: View {
    @State private var model: NativeAppFilesModel
    let recordID: UUID?
    @State private var attachToRecord = false
    @Environment(\.dismiss) private var dismiss

    init(model: NativeAppFilesModel, recordID: UUID?) {
        _model = State(initialValue: model)
        self.recordID = recordID
    }

    var body: some View {
        VStack(spacing: 0) {
            if let command = model.pending {
                NativeAppConfirmationView(command: command, space: model.space) { model.decide(command, approved: $0) }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(L.string("apps.files.title"), systemImage: "folder").font(.title2)
                        Spacer()
                        Text(L.string(model.space.nameKey)).foregroundStyle(model.space.tint)
                    }
                    Text(L.string("apps.files.description")).font(.callout).foregroundStyle(.secondary)
                    if recordID != nil { Toggle(L.string("apps.files.attach"), isOn: $attachToRecord).disabled(model.busy) }
                    if model.files.isEmpty {
                        ContentUnavailableView(L.string("apps.files.empty"), systemImage: "doc")
                    } else {
                        List(model.files) { file in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.name).lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if file.recordID != nil { Text(L.string("apps.files.attached")).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button(L.string("apps.files.export")) { export(file) }
                                Button(L.string("apps.files.delete"), role: .destructive) { model.delete(file) }
                            }.padding(.vertical, 4)
                        }.disabled(model.busy)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                    HStack {
                        if model.busy { ProgressView().controlSize(.small) }
                        Button(L.string("apps.files.import"), systemImage: "square.and.arrow.down") { importFile() }.disabled(model.busy)
                        Spacer()
                        Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }.padding(20).frame(width: 660, height: 480)
            }
        }
        .task { await model.reload() }
        .onDisappear { model.suspend() }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importFile(url, recordID: attachToRecord ? recordID : nil)
    }

    private func export(_ file: NativeAppFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(file, to: url)
    }
}

struct NativeAppConfirmationView: View {
    let command: NativeAppPendingCommand
    let space: AppSpace
    let decide: (Bool) -> Void
    var authorizeVersion: (() -> Void)? = nil
    private var approvalToolName: String {
        if case .capability = command.effect { return "nativeapp_host_call" }
        return "nativeapp_python_run"
    }
    var body: some View {
        if command.versionApproval != nil, let authorizeVersion {
            VStack(alignment: .leading, spacing: 14) {
                Label(L.string("apps.script.authorization.title"), systemImage: "hand.raised").font(.headline)
                Text(command.title).font(.title3)
                Text(L.string(space.nameKey)).foregroundStyle(space.tint)
                Text(L.string("apps.script.authorization.scope"))
                Text(L.string("apps.script.authorization.boundary")).font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(command.content).font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(L.string("common.cancel")) { decide(false) }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L.string("chat.confirm.approve_once")) { decide(true) }
                    Button(L.string("apps.script.authorization.grantRun"), action: authorizeVersion)
                        .buttonStyle(.borderedProminent)
                }
            }.padding(20).frame(width: 720, height: 650)
        } else if let presentation = command.presentation {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(command.title).font(.title3)
                    Text(L.string(space.nameKey)).foregroundStyle(space.tint)
                    ScriptApprovalCard(pending: PendingConfirmation(messageId: command.id, toolName: approvalToolName,
                        argumentsDisplay: command.content, requirement: .init(kind: .hard, scope: .tool), approvalID: command.id),
                        presentation: presentation, onDecision: { decide($0.approved) })
                }.padding(16)
            }.frame(width: 680, height: 620)
        } else {
        VStack(alignment: .leading, spacing: 14) {
            Label(L.string(command.titleKey), systemImage: "hand.raised").font(.headline)
            Text(L.string(space.nameKey)).foregroundStyle(space.tint)
            Text(command.title).font(.title3).textSelection(.enabled)
            ScrollView { Text(command.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Spacer()
                Button(L.string("common.cancel")) { decide(false) }.keyboardShortcut(.cancelAction)
                Button(L.string(command.titleKey)) { decide(true) }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 560, height: 420)
        }
    }
}
