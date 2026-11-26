import CryptoKit
import Foundation

public struct MailArchiveLabels: Sendable {
    public let title: String, original: String, attachments: String, from: String, to: String, date: String, emptyBody: String, generated: String
    public init(title: String, original: String, attachments: String, from: String, to: String, date: String, emptyBody: String, generated: String) {
        self.title = title; self.original = original; self.attachments = attachments; self.from = from; self.to = to
        self.date = date; self.emptyBody = emptyBody; self.generated = generated
    }
}

public enum MailArchiveBundle {
    public struct File: Sendable { public let components: [String]; public let data: Data }
    public struct Payload: Sendable {
        public let files: [File]
        public let originalSHA256: String
        public let originalByteCount: Int
    }
    private struct AttachmentReceipt: Codable {
        let name: String, path: String, mimeType: String, sha256: String
        let bytes: Int
        let inline: Bool
    }
    private struct Receipt: Codable {
        let messageID: UUID, originalKind: MailRawKind, originalSHA256: String, originalBytes: Int
        let attachments: [AttachmentReceipt]
    }

    /// Every readable field is escaped text. Original HTML never becomes active
    /// markup, scripts, forms, tracking pixels or remote resources in an archive.
    public static func build(raw: MailRawMessage, message: MailMessage, labels: MailArchiveLabels) throws -> Payload {
        try Task.checkCancellation()
        guard !raw.data.isEmpty, raw.data.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
        let envelope = try MailFoundationAdapter.importedEnvelope(raw.data)
        let body = try MailFoundationAdapter.importedBody(raw.data)
        var files: [File] = [.init(components: ["message.eml"], data: raw.data)], receipts: [AttachmentReceipt] = []
        var links = "", total = raw.data.count
        for (index, attachment) in body.attachments.enumerated() {
            try Task.checkCancellation()
            let data = try MailSmtpAdapter.localAttachment(raw.data, index: index, filename: attachment.filename, mimeType: attachment.mimeType)
            var stem = ""
            for character in MailExportDestination.safeName(attachment.filename) {
                guard stem.utf8.count + String(character).utf8.count <= 150 else { break }
                stem.append(character)
            }
            let filename = String(format: "%04d-", index + 1) + stem
            let path = ["attachments", filename]
            // Bound one prepared message, independently of whole archive size.
            guard data.count <= MailDraftAttachment.maximumFileBytes, data.count <= 160 * 1024 * 1024 - total else { throw MailExportError.tooLarge }
            total += data.count
            files.append(.init(components: path, data: data))
            receipts.append(.init(name: attachment.filename, path: path.joined(separator: "/"), mimeType: attachment.mimeType,
                sha256: digest(data), bytes: data.count, inline: attachment.isInline))
            links += "<li><a download href=\"\(relativeURL(path))\">\(escape(attachment.filename))</a> (\(data.count))</li>"
        }
        let text = body.textBody.flatMap { MailFoundationAdapter.looksLikeHTML($0) ? MailAIContextService.htmlToText($0) : $0 }
        let readable = text ?? MailAIContextService.htmlToText(body.htmlBody) ?? labels.emptyBody
        let addresses = envelope.to.map { $0.name.isEmpty ? $0.address : $0.name + " <" + $0.address + ">" }.joined(separator: ", ")
        let date = envelope.date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        let note = raw.kind == .generated ? "<p>\(escape(labels.generated))</p>" : ""
        let content = "<h1>\(escape(envelope.subject))</h1>\(note)<dl><dt>\(escape(labels.from))</dt><dd>\(escape(envelope.from.name + " <" + envelope.from.address + ">"))</dd><dt>\(escape(labels.to))</dt><dd>\(escape(addresses))</dd><dt>\(escape(labels.date))</dt><dd>\(escape(date))</dd></dl><p><a download href=\"message.eml\">\(escape(labels.original))</a></p><pre>\(escape(readable))</pre><h2>\(escape(labels.attachments))</h2><ul>\(links)</ul>"
        let html = document(title: envelope.subject, content: content)
        guard html.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
        let hash = digest(raw.data), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        files.append(.init(components: ["manifest.json"], data: try encoder.encode(Receipt(messageID: message.id,
            originalKind: raw.kind, originalSHA256: hash, originalBytes: raw.data.count, attachments: receipts))))
        files.append(.init(components: ["index.html"], data: html))
        return .init(files: files, originalSHA256: hash, originalByteCount: raw.data.count)
    }

    public static func index(title: String, rows: [(title: String, path: [String]?, error: String?)]) throws -> Data {
        var content = "<h1>\(escape(title))</h1><ol>"
        for row in rows {
            try Task.checkCancellation()
            if let path = row.path { content += "<li><a href=\"\(relativeURL(path))\">\(escape(row.title))</a></li>" }
            else { content += "<li>\(escape(row.title)) — \(escape(row.error ?? ""))</li>" }
            guard content.utf8.count <= MailService.rawMessageByteLimit / 2 else { throw MailExportError.tooLarge }
        }
        return document(title: title, content: content + "</ol>")
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func relativeURL(_ path: [String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func document(title: String, content: String) -> Data {
        Data("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\"><title>\(escape(title))</title><style>body{max-width:70rem;margin:2rem auto;padding:0 1rem;font:16px system-ui;line-height:1.6}pre{white-space:pre-wrap;overflow-wrap:anywhere}dd{overflow-wrap:anywhere}dt{font-weight:bold}li{margin:.6rem 0}</style></head><body>\(content)</body></html>".utf8)
    }
}
