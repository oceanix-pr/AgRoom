import AppKit
import Observation
import SwiftUI
import AgRoomCore

struct MailSourceRequest: Identifiable {
    let id = UUID()
    let messageID: UUID
    let headersOnly: Bool
}

/// Bounded text pages keep large MIME attachments out of the native text layout.
/// The owned bytes remain untouched; this view is never used to export an original.
struct MailSourceDocument: Sendable {
    let raw: MailRawMessage
    private let sourcePages: [Range<Data.Index>]
    private let headerPages: [Range<Data.Index>]

    init(raw: MailRawMessage) throws {
        try Task.checkCancellation()
        guard !raw.data.isEmpty, raw.data.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
        self.raw = raw
        let data = raw.data
        let separator = data.range(of: Data([13, 10, 13, 10])) ?? data.range(of: Data([10, 10]))
        sourcePages = try Self.pages(data.startIndex..<data.endIndex, data: data)
        headerPages = try Self.pages(data.startIndex..<(separator?.lowerBound ?? data.endIndex), data: data)
    }

    private static func pages(_ range: Range<Data.Index>, data: Data) throws -> [Range<Data.Index>] {
        var result: [Range<Data.Index>] = [], start = range.lowerBound
        while start < range.upperBound {
            try Task.checkCancellation()
            var end = min(start + 64 * 1024, range.upperBound)
            // Avoid splitting a UTF-8 scalar at the page edge. Invalid octets
            // are displayed with replacement characters, never rewritten.
            var advanced = 0
            while end < range.upperBound, data[end] & 0xC0 == 0x80, advanced < 3 { end += 1; advanced += 1 }
            result.append(start..<end); start = end
        }
        return result.isEmpty ? [range] : result
    }

    func pageCount(headersOnly: Bool) -> Int { (headersOnly ? headerPages : sourcePages).count }
    func text(headersOnly: Bool, page: Int) -> String {
        let ranges = headersOnly ? headerPages : sourcePages
        guard ranges.indices.contains(page) else { return "" }
        return String(decoding: raw.data[ranges[page]], as: UTF8.self)
    }
}

@MainActor @Observable
final class MailSourceModel {
    let request: MailSourceRequest
    let hub: Hub
    let space: AppSpace
    var headersOnly: Bool
    var page = 0
    private(set) var document: MailSourceDocument?
    private(set) var busy = false
    private(set) var error: String?
    private var operation = UUID()
    private var task: Task<Void, Never>?
    var makeSyncService: @MainActor () -> MailSyncService?

    init(request: MailSourceRequest, hub: Hub, space: AppSpace) {
        self.request = request; self.hub = hub; self.space = space; self.headersOnly = request.headersOnly
        self.makeSyncService = { hub.makeMailSyncService(for: space) }
    }

    var pageCount: Int { document?.pageCount(headersOnly: headersOnly) ?? 1 }
    var text: String { document?.text(headersOnly: headersOnly, page: page) ?? "" }

    func load(download: Bool = false) {
        guard !busy else { return }
        let token = UUID(); operation = token; busy = true; error = nil
        task = Task {
            defer { if operation == token { busy = false; task = nil } }
            do {
                guard let mail = hub.makeMailService(for: space), try await mail.message(id: request.messageID) != nil else { throw MailSyncError.messageNotFound }
                var raw = try await mail.rawMessage(id: request.messageID)
                if raw == nil, download {
                    guard let sync = makeSyncService() else { throw MailSyncError.accountNotFound }
                    raw = try await sync.rawMessage(messageId: request.messageID, downloadIfNeeded: true)
                }
                try Task.checkCancellation()
                guard let raw else { return }
                let prepare = Task.detached { try MailSourceDocument(raw: raw) }
                let loaded = try await withTaskCancellationHandler { try await prepare.value } onCancel: { prepare.cancel() }
                guard operation == token, !Task.isCancelled else { return }
                document = loaded; page = 0
            } catch is CancellationError { }
            catch { if operation == token { self.error = MailErrorText.message(for: error) } }
        }
    }

    func cancel() { task?.cancel(); operation = UUID(); busy = false; task = nil }
}

struct MailSourceView: View {
    @State var model: MailSourceModel
    @Environment(\.dismiss) private var dismiss
    @State private var export: MailTransferRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("mail.source.title")).font(.headline)
            Picker(L.string("mail.source.title"), selection: $model.headersOnly) {
                Text(L.string("mail.source.headers")).tag(true)
                Text(L.string("mail.source.original")).tag(false)
            }.pickerStyle(.segmented)
            if let document = model.document {
                Text(L.string(document.raw.kind == .generated ? "mail.export.generatedHint" : "mail.source.textHint"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                MailSourceTextView(text: model.text)
                    .accessibilityLabel(L.string(model.headersOnly ? "mail.source.headers" : "mail.source.original"))
                HStack {
                    Button(L.string("mail.source.previous")) { model.page -= 1 }.disabled(model.page == 0)
                    Text(L.format("mail.source.page", model.page + 1, model.pageCount)).font(.caption).monospacedDigit()
                    Button(L.string("mail.source.next")) { model.page += 1 }.disabled(model.page + 1 >= model.pageCount)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(document.raw.data.count), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView {
                    Label(L.string("mail.source.missing"), systemImage: "doc.text")
                } description: { Text(L.string("mail.source.missingHint")) }
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if model.document != nil {
                    Button(L.string(model.pageCount > 1 ? "mail.source.copyPage" : "mail.action.copy")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.text, forType: .string)
                    }
                    Button(L.string("mail.export.title")) { export = .init(content: .messages([model.request.messageID])) }
                } else {
                    Button(L.string("mail.source.download")) { model.load(download: true) }.disabled(model.busy)
                }
                Spacer()
                Button(L.string("common.close")) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 780, height: 580)
        .task { model.load() }
        .onChange(of: model.headersOnly) { _, _ in model.page = 0 }
        .onDisappear { model.cancel() }
        .sheet(item: $export) { request in
            MailTransferView(model: MailTransferModel(request: request, hub: model.hub, space: model.space))
        }
    }
}

private struct MailSourceTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticDataDetectionEnabled = false
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text; view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
