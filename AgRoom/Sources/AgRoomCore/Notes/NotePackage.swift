import Foundation

public struct NotePackage: Codable, Sendable, Identifiable {
    public var id: UUID { note.id }
    public struct Media: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var data: Data
        public var sha256: String
    }
    public let format: String
    public var note: WorkNote
    public var media: [Media]
    public static let maximumBytes = 512 * 1024 * 1024
    public func validate() throws {
        guard format == "agroom-note-v1", media.count <= 256,
              !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              try JSONEncoder().encode(note).count <= NoteStore.maximumContentBytes,
              note.todos.count <= 1000, note.summaries.count <= 100,
              Set(media.map(\.id)).count == media.count else { throw NoteStoreError.invalidContent }
        var total = 0
        for item in media {
            guard !item.name.isEmpty, URL(fileURLWithPath: item.name).lastPathComponent == item.name,
                  !item.data.isEmpty, item.data.count <= NoteStore.maximumMediaBytes,
                  item.sha256 == NoteMediaTranscriber.sourceHash(item.data) else { throw NoteStoreError.invalidContent }
            total += item.data.count
            guard total <= Self.maximumBytes else { throw NoteStoreError.tooLarge }
        }
    }
    public func write(to destination: URL) throws {
        try validate()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw NoteStoreError.conflict }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".note-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        struct Index: Codable { let format: String; let note: WorkNote; let media: [NotePackageIndexItem] }
        let index = Index(format: format, note: note, media: media.map { .init(id: $0.id, name: $0.name, bytes: $0.data.count, sha256: $0.sha256) })
        try JSONEncoder().encode(index).write(to: staging.appendingPathComponent("note.json"), options: .atomic)
        for item in media { try item.data.write(to: staging.appendingPathComponent(item.id.uuidString + ".bin"), options: .atomic) }
        try FileManager.default.moveItem(at: staging, to: destination)
    }
    public static func read(from directory: URL) throws -> NotePackage {
        try NoteCaptureRecovery.regularDirectory(directory)
        struct Index: Codable { let format: String; let note: WorkNote; let media: [NotePackageIndexItem] }
        let data = try NoteCaptureRecovery.read(directory.appendingPathComponent("note.json"), maximum: 8 * 1024 * 1024)
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.media.count <= 256, index.media.allSatisfy({ $0.bytes > 0 && $0.bytes <= NoteStore.maximumMediaBytes }),
              index.media.reduce(0, { $0 + $1.bytes }) <= maximumBytes else { throw NoteStoreError.tooLarge }
        let media = try index.media.map { entry in
            let data = try NoteCaptureRecovery.read(directory.appendingPathComponent(entry.id.uuidString + ".bin"), maximum: entry.bytes)
            guard data.count == entry.bytes else { throw NoteStoreError.invalidContent }
            return Media(id: entry.id, name: entry.name, data: data, sha256: entry.sha256)
        }
        let package = NotePackage(format: index.format, note: index.note, media: media)
        try package.validate()
        return package
    }
}
private struct NotePackageIndexItem: Codable {
    let id: UUID
    let name: String
    let bytes: Int
    let sha256: String
}
