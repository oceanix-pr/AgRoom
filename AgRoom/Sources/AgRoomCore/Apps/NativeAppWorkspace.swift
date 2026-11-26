import Foundation
import GRDB
import Darwin

public struct NativeAppRecord: Codable, Equatable, Sendable, Identifiable {
    public static let maximumRevision = 1_000_000_000
    public let id: UUID
    public let collection: String
    public let title: String
    public let content: String
    public let fields: [String: NativeAppValue]
    public let revision: Int
    public let updatedAt: Date
    public init(id: UUID, collection: String, title: String, content: String,
                fields: [String: NativeAppValue] = [:], revision: Int, updatedAt: Date) {
        self.id = id; self.collection = collection; self.title = title; self.content = content
        self.fields = fields; self.revision = revision; self.updatedAt = updatedAt
    }
}

public struct NativeAppFile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let byteCount: Int
    public let sha256: String
    public let recordID: UUID?
    public let createdAt: Date
    /// Names are display metadata. Only this generated relative path reaches disk.
    public var relativePath: String { "files/" + id.uuidString.lowercased() }
}

struct NativeAppWorkspaceIdentity: Codable, Sendable {
    let id: UUID
    let dataVersion: Int
}

public struct NativeAppEditingContext: Codable, Equatable, Sendable {
    public let id: UUID
    public let collection: String
    public let revision: Int
    public init(record: NativeAppRecord) { id = record.id; collection = record.collection; revision = record.revision }
    public init(id: UUID, collection: String, revision: Int) { self.id = id; self.collection = collection; self.revision = revision }
}

public struct NativeAppDraftState: Codable, Sendable {
    public let values: [String: NativeAppValue]
    public let editors: [String: NativeAppEditingContext]
    public let boards: [String: NativeAppBoardProgress]
    public init(values: [String: NativeAppValue], editors: [String: NativeAppEditingContext] = [:], boards: [String: NativeAppBoardProgress] = [:]) {
        self.values = values; self.editors = editors; self.boards = boards
    }
    private enum CodingKeys: String, CodingKey { case values, editors, boards }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decode([String: NativeAppValue].self, forKey: .values)
        editors = try container.decodeIfPresent([String: NativeAppEditingContext].self, forKey: .editors) ?? [:]
        boards = try container.decodeIfPresent([String: NativeAppBoardProgress].self, forKey: .boards) ?? [:]
    }
    public func encoded() throws -> Data {
        // Keep old scalar-only state byte-compatible; structured progress uses an envelope.
        try editors.isEmpty && boards.isEmpty ? JSONEncoder().encode(values) : JSONEncoder().encode(self)
    }
    public static func decode(_ data: Data) throws -> NativeAppDraftState {
        guard data.count <= NativeAppDefinition.maximumStateBytes else { throw NativeAppError(.tooLarge) }
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode([String: NativeAppValue].self, from: data) { return .init(values: legacy) }
        let state = try decoder.decode(Self.self, from: data)
        guard state.boards.count <= 4, state.boards.keys.allSatisfy(NativeAppDefinition.validID),
              state.editors.count <= 8, state.editors.allSatisfy({
            NativeAppDefinition.validID($0.key) && NativeAppDefinition.validID($0.value.collection)
                && $0.value.revision > 0 && $0.value.revision <= NativeAppRecord.maximumRevision
        }) else { throw NativeAppError(.incompatibleState) }
        return state
    }
}

/// A capability for exactly one installation, not a mutable current-space lookup.
/// All disk and SQLite operations share the store's actor, including backup/removal.
public struct NativeAppWorkspace: Sendable {
    let root: URL
    public let appID: String
    public let space: AppSpace
    let identity: UUID
    public static let maximumFileBytes = 16 * 1024 * 1024
    public static let maximumTotalFileBytes = 128 * 1024 * 1024
    public static let maximumRecords = 10_000
    public static let maximumFiles = 256

    public func loadDraft(for definition: NativeAppDefinition) async throws -> NativeAppDraftState {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.loadDraft(self, definition: definition) }
    }
    public func saveDraft(_ state: NativeAppDraftState, for definition: NativeAppDefinition) async throws {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.saveDraft(self, definition: definition, state: state) }
    }

    public func records(collection: String, search: String = "", offset: Int = 0, limit: Int = 20) async throws -> [NativeAppRecord] {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.records(self, collection: collection, search: search, offset: offset, limit: limit) }
    }
    public func recordSummaries(collection: String, search: String = "", offset: Int = 0, limit: Int = 20) async throws -> NativeAppKnowledgePage {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.recordSummaries(self, collection: collection, search: search, offset: offset, limit: limit) }
    }
    public func record(id: UUID) async throws -> NativeAppRecord {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.record(self, id: id) }
    }
    public func saveRecord(id: UUID, collection: String, title: String, content: String,
                           fields: [String: NativeAppValue] = [:], replacing revision: Int?) async throws {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.saveRecord(self, id: id, collection: collection, title: title,
            content: content, fields: fields, revision: revision) }
    }
    public func deleteRecord(id: UUID, revision: Int) async throws {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.deleteRecord(self, id: id, revision: revision) }
    }
    public func files() async throws -> [NativeAppFile] {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.files(self) }
    }
    public func fileData(id: UUID) async throws -> Data {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.fileData(self, id: id) }
    }
    public func saveFile(id: UUID, name: String, data: Data, recordID: UUID? = nil) async throws {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.saveFile(self, id: id, name: name, data: data, recordID: recordID) }
    }
    public func deleteFile(_ file: NativeAppFile) async throws {
        try await nativeAppStorageOperation(maintenanceKey: root.path) { try await NativeAppDisk.shared.deleteFile(self, file: file) }
    }
    public static func readSelectedFile(_ url: URL) async throws -> Data {
        guard url.isFileURL else { throw NativeAppError(.unsafePath) }
        return try await Task.detached {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw NativeAppError(.unsafePath) }
            defer { Darwin.close(fd) }
            return try AppDirectory.read(fd: fd, limit: maximumFileBytes)
        }.value
    }
}

extension NativeAppStore {
    public func workspace(for definition: NativeAppDefinition) async throws -> NativeAppWorkspace {
        try await nativeAppStorageOperation(maintenanceKey: directoryURL.path) { try await NativeAppDisk.shared.workspace(root: directoryURL, space: space, definition: definition) }
    }
    public func loadIncludingRetained(id: String) async throws -> NativeAppSnapshot {
        try await NativeAppDisk.shared.loadRetained(root: directoryURL, id: id)
    }
}

extension NativeAppDisk {
    func recordSummaries(_ workspace: NativeAppWorkspace, collection: String, search: String, offset: Int, limit: Int) throws -> NativeAppKnowledgePage {
        guard NativeAppDefinition.validID(collection) else { throw NativeAppError(.invalidDefinition) }
        let database = try NativeAppDatabase(app: appDirectory(workspace))
        let count = min(50, max(1, limit))
        let term = String(search.prefix(256)).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, substr(title, 1, 512) AS title, substr(content, 1, 180) AS preview FROM records
                WHERE collection = ? AND (? = '' OR title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')
                ORDER BY updatedAt DESC, id ASC LIMIT ? OFFSET ?
                """, arguments: [collection, term, "%" + term + "%", "%" + term + "%", count + 1, min(10_000, max(0, offset))])
            let items = try rows.prefix(count).map { row -> NativeAppKnowledgeSummary in
                guard let id = UUID(uuidString: row["id"]) else { throw NativeAppError(.corruptData) }
                return NativeAppKnowledgeSummary(id: id, title: row["title"], preview: row["preview"])
            }
            return NativeAppKnowledgePage(items: items, hasMore: rows.count > count)
        }
    }
    func loadDraft(_ workspace: NativeAppWorkspace, definition: NativeAppDefinition) throws -> NativeAppDraftState {
        let app = try appDirectory(workspace)
        guard app.exists("state.json") else { return .init(values: [:]) }
        do {
            let state = try NativeAppDraftState.decode(app.read("state.json", limit: NativeAppDefinition.maximumStateBytes))
            try definition.validateSavedDraft(state)
            return state
        } catch let issue as NativeAppError { throw issue }
        catch { throw NativeAppError(.incompatibleState) }
    }

    func saveDraft(_ workspace: NativeAppWorkspace, definition: NativeAppDefinition, state: NativeAppDraftState) throws {
        let app = try appDirectory(workspace)
        let current = try NativeAppDefinition.decode(app.read("app.zhiapp.json", limit: NativeAppDefinition.maximumBytes))
        guard current.acceptsStateSchema(of: definition) else { throw NativeAppError(.incompatibleState) }
        try definition.validateSavedDraft(state)
        try current.validateSavedDraft(state)
        let data = try state.encoded()
        guard data.count <= NativeAppDefinition.maximumStateBytes else { throw NativeAppError(.tooLarge) }
        _ = try NativeAppDraftState.decode(data)
        try app.write(data, name: "state.json")
    }
    func loadRetained(root: URL, id: String) throws -> NativeAppSnapshot {
        try load(directory: AppDirectory(url: root, create: false), id: id, includingRetained: true)
    }
    func workspaceIdentity(app: AppDirectory, create: Bool) throws -> NativeAppWorkspaceIdentity {
        if app.exists("workspace.json") {
            let value: NativeAppWorkspaceIdentity
            do { value = try JSONDecoder().decode(NativeAppWorkspaceIdentity.self, from: app.read("workspace.json", limit: 1024)) }
            catch let error as NativeAppError { throw error }
            catch { throw NativeAppError(.corruptData) }
            guard value.dataVersion == 1 else { throw NativeAppError(.incompatibleState) }
            return value
        }
        guard create else { throw NativeAppError(.missing) }
        let value = NativeAppWorkspaceIdentity(id: UUID(), dataVersion: 1)
        try app.write(JSONEncoder().encode(value), name: "workspace.json")
        return value
    }

    func workspace(root: URL, space: AppSpace, definition: NativeAppDefinition) throws -> NativeAppWorkspace {
        try Task.checkCancellation()
        let directory = try AppDirectory(url: root, create: false)
        let current = try load(directory: directory, id: definition.id)
        guard current.definition.dataVersion == definition.dataVersion else { throw NativeAppError(.incompatibleState) }
        let app = try directory.child(definition.id, create: false)
        let identity = try workspaceIdentity(app: app, create: true)
        return NativeAppWorkspace(root: root, appID: definition.id, space: space, identity: identity.id)
    }

    func appDirectory(_ workspace: NativeAppWorkspace) throws -> AppDirectory {
        try Task.checkCancellation()
        let directory = try AppDirectory(url: workspace.root, create: false)
        _ = try load(directory: directory, id: workspace.appID)
        let app = try directory.child(workspace.appID, create: false)
        guard try workspaceIdentity(app: app, create: false).id == workspace.identity else { throw NativeAppError(.conflict) }
        return app
    }

    func records(_ workspace: NativeAppWorkspace, collection: String, search: String, offset: Int, limit: Int) throws -> [NativeAppRecord] {
        guard NativeAppDefinition.validID(collection) else { throw NativeAppError(.invalidDefinition) }
        let app = try appDirectory(workspace)
        let database = try NativeAppDatabase(app: app)
        let term = String(search.prefix(256)).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM records WHERE collection = ? AND (? = '' OR title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')
                ORDER BY updatedAt DESC, id ASC LIMIT ? OFFSET ?
                """, arguments: [collection, term, "%" + term + "%", "%" + term + "%", min(51, max(1, limit)), min(10_000, max(0, offset))])
                .map(Self.decodeRecord)
        }
    }

    func record(_ workspace: NativeAppWorkspace, id: UUID) throws -> NativeAppRecord {
        let database = try NativeAppDatabase(app: appDirectory(workspace))
        return try database.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM records WHERE id = ?", arguments: [id.uuidString]) else {
                throw NativeAppError(.missing)
            }
            return try Self.decodeRecord(row)
        }
    }

    static func validateRecord(collection: String, title: String, content: String, fields: [String: NativeAppValue]) throws {
        guard NativeAppDefinition.validID(collection), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 512, content.utf8.count <= 32 * 1024,
              fields.count <= 32, fields.allSatisfy({ NativeAppDefinition.validID($0.key) && $0.value.isBounded }),
              try JSONEncoder().encode(fields).count <= 64 * 1024 else { throw NativeAppError(.tooLarge) }
    }

    func saveRecord(_ workspace: NativeAppWorkspace, id: UUID, collection: String, title: String,
                    content: String, fields: [String: NativeAppValue], revision: Int?) throws {
        try Self.validateRecord(collection: collection, title: title, content: content, fields: fields)
        guard revision == nil || (revision! > 0 && revision! < NativeAppRecord.maximumRevision) else { throw NativeAppError(.capacity) }
        let database = try NativeAppDatabase(app: appDirectory(workspace))
        try database.queue.write { db in
            let old = try Row.fetchOne(db, sql: "SELECT revision, collection FROM records WHERE id = ?", arguments: [id.uuidString])
            let oldRevision: Int? = old?["revision"]
            guard oldRevision == revision, old == nil || (old?["collection"] as String?) == collection else { throw NativeAppError(.conflict) }
            if old == nil, try Int.fetchOne(db, sql: "SELECT count(*) FROM records") ?? 0 >= NativeAppWorkspace.maximumRecords {
                throw NativeAppError(.capacity)
            }
            try Task.checkCancellation()
            try db.execute(sql: """
                INSERT INTO records(id, collection, title, content, fields, revision, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, content=excluded.content, fields=excluded.fields,
                    revision=excluded.revision, updatedAt=excluded.updatedAt
                """, arguments: [id.uuidString, collection, title, content, String(decoding: try JSONEncoder().encode(fields), as: UTF8.self),
                    (revision ?? 0) + 1, Date().timeIntervalSince1970])
        }
    }

    func deleteRecord(_ workspace: NativeAppWorkspace, id: UUID, revision: Int) throws {
        let database = try NativeAppDatabase(app: appDirectory(workspace))
        try database.queue.write { db in
            try Task.checkCancellation()
            try db.execute(sql: "DELETE FROM records WHERE id = ? AND revision = ?", arguments: [id.uuidString, revision])
            guard db.changesCount == 1 else { throw NativeAppError(.conflict) }
        }
    }

    func files(_ workspace: NativeAppWorkspace) throws -> [NativeAppFile] {
        let app = try appDirectory(workspace)
        let database = try NativeAppDatabase(app: app)
        try reconcileFiles(app: app, database: database)
        return try database.queue.read { try Row.fetchAll($0, sql: "SELECT * FROM files ORDER BY createdAt DESC, id ASC").map(Self.decodeFile) }
    }

    func fileData(_ workspace: NativeAppWorkspace, id: UUID) throws -> Data {
        let app = try appDirectory(workspace)
        let database = try NativeAppDatabase(app: app)
        let file = try database.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM files WHERE id = ?", arguments: [id.uuidString]) else { throw NativeAppError(.missing) }
            return try Self.decodeFile(row)
        }
        let data = try app.child("files", create: false).read(id.uuidString.lowercased(), limit: NativeAppWorkspace.maximumFileBytes)
        guard data.count == file.byteCount, Self.digest(data) == file.sha256 else { throw NativeAppError(.corruptData) }
        return data
    }

    func saveFile(_ workspace: NativeAppWorkspace, id: UUID, name: String, data: Data, recordID: UUID?) throws {
        guard Self.validFileName(name), data.count <= NativeAppWorkspace.maximumFileBytes else { throw NativeAppError(.tooLarge) }
        let app = try appDirectory(workspace)
        let database = try NativeAppDatabase(app: app)
        try reconcileFiles(app: app, database: database)
        let files = try app.child("files", create: true)
        let path = id.uuidString.lowercased()
        guard !files.exists(path) else { throw NativeAppError(.conflict) }
        try database.queue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM files") ?? 0 < NativeAppWorkspace.maximumFiles,
                  try Int.fetchOne(db, sql: "SELECT coalesce(sum(byteCount), 0) FROM files") ?? 0 <= NativeAppWorkspace.maximumTotalFileBytes - data.count else {
                throw NativeAppError(.capacity)
            }
            try Task.checkCancellation()
            // Publish bytes before their metadata. A failed transaction leaves an
            // unreferenced UUID file, removed by bounded reconciliation next time.
            try files.write(data, name: path)
            try db.execute(sql: "INSERT INTO files(id, name, byteCount, sha256, recordID, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [id.uuidString, name, data.count, Self.digest(data), recordID?.uuidString, Date().timeIntervalSince1970])
        }
    }

    func deleteFile(_ workspace: NativeAppWorkspace, file: NativeAppFile) throws {
        let app = try appDirectory(workspace)
        let database = try NativeAppDatabase(app: app)
        try database.queue.write { db in
            try Task.checkCancellation()
            try db.execute(sql: "DELETE FROM files WHERE id = ? AND sha256 = ?", arguments: [file.id.uuidString, file.sha256])
            guard db.changesCount == 1 else { throw NativeAppError(.conflict) }
        }
        // Metadata deletion commits first. Cleanup is retryable and never replays
        // a business write; orphan bytes are not returned by list/export.
        try reconcileFiles(app: app, database: database)
    }

    func reconcileFiles(app: AppDirectory, database: NativeAppDatabase) throws {
        guard app.exists("files") else { return }
        let files = try app.child("files", create: false)
        let referenced = try database.queue.read { Set(try String.fetchAll($0, sql: "SELECT lower(id) FROM files")) }
        for name in try files.names() {
            let isOrphan = UUID(uuidString: name) != nil && !referenced.contains(name.lowercased())
            let isPending = name.hasPrefix(".pending-") && UUID(uuidString: String(name.dropFirst(9))) != nil
            guard isOrphan || isPending else { continue }
            try files.checkRegular(name, missingOK: false)
            try files.removeFile(name)
        }
    }

    static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func decodeRecord(_ row: Row) throws -> NativeAppRecord {
        guard let id = UUID(uuidString: row["id"]) else { throw NativeAppError(.corruptData) }
        let fields: String = row["fields"]
        let revision: Int = row["revision"]
        guard revision > 0, revision <= NativeAppRecord.maximumRevision else { throw NativeAppError(.corruptData) }
        return NativeAppRecord(id: id, collection: row["collection"], title: row["title"], content: row["content"],
            fields: try JSONDecoder().decode([String: NativeAppValue].self, from: Data(fields.utf8)),
            revision: revision, updatedAt: Date(timeIntervalSince1970: row["updatedAt"]))
    }
    static func decodeFile(_ row: Row) throws -> NativeAppFile {
        guard let id = UUID(uuidString: row["id"]) else { throw NativeAppError(.corruptData) }
        let record: String? = row["recordID"]
        return NativeAppFile(id: id, name: row["name"], byteCount: row["byteCount"], sha256: row["sha256"],
            recordID: record.flatMap(UUID.init(uuidString:)), createdAt: Date(timeIntervalSince1970: row["createdAt"]))
    }
}

/// Short-lived, actor-owned connection. No service or connection registry is cached
/// in Hub. Descriptor-relative roots and no-link preflight apply to DB sidecars too.
final class NativeAppDatabase {
    let app: AppDirectory
    let queue: DatabaseQueue
    init(app: AppDirectory) throws {
        self.app = app
        for name in ["data.sqlite", "data.sqlite-journal", "data.sqlite-wal", "data.sqlite-shm"] {
            try app.checkRegular(name)
        }
        let directoryURL = try app.kernelURL()
        let path = directoryURL.appendingPathComponent("data.sqlite").path
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON; PRAGMA trusted_schema = OFF; PRAGMA busy_timeout = 3000")
        }
        queue = try DatabaseQueue(path: path, configuration: configuration)
        try app.verifyIdentity(at: directoryURL)
        try queue.writeWithoutTransaction { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version <= 1 else { throw NativeAppError(.incompatibleState) }
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            guard pageSize > 0 else { throw NativeAppError(.corruptData) }
            try db.execute(sql: "PRAGMA journal_mode = DELETE; PRAGMA max_page_count = \(64 * 1024 * 1024 / pageSize)")
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_native_app_data") { db in
            try db.execute(sql: """
                CREATE TABLE records (
                    id TEXT PRIMARY KEY NOT NULL, collection TEXT NOT NULL,
                    title TEXT NOT NULL, content TEXT NOT NULL, fields TEXT NOT NULL,
                    revision INTEGER NOT NULL, updatedAt REAL NOT NULL
                );
                CREATE INDEX records_collection_updated ON records(collection, updatedAt DESC, id);
                CREATE TABLE files (
                    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, byteCount INTEGER NOT NULL,
                    sha256 TEXT NOT NULL, recordID TEXT REFERENCES records(id) ON DELETE SET NULL,
                    createdAt REAL NOT NULL
                );
                PRAGMA user_version = 1;
                """)
        }
        do { try migrator.migrate(queue) }
        catch { throw NativeAppError(.corruptData) }
        try app.checkRegular("data.sqlite", missingOK: false)
        try app.verifyIdentity(at: directoryURL)
    }
}

/// Keep SQL diagnostics and bound private values out of user-visible errors.
func nativeAppStorageOperation<T: Sendable>(maintenanceKey: String? = nil, _ operation: @Sendable () async throws -> T) async throws -> T {
    do {
        if let maintenanceKey { return try await ResourceMaintenance.withAsyncAccess(ResourceMaintenance.directoryKey(URL(fileURLWithPath: maintenanceKey)), operation: operation) }
        return try await operation()
    }
    catch let issue as MaintenanceError { throw issue }
    catch let issue as NativeAppError { throw issue }
    catch let issue as NativeAppScriptError { throw issue }
    catch is CancellationError { throw CancellationError() }
    catch let issue as DatabaseError {
        if issue.resultCode == .SQLITE_CORRUPT || issue.resultCode == .SQLITE_NOTADB { throw NativeAppError(.corruptData) }
        if issue.resultCode == .SQLITE_CONSTRAINT { throw NativeAppError(.conflict) }
        throw NativeAppError(.storage)
    }
    catch is DecodingError { throw NativeAppError(.corruptData) }
    catch { throw NativeAppError(.storage) }
}
