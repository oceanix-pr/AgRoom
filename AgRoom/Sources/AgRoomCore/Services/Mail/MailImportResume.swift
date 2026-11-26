import CryptoKit
import Foundation
import GRDB

public struct MailImportRecordLocator: Codable, Sendable {
    public let fileSource: String
    public let location: MailMboxRecordLocation?
}

/// Contains relative provenance and fixed destinations, never external URLs or
/// access grants. Reopening a batch requires a freshly selected source session.
public struct MailImportResumeManifest: Codable, Sendable {
    struct Item: Codable, Sendable {
        let id: UUID
        let source: String
        let identity: MailImportIdentity
        let variant: MailMboxVariant?
        let locator: MailImportRecordLocator?
    }
    let account: MailAccount
    let items: [Item]
    let destinations: [String: [MailImportMappingReview.Node]]
    init(preview: MailImportIndexedPreview, review: MailImportMappingReview) {
        account = review.account; destinations = review.destinations
        items = preview.candidates.map { .init(id: $0.id, source: $0.source, identity: $0.identity, variant: $0.sourceVariant, locator: $0.locator) }
    }
}

public struct MailImportResumeReview: Identifiable, Sendable {
    public enum Status: String, Sendable { case matched, missing, changed, ambiguous, finished }
    public struct Item: Identifiable, Sendable {
        public let id: UUID
        public let source: String
        public let status: Status
    }
    public let id = UUID()
    public let items: [Item]
    public var resumableCount: Int { items.filter { $0.status == .matched }.count }
    public var canResume: Bool { resumableCount > 0 }
    let batch: MailImportBatch
    let fingerprint: Data
    let originQueue: DatabaseQueue
    let preview: MailImportIndexedPreview
    let candidates: [MailImportMetadata]
    let sourceIDs: [UUID]
    let mapping: MailImportMappingReview
}

extension MailService {
    public func previewImportResume(batchID: UUID, archiveID: UUID, source: MailImportIndexedPreview) async throws -> MailImportResumeReview {
        let queue = databaseQueue
        return try await queue.read { db in
            let batch = try Self.loadImportResumeBatch(batchID, archiveID: archiveID, db: db)
            guard let manifest = batch.resumeManifest else { throw MailImportError.changed }
            try Self.validateImportManifest(manifest, batch: batch)
            let results = Dictionary(uniqueKeysWithValues: batch.results.map { ($0.id, $0) })
            let available = Dictionary(grouping: source.candidates, by: { Data($0.source.utf8) })
            var rows: [MailImportResumeReview.Item] = [], candidates: [MailImportMetadata] = [], sourceIDs: [UUID] = []
            for saved in manifest.items {
                try Task.checkCancellation()
                guard let result = results[saved.id] else { throw MailImportError.changed }
                let status: MailImportResumeReview.Status
                if result.status == .imported || result.status == .duplicate { status = .finished }
                else {
                    let matches = available[Data(saved.source.utf8)] ?? []
                    let exact = matches.filter { Data($0.folder.utf8) == Data(saved.identity.folder.utf8)
                        && $0.sha256 == saved.identity.sha256 && $0.byteCount == saved.identity.byteCount && $0.sourceVariant == saved.variant }
                    if exact.count == 1, let current = exact.first {
                        status = .matched; sourceIDs.append(current.id)
                        var item = MailImportMetadata(id: saved.id, source: saved.source, folder: saved.identity.folder, envelope: current.envelope,
                            sha256: saved.identity.sha256, byteCount: saved.identity.byteCount, sourceVariant: saved.variant)
                        item.locator = current.locator; candidates.append(item)
                    } else if exact.count > 1 { status = .ambiguous }
                    else { status = matches.isEmpty ? .missing : .changed }
                }
                rows.append(.init(id: saved.id, source: saved.source, status: status))
            }
            let summaries = MailImportMappingSource.summarize(candidates)
            let mapping = MailImportMappingReview(account: manifest.account, isNewArchive: false,
                rows: try summaries.map { summary in
                    guard let nodes = manifest.destinations[summary.id], !nodes.isEmpty else { throw MailImportError.changed }
                    return .init(source: summary, path: nodes.map(\.folder.name))
                }, originQueue: queue, sourceSessionID: source.access.id, systemFolders: [],
                identities: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.identity) }), destinations: manifest.destinations)
            let materialized = Set(batch.results.flatMap { $0.destinationFolderIDs ?? [] })
            for summary in summaries { _ = try Self.validateImportMapping(mapping, source: summary.source, materialized: materialized, db: db) }
            return .init(items: rows, batch: batch, fingerprint: try Self.importResumeFingerprint(batch), originQueue: queue,
                preview: source, candidates: candidates, sourceIDs: sourceIDs, mapping: mapping)
        }
    }

    public func resumeImport(_ review: MailImportResumeReview,
                             progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> MailImportBatch {
        guard review.originQueue === databaseQueue, review.canResume else { throw MailImportError.changed }
        let wanted = Set(review.sourceIDs)
        try await review.preview.access.validateSelection(review.preview.candidates.filter { wanted.contains($0.id) })
        return try await performImportMessages(review.candidates, failures: [], archiveID: review.batch.accountID, mappingReview: review.mapping,
            resume: review, read: { position in
                let current = try await review.preview.access.original(review.sourceIDs[position])
                let saved = review.candidates[position]
                return .init(id: saved.id, source: saved.source, folder: saved.folder, envelope: current.envelope, data: current.data,
                    sha256: current.sha256, sourceVariant: current.sourceVariant)
            }, progress: progress)
    }

    static func validateImportResume(_ review: MailImportResumeReview, db: Database) throws {
        let current = try loadImportResumeBatch(review.batch.id, archiveID: review.batch.accountID, db: db)
        guard try importResumeFingerprint(current) == review.fingerprint else { throw MailImportError.changed }
    }

    static func requireImportRun(_ id: UUID, token: UUID?, db: Database) throws {
        if let data = try Data.fetchOne(db, sql: "SELECT payload FROM mail_import_batches WHERE id=?", arguments: [id.uuidString]) {
            guard try JSONDecoder().decode(MailImportBatch.self, from: data).runToken == token else { throw MailImportError.changed }
        }
    }

    private static func loadImportResumeBatch(_ id: UUID, archiveID: UUID, db: Database) throws -> MailImportBatch {
        guard try MailAccountRow.fetchOne(db, key: archiveID.uuidString)?.sourceKind == MailAccountSource.localArchive.rawValue,
              let data = try Data.fetchOne(db, sql: "SELECT payload FROM mail_import_batches WHERE id=? AND accountID=?", arguments: [id.uuidString, archiveID.uuidString]),
              try !importWasUndone(id, db: db) else { throw MailImportError.changed }
        var batch = try JSONDecoder().decode(MailImportBatch.self, from: data)
        guard batch.id == id, batch.accountID == archiveID, batch.undo == nil,
              batch.results.count <= MailImportReader.maximumItems,
              Set(batch.results.map(\.id)).count == batch.results.count else { throw MailImportError.changed }
        let entries = try Data.fetchAll(db, sql: "SELECT payload FROM mail_import_entries WHERE batchID=?", arguments: [id.uuidString])
            .map { try JSONDecoder().decode(MailImportResult.self, from: $0) }
        let completed = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        batch.results = batch.results.map { completed[$0.id] ?? $0 }
        return batch
    }

    private static func importResumeFingerprint(_ batch: MailImportBatch) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(batch)))
    }

    static func validateImportManifest(_ manifest: MailImportResumeManifest, batch: MailImportBatch) throws {
        guard manifest.account.id == batch.accountID, manifest.account.isLocalArchive,
              [manifest.account.imapHost, manifest.account.smtpHost, manifest.account.username, manifest.account.emailAddress].allSatisfy(\.isEmpty),
              manifest.items.count <= MailImportReader.maximumItems,
              Set(manifest.items.map(\.id)).count == manifest.items.count,
              manifest.destinations.count <= MailImportReader.maximumItems else { throw MailImportError.invalidMessage }
        let results = Dictionary(uniqueKeysWithValues: batch.results.map { ($0.id, $0) })
        for item in manifest.items {
            try validateImportIdentity(item.identity)
            guard let result = results[item.id], result.originalIdentity == item.identity,
                  Data(result.source.utf8) == Data(item.source.utf8), result.sourceVariant == item.variant,
                  let chain = manifest.destinations[MailImportMappingSource.key(item.identity.folder)], !chain.isEmpty, chain.count <= 128,
                  chain.allSatisfy({ $0.folder.accountId == batch.accountID }), chain.last?.folder.isContainer == false else { throw MailImportError.invalidMessage }
            if let locator = item.locator {
                let components = locator.fileSource.split(separator: "/", omittingEmptySubsequences: false)
                guard !components.isEmpty, locator.fileSource.utf8.count <= 16_384,
                      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw MailImportError.invalidMessage }
                if let location = locator.location {
                    guard location.envelopeOffset >= 0, location.offset > location.envelopeOffset, location.byteCount > 0,
                          location.byteCount <= rawMessageByteLimit * 2, location.variant != .automatic else { throw MailImportError.invalidMessage }
                }
            }
        }
    }
}
