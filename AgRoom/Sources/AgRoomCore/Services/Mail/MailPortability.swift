import Foundation
import GRDB

public enum MailRawKind: String, Codable, Sendable {
    case received, generated, imported
}

public struct MailRawMessage: Sendable {
    public let data: Data
    public let kind: MailRawKind
    public init(data: Data, kind: MailRawKind) { self.data = data; self.kind = kind }
}

public enum MailExportError: Error, Sendable {
    case incomplete, changed, unsafeDestination, tooLarge, renderingFailed, mboxRequiresEML, invalidLayout, nameConflict
}

public enum MailAttachmentFile {
    public static func read(_ url: URL, maxBytes: Int = 25 * 1024 * 1024) throws -> Data {
        guard maxBytes > 0, maxBytes <= 25 * 1024 * 1024 else { throw MailAttachmentError.capacity }
        return try AppDirectory(url: url.deletingLastPathComponent(), create: false)
            .read(url.lastPathComponent, limit: maxBytes)
    }
}

public struct MailExportCoverage: Sendable {
    public var total = 0
    public var raw = 0
    public var generated = 0
    public var bodies = 0
    public var titles: [UUID: String] = [:]
}

extension MailService {
    public static let rawMessageByteLimit = 64 * 1024 * 1024
    static let rawCacheByteLimit = 128 * 1024 * 1024

    static func createRawSchema(_ db: Database) throws {
        try db.create(table: "mail_raw_messages", ifNotExists: true) { t in
            t.column("messageID", .text).primaryKey().references("mail_messages", onDelete: .cascade)
            t.column("data", .blob).notNull()
            t.column("kind", .text).notNull()
            t.column("fetchedAt", .datetime).notNull()
        }
    }

    public func rawMessage(id: UUID) async throws -> MailRawMessage? {
        try await databaseQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT data, kind FROM mail_raw_messages WHERE messageID = ?", arguments: [id.uuidString]),
                  let kind = MailRawKind(rawValue: row["kind"]) else { return nil }
            return .init(data: row["data"], kind: kind)
        }
    }

    public func saveRawMessage(id: UUID, raw: MailRawMessage, expected: MailMessage? = nil) async throws {
        guard !raw.data.isEmpty, raw.data.count <= Self.rawMessageByteLimit else { throw MailExportError.tooLarge }
        try await databaseQueue.maintenanceWrite { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_messages WHERE id = ?)", arguments: [id.uuidString]) == true else {
                throw MailSyncError.messageNotFound
            }
            if let expected {
                guard let row = try Row.fetchOne(db, sql: "SELECT accountId,folderId,uid,messageId FROM mail_messages WHERE id=?", arguments: [id.uuidString]),
                      (row["accountId"] as String) == expected.accountId.uuidString,
                      (row["folderId"] as String) == expected.folderId.uuidString,
                      (row["uid"] as Int64) == Int64(expected.uid),
                      (row["messageId"] as String?) == expected.messageId else { throw MailExportError.changed }
            }
            try Self.saveRawMessage(id: id, raw: raw, in: db)
        }
    }

    /// Also used when a whole-message body fallback publishes local part IDs.
    static func saveRawMessage(id: UUID, raw: MailRawMessage, in db: Database) throws {
        guard !raw.data.isEmpty, raw.data.count <= Self.rawMessageByteLimit else { throw MailExportError.tooLarge }
        try db.execute(sql: "INSERT INTO mail_raw_messages(messageID,data,kind,fetchedAt) VALUES(?,?,?,?) ON CONFLICT(messageID) DO UPDATE SET data=excluded.data,kind=excluded.kind,fetchedAt=excluded.fetchedAt",
                       arguments: [id.uuidString, raw.data, raw.kind.rawValue, Date()])
        var bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(data)),0) FROM mail_raw_messages WHERE kind = 'received'") ?? 0
        if bytes > Self.rawCacheByteLimit {
            let rows = try Row.fetchAll(db, sql: "SELECT messageID,LENGTH(data) AS bytes FROM mail_raw_messages WHERE kind = 'received' ORDER BY fetchedAt, messageID")
            for row in rows where bytes > Self.rawCacheByteLimit {
                let key: String = row["messageID"]
                try db.execute(sql: "DELETE FROM mail_raw_messages WHERE messageID = ?", arguments: [key])
                bytes -= (row["bytes"] as Int)
            }
        }
    }

    public func exportCoverage(ids: [UUID]) async throws -> MailExportCoverage {
        try await databaseQueue.read { db in
            var coverage = MailExportCoverage()
            for id in Set(ids) {
                guard let row = try Row.fetchOne(db, sql: "SELECT r.kind, m.subject, CASE WHEN b.textBody IS NOT NULL OR b.htmlBody IS NOT NULL THEN 1 ELSE 0 END AS ready FROM mail_messages m LEFT JOIN mail_raw_messages r ON r.messageID=m.id LEFT JOIN mail_bodies b ON b.messageID=m.id WHERE m.id=?", arguments: [id.uuidString]) else { throw MailSyncError.messageNotFound }
                coverage.total += 1
                coverage.titles[id] = row["subject"]
                if let kind: String = row["kind"] {
                    coverage.raw += 1
                    if kind == MailRawKind.generated.rawValue { coverage.generated += 1 }
                }
                if row["ready"] as Int == 1 { coverage.bodies += 1 }
            }
            return coverage
        }
    }
}

/// User-selected destinations are frozen before downloads begin. Writes reject
/// links, replaced directories and files changed since the save panel closed.
public actor MailExportDestination {
    public let directoryURL: URL
    private let directory: AppDirectory
    private let filename: String?
    private let previous: Data?
    private var used = Set<String>()
    private var plannedDirectories: [String: AppDirectory] = [:]
    private let planned: Bool

    public init(directory url: URL, filename: String? = nil) throws {
        let root = url.standardizedFileURL
        let handle = try AppDirectory(url: root, create: false)
        if let filename {
            guard Self.validName(filename) else { throw MailExportError.unsafeDestination }
        }
        self.directoryURL = root; self.directory = handle; self.filename = filename; planned = false
        self.previous = try filename.flatMap { handle.exists($0) ? try handle.read($0, limit: MailService.rawMessageByteLimit) : nil }
        if filename == nil { used.insert("export-report.json") }
    }

    private init(ownedDirectory: AppDirectory, url: URL) throws {
        try ownedDirectory.verifyIdentity(at: url)
        directoryURL = url.standardizedFileURL; directory = ownedDirectory
        filename = nil; previous = nil; planned = true; used.insert("export-report.json")
    }

    public static func batch(in parent: URL, prefix: String) throws -> MailExportDestination {
        var stem = ""
        for character in safeName(prefix) {
            guard stem.utf8.count + String(character).utf8.count <= 123 else { break }
            stem.append(character)
        }
        let name = stem + "-" + UUID().uuidString
        return try namedBatch(in: parent, name: name)
    }

    /// The reviewed name is exact. An existing directory is never adopted or renamed.
    public static func namedBatch(in parent: URL, name: String) throws -> MailExportDestination {
        guard validName(name), name == safeName(name) else { throw MailExportError.invalidLayout }
        let root = try AppDirectory(url: parent, create: false)
        guard !root.exists(name) else { throw MailExportError.nameConflict }
        let child = try root.child(name, create: true, exclusive: true)
        try root.verifyIdentity(at: parent)
        return try MailExportDestination(ownedDirectory: child, url: parent.appendingPathComponent(name, isDirectory: true))
    }

    /// Writes only the precomputed relative path; collisions fail instead of
    /// silently producing a filename that was absent from the review.
    public func writePlanned(_ data: Data, components: [String]) throws -> URL {
        try Task.checkCancellation()
        guard !components.isEmpty, components.count <= 132,
              components.allSatisfy({ Self.validName($0) && $0.utf8.count <= 255 }) else { throw MailExportError.invalidLayout }
        if filename != nil {
            guard components.count == 1 else { throw MailExportError.invalidLayout }
            return try publish(data, suggestedName: components[0])
        }
        guard data.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
        let key = components.map(Self.nameKey).joined(separator: "/")
        guard !used.contains(key) else { throw MailExportError.nameConflict }
        try directory.verifyIdentity(at: directoryURL)
        var parent = directory, url = directoryURL, chain: [(AppDirectory, URL)] = [(directory, directoryURL)]
        var path: [String] = []
        for component in components.dropLast() {
            try Task.checkCancellation()
            path.append(component); url.appendPathComponent(component, isDirectory: true)
            let identity = path.map(Self.nameKey).joined(separator: "/")
            if let existing = plannedDirectories[identity] {
                try existing.verifyIdentity(at: url); parent = existing
            } else {
                parent = try parent.child(component, create: true, exclusive: true)
                try parent.verifyIdentity(at: url); plannedDirectories[identity] = parent
            }
            chain.append((parent, url))
        }
        for (handle, location) in chain { try handle.verifyIdentity(at: location) }
        let output = url.appendingPathComponent(components.last!, isDirectory: false)
        try SecureFileWriter.write(data, to: output, root: url, policy: .createOnly)
        for (handle, location) in chain { try handle.verifyIdentity(at: location) }
        used.insert(key)
        return output
    }

    public func write(_ data: Data, suggestedName: String) throws -> URL {
        try Task.checkCancellation()
        return try publish(data, suggestedName: suggestedName)
    }

    /// Cancellation still leaves a bounded manifest explaining completed files.
    public func writeReceipt(_ data: Data, suggestedName: String) throws -> URL {
        guard filename == nil else { throw MailExportError.unsafeDestination }
        if planned {
            guard Self.validName(suggestedName), suggestedName.utf8.count <= 255 else { throw MailExportError.invalidLayout }
            guard data.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
            try directory.verifyIdentity(at: directoryURL)
            let output = directoryURL.appendingPathComponent(suggestedName, isDirectory: false)
            try SecureFileWriter.write(data, to: output, root: directoryURL, policy: .createOnly)
            try directory.verifyIdentity(at: directoryURL)
            used.insert(Self.nameKey(suggestedName))
            return output
        }
        used.remove(suggestedName.lowercased())
        return try publish(data, suggestedName: suggestedName)
    }

    private func publish(_ data: Data, suggestedName: String) throws -> URL {
        guard data.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
        try directory.verifyIdentity(at: directoryURL)
        let name: String
        let policy: SecureFileWriter.WritePolicy
        if let filename {
            guard !used.contains(filename.lowercased()) else { throw MailExportError.changed }
            name = filename
            policy = previous.map { .matching($0) } ?? .createOnly
        } else {
            let base = Self.safeName(suggestedName)
            let path = URL(fileURLWithPath: base)
            var candidate = base, index = 2
            while used.contains(candidate.lowercased()) || directory.exists(candidate) {
                let stem = path.deletingPathExtension().lastPathComponent
                candidate = stem + " (\(index))" + (path.pathExtension.isEmpty ? "" : "." + path.pathExtension)
                index += 1
            }
            name = candidate; policy = .createOnly
        }
        let target = directoryURL.appendingPathComponent(name, isDirectory: false)
        try SecureFileWriter.write(data, to: target, root: directoryURL, policy: policy)
        try directory.verifyIdentity(at: directoryURL)
        used.insert(name.lowercased())
        return target
    }

    public static func safeName(_ value: String) -> String {
        let clean = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) ? "_" : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        for character in clean {
            guard name.utf8.count + String(character).utf8.count <= 160 else { break }
            name.append(character)
        }
        return validName(name) ? name : "mail"
    }

    static func nameKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
