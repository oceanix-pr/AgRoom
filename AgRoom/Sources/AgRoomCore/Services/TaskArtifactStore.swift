import CryptoKit
import Darwin
import Foundation
import GRDB

public enum TaskArtifactError: Error, Equatable, Sendable { case unavailable, unsafeFile, changedFile, storage, previewInUse, cacheCleanupPending }

enum TaskArtifactBaseline: Sendable {
    case created
    case existing(Data)
    var data: Data? { if case .existing(let data) = self { data } else { nil } }
}

public struct TaskArtifactVersion: Codable, Equatable, Identifiable, Sendable {
    public var artifact: TaskArtifact
    public var logicalPath: String
    public var sessionID: UUID?
    public let runID: UUID
    public var workspaceID: String?
    public let operationID: String
    public var id: UUID { artifact.versionID ?? runID }
}

/// Metadata only: unchanged inputs are never read into the artifact store.
struct ArtifactFileStamp: Equatable, Sendable {
    let device: Int64, inode: UInt64, size: Int64
    let modifiedSeconds: Int, modifiedNanoseconds: Int
    let changedSeconds: Int, changedNanoseconds: Int
    init(_ info: stat) {
        device = Int64(info.st_dev); inode = UInt64(info.st_ino); size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

/// Immutable contents and provenance live in the producing space's database.
/// Preview files are disposable, verified copies; neither paths in model text nor
/// a version ID from another database can authorize a private file read.
public struct TaskArtifactStore: Sendable {
    let queue: DatabaseQueue
    public let space: AppSpace
    let previewRoot: URL
    private let operationSnapshotLimit: Int
    public static let maximumSnapshotBytes = 64 * 1024 * 1024
    public static let maximumOperationSnapshotBytes = 256 * 1024 * 1024

    public init(databaseQueue: DatabaseQueue, space: AppSpace, previewRoot: URL) {
        self.init(databaseQueue: databaseQueue, space: space, previewRoot: previewRoot, operationSnapshotLimit: Self.maximumOperationSnapshotBytes)
    }

    init(databaseQueue: DatabaseQueue, space: AppSpace, previewRoot: URL, operationSnapshotLimit: Int) {
        queue = databaseQueue; self.space = space; self.previewRoot = previewRoot
        self.operationSnapshotLimit = min(Self.maximumOperationSnapshotBytes, max(1, operationSnapshotLimit))
    }

    static func createSchema(_ db: Database) throws {
        try db.create(table: "artifact_versions", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("sessionID", .text); t.column("workspaceID", .text)
            t.column("runID", .text).notNull(); t.column("operationID", .text).notNull()
            t.column("path", .text).notNull(); t.column("logicalPath", .text).notNull()
            t.column("version", .integer).notNull(); t.column("createdAt", .datetime).notNull()
            t.column("metadata", .blob).notNull(); t.column("contents", .blob)
        }
        try db.create(index: "artifact_versions_operation", on: "artifact_versions", columns: ["runID", "operationID", "path"], unique: true, ifNotExists: true)
        try db.create(index: "artifact_versions_lineage", on: "artifact_versions", columns: ["workspaceID", "logicalPath", "version"], ifNotExists: true)
        try db.create(index: "artifact_versions_session", on: "artifact_versions", columns: ["sessionID"], ifNotExists: true)
        try db.create(index: "artifact_versions_library", on: "artifact_versions", columns: ["createdAt", "id"], ifNotExists: true)
    }

    static func createComparisonSchema(_ db: Database) throws {
        if !(try db.columns(in: "artifact_versions")).contains(where: { $0.name == "beforeContents" }) {
            try db.alter(table: "artifact_versions") { $0.add(column: "beforeContents", .blob) }
        }
    }

    struct Origin: Sendable {
        let space: AppSpace
        let sessionID: UUID?
        let runID: UUID
        let workspaceID: String?
        let operationID: String
        let tool: String
        var inputVersionIDs: [UUID]? = nil
        var writeRootIdentities: [String: TaskDirectoryIdentity] = [:]
    }

    func capture(_ file: URL, root: URL, logicalPath: String?, origin: Origin,
                 observedChange: Bool = false, expected: ArtifactFileStamp? = nil,
                 rootIdentity: TaskDirectoryIdentity? = nil, baseline: TaskArtifactBaseline? = nil,
                 expectedContents: Data? = nil, recoveryID: UUID? = nil) async throws -> TaskArtifact {
        guard origin.space == space else { throw TaskArtifactError.unsafeFile }
        let frozen = try await Task.detached { try Self.freeze(file, root: root, expected: expected, rootIdentity: rootIdentity) }.value
        if let expectedContents, frozen.data != expectedContents { throw TaskArtifactError.changedFile }
        let editRoot = origin.writeRootIdentities.values
            .filter { file.path.hasPrefix($0.canonicalPath + "/") }
            .max { $0.canonicalPath.count < $1.canonicalPath.count }
        return try await queue.maintenanceWrite { db in
            if let old = try Data.fetchOne(db, sql: "SELECT metadata FROM artifact_versions WHERE runID=? AND operationID=? AND path=?",
                arguments: [origin.runID.uuidString, origin.operationID, file.path]) {
                return try Self.decode(old, space: space).artifact
            }
            let inherited = try String.fetchOne(db, sql: "SELECT logicalPath FROM artifact_versions WHERE path=? AND workspaceID IS ? ORDER BY createdAt DESC,id DESC LIMIT 1",
                arguments: [file.path, origin.workspaceID])
            let sourceLineage = try logicalPath.flatMap { path in
                try String.fetchOne(db, sql: "SELECT logicalPath FROM artifact_versions WHERE path=? AND workspaceID IS ? ORDER BY createdAt DESC,id DESC LIMIT 1", arguments: [path, origin.workspaceID])
            }
            let lineage = sourceLineage ?? logicalPath ?? inherited ?? file.path
            let ordinal = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(version),0)+1 FROM artifact_versions WHERE logicalPath=? AND workspaceID IS ?",
                arguments: [lineage, origin.workspaceID]) ?? 1
            let retainedBytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(COALESCE(length(contents),0)+COALESCE(length(beforeContents),0)),0) FROM artifact_versions WHERE runID=? AND operationID=?",
                arguments: [origin.runID.uuidString, origin.operationID]) ?? 0
            let reason: TaskArtifactRetentionReason? = frozen.data == nil ? .fileTooLarge
                : (retainedBytes > operationSnapshotLimit - frozen.size - (baseline?.data?.count ?? 0) ? .operationLimit : nil)
            let contents = reason == nil ? frozen.data : nil
            var inputs: [UUID] = []
            for id in (origin.inputVersionIDs ?? []).prefix(32) where !inputs.contains(id) {
                guard let data = try Data.fetchOne(db, sql: "SELECT metadata FROM artifact_versions WHERE id=?", arguments: [id.uuidString]) else { continue }
                let input = try Self.decode(data, space: space)
                guard input.id == id else { throw TaskArtifactError.unavailable }
                inputs.append(id)
            }
            var artifact = TaskArtifact(path: file.path, versionID: UUID(), version: ordinal, sha256: frozen.digest,
                byteCount: frozen.size, createdAt: Date(), sourceTool: origin.tool, sourceSpace: space,
                contentRetained: contents != nil, observedChange: observedChange ? true : nil, retentionReason: reason,
                inputVersionIDs: inputs.isEmpty ? nil : inputs)
            if let baseline {
                artifact.change = TaskArtifactChange(kind: baseline.data == nil ? .created : .modified,
                    beforeSHA256: baseline.data.map(Self.digest), beforeByteCount: baseline.data?.count ?? 0,
                    beforeRetained: reason == nil)
            }
            let record = TaskArtifactVersion(artifact: artifact, logicalPath: lineage, sessionID: origin.sessionID,
                runID: origin.runID, workspaceID: origin.workspaceID, operationID: origin.operationID)
            try db.execute(sql: """
                INSERT INTO artifact_versions(id,sessionID,workspaceID,runID,operationID,path,logicalPath,version,createdAt,metadata,contents,beforeContents)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [record.id.uuidString, record.sessionID?.uuidString, record.workspaceID, record.runID.uuidString,
                    record.operationID, artifact.path, lineage, ordinal, artifact.createdAt, try JSONEncoder().encode(record), contents,
                    reason == nil ? baseline?.data : nil])
            if let editRoot, baseline != nil, expectedContents != nil, reason == nil,
               origin.sessionID != nil, origin.workspaceID != nil {
                try db.execute(sql: """
                    INSERT INTO artifact_edit_receipts(versionID, rootIdentity, recoveryID) VALUES (?, ?, ?)
                    """, arguments: [record.id.uuidString, try JSONEncoder().encode(editRoot), recoveryID?.uuidString])
            }
            return artifact
        }
    }

    func artifacts(runID: UUID, operationID: String) async throws -> [TaskArtifact] {
        try await queue.read { db in
            try Data.fetchAll(db, sql: "SELECT metadata FROM artifact_versions WHERE runID=? AND operationID=? ORDER BY path", arguments: [runID.uuidString, operationID])
                .map { try Self.decode($0, space: space).artifact }
        }
    }

    public func version(id: UUID, includeHidden: Bool = false) async throws -> TaskArtifactVersion? {
        try await queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT a.metadata FROM artifact_versions a LEFT JOIN chat_sessions s ON s.id=a.sessionID WHERE a.id=? AND (? OR COALESCE(s.isHidden,0)=0)", arguments: [id.uuidString, includeHidden]) else { return nil }
            let value = try Self.decode(data, space: space)
            guard value.id == id else { throw TaskArtifactError.unavailable }
            return value
        }
    }

    public func versions(of artifact: TaskArtifact, limit: Int = 50) async throws -> [TaskArtifactVersion] {
        guard let id = artifact.versionID else { return [] }
        return try await queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT metadata FROM artifact_versions WHERE id=?", arguments: [id.uuidString]) else { return [] }
            let selected = try Self.decode(data, space: space)
            guard selected.artifact.path == artifact.path, selected.id == id else { throw TaskArtifactError.unavailable }
            return try Data.fetchAll(db, sql: "SELECT metadata FROM artifact_versions WHERE workspaceID IS ? AND logicalPath=? ORDER BY version DESC LIMIT ?",
                arguments: [selected.workspaceID, selected.logicalPath, min(100, max(1, limit))]).map { try Self.decode($0, space: space) }
        }
    }

    public func inputs(of artifact: TaskArtifact) async throws -> [TaskArtifactVersion] {
        guard let id = artifact.versionID else { return [] }
        return try await queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT metadata FROM artifact_versions WHERE id=?", arguments: [id.uuidString]) else { return [] }
            let selected = try Self.decode(data, space: space)
            guard selected.id == id, selected.artifact.path == artifact.path else { throw TaskArtifactError.unavailable }
            return try (selected.artifact.inputVersionIDs ?? []).prefix(32).compactMap { inputID in
                guard let data = try Data.fetchOne(db, sql: "SELECT metadata FROM artifact_versions WHERE id=?", arguments: [inputID.uuidString]) else { return nil }
                let input = try Self.decode(data, space: space)
                guard input.id == inputID else { throw TaskArtifactError.unavailable }
                return input
            }
        }
    }

    /// The caller can preview/export or attach this copy. It is never a grant for
    /// model tools to access the private artifact database or preview directory.
    public func materialize(_ artifact: TaskArtifact) async throws -> URL {
        try await ResourceMaintenance.withAsyncAccess(queue.maintenanceKey) {
            try await ResourceMaintenance.withAsyncAccess(cacheMaintenanceKey) { try await materializeProtected(artifact) }
        }
    }

    private func materializeProtected(_ artifact: TaskArtifact) async throws -> URL {
        guard let id = artifact.versionID else { throw TaskArtifactError.unavailable }
        let (record, contents): (TaskArtifactVersion, Data) = try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT metadata,contents FROM artifact_versions WHERE id=?", arguments: [id.uuidString]),
                  let data: Data = row["contents"] else { throw TaskArtifactError.unavailable }
            let metadata: Data = row["metadata"]
            let record = try Self.decode(metadata, space: space)
            guard record.artifact.path == artifact.path, record.id == id else { throw TaskArtifactError.unavailable }
            try Self.validate(record, contents: data)
            return (record, data)
        }
        let root = previewRoot
        do { return try await Task.detached {
            let directory = try AppDirectory(url: root, create: true).child(id.uuidString, create: true)
            let name = Self.snapshotName(record.artifact)
            _ = try BackupFileIO.components(name)
            if directory.exists(name) {
                try directory.checkRegular(name, missingOK: false, limit: Self.maximumSnapshotBytes)
                if try directory.read(name, limit: Self.maximumSnapshotBytes) != contents { try directory.write(contents, name: name) }
            } else { try directory.write(contents, name: name) }
            guard fchmodat(directory.fd, name, 0o400, AT_SYMLINK_NOFOLLOW) == 0 else { throw TaskArtifactError.storage }
            return root.appendingPathComponent(id.uuidString).appendingPathComponent(name)
        }.value } catch let error as TaskArtifactError { throw error }
        catch { throw TaskArtifactError.storage }
    }

    static func decode(_ data: Data, space: AppSpace) throws -> TaskArtifactVersion {
        guard data.count <= 128 * 1024 else { throw TaskArtifactError.unavailable }
        let value: TaskArtifactVersion
        do { value = try JSONDecoder().decode(TaskArtifactVersion.self, from: data) }
        catch { throw TaskArtifactError.unavailable }
        guard value.artifact.versionID != nil, value.artifact.sourceSpace == space,
              (value.artifact.version ?? 0) > 0, (value.artifact.byteCount ?? -1) >= 0,
              (value.artifact.inputVersionIDs?.count ?? 0) <= 32,
              value.artifact.inputVersionIDs?.contains(value.id) != true,
              value.artifact.retentionReason == nil || value.artifact.contentRetained == false,
              value.artifact.path.hasPrefix("/"), !value.artifact.path.contains("\0"),
              value.artifact.createdAt?.timeIntervalSince1970.isFinite == true else { throw TaskArtifactError.unavailable }
        return value
    }

    static func validate(_ record: TaskArtifactVersion, contents: Data?) throws {
        guard let contents else {
            guard record.artifact.contentRetained != true else { throw TaskArtifactError.unavailable }
            return
        }
        guard contents.count <= maximumSnapshotBytes, record.artifact.contentRetained == true,
              record.artifact.byteCount == contents.count, record.artifact.sha256 == digest(contents) else { throw TaskArtifactError.changedFile }
    }

    static func validateBaseline(_ record: TaskArtifactVersion, contents: Data?) throws {
        guard let change = record.artifact.change else {
            guard contents == nil else { throw TaskArtifactError.changedFile }
            return
        }
        guard change.beforeByteCount >= 0, change.beforeByteCount <= maximumSnapshotBytes else { throw TaskArtifactError.changedFile }
        if change.kind == .created {
            guard contents == nil, change.beforeSHA256 == nil, change.beforeByteCount == 0 else { throw TaskArtifactError.changedFile }
        } else if change.beforeRetained {
            guard let contents, contents.count == change.beforeByteCount, digest(contents) == change.beforeSHA256 else { throw TaskArtifactError.changedFile }
        } else if contents != nil { throw TaskArtifactError.changedFile }
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func snapshotName(_ artifact: TaskArtifact) -> String {
        let url = URL(fileURLWithPath: artifact.path)
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let revision = " (v\(artifact.version ?? 1))"
        let budget = 255 - suffix.utf8.count - revision.utf8.count
        guard budget > 0 else { return artifact.name }
        var stem = url.deletingPathExtension().lastPathComponent
        while stem.utf8.count > budget { stem.removeLast() }
        return stem + revision + suffix
    }
    private struct Frozen: Sendable { let data: Data?; let size: Int; let digest: String? }
    private static func freeze(_ file: URL, root: URL, expected: ArtifactFileStamp?, rootIdentity: TaskDirectoryIdentity?) throws -> Frozen {
        let root = root.standardizedFileURL
        guard file.isFileURL, file.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw TaskArtifactError.unsafeFile }
        let relative = String(file.standardizedFileURL.path.dropFirst(root.path.count + 1))
        let directory = try AppDirectory(url: root, create: false)
        if let rootIdentity {
            var info = stat()
            guard fstat(directory.fd, &info) == 0, rootIdentity.matches(root),
                  UInt64(bitPattern: Int64(info.st_dev)) == rootIdentity.device,
                  UInt64(info.st_ino) == rootIdentity.inode else { throw TaskArtifactError.unsafeFile }
        }
        let (parent, name) = try BackupFileIO.parent(relative, in: directory, create: false)
        let fd = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TaskArtifactError.unavailable }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_size >= 0 else { throw TaskArtifactError.unsafeFile }
        if let expected { guard ArtifactFileStamp(before) == expected else { throw TaskArtifactError.changedFile } }
        guard before.st_size <= maximumSnapshotBytes else { return Frozen(data: nil, size: Int(before.st_size), digest: nil) }
        let data = try AppDirectory.read(fd: fd, limit: maximumSnapshotBytes)
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw TaskArtifactError.changedFile }
        return Frozen(data: data, size: data.count, digest: digest(data))
    }
}

/// One collector per tool call; children inherit the store but install their own
/// collector, so concurrent tools cannot attribute each other's files.
final class ToolArtifactCapture: @unchecked Sendable {
    @TaskLocal static var current: ToolArtifactCapture?
    let store: TaskArtifactStore?
    let origin: TaskArtifactStore.Origin
    private let lock = NSLock()
    private var values: [TaskArtifact] = []
    private var _evidence: ToolExecutionEvidence?
    var evidence: ToolExecutionEvidence? {
        get { lock.withLock { _evidence } }
        set { lock.withLock { _evidence = newValue } }
    }
    static func recordSource(_ receipt: ToolSourceReceipt) {
        guard let current else { return }
        current.lock.withLock {
            if current._evidence == nil { current._evidence = ToolExecutionEvidence() }
            current._evidence?.sourceReceipt = receipt
        }
    }
    typealias ChildCheckpointWriter = @Sendable (UUID, UUID, EngineRunSnapshot, DelegatedRunResult?) -> Bool
    let mailTarget: MailTurnTarget?
    let checkpointChild: ChildCheckpointWriter?
    var artifacts: [TaskArtifact] { lock.withLock { values } }
    init(store: TaskArtifactStore?, origin: TaskArtifactStore.Origin, mailTarget: MailTurnTarget? = nil, checkpointChild: ChildCheckpointWriter? = nil) {
        self.store = store
        self.mailTarget = mailTarget
        self.origin = origin
        self.checkpointChild = checkpointChild
    }

    static func record(_ file: URL, root: URL, logicalPath: String? = nil, observedChange: Bool = false,
                       expected: ArtifactFileStamp? = nil, rootIdentity: TaskDirectoryIdentity? = nil,
                       baseline: TaskArtifactBaseline? = nil, expectedContents: Data? = nil, recoveryID: UUID? = nil) async throws {
        guard let current else { return }
        do {
            let value: TaskArtifact
            if let store = current.store {
                value = try await store.capture(file, root: root, logicalPath: logicalPath, origin: current.origin,
                    observedChange: observedChange, expected: expected, rootIdentity: rootIdentity,
                    baseline: baseline, expectedContents: expectedContents, recoveryID: recoveryID)
            } else { value = TaskArtifact(path: file.path, createdAt: Date(), sourceTool: current.origin.tool, observedChange: observedChange ? true : nil) }
            current.lock.withLock { current.values.append(value) }
        } catch {
            current.lock.withLock { current.values.append(TaskArtifact(path: file.path, sourceTool: current.origin.tool,
                sourceSpace: current.origin.space, recordingFailed: true)) }
            throw ToolExecutionFailure(message: "The file was produced, but its artifact version could not be saved. Do not repeat the operation. Produced file: \(file.path)")
        }
    }

    static func recordAll(_ files: [URL], root: URL) async throws {
        var failed = false
        for file in files {
            do { try await record(file, root: root) }
            catch { failed = true }
        }
        if failed { throw ToolExecutionFailure(message: "Some files were produced but their versions could not be saved. Do not repeat the operation; inspect the existing files.") }
    }

    static func recordItem(_ file: URL, logicalPath: String? = nil) async throws {
        guard current != nil else { return }
        var info = stat()
        guard lstat(file.path, &info) == 0 else { throw ToolExecutionFailure(message: "The file operation completed, but its output could not be inspected. Do not repeat the operation.") }
        if info.st_mode & S_IFMT == S_IFDIR { _ = try await recordDirectory(file, logicalRoot: logicalPath) }
        else { try await record(file, root: file.deletingLastPathComponent(), logicalPath: logicalPath) }
    }

    static func recordDirectory(_ root: URL, logicalRoot: String? = nil) async throws -> Int {
        guard current != nil else { return 0 }
        let files: [URL], skipped: Int
        do { (files, skipped) = try await Task.detached {
            var files: [URL] = [], skipped = 0, count = 0
            func walk(_ directory: AppDirectory, at url: URL, depth: Int) throws {
                guard depth <= 12 else { throw TaskArtifactError.unsafeFile }
                for name in try directory.names(limit: 4096).sorted() {
                    count += 1
                    guard count <= 4096 else { throw NativeAppError(.capacity) }
                    var info = stat()
                    guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw TaskArtifactError.unavailable }
                    let child = url.appendingPathComponent(name)
                    if info.st_mode & S_IFMT == S_IFDIR { try walk(directory.child(name, create: false), at: child, depth: depth + 1) }
                    else if info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 { files.append(child) }
                    else { skipped += 1 }
                }
            }
            try walk(AppDirectory(url: root, create: false), at: root, depth: 0)
            return (files, skipped)
        }.value } catch {
            throw ToolExecutionFailure(message: "Files may have been produced, but output discovery could not finish safely. Do not repeat the operation automatically. Output directory: \(root.path)")
        }
        if let logicalRoot {
            var failed = false
            for file in files {
                let relative = String(file.path.dropFirst(root.path.count))
                do { try await record(file, root: root, logicalPath: logicalRoot + relative) } catch { failed = true }
            }
            if failed { throw ToolExecutionFailure(message: "Some moved files could not be recorded. Inspect the existing destination; do not repeat the move.") }
        } else { try await recordAll(files, root: root) }
        return skipped
    }
}

/// Shell has no managed write receipt. Observe only new/changed regular files in
/// its approved working directory and label that weaker provenance explicitly.
/// A bounded preflight fails before execution; no partial baseline can make an
/// unchanged input appear to be a newly produced output.
struct ShellArtifactObservation: Sendable {
    private let root: URL
    private let identity: TaskDirectoryIdentity
    private let paths: [String]
    private let denied: [URL]
    private let before: Scan
    private static let entryLimit = 8192
    private static let depthLimit = 24
    private struct Scan: Sendable { var files: [String: ArtifactFileStamp] = [:]; var skipped = 0 }

    static func prepare(directory: URL, args: [String: Any], denied: [URL], readOnly: Bool) async throws -> Self? {
        let paths = try requestedPaths(args["artifact_paths"], root: directory)
        guard ToolArtifactCapture.current != nil, !readOnly else { return nil }
        do {
            let identity = try TaskDirectoryIdentity.capture(directory)
            let root = URL(fileURLWithPath: identity.canonicalPath)
            let denied = denied.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            guard !isDenied(root, denied: denied) else { throw TaskArtifactError.unsafeFile }
            guard paths.allSatisfy({ !isDenied(root.appendingPathComponent($0), denied: denied) }) else {
                throw TaskArtifactError.unsafeFile
            }
            let before = try await Task.detached { try scan(root: root, identity: identity, paths: paths, denied: denied) }.value
            return Self(root: root, identity: identity, paths: paths, denied: denied, before: before)
        } catch {
            throw ToolExecutionFailure(message: "Artifact discovery could not safely inspect the working directory. Nothing was executed. Use artifact_paths to name a smaller set of output files/folders inside working_directory, or choose a narrower working directory.")
        }
    }

    func finish(_ result: ChildProcessResult) async throws -> String {
        switch result.outcome {
        case .launchFailed, .indeterminate: return ""
        default: break
        }
        let after: Scan
        do { after = try await Task.detached { try Self.scan(root: root, identity: identity, paths: paths, denied: denied) }.value }
        catch {
            throw ToolExecutionFailure(message: "The command has already run, but artifact discovery could not finish safely. Inspect its working directory; do not repeat the command automatically. Existing outputs were not rolled back.")
        }
        var failed = false
        for path in after.files.keys.sorted() {
            guard let stamp = after.files[path], before.files[path] != stamp else { continue }
            do {
                try await ToolArtifactCapture.record(root.appendingPathComponent(path), root: root,
                    observedChange: true, expected: stamp, rootIdentity: identity)
            } catch { failed = true }
        }
        if failed {
            throw ToolExecutionFailure(message: "The command has already run, but some changed files could not be retained safely. Inspect the existing outputs; do not repeat the command automatically.")
        }
        let skipped = max(before.skipped, after.skipped)
        return skipped == 0 ? "" : "\nArtifact discovery excluded \(skipped) linked, special or private entries. Only regular files inside the approved output scope were retained."
    }

    private static func requestedPaths(_ raw: Any?, root: URL) throws -> [String] {
        guard let raw else { return [""] }
        guard let paths = raw as? [String], !paths.isEmpty, paths.count <= 32 else {
            throw ToolExecutionFailure(message: "artifact_paths must contain 1–32 relative output files/folders inside working_directory. Nothing was executed.")
        }
        return try paths.map { path in
            guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"),
                  !path.split(separator: "/").contains("..") else { throw TaskArtifactError.unsafeFile }
            if path == "." { return "" }
            let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
            guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { throw TaskArtifactError.unsafeFile }
            return target.path == root.path ? "" : String(target.path.dropFirst(root.path.count + 1))
        }
    }

    private static func scan(root: URL, identity: TaskDirectoryIdentity, paths: [String], denied: [URL]) throws -> Scan {
        guard identity.matches(root) else { throw TaskArtifactError.unsafeFile }
        let directory = try AppDirectory(url: root, create: false)
        var result = Scan(), visited = Set<String>()
        func visit(_ parent: AppDirectory, name: String, relative: String, depth: Int) throws {
            guard visited.insert(relative).inserted else { return }
            guard visited.count <= entryLimit, depth <= depthLimit else { throw NativeAppError(.capacity) }
            let url = root.appendingPathComponent(relative)
            if isDenied(url, denied: denied) { result.skipped += 1; return }
            var info = stat()
            guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return }
                throw TaskArtifactError.unavailable
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                try walk(parent.child(name, create: false), relative: relative, depth: depth)
            } else if info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 {
                result.files[relative] = ArtifactFileStamp(info)
            } else { result.skipped += 1 }
        }
        func walk(_ directory: AppDirectory, relative: String, depth: Int) throws {
            for name in try directory.names(limit: entryLimit).sorted() {
                try visit(directory, name: name, relative: relative.isEmpty ? name : relative + "/" + name, depth: depth + 1)
            }
        }
        for path in paths {
            if path.isEmpty { try walk(directory, relative: "", depth: 0); continue }
            let parts = try BackupFileIO.components(path)
            var parent = directory, missing = false, prefix = ""
            for part in parts.dropLast() {
                prefix += prefix.isEmpty ? part : "/" + part
                let url = root.appendingPathComponent(prefix)
                guard !isDenied(url, denied: denied) else { throw TaskArtifactError.unsafeFile }
                var info = stat()
                if fstatat(parent.fd, part, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else { throw TaskArtifactError.unavailable }
                    missing = true; break
                }
                guard info.st_mode & S_IFMT == S_IFDIR else { throw TaskArtifactError.unsafeFile }
                parent = try parent.child(part, create: false)
            }
            if !missing, let name = parts.last { try visit(parent, name: name, relative: path, depth: parts.count) }
        }
        guard identity.matches(root) else { throw TaskArtifactError.unsafeFile }
        return result
    }

    private static func isDenied(_ url: URL, denied: [URL]) -> Bool {
        denied.contains { url.path == $0.path || url.path.hasPrefix($0.path + "/") }
    }
}
