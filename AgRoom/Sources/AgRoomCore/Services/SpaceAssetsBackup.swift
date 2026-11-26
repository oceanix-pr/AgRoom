import Darwin
import Foundation
import GRDB

struct SpaceAssetsArchive: Codable, Sendable, Equatable {
    struct App: Codable, Sendable, Equatable {
        let id: String
        let file: String
        let fingerprint: String
        let records: Int
        let files: Int
    }
    struct Project: Codable, Sendable, Equatable {
        let id: UUID
        let workspaceID: UUID
        let referenceID: UUID?
        let name: String
        let sourcePath: String
        var directories: [String]
    }
    struct File: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case project, database, knowledge, skillHistory }
        let kind: Kind
        let projectID: UUID?
        let relativePath: String
        let sourcePath: String
        let file: String
        let receipt: BackupFileIO.Receipt
    }
    let space: String
    var apps: [App] = []
    var drafts: [NativeAppPendingDraft] = []
    var projects: [Project] = []
    var files: [File] = []
    var omittedWorkspaces: [String] = []
    var omittedLinks: [String] = []
    var recordCount: Int { apps.count + drafts.count + projects.count + files.count }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.space == rhs.space && lhs.apps == rhs.apps && lhs.drafts == rhs.drafts && lhs.projects == rhs.projects
            && lhs.files == rhs.files && lhs.omittedWorkspaces == rhs.omittedWorkspaces && lhs.omittedLinks == rhs.omittedLinks
    }
}

struct SpaceAssetsRestorePlan: Codable, Sendable {
    struct App: Codable, Sendable {
        let id: String
        let file: String
        let beforeFile: String?
        let beforeFingerprint: String?
        let afterFingerprint: String
    }
    struct File: Codable, Sendable {
        let source: SpaceAssetsArchive.File
        let destination: String
    }
    let id: UUID
    var apps: [App]
    var drafts: [NativeAppPendingDraft]
    var files: [File]
    var workspaces: [ChatWorkspace]
    var directories: [String]
    var workspaceMappings: [String: String]?
    var pathMappings: [String: String] { Dictionary(files.map { ($0.source.sourcePath, $0.destination) }, uniquingKeysWith: { first, _ in first }) }
}

/// A fixed space root and explicitly supplied workspace list. Portable paths are
/// data only: every restore destination is freshly allocated inside this space.
struct SpaceAssetsBackupStore: Sendable {
    let space: AppSpace
    let spaceRoot: URL
    let fileArea: FileAreaService
    var apps: NativeAppStore { .init(directoryURL: spaceRoot.appendingPathComponent("apps"), space: space) }
    var drafts: NativeAppDraftStore { .init(directoryURL: spaceRoot.appendingPathComponent("app-drafts"), space: space) }
    var maintenanceKeys: [String] { [apps.directoryURL, drafts.directoryURL].map(ResourceMaintenance.directoryKey) }
    static let maximumFileBytes = 256 * 1024 * 1024
    static let maximumInventoryBytes = 32 * 1024 * 1024

    func export(to staging: URL, workspaces: [ChatWorkspace], includeExternal: Bool) async throws -> SpaceAssetsArchive {
        let root = try AppDirectory(url: staging, create: false)
        _ = try root.child("space-assets", create: true)
        var result = SpaceAssetsArchive(space: space.rawValue)
        let catalog = try await apps.catalog()
        guard catalog.invalidIDs.isEmpty else { throw BackupError.preflightFailed("Repair unreadable mini-apps before creating a complete space backup") }
        for app in (catalog.apps + catalog.retainedApps).sorted(by: { $0.id < $1.id }) {
            let archive = try await apps.backup(id: app.id, space: space)
            let path = "space-assets/apps/" + app.id + ".json"
            try BackupFileIO.write(archive.encoded(), path: path, in: root)
            result.apps.append(.init(id: app.id, file: path, fingerprint: archive.fingerprint, records: archive.recordCount, files: archive.fileCount))
        }
        let pending = try await drafts.catalog()
        guard pending.invalidIDs.isEmpty else { throw BackupError.preflightFailed("Repair unreadable mini-app drafts before backing up") }
        result.drafts = pending.drafts

        let managed = [fileArea.defaultChatRoot(for: space)] + fileArea.defaultWriteRoots(for: space) + [fileArea.filesRoot]
        for workspace in workspaces where workspace.space == space {
            let folders: [(UUID?, URL)] = [(nil, workspace.url)] + workspace.referencedFolders.map { ($0.id, $0.url) }
            for (reference, url) in folders {
                let path = url.standardizedFileURL.path
                let isManaged = managed.contains { FileAreaService.isInside(url, root: $0) }
                guard isManaged || includeExternal else { result.omittedWorkspaces.append(path); continue }
                guard FileManager.default.fileExists(atPath: path) else { result.omittedWorkspaces.append(path); continue }
                let group = SpaceAssetsArchive.Project(id: UUID(), workspaceID: workspace.id, referenceID: reference,
                    name: workspace.name.isEmpty ? url.lastPathComponent : workspace.name, sourcePath: path, directories: [])
                result.projects.append(group)
            }
        }
        // Skill output areas are space-owned even without a chat workspace entry.
        for url in fileArea.defaultWriteRoots(for: space) where FileManager.default.fileExists(atPath: url.path) {
            if !result.projects.contains(where: { $0.sourcePath == url.standardizedFileURL.path }) {
                let group = SpaceAssetsArchive.Project(id: UUID(), workspaceID: UUID(), referenceID: nil,
                    name: url.lastPathComponent, sourcePath: url.standardizedFileURL.path, directories: [])
                result.projects.append(group)
            }
        }
        for project in result.projects {
            try collect(directoryURL: URL(fileURLWithPath: project.sourcePath), kind: .project, projectID: project.id, staging: staging, archive: &result)
        }
        for (folder, kind) in [("databases", SpaceAssetsArchive.File.Kind.database), ("knowledge-assets", .knowledge), ("skills/.versions", .skillHistory)] {
            let url = spaceRoot.appendingPathComponent(folder)
            if FileManager.default.fileExists(atPath: url.path) {
                try collect(directoryURL: url, kind: kind, projectID: nil, staging: staging, archive: &result)
            }
        }
        return result
    }

    private func collect(directoryURL: URL, kind: SpaceAssetsArchive.File.Kind, projectID: UUID?,
                         staging: URL, archive: inout SpaceAssetsArchive) throws {
        let source = try AppDirectory(url: directoryURL, create: false)
        let target = try AppDirectory(url: staging, create: false)
        var total = archive.files.reduce(0) { $0 + $1.receipt.byteCount }
        func walk(_ directory: AppDirectory, relative: String, depth: Int) throws {
            guard depth < 48 else { throw BackupError.preflightFailed("Project folder nesting exceeds the backup limit") }
            let names = try directory.names(limit: BackupService.maxExtractedFileCount).sorted()
            for name in names {
                try Task.checkCancellation()
                let path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NativeAppError(.storage) }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let fullPath = directoryURL.appendingPathComponent(path).standardizedFileURL.path
                    if archive.projects.contains(where: { $0.id != projectID && $0.sourcePath == fullPath }) { continue }
                    if let index = archive.projects.firstIndex(where: { $0.id == projectID }) { archive.projects[index].directories.append(path) }
                    try walk(directory.child(name, create: false), relative: path, depth: depth + 1)
                } else if info.st_mode & S_IFMT != S_IFREG || info.st_nlink != 1 {
                    archive.omittedLinks.append(directoryURL.appendingPathComponent(path).path)
                } else {
                    // Sidecars are represented by the transactionally backed-up database.
                    if (name.hasSuffix(".sqlite-wal") || name.hasSuffix(".sqlite-shm")),
                       directory.exists(String(name.dropLast(4))) { continue }
                    let packed = "space-assets/objects/" + UUID().uuidString
                    let receipt: BackupFileIO.Receipt
                    if name.hasSuffix(".sqlite") {
                        receipt = try snapshotSQLite(name: name, in: directory, target: target, packed: packed, staging: staging)
                    } else {
                        receipt = try BackupFileIO.copy(path, from: source, to: target, as: packed, limit: Self.maximumFileBytes)
                    }
                    total += receipt.byteCount
                    guard total <= BackupService.maxExtractedByteCount, archive.files.count < BackupService.maxExtractedFileCount - 100 else { throw NativeAppError(.tooLarge) }
                    archive.files.append(.init(kind: kind, projectID: projectID, relativePath: path,
                        sourcePath: directoryURL.appendingPathComponent(path).path, file: packed, receipt: receipt))
                }
            }
        }
        try walk(source, relative: "", depth: 0)
    }

    private func snapshotSQLite(name: String, in source: AppDirectory, target: AppDirectory, packed: String, staging: URL) throws -> BackupFileIO.Receipt {
        try source.checkRegular(name, missingOK: false, limit: Self.maximumFileBytes)
        let directoryURL = try source.kernelURL()
        var before = stat(), after = stat()
        guard fstatat(source.fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw NativeAppError(.storage) }
        let snapshot = staging.appendingPathComponent(".sqlite-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        var configuration = Configuration(); configuration.readonly = true
        let input = try DatabaseQueue(path: directoryURL.appendingPathComponent(name).path, configuration: configuration)
        let output = try DatabaseQueue(path: snapshot.path)
        try input.backup(to: output)
        try output.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=DELETE") }
        try source.verifyIdentity(at: directoryURL)
        guard fstatat(source.fd, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, after.st_mode & S_IFMT == S_IFREG,
              after.st_nlink == 1 else { throw NativeAppError(.unsafePath) }
        return try BackupFileIO.copy(snapshot.lastPathComponent, from: AppDirectory(url: staging, create: false),
            to: target, as: packed, limit: Self.maximumFileBytes)
    }

    func validate(_ archive: SpaceAssetsArchive, staging: URL, sourceSpace: String) throws {
        guard archive.space == sourceSpace, AppSpace(rawValue: sourceSpace) != nil,
              archive.files.count <= BackupService.maxExtractedFileCount,
              Set(archive.projects.map(\.id)).count == archive.projects.count,
              Set(archive.apps.map(\.id)).count == archive.apps.count,
              Set(archive.files.map(\.file)).count == archive.files.count,
              Set(archive.drafts.map(\.id)).count == archive.drafts.count else { throw BackupError.preflightFailed("Invalid space asset inventory") }
        let root = try AppDirectory(url: staging, create: false)
        let groups = Set(archive.projects.map(\.id))
        let primaries = archive.projects.filter { $0.referenceID == nil }
        guard Set(primaries.map(\.workspaceID)).count == primaries.count,
              archive.projects.allSatisfy({ project in
                  !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && project.name.utf8.count <= 255
                    && project.sourcePath.hasPrefix("/") && project.directories.count <= BackupService.maxExtractedFileCount
                    && (project.referenceID == nil || primaries.contains(where: { $0.workspaceID == project.workspaceID }))
              }) else { throw BackupError.preflightFailed("Invalid project inventory") }
        var destinations = Set<String>()
        for file in archive.files {
            _ = try BackupFileIO.components(file.relativePath)
            guard file.file.hasPrefix("space-assets/objects/"), file.sourcePath.hasPrefix("/"),
                  file.receipt.byteCount >= 0, file.receipt.byteCount <= Self.maximumFileBytes,
                  (file.kind == .project ? file.projectID.map(groups.contains) == true : file.projectID == nil),
                  destinations.insert("\(file.kind):\(file.projectID?.uuidString ?? ""):\(file.relativePath)").inserted else {
                throw BackupError.preflightFailed("Invalid space asset path")
            }
            let receipt = try BackupFileIO.receipt(file.file, in: root, limit: Self.maximumFileBytes)
            guard receipt.byteCount == file.receipt.byteCount && receipt.sha256 == file.receipt.sha256 else { throw BackupError.preflightFailed("Space asset checksum mismatch") }
        }
        for project in archive.projects { for path in project.directories { _ = try BackupFileIO.components(path) } }
        for app in archive.apps {
            guard app.file.hasPrefix("space-assets/apps/") else { throw BackupError.preflightFailed("Invalid mini-app asset path") }
            let value = try NativeAppBackup.decode(BackupFileIO.read(app.file, in: root, limit: NativeAppBackup.maximumBytes))
            guard value.space.rawValue == sourceSpace, value.definition.id == app.id, value.fingerprint == app.fingerprint,
                  value.recordCount == app.records, value.fileCount == app.files else { throw BackupError.preflightFailed("Mini-app backup inventory mismatch") }
        }
        for draft in archive.drafts {
            guard draft.space.rawValue == sourceSpace else { throw BackupError.preflightFailed("Mini-app draft belongs to another space") }
            try draft.definition.validate()
        }
    }

    func prepare(_ archive: SpaceAssetsArchive, staging: URL, id: UUID, recovery: URL) async throws -> SpaceAssetsRestorePlan {
        try validate(archive, staging: staging, sourceSpace: archive.space)
        let root = try AppDirectory(url: staging, create: false)
        let privateRecovery = try AppDirectory(url: recovery, create: true)
        var result = SpaceAssetsRestorePlan(id: id, apps: [], drafts: [], files: [], workspaces: [], directories: [])
        for app in archive.apps {
            let backup = try retarget(NativeAppBackup.decode(BackupFileIO.read(app.file, in: root, limit: NativeAppBackup.maximumBytes)))
            let current = try await apps.inspectRestore(backup, space: space)
            guard !current.currentDataIsUnreadable else { throw BackupError.preflightFailed("Repair the existing mini-app before restoring the space") }
            var beforeFile: String?
            if current.previousFingerprint != nil {
                let before = try await apps.backup(id: app.id, space: space)
                beforeFile = "apps/" + app.id + ".json"
                try BackupFileIO.write(before.encoded(), path: beforeFile!, in: privateRecovery)
            }
            result.apps.append(.init(id: app.id, file: app.file, beforeFile: beforeFile,
                beforeFingerprint: current.previousFingerprint, afterFingerprint: backup.fingerprint))
        }
        let existing = try await drafts.catalog()
        guard existing.invalidIDs.isEmpty else { throw BackupError.preflightFailed("Repair unreadable mini-app drafts before restoring") }
        for draft in archive.drafts {
            let value = NativeAppPendingDraft(id: draft.id, space: space, createdAt: draft.createdAt,
                definition: draft.definition, sourceSessionID: draft.sourceSessionID, updatingAppID: draft.updatingAppID)
            if existing.drafts.contains(value) { continue }
            let imported = existing.drafts.contains(where: { $0.id == value.id })
                ? NativeAppPendingDraft(id: UUID(), space: space, createdAt: value.createdAt, definition: value.definition,
                    sourceSessionID: value.sourceSessionID, updatingAppID: value.updatingAppID) : value
            result.drafts.append(imported)
        }
        guard existing.drafts.count + result.drafts.count <= 8 else { throw BackupError.preflightFailed("Mini-app draft capacity would be exceeded. Review pending drafts first.") }
        let projectsRoot = fileArea.defaultChatRoot(for: space).appendingPathComponent("Restored/" + id.uuidString)
        var groups: [UUID: URL] = [:]
        var sourceRoots: [String: URL] = [:]
        for project in archive.projects {
            let target = sourceRoots[project.sourcePath] ?? projectsRoot.appendingPathComponent(project.id.uuidString)
            sourceRoots[project.sourcePath] = target
            groups[project.id] = target
            result.directories.append(target.path)
            result.directories += project.directories.map { target.appendingPathComponent($0).path }
        }
        for project in archive.projects where project.referenceID == nil {
            guard let target = groups[project.id] else { continue }
            let references = archive.projects.filter { $0.workspaceID == project.workspaceID && $0.referenceID != nil }.compactMap { group in
                groups[group.id].map { WorkspaceFolderReference(path: $0.path) }
            }
            let workspace = ChatWorkspace(name: project.name, path: target.path, space: space, referencedFolders: references)
            result.workspaces.append(workspace)
            if result.workspaceMappings == nil { result.workspaceMappings = [:] }
            result.workspaceMappings?[project.workspaceID.uuidString] = workspace.id.uuidString
        }
        var targetReceipts: [String: BackupFileIO.Receipt] = [:]
        for file in archive.files {
            let destination: URL
            switch file.kind {
            case .project:
                guard let groupID = file.projectID, let group = groups[groupID] else { throw BackupError.preflightFailed("Missing project folder") }
                destination = group.appendingPathComponent(file.relativePath)
            case .database:
                let base = URL(fileURLWithPath: file.relativePath).deletingPathExtension().lastPathComponent.prefix(120)
                destination = spaceRoot.appendingPathComponent("databases/\(base)-\(id.uuidString.prefix(8))-\(result.files.count).sqlite")
            case .knowledge:
                destination = spaceRoot.appendingPathComponent("knowledge-assets/restored/" + id.uuidString + "/" + file.relativePath)
            case .skillHistory:
                let parts = try BackupFileIO.components(file.relativePath)
                guard parts.count >= 3 else { throw BackupError.preflightFailed("Invalid skill history path") }
                destination = spaceRoot.appendingPathComponent("skills/.versions/" + parts[0] + "/" + id.uuidString.prefix(8) + "-" + parts[1] + "/" + parts.dropFirst(2).joined(separator: "/"))
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw MaintenanceError.busy }
            if let existing = targetReceipts[destination.path] {
                guard existing == file.receipt else { throw BackupError.preflightFailed("Conflicting project file snapshots") }
                continue
            }
            targetReceipts[destination.path] = file.receipt
            result.files.append(.init(source: file, destination: destination.path))
            var parent = destination.deletingLastPathComponent()
            let boundary = file.kind == .project ? fileArea.defaultChatRoot(for: space) : spaceRoot
            while parent.path != boundary.path, FileAreaService.isInside(parent, root: boundary) {
                if !FileManager.default.fileExists(atPath: parent.path) { result.directories.append(parent.path) }
                parent.deleteLastPathComponent()
            }
        }
        result.directories = Array(Set(result.directories)).sorted { $0.count < $1.count }
        return result
    }

    func conflicts(_ archive: SpaceAssetsArchive, staging: URL) async throws -> [String] {
        let root = try AppDirectory(url: staging, create: false)
        var conflicts: [String] = []
        for app in archive.apps {
            let backup = try retarget(NativeAppBackup.decode(BackupFileIO.read(app.file, in: root, limit: NativeAppBackup.maximumBytes)))
            let plan = try await apps.inspectRestore(backup, space: space)
            guard !plan.currentDataIsUnreadable else { throw BackupError.preflightFailed("Repair the existing mini-app before restoring the space") }
            if plan.previousFingerprint != nil { conflicts.append(app.id) }
        }
        return conflicts
    }

    func apply(_ plan: SpaceAssetsRestorePlan, staging: URL) async throws {
        let input = try AppDirectory(url: staging, create: false)
        for path in plan.directories { _ = try AppDirectory(url: URL(fileURLWithPath: path), create: true) }
        for file in plan.files {
            let url = URL(fileURLWithPath: file.destination)
            let output = try AppDirectory(url: url.deletingLastPathComponent(), create: true)
            try BackupFileIO.copy(file.source.file, from: input, to: output, as: url.lastPathComponent,
                limit: Self.maximumFileBytes, expected: file.source.receipt)
        }
        for app in plan.apps {
            let value = try retarget(NativeAppBackup.decode(BackupFileIO.read(app.file, in: input, limit: NativeAppBackup.maximumBytes)))
            try await apps.restore(value, space: space, replacing: app.beforeFingerprint)
        }
        for draft in plan.drafts { try await drafts.restoreDraft(draft) }
    }

    func verify(_ plan: SpaceAssetsRestorePlan) async throws {
        for file in plan.files {
            let url = URL(fileURLWithPath: file.destination)
            let current = try BackupFileIO.receipt(url.lastPathComponent, in: AppDirectory(url: url.deletingLastPathComponent(), create: false), limit: Self.maximumFileBytes)
            guard current.sha256 == file.source.receipt.sha256, current.byteCount == file.source.receipt.byteCount else { throw BackupError.preflightFailed("Restored file verification failed") }
        }
        for app in plan.apps {
            guard try await apps.backup(id: app.id, space: space).fingerprint == app.afterFingerprint else { throw BackupError.preflightFailed("Restored mini-app verification failed") }
        }
        let pending = try await drafts.catalog()
        guard plan.drafts.allSatisfy(pending.drafts.contains) else { throw BackupError.preflightFailed("Restored mini-app draft verification failed") }
    }

    func rollback(_ plan: SpaceAssetsRestorePlan, recovery: URL) async throws {
        let root = try AppDirectory(url: recovery, create: false)
        for app in plan.apps.reversed() {
            let current: NativeAppBackup?
            do { current = try await apps.backup(id: app.id, space: space) }
            catch let issue as NativeAppError where issue.code == .missing { current = nil }
            if current?.fingerprint == app.beforeFingerprint { continue }
            guard current?.fingerprint == app.afterFingerprint else { throw MaintenanceError.busy }
            if let beforeFile = app.beforeFile {
                let before = try NativeAppBackup.decode(BackupFileIO.read(beforeFile, in: root, limit: NativeAppBackup.maximumBytes))
                try await apps.restore(before, space: space, replacing: app.afterFingerprint)
            } else {
                let snapshot = try await apps.loadIncludingRetained(id: app.id)
                try await apps.remove(id: app.id, revision: snapshot.revision, keepData: false)
            }
        }
        let pending = try await drafts.catalog()
        for draft in plan.drafts {
            if let current = pending.drafts.first(where: { $0.id == draft.id }) {
                guard current == draft else { throw MaintenanceError.busy }
                try await drafts.discard(id: draft.id)
            }
        }
        for file in plan.files.reversed() {
            let url = URL(fileURLWithPath: file.destination)
            if FileManager.default.fileExists(atPath: url.path) {
                try BackupFileIO.removeUnchanged(url.lastPathComponent, in: AppDirectory(url: url.deletingLastPathComponent(), create: false),
                    expected: file.source.receipt, limit: Self.maximumFileBytes)
            }
        }
        for path in plan.directories.sorted(by: { $0.count > $1.count }) {
            // rmdir cannot remove a directory containing later user material.
            if rmdir(path) != 0, errno != ENOENT, errno != ENOTEMPTY { throw NativeAppError(.storage) }
        }
    }

    private func retarget(_ backup: NativeAppBackup) throws -> NativeAppBackup {
        if backup.space == space { return backup }
        let value = backup.contents
        return try NativeAppBackup(contents: .init(space: space, definition: value.definition, previous: value.previous,
            state: value.state, installed: value.installed, dataVersion: value.dataVersion, records: value.records,
            files: value.files, iconColor: value.iconColor))
    }
}
