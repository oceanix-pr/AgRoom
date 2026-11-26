import Foundation
import GRDB

/// File-backed preview. A collection inventory never loads the library's media into memory.
public struct NoteFilePackage: Sendable, Identifiable {
    public struct Media: Codable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let bytes: Int
        public let sha256: String
        public var file: URL
    }
    public var id: UUID { note.id }
    public var note: WorkNote
    public let media: [Media]
    public var sourceIdentity: String?
    public var visual: Visual?
    public struct Visual: Sendable {
        public let mediaID: UUID
        public let name: String
        public let source: String
        public let sourceRemoved: Bool
        public let frames: [Frame]
    }
    public struct Frame: Sendable {
        public let id: UUID
        public let seconds: Double
        public let bytes: Int
        public let sha256: String
        public let file: URL
    }
    public init(note: WorkNote, media: [Media], sourceIdentity: String? = nil, visual: Visual? = nil) {
        self.note = note; self.media = media; self.sourceIdentity = sourceIdentity; self.visual = visual
    }
    struct Index: Codable { let format: String; let note: WorkNote; let media: [IndexMedia]; var visual: IndexVisual? }
    struct IndexMedia: Codable { let id: UUID; let name: String; let bytes: Int; let sha256: String }
    struct IndexVisual: Codable {
        let mediaID: UUID; let name: String; let source: String; let sourceRemoved: Bool
        let frames: [IndexFrame]
    }
    struct IndexFrame: Codable { let id: UUID; let seconds: Double; let bytes: Int; let sha256: String }
    var visualIndex: IndexVisual? {
        visual.map { .init(mediaID: $0.mediaID,name: $0.name,source: $0.source,sourceRemoved: $0.sourceRemoved,frames: $0.frames.map { .init(id: $0.id,seconds: $0.seconds,bytes: $0.bytes,sha256: $0.sha256) }) }
    }
    public static func read(_ directory: URL) async throws -> Self {
        try NoteCaptureRecovery.regularDirectory(directory)
        let index = try JSONDecoder().decode(Index.self, from: NoteCaptureRecovery.read(directory.appendingPathComponent("note.json"), maximum: 8 * 1024 * 1024))
        guard index.format == "agroom-note-v1", index.media.count <= 10_000, Set(index.media.map(\.id)).count == index.media.count else { throw NoteStoreError.invalidContent }
        var files: [Media] = []
        for item in index.media {
            try Task.checkCancellation()
            guard !item.name.isEmpty, item.name == URL(fileURLWithPath: item.name).lastPathComponent, item.bytes > 0, item.bytes <= NoteStore.maximumFileBytes else { throw NoteStoreError.invalidContent }
            let file = directory.appendingPathComponent(item.id.uuidString + ".bin")
            guard try NoteMediaFileStamp.read(file).bytes == item.bytes, try await NoteStore.digest(file) == item.sha256 else { throw NoteStoreError.invalidContent }
            files.append(.init(id: item.id, name: item.name, bytes: item.bytes, sha256: item.sha256, file: file))
        }
        let visual = try await readVisual(index.visual,in: directory)
        if let visual {
            guard index.note.visualMediaID == visual.mediaID, visual.sourceRemoved != files.contains(where: { $0.id == visual.mediaID }) else { throw NoteStoreError.invalidContent }
        }
        return .init(note: index.note, media: files, visual: visual)
    }
    static func readVisual(_ index: IndexVisual?, in directory: URL) async throws -> Visual? {
        guard let index else { return nil }
        guard !index.name.isEmpty, index.name == URL(fileURLWithPath: index.name).lastPathComponent,
              index.source.count <= 256, !index.frames.isEmpty, index.frames.count <= 1024,
              Set(index.frames.map(\.id)).count == index.frames.count else { throw NoteStoreError.invalidContent }
        var frames: [Frame] = [], bytes = 0
        for frame in index.frames {
            try Task.checkCancellation()
            guard frame.seconds.isFinite, frame.seconds >= 0, frame.seconds <= 28_800, (1...2 * 1024 * 1024).contains(frame.bytes) else { throw NoteStoreError.invalidContent }
            bytes += frame.bytes; guard bytes <= 96 * 1024 * 1024 else { throw NoteStoreError.tooLarge }
            let file = directory.appendingPathComponent("frames").appendingPathComponent(frame.id.uuidString + ".jpg")
            try NoteCaptureRecovery.regularDirectory(file.deletingLastPathComponent())
            guard try NoteMediaFileStamp.read(file).bytes == frame.bytes, try await NoteStore.digest(file) == frame.sha256 else { throw NoteStoreError.invalidContent }
            frames.append(.init(id: frame.id,seconds: frame.seconds,bytes: frame.bytes,sha256: frame.sha256,file: file))
        }
        return .init(mediaID: index.mediaID,name: index.name,source: index.source,sourceRemoved: index.sourceRemoved,frames: frames)
    }
    public func write(to destination: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw NoteStoreError.conflict }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".note-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let index = Index(format: "agroom-note-v1", note: note, media: media.map { .init(id: $0.id,name: $0.name,bytes: $0.bytes,sha256: $0.sha256) },visual: visualIndex)
        try JSONEncoder().encode(index).write(to: staging.appendingPathComponent("note.json"), options: .atomic)
        for file in media {
            try Task.checkCancellation()
            try await NoteFileTransfer.copy(file.file, to: staging.appendingPathComponent(file.id.uuidString + ".bin"), expectedDigest: file.sha256)
        }
        if let visual {
            let folder = staging.appendingPathComponent("frames")
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: false,attributes: [.posixPermissions:0o700])
            for frame in visual.frames {
                try await NoteFileTransfer.copy(frame.file,to: folder.appendingPathComponent(frame.id.uuidString + ".jpg"),expectedDigest: frame.sha256)
            }
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}

public enum NoteFileTransfer {
    public static func copy(_ source: URL, to destination: URL, expectedDigest: String? = nil) async throws {
        try await NoteStore.copyMediaFile(source,to: destination,expectedDigest: expectedDigest)
    }
}

extension NoteLegacyImporter {
    public static func inventory(directory: URL) throws -> [URL] {
        try NoteCaptureRecovery.regularDirectory(directory)
        var entries: [URL] = [], inspected = 0
        func scan(_ root: URL, depth: Int) throws {
            guard depth <= 8 else { return }
            for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                try Task.checkCancellation(); inspected += 1
                guard inspected <= 200_000 else { throw NoteStoreError.tooLarge }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                if child.lastPathComponent.range(of: #"^\d{12}(\d{2})?(-[1-9]\d*)?$"#, options: .regularExpression) != nil { entries.append(child) }
                else if !["WhisperModel", "DiarizationModel", "Voiceprints", "Dictionary"].contains(child.lastPathComponent) { try scan(child, depth: depth + 1) }
            }
        }
        try scan(directory, depth: 0)
        return entries.sorted { $0.path < $1.path }
    }
    public static func previewFiles(directory: URL, plaintext: Bool = false) async throws -> NoteFilePackage {
        let package = try await Task.detached { try preview(directory: directory, allowLegacyKeychain: !plaintext, plaintext: plaintext, includeMedia: false) }.value
        let extensions: Set<String> = ["m4a","wav","mp3","aac","caf","flac","ogg","mp4","mov","m4v","png","jpg","jpeg","heic","webp","tiff","gif"]
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        guard children.count <= 10_000 else { throw NoteStoreError.tooLarge }
        var media: [NoteFilePackage.Media] = [], fingerprints: [String] = []
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize != 0 else { continue }
            let stamp = try NoteMediaFileStamp.read(child)
            fingerprints.append("\(child.lastPathComponent):\(stamp.bytes):\(stamp.modifiedSeconds):\(stamp.modifiedNanos)")
            if extensions.contains(child.pathExtension.lowercased()) {
                media.append(.init(id: UUID(), name: child.lastPathComponent, bytes: stamp.bytes, sha256: try await NoteStore.digest(child), file: child))
            }
        }
        let identity = NoteMediaTranscriber.sourceHash(Data((directory.standardizedFileURL.path + fingerprints.joined(separator: "\n")).utf8))
        return .init(note: package.note, media: media, sourceIdentity: identity)
    }
}

extension NoteStore {
    public func filePackage(id: UUID, in directory: URL) async throws -> NoteFilePackage {
        guard let note = try await get(id: id) else { throw NoteStoreError.missing }
        var files: [NoteFilePackage.Media] = []
        for item in try await media(noteID: id) {
            let url = directory.appendingPathComponent(item.id.uuidString + ".bin")
            try await writeMedia(noteID: id, id: item.id, to: url)
            files.append(.init(id: item.id, name: item.name, bytes: item.byteCount, sha256: try await Self.digest(url), file: url))
        }
        var visual: NoteFilePackage.Visual?
        if let mediaID = note.visualMediaID {
            let metadata: (String,Bool,String)? = try await queue.read { db in
                guard let row = try Row.fetchOne(db,sql: "SELECT name,sourceRemoved FROM note_media WHERE id = ? AND noteID = ? AND isReady = 1",arguments: [mediaID.uuidString,id.uuidString]),
                      let source = try String.fetchOne(db,sql: "SELECT source FROM note_visual_frames WHERE mediaID = ? LIMIT 1",arguments: [mediaID.uuidString]) else { return nil }
                return (row["name"],row["sourceRemoved"],source)
            }
            if let metadata {
                var frames: [NoteFilePackage.Frame] = []
                for frame in try await visualFrames(mediaID: mediaID,source: metadata.2) {
                    try Task.checkCancellation()
                    let frameID = UUID(), file = directory.appendingPathComponent(frameID.uuidString + ".jpg")
                    try frame.jpeg.write(to: file,options: .withoutOverwriting)
                    frames.append(.init(id: frameID,seconds: frame.seconds,bytes: frame.jpeg.count,sha256: NoteMediaTranscriber.sourceHash(frame.jpeg),file: file))
                }
                visual = .init(mediaID: mediaID,name: metadata.0,source: metadata.2,sourceRemoved: metadata.1,frames: frames)
            }
        }
        guard try await get(id: id) == note else { throw NoteStoreError.conflict }
        return .init(note: note, media: files, visual: visual)
    }
    public func importedNote(source: String) async throws -> WorkNote? {
        let id = try await queue.read { db in try String.fetchOne(db, sql: "SELECT noteID FROM note_import_origins WHERE source = ?", arguments: [source]) }
        guard let id = id.flatMap(UUID.init(uuidString:)) else { return nil }
        return try await get(id: id)
    }
    public func importFiles(_ package: NoteFilePackage) async throws -> WorkNote {
        if let source = package.sourceIdentity, let note = try await importedNote(source: source) { return note }
        let snapshot = NoteFilePackage.Index(format: "agroom-note-v1",note: package.note,media: package.media.map { .init(id: $0.id,name: $0.name,bytes: $0.bytes,sha256: $0.sha256) },visual: package.visualIndex)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let source = try package.sourceIdentity ?? "package:" + NoteMediaTranscriber.sourceHash(encoder.encode(snapshot))
        let stagedID = try await queue.read { db in try String.fetchOne(db, sql: "SELECT noteID FROM note_import_staging WHERE source = ?", arguments: [source]) }
        let saved: WorkNote
        if let id = stagedID.flatMap(UUID.init(uuidString:)), let existing = try await get(id: id) { saved = existing }
        else {
            var note = package.note; note.id = UUID(); note.revision = 1; note.versionToken = UUID(); note.visualMediaID = nil
            for index in note.todos.indices { note.todos[index].reminderID = nil }
            guard !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.todos.count <= 1000, note.summaries.count <= 100,
                  try JSONEncoder().encode(note).count <= Self.maximumContentBytes else { throw NoteStoreError.invalidContent }
            let candidate = note
            try await queue.maintenanceWrite { db in
                try db.execute(sql: "INSERT INTO notes (id,revision,title,searchText,archived,pinned,updatedAt,contents) VALUES (?,?,?,?,?,?,?,?)",arguments: [candidate.id.uuidString,candidate.revision,cipher.enabled ? "" : candidate.title,cipher.enabled ? "" : candidate.searchText,candidate.archived,candidate.pinned,candidate.updatedAt,try cipher.encode(candidate,table: "notes")])
                try db.execute(sql: "INSERT INTO note_import_staging (source,noteID) VALUES (?,?)",arguments: [source,candidate.id.uuidString])
            }
            saved = candidate
        }
        var mediaMap: [UUID:UUID] = [:]
        for file in package.media {
            try Task.checkCancellation()
            guard try NoteMediaFileStamp.read(file.file).bytes == file.bytes, try await Self.digest(file.file) == file.sha256 else { throw NoteStoreError.conflict }
            let existing = try await queue.read { db in try String.fetchOne(db, sql: "SELECT id FROM note_media WHERE noteID = ? AND name = ? AND sha256 = ? AND isReady = 1", arguments: [saved.id.uuidString,file.name,file.sha256]) }
            let id = existing.flatMap(UUID.init(uuidString:)) ?? UUID()
            if existing == nil { try await addMediaFile(id: id,noteID: saved.id,name: file.name,file: file.file) }
            mediaMap[file.id] = id
        }
        var restored = saved
        var visualFrames: [NoteVisualFrame] = []
        let visualID: UUID?
        if let visual = package.visual {
            guard package.note.visualMediaID == visual.mediaID, visual.sourceRemoved != (mediaMap[visual.mediaID] != nil), !visual.frames.isEmpty, visual.frames.count <= 1024 else { throw NoteStoreError.invalidContent }
            visualID = mediaMap[visual.mediaID] ?? UUID()
            var bytes = 0
            for frame in visual.frames {
                let data = try NoteCaptureRecovery.read(frame.file,maximum: 2 * 1024 * 1024)
                bytes += data.count
                guard bytes <= 96 * 1024 * 1024, data.count == frame.bytes, frame.seconds.isFinite, (0...28_800).contains(frame.seconds), NoteMediaTranscriber.sourceHash(data) == frame.sha256 else { throw NoteStoreError.invalidContent }
                visualFrames.append(.init(seconds: frame.seconds,jpeg: data))
            }
            restored.visualMediaID = visualID
        } else { visualID = nil }
        let result = restored, frames = visualFrames
        try await queue.maintenanceWrite { db in
            guard let data = try Data.fetchOne(db,sql: "SELECT contents FROM notes WHERE id = ?",arguments: [saved.id.uuidString]), try cipher.decode(WorkNote.self,from: data,table: "notes") == saved else { throw NoteStoreError.conflict }
            if let visual = package.visual, let visualID {
                if visual.sourceRemoved {
                    guard !visual.name.isEmpty, visual.name == URL(fileURLWithPath: visual.name).lastPathComponent else { throw NoteStoreError.invalidContent }
                    try db.execute(sql: "INSERT INTO note_media (id,noteID,name,contents,byteCount,isReady,sourceRemoved) VALUES (?,?,?,X'',0,1,1)",arguments: [visualID.uuidString,saved.id.uuidString,visual.name])
                }
                try db.execute(sql: "DELETE FROM note_visual_frames WHERE mediaID = ?",arguments: [visualID.uuidString])
                for (index,frame) in frames.enumerated() {
                    try db.execute(sql: "INSERT INTO note_visual_frames (id,mediaID,source,sequence,seconds,contents) VALUES (?,?,?,?,?,?)",arguments: [visualID.uuidString + ":\(index)",visualID.uuidString,visual.source,index,frame.seconds,frame.jpeg])
                }
                try db.execute(sql: "UPDATE notes SET contents = ? WHERE id = ?",arguments: [try cipher.encode(result,table: "notes"),saved.id.uuidString])
            }
            if let identity = package.sourceIdentity { try db.execute(sql: "INSERT INTO note_import_origins (source,noteID) VALUES (?,?)", arguments: [identity,saved.id.uuidString]) }
            try db.execute(sql: "DELETE FROM note_import_staging WHERE source = ? AND noteID = ?", arguments: [source,saved.id.uuidString])
        }
        return result
    }
}
