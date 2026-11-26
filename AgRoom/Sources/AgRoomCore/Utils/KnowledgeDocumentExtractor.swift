import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import PDFKit

struct KnowledgeFileSnapshot: Sendable {
    let url: URL
    let data: Data
    let hash: String
}

enum KnowledgeSourceFile {
    static let maximumBytes = 32 * 1024 * 1024
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func validatedURL(_ input: URL, space: AppSpace) throws -> URL {
        guard input.isFileURL else { throw KnowledgeImportError.permission }
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
        var forbidden = support.map { root in [root.appendingPathComponent("AgRoom"), root.appendingPathComponent("AgentHub")] } ?? []
        if let root = documents?.appendingPathComponent("AgRoom") {
            let other = space == .work ? "personal" : "work"
            forbidden += [root.appendingPathComponent("default-chat/" + other), root.appendingPathComponent(space == .work ? "privatespace" : "workspace")]
        }
        guard !forbidden.contains(where: { FileAreaService.isInside(url, root: $0.standardizedFileURL.resolvingSymlinksInPath()) }) else { throw KnowledgeImportError.permission }
        return url
    }

    static func read(_ input: URL, space: AppSpace) throws -> KnowledgeFileSnapshot {
        try Task.checkCancellation()
        let access = input.startAccessingSecurityScopedResource()
        defer { if access { input.stopAccessingSecurityScopedResource() } }
        let url = try validatedURL(input, space: space)
        do {
            let parent = try AppDirectory(url: url.deletingLastPathComponent(), create: false)
            let fd = openat(parent.fd, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw errno == ENOENT ? KnowledgeImportError.sourceMissing : KnowledgeImportError.permission }
            defer { Darwin.close(fd) }
            var before = stat(), after = stat(), current = stat()
            guard fstat(fd, &before) == 0 else { throw KnowledgeImportError.unreadable }
            let bytes = try AppDirectory.read(fd: fd, limit: maximumBytes)
            try Task.checkCancellation()
            guard fstat(fd, &after) == 0, fstatat(parent.fd, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_ino == current.st_ino, before.st_dev == current.st_dev,
                  before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw KnowledgeImportError.changed }
            return KnowledgeFileSnapshot(url: url, data: bytes, hash: digest(bytes))
        } catch let error as NativeAppError {
            switch error.code {
            case .tooLarge: throw KnowledgeImportError.tooLarge
            case .missing: throw KnowledgeImportError.sourceMissing
            case .unsafePath: throw KnowledgeImportError.permission
            default: throw KnowledgeImportError.unreadable
            }
        }
    }
}

public enum KnowledgeDocumentExtractor {
    public static let supportedExtensions = ["md", "markdown", "txt", "pdf"] + OCRService.supportedExtensions
    public static let maximumContentBytes = 4 * 1024 * 1024

    static func extract(_ snapshot: KnowledgeFileSnapshot, options: KnowledgeImportOptions) async throws -> KnowledgeExtraction {
        let title = snapshot.url.deletingPathExtension().lastPathComponent
        let ext = snapshot.url.pathExtension.lowercased()
        let extraction: KnowledgeExtraction
        if ["md", "markdown", "txt"].contains(ext) {
            let text: String?
            switch options.encoding {
            case "utf8": text = String(data: snapshot.data, encoding: .utf8)
            case "utf16": text = String(data: snapshot.data, encoding: .utf16)
            case "automatic":
                if snapshot.data.starts(with: [0xff, 0xfe]) || snapshot.data.starts(with: [0xfe, 0xff]) { text = String(data: snapshot.data, encoding: .utf16) }
                else { text = String(data: snapshot.data, encoding: .utf8) }
            default: throw KnowledgeImportError.encoding
            }
            guard let text else { throw KnowledgeImportError.encoding }
            extraction = .init(title: title, blocks: [.init(text: text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")))], parser: "text-v1")
        } else if ext == "pdf" {
            extraction = try await pdf(snapshot.data, title: title, options: options)
        } else if OCRService.supportedExtensions.contains(ext) {
            guard options.ocr != .textOnly else { throw KnowledgeImportError.empty }
            let text = try await OCRService.recognizeCancellable(imageData: snapshot.data)
            extraction = .init(title: title, blocks: [.init(kind: "image", text: text, location: .init(page: 1))], warnings: ["ocr"], parser: "vision-image-v1")
        } else { throw KnowledgeImportError.unsupported }
        guard !extraction.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KnowledgeImportError.empty }
        guard extraction.content.utf8.count <= maximumContentBytes else { throw KnowledgeImportError.tooLarge }
        try Task.checkCancellation()
        return extraction
    }

    private static func pdf(_ data: Data, title: String, options: KnowledgeImportOptions) async throws -> KnowledgeExtraction {
        guard let document = PDFDocument(data: data) else { throw KnowledgeImportError.corrupt }
        guard !document.isLocked else { throw KnowledgeImportError.encrypted }
        let first = options.firstPage ?? 1, last = options.lastPage ?? document.pageCount
        guard first >= 1, last >= first, last <= document.pageCount, last - first < 200 else { throw KnowledgeImportError.tooLarge }
        var blocks: [KnowledgeBlock] = [], warnings: [String] = [], bytes = 0
        for index in (first - 1)..<last {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw KnowledgeImportError.corrupt }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let needsOCR = options.ocr == .force || (options.ocr == .automatic && text.count < 40)
            if needsOCR {
                do {
                    text = try await OCRService.recognizeCancellable(cgImage: render(page))
                    warnings.append("ocr:\(index + 1)")
                } catch OCRService.OCRError.noTextFound { warnings.append("blank:\(index + 1)") }
            } else if text.isEmpty { warnings.append("noTextLayer:\(index + 1)") }
            bytes += text.utf8.count
            guard bytes <= maximumContentBytes else { throw KnowledgeImportError.tooLarge }
            blocks.append(.init(kind: "page", text: text, location: .init(page: index + 1)))
        }
        return .init(title: title, blocks: blocks, warnings: warnings, parser: "pdf-vision-v1", metadata: ["pageCount": String(document.pageCount), "firstPage": String(first), "lastPage": String(last)])
    }

    private static func render(_ page: PDFPage) throws -> CGImage {
        guard let reference = page.pageRef else { throw KnowledgeImportError.corrupt }
        let bounds = reference.getBoxRect(.mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw KnowledgeImportError.corrupt }
        let scale = min(3, 2400 / max(bounds.width, bounds.height))
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw KnowledgeImportError.tooLarge }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
        context.concatenate(reference.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw KnowledgeImportError.corrupt }
        return image
    }
}
