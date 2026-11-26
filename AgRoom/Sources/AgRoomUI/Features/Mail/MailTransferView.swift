import AppKit
import PDFKit
import SwiftUI
import WebKit
import AgRoomCore

struct MailTransferRequest: Identifiable {
    enum Content { case messages([UUID]), attachments(UUID, [UUID]) }
    enum Scope { case selection, folder(String), folderTree(String), query(MailSearchScope) }
    let id = UUID()
    let content: Content
    var scope: Scope = .selection
}

struct MailTransferItem: Codable, Identifiable {
    let id: UUID
    let title: String
    let file: String?
    let kind: String?
    let error: String?
    var originalSHA256: String? = nil
    var originalByteCount: Int? = nil
}

struct MailTransferView: View {
    @State var model: MailTransferModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string(model.titleKey)).font(.headline)
            Text(L.format("mail.export.count", model.count))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if case .messages = model.request.content {
                        Text(model.scopeDescription).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let coverage = model.coverage { messageOptions(coverage) }
                    else if !model.attachments.isEmpty {
                        Text(L.string("mail.export.attachmentHint")).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.busy { ProgressView(value: Double(model.progress), total: Double(max(1, model.count))) }
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if model.needsReview {
                        Button(L.string("mail.export.reviewAgain")) {
                            Task {
                                if model.results.isEmpty { await model.prepare() }
                                else { await model.prepareFailedItems() }
                            }
                        }.disabled(model.busy)
                    }
                    if !model.results.isEmpty {
                        Text(L.format("mail.export.result", model.results.filter { $0.file != nil }.count,
                                      model.results.filter { $0.file == nil }.count))
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.results) { result in
                                VStack(alignment: .leading) {
                                    Text(result.file ?? result.title).lineLimit(3)
                                    if result.file != nil { Text(result.title).foregroundStyle(.secondary).lineLimit(2) }
                                    if let error = result.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                                    if result.kind == MailRawKind.generated.rawValue { Text(L.string("mail.export.generated")).foregroundStyle(.secondary) }
                                }.font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let destination = model.destination {
                    Button(L.string("files.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                }
                Spacer()
                Button(L.string(model.busy ? "common.cancel" : "common.close")) {
                    if model.busy { model.cancel() } else { model.close(); dismiss() }
                }.keyboardShortcut(.cancelAction)
                if model.results.isEmpty {
                    Button(L.string("mail.export.choose")) { model.start() }
                        .disabled(model.busy || model.count == 0 || !model.prepared)
                } else if !model.busy, model.results.contains(where: { $0.file == nil }) || model.bundleNeedsRetry {
                    Button(L.string(model.bundleNeedsRetry ? "mail.export.bundle.retry" : "mail.export.retryFailed")) { Task { await model.prepareFailedItems() } }
                }
            }
        }
        .padding(20).frame(width: 640, height: model.coverage == nil ? 440 : 740)
        .task { await model.prepare() }
        .onDisappear { model.close() }
    }

    private func messageOptions(_ coverage: MailExportCoverage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                Picker(L.string("mail.export.format"), selection: $model.format) {
                    Text(L.string("mail.export.eml")).tag(MailExportFormat.eml)
                    Text(L.string("mail.export.pdf")).tag(MailExportFormat.pdf)
                    Text(L.string("mail.export.mbox")).tag(MailExportFormat.mbox)
                    Text(L.string("mail.export.bundle")).tag(MailExportFormat.bundle)
                }.pickerStyle(.segmented)
                if model.format != .mbox {
                    Picker(L.string("mail.export.naming"), selection: $model.naming) {
                        ForEach(MailExportNaming.allCases, id: \.self) { Text(L.string("mail.export.naming." + $0.rawValue)).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Picker(L.string("mail.export.grouping"), selection: $model.grouping) {
                    ForEach(MailExportGrouping.allCases, id: \.self) { value in
                        Text(L.string("mail.export.grouping." + value.rawValue)).tag(value)
                            .disabled(value == .accountFolder && model.review?.hasCompleteHierarchy != true)
                    }
                }.pickerStyle(.segmented)
                if model.showsDirectory {
                    TextField(L.string("mail.export.directoryName"), text: $model.directoryName)
                        .textFieldStyle(.roundedBorder)
                }
            }.disabled(model.busy || !model.results.isEmpty)
            Text(L.format("mail.export.coverage", coverage.raw, coverage.total, coverage.bodies)).font(.caption)
            Text(L.string("mail.export.generatedHint")).font(.caption).foregroundStyle(.secondary)
            if model.format == .bundle {
                Text(L.string("mail.export.bundle.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let preparation = model.preparation {
                Text(L.format("mail.export.preparation.local", coverage.total - preparation.missingLocal,
                              preparation.missingLocal, preparation.unavailableLocally)).font(.caption)
                if preparation.downloadCandidates > 0 {
                    Text(L.format("mail.export.preparation.download", preparation.downloadCandidates)).font(.caption)
                    if let bytes = preparation.knownDownloadBytes {
                        Text(L.format("mail.export.preparation.bytes", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                                      preparation.unknownSizes)).font(.caption).foregroundStyle(.secondary)
                    } else { Text(L.string("mail.export.preparation.unknown")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if model.canDownload {
                Toggle(L.string("mail.export.download"), isOn: $model.downloadMissing).disabled(model.busy || !model.results.isEmpty)
                if model.review?.sources.contains(where: { !$0.allowsNetwork }) == true {
                    Text(L.string("mail.export.localSources")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(L.string("mail.export.offlineOnly")).font(.caption).foregroundStyle(.secondary)
            }
            if model.format == .pdf { Text(L.string("mail.export.pdfHint")).font(.caption).foregroundStyle(.secondary) }
            if model.format == .mbox {
                Text(L.string("mail.export.mboxHint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.results.isEmpty { filePreview }
        }
    }

    private var filePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(L.string("mail.export.paths.title")).font(.subheadline.bold())
            if let layout = model.layout {
                if layout.isDirectory { Text(layout.directoryName + "/").font(.caption.monospaced()).textSelection(.enabled) }
                else { Text(L.string("mail.export.paths.singleHint")).font(.caption).foregroundStyle(.secondary) }
                if layout.options.format == .mbox {
                    Text(L.string("mail.export.paths.mboxHint")).font(.caption).foregroundStyle(.secondary)
                }
                TextField(L.string("mail.export.paths.search"), text: $model.previewQuery).textFieldStyle(.roundedBorder)
                Text(L.format("mail.export.paths.count", model.visiblePaths.count, model.matchingPaths)).font(.caption).foregroundStyle(.secondary)
                if model.filteringPaths { ProgressView().controlSize(.small) }
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.visiblePaths) { entry in Text(entry.path).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if model.visiblePaths.count < model.matchingPaths {
                    Button(L.string("mail.list.load_more")) { model.showMorePaths() }.disabled(model.filteringPaths)
                }
            } else if !model.needsReview, model.error == nil {
                HStack { ProgressView().controlSize(.small); Text(L.string("mail.export.paths.preparing")).font(.caption) }
            }
        }
    }
}

/// Uses the reader's external-resource policy and current-message CID attachments,
/// then paginates vector PDF content.
@MainActor
final class MailPDFRenderer: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var pdfContinuation: CheckedContinuation<Data, Error>?
    private var webView: WKWebView?
    private var timeout: Task<Void, Never>?
    private var initialPending = true

    func render(message: MailMessage, body: MailBody, space: AppSpace, inlineImages: MailInlineImageSource? = nil) async throws -> Data {
        try Task.checkCancellation()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let inlineHandler = MailInlineImageHandler(); inlineHandler.replaceSource(inlineImages)
        if !WKWebView.handlesURLScheme("cid") { configuration.setURLSchemeHandler(inlineHandler, forURLScheme: "cid") }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 720), configuration: configuration)
        webView = view; view.navigationDelegate = self
        defer { timeout?.cancel(); view.stopLoading(); inlineHandler.invalidate(); webView = nil }
        let sender = MailAddress(name: message.fromName, address: message.fromAddress).display
        var fields = [escape(L.string("mail.compose.from")) + ": " + escape(sender)]
        if !message.to.isEmpty { fields.append(escape(L.string("mail.field.to")) + ": " + escape(message.to.map(\.display).joined(separator: ", "))) }
        if !message.cc.isEmpty { fields.append(escape(L.string("mail.field.cc")) + ": " + escape(message.cc.map(\.display).joined(separator: ", "))) }
        if let date = message.date { fields.append(escape(AppDate.string(from: date))) }
        let header = "<h2>\(escape(message.subject))</h2><p>\(fields.joined(separator: "<br>"))</p><hr>"
        var document = MailHTMLView.document(html: body.htmlBody, text: body.textBody)
        guard let bodyTag = document.range(of: "<body>") else { throw MailExportError.renderingFailed }
        document.insert(contentsOf: header, at: bodyTag.upperBound)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (promise: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { promise.resume(throwing: CancellationError()); return }
                continuation = promise
                view.loadHTMLString(document, baseURL: nil)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)); self?.finish(MailExportError.renderingFailed) } catch { }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(CancellationError()) } }
        try Task.checkCancellation()
        if inlineHandler.failureCount > 0 || (inlineImages?.failureCount ?? 0) > 0 { throw MailExportError.incomplete }
        let source = try await capturePDF(view)
        try Task.checkCancellation()
        let pagination = Task.detached { try Self.paginate(source) }
        return try await withTaskCancellationHandler { try await pagination.value } onCancel: { pagination.cancel() }
    }

    private func capturePDF(_ view: WKWebView) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (promise: CheckedContinuation<Data, any Error>) in
                guard !Task.isCancelled else { promise.resume(throwing: CancellationError()); return }
                pdfContinuation = promise
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)); self?.finish(MailExportError.renderingFailed) } catch { }
                }
                view.createPDF(configuration: WKPDFConfiguration()) { [weak self] (result: Result<Data, any Error>) in
                    guard let self, let pending = self.pdfContinuation else { return }
                    self.pdfContinuation = nil; self.timeout?.cancel()
                    pending.resume(with: result)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(CancellationError()) } }
    }

    private nonisolated static func paginate(_ source: Data) throws -> Data {
        guard source.count <= MailService.rawMessageByteLimit,
              let provider = CGDataProvider(data: source as CFData), let document = CGPDFDocument(provider) else {
            throw MailExportError.renderingFailed
        }
        let output = NSMutableData()
        let layout = PDFDocument(data: source)
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &paper, nil) else {
            throw MailExportError.renderingFailed
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        var pages = 0
        for index in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: index) else { throw MailExportError.renderingFailed }
            let bounds = page.getBoxRect(.mediaBox)
            guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { throw MailExportError.renderingFailed }
            let scale = min(1, 540 / bounds.width)
            let count = ceil(bounds.height * scale / 720)
            guard count.isFinite, count <= 500, pages + Int(count) <= 500 else { throw MailExportError.tooLarge }
            let textPage = layout?.page(at: index - 1)
            let lines = textPage.flatMap { page in
                page.selection(for: bounds)?.selectionsByLine().map { $0.bounds(for: page) }
            } ?? []
            var top = bounds.maxY
            while top > bounds.minY + 0.1 {
                try Task.checkCancellation()
                guard pages < 500 else { throw MailExportError.tooLarge }
                var bottom = max(bounds.minY, top - 720 / scale)
                // Move a break above any text line it would bisect. Drawing keeps
                // vector text; clipping also handles images wider than the page.
                if bottom > bounds.minY,
                   let crossing = lines.filter({ $0.minY < bottom && $0.maxY > bottom }).map(\.maxY).max(),
                   crossing + 2 < top {
                    bottom = crossing + 2
                }
                context.beginPDFPage(nil)
                context.saveGState()
                context.clip(to: CGRect(x: 36, y: 756 - (top - bottom) * scale, width: 540, height: (top - bottom) * scale))
                context.translateBy(x: 36 - bounds.minX * scale, y: 756 - top * scale)
                context.scaleBy(x: scale, y: scale)
                context.drawPDFPage(page)
                context.restoreGState()
                context.endPDFPage()
                pages += 1
                top = bottom
                guard output.length <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
            }
        }
        context.closePDF(); closed = true
        guard output.length > 0, output.length <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
        return output as Data
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { initialPending = false; finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(error) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let decision = MailHTMLNavigationDecision.decide(url: action.request.url, navigationType: action.navigationType,
            isMainFrame: action.targetFrame?.isMainFrame == true, initialDocumentPending: initialPending)
        return decision == .allowInitialDocument ? .allow : .cancel
    }
    private func finish(_ error: (any Error)?) {
        timeout?.cancel()
        if let promise = continuation {
            continuation = nil
            if let error { promise.resume(throwing: error) } else { promise.resume() }
        }
        if let promise = pdfContinuation {
            pdfContinuation = nil
            promise.resume(throwing: error ?? MailExportError.renderingFailed)
        }
    }
    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
