import Foundation
import GRDB

public enum MailComposePresetError: String, Error, Sendable { case invalid, capacity, duplicateName, changed }

public struct MailSignatureSource: Identifiable, Sendable {
    let database: DatabaseQueue
    let account: MailAccount
    let folder: RemoteMailFolder
    let uidValidity: UInt32
    public let id: UInt32
    public let subject: String
    public let date: Date?
}

public enum MailSignatureImportError: String, Error { case noText, changed }

public struct MailSignaturePreview: Sendable, Equatable {
    public let text: String
    public let suggestedRange: NSRange?

    init(body: RemoteMessageBody) throws {
        let plain = body.textBody?.trimmingCharacters(in: .newlines) ?? ""
        let usePlain = !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !MailFoundationAdapter.looksLikeHTML(plain)
        guard let readable = usePlain ? plain : MailAIContextService.htmlToText(body.htmlBody ?? plain), !readable.isEmpty else {
            throw MailSignatureImportError.noText
        }
        text = readable.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Preselect only a delimited signature in the author's unquoted part.
        // With an unmarked corporate footer the user selects the exact lines.
        // Converting an HTML blockquote to text loses its quote depth.
        guard usePlain else { suggestedRange = nil; return }
        let quote = text.range(of: #"(?im)^[ \t]*(?:>|On [^\n]+ wrote:\s*$|在[^\n]+(?:写道|寫道)[：:]|-{2,}\s*(?:Original Message|Forwarded message|原始邮件|转发邮件|原始郵件|轉寄郵件)\s*-{2,}|(?:From|发件人|寄件者)[：:])"#, options: .regularExpression)
        let authored = text[..<(quote?.lowerBound ?? text.endIndex)]
        if let delimiter = authored.range(of: #"(?m)^--[ \t]*\n"#, options: .regularExpression),
           let range = authored[delimiter.upperBound...].rangeOfNonWhitespace {
            suggestedRange = NSRange(range, in: text)
        } else { suggestedRange = nil }
    }
}

private extension Substring {
    var rangeOfNonWhitespace: Range<String.Index>? {
        guard let first = firstIndex(where: { !$0.isWhitespace }),
              let last = lastIndex(where: { !$0.isWhitespace }) else { return nil }
        return first..<index(after: last)
    }
}
public struct MailComposePreset: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case signature, reply }
    public let id: UUID
    public var kind: Kind
    public var name: String
    public var body: String
    public init(id: UUID = UUID(), kind: Kind, name: String, body: String) {
        self.id = id; self.kind = kind; self.name = name; self.body = body
    }
}

public struct MailComposePresets: Codable, Sendable, Equatable {
    public var items: [MailComposePreset] = []
    public var defaultSignatures: [String: UUID] = [:]
    public init() {}
    public func validate() throws {
        guard items.count <= 100, defaultSignatures.count <= 1000,
              Set(items.map(\.id)).count == items.count else { throw MailComposePresetError.capacity }
        var names = Set<String>(), bytes = 0
        for item in items {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.name.utf8.count <= 120,
                  item.name.rangeOfCharacter(from: .controlCharacters) == nil, !item.body.contains("\0"),
                  !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailComposePresetError.invalid }
            guard item.body.utf8.count <= 32 * 1024 else { throw MailComposePresetError.capacity }
            bytes += item.name.utf8.count + item.body.utf8.count
            guard bytes <= 1024 * 1024 else { throw MailComposePresetError.capacity }
            let key = item.kind.rawValue + ":" + item.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw MailComposePresetError.duplicateName }
        }
        for (owner, id) in defaultSignatures {
            guard UUID(uuidString: owner) != nil, items.contains(where: { $0.id == id && $0.kind == .signature }) else { throw MailComposePresetError.invalid }
        }
    }
    public func defaultSignature(accountID: UUID) -> MailComposePreset? {
        guard let id = defaultSignatures[accountID.uuidString] else { return nil }
        return items.first { $0.id == id && $0.kind == .signature }
    }
}

extension MailService {
    public func composePresets() async throws -> MailComposePresets {
        try await databaseQueue.read { db in try Self.loadComposePresets(db) }
    }

    public func saveComposePresets(_ value: MailComposePresets, replacing expected: MailComposePresets) async throws -> MailComposePresets {
        try value.validate()
        return try await databaseQueue.maintenanceWrite { db in
            guard try Self.loadComposePresets(db) == expected else { throw MailComposePresetError.changed }
            let owners = Set(try MailAccountRow.fetchAll(db).compactMap { $0.toAccount() }.filter { !$0.isLocalArchive }.map { $0.id.uuidString })
            var stored = value
            stored.defaultSignatures = stored.defaultSignatures.filter { owners.contains($0.key) }
            let data = try JSONEncoder().encode(stored)
            guard data.count <= 8 * 1024 * 1024 else { throw MailComposePresetError.capacity }
            try db.execute(sql: "INSERT INTO product_preferences(key,value,updatedAt) VALUES('mail.compose.presets',?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updatedAt=excluded.updatedAt", arguments: [data, Date()])
            return stored
        }
    }

    private static func loadComposePresets(_ db: Database) throws -> MailComposePresets {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key='mail.compose.presets'") else { return .init() }
        guard data.count <= 8 * 1024 * 1024 else { throw MailComposePresetError.capacity }
        let value = try JSONDecoder().decode(MailComposePresets.self, from: data)
        try value.validate()
        return value
    }
}
