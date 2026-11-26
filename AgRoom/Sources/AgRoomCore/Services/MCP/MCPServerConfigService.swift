import Foundation
import GRDB
import Darwin

internal protocol MCPCredentialStore: Sendable {
    func read(account: String) -> String?
    func save(_ value: String, account: String) throws
    func delete(account: String) throws
}

private struct MCPKeychainStore: MCPCredentialStore {
    func read(account: String) -> String? { KeychainService.getString(account: account) }
    func save(_ value: String, account: String) throws { try KeychainService.setString(value, account: account) }
    func delete(account: String) throws { try KeychainService.delete(account: account) }
}

/// A local receipt contains no submitted arguments, results or credentials.
public struct MCPUncertainSubmission: Identifiable, Sendable {
    public let id: String
    public let serverName: String
    public let toolName: String
    public let startedAt: Date
}

/// One database, one space. Hub constructs this service on demand; no global catalog/client cache.
public actor MCPServerConfigService {
    public nonisolated let space: AppSpace
    private let queue: DatabaseQueue
    private let credentials: any MCPCredentialStore

    public init(databaseQueue: DatabaseQueue, space: AppSpace) {
        queue = databaseQueue
        self.space = space
        credentials = MCPKeychainStore()
    }

    internal init(databaseQueue: DatabaseQueue, space: AppSpace, credentials: any MCPCredentialStore) {
        queue = databaseQueue
        self.space = space
        self.credentials = credentials
    }

    internal nonisolated static func createSchema(_ db: Database) throws {
        try db.create(table: "mcp_servers", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("configurationJSON", .text).notNull()
        }
        try createSubmissionSchema(db)
    }

    static func createSubmissionSchema(_ db: Database) throws {
        try db.create(table: "mcp_submissions", ifNotExists: true) { t in
            t.column("operationKey", .text).primaryKey()
            t.column("attempt", .text).notNull().unique()
            t.column("serverName", .text).notNull()
            t.column("toolName", .text).notNull()
            t.column("startedAt", .datetime).notNull()
            t.column("pid", .integer).notNull()
            t.column("uncertain", .boolean).notNull()
        }
    }

    func claimSubmission(server: MCPServerConfig, tool: MCPToolDescriptor, arguments: String) async throws -> String {
        let canonical = try MCPJSON.string(MCPJSON.object(arguments))
        let key = MCPJSON.digest(try MCPJSON.string([server.endpoint, tool.name, canonical]))
        let attempt = UUID().uuidString
        do {
            try await queue.maintenanceWrite { db in
                try db.execute(sql: """
                    INSERT INTO mcp_submissions (operationKey, attempt, serverName, toolName, startedAt, pid, uncertain)
                    VALUES (?, ?, ?, ?, ?, ?, 0) ON CONFLICT(operationKey) DO NOTHING
                    """, arguments: [key, attempt, server.name, tool.name, Date(), Int(getpid())])
                guard db.changesCount == 1 else { throw MCPError(.resultUnknown) }
            }
        } catch { throw Self.safeStorageError(error) }
        return attempt
    }

    func finishSubmission(_ attempt: String, uncertain: Bool) async throws {
        // Cancellation of the HTTP task must not cancel recording its final disposition.
        let queue = queue
        do {
            try await Task {
                try await queue.maintenanceWrite { db in
                    let sql = uncertain ? "UPDATE mcp_submissions SET uncertain = 1 WHERE attempt = ?" : "DELETE FROM mcp_submissions WHERE attempt = ?"
                    try db.execute(sql: sql, arguments: [attempt])
                }
            }.value
        } catch { throw Self.safeStorageError(error) }
    }

    private nonisolated static func canAcknowledge(_ row: Row) -> Bool {
        let marked: Bool = row["uncertain"]
        let pid: Int32 = row["pid"]
        return marked || (kill(pid, 0) != 0 && errno == ESRCH)
    }

    public func uncertainSubmissions() async throws -> [MCPUncertainSubmission] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mcp_submissions ORDER BY startedAt DESC")
                .filter(Self.canAcknowledge).map {
                    MCPUncertainSubmission(id: $0["attempt"], serverName: $0["serverName"], toolName: $0["toolName"], startedAt: $0["startedAt"])
                }
        }
    }

    /// Only the fixed-space settings UI can acknowledge a verified remote outcome.
    public func acknowledgeSubmission(_ attempt: String) async throws {
        try await queue.maintenanceWrite { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mcp_submissions WHERE attempt = ?", arguments: [attempt]),
                  Self.canAcknowledge(row) else { throw MCPError(.configurationChanged) }
            try db.execute(sql: "DELETE FROM mcp_submissions WHERE attempt = ?", arguments: [attempt])
        }
    }

    public func getAll() async throws -> [MCPServerConfig] {
        do {
            return try await queue.read { db in
                try MCPServerRow.fetchAll(db).map { try $0.decode() }.sorted { $0.name < $1.name }
            }
        } catch { throw Self.safeStorageError(error) }
    }

    private func fetch(_ id: UUID) async throws -> MCPServerConfig? {
        do {
            return try await queue.read { db in
                try MCPServerRow.fetchOne(db, key: id.uuidString)?.decode()
            }
        } catch { throw Self.safeStorageError(error) }
    }

    /// A new immutable Keychain entry is published by the DB transaction. Failed DB writes leave
    /// the old configuration/token intact. Revision checks also cover other service instances.
    @discardableResult
    public func save(_ input: MCPServerConfig, token: String? = nil, creating: Bool = false) async throws -> MCPServerConfig {
        var config = input
        config.name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(config)
        let previous = try await fetch(config.id)
        guard creating ? previous == nil : previous?.revision == input.revision else {
            throw MCPError(.configurationChanged)
        }
        let oldCredentialID = previous?.credentialID
        var newCredentialID: UUID?
        if config.authentication == .none {
            config.credentialID = nil
        } else if let token {
            try Self.validateToken(token)
            let id = UUID()
            do { try credentials.save(token, account: credentialAccount(serverID: config.id, credentialID: id)) }
            catch { throw MCPError(.storage) }
            config.credentialID = id
            newCredentialID = id
        } else {
            guard let previous, previous.endpoint == config.endpoint,
                  previous.authentication == config.authentication, let id = previous.credentialID,
                  credentials.read(account: credentialAccount(serverID: config.id, credentialID: id)) != nil else {
                throw MCPError(.credentialsRequired)
            }
            config.credentialID = id
        }
        config.revision = UUID()
        let saved = config
        do {
            let payload = try String(decoding: JSONEncoder().encode(saved), as: UTF8.self)
            try await queue.maintenanceWrite { db in
                let current = try MCPServerRow.fetchOne(db, key: saved.id.uuidString)?.decode()
                guard creating ? current == nil : current?.revision == input.revision else {
                    throw MCPError(.configurationChanged)
                }
                let others = try MCPServerRow.fetchAll(db).filter { $0.id != saved.id.uuidString }
                guard others.count < MCPServerConfig.maximumServers else { throw MCPError(.invalidConfiguration) }
                let enabledOthers = try others.map { try $0.decode() }.filter(\.isEnabled)
                let otherSelected = enabledOthers.reduce(0) { $0 + $1.selectedToolNames.count }
                guard otherSelected + (saved.isEnabled ? saved.selectedToolNames.count : 0)
                        <= MCPServerConfig.maximumSelectedTools else { throw MCPError(.invalidConfiguration) }
                let selectedBytes = enabledOthers.reduce(0) { $0 + $1.selectedDefinitionBytes }
                    + (saved.isEnabled ? saved.selectedDefinitionBytes : 0)
                guard selectedBytes <= MCPServerConfig.maximumSelectedDefinitionBytes else { throw MCPError(.toolBudget) }
                try MCPServerRow(id: saved.id.uuidString, configurationJSON: payload).save(db)
            }
        } catch {
            if let newCredentialID { removeCredential(serverID: config.id, id: newCredentialID) }
            throw Self.safeStorageError(error)
        }
        if let oldCredentialID, oldCredentialID != saved.credentialID {
            removeCredential(serverID: config.id, id: oldCredentialID)
        }
        return saved
    }

    public func delete(_ config: MCPServerConfig) async throws {
        do {
            let credential = try await queue.maintenanceWrite { db -> UUID? in
                guard let current = try MCPServerRow.fetchOne(db, key: config.id.uuidString)?.decode() else { return nil }
                guard current.revision == config.revision else { throw MCPError(.configurationChanged) }
                _ = try MCPServerRow.deleteOne(db, key: config.id.uuidString)
                return current.credentialID
            }
            if let credential { removeCredential(serverID: config.id, id: credential) }
        } catch { throw Self.safeStorageError(error) }
    }

    /// Test only the entered endpoint/credential; never silently transfer a saved token to a new URL.
    public func discover(config: MCPServerConfig, token: String?) async throws -> MCPToolCatalog {
        _ = try config.validatedEndpoint()
        let credential: String?
        if config.authentication == .none { credential = nil }
        else if let token { try Self.validateToken(token); credential = token }
        else {
            guard let saved = try await fetch(config.id), saved.revision == config.revision,
                  saved.endpoint == config.endpoint, saved.authentication == config.authentication else {
                throw MCPError(.credentialsRequired)
            }
            credential = try savedToken(saved)
        }
        let client = try MCPHTTPClient(config: config, token: credential)
        do {
            let catalog = try await client.discover()
            await client.close()
            return catalog
        } catch {
            await client.close()
            throw error
        }
    }

    internal func requireCurrent(_ snapshot: MCPServerConfig, tool: MCPToolDescriptor) async throws -> String? {
        guard let current = try await fetch(snapshot.id), current.isEnabled,
              current.selectedToolNames.contains(tool.name) else { throw MCPError(.unavailable) }
        guard current.revision == snapshot.revision, current.endpoint == snapshot.endpoint,
              current.tools.contains(where: { $0.fingerprint == tool.fingerprint }) else {
            throw MCPError(.configurationChanged)
        }
        return try savedToken(current)
    }

    private func savedToken(_ config: MCPServerConfig) throws -> String? {
        if config.authentication == .none { return nil }
        guard let id = config.credentialID,
              let token = credentials.read(account: credentialAccount(serverID: config.id, credentialID: id)) else {
            throw MCPError(.credentialsRequired)
        }
        try Self.validateToken(token)
        return token
    }

    internal nonisolated func credentialAccount(serverID: UUID, credentialID: UUID) -> String {
        "mcp.\(space.rawValue).\(serverID.uuidString).\(credentialID.uuidString)"
    }

    private func removeCredential(serverID: UUID, id: UUID) {
        do { try credentials.delete(account: credentialAccount(serverID: serverID, credentialID: id)) }
        catch { HubLogger.shared.warning("MCP credential cleanup failed; an unreferenced Keychain entry remains") }
    }

    private nonisolated static func validateToken(_ token: String) throws {
        guard !token.isEmpty, token.utf8.count <= 16_384,
              token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw MCPError(.credentialsRequired) }
    }

    internal nonisolated static func validate(_ config: MCPServerConfig) throws {
        _ = try config.validatedEndpoint()
        guard !config.name.isEmpty, config.name.utf8.count <= 256,
              !config.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              config.tools.count <= 256, config.rejectedToolCount >= 0,
              config.selectedToolNames.count <= MCPServerConfig.maximumSelectedTools,
              config.selectedToolNames.isSubset(of: Set(config.tools.map(\.name))),
              Set(config.tools.map(\.name)).count == config.tools.count else { throw MCPError(.invalidConfiguration) }
        for tool in config.tools {
            _ = try MCPToolDescriptor(name: tool.name, description: tool.description, inputSchemaJSON: tool.inputSchemaJSON)
        }
        guard try JSONEncoder().encode(config).count <= 2 * 1_024 * 1_024 else { throw MCPError(.catalogLimit) }
    }

    private nonisolated static func safeStorageError(_ error: Error) -> MCPError {
        (error as? MCPError) ?? MCPError(.storage)
    }
}

private struct MCPServerRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mcp_servers"
    let id: String
    let configurationJSON: String

    func decode() throws -> MCPServerConfig {
        let config = try JSONDecoder().decode(MCPServerConfig.self, from: Data(configurationJSON.utf8))
        guard config.id.uuidString == id else { throw MCPError(.storage) }
        try MCPServerConfigService.validate(config)
        return config
    }
}
