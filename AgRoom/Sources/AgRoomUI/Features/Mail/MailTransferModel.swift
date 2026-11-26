import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import AgRoomCore

@MainActor @Observable
final class MailTransferModel {
    let request: MailTransferRequest
    private let hub: Hub
    private let space: AppSpace
    var format = MailExportFormat.eml { didSet { scheduleLayout() } }
    var naming = MailExportNaming.subject { didSet { scheduleLayout() } }
    var grouping = MailExportGrouping.flat { didSet { scheduleLayout() } }
    var directoryName: String { didSet { scheduleLayout() } }
    var downloadMissing = true
    var previewQuery = "" { didSet { pathLimit = 100; filterPaths() } }
    private(set) var coverage: MailExportCoverage?
    private(set) var preparation: MailExportPreparation?
    private(set) var review: MailExportReview?
    private(set) var layout: MailExportLayout?
    private(set) var visiblePaths: [MailExportLayoutEntry] = []
    private(set) var matchingPaths = 0
    private(set) var filteringPaths = false
    private(set) var canDownload = false
    private(set) var attachments: [MailAttachment] = []
    private(set) var error: String?
    private(set) var needsReview = false
    private(set) var busy = false
    private(set) var prepared = false
    private(set) var progress = 0
    private(set) var results: [MailTransferItem] = []
    private(set) var destination: URL?
    private var task: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var revision = UUID()
    private var filterRevision = UUID()
    private var pathLimit = 100
    private var panel: NSSavePanel?
    private var cancelled = false
    private var closed = false
    private var selectedIDs: [UUID]
    private var attachmentsByID: [UUID: MailAttachment] = [:]
    var chooseDestination: @MainActor (NSSavePanel) async -> ArtifactExportChoice = { await ArtifactExportChoice.choose($0) }
    var makeSyncService: @MainActor () -> MailSyncService?
    var mboxPartByteLimit = MailService.rawMessageByteLimit

    init(request: MailTransferRequest, hub: Hub, space: AppSpace) {
        self.request = request; self.hub = hub; self.space = space
        let ids: [UUID]
        switch request.content { case .messages(let values), .attachments(_, let values): ids = values }
        var seen = Set<UUID>(); selectedIDs = ids.filter { seen.insert($0).inserted }
        directoryName = Self.freshDirectoryName()
        makeSyncService = { hub.makeMailSyncService(for: space) }
    }

    private static func freshDirectoryName() -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyyMMdd-HHmmss"
        return L.string("mail.export.folder") + "-" + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(6)
    }

    var count: Int { selectedIDs.count }
    var titleKey: String {
        switch request.content { case .messages: "mail.export.title"; case .attachments: "mail.attachment.saveAll" }
    }
    var scopeDescription: String {
        switch request.scope {
        case .selection: L.string("mail.export.scope.selection")
        case .folder(let name): L.format("mail.export.scope.folder", name)
        case .folderTree(let name): L.format("mail.export.scope.folderTree", name)
        case .query(let scope): L.format("mail.export.scope.query", L.string("mail.search.range." + scope.rawValue))
        }
    }
    var showsDirectory: Bool { format == .bundle || count > 1 || grouping != .flat }
    var bundleNeedsRetry: Bool { format == .bundle && error != nil && !results.isEmpty }

    func prepare() async {
        guard !busy, !closed else { return }
        layoutTask?.cancel(); filterTask?.cancel()
        let token = UUID(); revision = token
        prepared = false; error = nil; needsReview = false; layout = nil; review = nil
        visiblePaths = []; matchingPaths = 0; preparation = nil; canDownload = false
        do {
            guard let mail = hub.makeMailService(for: space) else { throw MailSyncError.accountNotFound }
            switch request.content {
            case .messages:
                let value = try await mail.reviewExport(ids: selectedIDs)
                guard !closed, revision == token, !Task.isCancelled else { return }
                review = value; coverage = value.coverage; canDownload = value.allowsNetwork
                await rebuildLayout(value, token: token, options: layoutOptions())
            case .attachments(let messageID, _):
                let wanted = Set(selectedIDs)
                let values = try await mail.attachments(messageId: messageID).filter { wanted.contains($0.id) }
                guard !closed, revision == token, !Task.isCancelled else { return }
                guard values.count == wanted.count else { throw MailSyncError.messageNotFound }
                attachments = values; attachmentsByID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }); prepared = true
            }
        } catch { if !closed, revision == token { self.error = MailErrorText.message(for: error) } }
    }

    private func layoutOptions() -> MailExportLayoutOptions {
        .init(format: format, naming: naming, grouping: grouping, directoryName: directoryName,
            timeZoneIdentifier: TimeZone.current.identifier,
            labels: .init(undated: L.string("mail.export.undated"), untitled: L.string("mail.noSubject"), volumeBase: "mail"))
    }

    private func scheduleLayout() {
        guard !busy, !closed, let review else { return }
        layoutTask?.cancel(); filterTask?.cancel()
        let token = UUID(), options = layoutOptions(); revision = token
        prepared = false; layout = nil; preparation = nil; visiblePaths = []; error = nil
        layoutTask = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await rebuildLayout(review, token: token, options: options)
        }
    }

    private func rebuildLayout(_ review: MailExportReview, token: UUID, options: MailExportLayoutOptions) async {
        let build = Task.detached { (try MailExportLayout.build(review: review, options: options), review.preparation(for: options.format)) }
        do {
            let value = try await withTaskCancellationHandler { try await build.value } onCancel: { build.cancel() }
            guard !closed, revision == token, !Task.isCancelled else { return }
            layout = value.0; preparation = value.1; prepared = !needsReview
            pathLimit = 100; filterPaths()
        } catch is CancellationError { }
        catch { if !closed, revision == token { self.error = MailErrorText.message(for: error) } }
    }

    func showMorePaths() { pathLimit += 100; filterPaths() }

    private func filterPaths() {
        filterTask?.cancel(); filterRevision = UUID()
        guard !closed, let layout else { visiblePaths = []; matchingPaths = 0; filteringPaths = false; return }
        let token = filterRevision, query = previewQuery, limit = pathLimit
        filteringPaths = true
        filterTask = Task {
            let filter = Task.detached { () throws -> ([MailExportLayoutEntry], Int) in
                var visible: [MailExportLayoutEntry] = [], count = 0
                for entry in layout.entries {
                    try Task.checkCancellation()
                    if query.isEmpty || entry.path.localizedStandardContains(query) || entry.title.localizedStandardContains(query) {
                        count += 1; if visible.count < limit { visible.append(entry) }
                    }
                }
                return (visible, count)
            }
            do {
                let value = try await withTaskCancellationHandler { try await filter.value } onCancel: { filter.cancel() }
                guard !closed, filterRevision == token, !Task.isCancelled else { return }
                visiblePaths = value.0; matchingPaths = value.1; filteringPaths = false
            } catch { if filterRevision == token { filteringPaths = false } }
        }
    }

    func prepareFailedItems() async {
        guard !busy, !closed else { return }
        let remaining = bundleNeedsRetry ? Set(selectedIDs) : Set(results.filter { $0.file == nil }.map(\.id))
        selectedIDs = selectedIDs.filter { remaining.contains($0) }
        results = []; destination = nil; progress = 0
        review = nil; directoryName = Self.freshDirectoryName()
        await prepare()
    }

    func start() {
        guard !busy, !closed, prepared, count > 0 else { return }
        let ids = selectedIDs, frozenLayout = layout, frozenReview = review
        if case .messages = request.content { guard frozenLayout != nil, frozenReview != nil else { return } }
        let fill = downloadMissing, limit = min(max(mboxPartByteLimit, 1), MailService.rawMessageByteLimit)
        cancelled = false; busy = true; error = nil; progress = 0; results = []; destination = nil
        task = Task { await execute(ids: ids, layout: frozenLayout, review: frozenReview, fill: fill, mboxLimit: limit) }
    }

    func cancel() { cancelled = true; task?.cancel(); panel?.cancel(nil) }
    func close() {
        closed = true; revision = UUID(); filterRevision = UUID()
        cancel(); layoutTask?.cancel(); filterTask?.cancel(); prepared = false; busy = false
    }

    private func recordFailure(_ error: any Error) {
        if case MailExportError.changed = error { needsReview = true; prepared = false }
    }

    private func execute(ids: [UUID], layout: MailExportLayout?, review: MailExportReview?, fill: Bool, mboxLimit: Int) async {
        defer { if !closed { busy = false; task = nil; panel = nil } }
        do {
            guard let mail = hub.makeMailService(for: space), let sync = makeSyncService() else { throw MailSyncError.accountNotFound }
            let directoryOutput = layout?.isDirectory ?? (ids.count > 1)
            let chosen = directoryOutput ? NSOpenPanel() : NSSavePanel()
            chosen.title = L.string("mail.export.choose")
            if let folder = chosen as? NSOpenPanel {
                folder.canChooseFiles = false; folder.canChooseDirectories = true
                folder.canCreateDirectories = true; folder.allowsMultipleSelection = false
            } else {
                chosen.nameFieldStringValue = layout?.entries.first?.components.last ?? MailExportDestination.safeName(attachments.first?.filename ?? L.string("mail.export.attachmentDefault"))
                if let layout { chosen.allowedContentTypes = [UTType(filenameExtension: layout.options.format.rawValue) ?? .data] }
            }
            panel = chosen
            let choice = await chooseDestination(chosen)
            guard !cancelled, !closed else { return }
            let url: URL
            switch choice {
            case .selected(let selected): url = selected
            case .cancelled: return
            case .failed: throw MailExportError.unsafeDestination
            }
            try Task.checkCancellation()
            if let review { try await mail.validateExport(review) }
            try Task.checkCancellation()
            guard !closed else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let target: MailExportDestination
            if directoryOutput {
                if let layout { target = try .namedBatch(in: url, name: layout.directoryName) }
                else { target = try .batch(in: url, prefix: L.string("mail.export.folder")) }
            } else { target = try .init(directory: url.deletingLastPathComponent(), filename: url.lastPathComponent) }
            if directoryOutput, !closed { destination = await target.directoryURL }
            let values: [MailTransferItem]
            if let review, let layout, layout.options.format == .bundle {
                values = await executeBundle(ids: ids, mail: mail, sync: sync, target: target, review: review, layout: layout, fill: fill)
            } else if let review, let layout, layout.options.format == .mbox {
                values = await executeMbox(ids: ids, mail: mail, sync: sync, target: target, review: review, layout: layout, fill: fill, limit: mboxLimit)
            } else {
                values = await executeFiles(ids: ids, mail: mail, sync: sync, target: target, review: review, layout: layout, fill: fill)
            }
            if !closed { results = values }
            if directoryOutput {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                _ = try await target.writeReceipt(encoder.encode(values), suggestedName: "export-report.json")
                if layout?.options.format == .bundle {
                    let rows = values.map { item in
                        (title: item.title, path: item.file.map { $0.split(separator: "/").map(String.init) }, error: item.error)
                    }
                    let title = L.string("mail.export.bundle.indexTitle")
                    let index = try await Task.detached { try MailArchiveBundle.index(title: title, rows: rows) }.value
                    _ = try await target.writeReceipt(index, suggestedName: "index.html")
                }
                if !closed { destination = await target.directoryURL }
            }
        } catch is CancellationError { }
        catch { if !closed { recordFailure(error); self.error = MailErrorText.message(for: error) } }
    }

    private func title(for id: UUID) -> String {
        let value = coverage?.titles[id] ?? attachmentsByID[id]?.filename ?? ""
        return value.isEmpty ? L.string("mail.noSubject") : value
    }

    private func executeBundle(ids: [UUID], mail: MailService, sync: MailSyncService, target: MailExportDestination,
                               review: MailExportReview, layout: MailExportLayout, fill: Bool) async -> [MailTransferItem] {
        let labels = MailArchiveLabels(title: L.string("mail.export.bundle.indexTitle"), original: L.string("mail.export.bundle.original"),
            attachments: L.string("mail.export.bundle.attachments"), from: L.string("mail.export.bundle.from"),
            to: L.string("mail.export.bundle.to"), date: L.string("mail.export.bundle.date"),
            emptyBody: L.string("mail.export.bundle.emptyBody"), generated: L.string("mail.export.generated"))
        var values: [MailTransferItem] = []
        for (position, id) in ids.enumerated() {
            if Task.isCancelled || cancelled {
                values += ids[position...].map { .init(id: $0, title: title(for: $0), file: nil, kind: nil, error: L.string("mail.export.cancelled")) }
                break
            }
            do {
                guard let source = review.source(id), let entry = layout.entry(id) else { throw MailExportError.changed }
                try await mail.validateExport(review, messageID: id)
                let raw = try await sync.rawMessage(messageId: id, downloadIfNeeded: fill && source.allowsNetwork, exportReview: review)
                let prepare = Task.detached { try MailArchiveBundle.build(raw: raw, message: source.message, labels: labels) }
                let payload = try await withTaskCancellationHandler { try await prepare.value } onCancel: { prepare.cancel() }
                let directory = Array(entry.components.dropLast())
                for file in payload.files {
                    try Task.checkCancellation()
                    try await mail.validateExport(review, messageID: id)
                    _ = try await target.writePlanned(file.data, components: directory + file.components)
                }
                values.append(.init(id: id, title: title(for: id), file: entry.path, kind: raw.kind.rawValue, error: nil,
                    originalSHA256: payload.originalSHA256, originalByteCount: payload.originalByteCount))
            } catch {
                if !closed { recordFailure(error) }
                values.append(.init(id: id, title: title(for: id), file: nil, kind: nil, error: MailErrorText.message(for: error)))
            }
            if !closed { progress = position + 1 }
        }
        return values
    }

    private func executeFiles(ids: [UUID], mail: MailService, sync: MailSyncService, target: MailExportDestination,
                              review: MailExportReview?, layout: MailExportLayout?, fill: Bool) async -> [MailTransferItem] {
        var values: [MailTransferItem] = []
        for (index, id) in ids.enumerated() {
            if Task.isCancelled || cancelled {
                values += ids[index...].map { .init(id: $0, title: title(for: $0), file: nil, kind: nil, error: L.string("mail.export.cancelled")) }
                break
            }
            do {
                let data: Data, kind: String, output: URL, relative: String
                if let review, let layout, let source = review.source(id), let entry = layout.entry(id) {
                    try await mail.validateExport(review, messageID: id)
                    let download = fill && source.allowsNetwork
                    if layout.options.format == .eml {
                        let raw = try await sync.rawMessage(messageId: id, downloadIfNeeded: download, exportReview: review)
                        data = raw.data; kind = raw.kind.rawValue
                    } else {
                        let body = try await sync.bodyForExport(messageId: id, downloadIfNeeded: download, review: review)
                        let images = MailInlineImageSource(hub: hub, space: space, messageID: id, downloadMissing: download,
                            exportReview: review, syncService: sync)
                        data = try await MailPDFRenderer().render(message: source.message, body: body, space: space, inlineImages: images)
                        kind = "pdf"
                    }
                    try Task.checkCancellation()
                    try await mail.validateExport(review, messageID: id)
                    output = try await target.writePlanned(data, components: entry.components)
                    relative = layout.isDirectory ? entry.path : output.lastPathComponent
                } else if case .attachments(let messageID, _) = request.content,
                          let attachment = attachmentsByID[id] {
                    let source = try await sync.downloadAttachment(messageId: messageID, attachmentID: id)
                    let read = Task.detached { try MailAttachmentFile.read(source) }
                    data = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                    try Task.checkCancellation()
                    output = try await target.write(data, suggestedName: attachment.filename); relative = output.lastPathComponent; kind = "attachment"
                } else { throw MailExportError.changed }
                if !closed { destination = layout?.isDirectory ?? (ids.count > 1) ? await target.directoryURL : output }
                values.append(.init(id: id, title: title(for: id), file: relative, kind: kind, error: nil))
            } catch {
                if !closed { recordFailure(error) }
                values.append(.init(id: id, title: title(for: id), file: nil, kind: nil, error: MailErrorText.message(for: error)))
            }
            if !closed { progress = index + 1 }
        }
        return values
    }

    private func executeMbox(ids: [UUID], mail: MailService, sync: MailSyncService, target: MailExportDestination,
                             review: MailExportReview, layout: MailExportLayout, fill: Bool, limit: Int) async -> [MailTransferItem] {
        var values: [MailTransferItem] = [], handled = Set<UUID>(), done = 0
        for group in layout.groups {
            if Task.isCancelled || cancelled { break }
            var bytes = Data(), pending: [MailTransferItem] = [], part = 1
            func flush() async {
                guard !pending.isEmpty else { return }
                let items = pending, data = bytes; pending = []; bytes = Data()
                do {
                    try Task.checkCancellation()
                    for item in items { try await mail.validateExport(review, messageID: item.id) }
                    let path = try group.path(part: part)
                    let output = try await target.writePlanned(data, components: path)
                    if !closed { destination = layout.isDirectory ? await target.directoryURL : output }
                    values += items.map { item in
                        .init(id: item.id, title: item.title,
                            file: layout.isDirectory ? path.joined(separator: "/") : output.lastPathComponent, kind: item.kind, error: nil,
                            originalSHA256: item.originalSHA256, originalByteCount: item.originalByteCount)
                    }
                } catch {
                    if !closed { recordFailure(error) }
                    values += items.map { .init(id: $0.id, title: $0.title, file: nil, kind: $0.kind, error: MailErrorText.message(for: error)) }
                }
                part += 1
            }
            for id in group.messageIDs {
                if Task.isCancelled || cancelled { break }
                do {
                    guard let source = review.source(id) else { throw MailExportError.changed }
                    let raw = try await sync.rawMessage(messageId: id, downloadIfNeeded: fill && source.allowsNetwork, exportReview: review)
                    let encoding = Task.detached { try MailMboxCodec.encode(raw.data, date: source.message.date) }
                    let record = try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
                    guard record.data.count <= limit else { throw MailExportError.tooLarge }
                    if !pending.isEmpty, bytes.count + record.data.count > limit { await flush() }
                    try Task.checkCancellation()
                    bytes.append(record.data)
                    pending.append(.init(id: id, title: title(for: id), file: nil, kind: raw.kind.rawValue, error: nil,
                        originalSHA256: record.originalSHA256, originalByteCount: record.originalByteCount))
                } catch {
                    if !closed { recordFailure(error) }
                    values.append(.init(id: id, title: title(for: id), file: nil, kind: nil, error: MailErrorText.message(for: error)))
                }
                handled.insert(id); done += 1; if !closed { progress = done }
            }
            if Task.isCancelled || cancelled {
                values += pending.map { .init(id: $0.id, title: $0.title, file: nil, kind: $0.kind, error: L.string("mail.export.cancelled")) }
            } else { await flush() }
        }
        values += ids.filter { !handled.contains($0) }.map { .init(id: $0, title: title(for: $0), file: nil, kind: nil, error: L.string("mail.export.cancelled")) }
        let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }
}
