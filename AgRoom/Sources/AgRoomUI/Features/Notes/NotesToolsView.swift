import SwiftUI
import AgRoomCore

struct NotesToolsView: View {
    enum Page { case operations, mcp, data }
    @Bindable var model: NotesModel
    var page: Page? = nil
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var archiveMode: Bool?
    @State private var storageSummary: String?
    @State private var discarding: NoteCaptureManifest?
    var body: some View {
        VStack(alignment: .leading) {
            if !embedded { HStack { Text(L.string(page == .operations ? "notes.operations" : "notes.tools")).font(.title2); Spacer(); Button(L.string("notes.close")) { dismiss() } } }
            Form {
                if page == nil || page == .operations {
                Section(L.string("notes.pipeline")) {
                    Text(L.string("notes.pipeline.hint")).foregroundStyle(.secondary)
                    Text(L.string("notes.batch.hint")).font(.caption)
                    Button(String(format: L.string("notes.batch.enqueue"), model.batchSelection.count)) { model.enqueueBatch() }.disabled(model.batchSelection.isEmpty || model.busy || model.recording)
                    Button(L.string("notes.batch.resume")) { model.resumeBatch() }.disabled(model.busy || model.recording || !model.workflows.contains(where: { !$0.finished }))
                    Button(L.string("notes.pipeline.text")) { model.enqueueWorkflow(mediaID: nil) }.disabled(model.draft == nil || model.busy || model.recording)
                    ForEach(model.workflows.filter { !$0.finished }) { job in
                        HStack {
                            Text(job.noteID == model.draft?.id ? (model.draft?.title ?? "") : String(job.noteID.uuidString.prefix(8)))
                            Text("\(job.stage) / \(job.effectiveSteps.count)").monospacedDigit()
                            Spacer()
                            Button(L.string("notes.resume")) { model.executeWorkflow(job) }.disabled(model.busy || model.recording)
                        }
                    }
                }
                }
                if page == nil || page == .mcp {
                Section(L.string("notes.mcp")) {
                    Text(L.string("notes.mcp.hint")).font(.caption)
                    Button(L.string("notes.mcp.rotate")) { model.generateMCPToken() }.disabled(model.busy || model.recording)
                    if model.mcpPort == 0 {
                        Button(L.string("notes.mcp.start")) { model.startMCP() }.disabled(model.busy || model.recording)
                    } else {
                        Text("http://127.0.0.1:\(model.mcpPort)/mcp").textSelection(.enabled)
                        Button(L.string("notes.mcp.copy")) { model.copyMCPConfiguration() }
                        Button(L.string("notes.mcp.stop")) { model.stopMCP() }.disabled(model.busy)
                    }
                }
                }
                if page == nil || page == .data {
                Section(L.string("notes.capture.report")) {
                    ForEach(model.captureReports) { report in
                        VStack(alignment: .leading) {
                            Text(report.startedAt, style: .date)
                            Text(String(format: L.string("notes.capture.report.counts"), report.fragments, report.repaired, report.echoReduced))
                            ForEach(report.issues, id: \.self) { Text(L.string("notes.capture.issue." + $0)).foregroundStyle(.orange) }
                        }
                    }
                }
                }
                if page == nil || page == .data {
                Section(L.string("notes.recovery")) {
                    Text(L.string("notes.recovery.hint")).foregroundStyle(.secondary)
                    Button(L.string("notes.recovery.folder")) { model.revealCaptureRecovery() }
                    ForEach(model.recoverableCaptures) { capture in
                        HStack {
                            Text(capture.startedAt, style: .date)
                            Text("\(capture.parts.count)")
                            Spacer()
                            Button(L.string("notes.recover")) { model.recoverCapture(capture) }.disabled(model.busy || model.recording)
                            Button(role: .destructive) { discarding = capture } label: { Image(systemName: "trash") }.disabled(model.busy || model.recording)
                        }
                    }
                }
                }
                if page == nil || page == .data || page == .operations {
                Section(L.string("notes.portability")) {
                    if page == .data {
                        if let storageSummary { Text(storageSummary).font(.caption) }
                        Button(L.string("notes.refresh")) { Task { await loadStorageSummary() } }
                    }
                    if page != .operations {
                    Text(L.string("notes.mirror.hint")).font(.caption)
                    Button(L.string("notes.mirror.choose")) { model.chooseMirror() }.disabled(model.busy || model.recording)
                    Button(L.string("notes.mirror.sync")) { model.syncMirror() }.disabled(model.busy || model.recording || model.localPreferences.mirrorBookmark == nil)
                    Text(String(format: L.string("notes.mirror.written"), model.mirrorWritten)).font(.caption)
                    }
                    Button(L.string("notes.protected.export")) { archiveMode = false }.disabled(model.draft == nil || model.busy || model.recording)
                    Button(L.string("notes.protected.import")) { archiveMode = true }.disabled(model.busy || model.recording)
                    Text(L.string("notes.package.hint")).font(.caption).foregroundStyle(.secondary)
                    Button(L.string("notes.package.export")) { if !embedded { dismiss() }; model.exportPackage() }.disabled(model.draft == nil || model.busy || model.recording)
                    Button(L.string("notes.package.import")) { if !embedded { dismiss() }; model.previewImport(legacy: false) }.disabled(model.busy || model.recording)
                    Button(L.string("notes.legacy.import")) { if !embedded { dismiss() }; model.previewImport(legacy: true) }.disabled(model.busy || model.recording)
                    Button(L.string("notes.legacy.collection")) { if !embedded { dismiss() }; model.previewLegacyCollection() }.disabled(model.busy || model.recording)
                    Text(L.string("notes.legacy.hint")).font(.caption).foregroundStyle(.secondary)
                }
                }
            }.formStyle(.grouped)
            if model.busy { HStack { ProgressView().controlSize(.small); Button(L.string("notes.cancel")) { model.cancel() } } }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(embedded ? 0 : 20).frame(width: embedded ? nil : 620, height: embedded ? nil : 620)
        .sheet(isPresented: Binding(get: { archiveMode != nil }, set: { if !$0 { archiveMode = nil } })) { NotesArchivePasswordView(model: model, importing: archiveMode ?? false) }
        .sheet(item: Binding(get: { embedded ? model.pendingImport : nil }, set: { model.pendingImport = $0 })) { package in NoteImportPreview(model: model, package: package) }
        .task { await model.loadTranscriptionSettings(); model.loadCaptureRecovery(); await model.loadWorkflows(); await model.loadCaptureReports(); await loadStorageSummary() }
        .onChange(of: model.pendingImport?.id) { if model.pendingImport != nil && !embedded { dismiss() } }
        .onChange(of: model.captureEchoReduction) { Task { await model.saveLocalPreferences() } }
        .confirmationDialog(L.string("notes.recovery.discard"), isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible) {
            Button(L.string("notes.delete"), role: .destructive) { if let discarding { model.discardCapture(discarding) }; discarding = nil }
        }
    }
    private func loadStorageSummary() async {
        guard page == .data else { return }
        do {
            guard let store = model.store else { throw NoteStoreError.missing }
            let summary = try await store.storageSummary()
            storageSummary = L.format("notes.settings.storage", summary.notes, summary.media, ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))
        } catch { model.report(error) }
    }
}

struct NoteImportPreview: View {
    @Bindable var model: NotesModel
    let package: NotePackage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("notes.import.preview")).font(.title2)
            Text(package.note.title).font(.headline)
            Text(String(format: L.string("notes.import.count"), package.media.count, package.note.todos.count))
            ScrollView { Text(package.note.markdown).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button(L.string("notes.cancel")) { model.pendingImport = nil; model.protectedPackages = []; dismiss() }
                Spacer()
                Button(L.string("notes.import.confirm")) { model.confirmImport() }.disabled(model.busy)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }.padding(24).frame(width: 680, height: 580)
    }
}
