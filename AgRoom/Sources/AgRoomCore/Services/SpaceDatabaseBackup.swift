import Foundation
import GRDB

/// Portable SQLite values, not SQL text or a database file supplied by an archive.
enum SpaceBackupValue: Codable, Sendable, Equatable {
    case null, integer(Int64), real(Double), text(String), blob(Data)
    case blobFile(SpaceBackupBlobReference)
    /// Transient comparison only. It is never accepted as persisted input.
    case blobFingerprint(sha256: String, byteCount: Int)

    static func == (lhs: Self, rhs: Self) -> Bool {
        func identity(_ value: Self) -> (String, Int)? {
            switch value {
            case .blobFile(let ref): return (ref.sha256, ref.byteCount)
            case .blobFingerprint(let hash, let bytes): return (hash, bytes)
            default: return nil
            }
        }
        if let a = identity(lhs), let b = identity(rhs) { return a.0 == b.0 && a.1 == b.1 }
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.integer(let a), .integer(let b)): return a == b
        case (.real(let a), .real(let b)): return a == b
        case (.text(let a), .text(let b)): return a == b
        case (.blob(let a), .blob(let b)): return a == b
        default: return false
        }
    }

    init(_ value: DatabaseValue) throws {
        switch value.storage {
        case .null: self = .null
        case .int64(let number): self = .integer(number)
        case .double(let number):
            guard number.isFinite else { throw BackupError.preflightFailed("Non-finite database value") }
            self = .real(number)
        case .string(let string): self = .text(string)
        case .blob(let data): self = .blob(data)
        }
    }

    func databaseValue(blobs: SpaceBackupBlobs? = nil) throws -> DatabaseValue {
        switch self {
        case .null: return .null
        case .integer(let value): return value.databaseValue
        case .real(let value): return value.databaseValue
        case .text(let value): return value.databaseValue
        case .blob(let value): return value.databaseValue
        case .blobFile(let ref):
            guard let blobs else { throw BackupError.preflightFailed("Database content files are unavailable") }
            return try blobs.read(ref).databaseValue
        case .blobFingerprint: throw BackupError.preflightFailed("A database fingerprint cannot be written")
        }
    }

    var string: String? { if case .text(let value) = self { value } else { nil } }
    var isNull: Bool { self == .null }
}

struct SpaceTableBackup: Codable, Sendable, Equatable {
    let name: String
    let columns: [String]
    let primaryKey: [String]
    var rows: [[SpaceBackupValue]]
}

struct SpaceDatabaseBackup: Codable, Sendable, Equatable {
    let space: String
    var tables: [SpaceTableBackup]
    var recordCount: Int { tables.reduce(0) { $0 + $1.rows.count } }
    func count(_ table: String) -> Int { tables.first { $0.name == table }?.rows.count ?? 0 }
}

/// The private recovery image includes dependent operational tables too, so triggers
/// cannot silently destroy data during rollback. It never enters the portable package.
struct SpaceDatabaseRestorePlan: Codable, Sendable, Equatable {
    let before: SpaceDatabaseBackup
    let incoming: SpaceDatabaseBackup
    var after: SpaceDatabaseBackup?
    let preservedDeliveryDrafts: Int
}

/// Exactly one bound space queue. Incoming data can use only known business tables
/// and current columns; it cannot introduce schema, triggers, SQL, or credentials.
struct SpaceDatabaseBackupStore: Sendable {
    let queue: DatabaseQueue
    let space: String
    var blobs: SpaceBackupBlobs? = nil
    var noteCipher: NoteContentCipher? = nil

    static let portableTables = [
        "notes", "note_media", "note_media_chunks", "note_visual_frames", "note_voiceprints", "note_capture_reports", "agents", "knowledge_bases", "knowledge_folders", "knowledge_items",
        "knowledge_revisions", "knowledge_sources", "knowledge_import_batches", "knowledge_import_tasks",
        "knowledge_graph_settings", "knowledge_graph_documents", "knowledge_graph_relations",
        "knowledge_graph_decisions", "knowledge_graph_similarity_documents", "knowledge_graph_similarity",
        "mail_accounts", "mail_folders", "mail_messages", "mail_bodies", "mail_attachments", "mail_drafts", "mail_raw_messages", "mail_agent_draft_receipts",
        "mail_sync_coverage", "mail_pending_flags", "mail_import_batches", "mail_import_origins", "mail_import_entries", "mail_import_undos", "mail_saved_searches", "mail_folder_preferences", "mail_folder_mutations", "mail_server_drafts", "scheduled_tasks", "scheduled_runs",
        "mcp_servers", "mysql_connections", "product_preferences", "product_events", "workspace_projects", "team_tasks", "team_discussions", "product_task_runs", "product_job_runs", "product_task_center_cleared", "artifact_versions",
        "execution_goals", "goal_attempts", "goal_events", "memory_extraction_progress"
    ]
    private static let coreTables: Set<String> = [
        "chat_sessions", "chat_messages", "chat_message_quarantine", "memories", "memory_terms", "skills", "provider_usage", "chat_restore_tokens"
    ]
    static let maximumBytes = 256 * 1024 * 1024
    private static let maximumRows = 500_000
    private static let controlledHistory: Set<String> = ["product_task_runs", "product_job_runs", "product_task_center_cleared", "artifact_versions"]
    private static let observational: Set<String> = Set(["product_events", "knowledge_graph_similarity", "knowledge_graph_similarity_documents"]).union(controlledHistory)
    private static func stable(_ value: SpaceDatabaseBackup) -> SpaceDatabaseBackup {
        SpaceDatabaseBackup(space: value.space, tables: value.tables.filter { !observational.contains($0.name) })
    }

    func export() async throws -> SpaceDatabaseBackup {
        let noteCipher = try self.noteCipher ?? NoteContentCipher.database(queue, space: space)
        return try await queue.read { db in
            let tables = try Self.portableTables.filter { try db.tableExists($0) }
            var result = try Self.snapshot(db, tables: tables, space: space, blobs: blobs)
            result = try Self.sanitized(result, for: space, pathMappings: [:], workspaceMappings: [:], exporting: true, blobs: blobs, noteCipher: noteCipher)
            guard try Self.encoder.encode(result).count <= Self.maximumBytes else { throw BackupError.preflightFailed("Space database section exceeds its size limit") }
            return result
        }
    }

    /// Inspection validates incoming data without copying the destination's full
    /// before-image. Only an actual restore creates durable recovery material.
    func inspect(_ backup: SpaceDatabaseBackup, sourceSpace: String) async throws -> Int {
        guard backup.space == sourceSpace else { throw BackupError.preflightFailed("Space database ownership does not match the manifest") }
        let noteCipher = try self.noteCipher ?? NoteContentCipher.database(queue, space: space)
        return try await queue.read { db in
            try Self.validate(backup, db: db, portableOnly: true, blobs: blobs)
            let incoming = try Self.sanitized(backup, for: space, pathMappings: [:], workspaceMappings: [:], exporting: false, blobs: blobs, noteCipher: noteCipher)
            guard let table = incoming.tables.first(where: { $0.name == "mail_drafts" }) else { return 0 }
            return try table.rows.reduce(0) { count, values in
                guard let row = try Self.find(db, table: table, values: values) else { return count }
                let state: String? = row["deliveryState"], deliveredAt: DatabaseValue = row["deliveredAt"], deliveredID: DatabaseValue = row["deliveredMessageId"]
                return count + ((state != nil && state != "none") || deliveredAt != .null || deliveredID != .null ? 1 : 0)
            }
        }
    }

    /// Upgrade old private JSON images in place before comparing them with new
    /// file-backed snapshots. References stay relative when a restore point moves.
    func normalized(_ plan: SpaceDatabaseRestorePlan) throws -> SpaceDatabaseRestorePlan {
        try blobs?.checkCancellation()
        for image in [plan.before, plan.incoming] + (plan.after.map { [$0] } ?? []) {
            for table in image.tables {
                for row in table.rows {
                    guard !row.contains(where: { if case .blobFingerprint = $0 { return true }; return false }) else {
                        throw BackupError.preflightFailed("Invalid persisted database fingerprint")
                    }
                }
            }
        }
        guard blobs != nil else { return plan }
        try blobs?.prime(plan.before.blobReferences.union(plan.incoming.blobReferences).union(plan.after?.blobReferences ?? []))
        return SpaceDatabaseRestorePlan(before: try Self.externalized(plan.before, blobs: blobs, privateSnapshot: true),
            incoming: try Self.externalized(plan.incoming, blobs: blobs, privateSnapshot: false),
            after: try plan.after.map { try Self.externalized($0, blobs: blobs, privateSnapshot: true) },
            preservedDeliveryDrafts: plan.preservedDeliveryDrafts)
    }

    private func verifyContentFiles(_ plan: SpaceDatabaseRestorePlan) throws {
        let refs = plan.before.blobReferences.union(plan.incoming.blobReferences).union(plan.after?.blobReferences ?? [])
        guard !refs.isEmpty else { return }
        guard let blobs else { throw BackupError.preflightFailed("Recovery content files are unavailable") }
        for ref in refs { try blobs.verify(ref) }
    }

    func plan(_ backup: SpaceDatabaseBackup, sourceSpace: String, pathMappings: [String: String] = [:], workspaceMappings: [String: String] = [:]) async throws -> SpaceDatabaseRestorePlan {
        guard backup.space == sourceSpace else { throw BackupError.preflightFailed("Space database ownership does not match the manifest") }
        let noteCipher = try self.noteCipher ?? NoteContentCipher.database(queue, space: space)
        try blobs?.prime(backup.blobReferences)
        return try await queue.read { db in
            try Self.validate(backup, db: db, portableOnly: true, blobs: blobs)
            let before = try Self.snapshot(db, tables: Self.recoveryTableNames(db), space: space, blobs: blobs, privateSnapshot: true)
            var incoming = try Self.sanitized(backup, for: space, pathMappings: pathMappings, workspaceMappings: workspaceMappings, exporting: false, blobs: blobs, noteCipher: noteCipher)
            incoming = try Self.externalized(incoming, blobs: blobs, privateSnapshot: false)
            var preserved = 0
            // An incoming receipt must not erase evidence of newer server writes.
            if let index = incoming.tables.firstIndex(where: { $0.name == "mail_server_drafts" }) {
                let table = incoming.tables[index]
                incoming.tables[index].rows = try table.rows.filter { try Self.find(db, table: table, values: $0) == nil }
            }
            if let index = incoming.tables.firstIndex(where: { $0.name == "mail_drafts" }) {
                let table = incoming.tables[index]
                incoming.tables[index].rows = try table.rows.filter { values in
                    guard let current = try Self.find(db, table: table, values: values) else { return true }
                    let state: String? = current["deliveryState"]
                    let deliveredAt: DatabaseValue = current["deliveredAt"]
                    let deliveredID: DatabaseValue = current["deliveredMessageId"]
                    let protected = (state != nil && state != "none") || deliveredAt != .null || deliveredID != .null
                    if protected { preserved += 1 }
                    return !protected
                }
            }
            return SpaceDatabaseRestorePlan(before: before, incoming: incoming, after: nil, preservedDeliveryDrafts: preserved)
        }
    }

    /// The observed after-image is journaled before SQLite commits. A crash before
    /// commit leaves the before-image; a crash after commit has an exact after-image.
    func apply(_ plan: SpaceDatabaseRestorePlan,
               willCommit: @escaping @Sendable (SpaceDatabaseRestorePlan) throws -> Void) async throws -> SpaceDatabaseRestorePlan {
        let plan = try normalized(plan)
        try verifyContentFiles(plan)
        return try await queue.maintenanceWrite { db in
            let current = try Self.snapshot(db, tables: plan.before.tables.map(\.name), space: space, blobs: blobs, privateSnapshot: true, fingerprintOnly: true)
            guard current == plan.before else { throw MaintenanceError.busy }
            try Self.validate(plan.incoming, db: db, portableOnly: true, blobs: blobs)
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for table in try Self.ordered(plan.incoming.tables, db: db) {
                for values in table.rows {
                    try Task.checkCancellation(); try blobs?.checkCancellation()
                    try Self.upsert(db, table: table, values: values, blobs: blobs)
                }
            }
            // Merge restore must also pause target-only background definitions:
            // they could otherwise process newly imported private material.
            if try db.tableExists("scheduled_tasks") {
                try db.execute(sql: "UPDATE scheduled_tasks SET enabled = 0, nextFireAt = NULL")
            }
            if let targetSpace = AppSpace(rawValue: space) { try GoalStore.pauseForRestore(db, space: targetSpace) }
            if try db.tableExists("knowledge_graph_settings") {
                for row in try Row.fetchAll(db, sql: "SELECT id, json FROM knowledge_graph_settings") {
                    let id: Int = row["id"], json: String = row["json"]
                    var value = try JSONDecoder().decode(KnowledgeGraphSettings.self, from: Data(json.utf8))
                    value.extractionEnabled = false; value.needsRetry = false
                    try db.execute(sql: "UPDATE knowledge_graph_settings SET json = ? WHERE id = ?", arguments: [String(decoding: try Self.encoder.encode(value), as: UTF8.self), id])
                }
            }
            try ProductPreferencesService.backfillFirstTaskGuidance(db)
            var observed = plan
            observed.after = try Self.snapshot(db, tables: plan.before.tables.map(\.name), space: space, blobs: blobs, privateSnapshot: true)
            try willCommit(observed)
            return observed
        }
    }

    func verify(_ plan: SpaceDatabaseRestorePlan) async throws {
        let plan = try normalized(plan)
        try verifyContentFiles(plan)
        guard let after = plan.after else { throw BackupError.preflightFailed("Missing committed database receipt") }
        let current = try await queue.read { try Self.snapshot($0, tables: after.tables.map(\.name), space: space, blobs: blobs, privateSnapshot: true, fingerprintOnly: true) }
        guard Self.stable(current) == Self.stable(after), Self.taskRowsMatch(current, expected: after, scope: Self.historyScope(plan)) else {
            throw BackupError.preflightFailed("Restored database verification failed")
        }
    }

    func rollback(_ plan: SpaceDatabaseRestorePlan) async throws {
        let plan = try normalized(plan)
        try verifyContentFiles(plan)
        try await queue.maintenanceWrite { db in
            try Self.validate(plan.before, db: db, portableOnly: false, blobs: blobs)
            let current = try Self.snapshot(db, tables: plan.before.tables.map(\.name), space: space, blobs: blobs, privateSnapshot: true, fingerprintOnly: true)
            let wasRestored = Self.stable(current) != Self.stable(plan.before)
            if wasRestored {
                guard let after = plan.after, Self.stable(current) == Self.stable(after) else { throw MaintenanceError.busy }
            }
            let historyScope = Self.historyScope(plan)
            let taskRowsChanged = !Self.taskRowsMatch(current, expected: plan.before, scope: historyScope)
            if taskRowsChanged {
                guard let after = plan.after, Self.taskRowsMatch(current, expected: after, scope: historyScope) else { throw MaintenanceError.busy }
            }
            // Events are immutable observations. Preserve later local activity and
            // user clears; undo removes only unchanged receipts imported here.
            if let incoming = plan.incoming.tables.first(where: { $0.name == "product_events" }) {
                let before = plan.before.tables.first { $0.name == "product_events" }
                let oldRows = Set(try (before?.rows ?? []).map { try Self.encoder.encode($0) })
                for values in incoming.rows where !(try oldRows.contains(Self.encoder.encode(values))) {
                    if let row = try Self.find(db, table: incoming, values: values),
                       try incoming.columns.map({ try SpaceBackupValue(row[$0] as DatabaseValue) }) == values {
                        let indices = incoming.primaryKey.compactMap { incoming.columns.firstIndex(of: $0) }
                        try db.execute(sql: "DELETE FROM product_events WHERE " + incoming.primaryKey.map { Self.quote($0) + " IS ?" }.joined(separator: " AND "),
                            arguments: StatementArguments(try indices.map { try values[$0].databaseValue() }))
                    }
                }
            }
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            if wasRestored {
                let tables = try Self.ordered(plan.before.tables.filter { $0.name != "product_events" && !Self.controlledHistory.contains($0.name) }, db: db)
                for table in tables.reversed() { try db.execute(sql: "DELETE FROM \(Self.quote(table.name))") }
                // Account-delete triggers create tombstones during the clear itself.
                if tables.contains(where: { $0.name == "mail_deleted_accounts" }) {
                    try db.execute(sql: "DELETE FROM mail_deleted_accounts")
                }
                for table in tables {
                    for row in table.rows { try Self.upsert(db, table: table, values: row, blobs: blobs) }
                }
            }
            // Include rows affected by restore triggers, not just archive IDs.
            // Restore them after business tables whose own triggers can clear history.
            for (name, ids) in historyScope {
                let original = plan.before.tables.first { $0.name == name }
                let originalRows = Self.taskRows(plan.before, table: name)
                for id in ids.sorted() {
                    if let values = originalRows[id], let original { try Self.upsert(db, table: original, values: values, blobs: blobs) }
                    else { try db.execute(sql: "DELETE FROM \(Self.quote(name)) WHERE id=?", arguments: [id]) }
                }
            }
            let restored = try Self.snapshot(db, tables: plan.before.tables.map(\.name), space: space, blobs: blobs, privateSnapshot: true, fingerprintOnly: true)
            guard Self.stable(restored) == Self.stable(plan.before), Self.taskRowsMatch(restored, expected: plan.before, scope: historyScope) else {
                throw BackupError.preflightFailed("Database rollback verification failed")
            }
        }
    }

    private static func taskRows(_ snapshot: SpaceDatabaseBackup, table name: String) -> [String: [SpaceBackupValue]] {
        guard let table = snapshot.tables.first(where: { $0.name == name }), let idIndex = table.columns.firstIndex(of: "id") else { return [:] }
        return Dictionary(table.rows.compactMap { row in row[idIndex].string.map { ($0, row) } }, uniquingKeysWith: { _, last in last })
    }

    private static func historyScope(_ plan: SpaceDatabaseRestorePlan) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for name in controlledHistory {
            let before = taskRows(plan.before, table: name)
            let after = plan.after.map { taskRows($0, table: name) } ?? before
            var ids = Set(taskRows(plan.incoming, table: name).keys)
            ids.formUnion(Set(before.keys).union(after.keys).filter { before[$0] != after[$0] })
            if !ids.isEmpty { result[name] = ids }
        }
        return result
    }

    private static func taskRowsMatch(_ current: SpaceDatabaseBackup, expected: SpaceDatabaseBackup, scope: [String: Set<String>]) -> Bool {
        for (name, ids) in scope {
            let now = taskRows(current, table: name), wanted = taskRows(expected, table: name)
            if !ids.allSatisfy({ now[$0] == wanted[$0] }) { return false }
        }
        return true
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private static func recoveryTableNames(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' AND sql NOT LIKE 'CREATE VIRTUAL%' ORDER BY name")
            .filter { !coreTables.contains($0) && $0 != "mail_thread_links" }
    }

    private static func externalized(_ backup: SpaceDatabaseBackup, blobs: SpaceBackupBlobs?, privateSnapshot: Bool) throws -> SpaceDatabaseBackup {
        guard blobs != nil else { return backup }
        var copy = backup
        for tableIndex in copy.tables.indices {
            let table = copy.tables[tableIndex]
            for rowIndex in table.rows.indices {
                copy.tables[tableIndex].rows[rowIndex] = try table.rows[rowIndex].enumerated().map { index, value in
                    try externalized(value, table: table.name, column: table.columns[index], isKey: table.primaryKey.contains(table.columns[index]),
                        blobs: blobs, privateSnapshot: privateSnapshot)
                }
            }
        }
        return copy
    }

    private static func externalized(_ value: SpaceBackupValue, table: String, column: String, isKey: Bool,
                                     blobs: SpaceBackupBlobs?, privateSnapshot: Bool, fingerprintOnly: Bool = false) throws -> SpaceBackupValue {
        guard let blobs, !isKey, case .blob(let data) = value, !data.isEmpty,
              (["note_media", "note_media_chunks", "note_visual_frames"].contains(table) && column == "contents") || (table == "artifact_versions" && ["contents", "beforeContents"].contains(column)) || (privateSnapshot && data.count >= SpaceBackupBlobs.privateInlineLimit) else { return value }
        try blobs.checkCancellation()
        if fingerprintOnly { return .blobFingerprint(sha256: SpaceBackupBlobs.digest(data), byteCount: data.count) }
        return .blobFile(try blobs.put(data))
    }

    private static func snapshot(_ db: Database, tables: [String], space: String,
                                 blobs: SpaceBackupBlobs?, privateSnapshot: Bool = false, fingerprintOnly: Bool = false) throws -> SpaceDatabaseBackup {
        try blobs?.checkCancellation()
        var result: [SpaceTableBackup] = []
        var count = 0, bytes = 0
        let limit = privateSnapshot ? BackupService.maxExtractedByteCount : maximumBytes
        for name in tables.sorted() {
            try blobs?.checkCancellation()
            let columns = try db.columns(in: name).map(\.name)
            let key = try db.primaryKey(name).columns
            guard !key.isEmpty else { throw BackupError.preflightFailed("A database table has no stable identity") }
            let noteFilter: String
            if !privateSnapshot, name == "notes" { noteFilter = " WHERE NOT EXISTS (SELECT 1 FROM note_import_staging WHERE noteID = notes.id)" }
            else if !privateSnapshot, name == "note_media" { noteFilter = " WHERE isReady = 1 AND NOT EXISTS (SELECT 1 FROM note_import_staging WHERE noteID = note_media.noteID)" }
            else if !privateSnapshot, ["note_media_chunks","note_visual_frames"].contains(name) {
                noteFilter = " WHERE EXISTS (SELECT 1 FROM note_media m WHERE m.id = \(quote(name)).mediaID AND m.isReady = 1 AND NOT EXISTS (SELECT 1 FROM note_import_staging s WHERE s.noteID = m.noteID))"
            } else if !privateSnapshot, name == "note_capture_reports" { noteFilter = " WHERE NOT EXISTS (SELECT 1 FROM note_import_staging WHERE noteID = note_capture_reports.noteID)" }
            else { noteFilter = "" }
            let sql = "SELECT \(columns.map(quote).joined(separator: ",")) FROM \(quote(name))\(noteFilter) ORDER BY \(key.map(quote).joined(separator: ","))"
            let cursor = try Row.fetchCursor(db, sql: sql)
            var rows: [[SpaceBackupValue]] = []
            while let row = try cursor.next() {
                try Task.checkCancellation(); try blobs?.checkCancellation()
                count += 1
                guard count <= maximumRows else { throw BackupError.preflightFailed("Space database section has too many records") }
                let values = try columns.map { column in
                    try externalized(SpaceBackupValue(row[column] as DatabaseValue), table: name, column: column,
                        isKey: key.contains(column), blobs: blobs, privateSnapshot: privateSnapshot, fingerprintOnly: fingerprintOnly)
                }
                let encoded = try encoder.encode(values).count
                guard encoded <= limit - bytes else { throw BackupError.preflightFailed("Space database metadata exceeds its size limit") }
                bytes += encoded
                rows.append(values)
            }
            result.append(SpaceTableBackup(name: name, columns: columns, primaryKey: key, rows: rows))
        }
        return SpaceDatabaseBackup(space: space, tables: result)
    }

    private static func validate(_ backup: SpaceDatabaseBackup, db: Database, portableOnly: Bool, blobs: SpaceBackupBlobs?) throws {
        try blobs?.checkCancellation()
        guard backup.recordCount <= maximumRows, Set(backup.tables.map(\.name)).count == backup.tables.count else {
            throw BackupError.preflightFailed("Invalid database section inventory")
        }
        let allowed = portableOnly ? Set(portableTables) : Set(try recoveryTableNames(db))
        for table in backup.tables {
            guard allowed.contains(table.name), try db.tableExists(table.name), !table.columns.isEmpty,
                  Set(table.columns).count == table.columns.count,
                  Set(table.columns).isSubset(of: Set(try db.columns(in: table.name).map(\.name))),
                  table.primaryKey == (try db.primaryKey(table.name).columns),
                  table.primaryKey.allSatisfy(table.columns.contains) else {
                throw BackupError.preflightFailed("Unsupported database table or columns: \(table.name)")
            }
            let indexes = table.primaryKey.compactMap { table.columns.firstIndex(of: $0) }
            var identities = Set<Data>()
            for row in table.rows {
                try blobs?.checkCancellation()
                guard row.count == table.columns.count, indexes.allSatisfy({ !row[$0].isNull }),
                      identities.insert(try encoder.encode(indexes.map { row[$0] })).inserted,
                      row.allSatisfy({
                          if case .real(let value) = $0 { return value.isFinite }
                          if case .blobFingerprint = $0 { return false }
                          return true
                      }) else {
                    throw BackupError.preflightFailed("Invalid or duplicate database record: \(table.name)")
                }
                for (index, value) in row.enumerated() {
                    if case .blobFile(let reference) = value {
                        guard blobs != nil, !indexes.contains(index),
                              !portableOnly || (["note_media", "note_media_chunks", "note_visual_frames"].contains(table.name) && table.columns[index] == "contents") || (table.name == "artifact_versions" && ["contents", "beforeContents"].contains(table.columns[index])) else {
                            throw BackupError.preflightFailed("Unsupported database content reference")
                        }
                        try reference.validate()
                    }
                }
            }
        }
        if portableOnly { try NoteBackupMediaValidation.validate(backup,blobs: blobs) }
    }

    private static func ordered(_ tables: [SpaceTableBackup], db: Database) throws -> [SpaceTableBackup] {
        var remaining = tables.sorted { $0.name < $1.name }
        var output: [SpaceTableBackup] = []
        let names = Set(tables.map(\.name))
        while !remaining.isEmpty {
            let emitted = Set(output.map(\.name))
            let index = try remaining.firstIndex { table in
                let parents = Set(try db.foreignKeys(on: table.name).map(\.destinationTable)).intersection(names).subtracting([table.name])
                // Mail guard triggers are not declared foreign keys. Tombstones are
                // restored last, after valid accounts and dependent records exist.
                if table.name == "mail_deleted_accounts" { return remaining.count == 1 }
                if table.name.hasPrefix("mail_"), table.name != "mail_accounts", table.name != "mail_deleted_accounts",
                   names.contains("mail_accounts"), !emitted.contains("mail_accounts") { return false }
                if ["mail_bodies", "mail_attachments", "mail_pending_flags"].contains(table.name),
                   names.contains("mail_messages"), !emitted.contains("mail_messages") { return false }
                return parents.isSubset(of: emitted)
            }
            guard let index else { throw BackupError.preflightFailed("Unsupported cyclic database dependencies") }
            output.append(remaining.remove(at: index))
        }
        return output
    }

    private static func find(_ db: Database, table: SpaceTableBackup, values: [SpaceBackupValue]) throws -> Row? {
        let indices = table.primaryKey.compactMap { table.columns.firstIndex(of: $0) }
        let predicate = table.primaryKey.map { quote($0) + " IS ?" }.joined(separator: " AND ")
        return try Row.fetchOne(db, sql: "SELECT * FROM \(quote(table.name)) WHERE \(predicate)", arguments: StatementArguments(try indices.map { try values[$0].databaseValue() }))
    }

    private static func upsert(_ db: Database, table: SpaceTableBackup, values: [SpaceBackupValue], blobs: SpaceBackupBlobs?) throws {
        let columns = table.columns.map(quote).joined(separator: ",")
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        let fields = table.columns.filter { !table.primaryKey.contains($0) }
        let update = fields.isEmpty || table.name == "product_events" ? "NOTHING" : "UPDATE SET " + fields.map { quote($0) + "=excluded." + quote($0) }.joined(separator: ",")
        let sql = "INSERT INTO \(quote(table.name)) (\(columns)) VALUES (\(placeholders)) ON CONFLICT (\(table.primaryKey.map(quote).joined(separator: ","))) DO \(update)"
        try db.execute(sql: sql, arguments: StatementArguments(try values.map { try $0.databaseValue(blobs: blobs) }))
        if table.name == "note_media", !table.columns.contains("sourceRemoved"), let idIndex = table.columns.firstIndex(of: "id") {
            try db.execute(sql: "UPDATE note_media SET sourceRemoved = 0, isReady = 1, byteCount = NULL, sha256 = NULL WHERE id = ?",arguments: StatementArguments([try values[idIndex].databaseValue(blobs: blobs)]))
        }
    }

    private static func sanitized(_ backup: SpaceDatabaseBackup, for space: String,
                                  pathMappings: [String: String], workspaceMappings: [String: String], exporting: Bool,
                                  blobs: SpaceBackupBlobs?, noteCipher: NoteContentCipher = .plaintext) throws -> SpaceDatabaseBackup {
        var result = SpaceDatabaseBackup(space: space, tables: backup.tables)
        for tableIndex in result.tables.indices {
            let original = result.tables[tableIndex]
            if original.name == "mail_drafts", !original.columns.contains("bodyStylesData") {
                result.tables[tableIndex] = .init(name: original.name, columns: original.columns + ["bodyStylesData"], primaryKey: original.primaryKey, rows: original.rows.map { $0 + [.null] })
            }
            if original.name == "mail_bodies", !original.columns.contains("searchText") {
                result.tables[tableIndex] = .init(name: original.name, columns: original.columns + ["searchText"], primaryKey: original.primaryKey, rows: original.rows.map { $0 + [.null] })
            }
            if original.name == "mail_folder_preferences", !original.columns.contains("isHidden") {
                result.tables[tableIndex] = .init(name: original.name, columns: original.columns + ["isHidden"], primaryKey: original.primaryKey, rows: original.rows.map { $0 + [.integer(0)] })
            }
            let columns = result.tables[tableIndex].columns
            let name = result.tables[tableIndex].name
            if name == "mail_raw_messages" {
                for row in result.tables[tableIndex].rows {
                    guard let dataIndex = columns.firstIndex(of: "data"), let kindIndex = columns.firstIndex(of: "kind"),
                          let kind = row[kindIndex].string, MailRawKind(rawValue: kind) != nil,
                          let data = Data.fromDatabaseValue(try row[dataIndex].databaseValue(blobs: blobs)),
                          !data.isEmpty, data.count <= MailService.rawMessageByteLimit else {
                        throw BackupError.preflightFailed("Invalid raw mail record")
                    }
                }
            }
            if name == "mail_drafts", let index = columns.firstIndex(of: "attachmentsData") {
                for row in result.tables[tableIndex].rows where !row[index].isNull {
                    guard let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)),
                          data.count <= MailDraftAttachment.maximumSerializedBytes else {
                        throw BackupError.preflightFailed("Invalid draft attachments")
                    }
                    try MailDraftAttachment.validate(JSONDecoder().decode([MailDraftAttachment].self, from: data))
                }
            }
            for rowIndex in result.tables[tableIndex].rows.indices {
                try blobs?.checkCancellation()
                var row = result.tables[tableIndex].rows[rowIndex]
                func set(_ key: String, _ value: SpaceBackupValue) { if let index = columns.firstIndex(of: key) { row[index] = value } }
                func text(_ key: String) -> String? { columns.firstIndex(of: key).flatMap { row[$0].string } }
                if name == "mail_drafts", let index = columns.firstIndex(of: "bodyStylesData"), !row[index].isNull {
                    guard let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)),
                          let body = text("bodyText") else { throw MailFormattingError.invalid }
                    _ = try MailStyleSpan.decode(data, text: body)
                }
                let protectedNoteTable = ["notes", "note_capture_reports", "note_voiceprints"].contains(name)
                if protectedNoteTable, exporting, let index = columns.firstIndex(of: "contents"), let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)) {
                    row[index] = .blob(try noteCipher.open(data, table: name))
                }
                if name == "notes" {
                    guard let index = columns.firstIndex(of: "contents"),
                          let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)),
                          data.count <= NoteStore.maximumContentBytes + 128 else { throw NoteStoreError.tooLarge }
                    var note = try JSONDecoder().decode(WorkNote.self, from: data)
                    guard note.id.uuidString == text("id"), note.revision > 0,
                          !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          note.todos.count <= 1000, note.summaries.count <= 100 else { throw NoteStoreError.invalidContent }
                    if !exporting {
                        note.versionToken = UUID()
                        for index in note.todos.indices { note.todos[index].reminderID = nil }
                    }
                    set("contents", .blob(try encoder.encode(note)))
                    set("title", .text(note.title))
                    set("revision", .integer(Int64(note.revision)))
                    set("archived", .integer(note.archived ? 1 : 0))
                    set("pinned", .integer(note.pinned ? 1 : 0))
                    set("searchText", .text(note.searchText))
                } else if name == "note_capture_reports" {
                    guard let index = columns.firstIndex(of: "contents"), let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)), data.count <= 64 * 1024 else { throw NoteStoreError.invalidContent }
                    let report = try JSONDecoder().decode(NoteCaptureReport.self, from: data)
                    guard report.id.uuidString == text("id"), report.noteID.uuidString == text("noteID"), (0...2000).contains(report.fragments), report.issues.count <= 32 else { throw NoteStoreError.invalidContent }
                } else if name == "note_voiceprints" {
                    guard let index = columns.firstIndex(of: "contents"), let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)), data.count <= 64 * 1024 else { throw NoteStoreError.tooLarge }
                    let record = try JSONDecoder().decode(NoteVoiceprint.self, from: data)
                    guard record.id.uuidString == text("id"), record.name.count <= 200, !record.name.isEmpty, !NoteVoiceprintMath.normalize(record.embedding).isEmpty else { throw NoteStoreError.invalidContent }
                } else if name == "note_media" {
                    guard let index = columns.firstIndex(of: "contents"),
                          UUID(uuidString: text("id") ?? "") != nil,
                          UUID(uuidString: text("noteID") ?? "") != nil,
                          let name = text("name"), !name.isEmpty,
                          URL(fileURLWithPath: name).lastPathComponent == name else { throw NoteStoreError.invalidContent }
                    switch row[index] {
                    case .blobFile(let ref):
                        guard ref.byteCount > 0, ref.byteCount <= NoteStore.maximumMediaBytes else { throw NoteStoreError.tooLarge }
                    case .blob(let data):
                        guard (data.isEmpty && (columns.firstIndex(of: "sourceRemoved").map { row[$0] == .integer(1) } == true || columns.firstIndex(of: "byteCount").map { if case .integer(let count) = row[$0] { return count > 0 && count <= NoteStore.maximumFileBytes }; return false } == true)) || (!data.isEmpty && data.count <= NoteStore.maximumMediaBytes) else { throw NoteStoreError.tooLarge }
                    default: throw NoteStoreError.invalidContent
                    }
                } else if name == "mail_bodies" {
                    set("searchText", .text(MailService.searchableBody(text: text("textBody"), html: text("htmlBody"))))
                } else if name == "mail_server_drafts" {
                    guard let index = columns.firstIndex(of: "payload"),
                          let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)),
                          data.count <= MailService.serverDraftRecordByteLimit else { throw MailServerDraftError.capacity }
                    var record = try JSONDecoder().decode(MailServerDraftRecord.self, from: data)
                    try record.validate()
                    guard record.draftID.uuidString == text("draftID"), record.account.id.uuidString == text("accountID") else { throw MailServerDraftError.invalid }
                    if !exporting { record.needsReconciliation = true; record.revision = UUID(); set("payload", .blob(try encoder.encode(record))) }
                } else if name == "mail_folder_mutations" {
                    guard let index = columns.firstIndex(of: "payload"),
                          let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)), data.count <= MailService.folderMutationByteLimit else { throw MailFolderMutationError.changed }
                    let record = try JSONDecoder().decode(MailFolderMutationRecord.self, from: data)
                    try MailService.validateFolderMutationRecord(record)
                    guard text("id") == record.id.uuidString, text("accountID") == record.mutation.account.id.uuidString,
                          text("state") == record.state.rawValue else { throw MailFolderMutationError.changed }
                } else if name == "mail_folder_preferences" {
                    guard let id = text("folderID"), UUID(uuidString: id) != nil,
                          let favorite = columns.firstIndex(of: "isFavorite"),
                          row[favorite] == .integer(0) || row[favorite] == .integer(1),
                          let moved = columns.firstIndex(of: "lastMovedAt") else { throw MailSearchError.invalidFilter }
                    // Older backups omit visibility and receive the schema's visible default.
                    if let hidden = columns.firstIndex(of: "isHidden") {
                        guard row[hidden] == .integer(0) || row[hidden] == .integer(1) else { throw MailSearchError.invalidFilter }
                    }
                    if !row[moved].isNull {
                        guard let date = Date.fromDatabaseValue(try row[moved].databaseValue()), date.timeIntervalSince1970.isFinite else { throw MailSearchError.invalidFilter }
                    }
                } else if name == "mail_saved_searches" {
                    guard result.tables[tableIndex].rows.count <= 100, let index = columns.firstIndex(of: "payload"),
                          let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)), data.count <= 64 * 1024 else { throw MailSearchError.invalidFilter }
                    let saved = try JSONDecoder().decode(MailSavedSearch.self, from: data)
                    try MailService.validateSearchFilter(saved.filter)
                    guard saved.id.uuidString == text("id"), saved.name == text("name"), !saved.name.isEmpty,
                          saved.name.utf8.count <= 120, saved.name.rangeOfCharacter(from: .controlCharacters) == nil else { throw MailSearchError.invalidName }
                } else if name == "workspace_projects" {
                    guard let id = text("workspaceID"), UUID(uuidString: id) != nil,
                          let revision = text("revision"), UUID(uuidString: revision) != nil,
                          let index = columns.firstIndex(of: "configuration"), case .blob(let data) = row[index],
                          (try JSONDecoder().decode(WorkspaceProjectConfiguration.self, from: data)).isValid else {
                        throw WorkspaceProjectError.invalid
                    }
                    if !exporting { set("workspaceID", .text(workspaceMappings[id] ?? id)) }
                } else if name == "product_task_center_cleared" {
                    guard let id = text("id") else { throw ProductTaskHistoryError.invalidRecord }
                    let parts = id.split(separator: ":", omittingEmptySubsequences: false)
                    guard parts.count == 2, ProductTaskSource(rawValue: String(parts[0])) != nil,
                          let uuid = UUID(uuidString: String(parts[1])), uuid.uuidString == parts[1],
                          let index = columns.firstIndex(of: "clearedAt"),
                          let date = Date.fromDatabaseValue(try row[index].databaseValue()), date.timeIntervalSince1970.isFinite else {
                        throw ProductTaskHistoryError.invalidRecord
                    }
                } else if name == "product_task_runs" {
                    guard let index = columns.firstIndex(of: "payload"), case .blob(let data) = row[index] else { throw ProductTaskHistoryError.invalidRecord }
                    var run = try ProductTaskRunStore.decode(data)
                    guard run.id.uuidString == text("id"), run.sessionID.uuidString == text("sessionID"), run.messageID.uuidString == text("messageID") else {
                        throw ProductTaskHistoryError.invalidRecord
                    }
                    if !exporting {
                        if !run.status.isTerminal { run.status = .recoveryRequired; run.finishedAt = nil }
                        run.workspaceID = run.workspaceID.map { workspaceMappings[$0] ?? $0 }
                        if let target = AppSpace(rawValue: space) {
                            run.resourceContext = run.resourceContext?.rebinding(space: target, workspaceMappings: workspaceMappings)
                        }
                        func remap(_ artifact: TaskArtifact) -> TaskArtifact {
                            var copy = artifact; copy.path = pathMappings[copy.path] ?? copy.path
                            if copy.sourceSpace != nil { copy.sourceSpace = AppSpace(rawValue: space) }
                            return copy
                        }
                        run.artifacts = run.artifacts.map(remap)
                        run.trace = run.trace.map { entry in
                            DispatcherTraceEntry(toolName: entry.toolName, argumentsPreview: entry.argumentsPreview, resultPreview: entry.resultPreview,
                                argumentsFull: entry.argumentsFull, resultFull: entry.resultFull, artifact: entry.artifact.map(remap), artifacts: entry.producedArtifacts?.map(remap), citations: entry.citations,
                                duration: entry.duration, succeeded: entry.succeeded, inferReferences: false)
                        }
                    }
                    set("payload", .blob(try encoder.encode(run)))
                    set("status", .text(run.status.rawValue)); set("workspaceID", run.workspaceID.map(SpaceBackupValue.text) ?? .null)
                    set("finishedAt", try run.finishedAt.map { try SpaceBackupValue($0.databaseValue) } ?? .null)
                } else if name == "execution_goals" {
                    guard let index = columns.firstIndex(of: "payload"), case .blob(let data) = row[index],
                          let source = AppSpace(rawValue: backup.space), let target = AppSpace(rawValue: space) else { throw GoalError.invalid }
                    let old = try GoalStore.decode(data, space: source)
                    guard old.id.uuidString == text("id"), old.sessionID.uuidString == text("sessionID"),
                          old.workspaceID.uuidString == text("workspaceID"), old.status.rawValue == text("status") else { throw GoalError.invalid }
                    let goal = GoalStore.portable(old, space: target, workspaceMappings: workspaceMappings, importing: !exporting)
                    set("workspaceID", .text(goal.workspaceID.uuidString)); set("status", .text(goal.status.rawValue))
                    set("payload", .blob(try encoder.encode(goal)))
                } else if name == "goal_attempts" {
                    guard let index = columns.firstIndex(of: "payload"), case .blob(let data) = row[index], data.count <= GoalStore.maximumRecordBytes else { throw GoalError.invalid }
                    let attempt = try JSONDecoder().decode(GoalAttempt.self, from: data)
                    guard attempt.isValid, attempt.id.uuidString == text("id"), attempt.goalID.uuidString == text("goalID"),
                          attempt.sequence >= 1, attempt.receipt?.runID == nil || attempt.receipt?.runID == attempt.id else { throw GoalError.invalid }
                } else if name == "artifact_versions" {
                    guard let index = columns.firstIndex(of: "metadata"), case .blob(let data) = row[index],
                          let source = AppSpace(rawValue: backup.space), let target = AppSpace(rawValue: space) else { throw TaskArtifactError.unavailable }
                    var record = try TaskArtifactStore.decode(data, space: source)
                    guard record.id.uuidString == text("id"), record.artifact.path == text("path"), record.logicalPath == text("logicalPath"),
                          record.runID.uuidString == text("runID"), record.operationID == text("operationID"),
                          record.workspaceID == text("workspaceID"), record.sessionID?.uuidString == text("sessionID") else { throw TaskArtifactError.unavailable }
                    if let i = columns.firstIndex(of: "contents"), case .blobFile(let ref) = row[i] {
                        guard let blobs, record.artifact.contentRetained == true,
                              record.artifact.sha256 == ref.sha256, record.artifact.byteCount == ref.byteCount,
                              ref.byteCount <= TaskArtifactStore.maximumSnapshotBytes else { throw TaskArtifactError.changedFile }
                        try blobs.verify(ref)
                    } else {
                        let contents: Data?
                        if let i = columns.firstIndex(of: "contents") {
                            switch row[i] {
                            case .blob(let data): contents = data
                            case .null: contents = nil
                            default: throw TaskArtifactError.changedFile
                            }
                        } else { contents = nil }
                        try TaskArtifactStore.validate(record, contents: contents)
                    }
                    if let i = columns.firstIndex(of: "beforeContents"), case .blobFile(let ref) = row[i] {
                        guard let blobs, let change = record.artifact.change, change.kind == .modified, change.beforeRetained,
                              change.beforeSHA256 == ref.sha256, change.beforeByteCount == ref.byteCount,
                              ref.byteCount <= TaskArtifactStore.maximumSnapshotBytes else { throw TaskArtifactError.changedFile }
                        try blobs.verify(ref)
                    } else {
                        let before: Data?
                        if let i = columns.firstIndex(of: "beforeContents") {
                            switch row[i] {
                            case .blob(let data): before = data
                            case .null: before = nil
                            default: throw TaskArtifactError.changedFile
                            }
                        } else { before = nil }
                        try TaskArtifactStore.validateBaseline(record, contents: before)
                    }
                    if !exporting {
                        record.artifact.path = pathMappings[record.artifact.path] ?? record.artifact.path
                        record.artifact.sourceSpace = target
                        record.logicalPath = pathMappings[record.logicalPath] ?? record.logicalPath
                        record.workspaceID = record.workspaceID.map { workspaceMappings[$0] ?? $0 }
                    }
                    set("metadata", .blob(try encoder.encode(record)))
                    set("path", .text(record.artifact.path)); set("logicalPath", .text(record.logicalPath))
                    set("workspaceID", record.workspaceID.map(SpaceBackupValue.text) ?? .null)
                    set("version", .integer(Int64(record.artifact.version ?? 1)))
                    set("createdAt", try SpaceBackupValue(record.artifact.createdAt!.databaseValue))
                } else if name == "product_job_runs" {
                    guard let index = columns.firstIndex(of: "payload"), case .blob(let data) = row[index], let target = AppSpace(rawValue: space) else {
                        throw ProductTaskHistoryError.invalidRecord
                    }
                    let old = try ProductJobRunStore.decode(data)
                    guard old.id.uuidString == text("id"), old.space?.rawValue == backup.space else { throw ProductTaskHistoryError.invalidRecord }
                    var value = BackgroundJob(id: old.id, name: old.name, kind: old.kind, space: target, origin: old.origin, submittedAt: old.submittedAt)
                    value.state = old.state; value.finishedAt = old.finishedAt; value.resultText = old.resultText; value.errorText = old.errorText
                    value.historyTruncated = old.historyTruncated
                    value.resultPath = exporting ? old.resultPath : old.resultPath.flatMap { pathMappings[$0] }
                    if !exporting && !value.state.isFinished { value.state = .interrupted }
                    set("payload", .blob(try encoder.encode(value))); set("status", .text(value.state.rawValue))
                    set("title", .text(value.name)); set("preview", .text(String((value.errorText ?? value.resultText ?? "").prefix(512))))
                    set("origin", value.origin.map(SpaceBackupValue.text) ?? .null)
                    set("hostID", .null)
                    set("startedAt", try SpaceBackupValue(value.submittedAt.databaseValue))
                    set("finishedAt", try value.finishedAt.map { try SpaceBackupValue($0.databaseValue) } ?? .null)
                } else if ["knowledge_revisions", "knowledge_sources", "knowledge_import_batches", "knowledge_import_tasks"].contains(name) {
                    guard let index = columns.firstIndex(of: "payload"), case .blob(let data) = row[index], data.count <= 16 * 1024 * 1024 else {
                        throw BackupError.preflightFailed("Invalid knowledge import metadata")
                    }
                    switch name {
                    case "knowledge_revisions":
                        var value = try JSONDecoder().decode(KnowledgeRevision.self, from: data)
                        guard value.id.uuidString == text("id"), value.item.id.uuidString == text("itemID") else { throw KnowledgeImportError.corrupt }
                        value.assetPath = nil
                        set("payload", .blob(try encoder.encode(value)))
                    case "knowledge_sources":
                        var value = try JSONDecoder().decode(KnowledgeSource.self, from: data)
                        guard value.id.uuidString == text("id"), value.itemID.uuidString == text("itemID"), value.key == text("sourceKey"),
                              value.path.hasPrefix("/"), value.path.utf8.count <= 16_384, !value.path.contains("\0"),
                              value.hash.count == 64, value.hash.allSatisfy({ "0123456789abcdef".contains($0) }), value.profile.utf8.count <= 16_384 else { throw KnowledgeImportError.corrupt }
                        value.requiresSelection = true
                        set("payload", .blob(try encoder.encode(value)))
                    case "knowledge_import_batches":
                        var value = try JSONDecoder().decode(KnowledgeImportBatch.self, from: data)
                        guard value.id.uuidString == text("id"), value.candidates.count <= 50 else { throw KnowledgeImportError.corrupt }
                        for index in value.candidates.indices { value.candidates[index].bookmark = nil }
                        set("payload", .blob(try encoder.encode(value)))
                    default:
                        var value = try JSONDecoder().decode(KnowledgeImportTask.self, from: data)
                        guard value.id.uuidString == text("id"), value.batchID.uuidString == text("batchID") else { throw KnowledgeImportError.corrupt }
                        value.candidate.bookmark = nil
                        if !exporting, [.queued, .extracting].contains(value.state) { value.state = .cancelled }
                        set("payload", .blob(try encoder.encode(value)))
                    }
                } else if name == "mcp_servers", let json = text("configurationJSON"), let data = json.data(using: .utf8) {
                    var value = try JSONDecoder().decode(MCPServerConfig.self, from: data)
                    _ = try value.validatedEndpoint()
                    value.credentialID = nil
                    if !exporting { value.isEnabled = false; value.revision = UUID() }
                    set("configurationJSON", .text(String(decoding: try encoder.encode(value), as: UTF8.self)))
                } else if name == "mysql_connections", let json = text("configurationJSON"), let data = json.data(using: .utf8) {
                    var value = try JSONDecoder().decode(MySQLConnectionConfig.self, from: data)
                    try value.validate()
                    value.credentialID = nil
                    if !exporting { value.revision = UUID() }
                    set("configurationJSON", .text(String(decoding: try encoder.encode(value), as: UTF8.self)))
                } else if name == "knowledge_graph_settings", let json = text("json"), let data = json.data(using: .utf8) {
                    var value = try JSONDecoder().decode(KnowledgeGraphSettings.self, from: data)
                    if !exporting { value.extractionEnabled = false; value.needsRetry = false }
                    set("json", .text(String(decoding: try encoder.encode(value), as: UTF8.self)))
                } else if name == "product_preferences" {
                    let key = text("key") ?? ""
                    if key == "notes.local" {
                        // Device-scoped folder grants never survive portable backup.
                        continue
                    }
                    if key == "notes.processing" {
                        guard let index = columns.firstIndex(of: "value"), let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)) else { throw NoteStoreError.invalidContent }
                        var settings = try JSONDecoder().decode(NoteProcessingPreferences.self, from: data)
                        try settings.validate()
                        if !exporting { settings.voiceprintConsent = false }
                        set("value", .blob(try encoder.encode(settings)))
                    }
                    if key == "notes.transcription" {
                        guard let index = columns.firstIndex(of: "value"), let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)) else { throw NoteStoreError.invalidContent }
                        var settings = try JSONDecoder().decode(NoteTranscriptionSettings.self, from: data)
                        try settings.validate()
                        settings.whisperBookmark = nil; settings.whisperIdentity = nil; settings.diarizationBookmark = nil; settings.diarizationEnabled = false
                        if settings.effectiveEngine == "whisper" { settings.engine = "system" }
                        set("value", .blob(try encoder.encode(settings)))
                    }
                    if key == "mail.compose.presets" {
                        guard let index = columns.firstIndex(of: "value"),
                              let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)),
                              data.count <= 8 * 1024 * 1024 else { throw MailComposePresetError.capacity }
                        try JSONDecoder().decode(MailComposePresets.self, from: data).validate()
                    }
                    if ["mail.autoSync", "mail.autoSync.baseline", "mail.list.presentation"].contains(key) {
                        guard let index = columns.firstIndex(of: "value"),
                              let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)),
                              data.count <= 2 * 1024 * 1024 else { throw MailSearchError.invalidFilter }
                        switch key {
                        case "mail.autoSync":
                            var settings = try JSONDecoder().decode(MailAutoSyncSettings.self, from: data)
                            try settings.validate()
                            if !exporting { settings.enabled = false; settings.notifications = false }
                            set("value", .blob(try encoder.encode(settings)))
                        case "mail.autoSync.baseline":
                            let baseline = try JSONDecoder().decode(MailAutoSyncBaseline.self, from: data)
                            guard baseline.stamps.count <= 10_000 else { throw MailSearchError.capacity }
                            if !exporting { set("value", .blob(try encoder.encode(MailAutoSyncBaseline()))) }
                        default:
                            let settings = try JSONDecoder().decode(MailListPresentation.self, from: data)
                            try settings.validate()
                        }
                    }
                } else if name == "mail_accounts" {
                    guard let kind = MailAccountSource(rawValue: text("sourceKind") ?? MailAccountSource.imap.rawValue) else { throw MailImportError.invalidMessage }
                    if kind == .localArchive {
                        guard ["imapHost", "smtpHost", "username", "emailAddress"].allSatisfy({ (text($0) ?? "").isEmpty }) else { throw MailImportError.localOnly }
                    } else if !exporting { set("isEnabled", .integer(0)) }
                } else if name == "mail_import_batches" || name == "mail_import_entries" {
                    guard let index = columns.firstIndex(of: "payload"),
                          let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)),
                          data.count <= MailImportReader.maximumBytes else { throw MailImportError.invalidMessage }
                    if name == "mail_import_batches" {
                        var batch = try JSONDecoder().decode(MailImportBatch.self, from: data)
                        guard batch.id.uuidString == text("id"), batch.accountID.uuidString == text("accountID"),
                              batch.results.count <= MailImportReader.maximumItems,
                              Set(batch.results.map(\.id)).count == batch.results.count else { throw MailImportError.invalidMessage }
                        for item in batch.results { try MailService.validateImportIdentity(item.originalIdentity) }
                        if let manifest = batch.resumeManifest { try MailService.validateImportManifest(manifest, batch: batch) }
                        if !exporting, batch.state == .running { batch.state = .interrupted }
                        set("payload", .blob(try encoder.encode(batch)))
                    } else {
                        let item = try JSONDecoder().decode(MailImportResult.self, from: data)
                        guard item.id.uuidString == text("id"), UUID(uuidString: text("batchID") ?? "") != nil else { throw MailImportError.invalidMessage }
                        try MailService.validateImportIdentity(item.originalIdentity)
                    }
                } else if name == "mail_import_undos" {
                    guard let index = columns.firstIndex(of: "payload"), let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)), data.count <= 4 * 1024 * 1024 else { throw MailImportError.invalidMessage }
                    let undo = try JSONDecoder().decode(MailImportUndoReceipt.self, from: data)
                    let ids = undo.removed + undo.skipped
                    guard undo.batchID.uuidString == text("batchID"), ids.count <= MailImportReader.maximumItems,
                          Set(ids).count == ids.count else { throw MailImportError.invalidMessage }
                } else if name == "mail_import_origins" {
                    guard let hash = text("sha256"), hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                          ["messageID", "accountID", "batchID"].allSatisfy({ UUID(uuidString: text($0) ?? "") != nil }),
                          let source = text("source"), source.utf8.count <= 16_384,
                          let path = text("folderPath"), path.utf8.count <= 8192 else { throw MailImportError.invalidMessage }
                }
                else if name == "scheduled_tasks", !exporting { set("enabled", .integer(0)); set("nextFireAt", .null) }
                else if name == "scheduled_runs", !exporting, ["pending", "running"].contains(text("status") ?? "") { set("status", .text("interrupted")) }
                else if name == "team_tasks" {
                    if let data = text("planJSON")?.data(using: .utf8), var plan = try? JSONDecoder().decode(TeamPlan.self, from: data), plan.retryScope != nil {
                        plan.retryScope = nil
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = .sortedKeys
                        set("planJSON", .text(String(decoding: try encoder.encode(plan), as: UTF8.self)))
                    }
                    if !exporting, let status = text("status").flatMap(TeamTaskStatus.init(rawValue:)), !status.isTerminal {
                        set("status", .text("interrupted"))
                    }
                }
                else if name == "mail_attachments", !exporting {
                    set("localPath", text("localPath").flatMap { pathMappings[$0] }.map(SpaceBackupValue.text) ?? .null)
                }
                if protectedNoteTable, !exporting, noteCipher.enabled, let index = columns.firstIndex(of: "contents"), let data = Data.fromDatabaseValue(try row[index].databaseValue(blobs: blobs)) {
                    row[index] = .blob(try noteCipher.seal(data, table: name))
                    if name == "notes" { set("title", .text("")); set("searchText", .text("")) }
                }
                result.tables[tableIndex].rows[rowIndex] = row
            }
        }
        return result
    }
}
