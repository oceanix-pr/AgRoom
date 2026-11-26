import CryptoKit
import Darwin
import Foundation
import GRDB

public enum MailImportError: String, Error, Codable, Sendable {
    case unreadable, invalidMessage, unsupported, capacity, changed, cancelled, storage, localOnly, variantRequired, mappingInvalid
}

public struct MailImportedEnvelope: Sendable {
    public var subject: String
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var replyTo: [MailAddress]
    public var messageID: String?
    public var references: String?
    public var date: Date?
}

public struct MailImportCandidate: Identifiable, Sendable {
    public let id: UUID
    public let source: String
    public let folder: String
    public let envelope: MailImportedEnvelope
    public let data: Data
    public let sha256: String
    public let sourceVariant: MailMboxVariant?

    init(id: UUID, source: String, folder: String, envelope: MailImportedEnvelope, data: Data, sha256: String,
         sourceVariant: MailMboxVariant? = nil) {
        self.id = id; self.source = source; self.folder = folder; self.envelope = envelope; self.data = data
        self.sha256 = sha256; self.sourceVariant = sourceVariant
    }
}

public struct MailImportResult: Identifiable, Codable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable { case imported, duplicate, failed, unprocessed }
    public let id: UUID
    public let source: String
    public var subject: String
    public var status: Status
    public var messageID: UUID?
    public var error: MailImportError?
    public var originalIdentity: MailImportIdentity? = nil
    public var sourceVariant: MailMboxVariant? = nil
    public var destinationFolderIDs: [UUID]? = nil
}

public struct MailImportPreview: Sendable {
    public var candidates: [MailImportCandidate] = []
    public var failures: [MailImportResult] = []
    public var duplicates: Set<UUID> = []
    public var duplicateMatches: [UUID: MailImportDuplicateMatch] = [:]
    public var byteCount = 0
}

public struct MailImportBatch: Identifiable, Codable, Sendable {
    public enum State: String, Codable, Sendable { case running, complete, cancelled, interrupted }
    public let id: UUID
    public let accountID: UUID
    public let createdAt: Date
    public var state: State
    public var results: [MailImportResult]
    public var undo: MailImportUndoReceipt? = nil
    public var resumeManifest: MailImportResumeManifest? = nil
    public var runToken: UUID? = nil
}

public struct MailImportUndoPlan: Sendable {
    public struct Candidate: Sendable {
        public let messageID: UUID
        public let subject: String
        let fingerprint: String?
    }
    public let batchID: UUID
    public let accountID: UUID
    public let candidates: [Candidate]
    public var count: Int { candidates.filter { $0.fingerprint != nil }.count }
}

public struct MailImportUndoReceipt: Codable, Sendable, Equatable {
    public let batchID: UUID
    public let accountID: UUID
    public let createdAt: Date
    public let removed: [UUID]
    public let skipped: [UUID]
}

/// A bounded, owned snapshot. No external URL or persistent access grant enters the database.
public enum MailImportReader {
    public static let maximumBytes = 128 * 1024 * 1024
    public static let maximumItems = 10_000

    public static func read(_ urls: [URL], variant: MailMboxVariant = .automatic, progress: @Sendable (Int) -> Void = { _ in }) throws -> MailImportPreview {
        guard urls.count <= maximumItems else { throw MailImportError.capacity }
        var preview = MailImportPreview()
        var inspected = 0
        func failed(_ source: String, _ error: MailImportError) {
            preview.failures.append(.init(id: UUID(), source: source, subject: "", status: .failed, error: error))
        }
        func accept(_ data: Data, source: String, folder: String, sourceVariant: MailMboxVariant? = nil) throws {
            try Task.checkCancellation()
            guard preview.candidates.count + preview.failures.count < maximumItems,
                  data.count <= MailService.rawMessageByteLimit,
                  data.count <= maximumBytes - preview.byteCount else { throw MailImportError.capacity }
            do {
                let envelope = try MailFoundationAdapter.importedEnvelope(data)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                preview.candidates.append(.init(id: UUID(), source: source, folder: folder, envelope: envelope, data: data, sha256: hash, sourceVariant: sourceVariant))
                preview.byteCount += data.count
            } catch is CancellationError { throw CancellationError() }
            catch { failed(source, .invalidMessage) }
            progress(preview.candidates.count + preview.failures.count)
        }
        func readFile(_ parent: AppDirectory, name: String, source: String, folder: String) throws {
            try Task.checkCancellation()
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext == "eml" || ext == "mbox" || name.lowercased() == "mbox" else {
                failed(source, .unsupported); return
            }
            let candidatesBefore = preview.candidates.count, failuresBefore = preview.failures.count, bytesBefore = preview.byteCount
            var opened: MailImportSourceFile?
            do {
                let file = try MailImportSourceFile(parent: parent, name: name)
                opened = file
                if ext == "eml" {
                    try accept(file.readAll(limit: MailService.rawMessageByteLimit), source: source, folder: folder)
                } else {
                    let destination = [folder, (name as NSString).deletingPathExtension].filter { !$0.isEmpty && $0.lowercased() != "mbox" }.joined(separator: "/")
                    try MailMboxCodec.decodeStream(variant: variant, read: { try file.read(maximum: $0) }) { index, location, message in
                        try accept(message, source: source + "#\(index + 1)", folder: destination, sourceVariant: location.variant)
                    }
                }
                try file.validate()
            } catch is CancellationError { throw CancellationError() }
            catch {
                var failure = (error as? MailImportError) ?? .unreadable
                if let opened {
                    do { try opened.validate() }
                    catch { failure = .changed }
                }
                if failure == .capacity { throw failure }
                if failure == .changed {
                    preview.candidates.removeSubrange(candidatesBefore...)
                    preview.failures.removeSubrange(failuresBefore...)
                    preview.byteCount = bytesBefore
                }
                failed(source, failure)
            }
        }
        func walk(_ directory: AppDirectory, source: String, depth: Int) throws {
            guard depth <= 12 else { failed(source, .capacity); return }
            let copied = dup(directory.fd)
            guard copied >= 0, let stream = fdopendir(copied) else { if copied >= 0 { close(copied) }; throw MailImportError.unreadable }
            defer { closedir(stream) }
            var names: [String] = []
            while let entry = readdir(stream) {
                try Task.checkCancellation()
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name.hasPrefix(".") { continue }
                inspected += 1
                guard inspected <= maximumItems else { throw MailImportError.capacity }
                names.append(name)
            }
            for name in names.sorted() {
                try Task.checkCancellation()
                let relative = source + "/" + name
                var info = stat()
                guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { failed(relative, .unreadable); continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    do { try walk(directory.child(name, create: false), source: relative, depth: depth + 1) }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as MailImportError where error == .capacity { throw error }
                    catch { failed(relative, .unreadable) }
                } else if info.st_mode & S_IFMT == S_IFREG {
                    let ext = (name as NSString).pathExtension.lowercased()
                    if ext == "eml" || ext == "mbox" || name.lowercased() == "mbox" {
                        try readFile(directory, name: name, source: relative, folder: source)
                    }
                } else { failed(relative, .unreadable) }
            }
        }
        for url in urls {
            try Task.checkCancellation()
            guard url.isFileURL else { failed(url.lastPathComponent, .unreadable); continue }
            do {
                let parent = try AppDirectory(url: url.deletingLastPathComponent(), create: false)
                var info = stat()
                let name = url.lastPathComponent
                guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw MailImportError.unreadable }
                if info.st_mode & S_IFMT == S_IFDIR {
                    try walk(parent.child(name, create: false), source: name, depth: 0)
                } else {
                    try readFile(parent, name: name, source: name, folder: "")
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as MailImportError where error == .capacity { throw error }
            catch { failed(url.lastPathComponent, .unreadable) }
        }
        guard preview.candidates.count + preview.failures.count <= maximumItems else { throw MailImportError.capacity }
        return preview
    }
}

/// mboxrd export preserves message octets except envelope framing and transport quotes.
/// Import also supports explicit historical variants through the bounded stream decoder.
public enum MailMboxCodec {
    public struct Record: Sendable {
        public let data: Data
        public let originalSHA256: String
        public let originalByteCount: Int
    }

    /// No MIME reconstruction or newline conversion. Unsupported originals remain
    /// available as exact EML files rather than silently changing their bytes.
    public static func encode(_ raw: Data, date: Date?) throws -> Record {
        guard !raw.isEmpty, raw.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
        guard raw.last == 10 else { throw MailExportError.mboxRequiresEML }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        var output = Data(("From MAILER-DAEMON " + formatter.string(from: date ?? Date(timeIntervalSince1970: 0)) + "\n").utf8)
        let bytes = [UInt8](raw)
        var start = 0, inBody = false
        while start < bytes.count {
            try Task.checkCancellation()
            let end = bytes[start...].firstIndex(of: 10).map { $0 + 1 } ?? bytes.count
            let line = bytes[start..<end]
            if !inBody {
                if line == [10] || line == [13, 10] { inBody = true }
                else if String(decoding: line.prefix(15), as: UTF8.self).lowercased().hasPrefix("content-length:") {
                    throw MailExportError.mboxRequiresEML
                }
            } else {
                var from = start
                while from < end && bytes[from] == 62 { from += 1 }
                if bytes[from..<end].starts(with: [70, 114, 111, 109, 32]) { output.append(62) }
            }
            output.append(contentsOf: line)
            guard output.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
            start = end
        }
        guard inBody else { throw MailExportError.mboxRequiresEML }
        output.append(contentsOf: raw.suffix(2) == Data([13, 10]) ? [13, 10] : [10])
        guard output.count <= MailService.rawMessageByteLimit else { throw MailExportError.tooLarge }
        return Record(data: output, originalSHA256: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(), originalByteCount: raw.count)
    }

    public static func decode(_ data: Data, variant: MailMboxVariant = .automatic, consume: (Int, Data) throws -> Void) throws {
        guard data.count <= MailImportReader.maximumBytes else { throw MailImportError.capacity }
        var position = data.startIndex
        try decodeStream(variant: variant, read: { maximum in
            let end = min(data.endIndex, position + min(maximum, data.endIndex - position))
            let chunk = Data(data[position..<end]); position = end
            return chunk
        }, consume: { index, _, original in try consume(index, original) })
    }

}

extension MailService {
    static func createImportUndoSchema(_ db: Database) throws {
        try db.create(table: "mail_import_undos", ifNotExists: true) { t in
            t.column("batchID", .text).primaryKey().references("mail_import_batches", onDelete: .cascade)
            t.column("payload", .blob).notNull()
        }
    }

    public func previewImportUndo(batchID: UUID, archiveID: UUID) async throws -> MailImportUndoPlan {
        try await databaseQueue.read { db in
            try Self.requireLocalArchive(archiveID, db: db)
            guard try String.fetchOne(db, sql: "SELECT accountID FROM mail_import_batches WHERE id=?", arguments: [batchID.uuidString]) == archiveID.uuidString,
                  try !Self.importWasUndone(batchID, db: db) else { throw MailImportError.changed }
            let ids = try String.fetchAll(db, sql: "SELECT messageID FROM mail_import_origins WHERE batchID=? AND accountID=? ORDER BY messageID", arguments: [batchID.uuidString, archiveID.uuidString])
            let entries = try ids.compactMap { raw -> MailImportUndoPlan.Candidate? in
                guard let id = UUID(uuidString: raw) else { throw MailImportError.changed }
                let message = try MailMessageRow.fetchOne(db, key: raw)?.toMessage()
                return .init(messageID: id, subject: message?.subject ?? "", fingerprint: try Self.importUndoFingerprint(id, batchID: batchID, accountID: archiveID, db: db))
            }
            return .init(batchID: batchID, accountID: archiveID, candidates: entries)
        }
    }

    /// One transaction: frozen identities are checked again, changed messages are
    /// skipped, and the undo marker prevents a concurrent importer from republishing.
    public func undoImport(_ plan: MailImportUndoPlan) async throws -> MailImportUndoReceipt {
        try await databaseQueue.maintenanceWrite { db in
            try Task.checkCancellation()
            try Self.requireLocalArchive(plan.accountID, db: db)
            guard try String.fetchOne(db, sql: "SELECT accountID FROM mail_import_batches WHERE id=?", arguments: [plan.batchID.uuidString]) == plan.accountID.uuidString else { throw MailImportError.changed }
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM mail_import_undos WHERE batchID=?", arguments: [plan.batchID.uuidString]) {
                return try JSONDecoder().decode(MailImportUndoReceipt.self, from: data)
            }
            let current = Set(try String.fetchAll(db, sql: "SELECT messageID FROM mail_import_origins WHERE batchID=? AND accountID=?", arguments: [plan.batchID.uuidString, plan.accountID.uuidString]))
            let reviewed = Set(plan.candidates.map { $0.messageID.uuidString })
            guard current.isSubset(of: reviewed) else { throw MailImportError.changed }
            var removed: [UUID] = [], skipped: [UUID] = []
            for item in plan.candidates {
                try Task.checkCancellation()
                guard let fingerprint = item.fingerprint,
                      try Self.importUndoFingerprint(item.messageID, batchID: plan.batchID, accountID: plan.accountID, db: db) == fingerprint else {
                    skipped.append(item.messageID); continue
                }
                try Self.deleteMessageContents(messageId: item.messageID, in: db)
                _ = try MailMessageRow.filter(Column("id") == item.messageID.uuidString).deleteAll(db)
                removed.append(item.messageID)
            }
            let receipt = MailImportUndoReceipt(batchID: plan.batchID, accountID: plan.accountID, createdAt: Date(), removed: removed, skipped: skipped)
            try Task.checkCancellation()
            try db.execute(sql: "INSERT INTO mail_import_undos(batchID,payload) VALUES(?,?)", arguments: [plan.batchID.uuidString, try JSONEncoder().encode(receipt)])
            return receipt
        }
    }

    private static func importUndoFingerprint(_ id: UUID, batchID: UUID, accountID: UUID, db: Database) throws -> String? {
        guard let row = try Row.fetchOne(db, sql: "SELECT sha256 FROM mail_import_origins WHERE messageID=? AND batchID=? AND accountID=?", arguments: [id.uuidString, batchID.uuidString, accountID.uuidString]),
              var message = try MailMessageRow.fetchOne(db, key: id.uuidString)?.toMessage(), message.accountId == accountID,
              let raw = try Row.fetchOne(db, sql: "SELECT kind,data FROM mail_raw_messages WHERE messageID=?", arguments: [id.uuidString]),
              (raw["kind"] as String) == MailRawKind.imported.rawValue else { return nil }
        message.bodyState = .none; message.snippet = ""
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256(); hash.update(data: try encoder.encode(message))
        hash.update(data: Data((row["sha256"] as String).utf8)); hash.update(data: raw["data"] as Data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func importWasUndone(_ id: UUID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_import_undos WHERE batchID=?)", arguments: [id.uuidString]) == true
    }
    static func createImportSchema(_ db: Database) throws {
        if try !db.columns(in: "mail_accounts").contains(where: { $0.name == "sourceKind" }) {
            try db.alter(table: "mail_accounts") { $0.add(column: "sourceKind", .text).notNull().defaults(to: MailAccountSource.imap.rawValue) }
        }
        try db.create(table: "mail_import_batches", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("accountID", .text).notNull().references("mail_accounts", onDelete: .cascade)
            t.column("createdAt", .datetime).notNull()
            t.column("payload", .blob).notNull()
        }
        try db.create(table: "mail_import_origins", ifNotExists: true) { t in
            t.column("messageID", .text).primaryKey().references("mail_messages", onDelete: .cascade)
            t.column("accountID", .text).notNull().references("mail_accounts", onDelete: .cascade)
            t.column("batchID", .text).notNull().references("mail_import_batches", onDelete: .cascade)
            t.column("folderPath", .text).notNull()
            t.column("sha256", .text).notNull()
            t.column("source", .text).notNull()
            t.uniqueKey(["accountID", "folderPath", "sha256"])
        }
        try db.create(table: "mail_import_entries", ifNotExists: true) { t in
            t.column("id", .text).notNull()
            t.column("batchID", .text).notNull().indexed().references("mail_import_batches", onDelete: .cascade)
            t.column("payload", .blob).notNull()
            t.primaryKey(["batchID", "id"])
        }
    }

    public func createLocalArchive(name: String, inboxName: String, trashName: String, archiveName: String) async throws -> MailAccount {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 240, !title.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else { throw MailImportError.invalidMessage }
        let account = MailAccount(displayName: title, emailAddress: "", imapHost: "", smtpHost: "", username: "", sourceKind: .localArchive)
        try await databaseQueue.maintenanceWrite { db in
            var row = MailAccountRow(from: account); try row.insert(db)
            for (path, title, role) in [("INBOX", inboxName, MailFolderRole.inbox), ("Trash", trashName, .trash), ("Archive", archiveName, .archive)] {
                var folder = MailFolderRow(from: .init(accountId: account.id, path: path, name: title, role: role))
                try folder.insert(db)
            }
        }
        return account
    }

    public func importPreview(_ preview: MailImportPreview, archiveID: UUID?) async throws -> MailImportPreview {
        var result = preview
        result.duplicateMatches = try await importDuplicateMatches(preview.candidates.map(\.metadata), archiveID: archiveID)
        result.duplicates = Set(result.duplicateMatches.keys)
        return result
    }

    public func importPreview(_ preview: MailImportIndexedPreview, archiveID: UUID?) async throws -> MailImportIndexedPreview {
        var result = preview
        result.duplicateMatches = try await importDuplicateMatches(preview.candidates, archiveID: archiveID)
        result.duplicates = Set(result.duplicateMatches.keys)
        return result
    }

    private func importDuplicateMatches(_ candidates: [MailImportMetadata], archiveID: UUID?) async throws -> [UUID: MailImportDuplicateMatch] {
        try await databaseQueue.read { db in
            var matches: [UUID: MailImportDuplicateMatch] = [:], seen: [Data: UUID] = [:]
            if let archiveID { try Self.requireLocalArchive(archiveID, db: db) }
            for item in candidates {
                try Task.checkCancellation()
                let key = Data((item.folder + "\0" + item.sha256).utf8)
                let existing = try archiveID.flatMap { id in
                    try String.fetchOne(db, sql: "SELECT o.messageID FROM mail_import_origins o JOIN mail_messages m ON m.id=o.messageID AND m.accountId=o.accountID WHERE o.accountID=? AND o.folderPath=? AND o.sha256=?", arguments: [id.uuidString, item.folder, item.sha256]).flatMap(UUID.init(uuidString:))
                }
                if let existing { matches[item.id] = .existing(existing) }
                else if let original = seen[key] { matches[item.id] = .candidate(original) }
                if seen[key] == nil { seen[key] = item.id }
            }
            return matches
        }
    }

    public func importMessages(_ preview: MailImportPreview, archiveID: UUID,
                               progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> MailImportBatch {
        try await performImportMessages(preview, archiveID: archiveID, mappingReview: nil, progress: progress)
    }

    func performImportMessages(_ preview: MailImportPreview, archiveID: UUID, mappingReview: MailImportMappingReview?,
                               progress: @Sendable (Int, Int) async -> Void) async throws -> MailImportBatch {
        guard preview.candidates.count <= MailImportReader.maximumItems,
              preview.candidates.reduce(0, { $0 + $1.data.count }) <= MailImportReader.maximumBytes else { throw MailImportError.capacity }
        return try await performImportMessages(preview.candidates.map(\.metadata), failures: preview.failures, archiveID: archiveID,
            mappingReview: mappingReview, read: { preview.candidates[$0] }, progress: progress)
    }

    func performImportMessages(_ candidates: [MailImportMetadata], failures: [MailImportResult], archiveID: UUID, mappingReview: MailImportMappingReview?,
                               manifest: MailImportResumeManifest? = nil, resume: MailImportResumeReview? = nil,
                               read: @Sendable (Int) async throws -> MailImportCandidate,
                               progress: @Sendable (Int, Int) async -> Void) async throws -> MailImportBatch {
        guard candidates.count + failures.count <= MailImportReader.maximumItems,
              Set((candidates.map(\.id) + failures.map(\.id))).count == candidates.count + failures.count else { throw MailImportError.capacity }
        var batch = MailImportBatch(id: UUID(), accountID: archiveID, createdAt: Date(), state: .running,
            results: candidates.map { .init(id: $0.id, source: $0.source, subject: $0.envelope.subject, status: .unprocessed,
                originalIdentity: $0.identity, sourceVariant: $0.sourceVariant) } + failures)
        if let resume { batch = resume.batch; batch.state = .running }
        else { batch.resumeManifest = manifest }
        if batch.resumeManifest != nil { batch.runToken = UUID() }
        let runToken = batch.runToken
        var materialized = Set<UUID>()
        if let mappingReview {
            try Task.checkCancellation()
            let initial = batch
            materialized = try await databaseQueue.maintenanceWrite { db in
                try Task.checkCancellation()
                if let resume { try Self.validateImportResume(resume, db: db) }
                let materialized = try Self.beginImportMapping(mappingReview, db: db)
                try Self.writeImportBatch(initial, replacingToken: resume != nil, db: db)
                return materialized.union(initial.results.flatMap { $0.destinationFolderIDs ?? [] })
            }
        } else { try await storeImportBatch(batch) }
        let resultIndices = Dictionary(uniqueKeysWithValues: batch.results.enumerated().map { ($0.element.id, $0.offset) })
        for (index, item) in candidates.enumerated() {
            if Task.isCancelled { batch.state = .cancelled; break }
            do {
                let candidate = try await read(index)
                guard candidate.id == item.id, candidate.metadata.identity == item.identity,
                      Data(candidate.source.utf8) == Data(item.source.utf8) else { throw MailImportError.changed }
                let body = try MailFoundationAdapter.importedBody(candidate.data)
                guard let resultIndex = resultIndices[item.id] else { throw MailImportError.changed }
                let initial = batch.results[resultIndex], batchID = batch.id
                let requiredFolders = Set((mappingReview?.destinations[MailImportMappingSource.key(candidate.folder)] ?? []).map(\.folder.id).filter { materialized.contains($0) })
                let (outcome, created) = try await databaseQueue.maintenanceWrite { db -> (MailImportResult, Set<UUID>) in
                    try Task.checkCancellation()
                    try Self.requireImportRun(batchID, token: runToken, db: db)
                    try Self.requireLocalArchive(archiveID, db: db)
                    var result = initial, created = Set<UUID>()
                    if let mappingReview { created = try Self.validateImportMapping(mappingReview, source: candidate.folder, materialized: requiredFolders, db: db) }
                    if let existing = try String.fetchOne(db, sql: "SELECT messageID FROM mail_import_origins WHERE accountID=? AND folderPath=? AND sha256=?", arguments: [archiveID.uuidString, candidate.folder, candidate.sha256]), let id = UUID(uuidString: existing) {
                        result.status = .duplicate; result.messageID = id
                    } else {
                        let folderID: UUID
                        if let mappingReview {
                            let destination = try Self.resolveImportMapping(mappingReview, source: candidate.folder, materialized: requiredFolders, db: db)
                            folderID = destination.folderID; created.formUnion(destination.created)
                        } else { folderID = try Self.importFolder(archiveID: archiveID, path: candidate.folder, db: db) }
                        let maximum = try Int64.fetchOne(db, sql: "SELECT MAX(uid) FROM mail_messages WHERE accountId=? AND uid>=?", arguments: [archiveID.uuidString, Int64(Self.localUIDFloor)]) ?? Int64(Self.localUIDFloor) - 1
                        guard maximum < Int64(UInt32.max) else { throw MailImportError.capacity }
                        let envelope = candidate.envelope
                        let message = MailMessage(accountId: archiveID, folderId: folderID, uid: UInt32(maximum + 1),
                            messageId: envelope.messageID, subject: envelope.subject, fromName: envelope.from.name, fromAddress: envelope.from.address,
                            replyTo: envelope.replyTo, to: envelope.to, cc: envelope.cc, references: envelope.references, date: envelope.date,
                            hasAttachments: !body.attachments.isEmpty, sizeBytes: candidate.data.count,
                            snippet: String((body.textBody ?? "").prefix(200)), bodyState: .ready)
                        var row = MailMessageRow(from: message); try row.insert(db)
                        var storedBody = MailBodyRow(from: .init(messageId: message.id, textBody: body.textBody, htmlBody: body.htmlBody))
                        try storedBody.insert(db)
                        for part in body.attachments {
                            var attachment = MailAttachmentRow(from: .init(messageId: message.id, filename: part.filename, mimeType: part.mimeType,
                                sizeBytes: part.sizeBytes, contentId: part.contentId, isInline: part.isInline, partID: part.partID))
                            try attachment.insert(db)
                        }
                        try db.execute(sql: "INSERT INTO mail_raw_messages(messageID,data,kind,fetchedAt) VALUES(?,?,?,?)", arguments: [message.id.uuidString, candidate.data, MailRawKind.imported.rawValue, Date()])
                        try db.execute(sql: "INSERT INTO mail_import_origins(messageID,accountID,batchID,folderPath,sha256,source) VALUES(?,?,?,?,?,?)",
                            arguments: [message.id.uuidString, archiveID.uuidString, batchID.uuidString, candidate.folder, candidate.sha256, candidate.source])
                        result.status = .imported; result.messageID = message.id
                    }
                    result.destinationFolderIDs = Array(created).sorted { $0.uuidString < $1.uuidString }
                    try Self.writeImportEntry(result, batchID: batchID, db: db)
                    return (result, created)
                }
                materialized.formUnion(created)
                batch.results[resultIndex] = outcome
            } catch is CancellationError { batch.state = .cancelled; break }
            catch {
                guard let resultIndex = resultIndices[item.id] else { throw MailImportError.changed }
                batch.results[resultIndex].status = .failed
                batch.results[resultIndex].error = (error as? MailImportError) ?? .storage
                let result = batch.results[resultIndex], id = batch.id
                try await databaseQueue.maintenanceWrite { db in
                    try Self.requireImportRun(id, token: runToken, db: db)
                    try Self.writeImportEntry(result, batchID: id, db: db)
                }
            }
            await progress(index + 1, candidates.count)
        }
        if batch.state == .running { batch.state = Task.isCancelled ? .cancelled : .complete }
        let receipt = batch
        // A cancelled task must still persist the completed/remaining item report.
        try await Task.detached { try await self.storeImportBatch(receipt) }.value
        return batch
    }

    public func importBatches(archiveID: UUID, limit: Int = 20) async throws -> [MailImportBatch] {
        try await databaseQueue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM mail_import_batches WHERE accountID=? ORDER BY createdAt DESC LIMIT ?", arguments: [archiveID.uuidString, min(max(limit, 1), 100)]).map {
                var batch = try JSONDecoder().decode(MailImportBatch.self, from: $0)
                if batch.state == .running || batch.state == .interrupted {
                    let entries = try Data.fetchAll(db, sql: "SELECT payload FROM mail_import_entries WHERE batchID=?", arguments: [batch.id.uuidString])
                        .map { try JSONDecoder().decode(MailImportResult.self, from: $0) }
                    let completed = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
                    batch.results = batch.results.map { completed[$0.id] ?? $0 }
                }
                if let data = try Data.fetchOne(db, sql: "SELECT payload FROM mail_import_undos WHERE batchID=?", arguments: [batch.id.uuidString]) {
                    batch.undo = try JSONDecoder().decode(MailImportUndoReceipt.self, from: data)
                    if batch.state == .running || batch.state == .interrupted { batch.state = .cancelled }
                }
                return batch
            }
        }
    }

    private func storeImportBatch(_ batch: MailImportBatch) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try Self.requireLocalArchive(batch.accountID, db: db)
            try Self.writeImportBatch(batch, db: db)
        }
    }

    private static func writeImportBatch(_ batch: MailImportBatch, replacingToken: Bool = false, db: Database) throws {
        guard try !importWasUndone(batch.id, db: db) else { throw MailImportError.changed }
        if !replacingToken { try requireImportRun(batch.id, token: batch.runToken, db: db) }
        try db.execute(sql: "INSERT INTO mail_import_batches(id,accountID,createdAt,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
            arguments: [batch.id.uuidString, batch.accountID.uuidString, batch.createdAt, try JSONEncoder().encode(batch)])
        if batch.state != .running { try Self.trimBodyCache(in: db, maxBytes: Self.bodyCacheByteLimit) }
    }

    private static func writeImportEntry(_ result: MailImportResult, batchID: UUID, db: Database) throws {
        guard try !importWasUndone(batchID, db: db) else { throw MailImportError.changed }
        try db.execute(sql: "INSERT INTO mail_import_entries(id,batchID,payload) VALUES(?,?,?) ON CONFLICT(batchID,id) DO UPDATE SET payload=excluded.payload",
            arguments: [result.id.uuidString, batchID.uuidString, try JSONEncoder().encode(result)])
    }

    private static func requireLocalArchive(_ id: UUID, db: Database) throws {
        guard try MailAccountRow.fetchOne(db, key: id.uuidString)?.sourceKind == MailAccountSource.localArchive.rawValue else { throw MailImportError.localOnly }
    }

    private static func importFolder(archiveID: UUID, path: String, db: Database) throws -> UUID {
        if path.isEmpty {
            guard let folder = try MailFolderRow.filter(Column("accountId") == archiveID.uuidString).filter(Column("role") == MailFolderRole.inbox.rawValue).fetchOne(db),
                  let id = UUID(uuidString: folder.id) else { throw MailImportError.changed }
            return id
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.count <= 16, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw MailImportError.invalidMessage }
        var parent: String?, selected: UUID?
        for index in components.indices {
            let folderPath = "import/" + components[...index].joined(separator: "/")
            if let existing = try MailFolderRow.filter(Column("accountId") == archiveID.uuidString).filter(Column("path") == folderPath).fetchOne(db) {
                selected = UUID(uuidString: existing.id)
            } else {
                let folder = MailFolder(accountId: archiveID, path: folderPath, name: components[index], parentPath: parent, delimiter: "/")
                var row = MailFolderRow(from: folder); try row.insert(db); selected = folder.id
            }
            parent = folderPath
        }
        guard let selected else { throw MailImportError.invalidMessage }
        return selected
    }
}
