import Foundation
import GRDB
import Darwin

struct NativeAppBackupContents: Codable, Sendable {
    struct FileEntry: Codable, Sendable {
        let metadata: NativeAppFile
        let data: Data
    }
    let space: AppSpace
    let definition: Data
    let previous: Data?
    let state: Data?
    let installed: Bool
    let dataVersion: Int
    let records: [NativeAppRecord]
    let files: [FileEntry]
    var iconColor: NativeAppIconColor?
}

/// Portable logical snapshot, not a copy of a live SQLite main file. The disk actor
/// serializes this snapshot with every app write, including file publication.
public struct NativeAppBackup: Sendable {
    struct Envelope: Codable {
        let formatVersion: Int
        let payload: Data
        let sha256: String
    }
    let contents: NativeAppBackupContents
    public let definition: NativeAppDefinition
    public let fingerprint: String
    public var space: AppSpace { contents.space }
    public var recordCount: Int { contents.records.count }
    public var fileCount: Int { contents.files.count }
    public var isInstalled: Bool { contents.installed }
    public static let maximumBytes = 512 * 1024 * 1024

    init(contents: NativeAppBackupContents) throws {
        self.contents = contents
        definition = try NativeAppDefinition.decode(contents.definition)
        guard contents.dataVersion == definition.dataVersion, contents.records.count <= NativeAppWorkspace.maximumRecords,
              contents.files.count <= NativeAppWorkspace.maximumFiles else { throw NativeAppError(.incompatibleState) }
        if let previous = contents.previous {
            let old = try NativeAppDefinition.decode(previous)
            guard old.id == definition.id, old.dataVersion == definition.dataVersion,
                  definition.acceptsStateSchema(of: old) else { throw NativeAppError(.incompatibleState) }
        }
        if let state = contents.state {
            guard state.count <= NativeAppDefinition.maximumStateBytes else { throw NativeAppError(.tooLarge) }
            try definition.validateSavedDraft(NativeAppDraftState.decode(state))
        }
        var recordIDs = Set<UUID>()
        for record in contents.records {
            guard recordIDs.insert(record.id).inserted, record.revision > 0, record.revision <= NativeAppRecord.maximumRevision,
                  record.updatedAt.timeIntervalSince1970.isFinite else { throw NativeAppError(.corruptData) }
            try NativeAppDisk.validateRecord(collection: record.collection, title: record.title, content: record.content, fields: record.fields)
        }
        var fileIDs = Set<UUID>()
        var bytes = 0
        for entry in contents.files {
            let file = entry.metadata
            guard fileIDs.insert(file.id).inserted, NativeAppDisk.validFileName(file.name),
                  entry.data.count <= NativeAppWorkspace.maximumFileBytes,
                  file.byteCount == entry.data.count, file.sha256 == NativeAppDisk.digest(entry.data),
                  file.recordID == nil || recordIDs.contains(file.recordID!),
                  file.createdAt.timeIntervalSince1970.isFinite else { throw NativeAppError(.corruptData) }
            bytes += entry.data.count
            guard bytes <= NativeAppWorkspace.maximumTotalFileBytes else { throw NativeAppError(.tooLarge) }
        }
        fingerprint = NativeAppDisk.digest(try Self.encoder.encode(contents))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public func encoded() throws -> Data {
        let payload = try Self.encoder.encode(contents)
        let data = try Self.encoder.encode(Envelope(formatVersion: 1, payload: payload, sha256: NativeAppDisk.digest(payload)))
        guard data.count <= Self.maximumBytes else { throw NativeAppError(.tooLarge) }
        return data
    }

    public static func decode(_ data: Data) throws -> NativeAppBackup {
        guard data.count <= maximumBytes else { throw NativeAppError(.tooLarge) }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.formatVersion == 1, NativeAppDisk.digest(envelope.payload) == envelope.sha256 else { throw NativeAppError(.corruptData) }
            return try NativeAppBackup(contents: JSONDecoder().decode(NativeAppBackupContents.self, from: envelope.payload))
        } catch let issue as NativeAppError { throw issue }
        catch { throw NativeAppError(.corruptData) }
    }

    public static func importSelectedFile(_ url: URL) async throws -> NativeAppBackup {
        guard url.isFileURL else { throw NativeAppError(.unsafePath) }
        return try await Task.detached {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw NativeAppError(.unsafePath) }
            defer { Darwin.close(fd) }
            return try decode(AppDirectory.read(fd: fd, limit: maximumBytes))
        }.value
    }
}

public struct NativeAppDataRestorePlan: Sendable {
    public let previousFingerprint: String?
    public let existingRecordCount: Int
    public let existingFileCount: Int
    public var currentDataIsUnreadable = false
}

extension NativeAppStore {
    public func backup(id: String, space: AppSpace) async throws -> NativeAppBackup {
        guard space == self.space else { throw NativeAppError(.spaceMismatch) }
        return try await nativeAppStorageOperation(maintenanceKey: directoryURL.path) { try await NativeAppDisk.shared.backup(root: directoryURL, id: id, space: space) }
    }
    public func inspectRestore(_ backup: NativeAppBackup, space: AppSpace) async throws -> NativeAppDataRestorePlan {
        guard backup.space == space, space == self.space else { throw NativeAppError(.spaceMismatch) }
        return try await nativeAppStorageOperation(maintenanceKey: directoryURL.path) { try await NativeAppDisk.shared.inspectRestore(root: directoryURL, backup: backup) }
    }
    public func restore(_ backup: NativeAppBackup, space: AppSpace, replacing fingerprint: String?) async throws {
        guard backup.space == space, space == self.space else { throw NativeAppError(.spaceMismatch) }
        try await nativeAppStorageOperation(maintenanceKey: directoryURL.path) { try await NativeAppDisk.shared.restoreBackup(root: directoryURL, backup: backup, expected: fingerprint) }
    }
    public func recoveryBackup(id: String, space: AppSpace) async throws -> NativeAppBackup {
        guard space == self.space else { throw NativeAppError(.spaceMismatch) }
        return try await NativeAppDisk.shared.recoveryBackup(root: directoryURL, id: id, space: space)
    }
    public func rawRecoveryDirectory(id: String) async throws -> URL {
        try await NativeAppDisk.shared.rawRecoveryDirectory(root: directoryURL, id: id)
    }
}

extension NativeAppDisk {
    func backup(root: URL, id: String, space: AppSpace) throws -> NativeAppBackup {
        try Task.checkCancellation()
        let directory = try AppDirectory(url: root, create: false)
        let current = try load(directory: directory, id: id, includingRetained: true)
        let app = try directory.child(id, create: false)
        var records: [NativeAppRecord] = []
        var files: [NativeAppBackupContents.FileEntry] = []
        if app.exists("data.sqlite") {
            let database = try NativeAppDatabase(app: app)
            // A single read transaction captures records and attachment metadata.
            let snapshot = try database.queue.read { db in
                (try Row.fetchAll(db, sql: "SELECT * FROM records ORDER BY id LIMIT 10001").map(Self.decodeRecord),
                 try Row.fetchAll(db, sql: "SELECT * FROM files ORDER BY id LIMIT 257").map(Self.decodeFile))
            }
            guard snapshot.0.count <= NativeAppWorkspace.maximumRecords, snapshot.1.count <= NativeAppWorkspace.maximumFiles else {
                throw NativeAppError(.capacity)
            }
            records = snapshot.0
            var byteCount = 0
            for file in snapshot.1 {
                try Task.checkCancellation()
                let data = try app.child("files", create: false).read(file.id.uuidString.lowercased(), limit: NativeAppWorkspace.maximumFileBytes)
                byteCount += data.count
                guard byteCount <= NativeAppWorkspace.maximumTotalFileBytes else { throw NativeAppError(.tooLarge) }
                files.append(.init(metadata: file, data: data))
            }
        }
        return try NativeAppBackup(contents: NativeAppBackupContents(space: space,
            definition: current.definition.encoded(),
            previous: app.exists("previous.zhiapp.json") ? app.read("previous.zhiapp.json", limit: NativeAppDefinition.maximumBytes) : nil,
            state: app.exists("state.json") ? app.read("state.json", limit: NativeAppDefinition.maximumStateBytes) : nil,
            installed: current.isInstalled, dataVersion: current.definition.dataVersion, records: records, files: files,
            iconColor: try iconColor(app: app)))
    }

    func inspectRestore(root: URL, backup archive: NativeAppBackup) throws -> NativeAppDataRestorePlan {
        do {
            let existing = try backup(root: root, id: archive.definition.id, space: archive.space)
            return NativeAppDataRestorePlan(previousFingerprint: existing.fingerprint,
                existingRecordCount: existing.recordCount, existingFileCount: existing.fileCount)
        } catch let issue as NativeAppError where issue.code == .missing {
            do {
                let directory = try AppDirectory(url: root, create: false)
                if directory.exists(archive.definition.id) {
                    let app = try directory.child(archive.definition.id, create: false)
                    return try NativeAppDataRestorePlan(previousFingerprint: "raw:" + rawFingerprint(app),
                        existingRecordCount: 0, existingFileCount: 0, currentDataIsUnreadable: true)
                }
                guard try directory.names().filter(NativeAppDefinition.validID).count < 64 else { throw NativeAppError(.capacity) }
            } catch let issue as NativeAppError where issue.code == .missing { }
            return NativeAppDataRestorePlan(previousFingerprint: nil, existingRecordCount: 0, existingFileCount: 0)
        } catch {
            // A damaged current database/definition must not prevent recovery.
            // Preserve its raw directory and bind approval to those exact bytes.
            let directory = try AppDirectory(url: root, create: false)
            let app = try directory.child(archive.definition.id, create: false)
            return try NativeAppDataRestorePlan(previousFingerprint: "raw:" + rawFingerprint(app),
                existingRecordCount: 0, existingFileCount: 0, currentDataIsUnreadable: true)
        }
    }

    private func rawFingerprint(_ app: AppDirectory) throws -> String {
        var entries: [String: String] = [:]
        var bytes = 0
        func scan(_ directory: AppDirectory, path: String, depth: Int) throws {
            guard depth <= 4 else { throw NativeAppError(.capacity) }
            for name in try directory.names().sorted() {
                try Task.checkCancellation()
                let key = path + name
                guard entries.count < 2048 else { throw NativeAppError(.capacity) }
                var info = stat()
                guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NativeAppError(.storage) }
                if info.st_mode & S_IFMT == S_IFDIR {
                    entries[key + "/"] = "directory"
                    try scan(directory.child(name, create: false), path: key + "/", depth: depth + 1)
                } else {
                    let data = try directory.read(name, limit: min(64 * 1024 * 1024, NativeAppBackup.maximumBytes - bytes))
                    bytes += data.count
                    guard bytes <= NativeAppBackup.maximumBytes else { throw NativeAppError(.tooLarge) }
                    entries[key] = Self.digest(data)
                }
            }
        }
        try scan(app, path: "", depth: 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Self.digest(try encoder.encode(entries))
    }

    func rawRecoveryDirectory(root: URL, id: String) throws -> URL {
        guard NativeAppDefinition.validID(id) else { throw NativeAppError(.unsafePath) }
        let recovery = try AppDirectory(url: root, create: false).child(".recovery", create: false)
        return try recovery.child("raw-" + id, create: false).kernelURL()
    }

    func recoveryBackup(root: URL, id: String, space: AppSpace) throws -> NativeAppBackup {
        guard NativeAppDefinition.validID(id) else { throw NativeAppError(.unsafePath) }
        let directory = try AppDirectory(url: root, create: false).child(".recovery", create: false)
        let value = try NativeAppBackup.decode(directory.read(id + ".json", limit: NativeAppBackup.maximumBytes))
        guard value.definition.id == id, value.space == space else { throw NativeAppError(.spaceMismatch) }
        return value
    }

    func restoreBackup(root: URL, backup archive: NativeAppBackup, expected: String?) throws {
        try Task.checkCancellation()
        let plan = try inspectRestore(root: root, backup: archive)
        guard plan.previousFingerprint == expected else { throw NativeAppError(.conflict) }
        let directory = try AppDirectory(url: root, create: true)
        let id = archive.definition.id
        let recovery = try directory.child(".recovery", create: true)
        if expected != nil && !plan.currentDataIsUnreadable {
            let old = try backup(root: root, id: id, space: archive.space)
            try recovery.write(try old.encoded(), name: id + ".json")
        }
        let stagingName = ".restore-" + UUID().uuidString
        let staging = try directory.child(stagingName, create: true)
        var published = false
        var recoveryMoved = false
        defer {
            if published && expected != nil && !recoveryMoved {
                HubLogger.shared.warning("App restore kept original directory after recovery publication failed")
            } else {
                do { if directory.exists(stagingName) { try directory.removeTree(stagingName) } }
                catch { HubLogger.shared.warning(published ? "App restore recovery directory cleanup failed" : "App restore staging cleanup failed") }
            }
        }
        try materialize(archive, app: staging)
        try Task.checkCancellation()
        if plan.currentDataIsUnreadable { try recovery.removeFile(id + ".json", missingOK: true) }
        let flags = expected == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        guard renameatx_np(directory.fd, stagingName, directory.fd, id, flags) == 0 else { throw NativeAppError(.storage) }
        published = true
        guard fsync(directory.fd) == 0 else { throw NativeAppError(.storage) }
        if expected != nil {
            // Keep the previous physical directory too, including unreadable data
            // that cannot be converted into a logical snapshot. Replace one prior
            // recovery point atomically, then clean its superseded directory.
            let rawName = "raw-" + id
            let flag = recovery.exists(rawName) ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
            if renameatx_np(directory.fd, stagingName, recovery.fd, rawName, flag) != 0 {
                // The current workspace is already published. Never remove the
                // only surviving old bytes if moving recovery material fails.
                throw NativeAppError(.storage, path: root.appendingPathComponent(stagingName).path)
            }
            recoveryMoved = true
            guard fsync(recovery.fd) == 0 else { throw NativeAppError(.storage) }
        }
    }

    private func materialize(_ archive: NativeAppBackup, app: AppDirectory) throws {
        let contents = archive.contents
        try app.write(contents.definition, name: contents.installed ? "app.zhiapp.json" : "retained.zhiapp.json")
        if let previous = contents.previous { try app.write(previous, name: "previous.zhiapp.json") }
        if let state = contents.state { try app.write(state, name: "state.json") }
        if let color = contents.iconColor, color != .space {
            try app.write(JSONEncoder().encode(NativeAppAppearance(iconColor: color)), name: "appearance.json")
        }
        try app.write(JSONEncoder().encode(NativeAppWorkspaceIdentity(id: UUID(), dataVersion: contents.dataVersion)), name: "workspace.json")
        if !contents.records.isEmpty || !contents.files.isEmpty {
            let database = try NativeAppDatabase(app: app)
            let files = try app.child("files", create: true)
            try database.queue.write { db in
                for record in contents.records {
                    try Task.checkCancellation()
                    try db.execute(sql: "INSERT INTO records VALUES (?, ?, ?, ?, ?, ?, ?)",
                        arguments: [record.id.uuidString, record.collection, record.title, record.content,
                            String(decoding: try JSONEncoder().encode(record.fields), as: UTF8.self), record.revision, record.updatedAt.timeIntervalSince1970])
                }
                for entry in contents.files {
                    try Task.checkCancellation()
                    let file = entry.metadata
                    try files.write(entry.data, name: file.id.uuidString.lowercased())
                    try db.execute(sql: "INSERT INTO files VALUES (?, ?, ?, ?, ?, ?)",
                        arguments: [file.id.uuidString, file.name, file.byteCount, file.sha256,
                            file.recordID?.uuidString, file.createdAt.timeIntervalSince1970])
                }
            }
        }
        // Derivative data is intentionally absent from the portable snapshot.
        _ = try app.child("cache", create: true)
    }
}
