import Foundation
import GRDB

public struct MySQLConnectionConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var revision: UUID = UUID()
    public var name: String = ""
    public var host: String = "localhost"
    public var port: Int = 3306
    public var database: String = ""
    public var username: String = ""
    public var requiresTLS: Bool = true
    public var credentialID: UUID?
    public init() {}

    public var normalized: Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        value.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.host.hasPrefix("["), value.host.hasSuffix("]") { value.host = String(value.host.dropFirst().dropLast()) }
        return value
    }

    public func validate() throws {
        let names = [name, host, database, username]
        guard names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              (1...65535).contains(port), !host.contains(where: { $0.isWhitespace || "/@?#\\".contains($0) }),
              !host.contains(":") || host.filter({ $0 == ":" }).count >= 2,
              requiresTLS || ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) else {
            throw MySQLConnectorError(.invalidConfiguration)
        }
    }
}

public struct MySQLConnectorError: Error, Sendable {
    public enum Code: String, CaseIterable, Sendable {
        case invalidConfiguration, changed, credentialsRequired, storage, connection, timeout, tooLarge
        case authentication, tls, databaseUnavailable, accessDenied, hostResolution
    }
    public let code: Code
    public var localizationKey: String { "mysql.error." + code.rawValue }
    public init(_ code: Code) { self.code = code }
}

protocol DatabaseCredentialStore: Sendable {
    func read(account: String) -> String?
    func save(_ value: String, account: String) throws
    func delete(account: String) throws
}
private struct DatabaseKeychainStore: DatabaseCredentialStore {
    func read(account: String) -> String? { KeychainService.getString(account: account) }
    func save(_ value: String, account: String) throws { try KeychainService.setString(value, account: account) }
    func delete(account: String) throws { try KeychainService.delete(account: account) }
}

public protocol MySQLMetadataClient: Sendable {
    func read(config: MySQLConnectionConfig, password: String, table: String?) async throws -> HostDataTable
}

/// Credentials and connections belong to exactly one space. No connection or secret is cached.
public actor MySQLConnectorService {
    public nonisolated let space: AppSpace
    private let queue: DatabaseQueue
    private let credentials: any DatabaseCredentialStore
    private let client: any MySQLMetadataClient

    public init(databaseQueue: DatabaseQueue, space: AppSpace) {
        queue = databaseQueue; self.space = space
        credentials = DatabaseKeychainStore(); client = NativeMySQLMetadataClient()
    }
    init(databaseQueue: DatabaseQueue, space: AppSpace, credentials: any DatabaseCredentialStore,
         client: any MySQLMetadataClient) {
        queue = databaseQueue; self.space = space; self.credentials = credentials; self.client = client
    }
    static func createSchema(_ db: Database) throws {
        try db.create(table: "mysql_connections", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("configurationJSON", .text).notNull()
        }
    }
    public func connections() async throws -> [MySQLConnectionConfig] {
        do {
            return try await queue.read { db in
                try MySQLConnectionRow.fetchAll(db).map { try $0.config() }.sorted { $0.name < $1.name }
            }
        } catch { throw safe(error) }
    }
    public func connection(id: UUID) async throws -> MySQLConnectionConfig {
        do {
            guard let value = try await queue.read({ db in try MySQLConnectionRow.fetchOne(db, key: id.uuidString)?.config() }) else {
                throw MySQLConnectorError(.changed)
            }
            return value
        } catch { throw safe(error) }
    }
    @discardableResult
    public func save(_ input: MySQLConnectionConfig, password: String?, creating: Bool) async throws -> MySQLConnectionConfig {
        try Task.checkCancellation()
        var config = input.normalized
        try config.validate()
        let previous = try await connections().first { $0.id == input.id }
        try Task.checkCancellation()
        guard creating ? previous == nil : previous?.revision == input.revision else { throw MySQLConnectorError(.changed) }
        var freshCredential: UUID?
        if let password {
            guard password.utf8.count <= 4096, !password.contains("\0") else { throw MySQLConnectorError(.invalidConfiguration) }
            let credential = UUID()
            do { try credentials.save(password, account: account(config.id, credential)) }
            catch { throw MySQLConnectorError(.storage) }
            config.credentialID = credential; freshCredential = credential
        } else {
            guard let previous, previous.host == config.host, previous.port == config.port,
                  previous.username == config.username, previous.database == config.database,
                  previous.requiresTLS == config.requiresTLS, let id = previous.credentialID,
                  credentials.read(account: account(config.id, id)) != nil else { throw MySQLConnectorError(.credentialsRequired) }
            config.credentialID = previous.credentialID
        }
        config.revision = UUID()
        let saved = config
        do {
            let payload = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
            try await queue.maintenanceWrite { db in
                try Task.checkCancellation()
                let current = try MySQLConnectionRow.fetchOne(db, key: saved.id.uuidString)?.config()
                guard creating ? current == nil : current?.revision == input.revision else { throw MySQLConnectorError(.changed) }
                let count = try MySQLConnectionRow.fetchCount(db)
                guard current != nil || count < 32 else { throw MySQLConnectorError(.tooLarge) }
                try MySQLConnectionRow(id: saved.id.uuidString, configurationJSON: payload).save(db)
            }
        } catch {
            if let freshCredential { cleanup(config.id, freshCredential) }
            throw safe(error)
        }
        if let old = previous?.credentialID, old != saved.credentialID { cleanup(saved.id, old) }
        return saved
    }
    public func delete(_ config: MySQLConnectionConfig) async throws {
        do {
            try await queue.maintenanceWrite { db in
                guard let current = try MySQLConnectionRow.fetchOne(db, key: config.id.uuidString)?.config(),
                      current.revision == config.revision else { throw MySQLConnectorError(.changed) }
                _ = try MySQLConnectionRow.deleteOne(db, key: config.id.uuidString)
            }
            if let id = config.credentialID { cleanup(config.id, id) }
        } catch { throw safe(error) }
    }
    public func test(_ config: MySQLConnectionConfig, password: String?) async throws {
        let config = config.normalized
        try config.validate()
        try Task.checkCancellation()
        let secret: String
        if let password {
            guard password.utf8.count <= 4096, !password.contains("\0") else { throw MySQLConnectorError(.invalidConfiguration) }
            secret = password
        }
        else { secret = try await passwordForCurrent(config) }
        _ = try await client.read(config: config, password: secret, table: nil)
        try Task.checkCancellation()
        if password == nil { _ = try await passwordForCurrent(config) }
    }
    public func metadata(_ config: MySQLConnectionConfig, table: String? = nil) async throws -> HostDataTable {
        if let table { guard !table.isEmpty, table.utf8.count <= 256, !table.contains("\0") else { throw MySQLConnectorError(.invalidConfiguration) } }
        let password = try await passwordForCurrent(config)
        try Task.checkCancellation()
        let result = try await client.read(config: config, password: password, table: table)
        // A changed connection cannot publish a late result or consume a stale approval.
        _ = try await passwordForCurrent(config)
        try Task.checkCancellation()
        try result.validate()
        return result
    }
    private func passwordForCurrent(_ config: MySQLConnectionConfig) async throws -> String {
        let current = try await connection(id: config.id)
        guard current == config else { throw MySQLConnectorError(.changed) }
        guard let id = current.credentialID, let value = credentials.read(account: account(current.id, id)) else {
            throw MySQLConnectorError(.credentialsRequired)
        }
        return value
    }
    private func account(_ connection: UUID, _ credential: UUID) -> String {
        "mysql.\(space.rawValue).\(connection.uuidString).\(credential.uuidString)"
    }
    private func cleanup(_ connection: UUID, _ credential: UUID) {
        do { try credentials.delete(account: account(connection, credential)) }
        catch { HubLogger.shared.warning("An unreferenced database credential could not be removed") }
    }
    private func safe(_ error: Error) -> MySQLConnectorError { error as? MySQLConnectorError ?? .init(.storage) }
}

private struct MySQLConnectionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mysql_connections"
    let id: String
    let configurationJSON: String
    func config() throws -> MySQLConnectionConfig {
        let config = try JSONDecoder().decode(MySQLConnectionConfig.self, from: Data(configurationJSON.utf8))
        guard config.id.uuidString == id else { throw MySQLConnectorError(.storage) }
        try config.validate()
        return config
    }
}
