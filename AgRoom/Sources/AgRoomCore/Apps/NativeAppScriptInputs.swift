import Foundation
import GRDB

public struct NativeAppScriptRecordQuery: Sendable {
    public let collection: String
    public let search: String
    public let limit: Int
    public init(collection: String, search: String, limit: Int) {
        self.collection = collection; self.search = search; self.limit = limit
    }
}

struct NativeAppScriptInputs: Sendable {
    struct FileInfo: Codable, Sendable {
        let id: UUID
        let name: String
        let byteCount: Int
        let sha256: String
    }
    struct Payload: Codable, Sendable {
        let inputs: [String: NativeAppValue]
        let records: [String: [NativeAppRecord]]
        let files: [String: FileInfo]
        let data: [String: HostDataTable]?
    }
    let payload: Data
    let files: [String: Data]
    var digest: String { NativeAppDisk.digest(payload) }
}

extension NativeAppWorkspace {
    func scriptInputs(values: [String: NativeAppValue], records: [String: NativeAppScriptRecordQuery],
                      files: [String: UUID]) async throws -> NativeAppScriptInputs {
        try await nativeAppStorageOperation {
            try await NativeAppDisk.shared.scriptInputs(self, values: values, queries: records, fileIDs: files)
        }
    }

    public func validateScriptInstallation(_ definition: NativeAppDefinition) async throws {
        try await nativeAppStorageOperation { try await NativeAppDisk.shared.validateScriptInstallation(self, definition: definition) }
    }
}

extension NativeAppDisk {
    func validateScriptInstallation(_ workspace: NativeAppWorkspace, definition: NativeAppDefinition) throws {
        let app = try appDirectory(workspace)
        let current = try NativeAppDefinition.decode(app.read("app.zhiapp.json", limit: NativeAppDefinition.maximumBytes))
        guard current == definition else { throw NativeAppError(.conflict) }
    }

    /// One read transaction, independent of the UI's pagination. Oversized queries fail explicitly.
    func scriptInputs(_ workspace: NativeAppWorkspace, values: [String: NativeAppValue],
                      queries: [String: NativeAppScriptRecordQuery], fileIDs: [String: UUID]) throws -> NativeAppScriptInputs {
        guard values.count <= 32, values.allSatisfy({ NativeAppDefinition.validID($0.key) && $0.value.isBounded }),
              queries.count <= 8, fileIDs.count <= 8,
              queries.keys.allSatisfy(NativeAppDefinition.validID), fileIDs.keys.allSatisfy(NativeAppDefinition.validID) else {
            throw NativeAppError(.tooLarge)
        }
        let app = try appDirectory(workspace)
        let database = try NativeAppDatabase(app: app)
        return try database.queue.read { db in
            var records: [String: [NativeAppRecord]] = [:]
            var files: [String: Data] = [:]
            var metadata: [String: NativeAppScriptInputs.FileInfo] = [:]
            var recordBytes = 0
            for (key, query) in queries {
                try Task.checkCancellation()
                guard NativeAppDefinition.validID(query.collection), (1...1000).contains(query.limit), query.search.count <= 256 else {
                    throw NativeAppError(.invalidDefinition)
                }
                let term = query.search.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                let cursor = try Row.fetchCursor(db, sql: """
                    SELECT * FROM records WHERE collection = ? AND (? = '' OR title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')
                    ORDER BY updatedAt DESC, id ASC LIMIT ?
                    """, arguments: [query.collection, term, "%" + term + "%", "%" + term + "%", query.limit + 1])
                var selected: [NativeAppRecord] = []
                while let row = try cursor.next() {
                    guard selected.count < query.limit else { throw NativeAppScriptError(.queryTooLarge) }
                    let record = try Self.decodeRecord(row)
                    recordBytes += try JSONEncoder().encode(record).count
                    guard recordBytes <= 4 * 1024 * 1024 else { throw NativeAppError(.tooLarge) }
                    selected.append(record)
                }
                records[key] = selected
            }
            var totalFileBytes = 0
            for (key, id) in fileIDs {
                try Task.checkCancellation()
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM files WHERE id = ?", arguments: [id.uuidString]) else {
                    throw NativeAppError(.missing)
                }
                let file = try Self.decodeFile(row)
                let data = try app.child("files", create: false).read(id.uuidString.lowercased(), limit: NativeAppWorkspace.maximumFileBytes)
                guard data.count == file.byteCount, Self.digest(data) == file.sha256 else { throw NativeAppError(.corruptData) }
                totalFileBytes += data.count
                guard totalFileBytes <= 32 * 1024 * 1024 else { throw NativeAppError(.tooLarge) }
                files[key] = data
                metadata[key] = .init(id: id, name: file.name, byteCount: file.byteCount, sha256: file.sha256)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(NativeAppScriptInputs.Payload(inputs: values, records: records, files: metadata, data: nil))
            guard payload.count <= 5 * 1024 * 1024 else { throw NativeAppError(.tooLarge) }
            return NativeAppScriptInputs(payload: payload, files: files)
        }
    }
}
