import Darwin
import Foundation
import GRDB

public struct TaskArtifactEditScope: Sendable, Equatable {
    public let sessionID: UUID
    public let runID: UUID
    public let workspace: ChatWorkspace

    public init(sessionID: UUID, runID: UUID, workspace: ChatWorkspace) {
        self.sessionID = sessionID
        self.runID = runID
        self.workspace = workspace
    }
}

public enum TaskArtifactUndoStatus: Sendable { case available, undone, unavailable }
public enum TaskArtifactUndoError: Error, Equatable {
    case unavailable
    case changed(String)
    case interrupted(path: String, completed: Int)
}

private struct FileUndo: Sendable {
    let original: TaskArtifactVersion
    let latest: TaskArtifact
    let root: TaskDirectoryIdentity
    let versionIDs: [UUID]
    let recoveryIDs: [String]
    let undone: Bool
}

extension TaskArtifactStore {
    /// Only fresh local write receipts can authorize undo. Imported versions and older
    /// results remain reviewable without turning an archived path into a write grant.
    private func undoFiles(_ artifacts: [TaskArtifact], scope: TaskArtifactEditScope) async throws -> [FileUndo] {
        guard scope.workspace.space == space, !artifacts.isEmpty,
              Set(artifacts.map(\.path)).count == artifacts.count else { throw TaskArtifactUndoError.unavailable }
        return try await queue.read { db in
            try artifacts.map { artifact in
                guard artifact.sourceSpace == space, let id = artifact.versionID else { throw TaskArtifactUndoError.unavailable }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT a.metadata, r.rootIdentity, r.undone, r.recoveryID FROM artifact_versions a
                    LEFT JOIN artifact_edit_receipts r ON r.versionID = a.id
                    WHERE a.runID=? AND a.sessionID=? AND a.workspaceID=? AND a.path=? ORDER BY a.version LIMIT 1001
                    """, arguments: [scope.runID.uuidString, scope.sessionID.uuidString, scope.workspace.id.uuidString, artifact.path])
                guard !rows.isEmpty, rows.count <= 1000 else { throw TaskArtifactUndoError.unavailable }
                var history: [TaskArtifactVersion] = []
                var root: TaskDirectoryIdentity?
                var undone: Bool?
                var recoveries: [String] = []
                for row in rows {
                    let version = try Self.decode(row["metadata"], space: space)
                    guard let identity: Data = row["rootIdentity"], let wasUndone: Bool = row["undone"],
                          let change = version.artifact.change, version.artifact.sha256 != nil,
                          version.runID == scope.runID, version.sessionID == scope.sessionID,
                          version.workspaceID == scope.workspace.id.uuidString, version.artifact.path == artifact.path else {
                        throw TaskArtifactUndoError.unavailable
                    }
                    let recordedRoot = try JSONDecoder().decode(TaskDirectoryIdentity.self, from: identity)
                    if let prior = history.last {
                        guard root == recordedRoot, undone == wasUndone, change.kind == .modified,
                              change.beforeSHA256 == prior.artifact.sha256 else { throw TaskArtifactUndoError.unavailable }
                    }
                    root = recordedRoot
                    undone = wasUndone
                    if let recoveryID: String = row["recoveryID"] { recoveries.append(recoveryID) }
                    history.append(version)
                }
                guard let first = history.first, let last = history.last, last.id == id, let root, let undone,
                      undone || (first.artifact.change?.beforeRetained == true && last.artifact.contentRetained == true)
                else { throw TaskArtifactUndoError.unavailable }
                return FileUndo(original: first, latest: last.artifact, root: root, versionIDs: history.map(\.id),
                    recoveryIDs: recoveries, undone: undone)
            }
        }
    }

    public func undoStatus(for artifacts: [TaskArtifact], scope: TaskArtifactEditScope) async throws -> TaskArtifactUndoStatus {
        do {
            let files = try await undoFiles(artifacts, scope: scope)
            return files.allSatisfy(\.undone) ? .undone : .available
        } catch TaskArtifactUndoError.unavailable { return .unavailable }
    }

    /// Called after the user confirms this exact result. Preflight all files under
    /// the same path leases as managed edits before publishing the first restore.
    public func undoEdits(_ artifacts: [TaskArtifact], scope: TaskArtifactEditScope) async throws {
        try await ResourceMaintenance.withAsyncAccess(queue.maintenanceKey) {
            try await undoLocalEdits(artifacts, scope: scope)
        }
    }

    private func undoLocalEdits(_ artifacts: [TaskArtifact], scope: TaskArtifactEditScope) async throws {
        let pin = try pinComparison()
        defer { pin.release() }
        let leaseOwner = UUID()
        var leases: [TeamLease] = []
        do {
            let initial = try await undoFiles(artifacts, scope: scope)
            for file in initial.sorted(by: { $0.latest.path < $1.latest.path }) where !file.undone {
                leases.append(try await TeamLeaseCenter.shared.acquire(space: space.rawValue, path: file.latest.path,
                    taskID: scope.runID, subtaskID: leaseOwner, ttl: 600))
            }
            let files = try await undoFiles(artifacts, scope: scope).filter { !$0.undone }
            let service = FileAreaService.standard.scoped(to: scope.workspace.folderURLs)
            for file in files {
                try Task.checkCancellation()
                _ = try currentEdit(file, service: service)
            }
            var completed = 0
            for file in files {
                do {
                    try Task.checkCancellation()
                    let before: Data? = try await queue.read { db in
                        let bytes = try Data.fetchOne(db, sql: "SELECT beforeContents FROM artifact_versions WHERE id=?",
                            arguments: [file.original.id.uuidString])
                        try Self.validateBaseline(file.original, contents: bytes)
                        return bytes
                    }
                    if let current = try currentEdit(file, service: service) {
                        let target = URL(fileURLWithPath: file.latest.path)
                        let root = URL(fileURLWithPath: file.root.canonicalPath)
                        if let before {
                            try SecureFileWriter.write(before, to: target, root: root, policy: .matching(current), expectedRoot: file.root)
                        } else {
                            let directory = try pinnedRoot(file.root)
                            let relative = String(target.path.dropFirst(root.path.count + 1))
                            guard let digest = file.latest.sha256 else { throw TaskArtifactUndoError.unavailable }
                            let expected = BackupFileIO.Receipt(byteCount: current.count, sha256: digest, executable: false)
                            try BackupFileIO.removeUnchanged(relative, in: directory, expected: expected, limit: Self.maximumSnapshotBytes)
                        }
                    }
                    try await queue.maintenanceWrite { db in
                        for id in file.versionIDs {
                            try db.execute(sql: "UPDATE artifact_edit_receipts SET undone=1 WHERE versionID=?", arguments: [id.uuidString])
                        }
                        for id in file.recoveryIDs {
                            try db.execute(sql: "UPDATE task_file_recoveries SET state='reverted', revertedAt=? WHERE id=? AND space=? AND path=?",
                                arguments: [Date(), id, space.rawValue, file.latest.path])
                        }
                        try CodingTaskStore.noteRestore(in: db, sessionID: scope.sessionID, workspace: file.root, path: file.latest.path,
                            expectedDigest: file.latest.sha256, restoredDigest: file.original.artifact.change?.beforeSHA256)
                    }
                    completed += 1
                } catch { throw TaskArtifactUndoError.interrupted(path: file.latest.path, completed: completed) }
            }
        } catch {
            for lease in leases { await TeamLeaseCenter.shared.release(lease) }
            if case TaskArtifactUndoError.interrupted = error {
                await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: space.rawValue) }
            }
            throw error
        }
        for lease in leases { await TeamLeaseCenter.shared.release(lease) }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: space.rawValue) }
    }

    private func pinnedRoot(_ identity: TaskDirectoryIdentity) throws -> AppDirectory {
        let root = try AppDirectory(url: URL(fileURLWithPath: identity.canonicalPath), create: false)
        var info = stat()
        guard fstat(root.fd, &info) == 0, UInt64(bitPattern: Int64(info.st_dev)) == identity.device,
              UInt64(info.st_ino) == identity.inode else { throw TaskArtifactUndoError.unavailable }
        return root
    }

    /// nil means the baseline is already on disk (e.g. a retry after the file was
    /// restored but recording the result failed). Never write over a third version.
    private func currentEdit(_ file: FileUndo, service: FileAreaService) throws -> Data? {
        let path = file.latest.path
        let root = URL(fileURLWithPath: file.root.canonicalPath)
        guard service.scopedRoots?.contains(where: { $0.path == root.path }) == true else { throw TaskArtifactUndoError.unavailable }
        let reader = try RepositoryReader(root: root, service: service, space: space)
        guard reader.identity == file.root, try reader.resolve(path).path == path, path.hasPrefix(root.path + "/") else {
            throw TaskArtifactUndoError.unavailable
        }
        do {
            let directory = try pinnedRoot(file.root)
            let relative = String(path.dropFirst(root.path.count + 1))
            let (parent, name) = try BackupFileIO.parent(relative, in: directory, create: false)
            var info = stat()
            if fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT, file.original.artifact.change?.kind == .created { return nil }
                throw TaskArtifactUndoError.changed(path)
            }
            let data = try parent.read(name, limit: Self.maximumSnapshotBytes)
            let digest = ManagedTextSnapshot.digest(data)
            if digest == file.original.artifact.change?.beforeSHA256 { return nil }
            guard digest == file.latest.sha256 else { throw TaskArtifactUndoError.changed(path) }
            return data
        } catch { throw TaskArtifactUndoError.changed(path) }
    }
}
