import AppKit
import CryptoKit
import Observation
import SwiftUI
import AgRoomCore

@MainActor @Observable
final class MailAttachmentQueue {
    enum State: String { case queued, running, complete, failed, cancelled }
    struct Entry: Identifiable {
        let id: UUID
        let attachment: MailAttachment
        let source: MailMessage
        let review: MailExportReview
        var state = State.queued
        var url: URL?
        var sha256: String?
        var bytes: Int?
        var error: String?
        var terminal: Bool { state != .queued && state != .running }
    }
    private let hub: Hub
    private let space: AppSpace
    private(set) var entries: [Entry] = []
    private(set) var paused = false
    private(set) var error: String?
    private var generation = UUID()
    private var preparingCount = 0
    private var worker: Task<Void, Never>?
    private var active: Task<URL, Error>?
    private var activeRead: Task<(Int, String), Error>?
    private var waiters: [UUID: [UUID: CheckedContinuation<URL?, Never>]] = [:]
    var makeSyncService: @MainActor () -> MailSyncService?
    var pendingIDs: Set<UUID> { Set(entries.filter { !$0.terminal }.map(\.attachment.id)) }
    var activeCount: Int { entries.filter { !$0.terminal }.count + preparingCount }
    var hasFailures: Bool { error != nil || entries.contains { $0.state == .failed } }

    init(hub: Hub, space: AppSpace) {
        self.hub = hub; self.space = space; makeSyncService = { hub.makeMailSyncService(for: space) }
    }

    func request(_ attachment: MailAttachment, source: MailMessage?) async -> URL? {
        guard !Task.isCancelled, let source, source.id == attachment.messageId else { return nil }
        let epoch = generation
        do {
            let id: UUID
            if let current = entries.first(where: { !$0.terminal && $0.attachment.id == attachment.id && $0.source.uid == source.uid && $0.source.folderId == source.folderId }) { id = current.id }
            else {
                if entries.count + preparingCount >= 200 { clearFinished() }
                guard entries.count + preparingCount < 200 else { error = L.string("mail.downloads.full"); return nil }
                preparingCount += 1
                defer { preparingCount -= 1 }
                guard let mail = hub.makeMailService(for: space) else { throw MailExportError.changed }
                let review = try await mail.reviewExport(ids: [source.id])
                guard let actual = review.source(source.id)?.message, actual.accountId == source.accountId,
                      actual.folderId == source.folderId, actual.uid == source.uid, actual.messageId == source.messageId else { throw MailExportError.changed }
                try Task.checkCancellation()
                guard generation == epoch else { return nil }
                // Recheck after the read: two consumers may have selected the
                // same attachment while the first review was awaiting its DB.
                if let current = entries.first(where: { !$0.terminal && $0.attachment.id == attachment.id && $0.source.uid == source.uid && $0.source.folderId == source.folderId }) { id = current.id }
                else {
                    if entries.count >= 200 { clearFinished() }
                    guard entries.count < 200 else { throw MailAttachmentError.capacity }
                    id = UUID(); entries.append(.init(id: id, attachment: attachment, source: source, review: review))
                }
            }
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled, generation == epoch else { continuation.resume(returning: nil); return }
                    waiters[id, default: [:]][waiterID] = continuation
                    schedule()
                }
            } onCancel: {
                Task { @MainActor in self.waiters[id]?.removeValue(forKey: waiterID)?.resume(returning: nil) }
            }
        } catch is CancellationError { return nil }
        catch { if generation == epoch { self.error = MailErrorText.message(for: error) }; return nil }
    }

    func togglePaused() { paused.toggle(); if !paused { schedule() } }

    func cancel(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].terminal else { return }
        if entries[index].state == .running { active?.cancel(); activeRead?.cancel() }
        entries[index].state = .cancelled
        completeWaiters(id, url: nil)
    }

    func cancelAll() {
        generation = UUID(); active?.cancel(); activeRead?.cancel(); worker?.cancel(); active = nil; activeRead = nil; worker = nil
        for index in entries.indices where !entries[index].terminal { entries[index].state = .cancelled }
        let pending = waiters; waiters = [:]
        for group in pending.values { for waiter in group.values { waiter.resume(returning: nil) } }
    }

    func retry(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), entry.state == .failed || entry.state == .cancelled else { return }
        if entries.count >= 200 { clearFinished() }
        guard entries.count < 200 else { return }
        // Keep the original source proof; a changed UID or folder is not silently
        // adopted as a retry of the previously selected attachment.
        entries.append(.init(id: UUID(), attachment: entry.attachment, source: entry.source, review: entry.review))
        schedule()
    }

    func clearFinished() { entries.removeAll { $0.terminal && waiters[$0.id]?.isEmpty != false }; error = nil }

    func open(_ id: UUID, reveal: Bool) async {
        guard let entry = entries.first(where: { $0.id == id }), entry.state == .complete,
              let url = entry.url, let expected = entry.sha256 else { return }
        let epoch = generation
        do {
            guard let mail = hub.makeMailService(for: space) else { throw MailExportError.changed }
            try await mail.validateExport(entry.review, messageID: entry.source.id)
            let digest = try await Task.detached { Self.digest(try MailAttachmentFile.read(url)) }.value
            guard digest == expected else { throw MailExportError.changed }
            guard generation == epoch, !Task.isCancelled else { return }
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.open(url) }
        } catch { if generation == epoch { self.error = MailErrorText.message(for: error) } }
    }

    private func schedule() {
        guard worker == nil, !paused, entries.contains(where: { $0.state == .queued }) else { return }
        let epoch = generation
        worker = Task {
            while generation == epoch, !paused, !Task.isCancelled,
                  let index = entries.firstIndex(where: { $0.state == .queued }) {
                let entry = entries[index]; entries[index].state = .running
                let download = Task { () throws -> URL in
                    guard let sync = makeSyncService(), let mail = hub.makeMailService(for: space) else { throw MailExportError.changed }
                    try await mail.validateExport(entry.review, messageID: entry.source.id)
                    return try await sync.downloadAttachment(messageId: entry.source.id, attachmentID: entry.attachment.id,
                        exportReview: entry.review, expectedAttachment: entry.attachment)
                }
                active = download
                do {
                    let url = try await download.value
                    guard !download.isCancelled else { throw CancellationError() }
                    let read = Task.detached { () throws -> (Int, String) in
                        try Task.checkCancellation()
                        let data = try MailAttachmentFile.read(url)
                        try Task.checkCancellation()
                        return (data.count, Self.digest(data))
                    }
                    activeRead = read
                    let (bytes, digest) = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                    guard generation == epoch, let current = entries.firstIndex(where: { $0.id == entry.id }) else { break }
                    if entries[current].state == .running {
                        entries[current].url = url; entries[current].sha256 = digest
                        entries[current].bytes = bytes; entries[current].state = .complete
                        completeWaiters(entry.id, url: url)
                    }
                } catch {
                    guard generation == epoch, let current = entries.firstIndex(where: { $0.id == entry.id }) else { break }
                    if entries[current].state == .running {
                        entries[current].state = error is CancellationError ? .cancelled : .failed
                        entries[current].error = error is CancellationError ? nil : MailErrorText.message(for: error)
                    }
                    completeWaiters(entry.id, url: nil)
                }
                active = nil; activeRead = nil
            }
            if generation == epoch { worker = nil; active = nil; activeRead = nil }
        }
    }

    private func completeWaiters(_ id: UUID, url: URL?) {
        let group = waiters.removeValue(forKey: id) ?? [:]
        for waiter in group.values { waiter.resume(returning: url) }
    }
    nonisolated private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct MailAttachmentQueueView: View {
    @Bindable var model: MailAttachmentQueue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("mail.downloads.title")).font(.headline)
            HStack {
                Button(L.string(model.paused ? "mail.downloads.resume" : "mail.downloads.pause")) { model.togglePaused() }
                Button(L.string("mail.downloads.cancelAll")) { model.cancelAll() }.disabled(model.activeCount == 0)
                Button(L.string("mail.downloads.clear")) { model.clearFinished() }
            }
            Text(L.string("mail.downloads.hint")).font(.caption).foregroundStyle(.secondary)
            if model.entries.isEmpty { Text(L.string("mail.downloads.empty")).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.attachment.filename).lineLimit(2)
                            Text(entry.source.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            HStack {
                                if entry.state == .running { ProgressView().controlSize(.small) }
                                Text(L.string("mail.downloads.state." + entry.state.rawValue)).font(.caption)
                                if let bytes = entry.bytes { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.caption) }
                                Spacer()
                                if !entry.terminal { Button(L.string("common.cancel")) { model.cancel(entry.id) } }
                                if entry.state == .failed || entry.state == .cancelled { Button(L.string("mail.downloads.retry")) { model.retry(entry.id) } }
                                if entry.state == .complete {
                                    Button(L.string("mail.attachment.open")) { Task { await model.open(entry.id, reveal: false) } }
                                    Button(L.string("files.reveal")) { Task { await model.open(entry.id, reveal: true) } }
                                }
                            }
                            if let error = entry.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        }
                        Divider()
                    }
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(16).frame(width: 500, height: 440)
    }
}
