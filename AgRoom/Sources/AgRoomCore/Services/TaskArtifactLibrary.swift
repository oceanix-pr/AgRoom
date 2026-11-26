import Darwin
import Foundation
import Synchronization
import GRDB

public enum TaskArtifactContentFilter: String, CaseIterable, Sendable { case all, retained, referenceOnly }

public struct TaskArtifactLibrarySummary: Equatable, Sendable {
    public let versions: Int
    public let retainedVersions: Int
    public let retainedBytes: Int64
}

public struct TaskArtifactCacheSummary: Equatable, Sendable {
    public let files: Int
    public let bytes: Int64
}

public struct TaskArtifactLibraryPage: Sendable {
    public struct Cursor: Sendable {
        let date: String
        let id: String
    }
    public let items: [TaskArtifactVersion]
    public let next: Cursor?
}

/// An explicit preview or pending attachment keeps the disposable copy alive.
/// Cross-process file leases coordinate cleanup; no memory lock covers I/O.
public final class TaskArtifactPreviewPin: Sendable {
    private let lease: Mutex<ResourceMaintenance.Lease?>
    init(_ lease: ResourceMaintenance.Lease) { self.lease = Mutex(lease) }
    /// UI frameworks may retain an old presentation value after dismissal.
    /// Release its usage explicitly; the lock owns only the reference transfer.
    public func release() {
        let previous = lease.withLock { value in let old = value; value = nil; return old }
        withExtendedLifetime(previous) {}
    }
}

public extension TaskArtifactStore {
    static let didChange = Notification.Name("agroom.artifact.versions.changed")

    func librarySummary() async throws -> TaskArtifactLibrarySummary {
        try await queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS versions,COUNT(contents) AS retained,COALESCE(SUM(COALESCE(length(contents),0)+COALESCE(length(beforeContents),0)),0) AS bytes FROM artifact_versions")!
            return TaskArtifactLibrarySummary(versions: row["versions"], retainedVersions: row["retained"], retainedBytes: row["bytes"])
        }
    }

    /// Bounded metadata only, including versions whose conversation save failed.
    func libraryPage(search: String = "", filter: TaskArtifactContentFilter = .all,
                     before: TaskArtifactLibraryPage.Cursor? = nil, limit: Int = 40,
                     includeHidden: Bool = false) async throws -> TaskArtifactLibraryPage {
        let count = min(100, max(1, limit)), text = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4096))
        return try await queue.read { db in
            var clauses = ["1=1"], args = StatementArguments()
            if !includeHidden { clauses.append("NOT EXISTS(SELECT 1 FROM chat_sessions s WHERE s.id=artifact_versions.sessionID AND s.isHidden=1)") }
            if !text.isEmpty {
                let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                clauses.append("(path LIKE ? ESCAPE '\\' OR logicalPath LIKE ? ESCAPE '\\')")
                args += ["%" + escaped + "%", "%" + escaped + "%"]
            }
            if filter == .retained { clauses.append("contents IS NOT NULL") }
            if filter == .referenceOnly { clauses.append("contents IS NULL") }
            if let before {
                clauses.append("(createdAt < ? OR (createdAt = ? AND id < ?))")
                args += [before.date, before.date, before.id]
            }
            args += [count + 1]
            let rows = try Row.fetchAll(db, sql: "SELECT id,createdAt,metadata FROM artifact_versions WHERE " + clauses.joined(separator: " AND ") + " ORDER BY createdAt DESC,id DESC LIMIT ?", arguments: args)
            let page = Array(rows.prefix(count))
            let items = try page.map { row -> TaskArtifactVersion in
                let data: Data = row["metadata"], id: String = row["id"]
                let record = try Self.decode(data, space: space)
                guard record.id.uuidString == id else { throw TaskArtifactError.unavailable }
                return record
            }
            let next: TaskArtifactLibraryPage.Cursor? = rows.count > count ? page.last.map { .init(date: $0["createdAt"], id: $0["id"]) } : nil
            return TaskArtifactLibraryPage(items: items, next: next)
        }
    }

    func currentArtifacts(_ ids: [UUID]) async throws -> [TaskArtifact] {
        try await queue.read { db in
            try Array(Set(ids).prefix(100)).compactMap { id in
                guard let data = try Data.fetchOne(db, sql: "SELECT metadata FROM artifact_versions WHERE id=?", arguments: [id.uuidString]) else { return nil }
                let record = try Self.decode(data, space: space)
                guard record.id == id else { throw TaskArtifactError.unavailable }
                return record.artifact
            }
        }
    }

    func sourceSessionExists(for version: TaskArtifactVersion) async throws -> Bool {
        try await queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT metadata FROM artifact_versions WHERE id=?", arguments: [version.id.uuidString]) else { return false }
            let stored = try Self.decode(data, space: space)
            guard stored.id == version.id, stored.artifact.path == version.artifact.path, let sessionID = stored.sessionID else { return false }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat_sessions WHERE id=?)", arguments: [sessionID.uuidString]) ?? false
        }
    }

    /// Requires an explicit UI confirmation. The source file and provenance stay.
    /// Cache cleanup after commit is retryable without repeating a file operation.
    func removeRetainedContents(_ artifacts: [TaskArtifact]) async throws {
        guard !artifacts.isEmpty, artifacts.count <= 100,
              artifacts.allSatisfy({ $0.sourceSpace == space && $0.versionID != nil }) else { throw TaskArtifactError.unavailable }
        try await ResourceMaintenance.withAsyncAccess(queue.maintenanceKey) {
            try await withCacheMutation {
                try await queue.maintenanceWrite { db in
                    for expected in artifacts {
                        let id = expected.versionID!
                        guard let data = try Data.fetchOne(db, sql: "SELECT metadata FROM artifact_versions WHERE id=?", arguments: [id.uuidString]) else { continue }
                        var record = try Self.decode(data, space: space)
                        guard record.id == id, record.artifact.path == expected.path, record.artifact.sha256 == expected.sha256 else { throw TaskArtifactError.changedFile }
                        // A repeated cleanup is harmless. Metadata-only receipts keep
                        // their original reason; they never promised retained bytes.
                        guard record.artifact.contentRetained == true else { continue }
                        record.artifact.contentRetained = false
                        record.artifact.retentionReason = .removedByUser
                        record.artifact.change?.beforeRetained = false
                        try db.execute(sql: "UPDATE artifact_versions SET contents=NULL,beforeContents=NULL,metadata=? WHERE id=?", arguments: [try JSONEncoder().encode(record), id.uuidString])
                    }
                }
                await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: space.rawValue) }
                do { try await Task.detached { try Self.removeCache(root: previewRoot, ids: artifacts.compactMap(\.versionID)) }.value }
                catch { throw TaskArtifactError.cacheCleanupPending }
            }
        }
    }

    func pinPreview(_ artifact: TaskArtifact, at url: URL) throws -> TaskArtifactPreviewPin {
        guard artifact.sourceSpace == space, let id = artifact.versionID,
              url.standardizedFileURL.path == previewRoot.appendingPathComponent(id.uuidString).appendingPathComponent(Self.snapshotName(artifact)).standardizedFileURL.path else { throw TaskArtifactError.unsafeFile }
        let lease = try ResourceMaintenance.Lease(key: cacheMaintenanceKey, exclusive: false)
        do {
            let directory = try AppDirectory(url: previewRoot, create: false).child(id.uuidString, create: false)
            try directory.checkRegular(url.lastPathComponent, missingOK: false, limit: Self.maximumSnapshotBytes)
            return TaskArtifactPreviewPin(lease)
        } catch { throw TaskArtifactError.unavailable }
    }

    func previewCacheSummary() async throws -> TaskArtifactCacheSummary {
        try await ResourceMaintenance.withAsyncAccess(cacheMaintenanceKey) {
            try await Task.detached {
                guard let root = try Self.cacheRoot(previewRoot) else { return .init(files: 0, bytes: 0) }
                var files = 0, bytes: Int64 = 0, entries = 0
                func visit(_ directory: AppDirectory, depth: Int) throws {
                    guard depth <= 8 else { throw TaskArtifactError.unsafeFile }
                    for name in try directory.names(limit: 100_000) {
                        entries += 1
                        guard entries <= 100_000 else { throw TaskArtifactError.storage }
                        var info = stat()
                        guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw TaskArtifactError.storage }
                        if info.st_mode & S_IFMT == S_IFDIR { try visit(directory.child(name, create: false), depth: depth + 1) }
                        else if info.st_mode & S_IFMT == S_IFREG {
                            guard info.st_size >= 0, bytes <= Int64.max - info.st_size else { throw TaskArtifactError.storage }
                            files += 1; bytes += info.st_size
                        }
                    }
                }
                try visit(root, depth: 0)
                return TaskArtifactCacheSummary(files: files, bytes: bytes)
            }.value
        }
    }

    func clearPreviewCache() async throws {
        try await withCacheMutation { try await Task.detached { try Self.removeCache(root: previewRoot, ids: nil) }.value }
    }

    /// Removes deleted-session previews without touching still-retained versions.
    func pruneOrphanedPreviews() async throws {
        try await ResourceMaintenance.withAsyncAccess(queue.maintenanceKey) {
            try await withCacheMutation {
                let names = try await Task.detached { try Self.cacheRoot(previewRoot)?.names(limit: 100_000) ?? [] }.value
                for chunkStart in stride(from: 0, to: names.count, by: 100) {
                    let chunk = Array(names[chunkStart..<min(names.count, chunkStart + 100)])
                    let orphaned = try await queue.read { db in
                        try chunk.filter { name in
                            guard let id = UUID(uuidString: name) else { return false }
                            return try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM artifact_versions WHERE id=? AND contents IS NOT NULL)", arguments: [id.uuidString])!
                        }
                    }
                    try await Task.detached { try Self.removeCache(root: previewRoot, ids: orphaned.compactMap(UUID.init(uuidString:))) }.value
                }
            }
        }
    }
}

extension TaskArtifactStore {
    var cacheMaintenanceKey: String { ResourceMaintenance.directoryKey(previewRoot) }

    private func withCacheMutation<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await ResourceMaintenance.withExclusive([cacheMaintenanceKey], operation: body) }
        catch MaintenanceError.busy { throw TaskArtifactError.previewInUse }
    }

    private static func cacheRoot(_ root: URL) throws -> AppDirectory? {
        do { return try AppDirectory(url: root, create: false) }
        catch let error as NativeAppError where error.code == .missing { return nil }
        catch let error as NativeAppError where error.code == .unsafePath { throw TaskArtifactError.unsafeFile }
        catch { throw TaskArtifactError.storage }
    }

    private static func removeCache(root: URL, ids: [UUID]?) throws {
        guard let directory = try cacheRoot(root) else { return }
        let names = try ids.map { $0.map(\.uuidString) } ?? directory.names(limit: 100_000)
        for name in names where directory.exists(name) { try directory.removeTree(name) }
    }
}
