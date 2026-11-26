import CryptoKit
import Foundation
import GRDB

/// Task history is written in the same transaction as its conversation. It has no
/// foreign key to a message: retry/edit may replace that message's current value.
public final class ProductTaskRunStore: Sendable {
    public static let didChange = Notification.Name("agroom.product.taskRunsChanged")
    private let queue: DatabaseQueue
    static let maximumRecordBytes = 16 * 1024 * 1024
    static let backupColumns = ["id", "sessionID", "messageID", "workspaceID", "mode", "title", "preview", "status", "startedAt", "finishedAt", "payload"]
    public init(databaseQueue: DatabaseQueue) { queue = databaseQueue }

    static func createSchema(_ db: Database) throws {
        try db.create(table: "product_task_runs", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("sessionID", .text).notNull()
            table.column("messageID", .text).notNull()
            table.column("workspaceID", .text)
            table.column("mode", .text).notNull()
            table.column("title", .text).notNull()
            table.column("preview", .text).notNull()
            table.column("status", .text).notNull()
            table.column("startedAt", .datetime).notNull()
            table.column("finishedAt", .datetime)
            table.column("payload", .blob).notNull()
        }
        try db.create(index: "product_task_runs_started", on: "product_task_runs", columns: ["startedAt", "id"], ifNotExists: true)
        try db.create(index: "product_task_runs_session", on: "product_task_runs", columns: ["sessionID", "messageID"], ifNotExists: true)
        try db.create(index: "product_task_runs_status", on: "product_task_runs", columns: ["status", "startedAt"], ifNotExists: true)
    }

    public func run(id: UUID) async throws -> ProductTaskRun? {
        try await queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM product_task_runs WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return try Self.decode(data)
        }
    }

    public func summaries(group: ProductTaskGroup? = nil, search: String = "", limit: Int = 50,
                          before: ProductTaskRunSummary? = nil, includeHidden: Bool = false) async throws -> [ProductTaskRunSummary] {
        try await queue.read { db in
            var predicates = [includeHidden ? "1" : "COALESCE(s.isHidden, 0) = 0"]
            var arguments: [DatabaseValue] = []
            if let group {
                let statuses = [TaskRunStatus.running, .waitingForConfirmation, .waitingForInput, .succeeded, .incomplete, .failed, .cancelled, .recoveryRequired].filter { $0.taskGroup == group }
                predicates.append("r.status IN (" + Array(repeating: "?", count: statuses.count).joined(separator: ",") + ")")
                arguments += statuses.map { $0.rawValue.databaseValue }
            }
            if !search.isEmpty {
                predicates.append("(instr(lower(r.title), lower(?)) > 0 OR instr(lower(r.preview), lower(?)) > 0)")
                arguments += [search.databaseValue, search.databaseValue]
            }
            if let before {
                predicates.append("(r.startedAt < ? OR (r.startedAt = ? AND r.id < ?))")
                arguments += [before.startedAt.databaseValue, before.startedAt.databaseValue, before.id.uuidString.databaseValue]
            }
            arguments.append(min(200, max(1, limit)).databaseValue)
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.id, r.sessionID, r.messageID, r.workspaceID, r.mode, r.title, r.preview,
                       r.status, r.startedAt, r.finishedAt, COALESCE(s.isHidden, 0) AS sessionHidden
                FROM product_task_runs r LEFT JOIN chat_sessions s ON r.sessionID = s.id
                WHERE \(predicates.joined(separator: " AND ")) ORDER BY r.startedAt DESC, r.id DESC LIMIT ?
                """, arguments: StatementArguments(arguments))
            return try rows.map { row in
                guard let id = UUID(uuidString: row["id"]), let session = UUID(uuidString: row["sessionID"]),
                      let message = UUID(uuidString: row["messageID"]), let mode = ChatMode(rawValue: row["mode"]),
                      let status = TaskRunStatus(rawValue: row["status"]) else { throw ProductTaskHistoryError.invalidRecord }
                return .init(id: id, sessionID: session, messageID: message, workspaceID: row["workspaceID"], mode: mode,
                    title: row["title"], preview: row["preview"], startedAt: row["startedAt"], finishedAt: row["finishedAt"],
                    status: status, sessionHidden: row["sessionHidden"])
            }
        }
    }

    static func decode(_ data: Data) throws -> ProductTaskRun {
        guard data.count <= maximumRecordBytes else { throw ProductTaskHistoryError.invalidRecord }
        let run = try JSONDecoder().decode(ProductTaskRun.self, from: data)
        guard run.startedAt.timeIntervalSince1970.isFinite, run.updatedAt.timeIntervalSince1970.isFinite,
              run.finishedAt?.timeIntervalSince1970.isFinite != false,
              run.resourceContext?.isValid != false else { throw ProductTaskHistoryError.invalidRecord }
        return run
    }

    /// Legacy migration streams message rows, so long conversations do not become
    /// another unbounded in-memory chat copy. Corrupt rows stay in their repair flow.
    static func backfill(_ db: Database) throws {
        let sessions = try Row.fetchAll(db, sql: "SELECT id, workspaceId, mode, messagesJSON FROM chat_sessions")
        let hasMessageTable = try db.tableExists("chat_messages")
        for session in sessions {
            guard let id = UUID(uuidString: session["id"]) else { continue }
            let mode = ChatMode(rawValue: session["mode"] ?? "") ?? .chat
            var prompt = ""
            let legacy: String = session["messagesJSON"]
            if legacy.count > 2, let messages = try? JSONDecoder().decode([ChatMessage].self, from: Data(legacy.utf8)) {
                for message in messages {
                    if message.role == .user { prompt = message.content }
                    else { try capture(message, sessionID: id, workspaceID: session["workspaceId"], mode: mode, prompt: prompt, in: db, metrics: false) }
                }
            }
            guard hasMessageTable else { continue }
            let rows = try Row.fetchCursor(db, sql: "SELECT seq, payload FROM chat_messages WHERE sessionId = ? ORDER BY seq", arguments: [id.uuidString])
            prompt = ""
            while let row = try rows.next() {
                let payload: String = row["payload"]
                guard let message = try? JSONDecoder().decode(ChatMessage.self, from: Data(payload.utf8)) else { continue }
                if message.role == .user { prompt = message.content }
                else { try capture(message, sessionID: id, workspaceID: session["workspaceId"], mode: mode, prompt: prompt, in: db, metrics: false) }
            }
        }
    }

    static func capture(_ message: ChatMessage, sessionID: UUID, workspaceID: String?, mode: ChatMode,
                        prompt: String, in db: Database, metrics: Bool = true) throws {
        guard try db.tableExists("product_task_runs"), message.role != .user, message.sourceTaskRunID == nil else { return }
        let records = snapshots(message, sessionID: sessionID, workspaceID: workspaceID, mode: mode, prompt: prompt)
        for var run in records {
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM product_task_runs WHERE id=?", arguments: [run.id.uuidString]) {
                let previous = try decode(data)
                guard previous.sessionID == sessionID, previous.messageID == message.id else { throw ProductTaskHistoryError.identityConflict }
                // Late progress and selecting an old variation cannot regress a receipt.
                if previous.status.isTerminal && !run.status.isTerminal { continue }
                run.workspaceID = previous.workspaceID
                run.startedAt = previous.startedAt
                run.mode = previous.mode
                run.resourceContext = previous.resourceContext ?? run.resourceContext
                run.prompt = previous.prompt
                run.finishedAt = run.status.isTerminal ? (previous.finishedAt ?? run.finishedAt) : nil
                run.updatedAt = previous.updatedAt
                if run == previous { continue }
                run.updatedAt = Date()
            }
            try write(run, in: db)
            if run.status == .succeeded {
                try ProductPreferencesService.hideFirstTaskGuidance(in: db)
            }
            if metrics && !run.isLegacy { try recordMetrics(run, in: db) }
        }
    }

    static func snapshots(_ message: ChatMessage, sessionID: UUID, workspaceID: String?, mode: ChatMode, prompt: String) -> [ProductTaskRun] {
        guard message.role != .user, message.sourceTaskRunID == nil else { return [] }
        let variations = message.variations ?? []
        var result = variations.enumerated().compactMap { index, variation -> ProductTaskRun? in
            guard variation.sourceTaskRunID == nil,
                  variation.taskRun != nil || variation.runStatus != nil || !variation.content.isEmpty || !(variation.trace ?? []).isEmpty else { return nil }
            return makeRun(message: message, variation: variation, index: index, sessionID: sessionID, workspaceID: workspaceID, mode: mode, prompt: variation.question)
        }
        if message.taskRun != nil || !message.content.isEmpty || !(message.trace ?? []).isEmpty || message.runStatus != nil {
            let current = makeRun(message: message, variation: nil, index: variations.isEmpty ? 0 : message.activeVariationIndex,
                sessionID: sessionID, workspaceID: workspaceID, mode: mode, prompt: prompt)
            if let index = result.firstIndex(where: { $0.id == current.id }) { result[index] = current }
            else { result.append(current) }
        }
        return result
    }

    private static func makeRun(message: ChatMessage, variation: AnswerVariation?, index: Int, sessionID: UUID,
                                workspaceID: String?, mode: ChatMode, prompt: String) -> ProductTaskRun {
        let identity = variation?.taskRun ?? (variation == nil ? message.taskRun : nil)
        let answer = variation?.content ?? message.content
        let trace = variation?.trace ?? (variation == nil ? message.trace : nil) ?? []
        let status = variation?.runStatus ?? (variation == nil ? message.runStatus : nil) ?? (message.role == .error ? .failed : .succeeded)
        let clippedTrace = trace.suffix(256).map { entry in
            DispatcherTraceEntry(toolName: entry.toolName, argumentsPreview: entry.argumentsPreview, resultPreview: entry.resultPreview,
                argumentsFull: entry.argumentsFull.map { String($0.prefix(2048)) }, resultFull: entry.resultFull.map { String($0.prefix(2048)) },
                artifact: entry.artifact, artifacts: entry.producedArtifacts, citations: entry.citations, duration: entry.duration, succeeded: entry.succeeded, inferReferences: false)
        }
        var paths = Set<String>()
        let artifacts = trace.flatMap(\.allArtifacts).filter { paths.insert($0.id).inserted }
        return ProductTaskRun(id: identity?.id ?? legacyID(sessionID: sessionID, messageID: message.id, index: index),
            sessionID: sessionID, messageID: message.id, workspaceID: workspaceID, mode: mode,
            startedAt: identity?.startedAt ?? message.timestamp, updatedAt: Date(), finishedAt: status.isTerminal && identity != nil ? Date() : nil,
            status: status, prompt: String(prompt.prefix(65_536)), answer: String(answer.prefix(131_072)), trace: clippedTrace,
            artifacts: artifacts, completion: variation?.completion ?? (variation == nil ? message.completion : nil),
            inputTokens: variation?.inputTokens ?? (variation == nil ? message.inputTokens : nil),
            outputTokens: variation?.outputTokens ?? (variation == nil ? message.outputTokens : nil),
            contentTruncated: prompt.count > 65_536 || answer.count > 131_072 || trace.count > 256
                || trace.contains(where: { ($0.argumentsFull?.count ?? 0) > 2048 || ($0.resultFull?.count ?? 0) > 2048 }),
            toolCount: trace.count, isLegacy: identity == nil,
            resourceContext: variation?.contextReport?.resourceContext ?? (variation == nil ? message.contextReport?.resourceContext : nil))
    }

    static func legacyID(sessionID: UUID, messageID: UUID, index: Int) -> UUID {
        let hex = SHA256.hash(data: Data("chat-task:\(sessionID):\(messageID):\(index)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let groups = [8, 4, 4, 4, 12]
        var cursor = hex.startIndex
        let value = groups.map { count -> String in
            let end = hex.index(cursor, offsetBy: count)
            defer { cursor = end }
            return String(hex[cursor..<end])
        }.joined(separator: "-")
        return UUID(uuidString: value)!
    }

    public static func displayedRunID(for message: ChatMessage, in sessionID: UUID) -> UUID {
        message.sourceTaskRunID ?? message.taskRun?.id ?? legacyID(sessionID: sessionID, messageID: message.id,
            index: message.variations?.isEmpty == false ? message.activeVariationIndex : 0)
    }

    static func write(_ run: ProductTaskRun, in db: Database) throws {
        let data = try JSONEncoder().encode(run)
        guard data.count <= maximumRecordBytes else { throw ProductTaskHistoryError.invalidRecord }
        try db.execute(sql: """
            INSERT INTO product_task_runs (id, sessionID, messageID, workspaceID, mode, title, preview, status, startedAt, finishedAt, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET workspaceID=excluded.workspaceID, title=excluded.title, preview=excluded.preview,
              status=excluded.status, finishedAt=excluded.finishedAt, payload=excluded.payload
            """, arguments: [run.id.uuidString, run.sessionID.uuidString, run.messageID.uuidString, run.workspaceID, run.mode.rawValue,
                String(run.prompt.prefix(120)), String(run.answer.prefix(512)), run.status.rawValue, run.startedAt, run.finishedAt, data])
    }

    /// Rebuild the projection when importing a backup from before independent
    /// task history existed. Explicit archived runs win over derived answers.
    static func augmentBackup(_ backup: SpaceDatabaseBackup?, sessions: [ChatSession], sourceSpace: String) throws -> (SpaceDatabaseBackup, Int) {
        var result = backup ?? SpaceDatabaseBackup(space: sourceSpace, tables: [])
        var table = result.tables.first { $0.name == "product_task_runs" }
            ?? SpaceTableBackup(name: "product_task_runs", columns: backupColumns, primaryKey: ["id"], rows: [])
        guard table.columns == backupColumns else { throw ProductTaskHistoryError.invalidRecord }
        var ids = Set(table.rows.compactMap { $0.first?.string })
        var inserted = 0
        for session in sessions {
            var prompt = ""
            for message in session.messages {
                if message.role == .user { prompt = message.content; continue }
                for run in snapshots(message, sessionID: session.id, workspaceID: session.workspaceId, mode: session.mode, prompt: prompt) {
                    guard ids.insert(run.id.uuidString).inserted else { continue }
                    let data = try JSONEncoder().encode(run)
                    guard data.count <= maximumRecordBytes else { throw ProductTaskHistoryError.invalidRecord }
                    table.rows.append([
                        .text(run.id.uuidString), .text(run.sessionID.uuidString), .text(run.messageID.uuidString), run.workspaceID.map(SpaceBackupValue.text) ?? .null,
                        .text(run.mode.rawValue), .text(String(run.prompt.prefix(120))), .text(String(run.answer.prefix(512))), .text(run.status.rawValue),
                        try SpaceBackupValue(run.startedAt.databaseValue), try run.finishedAt.map { try SpaceBackupValue($0.databaseValue) } ?? .null, .blob(data)
                    ])
                    inserted += 1
                }
            }
        }
        if let index = result.tables.firstIndex(where: { $0.name == table.name }) { result.tables[index] = table }
        else { result.tables.append(table) }
        return (result, inserted)
    }

    private static func recordMetrics(_ run: ProductTaskRun, in db: Database) throws {
        guard try db.tableExists("product_events") else { return }
        if let since = try ProductPreferencesService.metricsSince(in: db), run.startedAt < since { return }
        var kinds: [ProductEventKind] = [.taskStarted]
        if run.status == .succeeded { kinds.append(.taskCompleted) }
        if !run.artifacts.isEmpty { kinds.append(.artifactProduced) }
        for kind in kinds {
            try db.execute(sql: "INSERT OR IGNORE INTO product_events(id, kind, taskID, elapsedSeconds, createdAt) VALUES (?, ?, ?, NULL, ?)",
                arguments: ["task:\(run.id):\(kind.rawValue)", kind.rawValue, run.id.uuidString, kind == .taskStarted ? run.startedAt : Date()])
        }
    }

    static func precedingPrompt(_ db: Database, sessionID: UUID, before sequence: Int) throws -> String {
        guard try db.tableExists("chat_messages") else { return "" }
        let rows = try Row.fetchCursor(db, sql: "SELECT payload FROM chat_messages WHERE sessionId=? AND seq<? ORDER BY seq DESC", arguments: [sessionID.uuidString, sequence])
        while let row = try rows.next() {
            let payload: String = row["payload"]
            guard let message = try? JSONDecoder().decode(ChatMessage.self, from: Data(payload.utf8)) else { continue }
            if message.role == .user { return message.content }
        }
        return ""
    }
}
