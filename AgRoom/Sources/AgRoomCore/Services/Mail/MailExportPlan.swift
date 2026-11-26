import Foundation
import GRDB

public enum MailExportFormat: String, CaseIterable, Sendable { case eml, pdf, mbox, bundle }
public enum MailExportNaming: String, CaseIterable, Sendable { case subject, dateSubject, dateSenderSubject }
public enum MailExportGrouping: String, CaseIterable, Sendable { case flat, accountFolder, month }

public struct MailExportSource: Sendable {
    public let message: MailMessage
    public let account: MailAccount
    public let folder: MailFolder
    /// Root to leaf; nil means the cached hierarchy cannot be proved complete.
    public let lineage: [MailFolder]?
    public let hasRaw: Bool
    public let rawKind: MailRawKind?
    public let bodyCached: Bool
    public let canRebuildOriginal: Bool
    public let possibleRemoteInlineImages: Bool
    public let allowsNetwork: Bool
}

public struct MailExportPreparation: Sendable {
    public let missingLocal: Int
    public let downloadCandidates: Int
    public let unavailableLocally: Int
    /// Full-message octets for EML/MBOX only; never a PDF body-download promise.
    public let knownDownloadBytes: Int64?
    public let unknownSizes: Int
}

/// An in-memory read review, bound to the exact originating database connection.
/// No credentials, output URL, persisted approval or executable continuation.
public struct MailExportReview: Sendable, Identifiable {
    public let id: UUID
    fileprivate let originQueue: DatabaseQueue
    public let sources: [MailExportSource]
    private let byID: [UUID: MailExportSource]
    public let allowsNetwork: Bool
    public let hasCompleteHierarchy: Bool
    public let coverage: MailExportCoverage

    fileprivate init(queue: DatabaseQueue, sources: [MailExportSource]) {
        id = UUID(); originQueue = queue; self.sources = sources
        byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.message.id, $0) })
        allowsNetwork = sources.contains(where: \.allowsNetwork)
        hasCompleteHierarchy = sources.allSatisfy { $0.lineage != nil }
        var result = MailExportCoverage()
        for source in sources {
            result.total += 1; result.titles[source.message.id] = source.message.subject
            if source.hasRaw { result.raw += 1 }
            if source.rawKind == .generated { result.generated += 1 }
            if source.bodyCached { result.bodies += 1 }
        }
        coverage = result
    }
    public func source(_ id: UUID) -> MailExportSource? { byID[id] }
    public func preparation(for format: MailExportFormat) -> MailExportPreparation {
        var missing = 0, candidates = 0, unavailable = 0, unknown = 0
        var bytes: Int64? = 0
        for source in sources {
            let local = format == .pdf ? source.bodyCached || source.hasRaw : source.hasRaw || source.canRebuildOriginal
            if !local { missing += 1; if !source.allowsNetwork { unavailable += 1 } }
            let needsNetwork = !local || (format == .pdf && !source.hasRaw && source.possibleRemoteInlineImages)
            guard source.allowsNetwork, needsNetwork else { continue }
            candidates += 1
            if format == .pdf { unknown += 1; bytes = nil; continue }
            if source.message.sizeBytes > 0, let previous = bytes {
                let sum = previous.addingReportingOverflow(Int64(source.message.sizeBytes))
                bytes = sum.overflow ? nil : sum.partialValue
            } else if source.message.sizeBytes <= 0 { unknown += 1 }
        }
        return .init(missingLocal: missing, downloadCandidates: candidates, unavailableLocally: unavailable,
            knownDownloadBytes: bytes, unknownSizes: unknown)
    }
}

extension MailService {
    public func reviewExport(ids: [UUID]) async throws -> MailExportReview {
        let queue = databaseQueue
        return try await queue.read { db in
            var seen = Set<UUID>(), sources: [MailExportSource] = []
            var accounts: [UUID: MailAccount] = [:]
            var folders: [UUID: [Data: MailFolder]] = [:]
            var folderIDs: [UUID: MailFolder] = [:], pendingAccounts: [UUID: Bool] = [:]
            var lineages: [UUID: [MailFolder]] = [:], invalidLineages = Set<UUID>()
            for id in ids where seen.insert(id).inserted {
                try Task.checkCancellation()
                guard let message = try MailMessageRow.fetchOne(db, key: id.uuidString)?.toMessage(),
                      message.date?.timeIntervalSince1970.isFinite != false else { throw MailExportError.changed }
                if accounts[message.accountId] == nil {
                    guard let account = try MailAccountRow.fetchOne(db, key: message.accountId.uuidString)?.toAccount() else { throw MailExportError.changed }
                    accounts[account.id] = account
                    let values = try MailFolderRow.filter(Column("accountId") == account.id.uuidString).fetchAll(db).compactMap { $0.toFolder() }
                    folders[account.id] = Dictionary(uniqueKeysWithValues: values.map { (Data($0.path.utf8), $0) })
                    for folder in values { folderIDs[folder.id] = folder }
                    pendingAccounts[account.id] = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_folder_mutations WHERE accountID=? AND state IN ('prepared','sent','acknowledged','unknown'))", arguments: [account.id.uuidString]) ?? false
                }
                let account = accounts[message.accountId]!
                guard let folder = folderIDs[message.folderId], folder.accountId == account.id, !folder.isContainer else { throw MailExportError.changed }
                if lineages[folder.id] == nil && !invalidLineages.contains(folder.id) {
                    var chain = [folder], visited: Set<UUID> = [folder.id]
                    while let parentPath = chain.last?.parentPath {
                        guard chain.count < 128, let parent = folders[account.id]?[Data(parentPath.utf8)], visited.insert(parent.id).inserted else {
                            invalidLineages.insert(folder.id); break
                        }
                        chain.append(parent)
                    }
                    if !invalidLineages.contains(folder.id) { lineages[folder.id] = Array(chain.reversed()) }
                }
                let cache = try Row.fetchOne(db, sql: "SELECT r.kind,length(r.data) AS rawBytes,b.messageID AS bodyID,b.textBody IS NOT NULL AS hasText,b.htmlBody IS NOT NULL AS hasHTML FROM mail_messages m LEFT JOIN mail_raw_messages r ON r.messageID=m.id LEFT JOIN mail_bodies b ON b.messageID=m.id WHERE m.id=?", arguments: [id.uuidString])!
                let rawBytes: Int? = cache["rawBytes"], rawKind: String? = cache["kind"]
                let hasRaw = rawKind.flatMap(MailRawKind.init(rawValue:)) != nil && rawBytes.map { $0 > 0 && $0 <= Self.rawMessageByteLimit } == true
                let hasText: Bool = cache["hasText"], hasHTML: Bool = cache["hasHTML"]
                let bodyID: String? = cache["bodyID"]
                let bodyCached = hasText || hasHTML || (bodyID != nil && message.bodyState == .ready)
                let pending = pendingAccounts[account.id] == true
                let inline = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_attachments WHERE messageId=? AND contentId IS NOT NULL AND localPath IS NULL)", arguments: [id.uuidString]) ?? false
                sources.append(.init(message: message, account: account, folder: folder, lineage: lineages[folder.id], hasRaw: hasRaw,
                    rawKind: hasRaw ? rawKind.flatMap(MailRawKind.init(rawValue:)) : nil,
                    bodyCached: bodyCached, canRebuildOriginal: !hasRaw && !account.isLocalArchive && message.uid >= Self.localUIDFloor && !message.hasAttachments && hasText,
                    possibleRemoteInlineImages: inline,
                    allowsNetwork: !account.isLocalArchive && account.isEnabled && message.uid < Self.localUIDFloor && !pending))
            }
            return MailExportReview(queue: queue, sources: sources)
        }
    }

    public func validateExport(_ review: MailExportReview, messageID: UUID? = nil) async throws {
        guard review.originQueue === databaseQueue else { throw MailExportError.changed }
        let sources: [MailExportSource]
        if let messageID {
            guard let source = review.source(messageID) else { throw MailExportError.changed }
            sources = [source]
        } else { sources = review.sources }
        try await databaseQueue.read { db in
            for source in sources {
                try Task.checkCancellation()
                try Self.validateExportSource(source, db: db)
            }
        }
    }

    private static func validateExportSource(_ source: MailExportSource, db: Database) throws {
        guard let current = try MailMessageRow.fetchOne(db, key: source.message.id.uuidString)?.toMessage(),
              let account = try MailAccountRow.fetchOne(db, key: source.account.id.uuidString)?.toAccount(),
              Self.sameFolderMutationAccount(account, source.account),
              account.displayName == source.account.displayName, account.emailAddress == source.account.emailAddress,
              current.accountId == source.message.accountId, current.folderId == source.message.folderId,
              current.uid == source.message.uid, current.messageId == source.message.messageId,
              current.subject == source.message.subject, current.fromName == source.message.fromName,
              current.fromAddress == source.message.fromAddress, current.date == source.message.date else { throw MailExportError.changed }
        // Counts, flags and cache eviction may change without changing the source.
        for expected in source.lineage ?? [source.folder] {
            guard let folder = try MailFolderRow.fetchOne(db, key: expected.id.uuidString)?.toFolder(),
                  folder.accountId == expected.accountId, folder.path == expected.path, folder.name == expected.name,
                  folder.parentPath == expected.parentPath, folder.delimiter == expected.delimiter,
                  folder.uidValidity == expected.uidValidity else { throw MailExportError.changed }
        }
    }

    /// Validate and publish every parsed field in the same transaction. A late
    /// body read must not attach itself to a newly rebound UID or renamed folder.
    func saveExportBody(_ remote: RemoteMessageBody, messageID: UUID, review: MailExportReview, snippet: String) async throws -> MailBody {
        guard review.originQueue === databaseQueue, let source = review.source(messageID) else { throw MailExportError.changed }
        if let bodyWriteFailureForTesting { throw bodyWriteFailureForTesting }
        let body = MailBody(messageId: messageID, textBody: remote.textBody, htmlBody: remote.htmlBody)
        try await databaseQueue.maintenanceWrite { db in
            try Self.validateExportSource(source, db: db)
            guard var message = try MailMessageRow.fetchOne(db, key: messageID.uuidString) else { throw MailExportError.changed }
            var row = MailBodyRow(from: body); try row.save(db)
            if let references = remote.references, !references.isEmpty { message.references = references }
            message.hasAttachments = !remote.attachments.isEmpty; message.bodyState = MailBodyState.ready.rawValue
            if message.snippet.isEmpty { message.snippet = snippet }
            try message.update(db)
            try Self.replaceAttachments(messageId: messageID, attachments: remote.attachments.map {
                .init(messageId: messageID, filename: $0.filename, mimeType: $0.mimeType, sizeBytes: $0.sizeBytes,
                    contentId: $0.contentId, isInline: $0.isInline, partID: $0.partID)
            }, in: db, restoringOriginal: remote.attachments.allSatisfy { $0.partID?.hasPrefix("local:") == true })
            if let original = remote.rawMessage {
                if let expected = source.message.messageId {
                    guard try MailFoundationAdapter.originalMessageID(original) == expected else { throw MailExportError.changed }
                }
                try Self.saveRawMessage(id: messageID, raw: .init(data: original, kind: .received), in: db)
            }
            try Self.trimBodyCache(in: db, maxBytes: Self.bodyCacheByteLimit)
        }
        return body
    }

    func saveExportAttachment(_ attachment: MailAttachment, review: MailExportReview) async throws {
        guard review.originQueue === databaseQueue, let source = review.source(attachment.messageId) else { throw MailExportError.changed }
        try await databaseQueue.maintenanceWrite { db in
            try Self.validateExportSource(source, db: db)
            guard let current = try MailAttachmentRow.fetchOne(db, key: attachment.id.uuidString),
                  current.messageId == attachment.messageId.uuidString, current.filename == attachment.filename,
                  current.mimeType == attachment.mimeType, current.partID == attachment.partID,
                  current.contentId == attachment.contentId, current.isInline == attachment.isInline else { throw MailExportError.changed }
            var row = MailAttachmentRow(from: attachment); try row.save(db)
        }
    }

}

public struct MailExportLayoutLabels: Sendable {
    public let undated: String
    public let untitled: String
    public let volumeBase: String
    public init(undated: String, untitled: String, volumeBase: String) {
        self.undated = undated; self.untitled = untitled; self.volumeBase = volumeBase
    }
}

public struct MailExportLayoutOptions: Sendable {
    public let format: MailExportFormat
    public let naming: MailExportNaming
    public let grouping: MailExportGrouping
    public let directoryName: String
    public let timeZoneIdentifier: String
    public let labels: MailExportLayoutLabels
    public init(format: MailExportFormat, naming: MailExportNaming, grouping: MailExportGrouping, directoryName: String,
                timeZoneIdentifier: String, labels: MailExportLayoutLabels) {
        self.format = format; self.naming = naming; self.grouping = grouping; self.directoryName = directoryName
        self.timeZoneIdentifier = timeZoneIdentifier; self.labels = labels
    }
}

public struct MailExportLayoutEntry: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let components: [String]
    public var path: String { components.joined(separator: "/") }
}

public struct MailExportLayoutGroup: Sendable, Identifiable {
    public let id: String
    public let directory: [String]
    public let messageIDs: [UUID]
    public let volumeBase: String
    public func path(part: Int) throws -> [String] {
        guard part > 0, part <= messageIDs.count else { throw MailExportError.invalidLayout }
        let number = String(part)
        return directory + [volumeBase + "-" + String(repeating: "0", count: max(0, 4 - number.count)) + number + ".mbox"]
    }
}

public struct MailExportLayout: Sendable {
    public let reviewID: UUID
    public let options: MailExportLayoutOptions
    public let directoryName: String
    public let isDirectory: Bool
    public let entries: [MailExportLayoutEntry]
    public let groups: [MailExportLayoutGroup]
    private let byID: [UUID: MailExportLayoutEntry]
    public func entry(_ id: UUID) -> MailExportLayoutEntry? { byID[id] }

    public static func build(review: MailExportReview, options: MailExportLayoutOptions) throws -> MailExportLayout {
        try Task.checkCancellation()
        let isDirectory = options.format == .bundle || review.sources.count > 1 || options.grouping != .flat
        if isDirectory {
            let name = options.directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 1024 else { throw MailExportError.invalidLayout }
        }
        guard [options.labels.undated, options.labels.untitled, options.labels.volumeBase].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw MailExportError.invalidLayout }
        let day = DateFormatter(), month = DateFormatter()
        for formatter in [day, month] {
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: options.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        }
        day.dateFormat = "yyyy-MM-dd"; month.dateFormat = "yyyy-MM"
        var names = ExportNames(), sourceDirectories: [UUID: [String]] = [:]
        var groups: [(id: String, directory: [String], ids: [UUID])] = [], groupIndexes: [String: Int] = [:]
        for source in review.sources {
            try Task.checkCancellation()
            let directory: [String], key: String
            switch options.grouping {
            case .flat: directory = []; key = ""
            case .month:
                let label = source.message.date.map { month.string(from: $0) } ?? options.labels.undated
                key = "month:" + (source.message.date.map { month.string(from: $0) } ?? "undated")
                directory = try names.directory(owner: key, parent: [], name: label)
            case .accountFolder:
                guard let lineage = source.lineage else { throw MailExportError.changed }
                let account = source.account
                let label = [account.displayName, account.emailAddress, account.username].first { !$0.isEmpty } ?? String(account.id.uuidString.prefix(8))
                var path = try names.directory(owner: "account:" + account.id.uuidString, parent: [], name: label)
                for folder in lineage {
                    path = try names.directory(owner: "folder:" + folder.id.uuidString, parent: path,
                        name: folder.name.isEmpty ? String(folder.id.uuidString.prefix(8)) : folder.name)
                }
                directory = path; key = "folder:" + source.folder.id.uuidString
            }
            sourceDirectories[source.message.id] = directory
            if let index = groupIndexes[key] { groups[index].ids.append(source.message.id) }
            else { groupIndexes[key] = groups.count; groups.append((key, directory, [source.message.id])) }
        }
        var entries: [MailExportLayoutEntry] = [], volumes: [MailExportLayoutGroup] = []
        if options.format == .mbox {
            for group in groups {
                try Task.checkCancellation()
                let prefix = try names.volumeBase(options.labels.volumeBase, directory: group.directory, maximumParts: group.ids.count)
                let volume = MailExportLayoutGroup(id: group.id, directory: group.directory, messageIDs: group.ids, volumeBase: prefix)
                volumes.append(volume)
                if let first = group.ids.first {
                    entries.append(.init(id: first, title: review.source(first)?.message.subject ?? "", components: try volume.path(part: 1)))
                }
            }
        } else {
            for source in review.sources {
                try Task.checkCancellation()
                let message = source.message
                let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? options.labels.untitled : message.subject
                let date = message.date.map { day.string(from: $0) } ?? options.labels.undated
                let sender = message.fromName.isEmpty ? message.fromAddress : message.fromName
                let base: String
                switch options.naming {
                case .subject: base = subject
                case .dateSubject: base = date + " - " + subject
                case .dateSenderSubject: base = [date, sender, subject].filter { !$0.isEmpty }.joined(separator: " - ")
                }
                let directory = sourceDirectories[message.id] ?? []
                let file = try names.file(base, directory: directory, suffix: options.format == .bundle ? "mail" : options.format.rawValue)
                entries.append(.init(id: message.id, title: subject, components: directory + [file] + (options.format == .bundle ? ["index.html"] : [])))
            }
        }
        return .init(reviewID: review.id, options: options, directoryName: MailExportDestination.safeName(options.directoryName), isDirectory: isDirectory,
            entries: entries, groups: volumes, byID: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }))
    }
}

/// Logical owners, rather than display names, prevent two accounts or folders
/// with equal or canonically equivalent names from being merged in an export.
private struct ExportNames {
    private var directories: [String: [String]] = [:]
    private var used: [String: Set<String>] = ["": [MailExportDestination.nameKey("export-report.json"), MailExportDestination.nameKey("index.html")]]
    private var nextConflict: [String: Int] = [:]
    private func key(_ directory: [String]) -> String { directory.map(MailExportDestination.nameKey).joined(separator: "/") }
    mutating func directory(owner: String, parent: [String], name: String) throws -> [String] {
        let identity = key(parent) + "\u{1F}" + owner
        if let value = directories[identity] { return value }
        let component = try allocate(name, directory: parent, suffix: nil)
        let path = parent + [component]; directories[identity] = path
        return path
    }
    mutating func file(_ name: String, directory: [String], suffix: String) throws -> String {
        try allocate(name, directory: directory, suffix: suffix)
    }
    private mutating func allocate(_ name: String, directory: [String], suffix: String?) throws -> String {
        let base = MailExportDestination.safeName(name), parent = key(directory)
        let extensionPart = suffix.map { "." + $0 } ?? ""
        let first = Self.prefix(base, bytes: 160 - extensionPart.utf8.count) + extensionPart
        if used[parent, default: []].insert(MailExportDestination.nameKey(first)).inserted { return first }
        var number = nextConflict[parent] ?? 2
        while true {
            try Task.checkCancellation()
            let tail = " (\(number))" + extensionPart
            let candidate = Self.prefix(base, bytes: max(1, 160 - tail.utf8.count)) + tail
            let normalized = MailExportDestination.nameKey(candidate)
            if used[parent, default: []].insert(normalized).inserted { nextConflict[parent] = number + 1; return candidate }
            number += 1
        }
    }
    func volumeBase(_ value: String, directory: [String], maximumParts: Int) throws -> String {
        var blocked = Set<String>()
        for name in used[key(directory)] ?? [] where name.hasSuffix(".mbox") {
            let stem = String(name.dropLast(5))
            guard let dash = stem.lastIndex(of: "-") else { continue }
            let digits = String(stem[stem.index(after: dash)...])
            guard let part = Int(digits), part > 0, part <= maximumParts,
                  String(repeating: "0", count: max(0, 4 - String(part).count)) + String(part) == digits else { continue }
            blocked.insert(String(stem[..<dash]))
        }
        let base = MailExportDestination.safeName(value)
        var number = 1
        while true {
            try Task.checkCancellation()
            let tail = number == 1 ? "" : " (\(number))"
            let candidate = Self.prefix(base, bytes: 160 - tail.utf8.count) + tail
            if !blocked.contains(MailExportDestination.nameKey(candidate)) { return candidate }
            number += 1
        }
    }
    private static func prefix(_ value: String, bytes: Int) -> String {
        var result = "", size = 0
        for character in value {
            let count = String(character).utf8.count
            guard size + count <= bytes else { break }
            result.append(character); size += count
        }
        return result.isEmpty ? "mail" : result
    }
}
