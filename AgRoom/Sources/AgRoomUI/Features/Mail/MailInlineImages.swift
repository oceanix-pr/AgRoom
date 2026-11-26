import Foundation
import ImageIO
import Observation
import WebKit
import AgRoomCore

struct MailInlineImage: Sendable {
    let data: Data
    let mimeType: String
    let pixels: Int
    var isDownsampled = false
}

enum MailInlineImageError: String, Error, CaseIterable {
    case unavailable, missingPart, downloadFailed, unsupportedFormat, invalidImage, capacity
}

/// Validate raster metadata off the main actor, with one decoder at a time.
private actor MailInlineImageDecoder {
    static let shared = MailInlineImageDecoder()
    static let byteLimit = 5 * 1024 * 1024
    private static let displayPixels = 16_000_000
    private let types = ["public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif",
                         "public.tiff": "image/tiff", "org.webmproject.webp": "image/webp", "public.heic": "image/heic",
                         "public.heif": "image/heif", "com.microsoft.bmp": "image/bmp", "public.avif": "image/avif"]

    func decode(_ data: Data) throws -> MailInlineImage {
        try Task.checkCancellation()
        guard data.count <= Self.byteLimit else { throw MailInlineImageError.capacity }
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else { throw MailInlineImageError.invalidImage }
        guard let mime = types[type as String] else { throw MailInlineImageError.unsupportedFormat }
        guard CGImageSourceGetStatus(source) == .statusComplete else { throw MailInlineImageError.invalidImage }
        let frames = CGImageSourceGetCount(source)
        guard frames > 0, frames <= 100 else { throw MailInlineImageError.capacity }
        var pixels = 0
        for index in 0..<frames {
            try Task.checkCancellation()
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else { throw MailInlineImageError.invalidImage }
            if frames == 1 {
                // Dimensions describe geometry, not admission. A tall, narrow
                // image can be cheap to decode; only its total area uses memory.
                guard width <= 64_000_000 / height else { throw MailInlineImageError.capacity }
                if width > Self.displayPixels / height {
                    // Never create a full-resolution CGImage before downsampling.
                    return try Self.preview(source, width: width, height: height, mimeType: mime)
                }
            } else {
                // Keep animation/frame budgets; a poster preview must not
                // silently discard frames from an animated or multi-page image.
                guard width <= (Self.displayPixels - pixels) / height else { throw MailInlineImageError.capacity }
            }
            pixels += width * height
        }
        guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { throw MailInlineImageError.invalidImage }
        return .init(data: data, mimeType: mime, pixels: pixels)
    }

    private static func preview(_ source: CGImageSource, width: Int, height: Int, mimeType: String) throws -> MailInlineImage {
        let longest = Double(max(width, height))
        let scale = sqrt(Double(displayPixels) / (Double(width) * Double(height)))
        // Account for the short side rounding up to at least one pixel. This
        // derives a preview size from area, without an independent edge limit.
        let shortSide = max(1, Int(ceil(Double(min(width, height)) * scale)))
        var dimension = max(1, min(Int(floor(longest * scale)), displayPixels / shortSide))
        let jpeg = mimeType == "image/jpeg"
        for _ in 0..<4 {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw MailInlineImageError.invalidImage }
            guard image.width > 0, image.height > 0,
                  image.width <= displayPixels / image.height else {
                // ImageIO applies orientation and pixel-aspect transforms.
                // Recompute from the actual result rather than guessing edges.
                let ratio = Double(displayPixels) / (Double(image.width) * Double(image.height))
                dimension = max(1, min(dimension - 1, Int(floor(Double(dimension) * min(0.99, ratio)))))
                continue
            }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil) else {
                throw MailInlineImageError.invalidImage
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw MailInlineImageError.invalidImage }
            try Task.checkCancellation()
            if bytes.length <= byteLimit {
                return .init(data: bytes as Data, mimeType: jpeg ? "image/jpeg" : "image/png",
                    pixels: image.width * image.height, isDownsampled: true)
            }
            // A noisy or high-bit-depth PNG can be larger after resizing. Keep
            // the delivered preview bounded too, with a fixed retry limit.
            dimension = max(1, dimension / 2)
        }
        throw MailInlineImageError.capacity
    }
}

/// Each source owns exactly one mail identity in one space. Only matching MIME
/// attachments can be read; CID strings are never treated as paths or web URLs.
@MainActor @Observable
final class MailInlineImageSource {
    let id = UUID()
    let messageID: UUID
    private let hub: Hub
    private let space: AppSpace
    private let downloadMissing: Bool
    private(set) var revision = UUID()
    private(set) var failureCount = 0
    private(set) var failureReasons: [MailInlineImageError] = []
    private(set) var downsampledCount = 0
    private(set) var refreshedAttachments: [MailAttachment]?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cache: [String: MailInlineImage] = [:]
    @ObservationIgnored private var failures: [String: MailInlineImageError] = [:]
    @ObservationIgnored private var byteCount = 0
    @ObservationIgnored private var pixelCount = 0
    private struct Pending {
        let task: Task<MailInlineImage, Error>
        var waiters: Set<UUID>
    }
    @ObservationIgnored private var pending: [String: Pending] = [:]
    @ObservationIgnored private var activeSlots: Set<UUID> = []
    @ObservationIgnored private var waitingSlots: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var slotOrder: [UUID] = []
    @ObservationIgnored private var metadataRefresh: Task<Void, Error>?
    @ObservationIgnored private var metadataRefreshAttempted = false
    @ObservationIgnored private var metadataRefreshFinished = false
    var readAttachment: @MainActor (UUID, UUID, Bool) async throws -> Data
    var refreshAttachments: @MainActor (MailMessage) async throws -> Void
    var onAttachmentsRefreshed: @MainActor ([MailAttachment]) -> Void = { _ in }

    init(hub: Hub, space: AppSpace, messageID: UUID, downloadMissing: Bool = true, exportReview: MailExportReview? = nil,
         syncService: MailSyncService? = nil) {
        self.hub = hub; self.space = space; self.messageID = messageID; self.downloadMissing = downloadMissing
        self.readAttachment = { messageID, attachmentID, download in
            guard let sync = syncService ?? hub.makeMailSyncService(for: space) else { throw MailInlineImageError.unavailable }
            let url = try await sync.downloadAttachment(messageId: messageID, attachmentID: attachmentID, downloadIfNeeded: download, maxBytes: 5 * 1024 * 1024, exportReview: exportReview)
            let read = Task.detached { try MailAttachmentFile.read(url, maxBytes: 5 * 1024 * 1024) }
            return try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        }
        self.refreshAttachments = { expected in
            guard let sync = syncService ?? hub.makeMailSyncService(for: space) else { throw MailInlineImageError.unavailable }
            try await sync.refreshInlineImageAttachments(messageId: messageID, downloadIfNeeded: downloadMissing,
                exportReview: exportReview, expectedMessage: expected)
        }
    }

    static func contentID(_ value: String) -> String? {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("<"), result.hasSuffix(">") { result = String(result.dropFirst().dropLast()) }
        guard !result.isEmpty, result.utf8.count <= 1024,
              result.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return result
    }

    static func contentID(url: URL) -> String? {
        guard url.scheme?.lowercased() == "cid", let colon = url.absoluteString.firstIndex(of: ":"),
              let decoded = String(url.absoluteString[url.absoluteString.index(after: colon)...]).removingPercentEncoding,
              !decoded.hasPrefix("//") else { return nil }
        return contentID(decoded)
    }

    func image(for url: URL) async throws -> MailInlineImage {
        try Task.checkCancellation()
        guard let key = Self.contentID(url: url) else { noteFailure(String(decoding: url.absoluteString.utf8.prefix(1024), as: UTF8.self), .unavailable); throw MailInlineImageError.unavailable }
        if let cached = cache[key] { return cached }
        guard Set(cache.keys).union(pending.keys).union(failures.keys).count < 64 || pending[key] != nil || failures[key] != nil else { noteFailure(key, .capacity); throw MailInlineImageError.capacity }
        let ticket = generation, waiter = UUID()
        if pending[key] == nil {
            let task = Task { try await self.fetch(key) }
            pending[key] = .init(task: task, waiters: [])
        }
        pending[key]?.waiters.insert(waiter)
        guard let job = pending[key] else { throw CancellationError() }
        defer { release(key, waiter: waiter) }
        return try await withTaskCancellationHandler {
            do {
                let image = try await job.task.value
                try Task.checkCancellation()
                guard generation == ticket else { throw CancellationError() }
                if cache[key] == nil {
                    guard image.data.count <= 20 * 1024 * 1024 - byteCount, image.pixels <= 32_000_000 - pixelCount else { throw MailInlineImageError.capacity }
                    cache[key] = image; byteCount += image.data.count; pixelCount += image.pixels
                    if image.isDownsampled { downsampledCount += 1 }
                }
                failures.removeValue(forKey: key); updateFailures()
                return image
            } catch {
                if generation == ticket, !Task.isCancelled, !(error is CancellationError) {
                    noteFailure(key, Self.failureReason(error))
                }
                throw error
            }
        } onCancel: { Task { @MainActor [weak self] in self?.release(key, waiter: waiter) } }
    }

    private static func failureReason(_ error: Error) -> MailInlineImageError {
        if let reason = error as? MailInlineImageError { return reason }
        if case MailProtocolError.messageTooLarge = error { return .capacity }
        if let error = error as? MailExportError {
            switch error {
            case .tooLarge: return .capacity
            case .changed: return .unavailable
            case .incomplete: return .missingPart
            default: break
            }
        }
        return .downloadFailed
    }

    private func noteFailure(_ key: String, _ reason: MailInlineImageError) {
        if failures.count < 64 || failures[key] != nil { failures[key] = reason }
        updateFailures()
    }

    private func updateFailures() {
        failureCount = failures.count
        failureReasons = MailInlineImageError.allCases.filter { failures.values.contains($0) }
    }

    private func release(_ key: String, waiter: UUID) {
        guard var job = pending[key], job.waiters.remove(waiter) != nil else { return }
        if job.waiters.isEmpty {
            pending.removeValue(forKey: key); job.task.cancel()
            if pending.isEmpty, !metadataRefreshFinished { metadataRefresh?.cancel(); metadataRefresh = nil }
        }
        else { pending[key] = job }
    }

    private func fetch(_ key: String) async throws -> MailInlineImage {
        let ticket = generation
        let slot = UUID()
        try await acquireSlot(slot)
        defer { releaseSlot(slot) }
        try Task.checkCancellation()
        guard let mail = hub.makeMailService(for: space), let message = try await mail.message(id: messageID) else { throw MailInlineImageError.unavailable }
        var candidates = try await mail.attachments(messageId: messageID).filter { $0.contentId.flatMap(Self.contentID) == key }
        if candidates.isEmpty {
            // Coalesce repair across different CID requests. Retrying explicitly
            // starts a new generation; broken HTML cannot cause unbounded reads.
            if metadataRefresh == nil, !metadataRefreshAttempted {
                metadataRefreshAttempted = true
                metadataRefresh = Task {
                    defer { if self.generation == ticket { self.metadataRefreshFinished = true } }
                    try await self.refreshAttachments(message)
                }
            }
            if let metadataRefresh { try await metadataRefresh.value }
            try Task.checkCancellation()
            let parts = try await mail.attachments(messageId: messageID)
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            refreshedAttachments = parts; onAttachmentsRefreshed(parts)
            candidates = parts.filter { $0.contentId.flatMap(Self.contentID) == key }
        }
        guard candidates.count == 1, let attachment = candidates.first,
              attachment.messageId == messageID else { throw MailInlineImageError.missingPart }
        guard attachment.mimeType.lowercased().hasPrefix("image/"),
              attachment.mimeType.lowercased() != "image/svg+xml" else { throw MailInlineImageError.unsupportedFormat }
        guard attachment.sizeBytes <= MailInlineImageDecoder.byteLimit else { throw MailInlineImageError.capacity }
        let bytes = try await readAttachment(messageID, attachment.id, downloadMissing)
        try Task.checkCancellation()
        guard let current = try await mail.message(id: messageID), current.accountId == message.accountId,
              current.folderId == message.folderId, current.uid == message.uid, current.messageId == message.messageId else { throw MailInlineImageError.unavailable }
        return try await MailInlineImageDecoder.shared.decode(bytes)
    }

    private func acquireSlot(_ id: UUID) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (promise: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { promise.resume(throwing: CancellationError()); return }
                if activeSlots.count < 2 { activeSlots.insert(id); promise.resume() }
                else { slotOrder.append(id); waitingSlots[id] = promise }
            }
        } onCancel: { Task { @MainActor [weak self] in
            self?.slotOrder.removeAll { $0 == id }
            self?.waitingSlots.removeValue(forKey: id)?.resume(throwing: CancellationError())
        } }
    }

    private func releaseSlot(_ id: UUID) {
        guard activeSlots.remove(id) != nil else { return }
        while !slotOrder.isEmpty {
            let next = slotOrder.removeFirst()
            guard let promise = waitingSlots.removeValue(forKey: next) else { continue }
            activeSlots.insert(next); promise.resume(); break
        }
    }

    func cancelPending() {
        generation = UUID()
        let jobs = pending.values; pending = [:]
        jobs.forEach { $0.task.cancel() }
        metadataRefresh?.cancel(); metadataRefresh = nil; metadataRefreshAttempted = false; metadataRefreshFinished = false
    }

    func retry() {
        cancelPending(); cache = [:]; failures = [:]; byteCount = 0; pixelCount = 0
        failureCount = 0; failureReasons = []; downsampledCount = 0; refreshedAttachments = nil; revision = UUID()
    }
}

/// All WebKit callbacks and resource state belong to the main actor. Stopped or
/// replaced tasks are removed before cancelling work, so late results cannot call WebKit.
@MainActor
final class MailInlineImageHandler: NSObject, WKURLSchemeHandler {
    private struct Entry {
        let token: UUID
        let task: any WKURLSchemeTask
        let work: Task<Void, Never>
    }
    private var source: MailInlineImageSource?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private(set) var failureCount = 0

    func replaceSource(_ source: MailInlineImageSource?) {
        guard self.source !== source else { return }
        invalidate(); self.source = source; failureCount = 0
    }

    func invalidate() {
        let current = entries.values; entries = [:]
        current.forEach { $0.work.cancel() }
        source?.cancelPending(); source = nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let source, let url = urlSchemeTask.request.url else { failureCount += 1; urlSchemeTask.didFailWithError(MailInlineImageError.unavailable); return }
        let key = ObjectIdentifier(urlSchemeTask), token = UUID()
        let work = Task { [weak self] in
            do {
                let image = try await source.image(for: url)
                guard let self, self.entries[key]?.token == token, !Task.isCancelled else { return }
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": image.mimeType, "Content-Length": String(image.data.count), "Cache-Control": "no-store"]) else { throw MailInlineImageError.unavailable }
                urlSchemeTask.didReceive(response)
                guard self.entries[key]?.token == token else { return }
                urlSchemeTask.didReceive(image.data)
                guard self.entries.removeValue(forKey: key)?.token == token else { return }
                urlSchemeTask.didFinish()
            } catch {
                guard let self, self.entries.removeValue(forKey: key)?.token == token else { return }
                self.failureCount += 1
                urlSchemeTask.didFailWithError(error)
            }
        }
        entries[key] = .init(token: token, task: urlSchemeTask, work: work)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        entries.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.work.cancel()
    }
}
