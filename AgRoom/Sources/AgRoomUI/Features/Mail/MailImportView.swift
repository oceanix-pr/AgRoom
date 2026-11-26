import AppKit
import Observation
import SwiftUI
import AgRoomCore

@MainActor @Observable
final class MailImportModel: Identifiable {
    let id = UUID()
    let space: AppSpace
    private let hub: Hub
    var destinationID: UUID? { didSet { if destinationID != oldValue { scheduleMapping() } } }
    var archiveName = L.string("mail.import.archiveDefault") { didSet { if archiveName != oldValue { scheduleMapping() } } }
    private(set) var archives: [MailAccount] = []
    private(set) var preview: MailImportIndexedPreview?
    private(set) var batch: MailImportBatch?
    private(set) var history: [MailImportBatch] = []
    private(set) var busy = false
    private(set) var progress = 0
    private(set) var writeTotal = 0
    private(set) var readProgress: MailImportReadProgress?
    private(set) var resumeReview: MailImportResumeReview?
    private var resumingBatch: MailImportBatch?
    private(set) var error: String?
    private(set) var undoPlan: MailImportUndoPlan?
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var inspection: MailImportInspectionModel?
    private(set) var mboxVariant = MailMboxVariant.automatic
    private(set) var mappingReview: MailImportMappingReview?
    private(set) var mappingRules: [String: MailImportFolderRule] = [:]
    private(set) var mappingTargets: MailImportMappingTargets?
    private(set) var mappingError: String?
    private(set) var mappingBusy = false
    var resultStatusFilter: MailImportResult.Status?
    var resultErrorFilter: MailImportError?
    var folderFilter: String?
    var after: Date?
    var before: Date?
    private var task: Task<Void, Never>?
    private var panel: NSSavePanel?
    private var operation = UUID()
    private var previewRevision = UUID()
    private var lastSourceURLs: [URL] = []
    private var scopedSourceURLs: [URL] = []
    private var closed = false
    private var mappingTask: Task<Void, Never>?
    private var mappingRevision = UUID()
    var chooseFiles: @MainActor (NSSavePanel) async -> ArtifactExportChoice = { await ArtifactExportChoice.choose($0) }
    var onImported: @MainActor (UUID) async -> Void = { _ in }
    var onRevealMessage: @MainActor (UUID) async -> Bool = { _ in false }
    var onRevealBatch: @MainActor (MailImportBatchContext) async -> Bool = { _ in false }
    var visibleResults: [MailImportResult] {
        (batch?.results ?? []).filter { (resultStatusFilter == nil || $0.status == resultStatusFilter) && (resultErrorFilter == nil || $0.error == resultErrorFilter) }
    }
    var resultErrors: [MailImportError] {
        Array(Set(batch?.results.compactMap { $0.error?.rawValue } ?? [])).sorted().compactMap(MailImportError.init(rawValue:))
    }
    func failureCount(_ error: MailImportError) -> Int { batch?.results.filter { $0.error == error }.count ?? 0 }
    var requiresMboxChoice: Bool { preview?.failures.contains { $0.error == .variantRequired } == true }

    func setMboxVariant(_ value: MailMboxVariant) {
        guard !busy, !closed, value != mboxVariant else { return }
        mboxVariant = value
        if !lastSourceURLs.isEmpty { readFiles(lastSourceURLs, resuming: resumingBatch) }
    }

    func inspectCandidate(_ id: UUID) {
        guard !busy, let preview, let candidate = preview.candidates.first(where: { $0.id == id }) else { return }
        dismissInspection()
        inspection = MailImportInspectionModel(readSource: {
            let original = try await preview.access.original(candidate.id)
            return .init(data: original.data, caption: candidate.source)
        })
    }

    func inspectDuplicate(_ id: UUID) {
        guard !busy, let preview, let match = preview.duplicateMatches[id] else { return }
        switch match {
        case .candidate(let original): inspectCandidate(original)
        case .existing:
            guard let archiveID = destinationID, let candidate = preview.candidates.first(where: { $0.id == id }) else { return }
            let hub = hub, space = space
            let resolve: @MainActor () async throws -> MailImportResolvedMessage = {
                guard let mail = hub.makeMailService(for: space) else { throw MailImportError.changed }
                return try await mail.importDuplicate(candidate: candidate, archiveID: archiveID)
            }
            openInspection(resolve)
        }
    }

    func inspectResult(_ id: UUID) {
        guard !busy, let batch else { return }
        let hub = hub, space = space, batchID = batch.id, archiveID = batch.accountID
        openInspection {
            guard let mail = hub.makeMailService(for: space) else { throw MailImportError.changed }
            return try await mail.importResultMessage(batchID: batchID, archiveID: archiveID, itemID: id)
        }
    }

    private func openInspection(_ resolve: @escaping @MainActor () async throws -> MailImportResolvedMessage) {
        dismissInspection()
        inspection = MailImportInspectionModel(readSource: {
            let source = try await resolve()
            return .init(data: source.data, caption: source.archiveName + " · " + source.folder.displayName)
        }, revealSource: { [weak self] in
            let source = try await resolve()
            try Task.checkCancellation()
            guard let self, await self.onRevealMessage(source.message.id) else { throw MailImportError.changed }
        })
    }

    func dismissInspection() { inspection?.cancel(); inspection = nil }

    func canInspectResult(_ result: MailImportResult) -> Bool {
        guard let id = result.messageID, batch?.undo?.removed.contains(id) != true else { return false }
        return result.status == .imported || (result.status == .duplicate && result.originalIdentity != nil)
    }

    func revealBatch() {
        guard !busy, let batch else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                guard let mail = hub.makeMailService(for: space) else { throw MailImportError.changed }
                let context = try await mail.importBatchContext(batchID: batch.id, archiveID: batch.accountID)
                try Task.checkCancellation()
                guard await onRevealBatch(context) else { throw MailImportError.changed }
            } catch is CancellationError { }
            catch { self.error = MailErrorText.message(for: error) }
        }
    }

    var visibleCandidates: [MailImportMetadata] {
        (preview?.candidates ?? []).filter { item in
            (folderFilter.map { item.folder == $0 } ?? true)
                && (after.map { cutoff in item.envelope.date.map { $0 >= cutoff } ?? false } ?? true)
                && (before.map { cutoff in item.envelope.date.map { $0 < cutoff } ?? false } ?? true)
        }
    }

    var sourceFolders: [String] { Array(Set(preview?.candidates.map(\.folder) ?? [])).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var selectedCandidates: [MailImportMetadata] { (preview?.candidates ?? []).filter { selectedIDs.contains($0.id) } }
    var mappingSources: [MailImportMappingSource] { selectedPreview.map { MailImportMappingSource.summarize($0.candidates) } ?? [] }
    var canStart: Bool { !busy && !closed && !mappingBusy && mappingReview != nil && !selectedCandidates.isEmpty }
    private var selectedPreview: MailImportIndexedPreview? {
        guard var preview else { return nil }
        preview.candidates = selectedCandidates
        preview.duplicates.formIntersection(selectedIDs)
        preview.byteCount = preview.candidates.reduce(0) { $0 + Int64($1.byteCount) }
        return preview
    }

    func setMappingRule(_ source: String, rule: MailImportFolderRule) {
        guard !closed, !busy else { return }
        mappingRules[source] = rule
        scheduleMapping()
    }

    private func invalidateMapping() {
        mappingTask?.cancel(); mappingTask = nil; mappingRevision = UUID()
        mappingReview = nil; mappingError = nil; mappingBusy = false; mappingTargets = nil
    }

    private func scheduleMapping() {
        invalidateMapping()
        guard !closed, !busy, preview != nil, batch == nil else { return }
        mappingBusy = true
        let revision = mappingRevision
        mappingTask = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await rebuildMapping(revision: revision)
            if mappingRevision == revision { mappingTask = nil }
        }
    }

    func refreshMapping() async {
        invalidateMapping()
        guard !closed, preview != nil, batch == nil else { return }
        mappingBusy = true
        await rebuildMapping(revision: mappingRevision)
    }

    private func rebuildMapping(revision: UUID) async {
        guard !closed, let selected = selectedPreview, !selected.candidates.isEmpty else {
            if mappingRevision == revision { mappingBusy = false }
            return
        }
        let archiveID = destinationID, rules = mappingRules
        let draft = MailImportArchiveDraft(name: archiveName, inbox: L.string("mail.folder.inbox"),
            trash: L.string("mail.folder.trash"), archive: L.string("mail.folder.archive"))
        defer { if mappingRevision == revision { mappingBusy = false } }
        do {
            guard let mail = hub.makeMailService(for: space) else { throw MailImportError.changed }
            let targets: MailImportMappingTargets?
            if let archiveID { targets = try await mail.importMappingTargets(archiveID: archiveID) } else { targets = nil }
            guard !closed, mappingRevision == revision, !Task.isCancelled else { return }
            // Choices remain editable when the current rule is invalid or stale.
            mappingTargets = targets
            let reviewed = try await mail.reviewImportMapping(selected, archiveID: archiveID, draft: draft, rules: rules)
            guard !closed, mappingRevision == revision, !Task.isCancelled else { return }
            mappingReview = reviewed
        } catch is CancellationError { }
        catch { if !closed, mappingRevision == revision { mappingError = MailErrorText.message(for: error) } }
    }
    var selectedByteCount: Int64 { selectedCandidates.reduce(0) { $0 + Int64($1.byteCount) } }
    var selectedDates: ClosedRange<Date>? {
        let dates = selectedCandidates.compactMap(\.envelope.date)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return first...last
    }

    func setSelected(_ id: UUID, selected: Bool) {
        guard !busy, preview?.candidates.contains(where: { $0.id == id }) == true else { return }
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        scheduleMapping()
    }

    func selectVisible(_ selected: Bool) {
        guard !busy else { return }
        let visible = Set(visibleCandidates.map(\.id))
        if selected { selectedIDs.formUnion(visible) } else { selectedIDs.subtract(visible) }
        scheduleMapping()
    }

    init(hub: Hub, space: AppSpace, archiveID: UUID? = nil) {
        self.hub = hub; self.space = space; self.destinationID = archiveID
    }

    func load() async {
        guard !closed else { return }
        do {
            let values = try await hub.makeMailAccountService(for: space)?.getAll().filter(\.isLocalArchive) ?? []
            guard !closed else { return }
            archives = values
            if let destinationID, !archives.contains(where: { $0.id == destinationID }) { self.destinationID = nil }
            await updateDestination()
        } catch { self.error = MailErrorText.message(for: error) }
    }

    func updateDestination() async {
        guard !closed else { return }
        let id = destinationID
        let revision = previewRevision
        do {
            guard let mail = hub.makeMailService(for: space) else { throw MailSyncError.accountNotFound }
            let revised: MailImportIndexedPreview?
            if let preview { revised = try await mail.importPreview(preview, archiveID: id) } else { revised = nil }
            let history: [MailImportBatch]
            if let id { history = try await mail.importBatches(archiveID: id) } else { history = [] }
            guard !closed, id == destinationID, revision == previewRevision, !Task.isCancelled else { return }
            if let revised { preview = revised }
            self.history = history
            await refreshMapping()
        } catch { self.error = MailErrorText.message(for: error) }
    }

    func choose(resuming: MailImportBatch? = nil) {
        guard !busy, !closed else { return }
        resumingBatch = resuming
        let token = UUID(); operation = token; error = nil; progress = 0
        busy = true
        task = Task {
            defer { if operation == token { busy = false; task = nil; panel = nil } }
            let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = true
            picker.allowsMultipleSelection = true; picker.treatsFilePackagesAsDirectories = true
            picker.title = L.string("mail.import.choose")
            panel = picker
            let choice = await chooseFiles(picker)
            guard operation == token, !Task.isCancelled else { return }
            if case .failed = choice { error = MailErrorText.message(for: MailImportError.unreadable); return }
            guard case .selected(let selected) = choice else { return }
            let urls = picker.urls.isEmpty ? [selected] : picker.urls
            resetPreviewForRead(urls)
            await readFiles(urls, token: token)
        }
    }

    var canPrepareResume: Bool {
        batch.map { $0.resumeManifest != nil && $0.undo == nil && $0.results.contains { $0.status == .failed || $0.status == .unprocessed } } ?? false
    }

    func chooseResumeSources() {
        guard !busy, !closed, canPrepareResume, let batch else { return }
        destinationID = batch.accountID; choose(resuming: batch)
    }

    func dismissResume() { resumeReview = nil; resumingBatch = nil }

    func confirmResume() {
        guard !busy, !closed, let reviewed = resumeReview, reviewed.canResume else { return }
        busy = true; progress = 0; readProgress = nil; error = nil
        writeTotal = reviewed.resumableCount; resultErrorFilter = nil
        let token = UUID(); operation = token
        task = Task {
            defer { if operation == token { busy = false; task = nil } }
            do {
                guard let mail = hub.makeMailService(for: space) else { throw MailImportError.changed }
                let completed = try await mail.resumeImport(reviewed) { done, _ in
                    await MainActor.run { if self.operation == token { self.progress = done } }
                }
                guard !closed, operation == token else { return }
                resumeReview = nil; resumingBatch = nil; batch = completed
                await onImported(completed.accountID)
                guard !closed, operation == token else { return }
                await load()
            } catch is CancellationError { }
            catch { if !closed, operation == token { self.error = MailErrorText.message(for: error) } }
        }
    }

    func readFiles(_ urls: [URL], resuming: MailImportBatch? = nil) {
        guard !busy, !closed, !urls.isEmpty else { return }
        resumingBatch = resuming
        let token = UUID(); operation = token; busy = true; error = nil; progress = 0
        resetPreviewForRead(urls)
        task = Task {
            defer { if operation == token { busy = false; task = nil } }
            await readFiles(urls, token: token)
        }
    }

    private func resetPreviewForRead(_ urls: [URL]) {
        releaseSources()
        lastSourceURLs = urls
        previewRevision = UUID(); preview = nil; batch = nil; undoPlan = nil
        selectedIDs = []; folderFilter = nil; after = nil; before = nil
        mappingRules = [:]; invalidateMapping()
        readProgress = nil; resumeReview = nil; resultErrorFilter = nil
    }

    private func releaseSources() {
        if let access = preview?.access { Task { await access.close() } }
        scopedSourceURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedSourceURLs = []
    }

    private func readFiles(_ urls: [URL], token: UUID) async {
        guard !closed, operation == token else { return }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        scopedSourceURLs = scoped
        defer {
            if operation == token, preview == nil {
                scopedSourceURLs.forEach { $0.stopAccessingSecurityScopedResource() }; scopedSourceURLs = []
            }
        }
        let variant = mboxVariant
        let reader = Task.detached { try await MailImportReader.index(urls, variant: variant) { value in
            Task { @MainActor in if !self.closed, self.operation == token { self.progress = value.records; self.readProgress = value } }
        } }
        do {
            let loaded = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            guard !closed, operation == token, !Task.isCancelled else { return }
            guard let mail = hub.makeMailService(for: space) else { throw MailSyncError.accountNotFound }
            let reviewed = try await mail.importPreview(loaded, archiveID: destinationID)
            guard !closed, operation == token, !Task.isCancelled else { return }
            previewRevision = UUID(); preview = reviewed; batch = nil
            resultStatusFilter = nil
            selectedIDs = Set(reviewed.candidates.map(\.id)); folderFilter = nil; after = nil; before = nil
            if let previous = resumingBatch {
                let resumed = try await mail.previewImportResume(batchID: previous.id, archiveID: previous.accountID, source: reviewed)
                guard !closed, operation == token, !Task.isCancelled else { return }
                batch = previous; resumeReview = resumed
            } else { await refreshMapping() }
        } catch is CancellationError { }
        catch { if operation == token { self.error = MailErrorText.message(for: error) } }
    }

    func start() {
        guard canStart, batch?.undo == nil, let preview = selectedPreview, let mappingReview else { return }
        // Freeze both the selected originals and the reviewed target identities.
        busy = true; progress = 0; readProgress = nil; error = nil
        writeTotal = preview.candidates.count; resultErrorFilter = nil
        resultStatusFilter = nil
        let token = UUID(); operation = token
        task = Task {
            defer { if operation == token { busy = false; task = nil } }
            do {
                try Task.checkCancellation()
                guard let mail = hub.makeMailService(for: space) else { throw MailSyncError.accountNotFound }
                let completed = try await mail.importMappedMessages(preview, review: mappingReview) { done, _ in
                    await MainActor.run { if self.operation == token { self.progress = done } }
                }
                guard !closed, operation == token else { return }
                batch = completed
                destinationID = completed.accountID
                await Task { @MainActor in
                    guard !self.closed, self.operation == token else { return }
                    await self.onImported(completed.accountID)
                    guard !self.closed, self.operation == token else { return }
                    await self.load()
                }.value
            } catch is CancellationError { }
            catch { if !closed, operation == token { self.error = MailErrorText.message(for: error); await refreshMapping() } }
        }
    }

    func retryRemaining() {
        guard !busy, !closed, let preview, let batch else { return }
        if batch.resumeManifest != nil {
            busy = true; error = nil
            let token = UUID(); operation = token
            task = Task {
                defer { if operation == token { busy = false; task = nil } }
                do {
                    guard let mail = hub.makeMailService(for: space) else { throw MailImportError.changed }
                    let review = try await mail.previewImportResume(batchID: batch.id, archiveID: batch.accountID, source: preview)
                    guard !closed, operation == token, !Task.isCancelled else { return }
                    resumeReview = review
                } catch is CancellationError { }
                catch { if !closed, operation == token { self.error = MailErrorText.message(for: error) } }
            }
            return
        }
        let remaining = Set(batch.results.filter { $0.status == .failed || $0.status == .unprocessed }.map(\.id))
        var revised = preview
        revised.candidates = preview.candidates.filter { remaining.contains($0.id) }
        revised.failures = []; revised.duplicates = []
        self.preview = revised
        selectedIDs = Set(revised.candidates.map(\.id)); folderFilter = nil; after = nil; before = nil
        previewRevision = UUID()
        self.batch = nil
        invalidateMapping()
        Task { await updateDestination() }
    }

    func show(_ batch: MailImportBatch) {
        guard !busy, !closed else { return }
        invalidateMapping(); dismissResume(); self.batch = batch; resultStatusFilter = nil; resultErrorFilter = nil
    }

    var canRetry: Bool {
        guard let batch, batch.undo == nil, let preview else { return false }
        let remaining = Set(batch.results.filter { $0.status == .failed || $0.status == .unprocessed }.map(\.id))
        return preview.candidates.contains { remaining.contains($0.id) }
    }

    var canUndo: Bool { batch.map { $0.undo == nil && $0.results.contains { $0.status == .imported } } ?? false }

    func prepareUndo() {
        guard !busy, canUndo, let batch else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                guard let mail = hub.makeMailService(for: space) else { throw MailSyncError.accountNotFound }
                let plan = try await mail.previewImportUndo(batchID: batch.id, archiveID: batch.accountID)
                try Task.checkCancellation()
                undoPlan = plan
            } catch is CancellationError { }
            catch { self.error = MailErrorText.message(for: error) }
        }
    }

    func dismissUndo() { undoPlan = nil }

    func confirmUndo(_ reviewed: MailImportUndoPlan? = nil) {
        guard !busy, !closed, let plan = reviewed ?? undoPlan else { return }
        undoPlan = nil; busy = true; error = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                guard let mail = hub.makeMailService(for: space) else { throw MailSyncError.accountNotFound }
                let receipt = try await mail.undoImport(plan)
                batch?.undo = receipt
                await Task { @MainActor in
                    await self.load()
                    await self.onImported(plan.accountID)
                }.value
            } catch is CancellationError { }
            catch { self.error = MailErrorText.message(for: error) }
        }
    }

    func saveReport() {
        guard !busy, let batch else { return }
        busy = true
        task = Task {
            defer { busy = false; task = nil; panel = nil }
            do {
                let picker = NSSavePanel(); picker.nameFieldStringValue = "mail-import-report.json"; panel = picker
                let choice = await chooseFiles(picker)
                guard !Task.isCancelled else { return }
                let url: URL
                switch choice {
                case .selected(let selected): url = selected
                case .cancelled: return
                case .failed: throw MailExportError.unsafeDestination
                }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let target = try MailExportDestination(directory: url.deletingLastPathComponent(), filename: url.lastPathComponent)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                _ = try await target.write(encoder.encode(batch), suggestedName: url.lastPathComponent)
            } catch { self.error = MailErrorText.message(for: error) }
        }
    }

    func cancel() { task?.cancel(); panel?.cancel(nil); dismissInspection() }

    func close() {
        closed = true; operation = UUID(); previewRevision = UUID()
        cancel(); releaseSources(); invalidateMapping(); mappingRules = [:]
        dismissResume()
        lastSourceURLs = []; preview = nil; batch = nil; selectedIDs = []; undoPlan = nil; busy = false
    }
}

struct MailImportView: View {
    @State var model: MailImportModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDateFilter = false
    @State private var afterDate = Date()
    @State private var beforeDate = Date()
    @State private var showMboxOptions = false
    @State private var showMappingOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string("mail.import.title")).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L.string("mail.import.hint")).font(.caption).foregroundStyle(.secondary)
                    if model.batch == nil {
                        Picker(L.string("mail.import.destination"), selection: $model.destinationID) {
                            Text(L.string("mail.import.newArchive")).tag(nil as UUID?)
                            ForEach(model.archives) { Text($0.displayName).tag($0.id as UUID?) }
                        }.disabled(model.busy)
                        if model.destinationID == nil {
                            TextField(L.string("mail.import.archiveName"), text: $model.archiveName).disabled(model.busy)
                        }
                        Button(L.string("mail.import.choose")) { model.choose() }.disabled(model.busy)
                        DisclosureGroup(L.string("mail.import.mbox.options"), isExpanded: $showMboxOptions) {
                            Picker(L.string("mail.import.mbox.options"), selection: Binding(get: { model.mboxVariant }, set: { model.setMboxVariant($0) })) {
                                ForEach(MailMboxVariant.allCases, id: \.self) { Text(L.string("mail.import.mbox.variant." + $0.rawValue)).tag($0) }
                            }.pickerStyle(.segmented).disabled(model.busy)
                            Text(L.string("mail.import.mbox.hint." + model.mboxVariant.rawValue)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L.string("mail.import.mbox.rereadHint")).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let preview = model.preview {
                            Text(L.format("mail.import.preview", preview.candidates.count, preview.duplicates.count, preview.failures.count))
                            selectionControls
                            mappingControls
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.visibleCandidates) { item in
                                      HStack(alignment: .top) {
                                        Toggle(isOn: Binding(get: { model.selectedIDs.contains(item.id) }, set: { model.setSelected(item.id, selected: $0) })) {
                                            VStack(alignment: .leading) {
                                                Text(item.envelope.subject.isEmpty ? L.string("mail.noSubject") : item.envelope.subject).lineLimit(2)
                                                Text(item.source).foregroundStyle(.secondary)
                                                if let variant = item.sourceVariant { Text(L.format("mail.import.mbox.resultFormat", L.string("mail.import.mbox.variant." + variant.rawValue))).foregroundStyle(.secondary) }
                                                if let date = item.envelope.date { Text(AppDate.string(from: date)).foregroundStyle(.secondary) }
                                                if let match = preview.duplicateMatches[item.id] {
                                                    if case .existing = match { Text(L.string("mail.import.duplicate.existing")).foregroundStyle(.secondary) }
                                                    else { Text(L.string("mail.import.duplicate.candidate")).foregroundStyle(.secondary) }
                                                }
                                            }
                                        }.toggleStyle(.checkbox).disabled(model.busy)
                                        Spacer(minLength: 8)
                                        VStack(alignment: .trailing, spacing: 6) {
                                            Button(L.string("mail.import.inspect.action")) { model.inspectCandidate(item.id) }
                                            if preview.duplicateMatches[item.id] != nil {
                                                Button(L.string("mail.import.duplicate.inspect")) { model.inspectDuplicate(item.id) }
                                            }
                                        }.disabled(model.busy)
                                      }
                                    }
                                    ForEach(preview.failures) { result in resultRow(result) }
                                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 220)
                        }
                    } else if let batch = model.batch {
                        if let review = model.resumeReview {
                            Text(L.string("mail.import.resume.hint")).font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 5) {
                                    ForEach(review.items) { item in
                                        Text(item.source + " · " + L.string("mail.import.resume.status." + item.status.rawValue))
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 150)
                            HStack {
                                Button(L.string("mail.import.resume.confirm")) { model.confirmResume() }.disabled(model.busy || !review.canResume)
                                Button(L.string("common.cancel")) { model.dismissResume() }.disabled(model.busy)
                            }
                        }
                        Text(L.string(batch.undo != nil ? "mail.import.undo.finished" : "mail.import.state." + batch.state.rawValue))
                        Text(L.format("mail.import.result", batch.results.filter { $0.status == .imported }.count,
                            batch.results.filter { $0.status == .duplicate }.count,
                            batch.results.filter { $0.status == .failed || $0.status == .unprocessed }.count))
                        if let undo = batch.undo {
                            Text(L.format("mail.import.undo.result", undo.removed.count, undo.skipped.count)).font(.caption)
                        }
                        Picker(L.string("mail.import.resultFilter"), selection: $model.resultStatusFilter) {
                            Text(L.string("mail.import.resultFilter.all")).tag(nil as MailImportResult.Status?)
                            ForEach(MailImportResult.Status.allCases, id: \.self) { status in Text(L.string("mail.import.status." + status.rawValue)).tag(status as MailImportResult.Status?) }
                        }.disabled(model.busy)
                        if !model.resultErrors.isEmpty {
                            DisclosureGroup(L.string("mail.import.failureGroups")) {
                                Button(L.string("mail.import.resultFilter.all")) { model.resultErrorFilter = nil }
                                ForEach(model.resultErrors, id: \.rawValue) { error in
                                    Button(L.format("mail.import.failureGroup", model.failureCount(error), MailErrorText.message(for: error))) {
                                        model.resultErrorFilter = error
                                    }.fixedSize(horizontal: false, vertical: true)
                                }
                            }.disabled(model.busy)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) { ForEach(model.visibleResults) { resultRow($0) } }
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 250)
                    }
                    if model.busy {
                        ProgressView()
                        if let value = model.readProgress {
                            Text(L.format("mail.import.phase." + value.phase.rawValue, value.discoveredFiles, value.completedFiles, value.records)).font(.caption)
                            if let total = value.totalBytes {
                                Text(L.format("mail.import.readBytes", ByteCountFormatter.string(fromByteCount: value.readBytes, countStyle: .file),
                                    ByteCountFormatter.string(fromByteCount: total, countStyle: .file))).font(.caption).foregroundStyle(.secondary)
                            }
                        } else { Text(L.format("mail.import.phase.writing", model.progress, model.writeTotal)).font(.caption) }
                    }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if !model.history.isEmpty {
                        DisclosureGroup(L.string("mail.import.history")) {
                            ScrollView {
                                ForEach(model.history) { batch in
                                    Button(AppDate.string(from: batch.createdAt) + " · " + L.string(batch.undo != nil ? "mail.import.undo.finished" : "mail.import.state." + batch.state.rawValue)) { model.show(batch) }
                                        .disabled(model.busy)
                                }
                            }.frame(maxHeight: 90)
                        }
                    }
                    if model.batch != nil {
                        HStack {
                            Button(L.string("mail.import.viewBatch")) { model.revealBatch() }.disabled(model.busy)
                            Button(L.string("mail.import.report")) { model.saveReport() }.disabled(model.busy)
                            Button(L.string("mail.import.choose")) { model.choose() }.disabled(model.busy)
                            if model.canPrepareResume {
                                Button(L.string("mail.import.resume.choose")) { model.chooseResumeSources() }.disabled(model.busy)
                            }
                            Spacer()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if model.canUndo { Button(L.string("mail.import.undo.title"), role: .destructive) { model.prepareUndo() }.disabled(model.busy) }
                if model.canRetry { Button(L.string("mail.import.retry")) { model.retryRemaining() }.disabled(model.busy) }
                Spacer()
                Button(L.string(model.busy ? "common.cancel" : "common.close")) {
                    if model.busy { model.cancel() } else { model.close(); dismiss() }
                }.keyboardShortcut(.cancelAction)
                if model.batch == nil {
                    Button(L.string("mail.import.start")) { model.start() }
                        .disabled(!model.canStart)
                }
            }
        }
        .padding(20).frame(width: 620, height: 740)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !model.busy else { return false }
            model.readFiles(urls); return true
        }
        .task { await model.load() }
        .task(id: model.destinationID) { await model.updateDestination() }
        .onChange(of: afterDate) { _, _ in updateDates() }
        .onChange(of: beforeDate) { _, _ in updateDates() }
        .onChange(of: model.requiresMboxChoice) { _, value in if value { showMboxOptions = true } }
        .onDisappear { model.close() }
        .sheet(item: Binding(get: { model.inspection }, set: { if $0 == nil { model.dismissInspection() } })) { inspection in
            MailImportInspectionView(model: inspection)
        }
        .alert(L.string("mail.import.undo.title"), isPresented: Binding(get: { model.undoPlan != nil }, set: { if !$0 { model.dismissUndo() } }), presenting: model.undoPlan) { plan in
            Button(L.string("mail.import.undo.confirm"), role: .destructive) { model.confirmUndo(plan) }
            Button(L.string("common.cancel"), role: .cancel) { model.dismissUndo() }
        } message: { plan in
            Text(L.format("mail.import.undo.message", plan.count, plan.candidates.count - plan.count))
        }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(L.string("mail.import.folderFilter"), selection: $model.folderFilter) {
                    Text(L.string("mail.import.allFolders")).tag(nil as String?)
                    ForEach(model.sourceFolders, id: \.self) { folder in
                        Text(folder.isEmpty ? L.string("mail.import.rootFolder") : folder).tag(folder as String?)
                    }
                }
                Button(L.string("mail.import.selectVisible")) { model.selectVisible(true) }
                Button(L.string("mail.import.deselectVisible")) { model.selectVisible(false) }
            }.disabled(model.busy)
            DisclosureGroup(L.string("mail.import.dateFilter"), isExpanded: $showDateFilter) {
                HStack {
                    Toggle(L.string("mail.filter.after"), isOn: Binding(get: { model.after != nil }, set: { model.after = $0 ? Calendar.current.startOfDay(for: afterDate) : nil }))
                    DatePicker(L.string("mail.filter.date"), selection: $afterDate, displayedComponents: .date).labelsHidden().disabled(model.after == nil)
                    Toggle(L.string("mail.filter.before"), isOn: Binding(get: { model.before != nil }, set: { model.before = $0 ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: beforeDate)) : nil }))
                    DatePicker(L.string("mail.filter.date"), selection: $beforeDate, displayedComponents: .date).labelsHidden().disabled(model.before == nil)
                }
            }.disabled(model.busy)
            Text(L.format("mail.import.selectionSummary", model.selectedCandidates.count, model.visibleCandidates.count,
                          ByteCountFormatter.string(fromByteCount: Int64(model.selectedByteCount), countStyle: .file)))
            if let dates = model.selectedDates {
                Text(L.format("mail.import.dateRange", AppDate.string(from: dates.lowerBound), AppDate.string(from: dates.upperBound)))
                    .foregroundStyle(.secondary)
            }
            Text(L.string("mail.import.selectionHint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.caption)
    }

    private var mappingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L.string("mail.import.mapping.title")).fontWeight(.medium)
                Spacer()
                Button(L.string("mail.import.mapping.refresh")) { Task { await model.refreshMapping() } }.disabled(model.busy)
            }
            if let review = model.mappingReview {
                Text(L.format("mail.import.mapping.archive", review.account.displayName)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(review.rows) { row in
                            Text((row.source.source.isEmpty ? L.string("mail.import.rootFolder") : row.source.source) + " → " + row.displayPath)
                                .textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 54)
            }
            DisclosureGroup(L.string("mail.import.mapping.edit"), isExpanded: $showMappingOptions) {
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.mappingSources) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L.format("mail.import.mapping.source", source.source.isEmpty ? L.string("mail.import.rootFolder") : source.source, source.count))
                                .textSelection(.enabled)
                            Picker(L.string("mail.import.mapping.rule"), selection: Binding(get: { mappingMode(source.id) }, set: { setMappingMode(source, mode: $0) })) {
                                ForEach(["preserve", "inbox", "existing", "path"], id: \.self) { Text(L.string("mail.import.mapping.mode." + $0)).tag($0) }
                            }.pickerStyle(.segmented)
                            if mappingMode(source.id) == "existing" {
                                Picker(L.string("mail.import.mapping.folder"), selection: Binding<UUID?>(get: {
                                    if case .existing(let id) = model.mappingRules[source.id] { return id }; return nil
                                }, set: { model.setMappingRule(source.id, rule: .existing($0)) })) {
                                    Text(L.string("mail.import.mapping.chooseFolder")).tag(nil as UUID?)
                                    ForEach(model.mappingTargets?.choices ?? []) { Text($0.displayPath).tag($0.id as UUID?) }
                                }.disabled(model.destinationID == nil)
                                if model.destinationID == nil { Text(L.string("mail.import.mapping.existingHint")).foregroundStyle(.secondary) }
                            } else if mappingMode(source.id) == "path" {
                                TextField(L.string("mail.import.mapping.path"), text: Binding(get: {
                                    if case .path(let value) = model.mappingRules[source.id] { return value }; return ""
                                }, set: { model.setMappingRule(source.id, rule: .path($0)) }))
                                Text(L.string("mail.import.mapping.pathHint")).foregroundStyle(.secondary)
                            }
                            if let target = model.mappingReview?.rows.first(where: { $0.id == source.id }) {
                                Text(L.format("mail.import.mapping.target", target.displayPath)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.frame(maxHeight: 190).disabled(model.busy)
            }
            if model.mappingBusy { ProgressView().controlSize(.small); Text(L.string("mail.import.mapping.preparing")) }
            if let unavailable = model.mappingTargets?.unavailable, unavailable > 0 {
                Text(L.format("mail.import.mapping.unavailable", unavailable)).foregroundStyle(.secondary)
            }
            if let error = model.mappingError { Text(error).foregroundStyle(.red) }
            Text(L.string("mail.import.mapping.duplicateHint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.caption)
    }

    private func mappingMode(_ id: String) -> String {
        switch model.mappingRules[id] ?? .preserve {
        case .preserve: "preserve"
        case .inbox: "inbox"
        case .existing: "existing"
        case .path: "path"
        }
    }

    private func setMappingMode(_ source: MailImportMappingSource, mode: String) {
        let rule: MailImportFolderRule
        switch mode {
        case "inbox": rule = .inbox
        case "existing": rule = .existing(nil)
        case "path": rule = .path(source.source)
        default: rule = .preserve
        }
        model.setMappingRule(source.id, rule: rule)
    }

    private func updateDates() {
        if model.after != nil { model.after = Calendar.current.startOfDay(for: afterDate) }
        if model.before != nil { model.before = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: beforeDate)) }
    }

    private func resultRow(_ result: MailImportResult) -> some View {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.subject.isEmpty ? result.source : result.subject).lineLimit(2)
            Text(result.source).foregroundStyle(.secondary)
            if let variant = result.sourceVariant { Text(L.format("mail.import.mbox.resultFormat", L.string("mail.import.mbox.variant." + variant.rawValue))).foregroundStyle(.secondary) }
            Text(L.string(result.status == .imported && result.messageID.map { model.batch?.undo?.removed.contains($0) == true } == true
                ? "mail.import.undo.removed" : "mail.import.status." + result.status.rawValue)).foregroundStyle(.secondary)
            if let error = result.error { Text(MailErrorText.message(for: error)).foregroundStyle(.red) }
            if result.status == .duplicate && !model.canInspectResult(result) { Text(L.string("mail.import.duplicate.unavailable")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.textSelection(.enabled)
        Spacer(minLength: 8)
        if model.canInspectResult(result) {
            Button(L.string(result.status == .duplicate ? "mail.import.duplicate.inspect" : "mail.import.inspect.action")) { model.inspectResult(result.id) }.disabled(model.busy)
        }
      }
    }
}
