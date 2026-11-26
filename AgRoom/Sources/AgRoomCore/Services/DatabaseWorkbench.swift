import Foundation
import GRDB
import SQLite3
import Darwin

// MARK: - SQL Result

public struct SQLResult: Sendable {
    public let columns: [String]
    public let rows: [[String]]
    public let rowsAffected: Int
    public let isRead: Bool
    public let duration: TimeInterval
    /// 读结果是否因行数上限被截断（自由 SQL 不设限会让 SELECT * 整表进内存）
    public var truncated = false
}

/// The tool accepts only SQLite scalar bindings. Keeping this value Sendable lets
/// the workbench move a query to its database queue without sharing GRDB state.
fileprivate enum SQLParameterValue: Decodable, Sendable {
    case null, text(String), integer(Int64), real(Double), boolean(Bool)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let real = try? value.decode(Double.self), real.isFinite { self = .real(real) }
        else if let text = try? value.decode(String.self), text.utf8.count <= 16 * 1024 { self = .text(text) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported or oversized SQL parameter") }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: .null
        case .text(let value): value.databaseValue
        case .integer(let value): value.databaseValue
        case .real(let value): value.databaseValue
        case .boolean(let value): value.databaseValue
        }
    }
}

fileprivate enum SQLParameters: Decodable, Sendable {
    case positional([SQLParameterValue]), named([String: SQLParameterValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let items = try? value.decode([SQLParameterValue].self), items.count <= 100 {
            self = .positional(items)
        } else if let items = try? value.decode([String: SQLParameterValue].self),
                  items.count <= 100, items.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 }) {
            self = .named(items)
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid SQL parameters")
        }
    }

    var statementArguments: StatementArguments {
        switch self {
        case .positional(let items): StatementArguments(items.map(\.databaseValue))
        case .named(let items): StatementArguments(items.mapValues(\.databaseValue))
        }
    }
}

private struct SQLQueryInput: Decodable, Sendable {
    let sql: String
    let parameters: SQLParameters?

    static func parse(_ argumentsJSON: String) throws -> Self {
        guard argumentsJSON.utf8.count <= 256 * 1024,
              let data = argumentsJSON.data(using: .utf8),
              let input = try? JSONDecoder().decode(Self.self, from: data),
              !input.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.sql.utf8.count <= 128 * 1024,
              !input.sql.contains("\0") else {
            throw ToolExecutionFailure(message: "sql_query requires one non-empty SQL statement and valid scalar parameters.")
        }
        return input
    }
}

// MARK: - Database Workbench

/// 内置关系数据库工作台：浏览任意 SQLite 库（空间业务库 + 用户自建库），
/// 执行 SQL 并区分读/写（写操作供调度确认流拦截）
public final class DatabaseWorkbench: @unchecked Sendable {

    public enum WorkbenchError: LocalizedError {
        case databaseNotFound(String)
        case invalidName
        case alreadyExists
        case readOnlyViolation
        case queryTimedOut
        case unsupportedStatement
        case invalidDeletion

        public var errorDescription: String? {
            switch self {
            case .databaseNotFound(let name):
                return "Database not found: \(name)"
            case .invalidName:
                return "Invalid database name."
            case .alreadyExists: return "A database with this name already exists. Choose another name."
            case .readOnlyViolation: return "This statement is not allowed in read-only mode."
            case .queryTimedOut: return "The query exceeded its time limit. Narrow the query and retry."
            case .unsupportedStatement: return "ATTACH, DETACH and VACUUM are unavailable in the workbench. Use explicit database import instead."
            case .invalidDeletion: return "Only regular user databases in the current space can be deleted."
            }
        }
    }

    /// 只读模式：拒绝一切写语句
    public var readOnly: Bool {
        get { lock.withLock { _readOnly } }
        set { lock.withLock { _readOnly = newValue } }
    }

    private let lock = NSLock()
    private var _readOnly: Bool
    private struct FileIdentity: Equatable { let device: UInt64; let inode: UInt64 }
    private struct CachedQueue { let identity: FileIdentity; let queue: DatabaseQueue }
    private var queueCache: [String: CachedQueue] = [:]
    private let queryTimeout: TimeInterval

    public init(readOnly: Bool = false, queryTimeout: TimeInterval = 30) {
        self._readOnly = readOnly
        self.queryTimeout = max(0.001, min(600, queryTimeout))
    }

    // MARK: - Database Registry

    /// 用户自建库目录
    public static var legacyUserDatabasesDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AgRoom").appendingPathComponent("databases")
    }

    /// 列出用户自建库文件
    public static func userDatabasesDir(for space: AppSpace, baseDirectory: URL? = nil) -> URL {
        let base = (baseDirectory ?? legacyUserDatabasesDir.deletingLastPathComponent()).standardizedFileURL.resolvingSymlinksInPath()
        return base.appendingPathComponent(space.rawValue).appendingPathComponent("databases", isDirectory: true)
    }

    public static func listUserDatabases(space: AppSpace, baseDirectory: URL? = nil) -> [URL] {
        let dir = userDatabasesDir(for: space, baseDirectory: baseDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "sqlite" }
            .filter { (try? managedDatabase($0, space: space, baseDirectory: baseDirectory)) != nil }
            .map { $0.resolvingSymlinksInPath() }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 新建用户库（空 SQLite 文件）
    @discardableResult
    public static func createDatabase(name: String, space: AppSpace, baseDirectory: URL? = nil) throws -> URL {
        let sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized.utf8.count <= 180, sanitized != ".", sanitized != "..",
              !sanitized.contains(where: { "/\\:".contains($0) }),
              !sanitized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw WorkbenchError.invalidName }
        let dir = userDatabasesDir(for: space, baseDirectory: baseDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(sanitized.hasSuffix(".sqlite") ? sanitized : sanitized + ".sqlite")
        do { try Data().write(to: url, options: .withoutOverwriting) }
        catch { if FileManager.default.fileExists(atPath: url.path) { throw WorkbenchError.alreadyExists }; throw error }
        do {
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in try db.execute(sql: "PRAGMA user_version = 1") }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url.resolvingSymlinksInPath()
    }

    /// Deletes only a user database owned by this space. Callers obtain explicit user confirmation.
    /// Active workbench queries and exclusive maintenance prevent deletion.
    public func deleteDatabase(at url: URL, space: AppSpace, baseDirectory: URL? = nil) throws {
        let target = try Self.managedDatabase(url, space: space, baseDirectory: baseDirectory)
        let lease = try ResourceMaintenance.Lease(key: target.path, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        _ = try Self.managedDatabase(target, space: space, baseDirectory: baseDirectory)
        let companions = ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: target.path + $0) }
        // Refuse linked or unexpected sidecars before closing a connection or removing any bytes.
        for companion in companions {
            var info = stat()
            if lstat(companion.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw WorkbenchError.invalidDeletion }
            } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let cached = lock.withLock { queueCache.removeValue(forKey: target.path) }
        // Closing outside the lock checkpoints the last owned WAL connection before unlinking it.
        try cached?.queue.close()
        try FileManager.default.removeItem(at: target)
        for companion in companions where FileManager.default.fileExists(atPath: companion.path) {
            try FileManager.default.removeItem(at: companion)
        }
    }

    private static func managedDatabase(_ url: URL, space: AppSpace, baseDirectory: URL?) throws -> URL {
        let directory = userDatabasesDir(for: space, baseDirectory: baseDirectory)
        let target = url.standardizedFileURL
        var info = stat()
        guard directory == directory.resolvingSymlinksInPath(),
              target.deletingLastPathComponent() == directory, target.pathExtension == "sqlite",
              target == target.resolvingSymlinksInPath(), lstat(target.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw WorkbenchError.invalidDeletion }
        return target
    }

    /// Explicit user import uses SQLite backup so committed WAL pages are included.
    /// Legacy shared databases are retained; no automatic cross-space ownership is inferred.
    public static func importDatabase(from source: URL, space: AppSpace, baseDirectory: URL? = nil) throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path),
              (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw WorkbenchError.databaseNotFound(source.lastPathComponent)
        }
        let directory = userDatabasesDir(for: space, baseDirectory: baseDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".sqlite")
        guard !FileManager.default.fileExists(atPath: target.path) else { throw WorkbenchError.alreadyExists }
        let temporary = directory.appendingPathComponent(".import-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var configuration = Configuration()
        configuration.readonly = true
        let input = try DatabaseQueue(path: source.path, configuration: configuration)
        let output = try DatabaseQueue(path: temporary.path)
        try input.backup(to: output)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target.resolvingSymlinksInPath()
    }

    // MARK: - Introspection

    /// 库中用户可见的表
    public func tables(at path: String) throws -> [String] {
        let lease = try ResourceMaintenance.Lease(key: Self.canonicalPath(path), exclusive: false)
        defer { withExtendedLifetime(lease) {} }
        let queue = try openQueue(path: path)
        return try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
        }
    }

    /// 表的行数
    public func rowCount(at path: String, table: String) throws -> Int {
        guard isValidIdentifier(table) else { return 0 }
        let lease = try ResourceMaintenance.Lease(key: Self.canonicalPath(path), exclusive: false)
        defer { withExtendedLifetime(lease) {} }
        let queue = try openQueue(path: path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
        }
    }

    /// 分页读取表数据
    public func rows(at path: String, table: String, limit: Int = 100, offset: Int = 0) throws -> SQLResult {
        guard isValidIdentifier(table) else { throw WorkbenchError.invalidName }
        let sql = "SELECT * FROM \"\(table)\" LIMIT \(max(1, min(500, limit))) OFFSET \(max(0, offset))"
        return try execute(at: path, sql: sql)
    }

    // MARK: - SQL Execution

    /// 自由 SQL 读结果行数上限：超限截断并置 truncated 标志
    public static let maxReadRows = 1000
    public static let maxReadBytes = 2 * 1024 * 1024

    private final class QueryCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    /// DatabaseQueue dispatches onto its own queue, so cancellation is forwarded explicitly.
    public func executeAsync(at path: String, sql: String) async throws -> SQLResult {
        try await executeAsync(at: path, sql: sql, parameters: nil, expectedReadOnly: false)
    }

    fileprivate func executeAsync(at path: String, sql: String, parameters: SQLParameters?, expectedReadOnly: Bool) async throws -> SQLResult {
        let cancellation = QueryCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                try self.execute(at: path, sql: sql, parameters: parameters,
                    expectedReadOnly: expectedReadOnly, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    public func tablesAsync(at path: String) async throws -> [String] {
        try await executeAsync(at: path, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .rows.compactMap { $0.first }
    }

    public func rowsAsync(at path: String, table: String, limit: Int = 100) async throws -> SQLResult {
        guard isValidIdentifier(table) else { throw WorkbenchError.invalidName }
        return try await executeAsync(at: path, sql: "SELECT * FROM \"\(table)\" LIMIT \(max(1, min(500, limit)))")
    }

    /// 执行 SQL：读语句返回结果集，写语句返回受影响行数
    public func execute(at path: String, sql: String) throws -> SQLResult {
        try execute(at: path, sql: sql, parameters: nil, expectedReadOnly: false, cancellation: nil)
    }

    /// Compile on the bound database. GRDB's makeStatement rejects trailing
    /// executable statements, and binding validation rejects missing/extra values.
    /// Failed preparation is never treated as proof of a read-only operation.
    fileprivate func statementIsReadOnly(at path: String, sql: String, parameters: SQLParameters?) throws -> Bool {
        guard !Self.isUnsupportedStatement(sql) else { throw WorkbenchError.unsupportedStatement }
        // Some PRAGMAs mutate connection state while reporting no file write.
        // Do not even prepare one during the confirmation classification pass.
        guard Self.firstKeyword(in: sql) != "pragma" else { return false }
        let lease = try ResourceMaintenance.Lease(key: Self.canonicalPath(path), exclusive: false)
        defer { withExtendedLifetime(lease) {} }
        let queue = try openQueue(path: path)
        return try queue.read { db in
            let statement = try db.makeStatement(sql: sql)
            try statement.validateArguments(parameters?.statementArguments ?? StatementArguments())
            return Self.hasOnlyResultRows(statement)
        }
    }

    private static func hasOnlyResultRows(_ statement: Statement) -> Bool {
        // SQLite may mark EXPLAIN DELETE/UPDATE as non-readonly based on the
        // underlying opcode. EXPLAIN itself reports the plan without running it.
        statement.isReadonly || sqlite3_stmt_isexplain(statement.sqliteStatement) != 0
    }

    private static func isUnsupportedStatement(_ sql: String) -> Bool {
        ["attach", "detach", "vacuum"].contains(firstKeyword(in: sql))
    }

    private func execute(at path: String, sql: String, parameters: SQLParameters?, expectedReadOnly: Bool, cancellation: QueryCancellation?) throws -> SQLResult {
        if cancellation?.isCancelled == true { throw CancellationError() }
        let key = Self.canonicalPath(path)
        let lease = ResourceMaintenance.owned.contains(key) ? nil : try ResourceMaintenance.Lease(key: key, exclusive: false)
        defer { withExtendedLifetime(lease) {} }
        let queue = try openQueue(path: path)
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = Date()
        let onlyReads = readOnly
        guard !Self.isUnsupportedStatement(trimmed) else { throw WorkbenchError.unsupportedStatement }
        // The dispatcher may have skipped both approval and intent because its
        // frozen plan was read-only. Never let that plan run a writing statement.
        if expectedReadOnly && Self.firstKeyword(in: trimmed) == "pragma" {
            throw WorkbenchError.readOnlyViolation
        }
        if onlyReads && !["select", "with", "explain"].contains(Self.firstKeyword(in: trimmed)) {
            throw WorkbenchError.readOnlyViolation
        }
        let arguments = parameters?.statementArguments ?? StatementArguments()
        let isRead = try queue.read { db in
            let statement = try db.makeStatement(sql: trimmed)
            try statement.validateArguments(arguments)
            return Self.hasOnlyResultRows(statement)
        }
        if expectedReadOnly && !isRead { throw WorkbenchError.readOnlyViolation }

        if isRead {
            return try queue.read { db in
                try withQueryDeadline(db, cancellation: cancellation) {
                    let statement = try db.makeStatement(sql: trimmed)
                    guard Self.hasOnlyResultRows(statement) else { throw WorkbenchError.readOnlyViolation }
                    try statement.setArguments(arguments)
                    let columns = statement.columnNames
                    // 游标逐行取，超限即停：不把整表读进内存
                    var rows: [[String]] = []
                    var totalBytes = 0
                    var truncated = false
                    let cursor = try Row.fetchCursor(statement)
                    while let row = try cursor.next() {
                        if rows.count >= Self.maxReadRows || totalBytes >= Self.maxReadBytes {
                            truncated = true
                            break
                        }
                        // Row cursors reuse their storage. Materialize before advancing the cursor.
                        let values = columns.map { column -> String in
                            let text: String
                            if let value = row[column] {
                                text = "\(value)"
                            } else { text = "NULL" }
                            let budget = min(16 * 1024, max(0, Self.maxReadBytes - totalBytes))
                            if text.utf8.count > budget {
                                truncated = true
                                let clipped = String(decoding: text.utf8.prefix(budget), as: UTF8.self)
                                totalBytes += clipped.utf8.count
                                return clipped
                            }
                            totalBytes += text.utf8.count
                            return text
                        }
                        rows.append(values)
                    }
                    var result = SQLResult(
                        columns: columns,
                        rows: rows,
                        rowsAffected: 0,
                        isRead: true,
                        duration: Date().timeIntervalSince(start)
                    )
                    result.truncated = truncated
                    return result
                }
            }
        }

        guard !onlyReads else {
            throw WorkbenchError.readOnlyViolation
        }
        return try queue.write { db in
            try withQueryDeadline(db, cancellation: cancellation) {
                let statement = try db.makeStatement(sql: trimmed)
                guard !Self.hasOnlyResultRows(statement) else { throw WorkbenchError.readOnlyViolation }
                try statement.execute(arguments: arguments)
                return SQLResult(
                    columns: [],
                    rows: [],
                    rowsAffected: db.changesCount,
                    isRead: false,
                    duration: Date().timeIntervalSince(start)
                )
            }
        }
    }

    private final class QueryDeadline {
        let end: TimeInterval
        let cancellation: QueryCancellation?
        init(timeout: TimeInterval, cancellation: QueryCancellation?) {
            end = ProcessInfo.processInfo.systemUptime + timeout
            self.cancellation = cancellation
        }
    }

    private func withQueryDeadline<T>(_ db: Database, cancellation: QueryCancellation?, _ body: () throws -> T) throws -> T {
        if cancellation?.isCancelled == true { throw CancellationError() }
        let deadline = QueryDeadline(timeout: queryTimeout, cancellation: cancellation)
        sqlite3_progress_handler(db.sqliteConnection, 1000, { pointer in
            guard let pointer else { return 1 }
            let deadline = Unmanaged<QueryDeadline>.fromOpaque(pointer).takeUnretainedValue()
            return deadline.cancellation?.isCancelled == true || ProcessInfo.processInfo.systemUptime >= deadline.end ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil); withExtendedLifetime(deadline) {} }
        do { return try body() }
        catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
            if cancellation?.isCancelled == true { throw CancellationError() }
            throw WorkbenchError.queryTimedOut
        }
    }

    // MARK: - Statement Classification

    /// Lexical hint only. Never use this to grant access: WITH/PRAGMA may write.
    public static func isReadStatement(_ sql: String) -> Bool {
        let firstWord = Self.firstKeyword(in: sql)
        return ["select", "pragma", "with", "explain"].contains(firstWord)
    }

    /// Legacy lexical hint. It cannot grant access because a statement may be
    /// invalid, contain trailing SQL, or require bindings. The SQL tool instead
    /// prepares the exact statement on its bound database.
    public static func isDefinitelyReadOnlyStatement(_ sql: String) -> Bool {
        let firstWord = Self.firstKeyword(in: sql)
        return firstWord == "select" || firstWord == "explain"
    }

    private static func firstKeyword(in sql: String) -> String {
        var text = sql[...]
        while true {
            text = text.drop(while: { $0.isWhitespace || $0 == ";" })
            if text.hasPrefix("--") {
                guard let end = text.firstIndex(of: "\n") else { return "" }
                text = text[text.index(after: end)...]
            } else if text.hasPrefix("/*") {
                guard let end = text.range(of: "*/") else { return "" }
                text = text[end.upperBound...]
            } else { break }
        }
        return text.split(whereSeparator: { !$0.isLetter })
            .first
            .map { $0.lowercased() } ?? ""
    }

    private func isValidIdentifier(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("\"") && name.count <= 200
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func openQueue(path: String) throws -> DatabaseQueue {
        let path = Self.canonicalPath(path)
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw WorkbenchError.databaseNotFound(path)
        }
        let identity = FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        if let existing = lock.withLock({ queueCache[path] }), existing.identity == identity { return existing.queue }
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_ATTACHED, 0)
            sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_LENGTH, 8 * 1024 * 1024)
            sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_SQL_LENGTH, 128 * 1024)
        }
        let opened = try DatabaseQueue(path: path, configuration: configuration)
        let result: (DatabaseQueue, CachedQueue?) = lock.withLock {
            if let existing = queueCache[path], existing.identity == identity { return (existing.queue, nil) }
            return (opened, queueCache.updateValue(CachedQueue(identity: identity, queue: opened), forKey: path))
        }
        withExtendedLifetime(result.1) {}
        return result.0
    }
}

// MARK: - SQL Query Tool

/// 调度工具：在空间业务库上执行 SQL（写操作需用户确认）。
/// 工具描述内嵌当前库的表结构概览（表名 + 列），模型无需盲猜 schema
/// Core-internal: write execution is only for DispatcherEngine after its
/// confirmation and intent gate. Do not expose the classified write entry to UI.
struct SQLQueryTool: DispatcherTool {
    let workbench: DatabaseWorkbench
    let databasePath: String
    /// 表结构概览（表 → 列清单，紧凑单行格式）：构造时一次读取
    private let schemaDigest: String

    public var definition: ToolDefinition {
        var description = "Execute SQL on the user's space database (SQLite). "
            + "A single prepared read-only statement or EXPLAIN runs directly; writes and PRAGMA require confirmation. "
            + "Pass optional scalar parameters as an array for ? placeholders or an object for named placeholders. Results and execution time are bounded. "
            + "Inspect schema with: SELECT name, sql FROM sqlite_master WHERE type='table'."
        if !schemaDigest.isEmpty {
            description += "\nDatabase schema:\n" + schemaDigest
        }
        return ToolDefinition(
            name: "sql_query",
            description: description,
            parametersSchemaJSON: #"{"type":"object","properties":{"sql":{"type":"string","description":"One SQL statement"},"parameters":{"description":"Optional scalar bindings, positional array or named object","oneOf":[{"type":"array","maxItems":100,"items":{"type":["string","number","boolean","null"]}},{"type":"object","maxProperties":100,"additionalProperties":{"type":["string","number","boolean","null"]}}]}},"required":["sql"],"additionalProperties":false}"#
        )
    }

    /// 静态属性保持保守默认；动态判定见 requiresConfirmation(argumentsJSON:)
    public let requiresConfirmation = true
    /// SQL 写的是空间业务库，不是会话文件工作区；按外部副作用处理。
    /// 只有确定只读的语句才允许在只读模式执行。
    public var permissionClass: PermissionClass { .externalEffect }

    public init(workbench: DatabaseWorkbench, databasePath: String) {
        self.workbench = workbench
        self.databasePath = databasePath
        self.schemaDigest = Self.buildSchemaDigest(workbench: workbench, databasePath: databasePath)
    }

    public func validateArguments(argumentsJSON: String) throws {
        _ = try SQLQueryInput.parse(argumentsJSON)
    }

    /// 读取 sqlite_master + PRAGMA table_info，生成紧凑结构概览（每表一行）
    static func buildSchemaDigest(workbench: DatabaseWorkbench, databasePath: String) -> String {
        // 容错读取：结构概览失败不影响工具可用性
        guard let tableResult = try? workbench.execute(
            at: databasePath,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ) else { return "" }
        var lines: [String] = []
        for row in tableResult.rows.prefix(30) {
            guard let tableName = row.first else { continue }
            let columns = (try? workbench.execute(
                at: databasePath,
                sql: "SELECT name FROM pragma_table_info('\(tableName.replacingOccurrences(of: "'", with: "''"))')"
            ))?
                .rows
                .compactMap { $0.first }
                .joined(separator: ", ") ?? ""
            lines.append("- \(tableName)(\(columns))")
        }
        return lines.joined(separator: "\n")
    }

    /// 只有在本空间数据库上成功预编译且验证绑定的单条只读语句免确认。
    /// 准备失败、无效绑定或未知结果都按可能写入处理，执行阶段再返回错误。
    private func isPreparedReadOnly(_ argumentsJSON: String) -> Bool {
        guard let input = try? SQLQueryInput.parse(argumentsJSON) else { return false }
        return (try? workbench.statementIsReadOnly(
            at: databasePath, sql: input.sql, parameters: input.parameters
        )) == true
    }

    public func requiresConfirmation(argumentsJSON: String) -> Bool {
        !isPreparedReadOnly(argumentsJSON)
    }

    public func permissionClass(argumentsJSON: String) -> PermissionClass {
        isPreparedReadOnly(argumentsJSON) ? .readOnly : .externalEffect
    }

    public func sideEffectClass(argumentsJSON: String) -> ToolSideEffectClass {
        isPreparedReadOnly(argumentsJSON) ? .readOnly : .nonIdempotentWrite
    }

    /// Direct callers have no dispatcher approval or intent receipt, so they
    /// can only use the read path. The dispatcher passes its frozen class below.
    public func execute(argumentsJSON: String) async throws -> String {
        try await executeSQL(argumentsJSON, expectedReadOnly: true)
    }

    public func execute(argumentsJSON: String, authorizationKey: String?, permittedSideEffectClass: ToolSideEffectClass) async throws -> String {
        if let authorizationKey, executionAuthorizationKey(argumentsJSON: argumentsJSON) != authorizationKey {
            throw ToolExecutionFailure(message: "The approved operation changed. Nothing was executed; request a fresh approval.")
        }
        return try await executeSQL(argumentsJSON, expectedReadOnly: permittedSideEffectClass == .readOnly)
    }

    private func executeSQL(_ argumentsJSON: String, expectedReadOnly: Bool) async throws -> String {
        let input = try SQLQueryInput.parse(argumentsJSON)
        let result = try await workbench.executeAsync(at: databasePath, sql: input.sql,
            parameters: input.parameters, expectedReadOnly: expectedReadOnly)
        if result.isRead {
            var lines: [String] = [result.columns.joined(separator: " | ")]
            for row in result.rows.prefix(30) {
                lines.append(row.joined(separator: " | "))
            }
            if result.rows.count > 30 {
                lines.append("... (\(result.rows.count - 30) more rows)")
            }
            var text = "Query OK in \(String(format: "%.2f", result.duration))s, \(result.rows.count) rows:\n" + lines.joined(separator: "\n")
            if result.truncated {
                text += "\n(Result preview truncated by row, cell or byte limits. Select fewer columns and shorter values, or add a LIMIT clause.)"
            }
            return text
        }
        return "Statement executed in \(String(format: "%.2f", result.duration))s, \(result.rowsAffected) rows affected."
    }
}
