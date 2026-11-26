import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import AgRoomCore

@MainActor @Observable final class MailFinderDragModel: Identifiable {
    let id = UUID()
    let message: MailMessage
    let space: AppSpace
    private let hub: Hub
    private(set) var raw: MailRawMessage?
    private(set) var review: MailExportReview?
    private(set) var busy = false
    private(set) var error: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var closed = false
    var filename: String { MailExportDestination.safeName(String(message.subject.prefix(100)).isEmpty ? "mail" : String(message.subject.prefix(100))) + ".eml" }
    init(message: MailMessage, hub: Hub, space: AppSpace) { self.message = message; self.hub = hub; self.space = space }

    func prepare(download: Bool = false) {
        guard !closed, !busy, hub.spaceStore.current == space else { return }
        let token = UUID(); generation = token; busy = true; error = nil; raw = nil; review = nil
        task = Task {
            defer { if generation == token { busy = false; task = nil } }
            do {
                guard let mail = hub.makeMailService(for: space), let sync = hub.makeMailSyncService(for: space) else { throw MailExportError.changed }
                let reference = MailSourceReference(message: message, space: space)
                _ = try await mail.resolveSourceReference(reference, in: space)
                let frozen = try await mail.reviewExport(ids: [message.id])
                guard let source = frozen.source(message.id), source.message.folderId == message.folderId,
                      source.message.uid == message.uid else { throw MailExportError.changed }
                let value = try await sync.rawMessage(messageId: message.id, downloadIfNeeded: download, exportReview: frozen)
                try await mail.validateExport(frozen)
                guard generation == token, !closed, !Task.isCancelled, hub.spaceStore.current == space else { return }
                raw = value; review = frozen
            } catch {
                if generation == token, !closed, !Task.isCancelled { self.error = MailErrorText.message(for: error) }
            }
        }
    }

    func write(_ data: Data, review: MailExportReview, to url: URL) async throws {
        guard !closed, hub.spaceStore.current == space, let mail = hub.makeMailService(for: space) else { throw MailExportError.changed }
        try await mail.validateExport(review)
        guard !closed, hub.spaceStore.current == space, !Task.isCancelled else { throw CancellationError() }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Finder supplies an exact destination. Existing files are never replaced.
        let destination = try MailExportDestination(directory: url.deletingLastPathComponent())
        _ = try await destination.writePlanned(data, components: [url.lastPathComponent])
    }
    func report(_ value: Error) { if !closed { error = MailErrorText.message(for: value) } }
    func close() { closed = true; generation = UUID(); task?.cancel(); task = nil; raw = nil; review = nil; busy = false }
}

struct MailFinderDragView: View {
    @State var model: MailFinderDragModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string("mail.drag.title")).font(.headline)
            Text(model.message.subject).lineLimit(2)
            Text(L.string("mail.drag.hint")).font(.caption).foregroundStyle(.secondary)
            if let raw = model.raw, let review = model.review {
                MailFinderDragHandle(model: model, data: raw.data, review: review).frame(height: 70)
                    .accessibilityLabel(L.string("mail.drag.handle"))
                if raw.kind == .generated { Text(L.string("mail.export.generatedHint")).font(.caption).foregroundStyle(.secondary) }
                Text(ByteCountFormatter.string(fromByteCount: Int64(raw.data.count), countStyle: .file)).font(.caption)
            } else if model.busy { ProgressView() }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if model.raw == nil { Button(L.string("mail.source.download")) { model.prepare(download: true) }.disabled(model.busy) }
                Spacer()
                Button(L.string("common.close")) { model.close(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 560, height: 300)
            .task { model.prepare() }.onDisappear { model.close() }
    }
}

private struct MailFinderDragHandle: NSViewRepresentable {
    let model: MailFinderDragModel
    let data: Data
    let review: MailExportReview
    func makeNSView(context: Context) -> Handle { let view = Handle(); configure(view); return view }
    func updateNSView(_ view: Handle, context: Context) { configure(view) }
    private func configure(_ view: Handle) { view.model = model; view.data = data; view.review = review; view.toolTip = L.string("mail.drag.handle") }

    @MainActor final class Handle: NSView, NSDraggingSource {
        var model: MailFinderDragModel?
        var data = Data()
        var review: MailExportReview?
        private var start: NSPoint?
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            let label = L.string("mail.drag.handle") as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: max(8, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
        override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
        override func mouseDragged(with event: NSEvent) {
            guard let start, let model, let review else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard abs(point.x - start.x) + abs(point.y - start.y) >= 4 else { return }
            self.start = nil
            let delegate = Promise(model: model, data: data, review: review)
            let provider = NSFilePromiseProvider(fileType: UTType(filenameExtension: "eml")?.identifier ?? "public.data", delegate: delegate)
            provider.userInfo = delegate // The promise must outlive the drag source view.
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSImage(systemSymbolName: "envelope", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 32, height: 32))
            item.setDraggingFrame(NSRect(origin: point, size: NSSize(width: 48, height: 48)), contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    }

    // AppKit invokes the writer outside the UI actor. This box transfers its
    // one-shot callback into a single task; no callback runs while holding a lock.
    private final class Completion: @unchecked Sendable {
        let call: (Error?) -> Void
        init(_ call: @escaping (Error?) -> Void) { self.call = call }
    }
    @MainActor private final class Promise: NSObject, NSFilePromiseProviderDelegate {
        let model: MailFinderDragModel
        let data: Data
        let review: MailExportReview
        init(model: MailFinderDragModel, data: Data, review: MailExportReview) { self.model = model; self.data = data; self.review = review }
        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { model.filename }
        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            let completion = Completion(completionHandler)
            Task { @MainActor in
                do { try await model.write(data, review: review, to: url); completion.call(nil) }
                catch { model.report(error); completion.call(error) }
            }
        }
    }
}
