import Foundation
import CryptoKit

/// Bookmarks are space-owned preferences, never included as authority in note exports.
public enum NoteModelAccess {
    public static func bookmark(_ folder: URL) throws -> Data {
        try NoteCaptureRecovery.regularDirectory(folder)
        return try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public static func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw NoteStoreError.missing }
        return url
    }
    public static func identity(_ folder: URL) throws -> String {
        try NoteCaptureRecovery.regularDirectory(folder)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { throw NoteStoreError.missing }
        var records: [String] = []
        var count = 0
        for case let url as URL in entries {
            try Task.checkCancellation()
            count += 1
            guard count <= 4096 else { throw NoteStoreError.tooLarge }
            let value = try url.resourceValues(forKeys: Set(keys))
            guard value.isSymbolicLink != true else { throw NoteStoreError.invalidContent }
            if value.isRegularFile == true {
                records.append(String(url.path.dropFirst(folder.path.count)) + "#\(value.fileSize ?? 0)#\(value.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        guard !records.isEmpty else { throw NoteStoreError.missing }
        return NoteMediaTranscriber.sourceHash(Data(records.sorted().joined(separator: "\n").utf8))
    }
}
