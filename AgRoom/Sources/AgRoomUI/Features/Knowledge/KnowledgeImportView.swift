import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import AgRoomCore

@MainActor @Observable
final class KnowledgeImportModel {
    struct Row: Identifiable {
        enum State: Equatable { case waiting, extracting, ready, saving, saved, skipped, failed }
        let id: UUID
        let url: URL
        var state: State = .waiting
        var preview: KnowledgeImportPreview?
        var decision: KnowledgeImportDecision = .skip
        var error: String?
    }
    let service: KnowledgeImportService
    let baseID: UUID?
    let folderID: UUID?
    let sourceID: UUID?
    private let jobs: JobCenter
    private let jobHistory: ProductJobRunStore
    private let isCurrentSpace: @MainActor () -> Bool
    var ocr = KnowledgeImportOptions.OCRMode.automatic
    var encoding = "automatic"
    var firstPage = ""
    var lastPage = ""
    private(set) var rows: [Row] = []
    private(set) var working = false
    private(set) var batch: KnowledgeImportBatch?
    private(set) var batches: [KnowledgeImportBatch] = []
    private(set) var activeJobID: UUID?
    var errorText: String?
    var selectedRowID: UUID?
    @ObservationIgnored private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var visible = true

    init(service: KnowledgeImportService, baseID: UUID?, folderID: UUID?, sourceID: UUID? = nil, jobs: JobCenter,
         isCurrentSpace: @escaping @MainActor () -> Bool = { true }) {
        self.service = service; self.baseID = baseID; self.folderID = folderID
        self.sourceID = sourceID; self.isCurrentSpace = isCurrentSpace
        self.jobs = jobs; self.jobHistory = service.makeJobRunStore()
    }
    var options: KnowledgeImportOptions? {
        var value = KnowledgeImportOptions(); value.ocr = ocr; value.encoding = encoding
        if !firstPage.isEmpty { guard let number = Int(firstPage), number > 0 else { return nil }; value.firstPage = number }
        if !lastPage.isEmpty { guard let number = Int(lastPage), number > 0 else { return nil }; value.lastPage = number }
        if let first = value.firstPage, let last = value.lastPage, first > last { return nil }
        return value
    }
    var selected: Row? { rows.first { $0.id == selectedRowID } }
    var canCommit: Bool { !working && visible && isCurrentSpace() && batch?.options == options && rows.contains { $0.state == .ready } }
    var replacesEdits: Bool { rows.contains { $0.state == .ready && $0.decision == .save && $0.preview?.disposition == .conflict } }
    func appear() { if isCurrentSpace() { visible = true } }

    func loadHistory() async {
        do {
            let values = try await service.batches()
            guard visible, isCurrentSpace(), !Task.isCancelled else { return }
            batches = values
        } catch { if visible { errorText = L.actionableError(error, fallbackKey: "knowledge.error.operation") } }
    }

    func prepare(_ urls: [URL]) {
        guard !working, visible, isCurrentSpace(), let options else { errorText = L.string("knowledge.import.error.tooLarge"); return }
        guard !urls.isEmpty, urls.count <= 50, sourceID == nil || urls.count == 1 else { errorText = L.string("knowledge.import.error.tooLarge"); return }
        abandonPending()
        let ticket = UUID(); generation = ticket
        batch = nil
        rows = urls.map { Row(id: UUID(), url: $0) }; selectedRowID = rows.first?.id
        working = true; errorText = nil
        let candidates = rows.map { row -> KnowledgeImportCandidate in
            var candidate = KnowledgeImportCandidate(path: row.url.path, rootPath: row.url.deletingLastPathComponent().path, size: 0,
                supported: KnowledgeDocumentExtractor.supportedExtensions.contains(row.url.pathExtension.lowercased()))
            candidate.id = row.id; return candidate
        }
        startJob(kind: "prepare", ticket: ticket) { [self] context in
            let batch = try await service.beginBatch(candidates: candidates, baseID: baseID, folderID: folderID, options: options)
            try requireCurrent(ticket)
            self.batch = batch
            let ids = rows.map(\.id)
            for (index, id) in ids.enumerated() {
                try requireCurrent(ticket)
                await extract(id, options: options, ticket: ticket)
                context.reportProgress(Double(index + 1) / Double(ids.count))
            }
            try requireCurrent(ticket)
            await loadHistory()
            let failed = rows.filter { $0.state == .failed }.count
            let summary = L.format("knowledge.import.job.previewResult", rows.filter { $0.state == .ready }.count, failed)
            context.reportResult(summary)
            if failed > 0 { throw JobFailure(message: summary) }
        }
    }

    private func extract(_ id: UUID, options: KnowledgeImportOptions, ticket: UUID) async {
        guard accepts(ticket), let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let url = rows[index].url
        rows[index].state = .extracting; rows[index].error = nil
        do {
            try await service.setTaskState(id: id, state: .extracting)
            let prior = rows.filter { $0.id != id }.compactMap(\.preview)
            let preview = try await service.prepare(url: url, options: options, sourceID: sourceID, considering: prior)
            guard accepts(ticket), let current = rows.firstIndex(where: { $0.id == id }) else { return }
            let total = rows.filter { $0.id != id }.reduce(0) { $0 + ($1.preview?.extraction.content.utf8.count ?? 0) }
            guard total + preview.extraction.content.utf8.count <= 16 * 1024 * 1024 else { throw KnowledgeImportError.tooLarge }
            rows[current].preview = preview; rows[current].state = .ready
            rows[current].decision = [.new, .update].contains(preview.disposition) ? .save : .skip
            try await service.setTaskState(id: id, state: .queued)
        } catch {
            guard accepts(ticket), let current = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[current].state = .failed; rows[current].error = L.actionableError(error, fallbackKey: "knowledge.error.operation")
            do { try await service.setTaskState(id: id, state: .failed, error: error as? KnowledgeImportError ?? .unreadable) }
            catch { errorText = L.string("error.database") }
        }
    }

    func retry(_ id: UUID) {
        guard !working, let batch, batch.options == options, visible, isCurrentSpace(),
              rows.contains(where: { $0.id == id && $0.state == .failed }) else { return }
        let ticket = UUID(); generation = ticket; working = true; errorText = nil
        startJob(kind: "retry", ticket: ticket) { [self] context in
            await extract(id, options: batch.options, ticket: ticket)
            try requireCurrent(ticket)
            context.reportProgress(1)
            let ready = rows.first { $0.id == id }?.state == .ready
            let summary = L.format("knowledge.import.job.previewResult", ready ? 1 : 0, ready ? 0 : 1)
            context.reportResult(summary)
            await loadHistory()
            if !ready { throw JobFailure(message: summary) }
        }
    }

    func setDecision(_ decision: KnowledgeImportDecision, id: UUID) {
        guard !working, let index = rows.firstIndex(where: { $0.id == id }), rows[index].state == .ready else { return }
        rows[index].decision = decision
    }

    func commit(onFinished: @escaping @MainActor () -> Void) {
        guard canCommit, let batch else { return }
        let ticket = UUID(); generation = ticket; working = true; errorText = nil
        startJob(kind: "commit", ticket: ticket) { [self] context in
            let selected = rows.filter { $0.state == .ready }
            for (ordinal, row) in selected.enumerated() {
                try requireCurrent(ticket)
                guard let preview = row.preview, let index = rows.firstIndex(where: { $0.id == row.id }) else { continue }
                rows[index].state = .saving
                do {
                    try await service.commit(preview, decision: row.decision, batchID: batch.id, taskID: row.id)
                    try requireCurrent(ticket)
                    if let current = rows.firstIndex(where: { $0.id == row.id }) { rows[current].state = row.decision == .skip ? .skipped : .saved }
                } catch {
                    try requireCurrent(ticket)
                    if let current = rows.firstIndex(where: { $0.id == row.id }) { rows[current].state = .failed; rows[current].error = L.actionableError(error, fallbackKey: "knowledge.error.operation") }
                    do { try await service.setTaskState(id: row.id, state: error as? KnowledgeImportError == .conflict ? .conflict : .failed, error: error as? KnowledgeImportError ?? .unreadable) }
                    catch { errorText = L.string("error.database") }
                }
                context.reportProgress(Double(ordinal + 1) / Double(selected.count))
            }
            try requireCurrent(ticket)
            await loadHistory(); onFinished()
            let ids = Set(selected.map(\.id)), outcomes = rows.filter { ids.contains($0.id) }
            let failed = outcomes.filter { $0.state == .failed }.count
            let summary = L.format("knowledge.import.job.saveResult", outcomes.filter { $0.state == .saved }.count,
                outcomes.filter { $0.state == .skipped }.count, failed)
            context.reportResult(summary)
            if failed > 0 { throw JobFailure(message: summary) }
        }
    }

    private struct JobFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private func requireCurrent(_ ticket: UUID) throws {
        guard accepts(ticket) else { throw CancellationError() }
    }

    private func startJob(kind: String, ticket: UUID,
                          action: @escaping @MainActor @Sendable (JobContext) async throws -> Void) {
        operation = Task { [weak self] in
            guard let self, self.accepts(ticket) else { return }
            defer {
                if self.generation == ticket { self.working = false; self.operation = nil; self.activeJobID = nil }
            }
            let updates = self.jobs.stream(space: self.service.space)
            let id = self.jobs.submit(name: L.string("knowledge.import.job." + kind), kind: "knowledge-import-" + kind,
                space: self.service.space, origin: "knowledge", historyStore: self.jobHistory) { [weak self] context in
                    guard let self else { throw CancellationError() }
                    do {
                        try await self.requireCurrent(ticket)
                        try await action(context)
                        try await self.requireCurrent(ticket)
                    } catch is CancellationError { throw CancellationError() }
                    catch { throw JobFailure(message: await MainActor.run { L.actionableError(error, fallbackKey: "knowledge.error.operation") }) }
                }
            self.activeJobID = id
            let jobs = self.jobs
            defer { jobs.cancel(id: id) }
            await withTaskCancellationHandler {
                for await values in updates {
                    guard self.accepts(ticket) else { break }
                    let job: BackgroundJob?
                    if let value = values.first(where: { $0.id == id }) ?? jobs.snapshot(space: self.service.space).first(where: { $0.id == id }) { job = value }
                    else {
                        do { job = try await self.jobHistory.run(id: id) }
                        catch { self.errorText = L.string("error.database"); break }
                    }
                    guard self.accepts(ticket) else { break }
                    guard let job else {
                        self.errorText = L.string("product.tasks.missing")
                        await self.settleUnfinishedRows(cancelled: false, ticket: ticket)
                        break
                    }
                    guard job.state.isFinished || job.state == .awaitingSave else { continue }
                    if job.state == .awaitingSave { self.errorText = L.string("jobs.history.failed") }
                    else if job.state == .interrupted { self.errorText = L.string("product.task.recoveryRequired") }
                    else if job.state == .failed { self.errorText = self.errorText ?? job.errorText ?? L.string("error.database") }
                    if job.state == .failed || job.state == .cancelled || job.state == .awaitingSave || job.state == .interrupted {
                        await self.settleUnfinishedRows(cancelled: job.state == .cancelled, ticket: ticket)
                    }
                    await self.loadHistory()
                    break
                }
            } onCancel: { jobs.cancel(id: id) }
        }
    }

    private func settleUnfinishedRows(cancelled: Bool, ticket: UUID) async {
        let receipts: [UUID: KnowledgeImportTask]
        do {
            if let batch {
                receipts = Dictionary(uniqueKeysWithValues: try await service.tasks(batchID: batch.id).map { ($0.id, $0) })
            } else { receipts = [:] }
        }
        catch { if accepts(ticket) { errorText = L.string("error.database") }; return }
        guard accepts(ticket) else { return }
        let message = cancelled ? L.string("jobs.state.cancelled") : errorText ?? L.string("error.database")
        var unfinished: [UUID] = []
        for index in rows.indices {
            let receipt = receipts[rows[index].id]
            if receipt?.state == .committed { rows[index].state = .saved }
            else if receipt?.state == .skipped { rows[index].state = .skipped }
            else if [.waiting, .extracting, .saving].contains(rows[index].state) || cancelled && rows[index].state == .ready {
                rows[index].state = .failed; rows[index].error = message
                unfinished.append(rows[index].id)
            }
        }
        for id in unfinished {
            guard accepts(ticket) else { return }
            do { try await service.setTaskState(id: id, state: cancelled ? .cancelled : .failed) }
            catch KnowledgeImportError.targetMissing {}
            catch { if accepts(ticket) { errorText = L.string("error.database") } }
        }
    }

    func forget(_ id: UUID) async {
        guard !working else { return }
        do {
            try await service.forgetBatch(id)
            if batch?.id == id { rows = []; batch = nil; selectedRowID = nil }
            await loadHistory()
        }
        catch { errorText = L.actionableError(error, fallbackKey: "knowledge.error.operation") }
    }

    private func accepts(_ ticket: UUID) -> Bool { visible && isCurrentSpace() && generation == ticket && !Task.isCancelled }
    private func abandonPending() {
        let pending = rows.filter { [.waiting, .extracting, .ready, .saving].contains($0.state) }.map(\.id)
        let service = service
        Task {
            for id in pending {
                do { try await service.setTaskState(id: id, state: .cancelled) }
                catch KnowledgeImportError.targetMissing { continue }
                catch { HubLogger.shared.error("Knowledge import cancellation receipt could not be saved") }
            }
        }
    }
    func cancel() {
        visible = false; generation = UUID(); operation?.cancel(); operation = nil
        if let activeJobID { jobs.cancel(id: activeJobID) }
        activeJobID = nil; working = false; abandonPending()
    }
}

struct KnowledgeImportSheet: View {
    @State private var model: KnowledgeImportModel
    let onFinished: @MainActor () -> Void
    private let chooseSources: (@MainActor () async -> [URL]?)?
    @Environment(\.dismiss) private var dismiss
    @State private var panel: NSOpenPanel?
    @State private var confirmReplacement = false
    @State private var forgetBatchID: UUID?

    init(model: KnowledgeImportModel, chooseSources: (@MainActor () async -> [URL]?)? = nil,
         onFinished: @escaping @MainActor () -> Void) {
        _model = State(initialValue: model); self.onFinished = onFinished; self.chooseSources = chooseSources
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("knowledge.import.preview.title")).font(.title2.bold())
            Text(L.string("knowledge.import.preview.help")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(L.string("knowledge.import.choose")) { chooseFiles() }.keyboardShortcut("o", modifiers: .command).disabled(model.working || panel != nil)
                if !model.rows.isEmpty {
                    Button(L.string("knowledge.import.reextract")) { model.prepare(model.rows.map(\.url)) }.disabled(model.working)
                }
                Spacer()
                if model.working { ProgressView().controlSize(.small); Text(L.string("knowledge.import.working")).font(.caption) }
            }
            DisclosureGroup(L.string("knowledge.import.options")) {
                HStack {
                    Picker(L.string("knowledge.import.ocr"), selection: $model.ocr) {
                        ForEach(KnowledgeImportOptions.OCRMode.allCases, id: \.self) { Text(L.string("knowledge.import.ocr.\($0.rawValue)")).tag($0) }
                    }
                    Picker(L.string("knowledge.import.encoding"), selection: $model.encoding) {
                        Text(L.string("knowledge.import.encoding.automatic")).tag("automatic")
                        Text("UTF-8").tag("utf8"); Text("UTF-16").tag("utf16")
                    }
                    TextField(L.string("knowledge.import.firstPage"), text: $model.firstPage).frame(width: 100)
                    TextField(L.string("knowledge.import.lastPage"), text: $model.lastPage).frame(width: 100)
                }.disabled(model.working)
                Text(L.string("knowledge.import.limits")).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.rows) { row in rowView(row) }
                    }
                }.frame(width: 270)
                Divider()
                if let row = model.selected, let preview = row.preview {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(preview.extraction.title).font(.headline)
                        Text(L.format("knowledge.import.extracted", preview.extraction.blocks.count, preview.extraction.content.count)).font(.caption).foregroundStyle(.secondary)
                        if !preview.extraction.warnings.isEmpty {
                            Text(L.string("knowledge.import.warnings")).font(.caption).foregroundStyle(.orange)
                            Text(preview.extraction.warnings.map(warningLabel).joined(separator: "\n")).font(.caption).textSelection(.enabled)
                        }
                        HStack(alignment: .top) {
                            if let existing = preview.existingItem, preview.disposition == .conflict || preview.disposition == .update {
                                VStack(alignment: .leading) {
                                    Text(L.string("knowledge.import.existing")).font(.caption.bold())
                                    KnowledgeImportText(text: existing.content, identity: preview.id.uuidString + "old")
                                }
                            }
                            VStack(alignment: .leading) {
                                Text(L.string("knowledge.import.extractedBody")).font(.caption.bold())
                                KnowledgeImportText(text: preview.extraction.content, identity: preview.id.uuidString)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Text(L.string("knowledge.import.preview.empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minHeight: 300)
            DisclosureGroup(L.string("knowledge.import.history")) {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(model.batches) { batch in
                            KnowledgeImportBatchRow(batch: batch, service: model.service, onChoose: chooseFiles,
                                onForget: { forgetBatchID = batch.id })
                        }
                    }
                }.frame(maxHeight: 130)
            }
            if let error = model.errorText { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(L.string("knowledge.import.retention")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L.string("common.close")) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.string("knowledge.import.commit")) {
                    if model.replacesEdits { confirmReplacement = true } else { model.commit(onFinished: onFinished) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!model.canCommit)
            }
        }.padding(20).frame(minWidth: 800, idealWidth: 940, minHeight: 600, idealHeight: 700)
        .onAppear { model.appear() }
        .task { await model.loadHistory() }
        .confirmationDialog(L.string("knowledge.import.conflict.title"), isPresented: $confirmReplacement, titleVisibility: .visible) {
            Button(L.string("knowledge.import.conflict.apply"), role: .destructive) { model.commit(onFinished: onFinished) }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("knowledge.import.conflict.help")) }
        .confirmationDialog(L.string("knowledge.import.history.clear"), isPresented: Binding(get: { forgetBatchID != nil }, set: { if !$0 { forgetBatchID = nil } }), titleVisibility: .visible) {
            Button(L.string("common.delete"), role: .destructive) { if let id = forgetBatchID { Task { await model.forget(id) } }; forgetBatchID = nil }
            Button(L.string("common.cancel"), role: .cancel) { forgetBatchID = nil }
        } message: { Text(L.string("knowledge.import.history.clear.help")) }
        .onDisappear {
            model.cancel()
            if let panel, panel.isVisible { panel.cancel(nil) }
            panel = nil
        }
    }

    private func rowView(_ row: KnowledgeImportModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { model.selectedRowID = row.id } label: { Text(row.url.lastPathComponent).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).help(row.url.path)
            Text(row.url.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
            if let preview = row.preview { Text(L.string("knowledge.import.disposition.\(preview.disposition.rawValue)")).font(.caption).foregroundStyle(.secondary) }
            if row.state == .ready {
                Picker(L.string("knowledge.import.action"), selection: Binding(get: { row.decision }, set: { model.setDecision($0, id: row.id) })) {
                    Text(L.string("knowledge.import.decision.skip")).tag(KnowledgeImportDecision.skip)
                    if row.preview?.disposition != .duplicate { Text(L.string(row.preview?.source == nil ? "knowledge.import.decision.add" : "knowledge.import.decision.update")).tag(KnowledgeImportDecision.save) }
                    Text(L.string("knowledge.import.decision.copy")).tag(KnowledgeImportDecision.copy)
                }.font(.caption).disabled(model.working)
            } else {
                Text(L.string("knowledge.import.row.\(stateKey(row.state))")).font(.caption).foregroundStyle(.secondary)
            }
            if let error = row.error { Text(error).font(.caption).foregroundStyle(.red) }
            if row.state == .failed { Button(L.string("common.retry")) { model.retry(row.id) }.controlSize(.small).disabled(model.working || model.batch?.options != model.options) }
        }.padding(9).background(model.selectedRowID == row.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
    private func stateKey(_ state: KnowledgeImportModel.Row.State) -> String {
        switch state { case .waiting: "waiting"; case .extracting: "extracting"; case .ready: "ready"; case .saving: "saving"; case .saved: "saved"; case .skipped: "skipped"; case .failed: "failed" }
    }
    private func warningLabel(_ value: String) -> String {
        let pieces = value.split(separator: ":")
        let page = pieces.count > 1 ? Int(pieces[1]) ?? 0 : 0
        switch pieces.first {
        case "ocr": return page == 0 ? L.string("knowledge.import.warning.ocrImage") : L.format("knowledge.import.warning.ocr", page)
        case "blank": return L.format("knowledge.import.warning.blank", page)
        case "noTextLayer": return L.format("knowledge.import.warning.noTextLayer", page)
        default: return L.string("knowledge.import.warnings")
        }
    }
    private func chooseFiles() {
        guard panel == nil, !model.working else { return }
        if let chooseSources {
            Task { if let urls = await chooseSources() { model.prepare(urls) } }
            return
        }
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = model.sourceID == nil
        picker.canChooseDirectories = false
        picker.allowedContentTypes = KnowledgeDocumentExtractor.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel = picker
        picker.begin { response in
            guard panel === picker else { return }
            panel = nil
            if response == .OK { model.prepare(picker.urls) }
        }
    }
}

struct KnowledgeImportText: View {
    let text: String
    let identity: String
    @AppStorage(ReadingTypography.preferenceKey) private var pointSize = ReadingTypography.defaultSize
    var body: some View {
        KnowledgeImportNativeText(text: text, identity: identity, pointSize: ReadingTypography(pointSize: pointSize).bodySize)
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct KnowledgeImportNativeText: NSViewRepresentable {
    let text: String
    let identity: String
    let pointSize: CGFloat
    final class Coordinator { var identity: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = NSTextView()
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.drawsBackground = false; editor.textColor = .labelColor
        editor.font = .systemFont(ofSize: pointSize)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? NSTextView else { return }
        if editor.font?.pointSize != pointSize { editor.font = .systemFont(ofSize: pointSize) }
        guard context.coordinator.identity != identity else { return }
        editor.string = text; editor.setSelectedRange(NSRange(location: 0, length: 0))
        context.coordinator.identity = identity
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { (view.documentView as? NSTextView)?.string = "" }
}

private struct KnowledgeImportBatchRow: View {
    let batch: KnowledgeImportBatch
    let service: KnowledgeImportService
    let onChoose: () -> Void
    let onForget: () -> Void
    @State private var tasks: [KnowledgeImportTask] = []
    @State private var errorText: String?
    var body: some View {
        HStack {
            Text(batch.createdAt, format: .dateTime.month().day().hour().minute())
            if let errorText { Text(errorText).foregroundStyle(.red) }
            else { Text(L.format("knowledge.import.batch.summary", tasks.filter { $0.state == .committed }.count, tasks.filter { $0.state == .skipped }.count, tasks.filter { !$0.isFinished }.count)) }
            Spacer()
            if tasks.contains(where: { !$0.isFinished }) { Button(L.string("knowledge.import.reselect"), action: onChoose) }
            Button(L.string("knowledge.import.history.clear"), action: onForget)
        }.font(.caption).controlSize(.small)
        .task(id: batch.id) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: KnowledgeImportService.didChange)) { note in
            if note.object as? String == service.space.rawValue { Task { await load() } }
        }
    }
    private func load() async {
        do { let values = try await service.tasks(batchID: batch.id); if !Task.isCancelled { tasks = values; errorText = nil } }
        catch { if !Task.isCancelled { errorText = L.string("error.database") } }
    }
}
