import Foundation
import GRDB
import Testing
import AppKit
import SwiftUI
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Native app host capabilities")
struct NativeAppCapabilityTests {
    @Test("DSL v3 rejects unknown capabilities, unsafe bindings and recursive workflows")
    func schema() throws {
        let app = try NativeAppTemplates.databaseMetadata()
        #expect(try NativeAppDefinition.decode(app.encoded()) == app)
        var invalid = app; invalid.manifest.dslVersion = 2
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.capabilities?["tables"]?.name = "shell_run"
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.capabilities?["tables"]?.resource = nil
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.actions["inspect"]?.steps = ["inspect"]
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.actions["load-columns"]?.inputs = ["table": .init(literal: .number(1))]
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.actions["export"]?.dataInputs = ["columns": "absent"]
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.actions["load-tables"]?.resultBindings = ["preview": "count"]
        #expect(throws: NativeAppError.self) { try invalid.validate() }
    }

    @Test("Database configuration and Keychain references remain isolated by space, with atomic stale-edit rejection")
    func connections() async throws {
        let secrets = MemoryDatabaseCredentials()
        let (queue, work, client) = try fixture(space: .work, secrets: secrets)
        let (_, personal, _) = try fixture(space: .personal, secrets: secrets)
        var input = config()
        let a = try await work.save(input, password: "work-test-password", creating: true)
        input.id = a.id
        let b = try await personal.save(input, password: "personal-test-password", creating: true)
        _ = try await work.metadata(a)
        #expect(await client.calls == 1)
        let json = try await queue.read { try String.fetchOne($0, sql: "SELECT configurationJSON FROM mysql_connections") }
        #expect(json?.contains("test-password") == false)
        #expect(secrets.accounts.allSatisfy { $0.hasPrefix("mysql.work.") || $0.hasPrefix("mysql.personal.") })
        var renamed = a; renamed.name = "Renamed"
        let changed = try await work.save(renamed, password: nil, creating: false)
        await #expect(throws: MySQLConnectorError.self) { _ = try await work.metadata(a) }
        await #expect(throws: MySQLConnectorError.self) { _ = try await work.save(a, password: "stale", creating: false) }
        try await queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_mysql_update BEFORE UPDATE ON mysql_connections BEGIN SELECT RAISE(ABORT,'fixture'); END")
        }
        await #expect(throws: MySQLConnectorError.self) { _ = try await work.save(changed, password: "must-not-publish", creating: false) }
        #expect(try await work.connection(id: changed.id) == changed)
        #expect(secrets.accounts.count == 2)
        try await queue.write { db in try db.execute(sql: "DROP TRIGGER fail_mysql_update") }
        var moved = changed; moved.host = "other.example.test"
        await #expect(throws: MySQLConnectorError.self) { _ = try await work.save(moved, password: nil, creating: false) }
        try await work.delete(changed)
        #expect(try await work.connections().isEmpty)
        #expect(try await personal.connections() == [b])
        #expect(secrets.accounts.count == 1)
        var insecure = config(); insecure.host = "db.example.test"; insecure.requiresTLS = false
        #expect(throws: MySQLConnectorError.self) { try insecure.validate() }
        for host in ["localhost", "127.0.0.1", "::1"] { insecure.host = host; try insecure.validate() }
    }

    @MainActor @Test("Host commands wait for identity-bound approval; denial stops the workflow and cannot authorize later steps")
    func runtimeWorkflow() async throws {
        let (_, mysql, client) = try fixture()
        let connection = try await mysql.save(config(), password: "test", creating: true)
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root, space: .personal)
        var definition = try NativeAppTemplates.databaseMetadata()
        definition.actions.removeValue(forKey: "export"); definition.scripts = nil
        definition.actions["inspect"]?.steps = ["load-columns", "copy"]
        definition.actions["copy"]?.inputs = ["text": .init(literal: .string("approved copy"))]
        try await store.install(definition, replacing: nil)
        let clipboard = CapabilityCounter()
        let bridge = NativeAppCapabilityBridge(space: .personal, resources: nil, mysql: mysql, platform: { _, _ in
            await clipboard.increment(); return HostCapabilityResult()
        })
        let runtime = NativeAppRuntime(definition: definition, space: .personal, store: store, capabilityBridge: bridge)
        await runtime.activate()
        runtime.selectResource("database", id: connection.id)
        runtime.perform("load-tables")
        try await until { runtime.pending != nil || !runtime.isBusy }
        #expect(await client.calls == 0)
        runtime.decide(try #require(runtime.pending), approved: true)
        try await until { !runtime.isBusy }
        #expect(runtime.error == nil)
        let query = try #require(runtime.queries["tables"])
        query.select(try #require(query.items.first).id)
        runtime.perform("inspect")
        try await until { runtime.pending != nil || !runtime.isBusy }
        let first = try #require(runtime.pending)
        runtime.decide(first, approved: true)
        try await until { runtime.pending != nil || !runtime.isBusy }
        let second = try #require(runtime.pending)
        #expect(first.id != second.id)
        runtime.decide(first, approved: true) // An old card cannot approve the clipboard operation.
        #expect(await clipboard.count == 0)
        runtime.decide(second, approved: false)
        try await until { !runtime.isBusy }
        #expect(await clipboard.count == 0)
        runtime.perform("copy")
        try await until { runtime.pending != nil || !runtime.isBusy }
        runtime.decide(try #require(runtime.pending), approved: true)
        try await until { !runtime.isBusy }
        #expect(await clipboard.count == 1)
        runtime.suspend()
        #expect(runtime.selectedResources.isEmpty && runtime.queries["columns"]?.dataset == nil)
    }

    @Test("Read-only mode, space mismatch and an updated definition cannot be bypassed by the capability bridge")
    func executionGuards() async throws {
        let (_, mysql, client) = try fixture()
        let connection = try await mysql.save(config(), password: "test", creating: true)
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root, space: .personal)
        let app = try NativeAppTemplates.databaseMetadata()
        try await store.install(app, replacing: nil)
        let workspace = try await store.workspace(for: app)
        let readOnly = NativeAppCapabilityBridge(space: .personal, resources: nil, mysql: mysql, permissionMode: .readOnly)
        let denied = try await readOnly.prepare(definition: app, workspace: workspace, actionID: "load-tables", inputs: [:], connection: connection)
        let outcome = try await denied.engine.executeCommand(denied.call)
        guard case .finished(_, _, let trace, _, _, _, _) = outcome else { Issue.record("Expected a mode denial"); return }
        let callsAfterDenial = await client.calls
        #expect(trace.last?.succeeded == false && callsAfterDenial == 0)
        let crossSpace = NativeAppCapabilityBridge(space: .work, resources: nil, mysql: mysql)
        await #expect(throws: NativeAppError.self) {
            _ = try await crossSpace.prepare(definition: app, workspace: workspace, actionID: "load-tables", inputs: [:], connection: connection)
        }
        let bridge = NativeAppCapabilityBridge(space: .personal, resources: nil, mysql: mysql)
        let command = try await bridge.prepare(definition: app, workspace: workspace, actionID: "load-tables", inputs: [:], connection: connection)
        _ = try await command.engine.executeCommand(command.call)
        let approval = try #require(command.engine.pendingApprovalID)
        let snapshot = try await store.load(id: app.id)
        var next = app; next.manifest.version += 1
        try await store.install(next, replacing: snapshot.revision)
        _ = try await command.engine.resume(.confirmed(approvalID: approval, approved: true, alwaysAllow: false, persistRule: false))
        #expect(await client.calls == 0)
    }

    @Test("Dynamic network arguments require fresh approval even for a public page read")
    func networkApproval() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root, space: .personal)
        var app = try NativeAppTemplates.databaseMetadata()
        app.capabilities?["copy"] = .init(name: "web.fetch")
        app.actions["copy"]?.inputs = ["url": .init(literal: .string("https://example.test/"))]
        try await store.install(app, replacing: nil)
        let workspace = try await store.workspace(for: app)
        let bridge = NativeAppCapabilityBridge(space: .personal, resources: nil)
        let command = try await bridge.prepare(definition: app, workspace: workspace, actionID: "copy",
            inputs: ["url": .string("https://example.test/")], connection: nil)
        let outcome = try await command.engine.executeCommand(command.call)
        guard case .needsConfirmation(_, _, _, let requirement) = outcome else {
            Issue.record("A network request bypassed approval"); return
        }
        #expect(requirement.kind == .hard)
        command.engine.revokeTaskAuthorization()
    }

    @MainActor @Test("Preview cannot contact host tools; partial transient data cannot enter Python")
    func previewAndData() async throws {
        let app = try NativeAppTemplates.databaseMetadata()
        let preview = NativeAppRuntime(definition: app, space: .personal, preview: true)
        await preview.activate(); preview.perform("load-tables")
        #expect(!preview.isBusy && preview.pending == nil && preview.connections.isEmpty)
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root, space: .personal)
        try await store.install(app, replacing: nil)
        let service = NativeAppScriptService(workspace: try await store.workspace(for: app))
        do {
            _ = try await service.prepare(definition: app, actionID: "export", inputs: [:], records: [:], files: [:],
                datasets: ["columns": HostDataTable(columns: [], rows: [], hasMore: true)])
            Issue.record("A partial table was accepted")
        } catch let error as NativeAppScriptError { #expect(error.code == .inputTruncated) }
    }

    private func config() -> MySQLConnectionConfig {
        var config = MySQLConnectionConfig(); config.name = "Fixture"; config.database = "fixture"; config.username = "reader"
        return config
    }

    @MainActor @Test("Metadata components render in narrow and regular windows",
        .enabled(if: ProcessInfo.processInfo.environment["AGROOM_NATIVE_APP_SNAPSHOT_DIR"] != nil))
    func renderMetadata() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AGROOM_NATIVE_APP_SNAPSHOT_DIR"])
        _ = NSApplication.shared
        let model = NativeAppRuntime(definition: try NativeAppTemplates.databaseMetadata(), space: .personal, preview: true)
        await model.activate()
        model.queries["columns"]?.replaceDataset(.init(columns: ["name", "type", "comment"], rows: [
            .init(id: "id", title: "id", content: "", fields: ["name": .string("id"), "type": .string("bigint"), "comment": .string("标识字段")]),
            .init(id: "title", title: "title", content: "", fields: ["name": .string("title"), "type": .string("varchar(255)"), "comment": .string("标题")])
        ]))
        for width in [480, 1100] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: NativeAppRenderer(model: model)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                defer { window.close() }
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("metadata-\(width)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test("A signed offline app function receives frozen host data and exports the actual metadata",
        .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"] != nil))
    func signedDataInput() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: .personal)
        let app = try NativeAppTemplates.databaseMetadata()
        try await store.install(app, replacing: nil)
        let workspace = try await store.workspace(for: app)
        let executor = try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs"), space: .personal)
        let service = NativeAppScriptService(workspace: workspace, executor: executor)
        let data = HostDataTable(columns: ["name", "type"], rows: [
            .init(id: "id", title: "id", content: "", fields: ["name": .string("id"), "type": .string("bigint")])
        ])
        let command = try await service.prepare(definition: app, actionID: "export", inputs: [:], records: [:], files: [:], datasets: ["columns": data])
        _ = try await command.engine.executeCommand(command.call)
        let id = try #require(command.engine.pendingApprovalID)
        _ = try await command.engine.resume(.confirmed(approvalID: id, approved: true, alwaysAllow: false, persistRule: false))
        let result = try await command.receipt.result()
        #expect(result.values["count"] == .number(1))
        #expect(result.values["preview"] == .string("id: bigint"))
        let artifact = try #require(result.artifacts.first { $0.name == "metadata.json" })
        #expect(try JSONDecoder().decode(HostDataTable.self, from: artifact.data) == data)
    }
    private func fixture(space: AppSpace = .personal, secrets: MemoryDatabaseCredentials = .init()) throws
        -> (DatabaseQueue, MySQLConnectorService, FixtureMySQLClient) {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let client = FixtureMySQLClient()
        return (queue, .init(databaseQueue: queue, space: space, credentials: secrets, client: client), client)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("app-host-" + UUID().uuidString) }
    @MainActor private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Host operation did not settle")
    }
}

private final class MemoryDatabaseCredentials: DatabaseCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    var accounts: [String] { lock.withLock { Array(storage.keys) } }
    func read(account: String) -> String? { lock.withLock { storage[account] } }
    func save(_ value: String, account: String) throws { lock.withLock { storage[account] = value } }
    func delete(account: String) throws { lock.withLock { _ = storage.removeValue(forKey: account) } }
}
private actor FixtureMySQLClient: MySQLMetadataClient {
    private(set) var calls = 0
    func read(config: MySQLConnectionConfig, password: String, table: String?) async throws -> HostDataTable {
        calls += 1
        let columns = NativeMySQLMetadataClient.query(table: table).columns
        let name = table == nil ? "demo" : "id"
        let fields = Dictionary(uniqueKeysWithValues: columns.map { ($0, NativeAppValue.string($0 == "name" ? name : "fixture")) })
        return .init(columns: columns, rows: [.init(id: name, title: name, content: "Fixture metadata", fields: fields)])
    }
}
private actor CapabilityCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
