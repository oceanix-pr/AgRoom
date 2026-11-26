import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import Logging

/// Native MySQL wire protocol; only fixed, parameterized information_schema queries are exposed.
public struct NativeMySQLMetadataClient: MySQLMetadataClient {
    public init() {}

    static func safeError(_ error: any Error) -> MySQLConnectorError {
        if let error = error as? MySQLConnectorError { return error }
        if error is NIOSSLError || error is NIOSSLExtraError { return .init(.tls) }
        if let error = error as? MySQLError {
            switch error {
            case .secureConnectionRequired: return .init(.tls)
            case .unsupportedAuthPlugin, .authPluginDataError: return .init(.authentication)
            case .server(let packet):
                switch packet.errorCode.rawValue {
                case 1045, 1698: return .init(.authentication)
                case 1044, 1142, 1143, 1227: return .init(.accessDenied)
                case 1049: return .init(.databaseUnavailable)
                default: break
                }
            default: break
            }
        }
        return .init(.connection)
    }
    public func read(config: MySQLConnectionConfig, password: String, table: String?) async throws -> HostDataTable {
        try config.validate()
        let request = MySQLMetadataRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.start(continuation, config: config, password: password, table: table)
            }
        } onCancel: { request.finish(.failure(CancellationError())) }
    }

    static func query(table: String?) -> (sql: String, columns: [String]) {
        if table == nil {
            return ("""
                SELECT TABLE_NAME AS name, TABLE_COMMENT AS comment, TABLE_TYPE AS type
                FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? ORDER BY TABLE_NAME LIMIT 1001
                """, ["name", "comment", "type"])
        }
        return ("""
            SELECT COLUMN_NAME AS name, COLUMN_TYPE AS type, IS_NULLABLE AS nullable,
                COALESCE(COLUMN_DEFAULT,'') AS default_value,
                (COLUMN_DEFAULT IS NULL) AS default_is_null, COLUMN_COMMENT AS comment,
                COLUMN_KEY AS column_key, ORDINAL_POSITION AS position, EXTRA AS extra
            FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
            ORDER BY ORDINAL_POSITION LIMIT 1001
            """, ["name", "type", "nullable", "default-value", "default-is-null", "comment", "column-key", "position", "extra"])
    }
}

/// The lock owns continuation/terminal state only. Shutdown/resume and all I/O occur outside it.
/// Cancellation closes the registered TCP channel. The event loop stays alive until all driver futures settle.
private final class MySQLMetadataRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostDataTable, any Error>?
    private var finished = false
    private var channel: (any Channel)?

    func start(_ continuation: CheckedContinuation<HostDataTable, any Error>, config: MySQLConnectionConfig,
               password: String, table: String?) {
        let accepted = lock.withLock { () -> Bool in
            guard !finished else { return false }
            self.continuation = continuation
            return true
        }
        guard accepted else { continuation.resume(throwing: CancellationError()); return }
        Task.detached { [self] in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully { _ in } }
            guard lock.withLock({ !finished }) else { return }
            let timeout = Task { [self] in
                do { try await Task.sleep(for: .seconds(30)); finish(.failure(MySQLConnectorError(.timeout))) }
                catch { }
            }
            defer { timeout.cancel() }
            do {
                let address: SocketAddress
                do { address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port) }
                catch { throw MySQLConnectorError(.hostResolution) }
                guard lock.withLock({ !finished }) else { return }
                if !config.requiresTLS {
                    guard ["127.0.0.1", "::1"].contains(address.ipAddress ?? "") else { throw MySQLConnectorError(.invalidConfiguration) }
                }
                let isIPAddress = (try? SocketAddress(ipAddress: config.host, port: config.port)) != nil
                let logger = Logger(label: "com.agroom.mysql", factory: { _ in SwiftLogNoOpLogHandler() })
                var tls = TLSConfiguration.makeClientConfiguration()
                tls.minimumTLSVersion = .tlsv12
                tls.certificateVerification = .fullVerification
                let connection = try await MySQLConnection.connect(to: address, username: config.username,
                    database: config.database, password: password,
                    tlsConfiguration: config.requiresTLS ? tls : nil,
                    serverHostname: isIPAddress ? nil : config.host, logger: logger, on: group.next(),
                    onChannel: { [self] channel in
                        lock.withLock {
                            guard !finished else { return false }
                            self.channel = channel
                            return true
                        }
                    }).get()
                let query = NativeMySQLMetadataClient.query(table: table)
                var binds = [MySQLData(string: config.database)]
                if let table { binds.append(MySQLData(string: table)) }
                var resultRows: [HostDataRow] = []
                var totalBytes = 0
                do {
                    try await connection.query(query.sql, binds, onRow: { row in
                        guard resultRows.count < 1000 else { throw MySQLConnectorError(.tooLarge) }
                        var fields: [String: NativeAppValue] = [:]
                        for key in query.columns {
                            let value = NativeAppValue.string(row.column(key.replacingOccurrences(of: "-", with: "_"))?.string ?? "")
                            guard value.isBounded else { throw MySQLConnectorError(.tooLarge) }
                            fields[key] = value
                        }
                        let name = fields["name"]?.string ?? ""
                        let content = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
                        let result = HostDataRow(id: name, title: name, content: content, fields: fields)
                        totalBytes += try JSONEncoder().encode(result).count
                        guard totalBytes <= 4 * 1024 * 1024 else { throw MySQLConnectorError(.tooLarge) }
                        resultRows.append(result)
                    }).get()
                    try await connection.close().get()
                } catch {
                    _ = try? await connection.close().get()
                    throw error
                }
                let result = HostDataTable(columns: query.columns, rows: resultRows)
                try result.validate()
                finish(.success(result))
            } catch let error as MySQLConnectorError { finish(.failure(error)) }
            catch let error as NativeAppError where error.code == .tooLarge { finish(.failure(MySQLConnectorError(.tooLarge))) }
            catch is CancellationError { finish(.failure(CancellationError())) }
            catch {
                // Driver errors can contain SQL, hostnames or authentication data; never publish them.
                finish(.failure(NativeMySQLMetadataClient.safeError(error)))
            }
        }
    }

    func finish(_ result: Result<HostDataTable, any Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<HostDataTable, any Error>?, (any Channel)?)? in
            guard !finished else { return nil }
            finished = true
            let value = (continuation, channel)
            continuation = nil; channel = nil
            return value
        }
        guard let state else { return }
        state.1?.close(mode: .all, promise: nil)
        state.0?.resume(with: result)
    }
}
