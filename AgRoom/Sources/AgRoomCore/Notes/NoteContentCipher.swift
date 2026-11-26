import Foundation
import CryptoKit
import GRDB
import Security

/// A value owned by one database. Keys never enter the database or portable backups.
public struct NoteContentCipher: Sendable {
    private static let marker = Data("AgRoomNote1\0".utf8)
    private static let tables = ["notes", "note_workflows", "note_transcription_checkpoints", "note_voiceprints", "note_capture_reports", "note_visual_checkpoints", "note_speaker_analysis"]
    private let key: SymmetricKey?
    private let scope: String
    public static let plaintext = NoteContentCipher(key: nil, scope: "")
    public init(key: Data?, scope: String) {
        self.key = key.map(SymmetricKey.init(data:)); self.scope = scope
    }
    public var enabled: Bool { key != nil }
    static func production(space: AppSpace, createIfMissing: Bool = true) throws -> Self {
        .init(key: try KeychainService.loadOrCreateSigningKey(account: "notes.encryption." + space.rawValue, createIfMissing: createIfMissing), scope: space.rawValue)
    }
    /// Isolated hosts use explicit test keys; only the real space files use the user's vault.
    static func database(_ queue: DatabaseQueue, space: String) throws -> Self {
        guard let owner = AppSpace(rawValue: space), let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              URL(fileURLWithPath: queue.path).standardizedFileURL == support.appendingPathComponent("AgRoom").appendingPathComponent(owner.databaseFileName).standardizedFileURL else { return .plaintext }
        return try loadForMount(queue) { try production(space: owner, createIfMissing: $0) }
    }

    static func loadForMount(_ queue: DatabaseQueue, key: (_ createIfMissing: Bool) throws -> Self) throws -> Self {
        do { return try key(false) }
        catch KeychainService.KeychainError.unexpectedStatus(let status) where status == errSecItemNotFound {
            // Only an empty or entirely legacy database may acquire a first key. A damaged marker still fails closed.
            let legacy = try queue.read { db in
                for table in tables where try db.tableExists(table) {
                    let invalid = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE NOT json_valid(CAST(contents AS TEXT)))")
                    if invalid == true { return false }
                }
                return true
            }
            guard legacy else { throw KeychainService.KeychainError.unexpectedStatus(status) }
            return try key(true)
        }
    }
    public func seal(_ data: Data, table: String) throws -> Data {
        guard let key else { return data }
        let box = try AES.GCM.seal(data, using: key, authenticating: Data((scope + ":" + table).utf8))
        guard let bytes = box.combined else { throw NoteStoreError.invalidContent }
        return Self.marker + bytes
    }
    public func open(_ data: Data, table: String) throws -> Data {
        guard data.starts(with: Self.marker) else { return data }
        guard let key else { throw NoteStoreError.invalidContent }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(Self.marker.count)), using: key, authenticating: Data((scope + ":" + table).utf8))
    }
    func encode<T: Encodable>(_ value: T, table: String) throws -> Data { try seal(JSONEncoder().encode(value), table: table) }
    func decode<T: Decodable>(_ type: T.Type, from data: Data, table: String) throws -> T { try JSONDecoder().decode(type, from: open(data, table: table)) }

    /// One atomic conversion. Failed authentication rolls back every row. No Keychain I/O in SQLite.
    static func protect(_ queue: DatabaseQueue, cipher: Self) throws {
        guard cipher.enabled else { return }
        let cleanup = try queue.write { db -> String? in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            var changed = false
            for table in tables where try db.tableExists(table) {
                let column = ["note_transcription_checkpoints", "note_speaker_analysis"].contains(table) ? "mediaID" : "id"
                var after: String?
                while true {
                    let predicate = after == nil ? "" : "WHERE \(column) > ?"
                    var replacements: [(String, Data)] = []
                    var convertedBytes = 0
                    var lastKey: String?
                    do {
                        let rows = try Row.fetchCursor(db, sql: "SELECT \(column), contents FROM \(table) \(predicate) ORDER BY \(column) LIMIT 64",
                                                       arguments: after.map { [$0] } ?? [])
                        while convertedBytes < 4 * 1024 * 1024, let row = try rows.next() {
                            try Task.checkCancellation()
                            let key = try row.decode(String.self, atIndex: 0)
                            let data = try row.decode(Data.self, atIndex: 1)
                            lastKey = key
                            if data.starts(with: marker) { _ = try cipher.open(data, table: table) }
                            else {
                                // An invalid envelope header must not be re-sealed as a legacy note.
                                _ = try JSONSerialization.jsonObject(with: data)
                                let sealed = try cipher.seal(data, table: table)
                                replacements.append((key, sealed))
                                convertedBytes += sealed.count
                            }
                        }
                    }
                    guard let lastKey else { break }
                    after = lastKey
                    // Finish the read cursor before updating its table.
                    for (key, sealed) in replacements {
                        try db.execute(sql: "UPDATE \(table) SET contents = ? WHERE \(column) = ?", arguments: [sealed, key])
                        changed = true
                    }
                }
            }
            try db.execute(sql: "UPDATE notes SET title = '', searchText = '' WHERE title != '' OR searchText != ''")
            if changed || db.changesCount > 0 {
                try db.execute(sql: "INSERT OR REPLACE INTO note_cipher_cleanup (id, generation) VALUES (1, ?)", arguments: [UUID().uuidString])
            }
            return try String.fetchOne(db, sql: "SELECT generation FROM note_cipher_cleanup WHERE id = 1")
        }
        guard let cleanup else { return }
        try queue.writeWithoutTransaction { db in
            func truncateWAL() throws {
                guard let result = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)"),
                      result[0] as Int == 0 else { throw NoteStoreError.conflict }
            }
            try truncateWAL()
            try db.execute(sql: "VACUUM")
            try truncateWAL()
            try db.execute(sql: "DELETE FROM note_cipher_cleanup WHERE id = 1 AND generation = ?", arguments: [cleanup])
        }
    }
}
