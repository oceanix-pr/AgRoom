import Foundation
import Network
import Testing
@testable import AgRoomCore

@Suite("Native MySQL wire connector")
struct MySQLWireTests {
    @Test("A native connection authenticates, binds schema/table parameters and decodes table/column result sets")
    func metadataRoundTrip() async throws {
        let server = try MySQLWireFixture()
        try await server.start(); defer { server.stop() }
        var config = configuration(port: try #require(server.listener.port).rawValue)
        config.requiresTLS = false
        let client = NativeMySQLMetadataClient()
        let tables: HostDataTable
        do { tables = try await client.read(config: config, password: "fixture-password", table: nil) }
        catch {
            Issue.record("Wire stage: packets=\(server.receivedPackets), prepared=\(server.preparedSQL.count), executed=\(server.executedQueries)")
            throw error
        }
        #expect(tables.rows.first?.fields["name"] == .string("demo"))
        #expect(tables.rows.first?.fields["comment"] == .string("中文 ' comment"))
        let injection = "demo' OR 1=1 --"
        let columns = try await client.read(config: config, password: "fixture-password", table: injection)
        #expect(columns.rows.first?.fields["name"] == .string("id"))
        #expect(columns.rows.first?.fields["column-key"] == .string("PRI"))
        #expect(server.preparedSQL.count == 2)
        #expect(server.preparedSQL.allSatisfy { $0.contains("TABLE_SCHEMA = ?") && !$0.contains(injection) })
    }

    @Test("Required TLS fails before authentication when the server does not advertise TLS")
    func noDowngrade() async throws {
        let server = try MySQLWireFixture()
        try await server.start(); defer { server.stop() }
        let config = configuration(port: try #require(server.listener.port).rawValue)
        do {
            _ = try await NativeMySQLMetadataClient().read(config: config, password: "never-send-this", table: nil)
            Issue.record("A server without TLS was accepted")
        } catch let error as MySQLConnectorError {
            #expect(error.code == .tls, "Expected an immediate protocol/TLS rejection, not a timeout")
        }
        #expect(server.receivedPackets == 0)
    }

    @Test("Server authentication errors are categorized without exposing diagnostics", arguments: [UInt16(1045), 1044, 1049])
    func authenticationErrors(code: UInt16) async throws {
        let server = try MySQLWireFixture(authenticationError: code)
        try await server.start(); defer { server.stop() }
        var config = configuration(port: try #require(server.listener.port).rawValue)
        config.requiresTLS = false
        do {
            _ = try await NativeMySQLMetadataClient().read(config: config, password: "fixture", table: nil)
            Issue.record("Expected a server authentication error")
        } catch let error as MySQLConnectorError {
            let expected: MySQLConnectorError.Code = code == 1045 ? .authentication : (code == 1044 ? .accessDenied : .databaseUnavailable)
            #expect(error.code == expected)
        }
        #expect(server.preparedSQL.isEmpty)
    }

    @Test("Cancelling a silent MySQL handshake stops promptly")
    func cancellation() async throws {
        let server = try MySQLWireFixture(greeting: false)
        try await server.start(); defer { server.stop() }
        var config = configuration(port: try #require(server.listener.port).rawValue); config.requiresTLS = false
        let captured = config
        let task = Task { try await NativeMySQLMetadataClient().read(config: captured, password: "test", table: nil) }
        try await Task.sleep(for: .milliseconds(80))
        let start = Date(); task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request completed") }
        catch is CancellationError { }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    private func configuration(port: UInt16) -> MySQLConnectionConfig {
        var config = MySQLConnectionConfig()
        config.name = "Loopback fixture"; config.host = "127.0.0.1"; config.port = Int(port)
        config.database = "fixture"; config.username = "reader"
        return config
    }

    @Test("Cancelling in-flight queries settles driver promises before the event loop shuts down")
    func queryCancellation() async throws {
        let server = try MySQLWireFixture(respondToQueries: false)
        try await server.start(); defer { server.stop() }
        var config = configuration(port: try #require(server.listener.port).rawValue); config.requiresTLS = false
        let captured = config
        for index in 0..<4 {
            let task = Task { try await NativeMySQLMetadataClient().read(config: captured, password: "test", table: nil) }
            for _ in 0..<200 {
                if server.executedQueries > index { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(server.executedQueries > index)
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled query completed") }
            catch is CancellationError { }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Test-only protocol peer. Packet state belongs to the serial queue; metrics/start state use the lock.
private final class MySQLWireFixture: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "agroom.tests.mysql")
    private let lock = NSLock()
    private let greeting: Bool
    private let respondToQueries: Bool
    private let authenticationError: UInt16?
    private var sessions: [MySQLWireSession] = []
    private var started = false
    private var queries: [String] = []
    private var packets = 0
    private var executes = 0
    var preparedSQL: [String] { lock.withLock { queries } }
    var receivedPackets: Int { lock.withLock { packets } }
    var executedQueries: Int { lock.withLock { executes } }
    init(greeting: Bool = true, respondToQueries: Bool = true, authenticationError: UInt16? = nil) throws {
        self.greeting = greeting; self.respondToQueries = respondToQueries
        self.authenticationError = authenticationError
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [self] state in
                let result: Result<Void, any Error>
                switch state { case .ready: result = .success(()); case .failed(let error): result = .failure(error); default: return }
                let first = lock.withLock { () -> Bool in guard !started else { return false }; started = true; return true }
                if first { continuation.resume(with: result) }
            }
            listener.newConnectionHandler = { [self] connection in
                let session = MySQLWireSession(connection: connection, queue: queue, greeting: greeting, respondToQueries: respondToQueries,
                    authenticationError: authenticationError,
                    onPacket: { [self] in lock.withLock { packets += 1 } },
                    onExecute: { [self] in lock.withLock { executes += 1 } },
                    onQuery: { [self] query in lock.withLock { queries.append(query) } })
                lock.withLock { sessions.append(session) }
                session.start()
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        let current = lock.withLock { let current = sessions; sessions = []; return current }
        current.forEach { $0.connection.cancel() }
    }
}

private final class MySQLWireSession: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let greeting: Bool
    private let respondToQueries: Bool
    private let authenticationError: UInt16?
    private let onPacket: @Sendable () -> Void
    private let onExecute: @Sendable () -> Void
    private let onQuery: @Sendable (String) -> Void
    // Queue-confined protocol state.
    private var buffer = Data()
    private var authenticated = false
    private var names: [String] = []
    private var values: [String] = []
    init(connection: NWConnection, queue: DispatchQueue, greeting: Bool, respondToQueries: Bool, authenticationError: UInt16?,
         onPacket: @escaping @Sendable () -> Void, onExecute: @escaping @Sendable () -> Void, onQuery: @escaping @Sendable (String) -> Void) {
        self.connection = connection; self.queue = queue; self.greeting = greeting; self.onPacket = onPacket; self.onQuery = onQuery
        self.respondToQueries = respondToQueries; self.onExecute = onExecute
        self.authenticationError = authenticationError
    }
    func start() {
        connection.stateUpdateHandler = { [self] state in
            if case .ready = state {
                if greeting { send(Self.packet(Self.handshake(), sequence: 0)) }
                receive()
            }
        }
        connection.start(queue: queue)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { buffer.append(data); consume() }
            if !complete, error == nil { receive() }
        }
    }
    private func consume() {
        while buffer.count >= 4 {
            let bytes = Array(buffer.prefix(4))
            let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16
            guard buffer.count >= length + 4 else { return }
            let payload = Data(buffer.dropFirst(4).prefix(length)); buffer = Data(buffer.dropFirst(length + 4))
            // Closing before authentication may send COM_QUIT. It contains no handshake or credential data.
            if !authenticated, payload == Data([0x01]) { continue }
            onPacket()
            if !authenticated {
                authenticated = true
                let response: Data
                if let code = authenticationError {
                    response = Data([0xff, UInt8(truncatingIfNeeded: code), UInt8(code >> 8), 0x23])
                        + Data("HY000private fixture diagnostic".utf8)
                } else { response = Data([0,0,0,2,0,0,0]) }
                send(Self.packet(response, sequence: 2)); continue
            }
            guard let command = payload.first else { continue }
            switch command {
            case 0x16:
                let sql = String(decoding: payload.dropFirst(), as: UTF8.self); onQuery(sql)
                if sql.contains("information_schema.COLUMNS") {
                    names = ["name","type","nullable","default_value","default_is_null","comment","column_key","position","extra"]
                    values = ["id","bigint","NO","","1","identifier","PRI","1",""]
                } else { names = ["name","comment","type"]; values = ["demo","中文 ' comment","BASE TABLE"] }
                let parameters = sql.contains("TABLE_NAME = ?") ? 2 : 1
                var packets = [Data([0]) + Self.le(1,4) + Self.le(names.count,2) + Self.le(parameters,2) + Data([0,0,0])]
                packets += (0..<parameters).map { _ in Self.column("param") }
                packets += names.map(Self.column)
                send(Self.packets(packets))
            case 0x17:
                onExecute()
                guard respondToQueries else { continue }
                var packets = [Data([UInt8(names.count)])] + names.map(Self.column)
                var row = Data(repeating: 0, count: 1 + (names.count + 9) / 8)
                for value in values { row.append(Self.string(value)) }
                packets += [row, Data([0xfe,0,0,2,0])]
                send(Self.packets(packets))
            default: break
            }
        }
    }
    private func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    private static func packets(_ values: [Data]) -> Data {
        values.enumerated().reduce(into: Data()) { $0.append(packet($1.element, sequence: UInt8($1.offset + 1))) }
    }
    private static func packet(_ data: Data, sequence: UInt8) -> Data { le(data.count,3) + Data([sequence]) + data }
    private static func le(_ value: Int, _ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private static func string(_ value: String) -> Data { Data([UInt8(value.utf8.count)]) + Data(value.utf8) }
    private static func column(_ name: String) -> Data {
        var value = string("def") + string("") + string("") + string("") + string(name) + string("")
        value += Data([12]) + le(45,2) + le(1024,4) + Data([0xfd]) + le(0,2) + Data([0,0,0])
        return value
    }
    private static func handshake() -> Data {
        let capabilities = 0x00000200 | 0x00008000 | 0x00080000 | 0x00000008 | 0x00002000 | 0x00000001 | 0x00200000 | 0x01000000
        var data = Data([10])
        data += Data("8.0.40-fixture\0".utf8)
        data += le(1,4) + Data("12345678\0".utf8)
        data += le(capabilities & 0xffff,2) + Data([45]) + le(2,2)
        data += le(capabilities >> 16,2) + Data([21])
        data += Data(repeating: 0, count: 10)
        data += Data("abcdefghijkl\0mysql_native_password\0".utf8)
        return data
    }
}
