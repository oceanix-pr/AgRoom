import CryptoKit
import Foundation
import GRDB

public enum MailImportFolderRule: Hashable, Sendable {
    case preserve, inbox, existing(UUID?), path(String)
}

public struct MailImportArchiveDraft: Sendable {
    public let name: String
    public let inbox: String
    public let trash: String
    public let archive: String
    public init(name: String, inbox: String, trash: String, archive: String) {
        self.name = name; self.inbox = inbox; self.trash = trash; self.archive = archive
    }
}

public struct MailImportMappingSource: Identifiable, Sendable {
    public let id: String
    public let source: String
    public let count: Int
    public static func key(_ source: String) -> String { Data(source.utf8).base64EncodedString() }
    public static func summarize(_ preview: MailImportPreview) -> [Self] {
        summarize(preview.candidates.map(\.metadata))
    }
    public static func summarize(_ candidates: [MailImportMetadata]) -> [Self] {
        Dictionary(grouping: candidates, by: { key($0.folder) }).map { key, items in
            .init(id: key, source: items[0].folder, count: items.count)
        }.sorted { $0.source == $1.source ? $0.id < $1.id : $0.source.localizedStandardCompare($1.source) == .orderedAscending }
    }
}

public struct MailImportMappingRow: Identifiable, Sendable {
    public var id: String { source.id }
    public let source: MailImportMappingSource
    public let path: [String]
    public var displayPath: String { path.joined(separator: " / ") }
}

public struct MailImportFolderChoice: Identifiable, Sendable {
    public let id: UUID
    public let path: [String]
    public var displayPath: String { path.joined(separator: " / ") }
}

public struct MailImportMappingTargets: Sendable {
    public let choices: [MailImportFolderChoice]
    public let unavailable: Int
}

/// A read-only review of the selected originals and their destinations. Newly
/// proposed accounts and folders are not inserted until import is confirmed.
public struct MailImportMappingReview: Identifiable, Sendable {
    public let id = UUID()
    public let account: MailAccount
    public let isNewArchive: Bool
    public let rows: [MailImportMappingRow]
    let originQueue: DatabaseQueue
    let sourceSessionID: UUID?
    let systemFolders: [MailFolder]
    let identities: [UUID: MailImportIdentity]
    let destinations: [String: [Node]]
    struct Node: Codable, Sendable { let folder: MailFolder; let mayCreate: Bool }
}

extension MailService {
    public func importMappingTargets(archiveID: UUID) async throws -> MailImportMappingTargets {
        try await databaseQueue.read { db in
            guard try MailAccountRow.fetchOne(db, key: archiveID.uuidString)?.sourceKind == MailAccountSource.localArchive.rawValue else { throw MailImportError.localOnly }
            let folders = try MailFolderRow.filter(Column("accountId") == archiveID.uuidString).fetchAll(db).compactMap { $0.toFolder() }
            var choices: [MailImportFolderChoice] = [], unavailable = 0
            for folder in folders where !folder.isContainer {
                do { choices.append(.init(id: folder.id, path: try Self.importMappingChain(folder, folders: folders).map(\.name))) }
                catch MailImportError.mappingInvalid { unavailable += 1 }
            }
            return .init(choices: choices.sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }, unavailable: unavailable)
        }
    }

    public func reviewImportMapping(_ preview: MailImportPreview, archiveID: UUID?, draft: MailImportArchiveDraft,
                                    rules: [String: MailImportFolderRule]) async throws -> MailImportMappingReview {
        for candidate in preview.candidates {
            try Task.checkCancellation()
            guard SHA256.hash(data: candidate.data).map({ String(format: "%02x", $0) }).joined() == candidate.sha256 else { throw MailImportError.changed }
        }
        return try await reviewImportMapping(preview.candidates.map(\.metadata), archiveID: archiveID, draft: draft, rules: rules, sourceSessionID: nil)
    }

    public func reviewImportMapping(_ preview: MailImportIndexedPreview, archiveID: UUID?, draft: MailImportArchiveDraft,
                                    rules: [String: MailImportFolderRule]) async throws -> MailImportMappingReview {
        try await reviewImportMapping(preview.candidates, archiveID: archiveID, draft: draft, rules: rules, sourceSessionID: preview.access.id)
    }

    private func reviewImportMapping(_ candidates: [MailImportMetadata], archiveID: UUID?, draft: MailImportArchiveDraft,
                                    rules: [String: MailImportFolderRule], sourceSessionID: UUID?) async throws -> MailImportMappingReview {
        let queue = databaseQueue
        return try await queue.read { db in
            try Task.checkCancellation()
            let account: MailAccount, system: [MailFolder], folders: [MailFolder]
            if let archiveID {
                guard let value = try MailAccountRow.fetchOne(db, key: archiveID.uuidString)?.toAccount(), value.isLocalArchive else { throw MailImportError.localOnly }
                account = value; system = []
                folders = try MailFolderRow.filter(Column("accountId") == archiveID.uuidString).fetchAll(db).compactMap { $0.toFolder() }
            } else {
                let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.utf8.count <= 240, name.rangeOfCharacter(from: .controlCharacters) == nil,
                      [draft.inbox, draft.trash, draft.archive].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 240 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else { throw MailImportError.mappingInvalid }
                account = MailAccount(displayName: name, emailAddress: "", imapHost: "", smtpHost: "", username: "", sourceKind: .localArchive)
                system = [("INBOX", draft.inbox, MailFolderRole.inbox), ("Trash", draft.trash, .trash), ("Archive", draft.archive, .archive)].map {
                    MailFolder(accountId: account.id, path: $0.0, name: $0.1, role: $0.2)
                }
                folders = system
            }
            let known = Dictionary(grouping: folders, by: { Data($0.path.utf8) })
            var planned: [Data: MailImportMappingReview.Node] = [:]
            var rows: [MailImportMappingRow] = [], destinations: [String: [MailImportMappingReview.Node]] = [:]
            let sources = MailImportMappingSource.summarize(candidates)
            var identities: [UUID: MailImportIdentity] = [:]
            for candidate in candidates {
                guard identities[candidate.id] == nil else { throw MailImportError.mappingInvalid }
                let identity = candidate.identity
                try Self.validateImportIdentity(identity)
                identities[candidate.id] = identity
            }
            for source in sources {
                try Task.checkCancellation()
                let chosen = rules[source.id] ?? .preserve
                let rule: MailImportFolderRule = chosen == .preserve && source.source.isEmpty ? .inbox : chosen
                let nodes: [MailImportMappingReview.Node]
                switch rule {
                case .inbox:
                    let inboxes = folders.filter { $0.role == .inbox && !$0.isContainer }
                    guard inboxes.count == 1, let inbox = inboxes.first else { throw MailImportError.mappingInvalid }
                    nodes = try Self.importMappingChain(inbox, folders: folders).map { .init(folder: $0, mayCreate: false) }
                case .existing(let id):
                    guard archiveID != nil, let id, let folder = folders.first(where: { $0.id == id }), !folder.isContainer else { throw MailImportError.mappingInvalid }
                    nodes = try Self.importMappingChain(folder, folders: folders).map { .init(folder: $0, mayCreate: false) }
                case .preserve, .path:
                    let value: String
                    if case .path(let path) = rule { value = path.trimmingCharacters(in: .whitespacesAndNewlines) }
                    else { value = source.source }
                    let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                    guard !components.isEmpty, components.count <= 16, components.allSatisfy({
                        !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 && !$0.contains("\0")
                    }) else { throw MailImportError.mappingInvalid }
                    if case .path = rule, components.contains(where: { $0.rangeOfCharacter(from: .controlCharacters) != nil }) { throw MailImportError.mappingInvalid }
                    var chain: [MailImportMappingReview.Node] = [], parent: String?
                    for index in components.indices {
                        let path = "import/" + components[...index].joined(separator: "/"), key = Data(path.utf8)
                        let node: MailImportMappingReview.Node
                        if let cached = planned[key] { node = cached }
                        else if let matches = known[key] {
                            guard matches.count == 1, let folder = matches.first,
                                  folder.parentPath.map({ Data($0.utf8) }) == parent.map({ Data($0.utf8) }),
                                  Data(folder.name.utf8) == Data(components[index].utf8) else { throw MailImportError.mappingInvalid }
                            node = .init(folder: folder, mayCreate: false)
                        } else {
                            node = .init(folder: .init(accountId: account.id, path: path, name: components[index], parentPath: parent, delimiter: "/"), mayCreate: true)
                        }
                        guard node.folder.parentPath.map({ Data($0.utf8) }) == parent.map({ Data($0.utf8) }) else { throw MailImportError.mappingInvalid }
                        planned[key] = node; chain.append(node); parent = node.folder.path
                    }
                    guard chain.last?.folder.isContainer == false else { throw MailImportError.mappingInvalid }
                    nodes = chain
                }
                destinations[source.id] = nodes
                rows.append(.init(source: source, path: nodes.map(\.folder.name)))
            }
            return .init(account: account, isNewArchive: archiveID == nil, rows: rows, originQueue: queue, sourceSessionID: sourceSessionID,
                systemFolders: system, identities: identities, destinations: destinations)
        }
    }

    public func importMappedMessages(_ preview: MailImportPreview, review: MailImportMappingReview,
                                     progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> MailImportBatch {
        try validateImportMappingSelection(preview, review: review)
        return try await performImportMessages(preview, archiveID: review.account.id, mappingReview: review, progress: progress)
    }

    public func importMappedMessages(_ preview: MailImportIndexedPreview, review: MailImportMappingReview,
                                     progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> MailImportBatch {
        guard review.originQueue === databaseQueue, review.sourceSessionID == preview.access.id,
              !preview.candidates.isEmpty, review.identities.count == preview.candidates.count,
              Set(preview.candidates.map(\.id)).count == preview.candidates.count else { throw MailImportError.changed }
        for candidate in preview.candidates {
            guard let expected = review.identities[candidate.id], Data(expected.folder.utf8) == Data(candidate.folder.utf8),
                  expected.sha256 == candidate.sha256, expected.byteCount == candidate.byteCount else { throw MailImportError.changed }
        }
        try await preview.access.validateSelection(preview.candidates)
        return try await performImportMessages(preview.candidates, failures: preview.failures, archiveID: review.account.id, mappingReview: review,
            manifest: MailImportResumeManifest(preview: preview, review: review),
            read: { try await preview.access.original(preview.candidates[$0].id) }, progress: progress)
    }

    private func validateImportMappingSelection(_ preview: MailImportPreview, review: MailImportMappingReview) throws {
        guard review.originQueue === databaseQueue, review.sourceSessionID == nil, !preview.candidates.isEmpty,
              review.identities.count == preview.candidates.count, Set(preview.candidates.map(\.id)).count == preview.candidates.count else { throw MailImportError.changed }
        for candidate in preview.candidates {
            guard let expected = review.identities[candidate.id], Data(expected.folder.utf8) == Data(candidate.folder.utf8),
                  expected.sha256 == candidate.sha256, expected.byteCount == candidate.data.count,
                  SHA256.hash(data: candidate.data).map({ String(format: "%02x", $0) }).joined() == expected.sha256 else { throw MailImportError.changed }
        }
    }

    static func beginImportMapping(_ review: MailImportMappingReview, db: Database) throws -> Set<UUID> {
        if review.isNewArchive {
            guard try MailAccountRow.fetchOne(db, key: review.account.id.uuidString) == nil else { throw MailImportError.changed }
            var account = MailAccountRow(from: review.account); try account.insert(db)
            for folder in review.systemFolders { var row = MailFolderRow(from: folder); try row.insert(db) }
        }
        try validateImportMappingAccount(review, db: db)
        var visited = Set<UUID>(), materialized = Set<UUID>()
        for nodes in review.destinations.values {
            for node in nodes where visited.insert(node.folder.id).inserted {
                try validateImportMappingNode(node, db: db)
                if try MailFolderRow.fetchOne(db, key: node.folder.id.uuidString) != nil { materialized.insert(node.folder.id) }
            }
        }
        return materialized
    }

    static func validateImportMapping(_ review: MailImportMappingReview, source: String, materialized: Set<UUID>, db: Database) throws -> Set<UUID> {
        try validateImportMappingAccount(review, db: db)
        guard let nodes = review.destinations[MailImportMappingSource.key(source)] else { throw MailImportError.changed }
        var observed = Set<UUID>()
        for node in nodes {
            let exists = try MailFolderRow.fetchOne(db, key: node.folder.id.uuidString) != nil
            if materialized.contains(node.folder.id), !exists { throw MailImportError.changed }
            try validateImportMappingNode(node, db: db)
            if exists { observed.insert(node.folder.id) }
        }
        return observed
    }

    static func resolveImportMapping(_ review: MailImportMappingReview, source: String, materialized: Set<UUID>, db: Database) throws -> (folderID: UUID, created: Set<UUID>) {
        _ = try validateImportMapping(review, source: source, materialized: materialized, db: db)
        guard let nodes = review.destinations[MailImportMappingSource.key(source)], let target = nodes.last else { throw MailImportError.changed }
        var created = Set<UUID>()
        for node in nodes where node.mayCreate {
            if try MailFolderRow.fetchOne(db, key: node.folder.id.uuidString) == nil {
                var row = MailFolderRow(from: node.folder); try row.insert(db)
                created.insert(node.folder.id)
            }
        }
        return (target.folder.id, created)
    }

    private static func validateImportMappingAccount(_ review: MailImportMappingReview, db: Database) throws {
        guard let current = try MailAccountRow.fetchOne(db, key: review.account.id.uuidString)?.toAccount(),
              current.isLocalArchive, current.displayName == review.account.displayName else { throw MailImportError.changed }
    }

    private static func validateImportMappingNode(_ node: MailImportMappingReview.Node, db: Database) throws {
        let expected = node.folder
        if let actual = try MailFolderRow.fetchOne(db, key: expected.id.uuidString)?.toFolder() {
            guard actual.accountId == expected.accountId, Data(actual.path.utf8) == Data(expected.path.utf8),
                  actual.parentPath.map({ Data($0.utf8) }) == expected.parentPath.map({ Data($0.utf8) }),
                  Data(actual.name.utf8) == Data(expected.name.utf8), actual.role == expected.role, actual.isContainer == expected.isContainer else { throw MailImportError.changed }
        } else {
            guard node.mayCreate,
                  try MailFolderRow.filter(Column("accountId") == expected.accountId.uuidString).filter(Column("path") == expected.path).fetchCount(db) == 0 else { throw MailImportError.changed }
        }
    }

    private static func importMappingChain(_ folder: MailFolder, folders: [MailFolder]) throws -> [MailFolder] {
        var result = [folder], seen: Set<UUID> = [folder.id]
        while let parent = result.last?.parentPath {
            let matches = folders.filter { Data($0.path.utf8) == Data(parent.utf8) }
            guard result.count < 128, matches.count == 1, let value = matches.first,
                  value.accountId == folder.accountId, seen.insert(value.id).inserted else { throw MailImportError.mappingInvalid }
            result.append(value)
        }
        return Array(result.reversed())
    }
}
