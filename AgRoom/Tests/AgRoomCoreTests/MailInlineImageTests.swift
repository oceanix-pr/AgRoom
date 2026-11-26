import AppKit
import Foundation
import GRDB
import ImageIO
import PDFKit
import SwiftUI
import Testing
import WebKit
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Mail CID images")
struct MailInlineImageTests {
    @MainActor final class SchemeTask: NSObject, @MainActor WKURLSchemeTask {
        let request: URLRequest
        var data = Data()
        var responses: [URLResponse] = []
        var finishes = 0
        var errors = 0
        init(_ url: String) { request = URLRequest(url: URL(string: url)!) }
        func didReceive(_ response: URLResponse) { responses.append(response) }
        func didReceive(_ data: Data) { self.data.append(data) }
        func didFinish() { finishes += 1 }
        func didFailWithError(_ error: any Error) { errors += 1 }
    }

    private struct Fixture {
        let queue: DatabaseQueue
        let mail: MailService
        let hub: Hub
        let first: MailMessage
        let second: MailMessage
        let firstPart: MailAttachment
        let secondPart: MailAttachment
    }

    @MainActor private func fixture() async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue)
        let account = try await mail.createLocalArchive(name: "Inline fixtures", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let folder = try #require(try await mail.folders(accountId: account.id).first { $0.role == .inbox })
        let first = MailMessage(accountId: account.id, folderId: folder.id, uid: MailService.localUIDFloor, subject: "First", bodyState: .ready)
        let second = MailMessage(accountId: account.id, folderId: folder.id, uid: MailService.localUIDFloor + 1, subject: "Second", bodyState: .ready)
        try await mail.upsertMessages([first, second])
        let firstPart = MailAttachment(messageId: first.id, filename: "logo.png", mimeType: "image/png", contentId: "<logo@example.test>", isInline: true)
        let secondPart = MailAttachment(messageId: second.id, filename: "logo.png", mimeType: "image/png", contentId: "logo@example.test", isInline: true)
        try await mail.saveAttachments([firstPart, secondPart])
        return .init(queue: queue, mail: mail, hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), first: first, second: second,
            firstPart: firstPart, secondPart: secondPart)
    }

    private func png(_ color: UInt8 = 255, width: Int = 32, height: Int = 24) throws -> Data {
        var pixels = Data()
        for _ in 0..<(width * height) { pixels.append(contentsOf: [0, color, 255, 255]) }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A compressible announcement poster with distinct top and bottom bands.
    /// Fill only the bands/lines rather than appending every background pixel.
    private func poster(width: Int, height: Int, type: String = "public.jpeg") throws -> Data {
        var pixels = Data(repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let color: (UInt8, UInt8, UInt8, UInt8)
                if y < 120 { color = (0, 255, 255, type == "public.png" ? 128 : 255) }
                else if y >= height - 240 { color = (255, 0, 255, 255) }
                else if y % 240 < 2 { color = (150, 150, 150, 255) }
                else { continue }
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    buffer[offset] = color.0; buffer[offset + 1] = color.1
                    buffer[offset + 2] = color.2; buffer[offset + 3] = color.3
                }
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func excessivePixelMetadata() throws -> Data {
        // A JPEG container declaring excessive area, with a tiny scan payload.
        // The decoder must reject metadata before attempting a giant allocation.
        var data = try poster(width: 1, height: 1)
        let marker = try #require((0..<(data.count - 9)).first {
            data[$0] == 0xff && [UInt8(0xc0), 0xc1, 0xc2].contains(data[$0 + 1])
        })
        for offset in [marker + 5, marker + 7] { data[offset] = 0x27; data[offset + 1] = 0x10 }
        return data
    }

    @MainActor
    @Test("Long posters render in full; larger static pictures use bounded previews without changing their original bytes",
          arguments: ["longJPEG", "largeJPEG", "transparentPNG", "tallPNG", "tallPreview"])
    func longStaticImages(_ kind: String) async throws {
        let f = try await fixture()
        let width: Int, height: Int, type: String, needsPreview: Bool
        switch kind {
        case "longJPEG": (width, height, type, needsPreview) = (900, 10_121, "public.jpeg", false)
        case "largeJPEG": (width, height, type, needsPreview) = (1800, 20_000, "public.jpeg", true)
        case "transparentPNG": (width, height, type, needsPreview) = (900, 20_000, "public.png", true)
        case "tallPNG": (width, height, type, needsPreview) = (32, 70_000, "public.png", false)
        default: (width, height, type, needsPreview) = (100, 200_000, "public.png", true)
        }
        let bytes = try poster(width: width, height: height, type: type)
        #expect(bytes.count < 5 * 1024 * 1024)
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        source.readAttachment = { _, _, _ in bytes }
        let image = try await source.image(for: URL(string: "cid:logo@example.test")!)
        let decoded = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
        let renderedWidth = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let renderedHeight = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        #expect(image.pixels == renderedWidth * renderedHeight && source.failureCount == 0)
        #expect(image.pixels <= 16_000_000)
        #expect(image.data.count <= 5 * 1024 * 1024)
        if !needsPreview {
            #expect(image.data == bytes && image.pixels == width * height && !image.isDownsampled && source.downsampledCount == 0)
        } else {
            #expect(image.data != bytes && image.isDownsampled && source.downsampledCount == 1)
            #expect(abs(Double(renderedWidth) / Double(renderedHeight) - Double(width) / Double(height)) < 0.001)
            _ = try await source.image(for: URL(string: "cid:logo@example.test")!)
            #expect(source.downsampledCount == 1)
        }
        #expect(image.mimeType == (type == "public.png" ? "image/png" : "image/jpeg"))
        if kind == "tallPNG" || kind == "tallPreview" { #expect(renderedHeight > 65_536) }
        if kind == "transparentPNG" { #expect((properties[kCGImagePropertyHasAlpha] as? Bool) == true) }
        source.retry()
        #expect(source.downsampledCount == 0)
    }

    @MainActor
    @Test("Multi-frame pictures keep tall frames when their cumulative area fits the budget")
    func tallMultipleFrames() async throws {
        let f = try await fixture(), posterBytes = try poster(width: 32, height: 70_000, type: "public.png")
        let original = try #require(CGImageSourceCreateWithData(posterBytes as CFData, nil))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.tiff" as CFString, 2, nil))
        let properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary
        for _ in 0..<2 { CGImageDestinationAddImageFromSource(destination, original, 0, properties) }
        #expect(CGImageDestinationFinalize(destination))
        let data = bytes as Data
        #expect(data.count < 5 * 1024 * 1024)
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        source.readAttachment = { _, _, _ in data }
        let image = try await source.image(for: URL(string: "cid:logo@example.test")!)
        #expect(image.data == data && image.mimeType == "image/tiff" && image.pixels == 32 * 70_000 * 2)
        #expect(!image.isDownsampled && source.downsampledCount == 0 && source.failureCount == 0)
        let decoded = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        #expect(CGImageSourceGetCount(decoded) == 2)
    }

    @MainActor
    @Test("Old cached mail repairs missing CID metadata from its retained original without credentials or network")
    func repairFromRetainedOriginal() async throws {
        let f = try await fixture(), bytes = try png()
        try await f.mail.replaceAttachments(messageId: f.first.id, attachments: [])
        let original = Data([
            "From: sender@example.test", "MIME-Version: 1.0", "Content-Type: multipart/related; boundary=repair", "",
            "--repair", "Content-Type: text/html; charset=utf-8", "", "<img src='cid:logo@example.test'>",
            "--repair", "Content-Type: image/png", "Content-ID: <logo@example.test>",
            "Content-Transfer-Encoding: base64", "", bytes.base64EncodedString(), "--repair--", ""
        ].joined(separator: "\r\n").utf8)
        try await f.mail.saveRawMessage(id: f.first.id, raw: .init(data: original, kind: .imported))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = MockMailClient()
        let sync = MailSyncService(accountService: MailAccountService(databaseQueue: f.queue, space: .work), mail: f.mail, space: .work,
            attachmentDirectory: root, clientFactory: { _ in client }, passwordProvider: { _ in Issue.record("Offline repair read credentials"); return nil })
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id, downloadMissing: false, syncService: sync)
        #expect(try await source.image(for: URL(string: "cid:logo@example.test")!).data == bytes)
        #expect(source.refreshedAttachments?.count == 1 && source.failureCount == 0)
        let part = try #require(try await f.mail.attachments(messageId: f.first.id).first)
        #expect(part.isInline && part.partID == "local:0" && part.localPath != nil)
        #expect(await client.connectCount == 0)
        try await f.mail.saveBody(.init(messageId: f.first.id, htmlBody: "<img src='cid:logo@example.test'>"))
        try await f.mail.replaceAttachments(messageId: f.first.id, attachments: [])
        let model = MailViewModel(hub: f.hub, space: .work)
        await model.selectMessage(f.first.id)
        let modelImages = try #require(model.inlineImages)
        modelImages.readAttachment = { _, _, _ in bytes }
        modelImages.refreshAttachments = { expected in
            try await sync.refreshInlineImageAttachments(messageId: expected.id, downloadIfNeeded: false, expectedMessage: expected)
        }
        #expect(model.attachments.isEmpty)
        _ = try await modelImages.image(for: URL(string: "cid:logo@example.test")!)
        #expect(model.attachments.count == 1)
        model.cancelPendingWork()
        let reader = MailConversationReader(hub: f.hub, space: .work, message: f.first)
        reader.makeSyncService = { sync }
        await reader.load(force: true)
        #expect(reader.attachments.count == 1 && reader.body?.htmlBody?.contains("cid:logo@example.test") == true)
        #expect(await client.connectCount == 0)
        reader.cancel()
    }

    @MainActor
    @Test("Missing CIDs share one online metadata repair per generation and explicit retry permits another")
    func boundedOnlineMetadataRepair() async throws {
        let f = try await fixture(), bytes = try png()
        let accounts = MailAccountService(databaseQueue: f.queue, space: .work)
        let account = MailAccount(displayName: "Remote", emailAddress: "reader@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "reader@example.test")
        try await accounts.save(account, password: nil)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox", role: .inbox)
        let message = MailMessage(accountId: account.id, folderId: folder.id, uid: 7, bodyState: .ready)
        try await f.mail.upsertFolders([folder]); try await f.mail.upsertMessages([message])
        try await f.mail.saveBody(.init(messageId: message.id, htmlBody: "<img src='cid:first'><img src='cid:second'>"))
        let client = MockMailClient(bodies: [7: .init(textBody: nil, htmlBody: "<img src='cid:first'><img src='cid:second'>", attachments: [
            .init(filename: "first.png", mimeType: "image/png", sizeBytes: bytes.count, contentId: "first", isInline: true, partID: "2"),
            .init(filename: "second.png", mimeType: "image/png", sizeBytes: bytes.count, contentId: "second", isInline: true, partID: "3")
        ])])
        let sync = MailSyncService(accountService: accounts, mail: f.mail, space: .work, clientFactory: { _ in client }, passwordProvider: { _ in "fixture" })
        let offlineSync = MailSyncService(accountService: accounts, mail: f.mail, space: .work, clientFactory: { _ in client },
            passwordProvider: { _ in Issue.record("Offline metadata repair read credentials"); return nil })
        let offline = MailInlineImageSource(hub: f.hub, space: .work, messageID: message.id, downloadMissing: false, syncService: offlineSync)
        await #expect(throws: MailExportError.incomplete) { try await offline.image(for: URL(string: "cid:first")!) }
        #expect(await client.connectCount == 0)
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: message.id, syncService: sync)
        source.readAttachment = { _, _, _ in bytes }
        let first = Task { try await source.image(for: URL(string: "cid:first")!) }
        let second = Task { try await source.image(for: URL(string: "cid:second")!) }
        let firstImage = try await first.value, secondImage = try await second.value
        #expect(firstImage.data == bytes && secondImage.data == bytes)
        #expect(await client.bodyFetchCount == 1)
        #expect(source.refreshedAttachments?.count == 2 && source.failureCount == 0)
        await #expect(throws: MailInlineImageError.missingPart) { try await source.image(for: URL(string: "cid:absent")!) }
        #expect(await client.bodyFetchCount == 1)
        #expect(source.failureReasons == [.missingPart])
        source.retry()
        await #expect(throws: MailInlineImageError.missingPart) { try await source.image(for: URL(string: "cid:absent")!) }
        #expect(await client.bodyFetchCount == 2)
        let review = try await f.mail.reviewExport(ids: [message.id])
        try await f.queue.write { db in try db.execute(sql: "UPDATE mail_messages SET uid=8 WHERE id=?", arguments: [message.id.uuidString]) }
        await #expect(throws: MailExportError.changed) {
            try await sync.refreshInlineImageAttachments(messageId: message.id, downloadIfNeeded: true, exportReview: review)
        }
        await #expect(throws: MailExportError.changed) {
            try await sync.refreshInlineImageAttachments(messageId: message.id, downloadIfNeeded: true, expectedMessage: message)
        }
        #expect(await client.bodyFetchCount == 2)
        let failed = MailInlineImageSource(hub: f.hub, space: .work, messageID: message.id)
        var attempts = 0
        failed.refreshAttachments = { _ in attempts += 1; throw MailProtocolError.connectionFailed("synthetic offline server") }
        for name in ["absent-one", "absent-two"] {
            await #expect(throws: MailProtocolError.self) { try await failed.image(for: URL(string: "cid:" + name)!) }
        }
        #expect(attempts == 1 && failed.failureCount == 2 && failed.failureReasons == [.downloadFailed])
    }

    @MainActor
    @Test("Cancelling the final image waiter cancels shared metadata repair without reporting a failed image")
    func metadataRepairCancellation() async throws {
        let f = try await fixture()
        try await f.mail.replaceAttachments(messageId: f.first.id, attachments: [])
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        var refreshes = 0, cancelled = false
        source.refreshAttachments = { _ in
            refreshes += 1
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
        }
        let first = Task { try await source.image(for: URL(string: "cid:first")!) }
        let second = Task { try await source.image(for: URL(string: "cid:second")!) }
        for _ in 0..<100 where refreshes == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(refreshes == 1)
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!cancelled)
        second.cancel()
        _ = await first.result; _ = await second.result
        #expect(cancelled && source.failureCount == 0)
    }

    @MainActor
    @Test("CID lookup is bound to the mail and space, decodes encoded IDs once, and validates raster data")
    func lookupAndIsolation() async throws {
        let f = try await fixture(), bytes = try png()
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        var requested: [UUID] = []
        source.readAttachment = { message, part, download in
            #expect(message == f.first.id && download); requested.append(part); return bytes
        }
        let image = try await source.image(for: URL(string: "cid:%3Clogo%40example.test%3E")!)
        #expect(image.data == bytes && image.mimeType == "image/png" && image.pixels == 32 * 24)
        #expect(requested == [f.firstPart.id])
        _ = try await source.image(for: URL(string: "cid:logo@example.test")!)
        #expect(requested.count == 1)
        await #expect(throws: (any Error).self) { try await source.image(for: URL(string: "cid:missing@example.test")!) }
        await #expect(throws: (any Error).self) { try await source.image(for: URL(string: "file:///tmp/logo.png")!) }
        #expect(source.failureCount == 2 && requested.count == 1)
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        let other = MailInlineImageSource(hub: Hub(spaceStore: SpaceStore(space: .personal, databaseQueue: isolated)), space: .personal, messageID: f.first.id)
        other.readAttachment = { _, _, _ in Issue.record("A foreign space must never read an attachment"); return bytes }
        await #expect(throws: (any Error).self) { try await other.image(for: URL(string: "cid:logo@example.test")!) }
        source.retry()
        source.readAttachment = { _, _, _ in Data("<svg xmlns='http://www.w3.org/2000/svg'><image href='https://example.test/tracker'/></svg>".utf8) }
        await #expect(throws: (any Error).self) { try await source.image(for: URL(string: "cid:logo@example.test")!) }
        #expect(source.failureCount == 1)
        source.retry()
        let formerlyRejected = try png(width: 8193, height: 1)
        source.readAttachment = { _, _, _ in formerlyRejected }
        #expect(try await source.image(for: URL(string: "cid:logo@example.test")!).pixels == 8193)
        source.retry()
        let thinPanorama = try png(width: 65_537, height: 1)
        source.readAttachment = { _, _, _ in thinPanorama }
        #expect(try await source.image(for: URL(string: "cid:logo@example.test")!).pixels == 65_537)
        source.retry()
        let hugeDimensions = try excessivePixelMetadata()
        source.readAttachment = { _, _, _ in hugeDimensions }
        await #expect(throws: MailInlineImageError.capacity) { try await source.image(for: URL(string: "cid:logo@example.test")!) }
        source.retry()
        source.readAttachment = { _, _, _ in Data(bytes.prefix(bytes.count / 2)) }
        await #expect(throws: (any Error).self) { try await source.image(for: URL(string: "cid:logo@example.test")!) }
        source.retry(); source.readAttachment = { _, _, _ in bytes }
        let duplicate = MailAttachment(messageId: f.first.id, filename: "other.png", mimeType: "image/png", contentId: "logo@example.test")
        try await f.mail.saveAttachments([f.firstPart, duplicate])
        await #expect(throws: (any Error).self) { try await source.image(for: URL(string: "cid:logo@example.test")!) }
    }

    @MainActor
    @Test("Duplicate requests share one read; cancelling one waiter preserves the other and cancelling all stops the work")
    func coalescingAndCancellation() async throws {
        let f = try await fixture(), bytes = try png()
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        var reads = 0, cancelled = false
        source.readAttachment = { _, _, _ in
            reads += 1
            try await Task.sleep(for: .milliseconds(150))
            return bytes
        }
        let url = URL(string: "cid:logo@example.test")!
        let first = Task { try await source.image(for: url) }, second = Task { try await source.image(for: url) }
        for _ in 0..<100 where reads == 0 { try await Task.sleep(for: .milliseconds(5)) }
        first.cancel()
        _ = await first.result
        #expect(try await second.value.data == bytes && reads == 1 && source.failureCount == 0)
        source.retry()
        source.readAttachment = { _, _, _ in
            reads += 1
            do { try await Task.sleep(for: .seconds(30)); return bytes }
            catch { cancelled = true; throw error }
        }
        let pending = Task { try await source.image(for: url) }
        for _ in 0..<100 where reads < 2 { try await Task.sleep(for: .milliseconds(5)) }
        pending.cancel(); _ = await pending.result
        #expect(cancelled && source.failureCount == 0)
    }

    @MainActor
    @Test("Stopped and replaced scheme tasks never receive late callbacks, including identical CID values in another message")
    func schemeLifecycle() async throws {
        _ = NSApplication.shared
        #expect(!WKWebView.handlesURLScheme("cid"))
        let f = try await fixture(), firstBytes = try png(), secondBytes = try png(0)
        let first = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        var late: CheckedContinuation<Data, Error>?
        first.readAttachment = { _, _, _ in try await withCheckedThrowingContinuation { late = $0 } }
        let second = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.second.id)
        second.readAttachment = { message, part, _ in #expect(message == f.second.id && part == f.secondPart.id); return secondBytes }
        let handler = MailInlineImageHandler(), view = WKWebView()
        handler.replaceSource(first)
        let stopped = SchemeTask("cid:logo@example.test")
        handler.webView(view, start: stopped); handler.webView(view, stop: stopped)
        let replaced = SchemeTask("cid:logo@example.test")
        handler.webView(view, start: replaced)
        for _ in 0..<100 where late == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(late != nil)
        handler.invalidate(); handler.replaceSource(second)
        let current = SchemeTask("cid:logo@example.test")
        handler.webView(view, start: current)
        for _ in 0..<100 where current.finishes == 0 && current.errors == 0 { try await Task.sleep(for: .milliseconds(10)) }
        late?.resume(returning: firstBytes)
        try await Task.sleep(for: .milliseconds(30))
        #expect(stopped.responses.isEmpty && stopped.finishes == 0 && stopped.errors == 0)
        #expect(replaced.responses.isEmpty && replaced.finishes == 0 && replaced.errors == 0)
        #expect(current.data == secondBytes && current.finishes == 1 && current.errors == 0 && current.responses.first?.mimeType == "image/png")
        handler.invalidate()
    }

    @MainActor
    @Test("Inline reads stay bounded and cancelled queued work releases its slot")
    func boundedReads() async throws {
        let f = try await fixture(), bytes = try png()
        let parts = (0..<4).map { MailAttachment(messageId: f.first.id, filename: "\($0).png", mimeType: "image/png", contentId: "image-\($0)@example.test") }
        try await f.mail.saveAttachments(parts)
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        var active = 0, peak = 0, reads = 0
        source.readAttachment = { _, _, _ in
            active += 1; reads += 1; peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(100)); return bytes
        }
        let jobs = (0..<4).map { index in Task { try await source.image(for: URL(string: "cid:image-\(index)@example.test")!) } }
        for _ in 0..<100 where active < 2 { try await Task.sleep(for: .milliseconds(5)) }
        jobs[3].cancel()
        for job in jobs { _ = await job.result }
        #expect(peak == 2 && active == 0 && reads == 3 && source.failureCount == 0)
        source.retry()
        let image = try await source.image(for: URL(string: "cid:image-3@example.test")!)
        #expect(image.data == bytes && active == 0)
    }

    @MainActor
    @Test("Offline CID images recover from archive originals and cache while missing server attachments stay offline when downloads are disabled")
    func offlineArchiveAndDownloadPolicy() async throws {
        let f = try await fixture(), bytes = try png()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-inline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data([
            "From: sender@example.test", "MIME-Version: 1.0", "Content-Type: multipart/related; boundary=inline-proof", "",
            "--inline-proof", "Content-Type: text/html; charset=utf-8", "", "<img src='cid:logo@example.test'>",
            "--inline-proof", "Content-Type: image/png", "Content-Disposition: inline; filename=logo.png",
            "Content-ID: <logo@example.test>", "Content-Transfer-Encoding: base64", "", bytes.base64EncodedString(), "--inline-proof--", ""
        ].joined(separator: "\r\n").utf8)
        try await f.mail.saveRawMessage(id: f.first.id, raw: .init(data: original, kind: .imported))
        var part = f.firstPart; part.partID = "local:0"
        try await f.mail.saveAttachments([part])
        let accounts = MailAccountService(databaseQueue: f.queue, space: .work), client = MockMailClient()
        let sync = MailSyncService(accountService: accounts, mail: f.mail, space: .work, attachmentDirectory: root,
            clientFactory: { _ in client }, passwordProvider: { _ in Issue.record("Offline reads must not access credentials"); return nil })
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id, downloadMissing: false)
        source.readAttachment = { message, attachment, download in
            let url = try await sync.downloadAttachment(messageId: message, attachmentID: attachment, downloadIfNeeded: download)
            return try MailAttachmentFile.read(url, maxBytes: 5 * 1024 * 1024)
        }
        #expect(try await source.image(for: URL(string: "cid:logo@example.test")!).data == bytes)
        try await f.queue.write { db in try db.execute(sql: "DELETE FROM mail_raw_messages WHERE messageID=?", arguments: [f.first.id.uuidString]) }
        source.retry()
        #expect(try await source.image(for: URL(string: "cid:logo@example.test")!).data == bytes)
        let remote = MailAccount(displayName: "Remote", emailAddress: "reader@example.test", imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "reader@example.test")
        try await accounts.save(remote, password: nil)
        let folder = MailFolder(accountId: remote.id, path: "INBOX", name: "Inbox", role: .inbox)
        try await f.mail.upsertFolders([folder])
        let message = MailMessage(accountId: remote.id, folderId: folder.id, uid: 1)
        let missing = MailAttachment(messageId: message.id, filename: "missing.png", mimeType: "image/png", contentId: "missing", partID: "2")
        try await f.mail.upsertMessages([message]); try await f.mail.saveAttachments([missing])
        await #expect(throws: MailExportError.incomplete) { try await sync.downloadAttachment(messageId: message.id, attachmentID: missing.id, downloadIfNeeded: false) }
        var oversized = missing; oversized.sizeBytes = 6 * 1024 * 1024
        try await f.mail.saveAttachments([oversized])
        await #expect(throws: MailProtocolError.self) { try await sync.downloadAttachment(messageId: message.id, attachmentID: missing.id, maxBytes: 5 * 1024 * 1024) }
        #expect(await client.connectCount == 0)
    }

    @MainActor
    @Test("Real WebKit renders CID images with scripts disabled, and PDF retains them or reports missing content")
    func nativeReaderAndPDF() async throws {
        _ = NSApplication.shared
        let f = try await fixture(), bytes = try png()
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        var reads = 0
        source.readAttachment = { _, _, _ in reads += 1; return bytes }
        let html = "<title>CID proof</title><script>document.title='unsafe'</script><img src='cid:logo@example.test' width='128' height='96'><img src='https://example.invalid/tracker.png'>"
        let host = NSHostingView(rootView: MailHTMLView(html: html, text: nil, inlineImages: source).frame(width: 400, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { source.cancelPending(); window.close() }
        func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let web = try #require(webViews(host).first)
        for _ in 0..<200 where web.isLoading || reads == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(web.title == "CID proof" && !web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(reads == 1 && source.failureCount == 0)
        let snapshot = try await web.takeSnapshot(configuration: nil)
        #expect(try cyanPixels(snapshot) > 1000)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] {
            let bitmap = try #require(NSBitmapImageRep(data: snapshot.tiffRepresentation!))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("mail-inline-native.png"))
        }
        let nextSource = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.second.id)
        let nextBytes = try png(0)
        var nextReads = 0
        nextSource.readAttachment = { message, part, _ in #expect(message == f.second.id && part == f.secondPart.id); nextReads += 1; return nextBytes }
        host.rootView = MailHTMLView(html: html, text: nil, inlineImages: nextSource).frame(width: 400, height: 300)
        for _ in 0..<200 where web.isLoading || nextReads == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let nextSnapshot = try await web.takeSnapshot(configuration: nil)
        let nextCyan = try cyanPixels(nextSnapshot)
        #expect(nextReads == 1)
        #expect(nextSource.failureCount == 0)
        #expect(nextCyan == 0)
        let pdfSource = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id, downloadMissing: false)
        pdfSource.readAttachment = { _, _, download in #expect(!download); return bytes }
        let data = try await MailPDFRenderer().render(message: f.first, body: .init(messageId: f.first.id, htmlBody: html), space: .work, inlineImages: pdfSource)
        let pdf = try #require(PDFDocument(data: data)), page = try #require(pdf.page(at: 0))
        let thumbnail = page.thumbnail(of: NSSize(width: 540, height: 720), for: .mediaBox)
        let pdfCyan = try cyanPixels(thumbnail)
        #expect(pdfCyan > 200)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mail-inline-native.pdf"))
            let bitmap = try #require(NSBitmapImageRep(data: thumbnail.tiffRepresentation!))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("mail-inline-pdf.png"))
        }
        let missing = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id, downloadMissing: false)
        await #expect(throws: MailExportError.incomplete) {
            try await MailPDFRenderer().render(message: f.first, body: .init(messageId: f.first.id, htmlBody: "<img src='cid:missing@example.test'>"), space: .work, inlineImages: missing)
        }
    }

    @MainActor
    @Test("Real WebKit scrolls to both ends of images above the former height limits", .timeLimit(.minutes(1)), arguments: [false, true])
    func nativeUnboundedHeight(_ downsample: Bool) async throws {
        _ = NSApplication.shared
        let f = try await fixture()
        let width = downsample ? 100 : 64, height = downsample ? 200_000 : 70_000
        let bytes = try poster(width: width, height: height, type: "public.png")
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        var reads = 0
        source.readAttachment = { _, _, _ in reads += 1; return bytes }
        let html = "<title>No height cap</title><img src='cid:logo@example.test' style='width:\(width)px;height:auto'>"
        let host = NSHostingView(rootView: MailHTMLView(html: html, text: nil, inlineImages: source).frame(width: 200, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { source.cancelPending(); window.close() }
        func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let web = try #require(webViews(host).first)
        for _ in 0..<300 where web.isLoading || reads == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let image = try await source.image(for: URL(string: "cid:logo@example.test")!)
        #expect(image.isDownsampled == downsample && image.pixels <= 16_000_000)
        #expect(source.failureCount == 0 && reads == 1)
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        web.pageZoom = 1
        var top = try await web.takeSnapshot(configuration: nil)
        var topPixels = try cyanPixels(top)
        for _ in 0..<40 where topPixels <= 1000 {
            try await Task.sleep(for: .milliseconds(50))
            top = try await web.takeSnapshot(configuration: nil)
            topPixels = try cyanPixels(top)
        }
        #expect(topPixels > 1000)
        // Native evaluation scrolls this test-owned document; scripts supplied
        // by the email remain disabled in the production configuration.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            web.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight)") { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        func footerPixels(_ snapshot: NSImage) throws -> Int {
            try coloredPixels(snapshot) { $0.redComponent > $0.greenComponent + 0.25 && $0.blueComponent > $0.greenComponent + 0.25 }
        }
        var bottom = try await web.takeSnapshot(configuration: nil)
        var bottomPixels = try footerPixels(bottom)
        for _ in 0..<40 where bottomPixels <= 1000 {
            try await Task.sleep(for: .milliseconds(50))
            bottom = try await web.takeSnapshot(configuration: nil)
            bottomPixels = try footerPixels(bottom)
        }
        #expect(bottomPixels > 1000)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] {
            for (suffix, snapshot) in [("top", top), ("bottom", bottom)] {
                let bitmap = try #require(NSBitmapImageRep(data: snapshot.tiffRepresentation!))
                let name = "mail-inline-no-height-\(downsample ? "preview" : "original")-\(suffix).png"
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
    }

    @MainActor
    @Test("Real WebKit and paginated PDF retain the entire long JPEG, including its bottom", .timeLimit(.minutes(1)), arguments: [false, true])
    func nativeLongPosterAndPDF(_ downsample: Bool) async throws {
        _ = NSApplication.shared
        let f = try await fixture()
        // Explicit opt-in for a local, read-only reproduction. Normal regression
        // uses synthetic bytes and never reads a user's mail or credentials.
        let probe = downsample ? nil : ProcessInfo.processInfo.environment["AGROOM_MAIL_TEST_IMAGE_PATH"].map { URL(fileURLWithPath: $0) }
        let bytes = try probe.map { try MailAttachmentFile.read($0, maxBytes: 5 * 1024 * 1024) }
            ?? poster(width: downsample ? 1800 : 900, height: downsample ? 20_000 : 10_121)
        let source = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id)
        var reads = 0
        source.readAttachment = { _, _, _ in reads += 1; return bytes }
        let html = "<title>Tall CID proof</title><img src='cid:logo@example.test' style='width:300px;height:auto'>"
        let host = NSHostingView(rootView: MailHTMLView(html: html, text: nil, inlineImages: source).frame(width: 400, height: 450))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { source.cancelPending(); window.close() }
        func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let web = try #require(webViews(host).first)
        for _ in 0..<300 where web.isLoading || reads == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(web.title == "Tall CID proof" && source.failureCount == 0 && reads == 1)
        let image = try await source.image(for: URL(string: "cid:logo@example.test")!)
        #expect(image.mimeType == "image/jpeg" && image.isDownsampled == downsample)
        if downsample { #expect(image.pixels <= 16_000_000 && source.downsampledCount == 1) }
        else { #expect(image.pixels == 900 * 10_121) }
        // Pixel assertions use fixed geometry, independent of saved reading
        // typography. WebKit may finish the resource before painting its pixels.
        web.pageZoom = 1
        func visiblePixels(_ image: NSImage) throws -> Int {
            if probe == nil { return try cyanPixels(image) }
            return try coloredPixels(image) {
                max($0.redComponent, max($0.greenComponent, $0.blueComponent))
                    - min($0.redComponent, min($0.greenComponent, $0.blueComponent)) > 0.15
            }
        }
        var snapshot = try await web.takeSnapshot(configuration: nil)
        var visible = try visiblePixels(snapshot)
        for _ in 0..<40 where visible <= 1000 {
            try await Task.sleep(for: .milliseconds(50))
            snapshot = try await web.takeSnapshot(configuration: nil)
            visible = try visiblePixels(snapshot)
        }
        #expect(visible > 1000)
        let pdfSource = MailInlineImageSource(hub: f.hub, space: .work, messageID: f.first.id, downloadMissing: false)
        pdfSource.readAttachment = { _, _, download in #expect(!download); return bytes }
        let data = try await MailPDFRenderer().render(message: f.first, body: .init(messageId: f.first.id, htmlBody: html), space: .work, inlineImages: pdfSource)
        let pdf = try #require(PDFDocument(data: data)), last = try #require(pdf.page(at: pdf.pageCount - 1))
        #expect(pdf.pageCount >= 3 && pdfSource.failureCount == 0)
        if probe == nil {
            let footer = last.thumbnail(of: NSSize(width: 540, height: 720), for: .mediaBox)
            #expect(try coloredPixels(footer) { $0.redComponent > $0.greenComponent + 0.25 && $0.blueComponent > $0.greenComponent + 0.25 } > 200)
        }
        if let directory = ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] {
            let root = URL(fileURLWithPath: directory)
            let name = downsample ? "mail-inline-large-native" : "mail-inline-tall-native"
            let bitmap = try #require(NSBitmapImageRep(data: snapshot.tiffRepresentation!))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
            try data.write(to: root.appendingPathComponent(name + ".pdf"))
        }
        if let probe { #expect(try MailAttachmentFile.read(probe, maxBytes: 5 * 1024 * 1024) == bytes) }
    }

    @MainActor
    @Test("The mailbox renders inline images and its retry banner in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeMailboxLayouts() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let f = try await fixture(), bytes = try png(), large = try poster(width: 1800, height: 20_000)
        try await f.mail.saveBody(.init(messageId: f.first.id, htmlBody: "<h2>Inline delivery / 内嵌交付图</h2><p>Current-message image.</p><img src='cid:logo@example.test' width='160' height='120'>"))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let model = MailViewModel(hub: f.hub, space: .work)
            await model.loadIfNeeded(); await model.selectMessage(f.first.id)
            let source = try #require(model.inlineImages)
            source.readAttachment = { _, _, _ in bytes }
            let host = NSHostingView(rootView: MailView(hub: f.hub, viewModel: model).frame(width: 1100, height: 680).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            for state in ["ready", "preview", "retry"] {
                if state == "preview" { source.readAttachment = { _, _, _ in large }; source.retry() }
                if state == "retry" { source.readAttachment = { _, _, _ in throw MailInlineImageError.unavailable }; source.retry() }
                for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                if state == "retry" {
                    for _ in 0..<100 where source.failureCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
                    #expect(source.failureCount == 1)
                }
                if state == "preview" {
                    for _ in 0..<200 where source.downsampledCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
                    #expect(source.downsampledCount == 1 && source.failureCount == 0)
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("mail-inline-\(state)-\(language.rawValue).png"))
            }
            model.cancelPendingWork(); window.close()
            #expect(model.inlineImages == nil)
            await model.loadIfNeeded()
            #expect(model.inlineImages?.id != source.id && model.inlineImages?.messageID == f.first.id)
            model.cancelPendingWork()
        }
    }

    @MainActor
    private func cyanPixels(_ image: NSImage) throws -> Int {
        try coloredPixels(image) { min($0.greenComponent, $0.blueComponent) > 0.7
            && $0.greenComponent > $0.redComponent + 0.25 && $0.blueComponent > $0.redComponent + 0.25 }
    }

    @MainActor
    private func coloredPixels(_ image: NSImage, matching: (NSColor) -> Bool) throws -> Int {
        let data = try #require(image.tiffRepresentation), bitmap = try #require(NSBitmapImageRep(data: data))
        var result = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                // PDF thumbnail conversion can alter saturation. Compare channel
                // contrast to distinguish the fixture bands from blank paper.
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   matching(color) { result += 1 }
            }
        }
        return result
    }
}
