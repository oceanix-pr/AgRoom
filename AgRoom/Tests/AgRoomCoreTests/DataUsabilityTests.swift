import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Database and MCP usability regressions")
struct DataUsabilityTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("data-usability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("User databases are physically separate and duplicate creation never alters existing content")
    func databaseOwnership() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let personal = try DatabaseWorkbench.createDatabase(name: "notes", space: .personal, baseDirectory: root)
        let work = try DatabaseWorkbench.createDatabase(name: "notes", space: .work, baseDirectory: root)
        #expect(personal != work)
        let queue = try DatabaseQueue(path: work.path)
        try queue.write { try $0.execute(sql: "PRAGMA user_version=7; CREATE TABLE secret (value TEXT); INSERT INTO secret VALUES ('work only')") }
        #expect(throws: DatabaseWorkbench.WorkbenchError.self) {
            try DatabaseWorkbench.createDatabase(name: "notes", space: .work, baseDirectory: root)
        }
        #expect(try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 7)
        #expect(DatabaseWorkbench.listUserDatabases(space: .personal, baseDirectory: root) == [personal])
        #expect(DatabaseWorkbench.listUserDatabases(space: .work, baseDirectory: root) == [work])
        for name in ["../escape", "x/y", "x\\y", "bad\0name"] {
            #expect(throws: DatabaseWorkbench.WorkbenchError.self) {
                try DatabaseWorkbench.createDatabase(name: name, space: .work, baseDirectory: root)
            }
        }
    }

    @Test("Explicit import includes committed WAL data and preserves its source")
    func importWAL() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("existing.sqlite")
        let queue = try DatabaseQueue(path: source.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE records (value TEXT); INSERT INTO records VALUES ('committed')")
        }
        #expect(FileManager.default.fileExists(atPath: source.path + "-wal"))
        let destination = try DatabaseWorkbench.importDatabase(from: source, space: .personal, baseDirectory: root)
        let copy = try DatabaseQueue(path: destination.path)
        #expect(try copy.read { try String.fetchOne($0, sql: "SELECT value FROM records") } == "committed")
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT value FROM records") } == "committed")
        #expect(throws: DatabaseWorkbench.WorkbenchError.self) {
            try DatabaseWorkbench.importDatabase(from: source, space: .personal, baseDirectory: root)
        }
    }

    @Test("Deleting a user database closes its cached WAL connection and preserves the other space")
    func deleteLocalDatabase() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let work = try DatabaseWorkbench.createDatabase(name: "notes", space: .work, baseDirectory: root)
        let personal = try DatabaseWorkbench.createDatabase(name: "notes", space: .personal, baseDirectory: root)
        let setup = try DatabaseQueue(path: work.path)
        try setup.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=WAL") }
        try setup.close()
        let workbench = DatabaseWorkbench()
        _ = try workbench.execute(at: work.path, sql: "CREATE TABLE records (value TEXT)")
        _ = try workbench.execute(at: work.path, sql: "INSERT INTO records VALUES ('owned')")
        #expect(FileManager.default.fileExists(atPath: work.path + "-wal"))
        try workbench.deleteDatabase(at: work, space: .work, baseDirectory: root)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: work.path + suffix))
        }
        #expect(FileManager.default.fileExists(atPath: personal.path))
        #expect(DatabaseWorkbench.listUserDatabases(space: .work, baseDirectory: root).isEmpty)
        let fresh = try DatabaseWorkbench.createDatabase(name: "notes", space: .work, baseDirectory: root)
        #expect(try workbench.tables(at: fresh.path).isEmpty)
    }

    @Test("Local deletion refuses other spaces, app databases, linked files and active leases without losing data")
    func deleteLocalDatabaseBoundaries() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let work = try DatabaseWorkbench.createDatabase(name: "owned", space: .work, baseDirectory: root)
        let personal = try DatabaseWorkbench.createDatabase(name: "private", space: .personal, baseDirectory: root)
        let appDatabase = root.appendingPathComponent("work.sqlite")
        try Data("protected".utf8).write(to: appDatabase)
        let workbench = DatabaseWorkbench()
        for protected in [personal, appDatabase] {
            #expect(throws: DatabaseWorkbench.WorkbenchError.self) {
                try workbench.deleteDatabase(at: protected, space: .work, baseDirectory: root)
            }
            #expect(FileManager.default.fileExists(atPath: protected.path))
        }
        let linked = work.deletingLastPathComponent().appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: personal)
        #expect(throws: DatabaseWorkbench.WorkbenchError.self) {
            try workbench.deleteDatabase(at: linked, space: .work, baseDirectory: root)
        }
        #expect(DatabaseWorkbench.listUserDatabases(space: .work, baseDirectory: root) == [work])
        let sidecar = URL(fileURLWithPath: work.path + "-wal")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: personal)
        #expect(throws: DatabaseWorkbench.WorkbenchError.self) {
            try workbench.deleteDatabase(at: work, space: .work, baseDirectory: root)
        }
        try FileManager.default.removeItem(at: sidecar)
        let lease = try ResourceMaintenance.Lease(key: work.path, exclusive: false)
        withExtendedLifetime(lease) {
            #expect(throws: MaintenanceError.self) {
                try workbench.deleteDatabase(at: work, space: .work, baseDirectory: root)
            }
        }
        #expect(FileManager.default.fileExists(atPath: work.path))
        #expect(FileManager.default.fileExists(atPath: personal.path))
    }

    @MainActor @Test("Remote workspace selects saved connections, invalidates edited metadata and clears deleted selections")
    func remoteConnectionLifecycle() async throws {
        let queue = try DatabaseQueue()
        try await queue.write { try MySQLConnectorService.createSchema($0) }
        let secrets = ProbeCredentials()
        let service = MySQLConnectorService(databaseQueue: queue, space: .work, credentials: secrets, client: BrowserMySQLProbe())
        var draft = MySQLConnectionConfig()
        draft.name = "First"; draft.database = "first"; draft.username = "reader"
        let first = try await service.save(draft, password: "fixture", creating: true)
        let model = MySQLConnectionsModel(service: service)
        defer { model.cancel() }
        await model.reload(selecting: first.id)
        try await waitForMetadata(model)
        #expect(model.selected == first.id && model.tables?.rows.first?.id == "first_table")
        #expect(model.columns?.rows.first?.id == "first_column")
        var edited = first; edited.database = "updated"
        let changed = try await service.save(edited, password: "replacement", creating: false)
        await model.reload()
        #expect(model.tables == nil && model.columns == nil && model.selectedTable == nil)
        try await waitForMetadata(model)
        #expect(model.tables?.rows.first?.id == "updated_table")
        #expect(model.columns?.rows.first?.id == "updated_column")
        #expect(model.status(for: changed) == .verified)
        draft.id = UUID(); draft.name = "Second"; draft.database = "second"
        let second = try await service.save(draft, password: "fixture", creating: true)
        await model.reload(selecting: second.id)
        try await waitForMetadata(model)
        #expect(model.selected == second.id && model.tables?.rows.first?.id == "second_table")

        try await queue.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_delete BEFORE DELETE ON mysql_connections BEGIN SELECT RAISE(ABORT,'fixture'); END")
        }
        await model.delete(second)
        #expect(model.error != nil && model.connections.contains(second))
        #expect(try await service.connection(id: second.id) == second)
        #expect(secrets.count == 2)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER refuse_delete") }
        await model.delete(second)
        try await waitForMetadata(model)
        #expect(model.selected == changed.id && !model.connections.contains(second))
        #expect(secrets.count == 1)
        await model.delete(changed)
        #expect(model.connections.isEmpty && model.selected == nil)
        #expect(model.tables == nil && model.columns == nil && model.selectedTable == nil)
        #expect(secrets.count == 0)
    }

    @MainActor private func waitForMetadata(_ model: MySQLConnectionsModel) async throws {
        for _ in 0..<200 {
            if !model.busy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!model.busy && model.columns != nil, "Remote metadata did not load: \(model.error ?? "no error")")
    }

    @Test("SQLite classifies the prepared statement and bindings, confirms writes, and blocks database escapes")
    func statementAccess() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = try DatabaseWorkbench.createDatabase(name: "query", space: .work, baseDirectory: root).path
        let personalPath = try DatabaseWorkbench.createDatabase(name: "query", space: .personal, baseDirectory: root).path
        let workbench = DatabaseWorkbench()
        _ = try workbench.execute(at: path, sql: "CREATE TABLE t (value INTEGER)")
        _ = try workbench.execute(at: path, sql: "INSERT INTO t VALUES (1),(2)")
        _ = try workbench.execute(at: personalPath, sql: "CREATE TABLE t (value INTEGER)")
        _ = try workbench.execute(at: personalPath, sql: "INSERT INTO t VALUES (99)")
        #expect(try workbench.execute(at: path, sql: "SELECT value FROM t ORDER BY value").rows == [["1"], ["2"]])
        let clipped = try workbench.execute(at: path, sql: "SELECT printf('%050000d', 1)")
        #expect(clipped.truncated && (clipped.rows.first?.first?.utf8.count ?? 0) == 16 * 1024)
        let tool = SQLQueryTool(workbench: workbench, databasePath: path)
        let commentedRead = #"{"sql":"-- DELETE FROM t;\n /* PRAGMA writable_schema=ON */ SELECT value FROM t WHERE value = ?","parameters":[2]}"#
        #expect(!tool.requiresConfirmation(argumentsJSON: commentedRead))
        #expect(tool.permissionClass(argumentsJSON: commentedRead) == .readOnly)
        #expect(tool.sideEffectClass(argumentsJSON: commentedRead) == .readOnly)
        #expect(try await tool.execute(argumentsJSON: commentedRead).contains("2"))
        let namedRead = #"{"sql":"WITH n AS (SELECT :value AS value) SELECT value FROM n","parameters":{"value":7}}"#
        #expect(!tool.requiresConfirmation(argumentsJSON: namedRead))
        #expect(tool.permissionClass(argumentsJSON: namedRead) == .readOnly)
        #expect(try await tool.execute(argumentsJSON: namedRead).contains("7"))
        #expect(!tool.requiresConfirmation(argumentsJSON: #"{"sql":"EXPLAIN DELETE FROM t WHERE value=1"}"#))
        #expect(try workbench.execute(at: path, sql: "EXPLAIN DELETE FROM t WHERE value=1").isRead)
        #expect(tool.requiresConfirmation(argumentsJSON: #"{"sql":"WITH n AS (SELECT 1) DELETE FROM t"}"#))
        #expect(tool.requiresConfirmation(argumentsJSON: #"{"sql":"PRAGMA user_version=8"}"#))
        #expect(tool.requiresConfirmation(argumentsJSON: #"{"sql":"PRAGMA table_info(t)"}"#))
        #expect(!tool.requiresConfirmation(argumentsJSON: #"{"sql":"/* read */ SELECT * FROM t"}"#))
        let boundWrite = #"{"sql":"INSERT INTO t(value) VALUES (?)","parameters":[3]}"#
        #expect(tool.requiresConfirmation(argumentsJSON: boundWrite))
        #expect(tool.permissionClass(argumentsJSON: boundWrite) == .externalEffect)
        #expect(tool.sideEffectClass(argumentsJSON: boundWrite) == .nonIdempotentWrite)
        await #expect(throws: DatabaseWorkbench.WorkbenchError.self) {
            try await tool.execute(argumentsJSON: boundWrite)
        }
        await #expect(throws: DatabaseWorkbench.WorkbenchError.self) {
            try await tool.execute(argumentsJSON: boundWrite, authorizationKey: nil, permittedSideEffectClass: .readOnly)
        }
        await #expect(throws: DatabaseWorkbench.WorkbenchError.self) {
            try await tool.execute(argumentsJSON: #"{"sql":"PRAGMA user_version=9"}"#,
                authorizationKey: nil, permittedSideEffectClass: .readOnly)
        }
        #expect(DispatcherEngine.confirmationRequirement(
            ToolCallRaw(id: "read", name: "sql_query", argumentsJSON: commentedRead),
            toolsByName: ["sql_query": tool], authorizedKeys: []
        ) == nil)
        #expect(DispatcherEngine.confirmationRequirement(
            ToolCallRaw(id: "write", name: "sql_query", argumentsJSON: boundWrite),
            toolsByName: ["sql_query": tool], authorizedKeys: []
        ) != nil)
        let multi = #"{"sql":"SELECT 1; DELETE FROM t WHERE value=2"}"#
        #expect(tool.requiresConfirmation(argumentsJSON: multi))
        #expect(tool.permissionClass(argumentsJSON: multi) == .externalEffect)
        await #expect(throws: (any Error).self) { try await tool.execute(argumentsJSON: multi) }
        let missingBinding = #"{"sql":"SELECT ?","parameters":[]}"#
        #expect(tool.requiresConfirmation(argumentsJSON: missingBinding))
        #expect(tool.sideEffectClass(argumentsJSON: missingBinding) == .nonIdempotentWrite)
        await #expect(throws: (any Error).self) { try await tool.execute(argumentsJSON: missingBinding) }
        let injection = #"{"sql":"SELECT ? AS value","parameters":["1; DELETE FROM t"]}"#
        #expect(!tool.requiresConfirmation(argumentsJSON: injection))
        #expect(try await tool.execute(argumentsJSON: injection).contains("1; DELETE FROM t"))
        #expect(try workbench.execute(at: personalPath, sql: "SELECT value FROM t").rows == [["99"]])
        let otherSpace = "ATTACH '\(personalPath)' AS personal"
        #expect(tool.requiresConfirmation(argumentsJSON: String(data: try JSONSerialization.data(withJSONObject: ["sql": otherSpace]), encoding: .utf8)!))
        #expect(throws: DatabaseWorkbench.WorkbenchError.self) { try workbench.execute(at: path, sql: otherSpace) }
        workbench.readOnly = true
        #expect(try await workbench.executeAsync(at: path, sql: "WITH n AS (SELECT 1) SELECT * FROM n").isRead)
        #expect(throws: DatabaseWorkbench.WorkbenchError.self) { try workbench.execute(at: path, sql: "WITH n AS (SELECT 1) DELETE FROM t") }
        #expect(throws: DatabaseWorkbench.WorkbenchError.self) { try workbench.execute(at: path, sql: "PRAGMA user_version=8") }
        workbench.readOnly = false
        let result = try workbench.execute(at: path, sql: "WITH n AS (SELECT 1) DELETE FROM t WHERE value=1")
        #expect(!result.isRead && result.rowsAffected == 1)
        #expect(throws: (any Error).self) { try workbench.execute(at: path, sql: "SELECT 1; DELETE FROM t") }
        for sql in ["ATTACH ':memory:' AS other", "/* comment */ VACUUM INTO '/tmp/no-db-copy.sqlite'", "; -- comment\n ATTACH ':memory:' AS other"] {
            #expect(throws: DatabaseWorkbench.WorkbenchError.self) { try workbench.execute(at: path, sql: sql) }
        }
        #expect(try workbench.execute(at: path, sql: "SELECT COUNT(*) FROM t").rows == [["1"]])
        #expect(try workbench.execute(at: personalPath, sql: "SELECT value FROM t").rows == [["99"]])
    }

    @Test("SQL reads need no side-effect intent; approved writes stop when intent cannot be saved")
    func sqlJournalBoundary() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = try DatabaseWorkbench.createDatabase(name: "journal", space: .work, baseDirectory: root).path
        let workbench = DatabaseWorkbench()
        _ = try workbench.execute(at: path, sql: "CREATE TABLE t(value INTEGER)")
        let tool = SQLQueryTool(workbench: workbench, databasePath: path)
        let failureDirectory = root.appendingPathComponent("journal-after-approval")
        let journal = OperationJournal(directory: failureDirectory)
        let provider = CloudProvider(
            config: LLMProviderConfig(name: "offline", endpoint: "https://example.invalid/v1", model: "test"),
            apiKey: "unused",
            session: URLSession(configuration: .ephemeral)
        )
        let read = DispatcherEngine(provider: provider, tools: [tool], systemPrompt: "test", maxSteps: 1)
        read.operationJournal = journal
        let readOutcome = try await read.executeCommand(ToolCallRaw(id: "sql-read", name: "sql_query", argumentsJSON: #"{"sql":"SELECT COUNT(*) FROM t"}"#))
        if case .finished = readOutcome {} else { Issue.record("Expected a read result without confirmation") }
        #expect(read.takeSnapshot().trace.last?.succeeded == true)
        #expect(!read.isJournalUnavailable)

        let write = DispatcherEngine(provider: provider, tools: [tool], systemPrompt: "test", maxSteps: 1)
        write.operationJournal = journal
        let pending = try await write.executeCommand(ToolCallRaw(id: "sql-write", name: "sql_query", argumentsJSON: #"{"sql":"INSERT INTO t VALUES (?)","parameters":[1]}"#))
        if case .needsConfirmation = pending {} else { Issue.record("SQL write bypassed confirmation") }
        let approval = try #require(write.pendingApprovalID)
        // The journal was healthy when approval was requested. Break its
        // directory only after approval so this exercises the intent barrier.
        try Data("file, not directory".utf8).write(to: failureDirectory)
        _ = try await write.resume(.confirmed(approvalID: approval, approved: true, alwaysAllow: false, persistRule: false))
        #expect(write.takeSnapshot().trace.last?.succeeded == false)
        #expect(write.isJournalUnavailable)
        #expect(try workbench.execute(at: path, sql: "SELECT COUNT(*) FROM t").rows == [["0"]])

        // A journal that is already unreadable fails closed before asking
        // for approval; it cannot present a card for an impossible write.
        let blockedJournal = OperationJournal(directory: failureDirectory)
        let blocked = DispatcherEngine(provider: provider, tools: [tool], systemPrompt: "test", maxSteps: 1)
        blocked.operationJournal = blockedJournal
        _ = try await blocked.executeCommand(ToolCallRaw(id: "sql-blocked", name: "sql_query",
            argumentsJSON: #"{"sql":"INSERT INTO t VALUES (?)","parameters":[3]}"#))
        #expect(blocked.pendingApprovalID == nil)
        #expect(blocked.takeSnapshot().trace.last?.succeeded == false)
        #expect(blocked.isJournalUnavailable)
        #expect(try workbench.execute(at: path, sql: "SELECT COUNT(*) FROM t").rows == [["0"]])

        let durable = DispatcherEngine(provider: provider, tools: [tool], systemPrompt: "test", maxSteps: 1)
        let durableJournal = OperationJournal(directory: root.appendingPathComponent("journal-valid"))
        durable.operationJournal = durableJournal
        let writeArguments = #"{"sql":"INSERT INTO t VALUES (?)","parameters":[2]}"#
        let durablePending = try await durable.executeCommand(ToolCallRaw(id: "sql-durable", name: "sql_query", argumentsJSON: writeArguments))
        if case .needsConfirmation = durablePending {} else { Issue.record("SQL write bypassed confirmation") }
        let durableApproval = try #require(durable.pendingApprovalID)
        _ = try await durable.resume(.confirmed(approvalID: durableApproval, approved: true, alwaysAllow: false, persistRule: false))
        #expect(durable.takeSnapshot().trace.last?.succeeded == true)
        #expect(durableJournal.unresolvedOperationIDs().isEmpty)
        #expect(try workbench.execute(at: path, sql: "SELECT value FROM t").rows == [["2"]])
    }

    @Test("Expensive SQL times out, cancellation interrupts its VM, and the connection remains usable")
    func queryBounds() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = try DatabaseWorkbench.createDatabase(name: "query", space: .work, baseDirectory: root).path
        let sql = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT sum(x) FROM n"
        let bounded = DatabaseWorkbench(queryTimeout: 0.02)
        do { _ = try bounded.execute(at: path, sql: sql); Issue.record("Expected timeout") }
        catch let error as DatabaseWorkbench.WorkbenchError { if case .queryTimedOut = error {} else { Issue.record("Unexpected error") } }
        let workbench = DatabaseWorkbench()
        let task = Task { try await workbench.executeAsync(at: path, sql: sql) }
        try await Task.sleep(for: .milliseconds(30))
        let start = Date(); task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(try workbench.execute(at: path, sql: "SELECT 3").rows == [["3"]])
    }

    @Test("MCP import accepts common HTTP configurations without granting tools or persisting tokens")
    func mcpImport() throws {
        let imported = try MCPConnectionImport.parse(#"{"mcpServers":{"Memonta":{"url":"http://127.0.0.1:42817/mcp","headers":{"Authorization":"Bearer fixture-token"}},"Remote":{"type":"http","url":"https://example.com/mcp"}}}"#)
        #expect(imported.map(\.config.name) == ["Memonta", "Remote"])
        #expect(imported.first?.token == "fixture-token")
        #expect(imported.first?.config.authentication == .bearer)
        #expect(imported.allSatisfy { $0.config.tools.isEmpty && $0.config.selectedToolNames.isEmpty })
        #expect(!String(decoding: try JSONEncoder().encode(imported[0].config), as: UTF8.self).contains("fixture-token"))
        #expect(try MCPConnectionImport.parse("https://example.com/mcp").count == 1)
        for text in [
            #"{"mcpServers":{"local":{"command":"node","args":["server.js"]}}}"#,
            #"{"url":"https://example.com/mcp","type":"sse"}"#,
            #"{"url":"https://example.com/mcp","headers":{"X-API-Key":"secret"}}"#,
            #"{"url":"https://example.com/mcp","headers":{"Authorization":"Bearer ${TOKEN}"}}"#,
            "http://remote.example.com/mcp", "https://user:password@example.com/mcp", "https://example.com/mcp?token=secret"
        ] { #expect(throws: MCPError.self) { try MCPConnectionImport.parse(text) } }
    }

    @Test("MySQL trims connection drafts and rejects malformed hosts without leaking diagnostics")
    func mysqlValidation() throws {
        var config = MySQLConnectionConfig()
        config.name = "  Test  "; config.host = " [::1] "; config.database = " db "; config.username = " user "
        let normalized = config.normalized
        #expect(normalized.name == "Test" && normalized.host == "::1" && normalized.database == "db" && normalized.username == "user")
        try normalized.validate()
        for host in ["host:3306", "http://localhost", "user@localhost", "bad host", "bad\nhost"] {
            var invalid = normalized; invalid.host = host
            #expect(throws: MySQLConnectorError.self) { try invalid.validate() }
        }
    }

    @Test("A saved MySQL test cannot publish success after its connection is changed")
    func staleMySQLTest() async throws {
        let queue = try DatabaseQueue()
        try await queue.write { try MySQLConnectorService.createSchema($0) }
        let client = PausedMySQLProbe()
        let service = MySQLConnectorService(databaseQueue: queue, space: .work, credentials: ProbeCredentials(), client: client)
        var draft = MySQLConnectionConfig()
        draft.name = "Probe"; draft.database = "demo"; draft.username = "reader"
        let saved = try await service.save(draft, password: "fixture", creating: true)
        let test = Task { try await service.test(saved, password: nil) }
        defer { test.cancel() }
        for _ in 0..<200 {
            if await client.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await client.started)
        var changed = saved; changed.name = "Updated"
        _ = try await service.save(changed, password: nil, creating: false)
        await client.release()
        do { try await test.value; Issue.record("Stale probe reported success") }
        catch let error as MySQLConnectorError { #expect(error.code == .changed) }
    }

    @Test("App icon colors persist per space, survive updates and backup, and leave definitions unchanged")
    func iconColor() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let personal = NativeAppStore(directoryURL: root.appendingPathComponent("personal"), space: .personal)
        let work = NativeAppStore(directoryURL: root.appendingPathComponent("work"), space: .work)
        var definition = try NativeAppTemplates.note()
        try await personal.install(definition, replacing: nil)
        try await work.install(definition, replacing: nil)
        let original = try await personal.load(id: definition.id)
        try await personal.setIconColor(.green, id: definition.id)
        let reopened = NativeAppStore(directoryURL: personal.directoryURL, space: .personal)
        #expect(try await reopened.catalog().apps.first?.iconColor == .green)
        #expect(try await work.catalog().apps.first?.iconColor == .space)
        #expect(try await reopened.load(id: definition.id).revision == original.revision)
        definition.manifest.version += 1
        try await personal.install(definition, replacing: original.revision)
        #expect(try await personal.catalog().apps.first?.iconColor == .green)
        let backup = try await personal.backup(id: definition.id, space: .personal)
        let decoded = try NativeAppBackup.decode(backup.encoded())
        let restored = NativeAppStore(directoryURL: root.appendingPathComponent("restored"), space: .personal)
        try await restored.restore(decoded, space: .personal, replacing: nil)
        #expect(try await restored.catalog().apps.first?.iconColor == .green)
        try await personal.setIconColor(.space, id: definition.id)
        #expect(try await personal.catalog().apps.first?.iconColor == .space)
        let file = personal.directoryURL.appendingPathComponent(definition.id).appendingPathComponent("appearance.json")
        try Data("broken".utf8).write(to: file)
        let damaged = try await personal.catalog()
        #expect(damaged.invalidIDs.isEmpty && damaged.apps.first?.iconColorNeedsReset == true)
        try await personal.setIconColor(.blue, id: definition.id)
        #expect(try await personal.catalog().apps.first?.iconColor == .blue)
    }
}

private actor PausedMySQLProbe: MySQLMetadataClient {
    private(set) var started = false
    private var released = false
    func release() { released = true }
    func read(config: MySQLConnectionConfig, password: String, table: String?) async throws -> HostDataTable {
        started = true
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        return HostDataTable(columns: ["name"], rows: [])
    }
}

private final class ProbeCredentials: DatabaseCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var count: Int { lock.withLock { values.count } }
    func read(account: String) -> String? { lock.withLock { values[account] } }
    func save(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
    func delete(account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}

private actor BrowserMySQLProbe: MySQLMetadataClient {
    func read(config: MySQLConnectionConfig, password: String, table: String?) async throws -> HostDataTable {
        let name = config.database + (table == nil ? "_table" : "_column")
        return HostDataTable(columns: ["name"], rows: [.init(id: name, title: name, content: name, fields: ["name": .string(name)])])
    }
}
