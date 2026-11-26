import Foundation
import GRDB

/// Durable receipts belong to the same space database as the work that produced them.
/// JobCenter keeps only a small indicator cache; this table is paged by the task center.
public struct ProductJobRunStore: Sendable {
    private let queue: DatabaseQueue
    public let space: AppSpace
    var storageIdentity: String { queue.maintenanceKey }
    static let maximumRecordBytes = 2 * 1024 * 1024
    static let hostID = UUID().uuidString

    public init(databaseQueue: DatabaseQueue, space: AppSpace) { queue = databaseQueue; self.space = space }

    static func createSchema(_ db: Database) throws {
        try db.create(table: "product_job_runs", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("preview", .text).notNull()
            t.column("status", .text).notNull()
            t.column("startedAt", .datetime).notNull()
            t.column("finishedAt", .datetime)
            t.column("origin", .text)
            t.column("hostID", .text)
            t.column("payload", .blob).notNull()
        }
        try db.create(index: "product_job_runs_started", on: "product_job_runs", columns: ["startedAt", "id"], ifNotExists: true)
        try db.create(index: "product_job_runs_status", on: "product_job_runs", columns: ["status", "startedAt"], ifNotExists: true)
    }

    /// Called by JobCenter's serial history owner, outside its state lock.
    func saveCompleted(_ entries: [BackgroundJob]) throws {
        let values = try entries.filter { $0.space == space && $0.state.isFinished }.map(Self.bounded)
        try ResourceMaintenance.withAccess(queue.maintenanceKey) {
            try queue.write { db in
                for value in values { try Self.save(value, db: db) }
            }
        }
    }

    func recordStarted(_ entry: BackgroundJob) async throws {
        guard entry.space == space else { throw ProductTaskHistoryError.invalidRecord }
        let value = try Self.bounded(entry)
        try await queue.maintenanceWrite { try Self.save(value, db: $0) }
    }

    private static func save(_ value: BackgroundJob, db: Database) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumRecordBytes else { throw ProductTaskHistoryError.invalidRecord }
        try db.execute(sql: """
            INSERT INTO product_job_runs(id,title,preview,status,startedAt,finishedAt,origin,hostID,payload) VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, preview=excluded.preview, status=excluded.status,
                finishedAt=excluded.finishedAt, origin=excluded.origin, hostID=excluded.hostID, payload=excluded.payload
            WHERE product_job_runs.status IN ('queued','running','awaitingSave')
            """, arguments: [value.id.uuidString, value.name, String((value.errorText ?? value.resultText ?? "").prefix(512)),
                value.state.rawValue, value.submittedAt, value.finishedAt, value.origin, hostID, data])
    }

    func clear() throws {
        try ResourceMaintenance.withAccess(queue.maintenanceKey) {
            try queue.write {
                try $0.execute(sql: "DELETE FROM product_job_runs WHERE status NOT IN ('queued','running','awaitingSave') OR hostID IS NULL OR hostID<>?", arguments: [Self.hostID])
            }
        }
    }

    public func run(id: UUID) async throws -> BackgroundJob? {
        try await queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM product_job_runs WHERE id=?", arguments: [id.uuidString]) else { return nil }
            var value = try Self.decode(data)
            guard value.space == space, value.id == id else { throw ProductTaskHistoryError.invalidRecord }
            if !value.state.isFinished { value.state = .interrupted }
            return value
        }
    }

    /// Acknowledge an archived interruption without changing the work or inventing an end time.
    public func acknowledgeInterruption(id: UUID) async throws -> BackgroundJob {
        let job = try await queue.maintenanceWrite { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT status, hostID, payload FROM product_job_runs WHERE id=?",
                arguments: [id.uuidString]) else { throw ProductTaskHistoryError.invalidRecord }
            var job = try Self.decode(row["payload"])
            let status: String = row["status"]
            let hostID: String? = row["hostID"]
            guard job.space == space, job.id == id, job.state.rawValue == status else {
                throw ProductTaskHistoryError.invalidRecord
            }
            if job.state == .interruptionAcknowledged { return job }
            guard job.state == .interrupted || (!job.state.isFinished && hostID != Self.hostID) else {
                throw ProductTaskHistoryError.invalidRecord
            }
            job.state = .interruptionAcknowledged
            let data = try JSONEncoder().encode(job)
            guard data.count <= Self.maximumRecordBytes else { throw ProductTaskHistoryError.invalidRecord }
            try db.execute(sql: "UPDATE product_job_runs SET status=?, payload=? WHERE id=?",
                arguments: [job.state.rawValue, data, id.uuidString])
            guard db.changesCount == 1 else { throw ProductTaskHistoryError.invalidRecord }
            return job
        }
        await MainActor.run { NotificationCenter.default.post(name: ProductTaskCenterStore.didChange, object: nil) }
        return job
    }

    static func decode(_ data: Data) throws -> BackgroundJob {
        guard data.count <= maximumRecordBytes else { throw ProductTaskHistoryError.invalidRecord }
        let value = try JSONDecoder().decode(BackgroundJob.self, from: data)
        guard value.space != nil, value.submittedAt.timeIntervalSince1970.isFinite,
              value.finishedAt?.timeIntervalSince1970.isFinite != false else { throw ProductTaskHistoryError.invalidRecord }
        return value
    }

    private static func bounded(_ job: BackgroundJob) throws -> BackgroundJob {
        guard job.submittedAt.timeIntervalSince1970.isFinite, job.finishedAt?.timeIntervalSince1970.isFinite != false else {
            throw ProductTaskHistoryError.invalidRecord
        }
        var value = BackgroundJob(id: job.id, name: String(job.name.prefix(240)), kind: String(job.kind.prefix(120)),
            space: job.space, origin: job.origin.map { String($0.prefix(80)) }, submittedAt: job.submittedAt)
        value.state = job.state; value.finishedAt = job.finishedAt
        value.resultText = job.resultText.map { String($0.prefix(131_072)) }
        value.errorText = job.errorText.map { String($0.prefix(16_384)) }
        value.resultPath = job.resultPath.map { String($0.prefix(4096)) }
        value.historyTruncated = job.historyTruncated == true || value.resultText != job.resultText || value.errorText != job.errorText
        return value
    }
}
