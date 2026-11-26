import Foundation

/// Immutable revisions in a user-selected folder (including system-managed cloud
/// folders). The database remains authoritative; incoming files require preview.
/// A marker prevents one folder from becoming a bridge between personal and work.
public enum NoteFolderMirror {
    private struct Marker: Codable { let format: String; let space: String }
    public static func prepare(_ root: URL, space: String) throws {
        guard ["personal", "work"].contains(space) else { throw NoteStoreError.invalidContent }
        try NoteCaptureRecovery.regularDirectory(root)
        let marker = root.appendingPathComponent("agroom-notes-space.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            let value = try JSONDecoder().decode(Marker.self, from: NoteCaptureRecovery.read(marker, maximum: 4096))
            guard value.format == "agroom-notes-mirror-v1", value.space == space else { throw NoteStoreError.conflict }
        } else {
            // Only an empty folder can acquire authority. Never adopt another
            // application's contents or replace an unrecognized marker.
            let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard contents.allSatisfy({ $0.lastPathComponent == ".DS_Store" }) else { throw NoteStoreError.conflict }
            try JSONEncoder().encode(Marker(format: "agroom-notes-mirror-v1", space: space)).write(to: marker, options: .withoutOverwriting)
        }
    }
    public static func write(_ package: NotePackage, to root: URL, space: String) throws -> Bool {
        try prepare(root, space: space)
        let folder = root.appendingPathComponent(package.id.uuidString)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try NoteCaptureRecovery.regularDirectory(folder)
        guard let token = package.note.versionToken else { throw NoteStoreError.invalidContent }
        let target = folder.appendingPathComponent("\(package.note.revision)-\(token.uuidString).zwnote")
        if FileManager.default.fileExists(atPath: target.path) {
            let previous = try NotePackage.read(from: target)
            guard previous.note == package.note, previous.media.count == package.media.count,
                  Dictionary(uniqueKeysWithValues: previous.media.map { ($0.id, $0.sha256) }) == Dictionary(uniqueKeysWithValues: package.media.map { ($0.id, $0.sha256) }) else { throw NoteStoreError.conflict }
            return false
        }
        try Task.checkCancellation()
        try package.write(to: target)
        return true
    }
    public static func revisions(in root: URL, space: String) throws -> [URL] {
        try prepare(root, space: space)
        var revisions: [URL] = []
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard folders.count <= 10_002 else { throw NoteStoreError.tooLarge }
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            try NoteCaptureRecovery.regularDirectory(folder)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "zwnote" {
                let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1)
                guard parts.count == 2, let revision = Int(parts[0]), revision > 0, UUID(uuidString: String(parts[1])) != nil else { throw NoteStoreError.invalidContent }
                try NoteCaptureRecovery.regularDirectory(file)
                revisions.append(file)
                guard revisions.count <= 10_000 else { throw NoteStoreError.tooLarge }
            }
        }
        return revisions.sorted { $0.path < $1.path }
    }
}

extension NoteFolderMirror {
    public static func writeFiles(_ package: NoteFilePackage, to root: URL, space: String) async throws -> Bool {
        try prepare(root,space: space)
        let folder = root.appendingPathComponent(package.id.uuidString)
        if !FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: false,attributes: [.posixPermissions:0o700]) }
        try NoteCaptureRecovery.regularDirectory(folder)
        guard let version = package.note.versionToken else { throw NoteStoreError.invalidContent }
        let target = folder.appendingPathComponent("\(package.note.revision)-\(version.uuidString).zwnote")
        if FileManager.default.fileExists(atPath: target.path) {
            let old = try await NoteFilePackage.read(target)
            guard old.note == package.note, Dictionary(uniqueKeysWithValues: old.media.map { ($0.id,$0.sha256) }) == Dictionary(uniqueKeysWithValues: package.media.map { ($0.id,$0.sha256) }) else { throw NoteStoreError.conflict }
            return false
        }
        try prepare(root,space: space)
        try await package.write(to: target)
        return true
    }
}
