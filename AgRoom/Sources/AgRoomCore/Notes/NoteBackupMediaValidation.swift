import Foundation
import CryptoKit

/// Verify the complete media graph before any restore writes, reading one bounded blob at a time.
enum NoteBackupMediaValidation {
    static func validate(_ backup: SpaceDatabaseBackup, blobs: SpaceBackupBlobs?) throws {
        func records(_ name: String) -> [[String:SpaceBackupValue]] {
            guard let table = backup.tables.first(where: { $0.name == name }) else { return [] }
            return table.rows.map { Dictionary(uniqueKeysWithValues: zip(table.columns,$0)) }
        }
        func integer(_ value: SpaceBackupValue?) -> Int? { if case .integer(let n) = value, let result = Int(exactly: n) { return result }; return nil }
        func text(_ value: SpaceBackupValue?) -> String? { value?.string }
        func bytes(_ value: SpaceBackupValue?, maximum: Int) throws -> Data {
            switch value {
            case .blob(let data): guard data.count <= maximum else { throw NoteStoreError.tooLarge }; return data
            case .blobFile(let ref):
                guard ref.byteCount <= maximum, let blobs else { throw NoteStoreError.tooLarge }
                return try blobs.read(ref)
            default: throw NoteStoreError.invalidContent
            }
        }
        let chunks = Dictionary(grouping: records("note_media_chunks"),by: { text($0["mediaID"]) ?? "" })
        let frames = Dictionary(grouping: records("note_visual_frames"),by: { text($0["mediaID"]) ?? "" })
        let media = records("note_media"), ids = Set(media.compactMap { text($0["id"]) })
        guard Set(chunks.keys).isSubset(of: ids), Set(frames.keys).isSubset(of: ids) else { throw NoteStoreError.invalidContent }
        for row in media {
            try blobs?.checkCancellation(); try Task.checkCancellation()
            guard let id = text(row["id"]), UUID(uuidString: id) != nil, integer(row["isReady"]) ?? 1 == 1 else { throw NoteStoreError.invalidContent }
            let inline = try bytes(row["contents"],maximum: NoteStore.maximumMediaBytes)
            let size = integer(row["byteCount"]) ?? inline.count, removed = integer(row["sourceRemoved"]) == 1
            let parts = chunks[id] ?? []
            guard (removed && size == 0 && inline.isEmpty && parts.isEmpty) || (!removed && size > 0 && size <= NoteStore.maximumFileBytes) else { throw NoteStoreError.invalidContent }
            if !removed {
                var hash = SHA256(), count = 0
                if !inline.isEmpty {
                    guard inline.count == size, parts.isEmpty else { throw NoteStoreError.invalidContent }
                    hash.update(data: inline); count = inline.count
                } else {
                    for (index,part) in parts.sorted(by: { (integer($0["sequence"]) ?? -1) < (integer($1["sequence"]) ?? -1) }).enumerated() {
                        guard integer(part["sequence"]) == index else { throw NoteStoreError.invalidContent }
                        let data = try bytes(part["contents"],maximum: NoteStore.mediaChunkBytes)
                        guard !data.isEmpty, data.count <= size - count else { throw NoteStoreError.invalidContent }
                        hash.update(data: data); count += data.count
                    }
                }
                guard count == size else { throw NoteStoreError.invalidContent }
                if let expected = text(row["sha256"]) {
                    guard hash.finalize().map({ String(format: "%02x",$0) }).joined() == expected else { throw NoteStoreError.invalidContent }
                }
            }
            let samples = frames[id] ?? []
            guard samples.count <= 1024 else { throw NoteStoreError.tooLarge }
            var frameBytes = 0, source: String?
            for (index,frame) in samples.sorted(by: { (integer($0["sequence"]) ?? -1) < (integer($1["sequence"]) ?? -1) }).enumerated() {
                let seconds: Double?
                switch frame["seconds"] { case .real(let n): seconds = n; case .integer(let n): seconds = Double(n); default: seconds = nil }
                guard integer(frame["sequence"]) == index, let seconds, seconds.isFinite, (0...28_800).contains(seconds),
                      let stamp = text(frame["source"]), stamp.count <= 256, source == nil || source == stamp else { throw NoteStoreError.invalidContent }
                source = stamp
                let data = try bytes(frame["contents"],maximum: 2 * 1024 * 1024)
                frameBytes += data.count
                guard !data.isEmpty, frameBytes <= 96 * 1024 * 1024 else { throw NoteStoreError.tooLarge }
            }
        }
    }
}
